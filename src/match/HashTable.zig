//! A hash table of two-entry buckets (level 1): the two latest positions
//! for each hash of four bytes, and nothing older; and beside it the
//! latest searched position for each hash of three bytes, for a near
//! three-byte match where no longer one is found.

const HashTable = @This();

const std = @import("std");
const match = @import("history.zig");

pub const bucket = 2;

/// Private: the latest positions per four-byte hash, newest first.
table: [][bucket]i16,
/// Private: the latest searched position per three-byte hash.
short: []i16,
/// Private: the tables' sizes in use, in bits.
bits: u5 = 0,
short_bits: u5 = 0,
/// Private: positions are stored relative to this.
base: isize = 0,
/// Private: the farthest a match reaches back.
window: u32 = match.window,

pub fn memory(bits: u5, short_bits: u5) usize {
    return (@as(usize, 1) << bits) * bucket * 2 + (@as(usize, 1) << short_bits) * 2;
}

pub fn reset(ht: *HashTable, first: isize, bits: u5, short_bits: u5) void {
    std.debug.assert(first >= -match.window);
    ht.bits = bits;
    ht.short_bits = short_bits;
    @memset(ht.table[0 .. @as(usize, 1) << bits], .{ match.none, match.none });
    @memset(ht.short[0 .. @as(usize, 1) << short_bits], match.none);
    ht.base = if (first < 0) -match.window else 0;
}

/// Moved back `n` positions: the buffer the positions index slid by `n`.
pub fn slide(ht: *HashTable, n: usize) void {
    ht.base -= @intCast(n);
}

/// Forget every position: a later match reaches none before this.
pub fn forget(ht: *HashTable) void {
    @memset(ht.table[0 .. @as(usize, 1) << ht.bits], .{ match.none, match.none });
    @memset(ht.short[0 .. @as(usize, 1) << ht.short_bits], match.none);
}

inline fn advance(ht: *HashTable, p: isize) void {
    if (p - ht.base >= match.window) {
        @branchHint(.unlikely);
        const n = @as(usize, 1) << ht.bits;
        match.rebase(std.mem.bytesAsSlice(i16, std.mem.sliceAsBytes(ht.table[0..n])));
        match.rebase(ht.short[0 .. @as(usize, 1) << ht.short_bits]);
        ht.base += match.window;
    }
}

/// The longer of the matches at the two positions with `p`'s hash, if
/// either is four bytes or more, else a three-byte match within
/// `short_reach`; at most `max_len` (`max_len >= 5`). Inserts `p`.
/// Returns the length (0 for none) and sets `distance`.
pub inline fn longestMatch(ht: *HashTable, comptime dictionary: bool, comptime full_window: bool, h: match.History, p: isize, max_len: u32, distance: *u32) u32 {
    ht.advance(p);
    const base = ht.base;
    const cur: i16 = @intCast(p - base);
    const window: i32 = if (full_window) match.window else @intCast(ht.window);
    const cutoff: i32 = @as(i32, cur) - window;
    const word = h.load32Of(false, p);
    const table = ht.table;
    const bits = ht.bits;
    const short = ht.short;
    const short_bits = ht.short_bits;
    const e = &table[match.hash(word, bits)];
    const cands = e.*;
    e.* = .{ cur, cands[0] };
    // The next position's bucket, fetched while this one is compared.
    @prefetch(&table[match.hash(h.load32Of(false, p + 1), bits)], .{ .rw = .write });
    var best: u32 = 0;
    var best_dist: u32 = 0;
    inline for (0..bucket) |i| {
        if (cands[i] > cutoff) {
            const c = base + cands[i];
            if (h.load32Of(dictionary, c) == word) {
                const len = h.matchLengthOf(dictionary, c, p, 4, max_len);
                if (len > best) {
                    best = len;
                    best_dist = @intCast(p - c);
                }
            }
        }
    }
    if (best == 0) {
        // Positions without a longer match only: where a match starts,
        // the four-byte table holds it.
        const s = &short[match.hash(word & 0xff_ffff, short_bits)];
        const cand3 = s.*;
        s.* = cur;
        if (cand3 > cutoff and cur - cand3 <= short_reach) {
            const c = base + cand3;
            if (h.load32Of(dictionary, c) & 0xff_ffff == word & 0xff_ffff) {
                best = h.matchLengthOf(dictionary, c, p, 3, max_len);
                best_dist = @intCast(p - c);
            }
        }
    }
    distance.* = best_dist;
    return best;
}

/// A three-byte match further than this costs more than its literals.
pub const short_reach = 256;

/// Insert `count` positions from `p` (`p >= 0`) without searching.
pub inline fn skip(ht: *HashTable, h: match.History, p: isize, count: u32) void {
    ht.insert(false, h, p, count);
}

/// Insert a dictionary's positions, which lie before the input.
pub fn prime(ht: *HashTable, h: match.History, p: isize, count: u32) void {
    ht.insert(true, h, p, count);
}

inline fn insert(ht: *HashTable, comptime dictionary: bool, h: match.History, p: isize, count: u32) void {
    var q = p;
    const end = p + match.offset(count);
    while (q < end) {
        ht.advance(q);
        // Up to the next window boundary, with the table in locals: no
        // store into it makes the compiler reload them.
        const base = ht.base;
        const stop = @min(end, base + match.window);
        const table = ht.table;
        const bits = ht.bits;
        while (q < stop) : (q += 1) {
            const e = &table[match.hash(h.load32Of(dictionary, q), bits)];
            // The old entry first: `e.* = .{ new, e[0] }` would write the
            // first field before reading it.
            const older = e[0];
            e.* = .{ @intCast(q - base), older };
        }
    }
}

test "both positions of a bucket are candidates, the older one too" {
    // "wxyz" at 0, 10 and 20; from 0 it runs on longer than from 10.
    const in = "wxyz12345_wxyz9999__wxyz1234567890";
    var table: [1 << 10][bucket]i16 = undefined;
    var short: [1 << 10]i16 = undefined;
    var ht: HashTable = .{ .table = &table, .short = &short };
    ht.reset(0, 10, 10);
    const h: match.History = .{ .in = in };
    ht.skip(h, 0, 20);
    var distance: u32 = 0;
    const len = ht.longestMatch(false, true, h, 20, @intCast(in.len - 20), &distance);
    try std.testing.expectEqual(@as(u32, 9), len);
    try std.testing.expectEqual(@as(u32, 20), distance);
}
