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
//!
//! LZMA's matches start at two bytes: with `shortest` 2 the latest position
//! per hash of two bytes gives those, and the shortest match found is
//! extended to its full length before the tree is searched, as liblzma's
//! bt4 does, with liblzma's hashes, so the matches are its matches.

const std = @import("std");
const match = @import("history.zig");

pub const Config = struct {
    /// The window, a power of two; over 64 KiB, distances take 32 bits.
    window: u32,
    /// The shortest match a search gives: 3, or 2 for LZMA.
    shortest: u32 = 3,
};

/// Binary trees over a window of `window` bytes, a power of two.
pub fn BinaryTreesFor(comptime window: u32) type {
    return BinaryTreesWith(.{ .window = window });
}

pub fn BinaryTreesWith(comptime config: Config) type {
    comptime std.debug.assert(config.shortest == 2 or config.shortest == 3);
    const window = config.window;
    return struct {
        const BinaryTrees = @This();
        const Pos = match.Position(window);
        const none = match.none(Pos);
        /// A stored position as its slot bits.
        const Unsigned = @Int(.unsigned, @bitSizeOf(Pos));
        const pairs = config.shortest == 2;

        pub const Match = match.MatchFor(window);
        pub const max_matches = match.max_matches;

        /// A search needs this many bytes from its position.
        pub const required = 4;
        /// The latest position per two-byte hash: as liblzma's, 1024 of them.
        pub const hash2_bits = if (pairs) 10 else 0;

        /// Private: the latest position per two-byte hash (`shortest` 2).
        hash2: if (pairs) []Pos else void = if (pairs) &.{} else {},
        /// Private: the two latest positions per three-byte hash, newest first.
        hash3: [][2]Pos,
        /// Private: each tree's root per four-byte hash.
        hash4: []Pos,
        /// Private: each position's two children (smaller, larger), by position
        /// modulo the window.
        child: []Pos,
        hash3_bits: u5 = 0,
        hash4_bits: u5 = 0,
        /// Private: positions are stored relative to this.
        base: isize = 0,
        /// Private: the farthest a match reaches back, plus one; at most
        /// one past the trees' length (`shortest` 2), as liblzma's window
        /// of the dictionary and one more position reaches a match exactly
        /// the dictionary back.
        window: u32 = window,
        /// A tree was ordered by a prefix that ended here. If the input grows,
        /// comparisons must verify the bytes rather than reuse that prefix length.
        prefix_end: ?isize = null,

        /// The memory for tables of `hash3_bits` and `hash4_bits` over a window of
        /// `span` bytes (at most `window`).
        pub fn memory(hash3_bits: u5, hash4_bits: u5, span: usize) usize {
            const two: usize = if (pairs) 1 << hash2_bits else 0;
            return (two + (@as(usize, 1) << hash3_bits) * 2 + (@as(usize, 1) << hash4_bits) + span * 2) * @sizeOf(Pos);
        }

        /// Start over for a stream that begins at `first` (negative with a
        /// dictionary), with tables of `hash3_bits` and `hash4_bits`.
        pub fn reset(bt: *BinaryTrees, first: isize, hash3_bits: u5, hash4_bits: u5) void {
            std.debug.assert(first >= -@as(isize, window));
            bt.hash3_bits = hash3_bits;
            bt.hash4_bits = hash4_bits;
            @memset(bt.hash3[0 .. @as(usize, 1) << hash3_bits], .{ none, none });
            @memset(bt.hash4[0 .. @as(usize, 1) << hash4_bits], none);
            if (pairs) @memset(bt.hash2, none);
            bt.base = if (first < 0) -@as(isize, window) else 0;
            bt.prefix_end = null;
        }

        /// Moved back `n` positions: the buffer the positions index slid by `n`.
        pub fn slide(bt: *BinaryTrees, n: usize) void {
            bt.base -= @intCast(n);
            if (bt.prefix_end) |*end| end.* -= @intCast(n);
        }

        /// Forget every position: a later match reaches none before this.
        pub fn forget(bt: *BinaryTrees) void {
            @memset(bt.hash3[0 .. @as(usize, 1) << bt.hash3_bits], .{ none, none });
            @memset(bt.hash4[0 .. @as(usize, 1) << bt.hash4_bits], none);
            if (pairs) @memset(bt.hash2, none);
            bt.prefix_end = null;
        }

        /// Keep positions storable: once `p` is a window past the base, move it.
        inline fn advance(bt: *BinaryTrees, p: isize) void {
            if (p - bt.base >= window) {
                @branchHint(.unlikely);
                match.rebase(window, std.mem.bytesAsSlice(Pos, std.mem.sliceAsBytes(bt.hash3[0 .. @as(usize, 1) << bt.hash3_bits])));
                match.rebase(window, bt.hash4[0 .. @as(usize, 1) << bt.hash4_bits]);
                match.rebase(window, bt.child);
                if (pairs) match.rebase(window, bt.hash2);
                bt.base += window;
            }
        }

        /// The slot of a stored position's children: a constant mask over the
        /// full window, as the chains' slots.
        inline fn slot(bt: *const BinaryTrees, comptime full_window: bool, rel: Pos) usize {
            const mask: usize = if (full_window) window - 1 else bt.child.len / 2 - 1;
            return 2 * (@as(Unsigned, @bitCast(rel)) & mask);
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
            const input_end: isize = @intCast(h.in.len);
            if (max_len == nice_len and p + match.offset(max_len) == input_end and bt.prefix_end == null) bt.prefix_end = input_end;
            const trust_prefix = if (bt.prefix_end) |end| input_end <= end else true;
            const base = bt.base;
            const child = bt.child.ptr;
            const cur: Pos = @intCast(p - base);
            const reach: i32 = if (full_window) window else @intCast(bt.window);
            const cutoff: i32 = @as(i32, cur) - reach;
            const word = h.load32Of(dictionary, p);
            var n: usize = 0;

            const lz: match.LzmaHashes = if (pairs) .of(word, (@as(u32, 1) << bt.hash4_bits) - 1) else undefined;
            const h3 = if (pairs) lz.three else match.hash(word & 0xff_ffff, bt.hash3_bits);
            const two = bt.hash3[h3];
            bt.hash3[h3] = .{ cur, two[0] };
            const h4 = if (pairs) lz.four else match.hash(word, bt.hash4_bits);
            var node = bt.hash4[h4];
            bt.hash4[h4] = cur;
            // The next position's buckets, fetched while this one is searched.
            if (!pairs and max_len >= required + 1) {
                const next = h.load32Of(dictionary, p + 1);
                @prefetch(&bt.hash3[match.hash(next & 0xff_ffff, bt.hash3_bits)], .{ .rw = .write });
                @prefetch(&bt.hash4[match.hash(next, bt.hash4_bits)], .{ .rw = .write });
            }
            var best_len: u32 = 3;
            if (pairs) {
                const h2 = lz.two;
                const c2 = bt.hash2[h2];
                bt.hash2[h2] = cur;
                if (record) {
                    n = shortMatches(dictionary, h, p, base, cutoff, c2, two, word, max_len, out);
                    if (n != 0) best_len = @max(best_len, out[n - 1].length);
                }
            } else if (record) {
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
                child[smaller] = none;
                child[larger] = none;
                return n;
            }
            var smaller_len: u32 = 0;
            var larger_len: u32 = 0;
            var len: u32 = 0;
            var depth = depth_in;
            while (true) {
                const m = base + node;
                const node_at = bt.slot(full_window, node);
                // A node the trees' length back shares `p`'s children: its
                // own, older, are out of reach, and the search ends with it.
                const last = pairs and node_at == at;
                if (byteAt(dictionary, h, m + match.offset(len)) == byteAt(dictionary, h, p + match.offset(len))) {
                    len = h.matchLengthOf(dictionary, m, p, len + 1, max_len);
                    if (record and len > best_len) {
                        best_len = len;
                        out[n] = .{ .length = @intCast(len), .offset = @intCast(p - m) };
                        n += 1;
                    }
                    if (len >= nice_len) {
                        child[smaller] = if (last) none else child[node_at];
                        child[larger] = if (last) none else child[node_at + 1];
                        return n;
                    }
                }
                if (byteAt(dictionary, h, m + match.offset(len)) < byteAt(dictionary, h, p + match.offset(len))) {
                    // The node sorts before `p`: it goes on the smaller side, and
                    // the search goes on to its larger child.
                    child[smaller] = node;
                    if (last) {
                        child[larger] = none;
                        return n;
                    }
                    smaller = node_at + 1;
                    node = child[smaller];
                    smaller_len = len;
                    len = if (trust_prefix) @min(len, larger_len) else 0;
                } else {
                    child[larger] = node;
                    if (last) {
                        child[smaller] = none;
                        return n;
                    }
                    larger = node_at;
                    node = child[larger];
                    larger_len = len;
                    len = if (trust_prefix) @min(len, smaller_len) else 0;
                }
                depth -= 1;
                if (node <= cutoff or depth == 0) {
                    child[smaller] = none;
                    child[larger] = none;
                    return n;
                }
            }
        }

        /// liblzma's bt4 start: a two-byte match from the latest position
        /// with those two bytes, a three-byte one from the latest with the
        /// hash of three (another position), the later of them extended to
        /// its full length. Their count.
        inline fn shortMatches(comptime dictionary: bool, h: match.History, p: isize, base: isize, cutoff: i32, c2: Pos, two: [2]Pos, word: u32, max_len: u32, out: [*]Match) usize {
            var n: usize = 0;
            var last: isize = undefined;
            if (c2 > cutoff and h.load32Of(dictionary, base + c2) & 0xffff == word & 0xffff) {
                last = base + c2;
                out[0] = .{ .length = 2, .offset = @intCast(p - last) };
                n = 1;
            }
            const c3 = two[0];
            if (c3 != c2 and c3 > cutoff and h.load32Of(dictionary, base + c3) & 0xff_ffff == word & 0xff_ffff) {
                last = base + c3;
                out[n] = .{ .length = 3, .offset = @intCast(p - last) };
                n += 1;
            }
            if (n != 0) out[n - 1].length = @intCast(h.matchLengthOf(dictionary, last, p, out[n - 1].length, max_len));
            return n;
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
    };
}

test "a search finds every longer match, and re-rooted trees find them again" {
    inline for (.{ match.window, 65536 }) |window| try findsEveryLongerMatch(window);
}

fn findsEveryLongerMatch(comptime window: u32) !void {
    const BinaryTrees = BinaryTreesFor(window);
    const Pos = match.Position(window);
    const in = "abcdefgh_abcdeXgh_abcdefgX_abcdefgh!";
    var hash3: [1 << 10][2]Pos = undefined;
    var hash4: [1 << 10]Pos = undefined;
    var child: [2 * window]Pos = undefined;
    var bt: BinaryTrees = .{ .hash3 = &hash3, .hash4 = &hash4, .child = &child };
    bt.reset(0, 10, 10);
    const h: match.History = .{ .in = in };
    var out: [match.max_matches]match.Match = undefined;
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
