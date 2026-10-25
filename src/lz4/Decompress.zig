//! Resumable LZ4 frame decoding: input and output in pieces of any size.
//! A block is decoded once its stored bytes are all in hand, straight from
//! the input when one call holds them, and lands in the caller's window
//! after the 64 KiB of history linked blocks reach into.
const Decompress = @This();

const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;
const block = @import("block.zig");
const frame = @import("frame.zig");
const decompress_ = @import("frames.zig");
const Diagnostic = @import("Diagnostic.zig");

pub const Options = struct {
    frames: decompress_.Frames = .all,
    verify_checksum: bool = true,
    /// What frames that name a dictionary refer back into; the last 64 KiB
    /// count. Borrowed.
    dictionary: []const u8 = &.{},
    dictionary_id: ?u32 = null,
    /// The largest block maximum accepted; it sizes the window. 8 MiB or
    /// more admits legacy frames.
    max_block_size: aegis.units.Bytes(usize) = .literal("4MiB"),
    diagnostic: ?*Diagnostic = null,
};

pub const Status = enum {
    /// Every input byte is taken and the frames go on: more input.
    need_input,
    /// The output is full and the frames go on.
    output_full,
    /// A frame ended and another may follow: the input is complete here if
    /// it ends here.
    frame_end,
    /// The frame asked for ended (`frames = .one`); input after it is not
    /// taken.
    done,
};

pub const Step = struct { in_len: usize, out_len: usize, status: Status };
pub const Error = decompress_.Error;

const history_len = 65536;

/// The bytes of window `init` needs for blocks of at most `max_block_size`:
/// the history, one decoded block, one stored block and its checksum (or
/// a legacy block, the larger, from 8 MiB).
pub fn memory(max_block_size: aegis.units.Bytes(usize)) usize {
    const b = max_block_size.raw();
    return history_len + b + stageLen(b);
}

fn stageLen(b: usize) usize {
    return if (b >= frame.legacy_block_len) @max(b + 4, frame.legacy_block_max) else b + 4;
}

const Phase = enum { header, skip, block_header, payload, drain, checksum, legacy_header, legacy_payload, done };

/// What a unit read says comes next: a frame of a kind, a block, the end
/// mark with a checksum after it, the last frame's end or another frame,
/// or a unit done.
const Event = enum { skippable, legacy, standard, block, checksum, last, more, read };

const Machine = aegis.state.Machine(Phase, Event, .{ .initial = .header, .terminal = &.{.done}, .edges = &.{
    .{ .from = .header, .on = .skippable, .to = .skip },
    .{ .from = .header, .on = .legacy, .to = .legacy_header },
    .{ .from = .header, .on = .standard, .to = .block_header },
    .{ .from = .skip, .on = .read, .to = .header },
    .{ .from = .block_header, .on = .block, .to = .payload },
    .{ .from = .block_header, .on = .checksum, .to = .checksum },
    .{ .from = .block_header, .on = .last, .to = .done },
    .{ .from = .block_header, .on = .more, .to = .header },
    .{ .from = .payload, .on = .read, .to = .drain },
    .{ .from = .drain, .on = .standard, .to = .block_header },
    .{ .from = .drain, .on = .legacy, .to = .legacy_header },
    .{ .from = .checksum, .on = .last, .to = .done },
    .{ .from = .checksum, .on = .more, .to = .header },
    .{ .from = .legacy_header, .on = .block, .to = .legacy_payload },
    .{ .from = .legacy_header, .on = .last, .to = .done },
    .{ .from = .legacy_header, .on = .more, .to = .header },
    .{ .from = .legacy_payload, .on = .read, .to = .drain },
} });

options: Options,
/// Private: the history and decoded block, then the stored block's staging.
window: []u8,
stage: []u8,
phase: Phase = .header,
/// Private: bytes gathered for the current unit, and how many it needs.
have: usize = 0,
wanted: usize = 4,
header: frame.Header = .{},
block_header: frame.BlockHeader = .{ .len = 0, .uncompressed = false },
/// Private: the input taken so far, where the frame and block started.
offset: u64 = 0,
frame_at: u64 = 0,
block_at: u64 = 0,
skip: u64 = 0,
frames: u64 = 0,
produced: u64 = 0,
/// Private: the window's history before `pending`, and the decoded bytes
/// still to hand out.
history: usize = 0,
pending: usize = 0,
pending_end: usize = 0,
/// Private: the dictionary while the frame's output is shorter than a
/// window.
dictionary: []const u8 = &.{},
hash: std.hash.XxHash32 = .init(0),
/// Private: the frame being read is a legacy one.
header_is_legacy: bool = false,
failure: ?Error = null,

/// `buffer.len >= memory(options.max_block_size)`. The value may move
/// before the first call; keep it in place while decoding.
pub fn init(buffer: []u8, options: Options) Decompress {
    std.debug.assert(buffer.len >= memory(options.max_block_size));
    const b = options.max_block_size.raw();
    return .{ .options = options, .window = buffer[0 .. history_len + b], .stage = buffer[history_len + b ..][0..stageLen(b)] };
}

pub fn reset(s: *Decompress) void {
    s.* = init(s.window.ptr[0 .. s.window.len + s.stage.len], s.options);
}

/// Take input and give output as far as each allows.
pub fn decode(s: *Decompress, in: []const u8, out: []u8) Error!Step {
    if (s.failure) |err| return err;
    var ip: usize = 0;
    var op: usize = 0;
    while (true) switch (s.phase) {
        .done => return .{ .in_len = ip, .out_len = op, .status = .done },
        .drain => {
            const n = @min(out.len - op, s.pending_end - s.pending);
            @memcpy(out[op..][0..n], s.window[s.pending..][0..n]);
            s.pending += n;
            op += n;
            if (s.pending != s.pending_end) return .{ .in_len = ip, .out_len = op, .status = .output_full };
            if (s.header_is_legacy) s.next(.drain, .legacy, 4) else s.next(.drain, .standard, 4);
        },
        .skip => {
            const n: usize = @intCast(@min(in.len - ip, s.skip));
            ip += n;
            s.offset += n;
            s.skip -= n;
            if (s.skip != 0) return .{ .in_len = ip, .out_len = op, .status = .need_input };
            s.next(.skip, .read, 4);
        },
        .payload => {
            // The whole stored block in this call's input: decoded from it.
            if (s.have == 0 and in.len - ip >= s.wanted) {
                const data = in[ip..][0..s.wanted];
                ip += s.wanted;
                s.offset += s.wanted;
                try s.readBlock(data);
                continue;
            }
            const n = @min(in.len - ip, s.wanted - s.have);
            @memcpy(s.stage[s.have..][0..n], in[ip..][0..n]);
            s.have += n;
            ip += n;
            s.offset += n;
            if (s.have != s.wanted) return .{ .in_len = ip, .out_len = op, .status = .need_input };
            try s.readBlock(s.stage[0..s.have]);
        },
        .legacy_payload => {
            if (s.have == 0 and in.len - ip >= s.wanted) {
                const data = in[ip..][0..s.wanted];
                ip += s.wanted;
                s.offset += s.wanted;
                try s.readLegacyBlock(data);
                continue;
            }
            const n = @min(in.len - ip, s.wanted - s.have);
            @memcpy(s.stage[s.have..][0..n], in[ip..][0..n]);
            s.have += n;
            ip += n;
            s.offset += n;
            if (s.have != s.wanted) return .{ .in_len = ip, .out_len = op, .status = .need_input };
            try s.readLegacyBlock(s.stage[0..s.have]);
        },
        .header, .block_header, .checksum, .legacy_header => {
            // A legacy frame ends where the input does, or at a frame.
            if (s.phase == .legacy_header and s.have == 0 and ip == in.len)
                return .{ .in_len = ip, .out_len = op, .status = .need_input };
            const n = @min(in.len - ip, s.wanted - s.have);
            @memcpy(s.stage[s.have..][0..n], in[ip..][0..n]);
            s.have += n;
            ip += n;
            s.offset += n;
            if (s.have != s.wanted) return .{ .in_len = ip, .out_len = op, .status = .need_input };
            switch (s.phase) {
                .header => {
                    if (try s.readHeader()) |status| return .{ .in_len = ip, .out_len = op, .status = status };
                },
                .block_header => {
                    if (try s.readBlockHeader()) |status| return .{ .in_len = ip, .out_len = op, .status = status };
                },
                .checksum => {
                    const want = std.mem.readInt(u32, s.stage[0..4], .little);
                    if (s.options.verify_checksum and s.hash.final() != want) return s.fail(error.ChecksumMismatch, s.offset - 4, .content_checksum);
                    return .{ .in_len = ip, .out_len = op, .status = s.endFrame(.checksum) };
                },
                .legacy_header => {
                    const len = std.mem.readInt(u32, s.stage[0..4], .little);
                    if (len <= frame.legacy_block_max) {
                        s.block_at = s.offset - 4;
                        s.next(.legacy_header, .block, len);
                        continue;
                    }
                    // Past the largest block: the next frame's magic, and
                    // the legacy frame's end.
                    s.header_is_legacy = false;
                    const status = s.endFrame(.legacy_header);
                    if (status == .done) {
                        // Left unread, as much of it as this call gave.
                        ip -= n;
                        s.offset -= n;
                    } else {
                        // The next header's first four bytes.
                        s.have = 4;
                    }
                    return .{ .in_len = ip, .out_len = op, .status = status };
                },
                else => unreachable,
            }
        },
    };
}

/// Declare the end of input after the output is drained: refuses a frame
/// that has not ended, a skippable frame cut short included.
pub fn finish(s: *Decompress) Error!void {
    if (s.failure) |err| return err;
    switch (s.phase) {
        .done => return,
        .header => if (s.frames != 0) {
            if (s.have == 0) return;
            // Bytes after a frame that end before a magic does.
            if (s.have < 4 and frame.after(s.stage[0..s.have]) == .trailing) return s.fail(error.InvalidStream, s.offset - s.have, .trailing_data);
        },
        // A legacy frame ends with the input.
        .legacy_header => if (s.have == 0) {
            s.header_is_legacy = false;
            _ = s.endFrame(.legacy_header);
            return;
        },
        else => {},
    }
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

/// A frame ended in `from`: the next, or done.
fn endFrame(s: *Decompress, comptime from: Phase) Status {
    s.frames += 1;
    if (s.options.frames == .one) {
        s.go(from, .last);
        return .done;
    }
    s.next(from, .more, 4);
    return .frame_end;
}

/// The header gathered so far: complete, or asking for more of itself.
fn readHeader(s: *Decompress) Error!?Status {
    const at = s.offset - s.have;
    if (s.have == 4 and s.frames > 0 and !frame.startsFrame(s.stage[0..4])) return s.fail(error.InvalidStream, at, .trailing_data);
    var diagnostic: Diagnostic = .{};
    const parsed = frame.parse(s.stage[0..s.have], &diagnostic, at) catch |err| switch (err) {
        error.Truncated => {
            // More of the header: its length is known from its flags.
            s.wanted = if (s.have < 7) (if (std.mem.readInt(u32, s.stage[0..4], .little) & 0xFFFF_FFF0 == frame.skippable_magic) @as(usize, 8) else 7) else headerLen(s.stage[4]);
            if (s.wanted <= s.have) return s.fail(error.InvalidStream, at, .bad_magic);
            return null;
        },
        error.InvalidStream => return s.fail(error.InvalidStream, diagnostic.offset.raw(), diagnostic.reason),
    };
    switch (parsed) {
        .skippable => |k| {
            s.skip = k.len;
            s.go(.header, .skippable);
        },
        .legacy => {
            // Its blocks need a window of 8 MiB.
            if (s.window.len - history_len < frame.legacy_block_len) return s.fail(error.InvalidStream, at, .block_too_large);
            s.frame_at = at;
            s.header_is_legacy = true;
            s.history = 0;
            s.next(.header, .legacy, 4);
        },
        .standard => |f| {
            const h = f.header;
            s.frame_at = at;
            if (h.dictionary_id) |id| {
                if (s.options.dictionary.len == 0) return s.fail(error.DictionaryMismatch, at, .dictionary_mismatch);
                if (s.options.dictionary_id) |want| if (want != id) return s.fail(error.DictionaryMismatch, at, .dictionary_mismatch);
            }
            if (aegis.units.Bytes(usize).fromRaw(h.block_size.bytes()).compare(s.options.max_block_size) == .gt) return s.fail(error.InvalidStream, at, .block_too_large);
            s.header = h;
            s.dictionary = s.options.dictionary[s.options.dictionary.len -| block.max_offset..];
            s.history = 0;
            s.produced = 0;
            s.hash = .init(0);
            s.next(.header, .standard, 4);
        },
    }
    return null;
}

/// A descriptor's length from its FLG byte.
fn headerLen(flg: u8) usize {
    return 4 + 2 + @as(usize, if (flg & (1 << 3) != 0) 8 else 0) + @as(usize, if (flg & 1 != 0) 4 else 0) + 1;
}

fn readBlockHeader(s: *Decompress) Error!?Status {
    const head = s.stage[0..4];
    if (frame.BlockHeader.isEnd(head)) {
        if (s.header.content_size) |n| if (n != s.produced) return s.fail(error.InvalidStream, s.frame_at, .content_size);
        if (s.header.content_checksum) {
            s.next(.block_header, .checksum, 4);
            return null;
        }
        return s.endFrame(.block_header);
    }
    s.block_at = s.offset - 4;
    s.block_header = frame.BlockHeader.read(head);
    if (s.block_header.len > s.header.block_size.bytes()) return s.fail(error.InvalidStream, s.block_at, .block_too_large);
    s.next(.block_header, .block, @as(usize, s.block_header.len) + @as(usize, if (s.header.block_checksum) 4 else 0));
    return null;
}

/// Where the next decoded block goes: after the history it may reach
/// into, the window moved down when a block would not fit after it.
fn place(s: *Decompress, block_max: usize, linked: bool) usize {
    if (!linked) return 0;
    if (s.window.len - s.history < block_max) {
        const keep = @min(s.history, history_len);
        @memmove(s.window[0..keep], s.window[s.history - keep ..][0..keep]);
        s.history = keep;
        // A whole window of output: the dictionary is out of reach.
        if (keep == history_len) s.dictionary = &.{};
    }
    return s.history;
}

fn readBlock(s: *Decompress, stored: []const u8) Error!void {
    const bh = s.block_header;
    const data = stored[0..bh.len];
    if (s.header.block_checksum and s.options.verify_checksum) {
        const want = std.mem.readInt(u32, stored[bh.len..][0..4], .little);
        if (std.hash.XxHash32.hash(0, data) != want) return s.fail(error.ChecksumMismatch, s.block_at, .block_checksum);
    }
    const block_max = s.header.block_size.bytes();
    const linked = !s.header.independent;
    const at = s.place(block_max, linked);
    var end: usize = undefined;
    if (bh.uncompressed) {
        @memcpy(s.window[at..][0..data.len], data);
        end = at + data.len;
    } else {
        const origin: usize = 0;
        const r = block.decode(data, s.window[origin .. at + block_max], at, .{
            .history = s.dictionary,
            .diagnostic = s.options.diagnostic,
            .in_base = s.block_at + 4,
        }) catch |err| switch (err) {
            error.OutputTooSmall => return s.fail(error.InvalidStream, s.block_at, .block_too_large),
            else => |e| {
                s.failure = e;
                return e;
            },
        };
        end = r.op;
    }
    if (s.header.content_checksum) s.hash.update(s.window[at..end]);
    s.produced += end - at;
    if (linked) s.history = end;
    s.pending = at;
    s.pending_end = end;
    s.go(.payload, .read);
}

fn readLegacyBlock(s: *Decompress, data: []const u8) Error!void {
    const r = block.decode(data, s.window[0..frame.legacy_block_len], 0, .{ .diagnostic = s.options.diagnostic, .in_base = s.block_at + 4 }) catch |err| switch (err) {
        error.OutputTooSmall => return s.fail(error.InvalidStream, s.block_at, .block_too_large),
        else => |e| {
            s.failure = e;
            return e;
        },
    };
    s.produced += r.op;
    s.pending = 0;
    s.pending_end = r.op;
    s.go(.legacy_payload, .read);
}

/// A `std.Io.Reader` over the same resumable decoder. `buffer` reserves 4
/// KiB for the reader's own buffering, then `memory(max_block_size)`.
pub const Reader = struct {
    interface: Io.Reader,
    input: *Io.Reader,
    state: Decompress,
    failure: ?Error = null,

    pub fn init(input: *Io.Reader, buffer: []u8, options: Options) Reader {
        const n = @min(buffer.len, 4096);
        return .{ .interface = .{ .vtable = &.{ .stream = stream, .readVec = readVec }, .buffer = buffer[0..n], .seek = 0, .end = 0 }, .input = input, .state = Decompress.init(buffer[n..], options) };
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
            r.input.toss(step.in_len); // aegis: no-danger: decode counts bytes of `input`, which the reader holds buffered
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
