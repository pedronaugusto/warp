//! The encoder's commands and histograms: an insert-and-copy command as the
//! reference encoder keeps it (insert length, copy length with the delta a
//! dictionary word's length code needs, the distance prefix and extra bits
//! as if NPOSTFIX and NDIRECT were 0 until they are chosen), its prefix
//! codes, and histograms over the three alphabets.

const std = @import("std");

pub const short_distance_codes = 16;
pub const literal_symbols = 256;
pub const command_symbols = 704;
/// Distance symbols a histogram holds: the large window's at NPOSTFIX 0,
/// NDIRECT 0, as the reference counts them.
pub const distance_symbols = 544;
pub const literal_context_bits = 6;
pub const distance_context_bits = 2;
pub const block_length_symbols = 26;
pub const max_block_types = 256;
pub const block_type_symbols = max_block_types + 2;

pub const insert_base = [24]u32{ 0, 1, 2, 3, 4, 5, 6, 8, 10, 14, 18, 26, 34, 50, 66, 98, 130, 194, 322, 578, 1090, 2114, 6210, 22594 };
pub const insert_extra = [24]u32{ 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 12, 14, 24 };
pub const copy_base = [24]u32{ 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 18, 22, 30, 38, 54, 70, 102, 134, 198, 326, 582, 1094, 2118 };
pub const copy_extra = [24]u32{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24 };

pub inline fn log2Floor(n: usize) u32 {
    std.debug.assert(n != 0);
    return @intCast(std.math.log2_int(usize, n));
}

pub fn insertCode(len: usize) u16 {
    if (len < 6) return @intCast(len);
    if (len < 130) {
        const nbits = log2Floor(len - 2) - 1;
        return @intCast((nbits << 1) + ((len - 2) >> @intCast(nbits)) + 2);
    }
    if (len < 2114) return @intCast(log2Floor(len - 66) + 10);
    if (len < 6210) return 21;
    if (len < 22594) return 22;
    return 23;
}

pub fn copyCode(len: usize) u16 {
    if (len < 10) return @intCast(len - 2);
    if (len < 134) {
        const nbits = log2Floor(len - 6) - 1;
        return @intCast((nbits << 1) + ((len - 6) >> @intCast(nbits)) + 4);
    }
    if (len < 2118) return @intCast(log2Floor(len - 70) + 12);
    return 23;
}

pub fn combineCodes(ins: u16, copy: u16, use_last_distance: bool) u16 {
    const bits64: u16 = (copy & 7) | ((ins & 7) << 3);
    if (use_last_distance and ins < 8 and copy < 16) {
        return if (copy < 8) bits64 else bits64 | 64;
    }
    var offset: u32 = 2 * ((copy >> 3) + 3 * (ins >> 3));
    offset = (offset << 5) + 0x40 + ((@as(u32, 0x520D40) >> @intCast(offset)) & 0xC0);
    return @intCast(offset | bits64);
}

pub fn lengthCode(insert_len: usize, copy_len: usize, use_last_distance: bool) u16 {
    return combineCodes(insertCode(insert_len), copyCode(copy_len), use_last_distance);
}

pub const DistanceParams = struct {
    postfix_bits: u32 = 0,
    direct_codes: u32 = 0,
    alphabet_size_max: u32,
    alphabet_size_limit: u32,
    max_distance: usize,
};

/// A distance code's prefix symbol (low 10 bits) with its extra-bit count
/// (high 6), and the extra bits.
pub const DistancePrefix = struct { prefix: u16, extra: u32 };

/// The distance alphabet and reach for NPOSTFIX and NDIRECT, the
/// reference's `BrotliInitDistanceParams`.
pub fn initDistanceParams(npostfix: u32, ndirect: u32, large_window: bool) DistanceParams {
    const max_distance_bits = 24;
    const large_max_distance_bits = 62;
    var p: DistanceParams = .{
        .postfix_bits = npostfix,
        .direct_codes = ndirect,
        .alphabet_size_max = short_distance_codes + ndirect + (@as(u32, max_distance_bits) << @intCast(npostfix + 1)),
        .alphabet_size_limit = undefined,
        .max_distance = ndirect + (@as(usize, 1) << @intCast(max_distance_bits + npostfix + 2)) - (@as(usize, 1) << @intCast(npostfix + 2)),
    };
    p.alphabet_size_limit = p.alphabet_size_max;
    if (large_window) {
        const limit = distanceCodeLimit(0x7ffffffc, npostfix, ndirect);
        p.alphabet_size_max = short_distance_codes + ndirect + (@as(u32, large_max_distance_bits) << @intCast(npostfix + 1));
        p.alphabet_size_limit = limit.alphabet;
        p.max_distance = limit.distance;
    }
    return p;
}

/// The symbols, and the distance they reach, below `max_distance`.
fn distanceCodeLimit(max_distance: u32, npostfix: u32, ndirect: u32) struct { alphabet: u32, distance: u32 } {
    if (max_distance <= ndirect) return .{ .alphabet = max_distance + short_distance_codes, .distance = max_distance };
    const p: u5 = @intCast(npostfix);
    var offset = max_distance + 1 - ndirect - 1;
    const postfix = (@as(u32, 1) << p) - 1;
    offset = (offset >> p) + 4;
    var ndistbits: u32 = 0;
    var tmp = offset / 2;
    while (tmp != 0) : (tmp >>= 1) ndistbits += 1;
    ndistbits -= 1;
    const half = (offset >> @intCast(ndistbits)) & 1;
    var group = ((ndistbits - 1) << 1) | half;
    if (group == 0) return .{ .alphabet = ndirect + short_distance_codes, .distance = ndirect };
    group -= 1;
    ndistbits = (group >> 1) + 1;
    const extra = (@as(u32, 1) << @intCast(ndistbits)) - 1;
    var start = (@as(u32, 1) << @intCast(ndistbits + 1)) - 4;
    start += (group & 1) << @intCast(ndistbits);
    return .{
        .alphabet = ((group << p) | postfix) + ndirect + short_distance_codes + 1,
        .distance = ((start + extra) << p) + postfix + ndirect + 1,
    };
}

pub fn prefixEncodeDistance(code: usize, direct_codes: usize, postfix_bits: u5) DistancePrefix {
    if (code < short_distance_codes + direct_codes) return .{ .prefix = @intCast(code), .extra = 0 };
    const dist = (@as(usize, 1) << (postfix_bits + 2)) + (code - short_distance_codes - direct_codes);
    const bucket = log2Floor(dist) - 1;
    const postfix_mask = (@as(usize, 1) << postfix_bits) - 1;
    const postfix = dist & postfix_mask;
    const prefix = (dist >> @intCast(bucket)) & 1;
    const offset = (2 + prefix) << @intCast(bucket);
    const nbits = bucket - postfix_bits;
    return .{
        .prefix = @intCast((nbits << 10) | (short_distance_codes + direct_codes + ((2 * (nbits - 1) + prefix) << postfix_bits) + postfix)),
        .extra = @intCast((dist - offset) >> postfix_bits),
    };
}

pub const Command = struct {
    insert_len: u32,
    /// Copy length in the low 25 bits, the length code's delta from it in
    /// the high 7.
    copy_len: u32,
    dist_extra: u32,
    cmd_prefix: u16,
    /// The distance symbol in the low 10 bits, its extra-bit count above.
    dist_prefix: u16,

    /// `distance_code` 0 repeats the last distance, 16 is distance 1.
    pub fn init(dist: *const DistanceParams, insert_len: usize, copy_len: usize, copy_code_delta: i32, distance_code: usize) Command {
        const delta: u32 = @as(u8, @bitCast(@as(i8, @intCast(copy_code_delta))));
        const d = prefixEncodeDistance(distance_code, dist.direct_codes, @intCast(dist.postfix_bits));
        return .{
            .insert_len = @intCast(insert_len),
            .copy_len = @intCast(copy_len | delta << 25),
            .dist_extra = d.extra,
            .dist_prefix = d.prefix,
            .cmd_prefix = lengthCode(insert_len, @intCast(@as(isize, @intCast(copy_len)) + copy_code_delta), d.prefix & 0x3ff == 0),
        };
    }

    pub fn insertOnly(insert_len: usize) Command {
        return .{
            .insert_len = @intCast(insert_len),
            .copy_len = 4 << 25,
            .dist_extra = 0,
            .dist_prefix = short_distance_codes,
            .cmd_prefix = lengthCode(insert_len, 4, false),
        };
    }

    pub inline fn copyLen(c: Command) u32 {
        return c.copy_len & 0x1ffffff;
    }

    pub inline fn copyLenCode(c: Command) u32 {
        const modifier = c.copy_len >> 25;
        const delta: i32 = @as(i8, @bitCast(@as(u8, @truncate(modifier | ((modifier & 0x40) << 1)))));
        return @intCast(@as(i32, @intCast(c.copy_len & 0x1ffffff)) + delta);
    }

    pub fn restoreDistanceCode(c: Command, dist: *const DistanceParams) u32 {
        const dcode: u32 = c.dist_prefix & 0x3ff;
        if (dcode < short_distance_codes + dist.direct_codes) return dcode;
        const nbits: u5 = @intCast(c.dist_prefix >> 10);
        const postfix: u5 = @intCast(dist.postfix_bits);
        const postfix_mask = (@as(u32, 1) << postfix) - 1;
        const hcode = (dcode - dist.direct_codes - short_distance_codes) >> postfix;
        const lcode = (dcode - dist.direct_codes - short_distance_codes) & postfix_mask;
        const offset = ((2 + (hcode & 1)) << nbits) - 4;
        return ((offset + c.dist_extra) << postfix) + lcode + dist.direct_codes + short_distance_codes;
    }

    pub fn distanceContext(c: Command) u32 {
        const r = c.cmd_prefix >> 6;
        const col = c.cmd_prefix & 7;
        if ((r == 0 or r == 2 or r == 4 or r == 7) and col <= 2) return col;
        return 3;
    }
};

pub fn Histogram(comptime size: usize) type {
    return struct {
        const Self = @This();
        pub const symbols = size;
        data: [size]u32,
        total: usize,
        bit_cost: f64,

        pub const empty: Self = .{ .data = @splat(0), .total = 0, .bit_cost = std.math.inf(f64) };

        pub inline fn add(h: *Self, v: usize) void {
            h.data[v] += 1;
            h.total += 1;
        }

        pub fn addVector(h: *Self, comptime T: type, p: []const T) void {
            h.total += p.len;
            for (p) |v| h.data[v] += 1;
        }

        pub fn addHistogram(h: *Self, v: *const Self) void {
            h.total += v.total;
            for (&h.data, v.data) |*a, b| a.* += b;
        }
    };
}

pub const LiteralHistogram = Histogram(literal_symbols);
pub const CommandHistogram = Histogram(command_symbols);
pub const DistanceHistogram = Histogram(distance_symbols);

test "a command's codes round-trip through the decoder's tables" {
    const codes = @import("codes.zig");
    const dist: DistanceParams = .{ .alphabet_size_max = 64, .alphabet_size_limit = 64, .max_distance = 1 << 24 };
    for ([_][2]usize{ .{ 0, 2 }, .{ 5, 9 }, .{ 130, 133 }, .{ 2113, 2117 }, .{ 22594, 3000 }, .{ 1 << 20, 1 << 20 } }) |ic| {
        const c: Command = .init(&dist, ic[0], ic[1], 0, 16 + 1000);
        const entry = codes.commands[c.cmd_prefix];
        try std.testing.expect(ic[0] >= entry.insert_offset and ic[0] - entry.insert_offset < @as(u64, 1) << entry.insert_extra);
        try std.testing.expect(ic[1] >= entry.copy_offset and ic[1] - entry.copy_offset < @as(u64, 1) << entry.copy_extra);
        try std.testing.expectEqual(16 + 1000, c.restoreDistanceCode(&dist));
    }
}
