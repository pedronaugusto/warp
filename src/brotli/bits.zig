//! Brotli's bit reader: bits taken least significant first, bytes in order.
//!
//! One reader serves both of the engine's modes; each read says which at
//! comptime. Fast reads load eight bytes at once without a bound check and
//! run only while `margin` bytes of input remain past the reader (the
//! engine checks that once per unit). Careful reads load byte by byte and
//! fail with `error.NeedInput` when the input ends first; the unit that
//! made them then rolls back to its `Mark` and is read again with more
//! input, or the stream is truncated.
//!
//! The writer is the encoder's: bits put least significant first, eight
//! bytes stored at once, so its buffer keeps eight bytes past the last bit.

const std = @import("std");
const aegis = @import("aegis");

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
    /// At most 63: loads stop at 56 bits and add at most 7 more.
    count: u6 = 0,

    pub const Mark = struct { pos: usize, buf: u64, count: u6 };

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
    pub inline fn fill(r: *Reader, comptime careful: bool, n: u6) NeedInput!void {
        if (r.count >= n) return;
        if (!careful) {
            r.buf |= std.mem.readInt(u64, r.in[r.pos..][0..8], .little) << r.count;
            // `~count` is 63 less the count: the whole bytes that fit.
            r.pos += ~r.count >> 3;
            r.count |= 56;
            return;
        }
        r.fillAvailable(n);
        if (r.count < n) return error.NeedInput;
    }

    /// Load bytes until `n` bits are loaded or the input ends.
    pub inline fn fillAvailable(r: *Reader, n: u6) void {
        while (r.count < n and r.pos < r.in.len) {
            r.buf |= @as(u64, r.in[r.pos]) << r.count;
            r.pos += 1;
            r.count += 8;
        }
    }

    /// The next `n` (< 64) loaded bits, not taken.
    pub inline fn peek(r: *const Reader, n: u6) u64 {
        return r.buf & ((@as(u64, 1) << n) - 1);
    }

    pub inline fn drop(r: *Reader, n: u6) void {
        r.buf >>= n;
        r.count -= n;
    }

    /// Take `n` (≤ 56) bits.
    pub inline fn bits(r: *Reader, comptime careful: bool, n: u6) NeedInput!u32 {
        try r.fill(careful, n);
        // At most 56 bits are taken, and no caller takes more than 32.
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
        aegis.assert.invariant(r.count & 7 == 0, "r.count & 7 == 0");
        r.pos -= r.count >> 3;
        r.buf = 0;
        r.count = 0;
    }
};

pub const Writer = struct {
    buf: []u8,
    /// Bits written; the byte at `pos >> 3` holds the partial byte, and the
    /// bits above `pos` in it are zero.
    pos: usize = 0,

    /// Put the low `n` bits of `v` (no bits above them), `n <= 56`.
    pub inline fn bits(w: *Writer, n: u32, v: u64) void {
        std.debug.assert(n <= 56 and v >> @intCast(n) == 0); // aegis: no-danger: the encoder's own codewords and their lengths, written per symbol
        const at = w.pos >> 3;
        const old: u64 = w.buf[at];
        std.mem.writeInt(u64, w.buf[at..][0..8], old | v << @intCast(w.pos & 7), .little);
        w.pos += n;
    }

    /// Pad with zero bits to a byte boundary.
    pub fn alignByte(w: *Writer) void {
        w.pos = (w.pos + 7) & ~@as(usize, 7);
        w.buf[w.pos >> 3] = 0;
    }

    /// Put whole bytes at a byte boundary.
    pub fn bytes(w: *Writer, data: []const u8) void {
        aegis.assert.invariant(w.pos & 7 == 0, "w.pos & 7 == 0");
        @memcpy(w.buf[w.pos >> 3 ..][0..data.len], data);
        w.pos += data.len * 8;
        w.buf[w.pos >> 3] = 0;
    }
};

test "the writer puts what the reader takes" {
    var buf: [40]u8 = @splat(0);
    var w: Writer = .{ .buf = &buf };
    const fields = [_][2]u64{ .{ 3, 5 }, .{ 13, 0x1abc }, .{ 1, 1 }, .{ 56, 0xab_cdef_0123_4567 }, .{ 7, 0 }, .{ 9, 300 } };
    for (fields) |f| w.bits(@intCast(f[0]), f[1]);
    w.alignByte();
    w.bytes("xy");
    var r: Reader = .{ .in = &buf };
    for (fields) |f| {
        var v: u64 = 0;
        var n: u32 = 0;
        while (n < f[0]) : (n += @min(24, @as(u32, @intCast(f[0])) - n)) v |= @as(u64, try r.bits(true, @min(24, @as(u32, @intCast(f[0])) - n))) << @intCast(n);
        try std.testing.expectEqual(f[1], v);
    }
    try std.testing.expect(r.alignByte());
    try std.testing.expectEqual('x', try r.bits(true, 8));
    try std.testing.expectEqual('y', try r.bits(true, 8));
}

test "fast and careful reads agree, and careful reads stop at the end" {
    const in = [_]u8{ 0b1010_1100, 0xff, 0x01, 0x80 } ++ @as([32]u8, @splat(0));
    var fast: Reader = .{ .in = &in };
    var careful: Reader = .{ .in = in[0..4] };
    for ([_]u6{ 3, 5, 9, 1, 13 }) |n| {
        try std.testing.expectEqual(try fast.bits(false, n), try careful.bits(true, n));
    }
    try std.testing.expectEqual(31, careful.bitOffset());
    try std.testing.expectError(error.NeedInput, careful.bits(true, 2));
    try std.testing.expectEqual(1, try careful.bits(true, 1));
}
