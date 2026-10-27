//! Resumable bzip2 decoding: input and output in pieces of any size, the
//! same engine as `Decompressor`, so a stream is decoded or refused the same
//! however it arrives.
//!
//! The engine reads the caller's input in place and takes only the bytes it
//! read whole; a byte it read part of is given again in the next call. A
//! unit the input cuts short (at most 57 bits: the block header) waits in a
//! small stage, topped up from the next input until the engine reads past
//! it. Bytes after the last stream are never taken: the streams' end is
//! exact, whatever the cuts.

const Decompress = @This();

const std = @import("std");
const Io = std.Io;
const engine = @import("decode.zig");
const bits = @import("bits.zig");
const Decompressor = @import("Decompressor.zig");
const Diagnostic = @import("Diagnostic.zig");

pub const Options = struct {
    streams: Decompressor.Streams = .all,
    diagnostic: ?*Diagnostic = null,
};

pub const Status = enum {
    /// More input is needed (or `finish`). The input is taken but for up to
    /// three bytes at its end that may begin another stream ("B", "BZ",
    /// "BZh"): give `in[in_len..]` again, with what follows.
    need_input,
    /// `out` is full.
    output_full,
    /// The streams ended; input after them is not taken.
    done,
};

pub const Step = struct { in_len: usize, out_len: usize, status: Status };
pub const Error = Decompressor.Error;

/// The stage: a unit cut short and the input that tops it up.
const stage_len = 64;

/// The bytes `init` needs: the BWT vector.
pub const memory = Decompressor.memory;

options: Options,
/// Private: the BWT vector, the code tables and the stream.
tt: []u32,
tables: engine.Tables = undefined,
state: engine.State = .{},
/// Private: `held` bytes of a unit cut short, taken. The engine resumes at
/// bit `skip` of `stage[0]`, or, with nothing held, of the next input's
/// first byte, which is bit `base` of the whole input.
stage: [stage_len]u8 = undefined,
held: usize = 0,
skip: u3 = 0,
base: u64 = 0,
/// Private: a stream has ended; what follows decides whether another
/// begins. `pending`: the bytes of a header's start given back.
between: bool = false,
pending: usize = 0,
failure: ?Error = null,

/// `buffer.len >= memory`, aligned to 4.
pub fn init(buffer: []align(4) u8, options: Options) Decompress {
    return .{ .options = options, .tt = std.mem.bytesAsSlice(u32, buffer[0..memory]) };
}

pub fn reset(s: *Decompress) void {
    s.* = .{ .options = s.options, .tt = s.tt };
}

/// Take input and give output as far as each allows.
pub fn decode(s: *Decompress, in: []const u8, out: []u8) Error!Step {
    if (s.failure) |err| return err;
    var ip: usize = 0;
    var op: usize = 0;
    while (true) {
        if (s.between) {
            const rest = in[ip..];
            if (rest.len == 0) return .{ .in_len = ip, .out_len = op, .status = .need_input };
            switch (Decompressor.next(rest)) {
                .stream => {
                    s.between = false;
                    s.pending = 0;
                    s.state = .{};
                },
                .end => {
                    s.pending = 0;
                    return .{ .in_len = ip, .out_len = op, .status = .done };
                },
                .truncated => {
                    s.pending = rest.len;
                    return .{ .in_len = ip, .out_len = op, .status = .need_input };
                },
            }
        }
        const result = if (s.held != 0) s.staged(in, &ip, out, &op) else s.direct(in, &ip, out, &op);
        const status = result catch |err| switch (err) {
            error.NeedInput => {
                if (ip == in.len) return .{ .in_len = ip, .out_len = op, .status = .need_input };
                continue;
            },
            error.InvalidStream, error.ChecksumMismatch => |e| return s.fail(e, s.state.fail_bit, s.state.reason),
        };
        switch (status) {
            .output_full => return .{ .in_len = ip, .out_len = op, .status = .output_full },
            .stream_end => {
                if (s.options.streams == .one) return .{ .in_len = ip, .out_len = op, .status = .done };
                s.between = true;
            },
        }
    }
}

const RunError = engine.Error || bits.NeedInput;

/// The engine over the input in place. A unit cut short goes to the stage,
/// and the input is taken.
fn direct(s: *Decompress, in: []const u8, ip: *usize, out: []u8, op: *usize) RunError!engine.Status {
    const rest = in[ip.*..];
    var r: bits.Reader = .init(rest, s.base, s.skip);
    const result = engine.run(&s.state, s.work(), &r, out, op);
    const bit = if (rest.len == 0) s.skip else r.bitOffset() - s.base;
    s.advance(bit);
    ip.* += @intCast(bit / 8);
    _ = result catch |err| if (err == error.NeedInput) {
        // What the unit has read is under `stage_len`: it is shorter than
        // its longest, the block header.
        const tail = in[ip.*..];
        @memcpy(s.stage[0..tail.len], tail);
        s.held = tail.len;
        ip.* = in.len;
    };
    return result;
}

/// The engine over the stage topped up from the input. Once it has read
/// past what was held, what it read of the input is taken and the rest
/// given back, and it goes on in place.
fn staged(s: *Decompress, in: []const u8, ip: *usize, out: []u8, op: *usize) RunError!engine.Status {
    const n = @min(in.len - ip.*, stage_len - s.held);
    @memcpy(s.stage[s.held..][0..n], in[ip.*..][0..n]);
    const len = s.held + n;
    var r: bits.Reader = .init(s.stage[0..len], s.base, s.skip);
    const result = engine.run(&s.state, s.work(), &r, out, op);
    const bit = r.bitOffset() - s.base;
    const byte: usize = @intCast(bit / 8);
    s.advance(bit);
    if (byte >= s.held) {
        ip.* += byte - s.held;
        s.held = 0;
    } else {
        @memmove(s.stage[0 .. len - byte], s.stage[byte..len]);
        s.held = len - byte;
        ip.* += n;
    }
    return result;
}

fn work(s: *Decompress) engine.Work {
    return .{ .tt = s.tt, .tables = &s.tables };
}

/// The engine read `bit` bits from where it resumed.
fn advance(s: *Decompress, bit: u64) void {
    s.base += 8 * (bit / 8);
    s.skip = @intCast(bit % 8);
}

/// Declare the end of input after the output is drained: refuses a stream
/// cut short.
pub fn finish(s: *Decompress) Error!void {
    if (s.failure) |err| return err;
    if (s.between) {
        if (s.pending == 0) return;
    } else if (s.state.done()) return;
    return s.fail(error.Truncated, s.base + s.skip + 8 * @as(u64, s.held + s.pending), .truncated);
}

/// Refuse the stream: every later call returns `err`.
fn fail(s: *Decompress, err: Error, bit: u64, reason: Diagnostic.Reason) Error {
    s.failure = err;
    if (s.options.diagnostic) |d| d.* = .{ .bit_offset = .fromRaw(bit), .reason = reason };
    return err;
}

/// A `std.Io.Reader` over the same resumable decoder. `buffer` reserves 4
/// KiB for the reader's own buffering, then `memory`; aligned to 4.
pub const Reader = struct {
    interface: Io.Reader,
    input: *Io.Reader,
    state: Decompress,
    failure: ?Error = null,

    pub fn init(input: *Io.Reader, buffer: []align(4) u8, options: Options) Reader {
        return .{ .interface = .{ .vtable = &.{ .stream = stream, .readVec = readVec }, .buffer = buffer[0..4096], .seek = 0, .end = 0 }, .input = input, .state = Decompress.init(@alignCast(buffer[4096..]), options) }; // aegis: no-danger: 4096 bytes into a buffer aligned to 4
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
            if (step.status == .done) return error.EndOfStream;
            // What was given back (a header's start) comes again, with more.
            input = r.input.peekGreedy(input.len - step.in_len + 1) catch |failure| {
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
        const r: *Reader = @alignCast(@fieldParentPtr("interface", interface)); // aegis: no-danger: interface is the embedded Reader field
        _ = writer;
        if (limit == .nothing) return 0;
        const n = try r.readInto(limit.slice(interface.buffer));
        interface.seek = 0;
        interface.end = n;
        return 0;
    }

    fn readVec(interface: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const r: *Reader = @alignCast(@fieldParentPtr("interface", interface)); // aegis: no-danger: interface is the embedded Reader field
        if (data[0].len != 0) return r.readInto(data[0]);
        const n = try r.readInto(interface.buffer[interface.end..]);
        interface.end += n;
        return 0;
    }
};
