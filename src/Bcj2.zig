//! BCJ2: 7-Zip's x86 branch converter of four streams, decoded as a
//! `std.Io.Reader` over them. The main stream holds the code with every
//! call (E8), jump (E9) and conditional jump (0F 8x) opcode in place; a
//! range-coded bit after each says whether its target was moved out, and a
//! moved target comes back from the call or the jump stream, big-endian
//! and absolute, made relative to the byte after it again. Read as 7-Zip
//! 9.20's `Bcj2_Decode` and libarchive's reader read it: one bit model per
//! byte before an E8, one for E9 and one for the conditional jumps.

const Bcj2 = @This();

const std = @import("std");
const Io = std.Io;

pub const Error = error{
    /// The call, jump or range-coded stream ended before a value the main
    /// stream asks of it.
    Truncated,
};

/// The four streams in 7z's order (the coder's in-streams 0 to 3).
pub const Streams = struct {
    main: *Io.Reader,
    call: *Io.Reader,
    jump: *Io.Reader,
    range: *Io.Reader,
};

const top: u32 = 1 << 24;
const model_bits = 11;
const model_total: u16 = 1 << model_bits;
const move_bits = 5;

interface: Io.Reader,
streams: Streams,
/// The decoded length when the folder declares it: the output stops
/// there, as 7-Zip's does, before a bit the last opcode would ask for.
left: ?u64,
/// Bit models: one per byte before an E8, then E9's, then the
/// conditional jumps'.
models: [256 + 2]u16 = @splat(model_total >> 1),
range: u32 = 0xffff_ffff,
code: u32 = 0,
/// The range coder's first five bytes have been read.
started: bool = false,
/// The byte before the next one in the output, which with it makes an
/// opcode.
prev: u8 = 0,
/// Bytes given so far, the position a moved target is relative to; it
/// wraps as 7-Zip's 32-bit position does.
pos: u32 = 0,
/// A target's bytes not given yet.
pending: [4]u8 = undefined,
pending_at: u8 = 4,
failure: ?Error = null,

/// Decode `streams`; `buffer` is the reader's own buffering, and `size`
/// the decoded length where it is known.
pub fn init(streams: Streams, buffer: []u8, size: ?u64) Bcj2 {
    return .{
        .interface = .{ .vtable = &.{ .stream = stream, .readVec = readVec }, .buffer = buffer, .seek = 0, .end = 0 },
        .streams = streams,
        .left = size,
    };
}

/// The error behind an `error.ReadFailed`, when it was the streams' own.
pub fn err(r: *const Bcj2) ?Error {
    return r.failure;
}

fn fail(r: *Bcj2, e: Error) error{ReadFailed} {
    r.failure = e;
    return error.ReadFailed;
}

/// A byte of `from`; the end of it is `Truncated`.
fn byteOf(r: *Bcj2, from: *Io.Reader) Io.Reader.Error!u8 {
    return from.takeByte() catch |e| switch (e) {
        error.EndOfStream => r.fail(error.Truncated),
        error.ReadFailed => error.ReadFailed,
    };
}

fn bit(r: *Bcj2, model: *u16) Io.Reader.Error!bool {
    const bound = (r.range >> model_bits) * model.*;
    var one = false;
    if (r.code < bound) {
        r.range = bound;
        model.* += (model_total - model.*) >> move_bits;
    } else {
        r.range -= bound;
        r.code -= bound;
        model.* -= model.* >> move_bits;
        one = true;
    }
    if (r.range < top) {
        r.range <<= 8;
        r.code = (r.code << 8) | try r.byteOf(r.streams.range);
    }
    return one;
}

fn isJump(prev: u8, b: u8) bool {
    return b & 0xfe == 0xe8 or (prev == 0x0f and b & 0xf0 == 0x80);
}

fn readInto(r: *Bcj2, out: []u8) Io.Reader.Error!usize {
    if (r.failure != null) return error.ReadFailed;
    if (out.len == 0) return 0;
    if (!r.started) {
        for (0..5) |_| r.code = (r.code << 8) | try r.byteOf(r.streams.range);
        r.started = true;
    }
    const room = if (r.left) |left| @min(out.len, left) else out.len;
    var n: usize = 0;
    while (n < room) {
        if (r.pending_at < 4) {
            out[n] = r.pending[r.pending_at];
            r.pending_at += 1;
            n += 1;
            r.pos +%= 1;
            continue;
        }
        const b = r.streams.main.takeByte() catch |e| switch (e) {
            error.EndOfStream => break,
            error.ReadFailed => return error.ReadFailed,
        };
        out[n] = b;
        n += 1;
        r.pos +%= 1;
        if (!isJump(r.prev, b)) {
            r.prev = b;
            continue;
        }
        // The output ends at this opcode: 7-Zip reads no bit for it.
        if (r.left) |left| if (n == left) break;
        const model = &r.models[if (b == 0xe8) r.prev else if (b == 0xe9) 256 else 257];
        if (!try r.bit(model)) {
            r.prev = b;
            continue;
        }
        const from = if (b == 0xe8) r.streams.call else r.streams.jump;
        var target: [4]u8 = undefined;
        for (&target) |*t| t.* = try r.byteOf(from);
        const dest = std.mem.readInt(u32, &target, .big) -% (r.pos +% 4);
        std.mem.writeInt(u32, &r.pending, dest, .little);
        r.pending_at = 0;
        r.prev = @truncate(dest >> 24);
    }
    if (r.left) |*left| left.* -= n;
    if (n == 0) return error.EndOfStream;
    return n;
}

fn stream(interface: *Io.Reader, writer: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
    const r: *Bcj2 = @alignCast(@fieldParentPtr("interface", interface));
    _ = writer;
    if (limit == .nothing) return 0;
    const n = try r.readInto(limit.slice(interface.buffer));
    interface.seek = 0;
    interface.end = n;
    return 0;
}

fn readVec(interface: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
    const r: *Bcj2 = @alignCast(@fieldParentPtr("interface", interface));
    if (data[0].len != 0) return r.readInto(data[0]);
    const n = try r.readInto(interface.buffer[interface.end..]);
    interface.end += n;
    return 0;
}

const testing = std.testing;

test "code with no jumps is the main stream as it is" {
    var main: Io.Reader = .fixed("plain bytes, no opcode");
    var none: Io.Reader = .fixed("");
    var range: Io.Reader = .fixed("\x00\x00\x00\x00\x00");
    var buffer: [16]u8 = undefined;
    var r: Bcj2 = .init(.{ .main = &main, .call = &none, .jump = &none, .range = &range }, &buffer, null);
    var out: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&out);
    _ = try r.interface.streamRemaining(&w);
    try testing.expectEqualStrings("plain bytes, no opcode", w.buffered());
}

test "a range coder shorter than its first five bytes is truncated" {
    var main: Io.Reader = .fixed("x");
    var none: Io.Reader = .fixed("");
    var range: Io.Reader = .fixed("\x00\x00");
    var buffer: [16]u8 = undefined;
    var r: Bcj2 = .init(.{ .main = &main, .call = &none, .jump = &none, .range = &range }, &buffer, null);
    var out: [4]u8 = undefined;
    try testing.expectError(error.ReadFailed, r.interface.readSliceShort(&out));
    try testing.expectEqual(@as(?Error, error.Truncated), r.err());
}
