//! Adaptive fractional bit prices for the optimal parsers. Frequencies
//! follow committed sequences, and are scaled between blocks.
const std = @import("std");
const codes = @import("../codes.zig");

pub const Model = struct {
    lit: [256]u32 = undefined,
    ll: [codes.max_ll + 1]u32 = undefined,
    ml: [codes.max_ml + 1]u32 = undefined,
    of: [codes.max_of + 1]u32 = undefined,
    sums: [4]u32 = .{ 0, 0, 0, 0 },
    bases: [4]u32 = undefined,
    predefined: bool = false,

    pub fn reset(m: *Model) void {
        m.sums = .{ 0, 0, 0, 0 };
    }

    pub fn begin(m: *Model, comptime accurate: bool, in: []const u8) void {
        m.predefined = in.len <= 8 and m.sums[1] == 0;
        if (m.sums[1] == 0) {
            @memset(&m.lit, 0);
            for (in) |b| m.lit[b] += 1;
            m.sums[0] = downscale(&m.lit, 8, false);
            @memset(&m.ll, 1);
            m.ll[0] = 4;
            m.ll[1] = 2;
            m.sums[1] = codes.max_ll + 1 + 4;
            @memset(&m.ml, 1);
            m.sums[2] = codes.max_ml + 1;
            m.of = .{ 6, 2, 1, 1, 2, 3, 4, 4, 4, 3, 2, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1 };
            m.sums[3] = sum(&m.of);
        } else {
            m.sums = .{ scale(&m.lit, 12), scale(&m.ll, 11), scale(&m.ml, 11), scale(&m.of, 11) };
        }
        m.updateBases(accurate);
    }

    pub fn updateBases(m: *Model, comptime accurate: bool) void {
        for (m.sums, &m.bases) |s, *b| b.* = weight(accurate, s);
    }

    pub inline fn literal(m: *const Model, comptime accurate: bool, b: u8) i32 {
        if (m.predefined) return 6 * 256;
        return @intCast(m.bases[0] - @min(weight(accurate, m.lit[b]), m.bases[0] - 256));
    }

    pub inline fn literalLength(m: *const Model, comptime accurate: bool, len: u32) i32 {
        if (m.predefined) return @intCast(weight(accurate, len));
        const full = len == 128 << 10;
        const code = codes.llCode(len - @intFromBool(full));
        return @intCast(@as(u32, codes.ll_bits[code]) * 256 + m.bases[1] - weight(accurate, m.ll[code]) + @as(u32, @intFromBool(full)) * 256);
    }

    pub inline fn increment(m: *const Model, comptime accurate: bool, len: u32) i32 {
        return m.literalLength(accurate, len) - m.literalLength(accurate, len - 1);
    }

    pub inline fn match(m: *const Model, comptime accurate: bool, off: u32, len: u32) i32 {
        const code = codes.ofCode(off);
        if (m.predefined) return @intCast(weight(accurate, len - 3) + (@as(u32, code) + 16) * 256);
        var cost = @as(u32, code) * 256 + m.bases[3] - weight(accurate, m.of[code]);
        if (!accurate and code >= 20) cost += (@as(u32, code) - 19) * 512;
        const ml = codes.mlCode(len);
        cost += @as(u32, codes.ml_bits[ml]) * 256 + m.bases[2] - weight(accurate, m.ml[ml]);
        return @intCast(cost + 256 / 5);
    }

    pub fn update(m: *Model, lits: []const u8, off: u32, len: u32) void {
        for (lits) |b| m.lit[b] += 2;
        m.sums[0] += @intCast(lits.len * 2);
        m.ll[codes.llCode(@intCast(lits.len))] += 1;
        m.ml[codes.mlCode(len)] += 1;
        m.of[codes.ofCode(off)] += 1;
        for (m.sums[1..]) |*s| s.* += 1;
    }
};

inline fn weight(comptime accurate: bool, raw: u32) u32 {
    const stat = raw + 1;
    const hb = std.math.log2_int(u32, stat);
    return @as(u32, hb) * 256 + if (accurate) (stat << 8) >> hb else @as(u32, 0);
}

fn sum(table: []const u32) u32 {
    var total: u32 = 0;
    for (table) |n| total += n;
    return total;
}

fn downscale(table: []u32, shift: u5, all: bool) u32 {
    var total: u32 = 0;
    for (table) |*n| {
        n.* = @intFromBool(all or n.* > 0) + (n.* >> shift);
        total += n.*;
    }
    return total;
}

fn scale(table: []u32, log: u5) u32 {
    const total = sum(table);
    const factor = total >> log;
    if (factor <= 1) return total;
    return downscale(table, std.math.log2_int(u32, factor), true);
}
