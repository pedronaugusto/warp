//! Brotli's bit reader: bits taken least significant first, bytes in order.
//!
//! One reader serves both of the engine's modes; each read says which at
//! comptime. Fast reads load eight bytes at once without a bound check and
//! run only while `margin` bytes of input remain past the reader (the
//! engine checks that once per unit). Careful reads load byte by byte and
//! fail with `error.NeedInput` when the input ends first; the unit that
//! made them then rolls back to its `Mark` and is read again with more
//! input, or the stream is truncated.

const std = @import("std");

pub const NeedInput = error{NeedInput};

/// Input bytes a unit may read in fast mode: the largest unit (a block
/// switch and a command, 117 bits) plus the eight-byte load past it.
pub const margin = 32;

pub const Reader = struct {
    in: []const u8,
    /// Bits of the stream before `in[0]`, for offsets.
    base: u64 = 0,
    /// The next byte to load.
    pos: usize = 0,
    /// Loaded bits, the next one lowest. Bits above `count` are zero or
    /// the stream's own next bits (a fast load leaves part of a byte there).
    buf: u64 = 0,
    count: u32 = 0,

    pub const Mark = struct { pos: usize, buf: u64, count: u32 };

    pub inline fn mark(r: *const Reader) Mark {
        return .{ .pos = r.pos, .buf = r.buf, .count = r.count };
    }

    pub inline fn restore(r: *Reader, m: Mark) void {
        r.pos = m.pos;
        r.buf = m.buf;
        r.count = m.count;
    }

    /// The bit the reader is at, counted from the stream's first.
    pub inline fn bitOffset(r: *const Reader) u64 {
        return r.base + @as(u64, r.pos) * 8 - r.count;
    }

    /// Whether a fast unit may run: `margin` bytes past `pos`.
    pub inline fn roomy(r: *const Reader) bool {
        return r.in.len - r.pos >= margin;
    }

    /// At least `n` (≤ 56) bits loaded. Careful mode loads what the input
    /// has and fails if that is short.
    pub inline fn fill(r: *Reader, comptime careful: bool, n: u32) NeedInput!void {
        if (r.count >= n) return;
        if (!careful) {
            r.buf |= std.mem.readInt(u64, r.in[r.pos..][0..8], .little) << @intCast(r.count);
            r.pos += (63 - r.count) >> 3;
            r.count |= 56;
            return;
        }
        r.fillAvailable(n);
        if (r.count < n) return error.NeedInput;
    }

    /// Load bytes until `n` bits are loaded or the input ends.
    pub inline fn fillAvailable(r: *Reader, n: u32) void {
        while (r.count < n and r.pos < r.in.len) {
            r.buf |= @as(u64, r.in[r.pos]) << @intCast(r.count);
            r.pos += 1;
            r.count += 8;
        }
    }

    /// The next `n` (< 64) loaded bits, not taken.
    pub inline fn peek(r: *const Reader, n: u32) u64 {
        return r.buf & ((@as(u64, 1) << @intCast(n)) - 1);
    }

    pub inline fn drop(r: *Reader, n: u32) void {
        r.buf >>= @intCast(n);
        r.count -= n;
    }

    /// Take `n` (≤ 56) bits.
    pub inline fn bits(r: *Reader, comptime careful: bool, n: u32) NeedInput!u32 {
        try r.fill(careful, n);
        const v: u32 = @intCast(r.peek(n));
        r.drop(n);
        return v;
    }

    /// Take the bits up to the next byte boundary; whether they are zero.
    pub fn alignByte(r: *Reader) bool {
        const pad = r.count & 7;
        const zero = r.peek(pad) == 0;
        r.drop(pad);
        return zero;
    }

    /// Give back the whole bytes loaded and not taken, at a byte boundary,
    /// so `in[pos..]` is the next input byte.
    pub fn unload(r: *Reader) void {
        std.debug.assert(r.count & 7 == 0);
        r.pos -= r.count >> 3;
        r.buf = 0;
        r.count = 0;
    }
};

test "fast and careful reads agree, and careful reads stop at the end" {
    const in = [_]u8{ 0b1010_1100, 0xff, 0x01, 0x80 } ++ @as([32]u8, @splat(0));
    var fast: Reader = .{ .in = &in };
    var careful: Reader = .{ .in = in[0..4] };
    for ([_]u32{ 3, 5, 9, 1, 13 }) |n| {
        try std.testing.expectEqual(try fast.bits(false, n), try careful.bits(true, n));
    }
    try std.testing.expectEqual(31, careful.bitOffset());
    try std.testing.expectError(error.NeedInput, careful.bits(true, 2));
    try std.testing.expectEqual(1, try careful.bits(true, 1));
}
