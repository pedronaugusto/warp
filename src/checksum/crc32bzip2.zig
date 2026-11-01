//! bzip2's CRC-32: the polynomial 0x04c11db7 most significant bit first
//! (`CRC-32/BZIP2`), the check of each bzip2 block's output. Slicing-by-8:
//! eight bytes a step through eight tables, as the reflected CRCs' portable
//! kernel.

const std = @import("std");

/// The polynomial, most significant bit first.
pub const polynomial: u32 = 0x04c11db7;

/// The tables: `tables[0]` is the byte-at-a-time table, `tables[k]` a byte
/// `k` places further from the end.
const tables: [8][256]u32 = blk: {
    @setEvalBranchQuota(20_000);
    var t: [8][256]u32 = undefined;
    for (0..256) |i| {
        var c: u32 = @as(u32, i) << 24;
        for (0..8) |_| c = if (c & 0x8000_0000 != 0) (c << 1) ^ polynomial else c << 1;
        t[0][i] = c;
    }
    for (1..8) |k| {
        for (0..256) |i| t[k][i] = (t[k - 1][i] << 8) ^ t[0][t[k - 1][i] >> 24];
    }
    break :blk t;
};

/// A running bzip2 CRC-32.
pub const Crc32Bzip2 = struct {
    /// The CRC of what was given so far.
    value: u32 = 0,

    pub const init: Crc32Bzip2 = .{};

    pub fn update(c: *Crc32Bzip2, bytes: []const u8) void {
        c.value = crc32Bzip2(c.value, bytes);
    }

    pub fn final(c: Crc32Bzip2) u32 {
        return c.value;
    }

    /// The bzip2 CRC-32 of `bytes`.
    pub fn hash(bytes: []const u8) u32 {
        return crc32Bzip2(0, bytes);
    }
};

/// `crc` continued over `bytes`; 0 starts a CRC.
pub fn crc32Bzip2(crc: u32, bytes: []const u8) u32 {
    return ~slicing8(~crc, bytes);
}

/// The register `reg` (not inverted) continued over `bytes`.
pub fn slicing8(reg: u32, bytes: []const u8) u32 {
    var c = reg;
    var rest = bytes;
    while (rest.len >= 8) {
        const hi = c ^ std.mem.readInt(u32, rest[0..4], .big);
        const lo = std.mem.readInt(u32, rest[4..8], .big);
        c = tables[7][hi >> 24] ^ tables[6][(hi >> 16) & 0xff] ^ tables[5][(hi >> 8) & 0xff] ^ tables[4][hi & 0xff] ^
            tables[3][lo >> 24] ^ tables[2][(lo >> 16) & 0xff] ^ tables[1][(lo >> 8) & 0xff] ^ tables[0][lo & 0xff];
        rest = rest[8..];
    }
    for (rest) |b| c = (c << 8) ^ tables[0][(c >> 24) ^ b];
    return c;
}

/// A bit at a time, the definition.
pub fn bitwise(reg: u32, bytes: []const u8) u32 {
    var c = reg;
    for (bytes) |b| {
        c ^= @as(u32, b) << 24;
        for (0..8) |_| c = if (c & 0x8000_0000 != 0) (c << 1) ^ polynomial else c << 1;
    }
    return c;
}

test "the check value, and slicing-by-8 as the definition at every length and start" {
    try std.testing.expectEqual(@as(u32, 0xfc891918), Crc32Bzip2.hash("123456789"));
    var bytes: [300]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(5);
    prng.random().bytes(&bytes);
    for (0..bytes.len) |len| for ([_]usize{ 0, 1, 7 }) |start| {
        if (start > len) continue;
        try std.testing.expectEqual(bitwise(0x1234_5678, bytes[start..len]), slicing8(0x1234_5678, bytes[start..len]));
    };
    var c: Crc32Bzip2 = .init;
    c.update(bytes[0..100]);
    c.update(bytes[100..]);
    try std.testing.expectEqual(Crc32Bzip2.hash(&bytes), c.final());
}
