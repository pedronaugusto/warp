//! xz's CRC-64: the ECMA-182 polynomial, reflected (`CRC-64/XZ`), the check
//! xz streams name 0x04. Slicing-by-8: eight bytes a step through eight
//! tables, as the reflected CRC-32s' portable kernel; a carry-less fold
//! kernel is Phase C's.

const std = @import("std");

/// The polynomial, reflected.
pub const polynomial: u64 = 0xc96c_5795_d787_0f42;

/// The tables: `tables[0]` is the byte-at-a-time table, `tables[k]` a byte
/// `k` places further from the end.
const tables: [8][256]u64 = blk: {
    @setEvalBranchQuota(20_000);
    var t: [8][256]u64 = undefined;
    for (0..256) |i| {
        var c: u64 = i;
        for (0..8) |_| c = if (c & 1 != 0) (c >> 1) ^ polynomial else c >> 1;
        t[0][i] = c;
    }
    for (1..8) |k| {
        for (0..256) |i| t[k][i] = (t[k - 1][i] >> 8) ^ t[0][t[k - 1][i] & 0xff];
    }
    break :blk t;
};

/// A running xz CRC-64.
pub const Crc64Xz = struct {
    /// The CRC of what was given so far.
    value: u64 = 0,

    pub const init: Crc64Xz = .{};

    pub fn update(c: *Crc64Xz, bytes: []const u8) void {
        c.value = crc64Xz(c.value, bytes);
    }

    pub fn final(c: Crc64Xz) u64 {
        return c.value;
    }

    /// The xz CRC-64 of `bytes`.
    pub fn hash(bytes: []const u8) u64 {
        return crc64Xz(0, bytes);
    }
};

/// `crc` continued over `bytes`; 0 starts a CRC.
pub fn crc64Xz(crc: u64, bytes: []const u8) u64 {
    return ~slicing8(~crc, bytes);
}

/// The register `reg` (not inverted) continued over `bytes`.
pub fn slicing8(reg: u64, bytes: []const u8) u64 {
    var c = reg;
    var rest = bytes;
    while (rest.len >= 8) {
        const v = c ^ std.mem.readInt(u64, rest[0..8], .little);
        c = tables[7][v & 0xff] ^ tables[6][(v >> 8) & 0xff] ^ tables[5][(v >> 16) & 0xff] ^ tables[4][(v >> 24) & 0xff] ^
            tables[3][(v >> 32) & 0xff] ^ tables[2][(v >> 40) & 0xff] ^ tables[1][(v >> 48) & 0xff] ^ tables[0][v >> 56];
        rest = rest[8..];
    }
    for (rest) |b| c = (c >> 8) ^ tables[0][(c ^ b) & 0xff];
    return c;
}

/// A bit at a time, the definition.
pub fn bitwise(reg: u64, bytes: []const u8) u64 {
    var c = reg;
    for (bytes) |b| {
        c ^= b;
        for (0..8) |_| c = if (c & 1 != 0) (c >> 1) ^ polynomial else c >> 1;
    }
    return c;
}

test "the check value, and slicing-by-8 as the definition at every length and start" {
    try std.testing.expectEqual(@as(u64, 0x995d_c9bb_df19_39fa), Crc64Xz.hash("123456789"));
    try std.testing.expectEqual(std.hash.crc.@"CRC-64/XZ".hash("123456789"), Crc64Xz.hash("123456789"));
    var bytes: [300]u8 = undefined;
    var prng: std.Random.DefaultPrng = .init(6);
    prng.random().bytes(&bytes);
    for (0..bytes.len) |len| for ([_]usize{ 0, 1, 7 }) |start| {
        if (start > len) continue;
        try std.testing.expectEqual(bitwise(0x1234_5678_9abc_def0, bytes[start..len]), slicing8(0x1234_5678_9abc_def0, bytes[start..len]));
    };
    var c: Crc64Xz = .init;
    c.update(bytes[0..100]);
    c.update(bytes[100..]);
    try std.testing.expectEqual(Crc64Xz.hash(&bytes), c.final());
}
