//! bzip2's bits, most significant first: a 64-bit buffer whose valid bits
//! sit at the top, refilled eight bytes at a time while eight remain and a
//! byte at a time after.

const std = @import("std");

pub const NeedInput = error{NeedInput};

pub const Reader = struct {
    in: []const u8,
    /// The next byte to load.
    pos: usize = 0,
    /// Valid bits at the top; below them, bits of bytes not yet counted
    /// (each where its byte will be counted) or zeros.
    buf: u64 = 0,
    /// Valid bits.
    n: u32 = 0,
    /// The bit offset of `in[0]` in the whole input.
    base: u64 = 0,

    pub const Mark = struct { pos: usize, buf: u64, n: u32 };

    /// A reader of `in`, from bit `skip` of its first byte.
    pub fn init(in: []const u8, base: u64, skip: u3) Reader {
        var r: Reader = .{ .in = in, .base = base };
        if (skip != 0 and in.len != 0) {
            r.buf = (@as(u64, in[0]) << 56) << skip;
            r.n = 8 - @as(u32, skip);
            r.pos = 1;
        }
        return r;
    }

    pub inline fn mark(r: *const Reader) Mark {
        return .{ .pos = r.pos, .buf = r.buf, .n = r.n };
    }

    pub inline fn restore(r: *Reader, m: Mark) void {
        r.pos = m.pos;
        r.buf = m.buf;
        r.n = m.n;
    }

    /// Bits consumed, from the start of the whole input.
    pub inline fn bitOffset(r: *const Reader) u64 {
        return r.base + 8 * @as(u64, r.pos) - r.n;
    }

    /// Bytes left to load: the fast loops run while there are this many.
    pub inline fn left(r: *const Reader) usize {
        return r.in.len - r.pos;
    }

    /// At least 56 valid bits, or every byte loaded.
    pub inline fn refill(r: *Reader) void {
        if (r.in.len - r.pos >= 8) {
            r.buf |= std.mem.readInt(u64, r.in[r.pos..][0..8], .big) >> @intCast(r.n);
            r.pos += (63 - r.n) >> 3;
            r.n |= 56;
            return;
        }
        while (r.n <= 56 and r.pos < r.in.len) : (r.pos += 1) {
            r.buf |= @as(u64, r.in[r.pos]) << @intCast(56 - r.n);
            r.n += 8;
        }
    }

    /// `k` (1-32) bits valid, or `NeedInput`.
    pub inline fn need(r: *Reader, k: u32) NeedInput!void {
        if (r.n < k) {
            r.refill();
            if (r.n < k) return error.NeedInput;
        }
    }

    /// The next `k` (1-32) bits; valid ones only after `need(k)`.
    pub inline fn peek(r: *const Reader, k: u32) u32 {
        return @intCast(r.buf >> @intCast(64 - k));
    }

    pub inline fn drop(r: *Reader, k: u32) void {
        r.buf <<= @intCast(k);
        r.n -= k;
    }

    /// The next `k` (1-32) bits.
    pub inline fn bits(r: *Reader, k: u32) NeedInput!u32 {
        try r.need(k);
        const v = r.peek(k);
        r.drop(k);
        return v;
    }

    /// The bits to the next byte boundary.
    pub inline fn alignByte(r: *Reader) void {
        r.drop(r.n & 7);
    }
};

test "bits come most significant first, across refills and from a bit inside the first byte" {
    const in = [_]u8{ 0b1011_0010, 0xff, 0x00, 0x5a, 1, 2, 3, 4, 5, 6, 7, 8 };
    var r: Reader = .{ .in = &in };
    try std.testing.expectEqual(@as(u32, 0b101), try r.bits(3));
    try std.testing.expectEqual(@as(u32, 0b1_0010_1111), try r.bits(9));
    try std.testing.expectEqual(@as(u32, 0xf00), try r.bits(12));
    try std.testing.expectEqual(@as(u64, 24), r.bitOffset());
    var s: Reader = .init(&in, 0, 3);
    try std.testing.expectEqual(@as(u32, 0b10010), try s.bits(5));
    try std.testing.expectEqual(@as(u64, 8), s.bitOffset());
    var t: Reader = .{ .in = in[0..2] };
    try std.testing.expectError(error.NeedInput, t.bits(17));
}
