//! Resumable LZMA decoding: raw LZMA, raw LZMA2 or a `.lzma` file in
//! pieces of input and output of any size, the window the caller's, the
//! engine the whole-buffer decoders', so a stream is decoded or refused the
//! same however it arrives. The stream's end is exact: input after it is
//! never taken.

const Decompress = @This();

const std = @import("std");
const Io = std.Io;
const engine = @import("decode.zig");
const Stream = @import("Stream.zig");
const Decompressor = @import("Decompressor.zig");
const Diagnostic = @import("Diagnostic.zig");

pub const Format = union(enum) {
    /// Raw LZMA with its properties apart; `size` as `Decompressor.Lzma1`.
    lzma1: struct { properties: engine.Properties = .{}, dictionary: u32, size: ?u64 = null },
    /// Raw LZMA2.
    lzma2: struct { dictionary: u32 },
    /// A `.lzma` file: its header names the dictionary and size.
    alone,
};

pub const Options = struct {
    diagnostic: ?*Diagnostic = null,
};

pub const Error = error{
    /// Data that breaks the format as liblzma reads it.
    InvalidStream,
    /// The input ends inside the stream (`finish`).
    Truncated,
    /// The stream's dictionary is larger than the window.
    WindowTooLarge,
};

pub const Status = Stream.Status;
pub const Step = Stream.Step;

/// The window a dictionary of `dictionary` bytes needs.
pub fn windowLength(dictionary: u64) usize {
    return @intCast(engine.dictionary(dictionary));
}

options: Options,
window: []u8,
format: Format,
stream: ?Stream = null,
header: [Decompressor.alone_header_len]u8 = undefined,
gathered: u8 = 0,
failure: ?Error = null,

pub fn init(window: []u8, format: Format, options: Options) Decompress {
    var z: Decompress = .{ .options = options, .window = window, .format = format };
    switch (format) {
        .lzma1 => |f| z.stream = Stream.init(window, f.dictionary, .{ .lzma1 = .{ .properties = f.properties, .size = f.size } }),
        .lzma2 => |f| z.stream = Stream.init(window, f.dictionary, .lzma2),
        .alone => {},
    }
    return z;
}

/// Take input and give output as far as each allows.
pub fn decode(z: *Decompress, in: []const u8, out: []u8) Error!Step {
    if (z.failure) |err| return err;
    var ip: usize = 0;
    if (z.stream == null) {
        // The .lzma header, gathered.
        while (z.gathered < z.header.len) {
            if (ip == in.len) return .{ .in_len = ip, .out_len = 0, .status = .need_input };
            z.header[z.gathered] = in[ip];
            z.gathered += 1;
            ip += 1;
            if (z.gathered == 1 and engine.Properties.parse(z.header[0]) == null) return z.fail(error.InvalidStream, 0, .properties);
        }
        const dict = std.mem.readInt(u32, z.header[1..5], .little);
        const size = std.mem.readInt(u64, z.header[5..13], .little);
        if (windowLength(dict) > z.window.len) return z.fail(error.WindowTooLarge, 1, .memory_limit);
        z.stream = Stream.init(z.window, dict, .{ .lzma1 = .{ .properties = engine.Properties.parse(z.header[0]).?, .size = if (size == std.math.maxInt(u64)) null else size } });
        z.stream.?.offset = Decompressor.alone_header_len;
    }
    const s = &z.stream.?;
    if (windowLength(s.ring.dict_size) > z.window.len) return z.fail(error.WindowTooLarge, 0, .memory_limit);
    const step = s.decode(in[ip..], out) catch |err| return z.fail(err, s.fail_at, s.reason);
    return .{ .in_len = ip + step.in_len, .out_len = step.out_len, .status = step.status };
}

/// Declare the end of input after the output is drained: refuses a stream
/// cut short.
pub fn finish(z: *Decompress) Error!void {
    if (z.failure) |err| return err;
    if (z.stream) |*s| if (s.done()) return;
    const at = if (z.stream) |s| s.offset else z.gathered;
    return z.fail(error.Truncated, at, .truncated);
}

fn fail(z: *Decompress, err: Error, at: u64, reason: Diagnostic.Reason) Error {
    z.failure = err;
    if (z.options.diagnostic) |d| d.* = .{ .offset = .fromRaw(at), .reason = reason };
    return err;
}

/// A `std.Io.Reader` over the same resumable decoder: `buffer` is the
/// reader's own buffering, `window` as `init`'s.
pub const Reader = struct {
    interface: Io.Reader,
    input: *Io.Reader,
    state: Decompress,
    failure: ?Error = null,

    pub fn init(input: *Io.Reader, buffer: []u8, window: []u8, format: Format, options: Options) Reader {
        return .{ .interface = .{ .vtable = &.{ .stream = stream, .readVec = readVec }, .buffer = buffer, .seek = 0, .end = 0 }, .input = input, .state = .init(window, format, options) };
    }

    /// The error behind an `error.ReadFailed`, when it was the stream's.
    pub fn err(r: *const Reader) ?Error {
        return r.failure;
    }

    fn readInto(r: *Reader, out: []u8) Io.Reader.Error!usize {
        var input: []const u8 = &.{};
        while (true) {
            const step = r.state.decode(input, out) catch |failure| {
                r.failure = failure;
                return error.ReadFailed;
            };
            r.input.toss(step.in_len);
            if (step.out_len != 0) return step.out_len;
            if (step.status == .end) return error.EndOfStream;
            input = r.input.peekGreedy(1) catch |failure| {
                if (failure == error.ReadFailed) return failure;
                r.state.finish() catch |codec_error| {
                    r.failure = codec_error;
                    return error.ReadFailed;
                };
                return error.EndOfStream;
            };
        }
    }

    fn stream(interface: *Io.Reader, writer: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const r: *Reader = @alignCast(@fieldParentPtr("interface", interface));
        _ = writer;
        if (limit == .nothing) return 0;
        const n = try r.readInto(limit.slice(interface.buffer));
        interface.seek = 0;
        interface.end = n;
        return 0;
    }

    fn readVec(interface: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const r: *Reader = @alignCast(@fieldParentPtr("interface", interface));
        if (data[0].len != 0) return r.readInto(data[0]);
        const n = try r.readInto(interface.buffer[interface.end..]);
        interface.end += n;
        return 0;
    }
};
