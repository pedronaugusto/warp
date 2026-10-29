//! Resumable zstd decoding. Input is assembled one block at a time;
//! decoded blocks live beside the retained history in the caller's window.
const Decompress = @This();
const std = @import("std");
const aegis = @import("aegis");
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

const Phase = enum { header, skip, block_header, payload, drain, checksum, frame_end, done };

/// What a unit read says comes next: a frame of a kind, another block,
/// the checksum or the frame's end after the last block, the last frame's
/// end or another frame, or a unit done.
const Event = enum { skippable, zstd, block, checksum, end, last, more, read };

const Machine = aegis.state.Machine(Phase, Event, .{ .initial = .header, .terminal = &.{.done}, .edges = &.{
    .{ .from = .header, .on = .skippable, .to = .skip },
    .{ .from = .header, .on = .zstd, .to = .block_header },
    .{ .from = .skip, .on = .read, .to = .header },
    .{ .from = .block_header, .on = .read, .to = .payload },
    .{ .from = .payload, .on = .read, .to = .drain },
    .{ .from = .drain, .on = .block, .to = .block_header },
    .{ .from = .drain, .on = .checksum, .to = .checksum },
    .{ .from = .drain, .on = .end, .to = .frame_end },
    .{ .from = .checksum, .on = .read, .to = .frame_end },
    .{ .from = .frame_end, .on = .last, .to = .done },
    .{ .from = .frame_end, .on = .more, .to = .header },
} });

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
    if (s.failure) |err| return err;
    var ip: usize = 0;
    var op: usize = 0;
    while (true) switch (s.phase) {
        .done => return .{ .in_len = ip, .out_len = op, .status = .done },
        .drain => {
            // The block's output not handed out yet, inside the window.
            aegis.assert.invariant(s.pending <= s.pending_end, "s.pending <= s.pending_end");
            aegis.assert.invariant(s.pending_end <= s.window.len, "s.pending_end <= s.window.len");
            const left = s.window[s.pending..s.pending_end];
            const n = @min(out.len - op, left.len);
            @memcpy(out[op..][0..n], left[0..n]);
            s.pending += n;
            op += n;
            if (s.pending != s.pending_end) return .{ .in_len = ip, .out_len = op, .status = .output_full };
            if (!s.block.last) {
                s.next(.drain, .block, 3);
            } else if (s.header.checksum) {
                s.next(.drain, .checksum, 4);
            } else s.go(.drain, .end);
        },
        .frame_end => {
            if (s.header.content_size) |size| if (s.produced != size) return s.fail(error.InvalidStream, s.frame_at, .content_size);
            s.frames += 1;
            if (s.options.frames == .one) {
                s.go(.frame_end, .last);
                return .{ .in_len = ip, .out_len = op, .status = .done };
            }
            s.next(.frame_end, .more, if (s.options.format == .standard) 5 else 1);
            return .{ .in_len = ip, .out_len = op, .status = .frame_end };
        },
        .skip => {
            const n = @min(in.len - ip, s.skip);
            ip += n;
            s.offset += n;
            s.skip -= @intCast(n);
            if (s.skip == 0) s.next(.skip, .read, if (s.options.format == .standard) 5 else 1) else return .{ .in_len = ip, .out_len = op, .status = .need_input };
        },
        .header, .block_header, .payload, .checksum => {
            // A unit is gathered up to what it wants, no further.
            aegis.assert.invariant(s.have <= s.wanted, "s.have <= s.wanted");
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
                    s.go(.checksum, .read);
                },
                else => unreachable,
            }
        },
    };
}

/// Declare end of input after draining output. Refuses every unfinished
/// frame, including a skippable frame or a partial checksum.
pub fn finish(s: *Decompress) Error!void {
    if (s.failure) |err| return err;
    if (s.phase == .done or (s.phase == .header and s.have == 0 and (s.frames != 0 or s.options.frames == .all))) return;
    return s.fail(error.Truncated, s.offset, .truncated);
}

/// The one place the phase changes: along a declared edge.
fn go(s: *Decompress, comptime from: Phase, comptime on: Event) void {
    s.phase = comptime Machine.after(from, on);
}

/// Take the edge, and start a unit of `wanted` bytes.
fn next(s: *Decompress, comptime from: Phase, comptime on: Event, wanted: usize) void {
    s.go(from, on);
    s.have = 0;
    s.wanted = wanted;
}

/// Refuse the stream: every later call returns `err`.
fn fail(s: *Decompress, err: Error, at: u64, reason: Diagnostic.Reason) Error {
    s.failure = err;
    if (s.options.diagnostic) |d| d.* = .{ .offset = .fromRaw(at), .reason = reason };
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
        return s.fail(err, s.offset -| s.have +| fault.offset, if (s.frames > 0 and fault.reason == .bad_magic) .trailing_data else fault.reason);
    };
    switch (parsed) {
        .skippable => |h| {
            if (h.len > std.math.maxInt(u32) - 8) return s.fail(error.InvalidStream, s.offset - s.have, .bad_magic);
            s.skip = h.len;
            s.go(.header, .skippable);
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
            s.next(.header, .zstd, 3);
        },
    }
}

fn readBlockHeader(s: *Decompress) Error!void {
    s.block_at = s.offset - 3;
    s.block = frame.blockHeader(s.buffer[0..3]) orelse return s.fail(error.InvalidStream, s.block_at, .bad_block_type);
    if (s.block.regenerated > s.header.blockMax()) return s.fail(error.InvalidStream, s.block_at, .block_too_large);
    s.next(.block_header, .read, s.block.size);
}

fn readBlock(s: *Decompress) Error!void {
    // The history earlier blocks left, inside the window.
    aegis.assert.invariant(s.history <= s.window.len, "s.history <= s.window.len");
    const written = s.window[0..s.history];
    // What of it the frame's window keeps, moved to the front.
    const keep: usize = @min(written.len, s.header.window_size);
    if (keep < written.len) {
        @memmove(written[0..keep], written[written.len - keep ..]);
        s.dictionary = &.{};
    }
    const block_max = s.header.blockMax();
    const end = keep + block_max;
    // readHeader took the frame only with its window and one block inside the window.
    aegis.assert.invariant(end <= s.window.len, "end <= s.window.len");
    // Where this block's output goes, after the history.
    const block = s.window[keep..end];
    var f: decode_.Frame = .{ .tables = &s.tables, .entropy = s.entropy, .out = s.window[0..end], .start = 0, .dict = s.dictionary, .block_max = block_max };
    const len: usize = switch (s.block.kind) {
        .raw => blk: {
            // readBlockHeader refused a block that regenerates more than a block, and a raw
            // block's payload is what it regenerates.
            aegis.assert.invariant(s.have <= block.len, "s.have <= block.len");
            @memcpy(block[0..s.have], s.buffer[0..s.have]);
            break :blk s.have;
        },
        .rle => blk: {
            aegis.assert.invariant(s.block.regenerated <= block.len, "s.block.regenerated <= block.len");
            @memset(block[0..s.block.regenerated], s.buffer[0]);
            break :blk s.block.regenerated;
        },
        .compressed => f.block(s.buffer[0..s.have], keep) catch |err| {
            if (err == error.OutputTooSmall) return s.fail(error.InvalidStream, s.block_at, .block_too_large);
            return s.fail(err, s.block_at +| 3 +| f.fault.offset, f.fault.reason);
        },
    };
    // A block writes inside its own part of the window.
    aegis.assert.invariant(len <= block.len, "len <= block.len");
    s.entropy = f.entropy;
    if (s.header.checksum and s.options.verify_checksum) s.hash.update(block[0..len]);
    // What the frame produced, compared with its declared content size.
    s.produced = std.math.add(u64, s.produced, len) catch return s.fail(error.InvalidStream, s.frame_at, .content_size);
    s.history = keep + len;
    s.pending = keep;
    s.pending_end = keep + len;
    s.go(.payload, .read);
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
