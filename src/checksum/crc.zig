//! What every reflected 32-bit CRC shares, for its polynomial: the
//! slicing-by-8 kernel any CPU runs, combining two CRCs in time
//! logarithmic in the second length, and the bitwise reference the tests
//! hold every kernel to.

const std = @import("std");

/// The CRC with reflected polynomial `polynomial` (bit 31 is x^0).
pub fn Crc(comptime polynomial: u32) type {
    return struct {
        /// Eight tables of 256 entries: the CRC of a byte followed by 0 to
        /// 7 zero bytes.
        pub const tables = blk: {
            @setEvalBranchQuota(100_000);
            var t: [8][256]u32 = undefined;
            for (0..256) |i| {
                var c: u32 = i;
                for (0..8) |_| c = if (c & 1 != 0) (c >> 1) ^ polynomial else c >> 1;
                t[0][i] = c;
            }
            for (0..256) |i| {
                for (1..8) |k| t[k][i] = (t[k - 1][i] >> 8) ^ t[0][t[k - 1][i] & 0xff];
            }
            break :blk t;
        };

        /// The register `start` continued over `bytes`, eight bytes at a
        /// time from the eight tables.
        pub fn slicing8(start: u32, bytes: []const u8) u32 {
            var c = start;
            var rest = bytes;
            while (rest.len >= 8) {
                const lo = std.mem.readInt(u32, rest[0..4], .little) ^ c;
                const hi = std.mem.readInt(u32, rest[4..8], .little);
                c = tables[7][lo & 0xff] ^ tables[6][(lo >> 8) & 0xff] ^ tables[5][(lo >> 16) & 0xff] ^ tables[4][lo >> 24] ^
                    tables[3][hi & 0xff] ^ tables[2][(hi >> 8) & 0xff] ^ tables[1][(hi >> 16) & 0xff] ^ tables[0][hi >> 24];
                rest = rest[8..];
            }
            for (rest) |b| c = (c >> 8) ^ tables[0][(c ^ b) & 0xff];
            return c;
        }

        /// The CRC of A ++ B from `crc_a`, `crc_b` and the length of B.
        pub fn combine(crc_a: u32, crc_b: u32, len_b: u64) u32 {
            return multiplyModP(xPow8nModP(len_b), crc_a) ^ crc_b;
        }

        /// a·b mod P, both reflected.
        pub fn multiplyModP(a: u32, b: u32) u32 {
            if (a == 0) return 0;
            var m: u32 = 1 << 31;
            var p: u32 = 0;
            var bb = b;
            while (true) {
                if (a & m != 0) {
                    p ^= bb;
                    if (a & (m - 1) == 0) break;
                }
                m >>= 1;
                bb = if (bb & 1 != 0) (bb >> 1) ^ polynomial else bb >> 1;
            }
            return p;
        }

        /// x^(2^k) mod P for k = 0..63: squarings, for `xPow8nModP`.
        const x2n_table = blk: {
            @setEvalBranchQuota(1_000_000);
            var t: [64]u32 = undefined;
            var p: u32 = 1 << 30; // x^1
            for (&t) |*e| {
                e.* = p;
                p = multiplyModP(p, p);
            }
            break :blk t;
        };

        /// x^(8n) mod P.
        pub fn xPow8nModP(n: u64) u32 {
            var p: u32 = 1 << 31; // x^0
            var k: usize = 3;
            var rest = n;
            while (rest != 0) : (rest >>= 1) {
                if (rest & 1 != 0) p = multiplyModP(x2n_table[k & 63], p);
                k += 1;
            }
            return p;
        }

        /// The CRC one bit at a time, as the polynomial defines it.
        pub fn bitwise(start: u32, bytes: []const u8) u32 {
            var c = start;
            for (bytes) |b| {
                c ^= b;
                for (0..8) |_| c = if (c & 1 != 0) (c >> 1) ^ polynomial else c >> 1;
            }
            return c;
        }
    };
}

/// A folding kernel `fold` over the bulk of `bytes` (when there are
/// `min_len`), the lane it returns and the rest finished by `scalar`.
pub inline fn folded(comptime min_len: usize, comptime scalar: fn (u32, []const u8) u32, comptime fold: anytype, reg: u32, bytes: []const u8) u32 {
    if (bytes.len < min_len) return scalar(reg, bytes);
    const f = fold(reg, bytes);
    var lane: [16]u8 = undefined;
    std.mem.writeInt(u128, &lane, f.lane, .little);
    return scalar(scalar(0, &lane), bytes[f.used..]);
}

test "combining joins two pieces, and is associative" {
    // The CRC-32 polynomial; crc32.zig and crc32c.zig test their own values.
    const C = Crc(0xedb88320);
    var buf: [1024]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @truncate(i *% 7919 >> 3);
    for ([_]usize{ 0, 1, 100, 1023, 1024 }) |cut| {
        const a = ~C.slicing8(~@as(u32, 0), buf[0..cut]);
        const b = ~C.slicing8(~@as(u32, 0), buf[cut..]);
        try std.testing.expectEqual(~C.slicing8(~@as(u32, 0), &buf), C.combine(a, b, buf.len - cut));
    }
    try std.testing.expectEqual(C.combine(C.combine(1, 2, 5), 3, 7), C.combine(1, C.combine(2, 3, 7), 12));
}
