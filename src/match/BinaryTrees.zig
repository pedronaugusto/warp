//! Binary trees (levels 10-12): for each hash of four bytes, the window's
//! positions with that hash in a binary search tree ordered by the bytes
//! that follow them, rooted at the newest. A search walks down from the
//! root, meets every match longer than the last it found, and re-roots the
//! tree at the position searched; so it finds more matches in fewer steps
//! than chains do, and a position is inserted only by searching it. Beside
//! the trees, the two latest positions per hash of three bytes give
//! three-byte matches.
//!
//! The near-optimal parser searches almost every position and wants every
//! match length, which is what the trees give.

const BinaryTrees = @This();

const std = @import("std");
const match = @import("history.zig");

/// A match: its length (3-258) and distance.
pub const Match = struct { length: u16, offset: u16 };

/// The most matches one search finds: one per length.
pub const max_matches = match.max_match - match.min_match + 1;

/// A search needs this many bytes from its position.
pub const required = 4;

/// Private: the two latest positions per three-byte hash, newest first.
hash3: [][2]i16,
/// Private: each tree's root per four-byte hash.
hash4: []i16,
/// Private: each position's two children (smaller, larger), by position
/// modulo the window.
child: []i16,
hash3_bits: u5 = 0,
hash4_bits: u5 = 0,
/// Private: positions are stored relative to this.
base: isize = 0,
/// Private: the farthest a match reaches back.
window: u32 = match.window,

/// The memory for tables of `hash3_bits` and `hash4_bits` over a window of
/// `window` bytes.
pub fn memory(hash3_bits: u5, hash4_bits: u5, window: usize) usize {
    return (@as(usize, 1) << hash3_bits) * 4 + (@as(usize, 1) << hash4_bits) * 2 + window * 4;
}

/// Start over for a stream that begins at `first` (negative with a
/// dictionary), with tables of `hash3_bits` and `hash4_bits`.
pub fn reset(bt: *BinaryTrees, first: isize, hash3_bits: u5, hash4_bits: u5) void {
    std.debug.assert(first >= -match.window);
    bt.hash3_bits = hash3_bits;
    bt.hash4_bits = hash4_bits;
    @memset(bt.hash3[0 .. @as(usize, 1) << hash3_bits], .{ match.none, match.none });
    @memset(bt.hash4[0 .. @as(usize, 1) << hash4_bits], match.none);
    bt.base = if (first < 0) -match.window else 0;
}

/// Moved back `n` positions: the buffer the positions index slid by `n`.
pub fn slide(bt: *BinaryTrees, n: usize) void {
    bt.base -= @intCast(n);
}

/// Forget every position: a later match reaches none before this.
pub fn forget(bt: *BinaryTrees) void {
    @memset(bt.hash3[0 .. @as(usize, 1) << bt.hash3_bits], .{ match.none, match.none });
    @memset(bt.hash4[0 .. @as(usize, 1) << bt.hash4_bits], match.none);
}

/// Keep positions storable: once `p` is a window past the base, move it.
inline fn advance(bt: *BinaryTrees, p: isize) void {
    if (p - bt.base >= match.window) {
        @branchHint(.unlikely);
        match.rebase(std.mem.bytesAsSlice(i16, std.mem.sliceAsBytes(bt.hash3[0 .. @as(usize, 1) << bt.hash3_bits])));
        match.rebase(bt.hash4[0 .. @as(usize, 1) << bt.hash4_bits]);
        match.rebase(bt.child);
        bt.base += match.window;
    }
}

/// The slot of a stored position's children: a constant mask over the
/// full window, as the chains' slots.
inline fn slot(bt: *const BinaryTrees, comptime full_window: bool, rel: i16) usize {
    const mask: usize = if (full_window) match.window - 1 else bt.child.len / 2 - 1;
    return 2 * (@as(u16, @bitCast(rel)) & mask);
}

/// Every match at `p` (`p >= 0`) longer than the last found, up to
/// `max_len` (`max_len >= required`, `p + max_len <= in.len`), stopping at
/// one of `nice_len` or after `depth` nodes; inserts `p`. The matches go
/// to `out` by increasing length; their count is returned.
pub inline fn matches(bt: *BinaryTrees, comptime dictionary: bool, comptime full_window: bool, h: match.History, p: isize, max_len: u32, nice_len: u32, depth: u32, out: [*]Match) usize {
    return bt.search(dictionary, full_window, true, h, p, max_len, nice_len, depth, out);
}

/// Insert `p` without recording its matches: a position inside a long
/// match. `max_len >= required`.
pub inline fn skip(bt: *BinaryTrees, comptime dictionary: bool, comptime full_window: bool, h: match.History, p: isize, max_len: u32, depth: u32) void {
    _ = bt.search(dictionary, full_window, false, h, p, max_len, max_len, depth, undefined);
}

inline fn search(bt: *BinaryTrees, comptime dictionary: bool, comptime full_window: bool, comptime record: bool, h: match.History, p: isize, max_len: u32, nice_in: u32, depth_in: u32, out: [*]Match) usize {
    bt.advance(p);
    const nice_len = @min(nice_in, max_len);
    const base = bt.base;
    const child = bt.child.ptr;
    const cur: i16 = @intCast(p - base);
    const window: i32 = if (full_window) match.window else @intCast(bt.window);
    const cutoff: i32 = @as(i32, cur) - window;
    const word = h.load32Of(dictionary, p);
    var n: usize = 0;

    const h3 = match.hash(word & 0xff_ffff, bt.hash3_bits);
    const two = bt.hash3[h3];
    bt.hash3[h3] = .{ cur, two[0] };
    const h4 = match.hash(word, bt.hash4_bits);
    var node = bt.hash4[h4];
    bt.hash4[h4] = cur;
    // The next position's buckets, fetched while this one is searched.
    if (max_len >= required + 1) {
        const next = h.load32Of(dictionary, p + 1);
        @prefetch(&bt.hash3[match.hash(next & 0xff_ffff, bt.hash3_bits)], .{ .rw = .write });
        @prefetch(&bt.hash4[match.hash(next, bt.hash4_bits)], .{ .rw = .write });
    }
    if (record) {
        // A three-byte match from the newer of the two, else the older.
        for (two) |c3| {
            if (c3 <= cutoff) break;
            const c = base + c3;
            if (h.load32Of(dictionary, c) & 0xff_ffff == word & 0xff_ffff) {
                out[0] = .{ .length = 3, .offset = @intCast(p - c) };
                n = 1;
                break;
            }
        }
    }
    const at = bt.slot(full_window, cur);
    var smaller: usize = at;
    var larger: usize = at + 1;
    if (node <= cutoff) {
        child[smaller] = match.none;
        child[larger] = match.none;
        return n;
    }
    var best_len: u32 = 3;
    var smaller_len: u32 = 0;
    var larger_len: u32 = 0;
    var len: u32 = 0;
    var depth = depth_in;
    while (true) {
        const m = base + node;
        const node_at = bt.slot(full_window, node);
        if (byteAt(dictionary, h, m + match.offset(len)) == byteAt(dictionary, h, p + match.offset(len))) {
            len = h.matchLengthOf(dictionary, m, p, len + 1, max_len);
            if (!record or len > best_len) {
                if (record) {
                    best_len = len;
                    out[n] = .{ .length = @intCast(len), .offset = @intCast(p - m) };
                    n += 1;
                }
                if (len >= nice_len) {
                    child[smaller] = child[node_at];
                    child[larger] = child[node_at + 1];
                    return n;
                }
            }
        }
        if (byteAt(dictionary, h, m + match.offset(len)) < byteAt(dictionary, h, p + match.offset(len))) {
            // The node sorts before `p`: it goes on the smaller side, and
            // the search goes on to its larger child.
            child[smaller] = node;
            smaller = node_at + 1;
            node = child[smaller];
            smaller_len = len;
            len = @min(len, larger_len);
        } else {
            child[larger] = node;
            larger = node_at;
            node = child[larger];
            larger_len = len;
            len = @min(len, smaller_len);
        }
        depth -= 1;
        if (node <= cutoff or depth == 0) {
            child[smaller] = match.none;
            child[larger] = match.none;
            return n;
        }
    }
}

/// The byte at `pos`, straight from the input when there is no dictionary.
inline fn byteAt(comptime dictionary: bool, h: match.History, pos: isize) u8 {
    if (!dictionary) return h.in[@intCast(pos)];
    return h.at(pos);
}

/// Insert a dictionary's positions, which lie before the input, as a
/// search inserts them (`p + count + 3 <= in.len` and every position with
/// `required` bytes).
pub fn prime(bt: *BinaryTrees, h: match.History, p: isize, count: u32, depth: u32) void {
    var q = p;
    const end = p + match.offset(count);
    while (q < end) : (q += 1) {
        const left: isize = @as(isize, @intCast(h.in.len)) - q;
        const max: u32 = @intCast(@min(match.max_match, left));
        if (max < required) return;
        bt.skip(true, false, h, q, max, depth);
    }
}

test "a search finds every longer match, and re-rooted trees find them again" {
    const in = "abcdefgh_abcdeXgh_abcdefgX_abcdefgh!";
    var hash3: [1 << 10][2]i16 = undefined;
    var hash4: [1 << 10]i16 = undefined;
    var child: [2 * match.window]i16 = undefined;
    var bt: BinaryTrees = .{ .hash3 = &hash3, .hash4 = &hash4, .child = &child };
    bt.reset(0, 10, 10);
    const h: match.History = .{ .in = in };
    var out: [max_matches]Match = undefined;
    for (0..27) |p| {
        const max: u32 = @intCast(@min(258, in.len - p));
        _ = bt.matches(false, true, h, @intCast(p), max, 258, 32, &out);
    }
    const n = bt.matches(false, true, h, 27, @intCast(in.len - 27), 258, 32, &out);
    // "abcdefgh" at 0 (27 back) is the longest; shorter ones come first.
    try std.testing.expect(n >= 1);
    try std.testing.expectEqual(@as(u16, 8), out[n - 1].length);
    try std.testing.expectEqual(@as(u16, 27), out[n - 1].offset);
    for (out[1..n], out[0 .. n - 1]) |longer, shorter| try std.testing.expect(longer.length > shorter.length);
}
