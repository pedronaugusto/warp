//! The bit writer every encoder writes through: DEFLATE packs fields from
//! the least significant bit of each byte. Bits gather in a 64-bit
//! register and leave eight bytes at a time with one unaligned store; the
//! store may run up to seven bytes past the bits it holds, so the output
//! keeps eight bytes of room at its end.
//!
//! An output that runs out stops taking bytes and says so (`overflow`);
//! the bytes written up to there are not a stream.

const std = @import("std");

pub const Writer = struct {
    out: []u8,
    /// The next whole byte to write.
    at: usize = 0,
    bitbuf: u64 = 0,
    /// Bits in `bitbuf`, below 64.
    count: u6 = 0,
    /// The output ran out.
    overflow: bool = false,

    pub fn init(out: []u8, at: usize) Writer {
        return .{ .out = out, .at = at };
    }

    /// Add `n` bits (at most 32 when the buffer may hold 32 already; the
    /// caller flushes between groups so that `count + n` stays below 64).
    pub inline fn add(w: *Writer, bits: u64, n: u6) void {
        w.bitbuf |= bits << w.count;
        w.count += n;
    }

    /// Write the whole bytes held.
    pub inline fn flush(w: *Writer) void {
        if (w.out.len - w.at >= 8) {
            std.mem.writeInt(u64, w.out[w.at..][0..8], w.bitbuf, .little);
        } else return w.flushNearEnd();
        const bytes = w.count >> 3;
        w.at += bytes;
        w.bitbuf >>= bytes << 3;
        w.count &= 7;
    }

    /// `flush` within eight bytes of the end: a byte at a time.
    fn flushNearEnd(w: *Writer) void {
        while (w.count >= 8) {
            if (w.at == w.out.len) {
                w.overflow = true;
                w.count = 0;
                w.bitbuf = 0;
                return;
            }
            w.out[w.at] = @truncate(w.bitbuf);
            w.at += 1;
            w.bitbuf >>= 8;
            w.count -= 8;
        }
    }

    /// Pad to the next byte boundary with zero bits and write everything.
    pub fn alignToByte(w: *Writer) void {
        w.count = (w.count + 7) & ~@as(u6, 7);
        w.flush();
    }

    /// Bytes as they are, at a byte boundary.
    pub fn writeBytes(w: *Writer, bytes: []const u8) void {
        std.debug.assert(w.count == 0);
        if (w.out.len - w.at < bytes.len) {
            w.overflow = true;
            return;
        }
        @memcpy(w.out[w.at..][0..bytes.len], bytes);
        w.at += bytes.len;
    }

    /// Bits written so far, from the start of the output.
    pub fn bitPosition(w: *const Writer) u64 {
        return @as(u64, w.at) * 8 + w.count;
    }
};

test "fields come out least significant bit first, across bytes" {
    var out: [16]u8 = undefined;
    var w: Writer = .init(&out, 0);
    w.add(1, 1);
    w.add(1, 2); // BTYPE 01
    w.add(0b0110000, 7); // 'A' would be 8 bits; here 7 bits of a code
    w.flush();
    w.add(0xabc, 12);
    w.alignToByte();
    try std.testing.expectEqual(@as(usize, 3), w.at);
    try std.testing.expectEqualSlices(u8, &.{ 0b1000_0011, 0b1111_0001, 0b0010_1010 }, out[0..3]);
    try std.testing.expect(!w.overflow);
}

test "an output that runs out says so and writes no further" {
    var out: [3]u8 = undefined;
    var w: Writer = .init(&out, 0);
    w.add(0xffff_ffff, 32);
    w.flush();
    try std.testing.expect(w.overflow);
    try std.testing.expectEqual(@as(usize, 3), w.at);
}
