//! What every matchfinder shares: the window, the bytes searched, match
//! lengths, hashing, and moving stored positions.
//!
//! Positions count from the input's first byte; a dictionary's bytes come
//! before it, at negative positions. Tables hold positions as 16-bit
//! offsets from a base that moves 32 KiB at a time (every entry moved with
//! it, saturating at "none"), which halves their cache footprint against
//! 32-bit positions.

const std = @import("std");

pub const window = 32768;
pub const min_match = 3;
pub const max_match = 258;

/// The empty entry: older than anything in the window.
pub const none: i16 = std.math.minInt(i16);

/// What a matchfinder searches: the input, and the last bytes of a
/// dictionary before it.
pub const History = struct {
    in: []const u8,
    /// At most `window` bytes, ending just before `in`.
    dict: []const u8 = &.{},

    /// The byte at `p`, which may be in the dictionary.
    pub inline fn at(h: History, p: isize) u8 {
        return if (p >= 0) h.in[@intCast(p)] else h.dict[@intCast(@as(isize, @intCast(h.dict.len)) + p)];
    }

    /// Four bytes from `p` (`p + 4 <= in.len`), little-endian.
    pub inline fn load32(h: History, p: isize) u32 {
        if (p >= 0) return std.mem.readInt(u32, h.in[@intCast(p)..][0..4], .little);
        return h.load32Slow(p);
    }

    fn load32Slow(h: History, p: isize) u32 {
        var v: u32 = 0;
        for (0..4) |i| v |= @as(u32, h.at(p + @as(isize, @intCast(i)))) << @intCast(8 * i);
        return v;
    }

    /// `load32`, straight from the input when there is no dictionary.
    pub inline fn load32Of(h: History, comptime dictionary: bool, p: isize) u32 {
        if (!dictionary) return std.mem.readInt(u32, h.in[@intCast(p)..][0..4], .little);
        return h.load32(p);
    }

    /// `matchLength`, straight from the input when there is no dictionary.
    pub inline fn matchLengthOf(h: History, comptime dictionary: bool, cand: isize, p: isize, start: u32, max: u32) u32 {
        if (!dictionary) return matchLengthIn(h.in, @intCast(cand), @intCast(p), start, max);
        return h.matchLength(cand, p, start, max);
    }

    /// The length of the match between `cand` and `p` (`cand < p`), from
    /// `start` bytes already known equal, up to `max`.
    pub inline fn matchLength(h: History, cand: isize, p: isize, start: u32, max: u32) u32 {
        if (cand >= 0) return matchLengthIn(h.in, @intCast(cand), @intCast(p), start, max);
        return h.matchLengthSlow(cand, p, start, max);
    }

    /// A match that starts in the dictionary, possibly running into the
    /// input: a byte at a time.
    fn matchLengthSlow(h: History, cand: isize, p: isize, start: u32, max: u32) u32 {
        var len = start;
        while (len < max and h.at(cand + offset(len)) == h.at(p + offset(len))) len += 1;
        return len;
    }
};

/// The length of the match between `in[a..]` and `in[b..]` (`a < b`), from
/// `start` equal bytes, at most `max` (`b + max <= in.len`): eight bytes a
/// compare, the first difference found from the exclusive or.
pub inline fn matchLengthIn(in: []const u8, a: usize, b: usize, start: u32, max: u32) u32 {
    var len = start;
    while (len + 8 <= max) {
        const x = std.mem.readInt(u64, in[a + len ..][0..8], .little) ^ std.mem.readInt(u64, in[b + len ..][0..8], .little);
        if (x != 0) return len + @ctz(x) / 8;
        len += 8;
    }
    while (len < max and in[a + len] == in[b + len]) len += 1;
    return len;
}

/// A length as a position offset: lengths are u32, positions isize, which
/// on a 32-bit target is not wider.
pub inline fn offset(n: u32) isize {
    return @intCast(n);
}

/// Multiplicative hashing: the top `bits` bits of the product.
pub inline fn hash(word: u32, bits: u5) u32 {
    return (word *% 0x1e35a7bd) >> @intCast(@as(u6, 32) - bits);
}

/// Every entry moved back `window` positions, saturating at `none`.
pub fn rebase(table: []i16) void {
    const lanes = 16;
    const i16xn = @Vector(lanes, i16);
    const shift: i16xn = @splat(window - 1);
    var i: usize = 0;
    // `-|` saturates; an entry at `none` + anything stays `none`.
    while (i + lanes <= table.len) : (i += lanes) {
        const v: i16xn = table[i..][0..lanes].*;
        table[i..][0..lanes].* = (v -| shift) -| @as(i16xn, @splat(1));
    }
    for (table[i..]) |*e| e.* = (e.* -| (window - 1)) -| 1;
}

test "match lengths: across eight-byte steps, at the limit, and into the input from a dictionary" {
    const in = "abcdefghij-abcdefghij-abcdefghijX";
    try std.testing.expectEqual(@as(u32, 21), matchLengthIn(in, 0, 11, 0, 22));
    try std.testing.expectEqual(@as(u32, 20), matchLengthIn(in, 0, 11, 0, 20));
    try std.testing.expectEqual(@as(u32, 10), matchLengthIn(in, 0, 22, 3, 11));
    const h: History = .{ .in = "xyzxyz-tail", .dict = "abcxyz" };
    // At -3 the dictionary holds "xyz", then the input continues "xyz-".
    try std.testing.expectEqual(@as(u32, 6), h.matchLength(-3, 0, 0, 11));
    try std.testing.expectEqual(@as(u32, 'c'), h.at(-4));
    try std.testing.expectEqual(std.mem.readInt(u32, "bcxy", .little), h.load32(-5));
}

test "rebase moves entries back a window, and old ones become none" {
    var t = [_]i16{ none, -1, 0, 1, 32767, -32767, 100, 30000, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 };
    rebase(&t);
    const want = [_]i16{ none, none, none, -32767, -1, none, -32668, -2768, -32763, -32762, -32761, -32760, -32759, -32758, -32757, -32756, -32755, -32754 };
    try std.testing.expectEqualSlices(i16, &want, &t);
}
