//! The three codes a sequence is written in: literal lengths, match
//! lengths and offsets. Each code stands for a base value and a number of
//! extra bits read after it (RFC 8878 3.1.1.3.2.1), and each has a default
//! distribution for blocks that do not send their own table.

const std = @import("std");

pub const max_ll = 35;
pub const max_ml = 52;
pub const max_of = 31;

/// Largest table logs a block may send.
pub const max_ll_log = 9;
pub const max_ml_log = 9;
pub const max_of_log = 8;

pub const min_match = 3;

pub const ll_base = [max_ll + 1]u32{
    0,    1,     2,     3,     4,  5,  6,  7,  8,  9,  10,  11,  12,  13,   14,   15,
    16,   18,    20,    22,    24, 28, 32, 40, 48, 64, 128, 256, 512, 1024, 2048, 4096,
    8192, 16384, 32768, 65536,
};
pub const ll_bits = [max_ll + 1]u8{
    0,  0,  0,  0,  0, 0, 0, 0, 0, 0, 0, 0, 0, 0,  0,  0,
    1,  1,  1,  1,  2, 2, 3, 3, 4, 6, 7, 8, 9, 10, 11, 12,
    13, 14, 15, 16,
};

pub const ml_base = [max_ml + 1]u32{
    3,    4,    5,     6,     7,     8,  9,  10, 11, 12, 13, 14,  15,  16,  17,   18,
    19,   20,   21,    22,    23,    24, 25, 26, 27, 28, 29, 30,  31,  32,  33,   34,
    35,   37,   39,    41,    43,    47, 51, 59, 67, 83, 99, 131, 259, 515, 1027, 2051,
    4099, 8195, 16387, 32771, 65539,
};
pub const ml_bits = [max_ml + 1]u8{
    0,  0,  0,  0,  0,  0, 0, 0, 0, 0, 0, 0, 0, 0, 0,  0,
    0,  0,  0,  0,  0,  0, 0, 0, 0, 0, 0, 0, 0, 0, 0,  0,
    1,  1,  1,  1,  2,  2, 3, 3, 4, 4, 5, 7, 8, 9, 10, 11,
    12, 13, 14, 15, 16,
};

/// An offset code `c` stands for an offset value of `2^c` plus `c` extra
/// bits; values 1-3 are repeat offsets and the rest are offsets plus 3.
/// The base kept here is the value minus 3 for codes of 2 bits or more
/// (the offset itself), and the value for codes 0 and 1 (repeats).
pub const of_base = blk: {
    var t: [max_of + 1]u32 = undefined;
    t[0] = 0;
    t[1] = 1;
    for (2..max_of + 1) |c| t[c] = (@as(u32, 1) << c) - 3;
    break :blk t;
};
pub const of_bits = blk: {
    var t: [max_of + 1]u8 = undefined;
    for (&t, 0..) |*b, c| b.* = c;
    break :blk t;
};

pub const ll_default_log = 6;
pub const ml_default_log = 6;
pub const of_default_log = 5;

pub const ll_default = [_]i16{
    4,  3,  2,  2,  2, 2, 2, 2, 2, 2, 2, 2, 2, 1, 1, 1,
    2,  2,  2,  2,  2, 2, 2, 2, 2, 3, 2, 1, 1, 1, 1, 1,
    -1, -1, -1, -1,
};
pub const ml_default = [_]i16{
    1,  4,  3,  2,  2,  2, 2, 2, 2, 1, 1, 1, 1, 1, 1,  1,
    1,  1,  1,  1,  1,  1, 1, 1, 1, 1, 1, 1, 1, 1, 1,  1,
    1,  1,  1,  1,  1,  1, 1, 1, 1, 1, 1, 1, 1, 1, -1, -1,
    -1, -1, -1, -1, -1,
};
pub const of_default = [_]i16{
    1, 1, 1, 1, 1, 1, 2, 2, 2,  1,  1,  1,  1,  1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, -1, -1, -1, -1, -1,
};

/// The literal-length code of `len`.
pub inline fn llCode(len: u32) u8 {
    const table = comptime blk: {
        @setEvalBranchQuota(10_000);
        var t: [64]u8 = undefined;
        for (&t, 0..) |*c, l| c.* = codeOf(&ll_base, l);
        break :blk t;
    };
    if (len < 64) return table[len];
    // Above 63 every code covers a power-of-two range: 64 is code 25.
    return @as(u8, std.math.log2_int(u32, len)) + 19;
}

/// The match-length code of a match of `len` bytes (`len >= 3`).
pub inline fn mlCode(len: u32) u8 {
    const table = comptime blk: {
        @setEvalBranchQuota(20_000);
        var t: [128]u8 = undefined;
        for (&t, 0..) |*c, v| c.* = codeOf(&ml_base, v + 3);
        break :blk t;
    };
    const v = len - 3;
    if (v < 128) return table[v];
    // From 131 (value 128) on, each code covers a power of two: 131 is 43.
    return @as(u8, std.math.log2_int(u32, v)) + 36;
}

/// The offset code of an offset value (offset + 3, or 1-3 for a repeat).
pub inline fn ofCode(value: u32) u8 {
    return @intCast(std.math.log2_int(u32, value));
}

fn codeOf(base: []const u32, v: usize) u8 {
    var c: usize = 0;
    while (c + 1 < base.len and base[c + 1] <= v) c += 1;
    return @intCast(c);
}

test "each length maps to the code whose range holds it" {
    for (0..1 << 17) |l| {
        const c = llCode(@intCast(l));
        try std.testing.expect(ll_base[c] <= l);
        try std.testing.expect(l < ll_base[c] + (@as(u64, 1) << @intCast(ll_bits[c])));
    }
    for (3..(1 << 17) + 3) |l| {
        const c = mlCode(@intCast(l));
        try std.testing.expect(ml_base[c] <= l);
        try std.testing.expect(l < ml_base[c] + (@as(u64, 1) << @intCast(ml_bits[c])));
    }
    for (1..100_000) |v| {
        const c = ofCode(@intCast(v));
        try std.testing.expect((@as(u64, 1) << @intCast(c)) <= v and v < (@as(u64, 2) << @intCast(c)));
    }
}
