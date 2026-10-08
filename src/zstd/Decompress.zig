//! Resumable zstd decoding. Input is assembled one block at a time;
//! decoded blocks live beside the retained history in the caller's window.
const Decompress = @This();
const std = @import("std");
const Io = std.Io;
const decode_ = @import("decode.zig");
const frame = @import("frame.zig");
const Decompressor = @import("Decompressor.zig");
const Dictionary = @import("Dictionary.zig");
const Diagnostic = @import("Diagnostic.zig");

pub const Options = struct {
    dictionaries: []const *const Dictionary = &.{},
    frames: Decompressor.Frames = .all,
    verify_checksum: bool = true,
    format: frame.Format = .standard,
    diagnostic: ?*Diagnostic = null,
};
pub const Status = enum { need_input, output_full, frame_end, done };
pub const Step = struct { in_len: usize, out_len: usize, status: Status };
pub const Error = Decompressor.Error;

const Phase = enum { header, skip, block_header, payload, drain, checksum, frame_end, done, failed };
options: Options,
window: []u8,
tables: decode_.Tables = undefined,
entropy: decode_.Entropy = .{},
dictionary: []const u8 = &.{},
buffer: [decode_.block_max]u8 = undefined,
have: usize = 0,
wanted: usize,
phase: Phase = .header,
header: frame.Header = undefined,
block: frame.Block = undefined,
offset: u64 = 0,
frame_at: u64 = 0,
block_at: u64 = 0,
skip: u32 = 0,
frames: u64 = 0,
produced: u64 = 0,
history: usize = 0,
pending: usize = 0,
pending_end: usize = 0,
hash: std.hash.XxHash64 = .init(0),
failure: ?Error = null,

/// `window` holds the declared history plus one regenerated block. The
/// value may move before the first call; keep it in place while decoding.
pub fn init(window: []u8, options: Options) Decompress {
    return .{ .window = window, .options = options, .wanted = if (options.format == .standard) 5 else 1 };
}

pub fn reset(s: *Decompress) void {
    s.* = init(s.window, s.options);
}

/// Consume and produce as much as possible. `.frame_end` leaves the next
/// frame unread; `.done` ends `frames = .one`. An empty input can drain
/// pending output, and never declares end of input.
pub fn decode(s: *Decompress, in: []const u8, out: []u8) Error!Step {
    var ip: usize = 0;
    var op: usize = 0;
    while (true) switch (s.phase) {
        .done => return .{ .in_len = ip, .out_len = op, .status = .done },
        .failed => return s.failure.?,
        .drain => {
            const n = @min(out.len - op, s.pending_end - s.pending);
            @memcpy(out[op..][0..n], s.window[s.pending..][0..n]);
            s.pending += n;
            op += n;
            if (s.pending != s.pending_end) return .{ .in_len = ip, .out_len = op, .status = .output_full };
            if (!s.block.last) {
                s.next(.block_header, 3);
            } else if (s.header.checksum) {
                s.next(.checksum, 4);
            } else s.phase = .frame_end;
        },
        .frame_end => {
            if (s.header.content_size) |size| if (s.produced != size) return s.fail(error.InvalidStream, s.frame_at, .content_size);
            s.frames += 1;
            if (s.options.frames == .one) {
                s.phase = .done;
                return .{ .in_len = ip, .out_len = op, .status = .done };
            }
            s.next(.header, if (s.options.format == .standard) 5 else 1);
            return .{ .in_len = ip, .out_len = op, .status = .frame_end };
        },
        .skip => {
            const n = @min(in.len - ip, s.skip);
            ip += n;
            s.offset += n;
            s.skip -= @intCast(n);
            if (s.skip == 0) s.next(.header, if (s.options.format == .standard) 5 else 1) else return .{ .in_len = ip, .out_len = op, .status = .need_input };
        },
        .header, .block_header, .payload, .checksum => {
            const n = @min(in.len - ip, s.wanted - s.have);
            @memcpy(s.buffer[s.have..][0..n], in[ip..][0..n]);
            s.have += n;
            ip += n;
            s.offset += n;
            if (s.have != s.wanted) return .{ .in_len = ip, .out_len = op, .status = .need_input };
            switch (s.phase) {
                .header => try s.readHeader(),
                .block_header => try s.readBlockHeader(),
                .payload => try s.readBlock(),
                .checksum => {
                    if (s.options.verify_checksum and std.mem.readInt(u32, s.buffer[0..4], .little) != @as(u32, @truncate(s.hash.final()))) return s.fail(error.ChecksumMismatch, s.offset - 4, .checksum);
                    s.phase = .frame_end;
                },
                else => unreachable,
            }
        },
    };
}

/// Declare end of input after draining output. Refuses every unfinished
/// frame, including a skippable frame or a partial checksum.
pub fn finish(s: *Decompress) Error!void {
    if (s.phase == .failed) return s.failure.?;
    if (s.phase == .done or (s.phase == .header and s.have == 0 and (s.frames != 0 or s.options.frames == .all))) return;
    return s.fail(error.Truncated, s.offset, .truncated);
}

fn next(s: *Decompress, phase: Phase, wanted: usize) void {
    s.phase = phase;
    s.have = 0;
    s.wanted = wanted;
}

fn fail(s: *Decompress, err: Error, at: u64, reason: Diagnostic.Reason) Error {
    s.phase = .failed;
    s.failure = err;
    if (s.options.diagnostic) |d| d.* = .{ .offset = at, .reason = reason };
    return err;
}

fn readHeader(s: *Decompress) Error!void {
    var fault: frame.Fault = undefined;
    const parsed = frame.parse(s.buffer[0..s.have], s.options.format, &fault) catch |err| {
        if (err == error.Truncated) {
            const skippable = s.options.format == .standard and std.mem.readInt(u32, s.buffer[0..4], .little) & frame.skippable_mask == frame.skippable_magic;
            s.wanted = if (skippable) 8 else frame.headerLen(s.buffer[if (s.options.format == .standard) @as(usize, 4) else 0], s.options.format);
            return;
        }
        return s.fail(err, s.offset - s.have + fault.offset, if (s.frames > 0 and fault.reason == .bad_magic) .trailing_data else fault.reason);
    };
    switch (parsed) {
        .skippable => |h| {
            if (h.len > std.math.maxInt(u32) - 8) return s.fail(error.InvalidStream, s.offset - s.have, .bad_magic);
            s.skip = h.len;
            s.phase = .skip;
        },
        .zstd => |h| {
            s.frame_at = s.offset - s.have;
            if (h.window_size > s.window.len or h.blockMax() > s.window.len - @as(usize, @intCast(h.window_size))) return s.fail(error.WindowTooLarge, s.frame_at, .window_too_large);
            var dictionary: ?*const Dictionary = null;
            if (h.dictionary_id == 0) {
                if (s.options.dictionaries.len != 0) dictionary = s.options.dictionaries[0];
            } else {
                for (s.options.dictionaries) |d| if (d.id == h.dictionary_id) {
                    dictionary = d;
                    break;
                };
                if (dictionary == null) return s.fail(error.DictionaryMismatch, s.frame_at, .dictionary_mismatch);
            }
            s.header = h;
            s.entropy = if (dictionary) |d| d.startEntropy() else .{};
            s.dictionary = if (dictionary) |d| d.content else &.{};
            s.history = 0;
            s.produced = 0;
            s.hash = .init(0);
            s.next(.block_header, 3);
        },
    }
}

fn readBlockHeader(s: *Decompress) Error!void {
    s.block_at = s.offset - 3;
    s.block = frame.blockHeader(s.buffer[0..3]);
    if (s.block.kind == .reserved) return s.fail(error.InvalidStream, s.block_at, .bad_block_type);
    if (s.block.regenerated > s.header.blockMax()) return s.fail(error.InvalidStream, s.block_at, .block_too_large);
    s.next(.payload, s.block.size);
}

fn readBlock(s: *Decompress) Error!void {
    const keep = @min(s.history, @as(usize, @intCast(s.header.window_size)));
    if (keep < s.history) {
        @memmove(s.window[0..keep], s.window[s.history - keep ..][0..keep]);
        s.dictionary = &.{};
    }
    var f: decode_.Frame = .{ .tables = &s.tables, .entropy = s.entropy, .out = s.window[0 .. keep + s.header.blockMax()], .start = 0, .dict = s.dictionary, .block_max = s.header.blockMax() };
    const len: usize = switch (s.block.kind) {
        .raw => blk: {
            @memcpy(s.window[keep..][0..s.have], s.buffer[0..s.have]);
            break :blk s.have;
        },
        .rle => blk: {
            @memset(s.window[keep..][0..s.block.regenerated], s.buffer[0]);
            break :blk s.block.regenerated;
        },
        .compressed => f.block(s.buffer[0..s.have], keep) catch |err| {
            if (err == error.OutputTooSmall) return s.fail(error.InvalidStream, s.block_at, .block_too_large);
            return s.fail(err, s.block_at + 3 + f.fault.offset, f.fault.reason);
        },
        .reserved => unreachable,
    };
    s.entropy = f.entropy;
    if (s.header.checksum and s.options.verify_checksum) s.hash.update(s.window[keep..][0..len]);
    s.produced += len;
    s.history = keep + len;
    s.pending = keep;
    s.pending_end = keep + len;
    s.phase = .drain;
}

/// A reader over the same resumable decoder. `buffer` reserves 4 KiB for
/// reader buffering, then the frame's window and one decoded block.
pub const Reader = struct {
    interface: Io.Reader,
    input: *Io.Reader,
    state: Decompress,
    failure: ?Error = null,

    pub fn init(input: *Io.Reader, buffer: []u8, options: Options) Reader {
        const n = @min(buffer.len, 4096);
        return .{ .interface = .{ .vtable = &.{ .stream = stream, .readVec = readVec }, .buffer = buffer[0..n], .seek = 0, .end = 0 }, .input = input, .state = Decompress.init(buffer[n..], options) };
    }

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
        const r: *Reader = @alignCast(@fieldParentPtr("interface", interface)); // safe: interface is the embedded Reader field
        _ = writer;
        if (limit == .nothing) return 0;
        const n = try r.readInto(limit.slice(interface.buffer));
        interface.seek = 0;
        interface.end = n;
        return 0;
    }

    fn readVec(interface: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const r: *Reader = @alignCast(@fieldParentPtr("interface", interface)); // safe: interface is the embedded Reader field
        if (data[0].len != 0) return r.readInto(data[0]);
        const n = try r.readInto(interface.buffer[interface.end..]);
        interface.end += n;
        return 0;
    }
};
