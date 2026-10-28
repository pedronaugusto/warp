//! The format's fixed codes: block counts, insert-and-copy commands and
//! distances (RFC 7932 §4, §5, §6), as comptime tables.

const std = @import("std");
const aegis = @import("aegis");

/// A prefix code's symbol stands for `offset` plus `extra` bits.
pub const Range = struct { offset: u32, extra: u5 };

/// The 26 block count symbols.
pub const block_counts = blk: {
    const extra = [26]u5{ 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 7, 8, 9, 10, 11, 12, 13, 24 };
    var r: [26]Range = undefined;
    var offset: u32 = 1;
    for (&r, extra) |*x, e| {
        x.* = .{ .offset = offset, .extra = e };
        offset += @as(u32, 1) << e;
    }
    break :blk r;
};

const insert_extra = [24]u5{ 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 12, 14, 24 };
const copy_extra = [24]u5{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24 };

/// What an insert-and-copy symbol says, packed for the command loop.
pub const Command = packed struct(u64) {
    insert_offset: u16,
    copy_offset: u16,
    insert_extra: u5,
    copy_extra: u5,
    /// Symbols below 128 reuse the last distance and read none.
    implicit_distance: bool,
    /// The distance's context: the copy length's, 0-3.
    distance_context: u2,
    _: u19 = 0,
};

/// The 704 insert-and-copy symbols.
pub const commands = blk: {
    @setEvalBranchQuota(20000);
    var insert_offsets: [24]u16 = undefined;
    var copy_offsets: [24]u16 = undefined;
    insert_offsets[0] = 0;
    copy_offsets[0] = 2;
    for (0..23) |i| {
        insert_offsets[i + 1] = insert_offsets[i] + (1 << insert_extra[i]);
        copy_offsets[i + 1] = copy_offsets[i] + (1 << copy_extra[i]);
    }
    // Each block of 64 symbols: the first insert code and the first copy
    // code it covers, as eighths.
    const cells = [11][2]u8{ .{ 0, 0 }, .{ 0, 1 }, .{ 0, 0 }, .{ 0, 1 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 2 }, .{ 2, 0 }, .{ 1, 2 }, .{ 2, 1 }, .{ 2, 2 } };
    var t: [704]Command = undefined;
    for (&t, 0..) |*c, symbol| {
        const cell = cells[symbol >> 6];
        const insert_code = cell[0] * 8 + ((symbol >> 3) & 7);
        const copy_code = cell[1] * 8 + (symbol & 7);
        const copy_offset = copy_offsets[copy_code];
        c.* = .{
            .insert_offset = insert_offsets[insert_code],
            .copy_offset = copy_offset,
            .insert_extra = insert_extra[insert_code],
            .copy_extra = copy_extra[copy_code],
            .implicit_distance = symbol < 128,
            .distance_context = if (copy_offset > 4) 3 else copy_offset - 2,
        };
    }
    break :blk t;
};

pub const short_distance_codes = 16;
pub const max_ndirect = 120;
pub const max_npostfix = 3;
/// Extra bits of a distance in an RFC 7932 stream, and in a large-window one.
pub const max_distance_bits = 24;
pub const large_max_distance_bits = 62;
/// The largest distance a stream may use (2^31 - 4): past it, refused.
pub const max_allowed_distance = 0x7ffffffc;

/// The distance alphabet's size for the stream's parameters; for a
/// large-window stream, the symbols a simple code's widths count (`max`)
/// and the ones it may use (`limit`), the format reference's rule.
pub fn distanceAlphabet(npostfix: u2, ndirect: u7, large_window: bool) struct { max: u32, limit: u32 } {
    // At most 62 << 4: 10 bits.
    const shift = @as(u4, npostfix) + 1;
    if (!large_window) {
        const n = short_distance_codes + @as(u32, ndirect) + (@as(u10, max_distance_bits) << shift);
        return .{ .max = n, .limit = n };
    }
    return .{ .max = short_distance_codes + @as(u32, ndirect) + (@as(u10, large_max_distance_bits) << shift), .limit = largeLimit(npostfix, ndirect) };
}

/// The distance symbols a large-window stream may use: complete groups of
/// 2^NPOSTFIX symbols whose distances stay within `max_allowed_distance`.
fn largeLimit(npostfix: u2, ndirect: u7) u32 {
    const max_distance: u32 = max_allowed_distance;
    // The largest distance less NDIRECT (at most 127, which bounds the
    // second part): 31 bits.
    const less = (max_distance - 127) + (127 - @as(u32, ndirect));
    const reduced: u31 = @truncate(less >> npostfix);
    const offset = @as(u32, reduced) + 4;
    const postfix = ~(~@as(u4, 0) << npostfix);
    // The bits of `offset / 2` (at least 2), less one: at most 30.
    const ndistbits: u5 = @intCast(31 - @as(u32, @clz(offset / 2)));
    const half: u1 = @truncate(offset >> ndistbits);
    var group = (@as(u6, ndistbits - 1) << 1) | half;
    if (group == 0) return @as(u32, ndirect) + short_distance_codes;
    group -= 1;
    // At most 59 << 3: 10 bits.
    const symbol = (@as(u10, group) << npostfix) | postfix;
    return @as(u32, symbol) + ndirect + short_distance_codes + 1;
}

/// The largest distance alphabet any stream can have, for table sizes.
pub const max_distance_limit = blk: {
    @setEvalBranchQuota(100000);
    var m: u32 = 0;
    for (0..max_npostfix + 1) |p| {
        var d: u32 = 0;
        while (d <= 15) : (d += 1) {
            const a = distanceAlphabet(@intCast(p), @intCast(d << p), true);
            m = @max(m, a.limit, distanceAlphabet(@intCast(p), @intCast(d << p), false).limit);
        }
    }
    break :blk m;
};

/// A distance symbol at or past `16 + NDIRECT` stands for `offset` plus
/// `extra` bits shifted by NPOSTFIX.
pub fn distanceRange(symbol: u32, npostfix: u2, ndirect: u7) Range {
    const direct = short_distance_codes + @as(u32, ndirect);
    if (symbol < direct) return .{ .offset = symbol - short_distance_codes + 1, .extra = 0 };
    const x = symbol - direct;
    // Shifted by at least one: 31 bits.
    const ndistbits = @as(u32, @as(u31, @truncate(x >> (@as(u5, npostfix) + 1)))) + 1;
    const half: u1 = @truncate(x >> npostfix);
    const postfix = x & ~(~@as(u32, 0) << npostfix);
    // The limit keeps a symbol's extra bits to five bits' count.
    aegis.assert.invariant(ndistbits <= 31, "ndistbits <= 31");
    // Large-window offsets past 2^32 cannot be reached within the limit.
    const scaled = (@as(u64, 2) + half) << @intCast(ndistbits);
    aegis.assert.invariant(scaled >= 4, "scaled >= 4");
    const start: u64 = scaled - 4;
    // Kept to 32 bits, as the reference keeps it: the sum wraps where it would pass them.
    return .{ .offset = @truncate((start << npostfix) +% postfix +% ndirect +% 1), .extra = @intCast(ndistbits) };
}

test "commands match RFC 7932's table" {
    // 0: insert 0, copy 2, last distance.
    try std.testing.expectEqual(Command{ .insert_offset = 0, .copy_offset = 2, .insert_extra = 0, .copy_extra = 0, .implicit_distance = true, .distance_context = 0 }, commands[0]);
    // 703: insert code 23, copy code 23.
    try std.testing.expectEqual(22594, commands[703].insert_offset);
    try std.testing.expectEqual(2118, commands[703].copy_offset);
    try std.testing.expectEqual(24, commands[703].insert_extra);
    try std.testing.expect(!commands[703].implicit_distance);
    // 448: insert code 16, copy code 0.
    try std.testing.expectEqual(130, commands[448].insert_offset);
    try std.testing.expectEqual(2, commands[448].copy_offset);
    try std.testing.expectEqual(16625, block_counts[25].offset);
}

test "distances: direct codes, then ranges" {
    try std.testing.expectEqual(Range{ .offset = 1, .extra = 0 }, distanceRange(16, 0, 4));
    // NPOSTFIX 0, NDIRECT 0: symbol 16 is distances 1-2, 17 is 3-4.
    try std.testing.expectEqual(Range{ .offset = 1, .extra = 1 }, distanceRange(16, 0, 0));
    try std.testing.expectEqual(Range{ .offset = 3, .extra = 1 }, distanceRange(17, 0, 0));
    try std.testing.expectEqual(Range{ .offset = 5, .extra = 2 }, distanceRange(18, 0, 0));
    try std.testing.expectEqual(16 + 48, distanceAlphabet(0, 0, false).limit);
    try std.testing.expect(max_distance_limit < 1128);
}
