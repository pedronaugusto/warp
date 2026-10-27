//! What every matchfinder shares: the window, the bytes searched, match
//! lengths, hashing, and moving stored positions.
//!
//! Positions count from the input's first byte; a dictionary's bytes come
//! before it, at negative positions. Tables hold positions as offsets from
//! a base that moves a window at a time (every entry moved with it,
//! saturating at "none"): 16 bits over DEFLATE's 32 KiB, which halves their
//! cache footprint against 32-bit positions, and 32 over a larger window
//! (GDeflate's 64 KiB).

const std = @import("std");

/// DEFLATE's window.
pub const window = 32768;
pub const min_match = 3;
pub const max_match = 258;

/// A match: its length (3-258) and distance.
pub const Match = struct { length: u16, offset: u16 };

/// A match over a window past 64 KiB (LZMA's): its distance in 32 bits.
pub const WideMatch = struct { length: u16, offset: u32 };

/// The match a finder over a window of `window_` bytes gives.
pub fn MatchFor(comptime window_: u32) type {
    return if (window_ <= 65536) Match else WideMatch;
}

/// The most matches one search finds: one per length.
pub const max_matches = max_match - min_match + 1;

/// A stored position over a window of `window_` bytes.
pub fn Position(comptime window_: u32) type {
    return if (window_ <= 32768) i16 else i32;
}

/// The empty entry: older than anything in the window.
pub fn none(comptime P: type) P {
    return std.math.minInt(P);
}

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

/// Every entry moved back `window_` positions, saturating at `none`.
pub fn rebase(comptime window_: u32, table: []Position(window_)) void {
    const P = Position(window_);
    const lanes = 16;
    const Pxn = @Vector(lanes, P);
    // In two steps: `window_ - 1` and one, each a value of the entry type.
    const shift: Pxn = @splat(window_ - 1);
    var i: usize = 0;
    // `-|` saturates; an entry at `none` + anything stays `none`.
    while (i + lanes <= table.len) : (i += lanes) {
        const v: Pxn = table[i..][0..lanes].*;
        table[i..][0..lanes].* = (v -| shift) -| @as(Pxn, @splat(1));
    }
    for (table[i..]) |*e| e.* = (e.* -| @as(P, window_ - 1)) -| 1;
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
    const n = none(i16);
    var t = [_]i16{ n, -1, 0, 1, 32767, -32767, 100, 30000, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14 };
    rebase(window, &t);
    const want = [_]i16{ n, n, n, -32767, -1, n, -32668, -2768, -32763, -32762, -32761, -32760, -32759, -32758, -32757, -32756, -32755, -32754 };
    try std.testing.expectEqualSlices(i16, &want, &t);
    // Over 64 KiB, in 32 bits.
    const n32 = none(i32);
    var w = [_]i32{ n32, -1, 0, 1, 65535, 65536, 100_000 };
    rebase(65536, &w);
    try std.testing.expectEqualSlices(i32, &.{ n32, -65537, -65536, -65535, -1, 0, 34464 }, &w);
}
