//! Hash chains (levels 2-9): a table of the latest position for each hash
//! of four bytes, each position linked to the one before it with the same
//! hash, and a table of the latest position for each hash of three bytes
//! (one candidate for a three-byte match).
//!
//! Only the hash tables are cleared per stream, sized to the input: the
//! chain links are written before they are read, so a short stream clears
//! a few kilobytes, not the window.

const std = @import("std");
const match = @import("history.zig");

pub const Config = struct {
    /// The window, a power of two; over 64 KiB, distances take 32 bits.
    window: u32,
    /// The shortest match `matches` gives: 2 for LZMA, from the latest
    /// position per hash of two bytes. 3: `longestMatch` alone.
    shortest: u32 = 3,
    /// The bytes the chains hash: 4, or 3 (liblzma's hc3; the hash of
    /// three bytes is then the chains').
    chain: u32 = 4,
};

/// Hash chains over a window of `window` bytes, a power of two.
pub fn HashChainsFor(comptime window: u32) type {
    return HashChainsWith(.{ .window = window });
}

pub fn HashChainsWith(comptime config: Config) type {
    comptime std.debug.assert(config.chain == 3 or config.chain == 4);
    comptime std.debug.assert(config.shortest == 2 or (config.shortest == 3 and config.chain == 4));
    const window = config.window;
    return struct {
        const HashChains = @This();
        const Pos = match.Position(window);
        const none = match.none(Pos);
        /// A stored position as its slot bits.
        const Unsigned = @Int(.unsigned, @bitSizeOf(Pos));
        const pairs = config.shortest == 2;

        pub const Match = match.MatchFor(window);
        /// The bytes a position needs to be hashed: three for liblzma's
        /// hc3, as it searches the input's last three.
        pub const required = if (pairs and config.chain == 3) 3 else 4;
        /// The latest position per two-byte hash: as liblzma's, 1024 of them
        /// (its hashes, `match.LzmaHashes`, with `shortest` 2).
        pub const hash2_bits = if (pairs) 10 else 0;

        /// Private: the latest position per two-byte hash (`shortest` 2).
        hash2: if (pairs) []Pos else void = if (pairs) &.{} else {},
        /// Private: the latest position per four-byte hash (three with
        /// `chain` 3): the chains' heads.
        hash4: []Pos,
        /// Private: the latest position per three-byte hash.
        hash3: []Pos,
        /// Private: the previous position with the same four-byte hash, by
        /// position modulo the window (a power of two, at most `window`).
        prev: []Pos,
        /// Private: the hash tables' sizes in use, in bits.
        hash4_bits: u5 = 0,
        hash3_bits: u5 = 0,
        /// Private: positions are stored relative to this.
        base: isize = 0,
        /// The farthest a match from `matches` reaches back, plus one: at
        /// most one past the chains' length, as liblzma's window of the
        /// dictionary and one more position reaches a match exactly the
        /// dictionary back.
        reach: u32 = window,

        /// The memory for tables of at most `hash4_bits` and `hash3_bits`, over a
        /// window of `span` bytes (at most `window`).
        pub fn memory(hash4_bits: u5, hash3_bits: u5, span: usize) usize {
            const two: usize = if (pairs) 1 << hash2_bits else 0;
            return (two + (@as(usize, 1) << hash4_bits) + (@as(usize, 1) << hash3_bits) + span) * @sizeOf(Pos);
        }

        /// Start over for a stream that begins at `first` (negative with a
        /// dictionary), with tables of `hash4_bits` and `hash3_bits`.
        pub fn reset(hc: *HashChains, first: isize, hash4_bits: u5, hash3_bits: u5) void {
            std.debug.assert(first >= -@as(isize, window));
            hc.hash4_bits = hash4_bits;
            hc.hash3_bits = hash3_bits;
            @memset(hc.hash4[0 .. @as(usize, 1) << hash4_bits], none);
            @memset(hc.hash3[0 .. @as(usize, 1) << hash3_bits], none);
            if (pairs) @memset(hc.hash2, none);
            // A multiple of the window: a dictionary's positions start a window
            // before the input.
            hc.base = if (first < 0) -@as(isize, window) else 0;
        }

        /// A stored position's link in `prev`, by its value relative to the base:
        /// the value a position is stored as never changes while it is in the
        /// window, whatever the base does.
        inline fn slot(rel: Pos, mask: usize) usize {
            return @as(Unsigned, @bitCast(rel)) & mask;
        }

        /// Moved back `n` positions: the buffer the positions index slid by `n`.
        pub fn slide(hc: *HashChains, n: usize) void {
            hc.base -= @intCast(n);
        }

        /// Forget every position: a later match reaches none before this.
        pub fn forget(hc: *HashChains) void {
            @memset(hc.hash4[0 .. @as(usize, 1) << hc.hash4_bits], none);
            @memset(hc.hash3[0 .. @as(usize, 1) << hc.hash3_bits], none);
            if (pairs) @memset(hc.hash2, none);
        }

        /// Keep positions storable: once `p` is a window past the base, move it.
        inline fn advance(hc: *HashChains, p: isize) void {
            if (p - hc.base >= window) {
                @branchHint(.unlikely);
                match.rebase(window, hc.hash4[0 .. @as(usize, 1) << hc.hash4_bits]);
                match.rebase(window, hc.hash3[0 .. @as(usize, 1) << hc.hash3_bits]);
                match.rebase(window, hc.prev);
                if (pairs) match.rebase(window, hc.hash2);
                hc.base += window;
            }
        }

        /// The longest match for `p` (`p >= 0`) of more than `best_len` bytes and
        /// at most `max_len` (`p + max_len <= in.len`, `max_len >= 4`), following
        /// at most `depth` links and stopping at `nice_len`; inserts `p`. Returns
        /// the length (`best_len` if none longer) and sets `distance` when it
        /// found one. Without `dictionary` every position is in the input, and the
        /// loads go straight to it.
        pub inline fn longestMatch(hc: *HashChains, comptime dictionary: bool, comptime full_window: bool, h: match.History, p: isize, best_len_in: u32, max_len: u32, nice_len_in: u32, depth: u32, distance: *u32) u32 {
            hc.advance(p);
            // Locals, so that no store through `distance` or the tables makes the
            // compiler reload them.
            const base = hc.base;
            const prev = hc.prev.ptr;
            const mask = windowMask(hc, full_window);
            // A match as long as the input allows ends the search too.
            const nice_len = @min(nice_len_in, max_len);
            var best_len = best_len_in;
            var best_dist: u32 = 0;
            const cur: Pos = @intCast(p - base);
            const reach: i32 = if (full_window) window else @intCast(hc.prev.len);
            const cutoff: i32 = @as(i32, cur) - reach;
            const word = h.load32Of(false, p);
            const h3 = match.hash(word & 0xff_ffff, hc.hash3_bits);
            const h4 = match.hash(word, hc.hash4_bits);
            const cand3 = hc.hash3[h3];
            hc.hash3[h3] = cur;
            var cand = hc.hash4[h4];
            hc.hash4[h4] = cur;
            prev[slot(cur, mask)] = cand;
            // The next position's buckets, fetched while this one is searched.
            if (max_len >= 5) {
                const next = h.load32Of(false, p + 1);
                @prefetch(&hc.hash3[match.hash(next & 0xff_ffff, hc.hash3_bits)], .{ .rw = .write });
                @prefetch(&hc.hash4[match.hash(next, hc.hash4_bits)], .{ .rw = .write });
            }
            if (best_len >= max_len) return best_len;

            // No position in the window shares the first three bytes: there is no
            // match at all, and the chain need not be walked.
            if (best_len < 4 and cand3 <= cutoff) return best_len;
            if (best_len < 3) {
                const c = base + cand3;
                if (h.load32Of(dictionary, c) & 0xff_ffff == word & 0xff_ffff) {
                    best_len = 3;
                    best_dist = @intCast(p - c);
                }
            }
            search: {
                if (cand <= cutoff) break :search;
                var left = depth;
                if (best_len < 4) {
                    // No four-byte match yet: the first four bytes decide.
                    while (h.load32Of(dictionary, base + cand) != word) {
                        left -= 1;
                        if (left == 0) break :search;
                        cand = prev[slot(cand, mask)];
                        if (cand <= cutoff) break :search;
                    }
                    const c = base + cand;
                    best_len = h.matchLengthOf(dictionary, c, p, 4, max_len);
                    best_dist = @intCast(p - c);
                    if (best_len >= nice_len) break :search;
                    left -= 1;
                    if (left == 0) break :search;
                    cand = prev[slot(cand, mask)];
                    if (cand <= cutoff) break :search;
                }
                // Longer matches. While `best_len` holds, a candidate must agree
                // on the four bytes where a longer match would end, then on the
                // first four: most fail the first test, and the bytes it compares
                // against are loaded once.
                while (true) {
                    const tail = h.load32Of(false, p + match.offset(best_len) - 3);
                    while (h.load32Of(dictionary, base + cand + match.offset(best_len) - 3) != tail or h.load32Of(dictionary, base + cand) != word) {
                        left -= 1;
                        if (left == 0) break :search;
                        cand = prev[slot(cand, mask)];
                        if (cand <= cutoff) break :search;
                    }
                    const c = base + cand;
                    const len = h.matchLengthOf(dictionary, c, p, 4, max_len);
                    if (len > best_len) {
                        best_len = len;
                        best_dist = @intCast(p - c);
                        if (len >= nice_len) break :search;
                    }
                    left -= 1;
                    if (left == 0) break :search;
                    cand = prev[slot(cand, mask)];
                    if (cand <= cutoff) break :search;
                }
            }
            if (best_dist != 0) distance.* = best_dist;
            return best_len;
        }

        /// Every match at `p` (`p >= 0`) longer than the last found, as
        /// liblzma's hc3 and hc4 find them (`shortest` 2): two bytes from the
        /// latest position with those two, three from the hash of three
        /// (with `chain` 4), the later of them extended to its full length,
        /// then the chain for longer ones, at most `depth` links and to
        /// `max_len` (`p + max(max_len, required) <= in.len`), stopping at
        /// one of `max_len`; inserts `p`. The matches go to `out` by
        /// increasing length; their count is returned. No dictionary.
        pub fn matches(hc: *HashChains, h: match.History, p: isize, max_len: u32, depth: u32, out: [*]Match) usize {
            comptime std.debug.assert(pairs);
            hc.advance(p);
            const base = hc.base;
            const prev = hc.prev.ptr;
            const slots = hc.prev.len - 1;
            const cur: Pos = @intCast(p - base);
            const cutoff: i32 = @as(i32, cur) - @as(i32, @intCast(hc.reach));
            const word = wordAt(false, h, p);
            const mask = (@as(u32, 1) << hc.hash4_bits) - 1;
            const lz: match.LzmaHashes = .of(word, mask);
            const c2 = hc.hash2[lz.two];
            hc.hash2[lz.two] = cur;
            const hk = if (config.chain == 4) lz.four else match.LzmaHashes.threeOf(word, mask);
            var cand = hc.hash4[hk];
            hc.hash4[hk] = cur;
            const at = slot(cur, slots);
            prev[at] = cand;
            var n: usize = 0;
            var last: isize = undefined;
            if (c2 > cutoff and h.load32Of(false, base + c2) & 0xffff == word & 0xffff) {
                last = base + c2;
                out[0] = .{ .length = 2, .offset = @intCast(p - last) };
                n = 1;
            }
            if (config.chain == 4) {
                const c3 = hc.hash3[lz.three];
                hc.hash3[lz.three] = cur;
                if (c3 != c2 and c3 > cutoff and h.load32Of(false, base + c3) & 0xff_ffff == word & 0xff_ffff) {
                    last = base + c3;
                    out[n] = .{ .length = 3, .offset = @intCast(p - last) };
                    n += 1;
                }
            }
            var best_len: u32 = 2;
            if (n != 0) {
                best_len = h.matchLengthOf(false, last, p, out[n - 1].length, max_len);
                out[n - 1].length = @intCast(best_len);
                if (best_len == max_len) return n;
            }
            // The chains: four-byte ones give matches past three bytes.
            if (config.chain == 4) best_len = @max(best_len, 3);
            var left = depth;
            while (left != 0 and cand > cutoff) : (left -= 1) {
                const c = base + cand;
                // A position the chains' length back shares `p`'s slot, its
                // link now `p`'s: the ones before it are out of reach.
                const link = slot(cand, slots);
                cand = if (link == at) none else prev[link];
                const end = match.offset(best_len);
                if (h.in[@intCast(c + end)] != h.in[@intCast(p + end)] or h.in[@intCast(c)] != h.in[@intCast(p)]) continue;
                const len = h.matchLengthOf(false, c, p, 1, max_len);
                if (len > best_len) {
                    best_len = len;
                    out[n] = .{ .length = @intCast(len), .offset = @intCast(p - c) };
                    n += 1;
                    if (len == max_len) break;
                }
            }
            return n;
        }

        /// Insert `count` positions from `p` (`p >= 0`) without searching (`p +
        /// count + required - 1 <= in.len`).
        pub inline fn skip(hc: *HashChains, comptime full_window: bool, h: match.History, p: isize, count: u32) void {
            hc.insert(false, full_window, h, p, count);
        }

        /// Insert a dictionary's positions, which lie before the input.
        pub fn prime(hc: *HashChains, h: match.History, p: isize, count: u32) void {
            hc.insert(true, false, h, p, count);
        }

        /// The bytes at `q` the hashes take: the last three of the input
        /// alone where `required` is 3.
        inline fn wordAt(comptime dictionary: bool, h: match.History, q: isize) u32 {
            if (required == 3 and q + 4 > @as(isize, @intCast(h.in.len))) return h.load24(q);
            return h.load32Of(dictionary, q);
        }

        /// The mask of a position's slot in `prev`: a constant for the full window,
        /// where the chain walks spend most of their time and a mask in a register
        /// costs a tenth of the speed.
        inline fn windowMask(hc: *const HashChains, comptime full_window: bool) usize {
            if (full_window) {
                std.debug.assert(hc.prev.len == window);
                return window - 1;
            }
            return hc.prev.len - 1;
        }

        inline fn insert(hc: *HashChains, comptime dictionary: bool, comptime full_window: bool, h: match.History, p: isize, count: u32) void {
            var q = p;
            const end = p + match.offset(count);
            while (q < end) {
                hc.advance(q);
                // Up to the next window boundary, with every table in a local: no
                // store into a table makes the compiler reload them.
                const base = hc.base;
                const stop = @min(end, base + window);
                const hash3 = hc.hash3;
                const hash4 = hc.hash4;
                const prev = hc.prev.ptr;
                const mask = windowMask(hc, full_window);
                const bits3 = hc.hash3_bits;
                const bits4 = hc.hash4_bits;
                while (q < stop) : (q += 1) {
                    const cur: Pos = @intCast(q - base);
                    const word = wordAt(dictionary, h, q);
                    var h4: u32 = undefined;
                    if (pairs) {
                        const lz: match.LzmaHashes = .of(word, (@as(u32, 1) << bits4) - 1);
                        hc.hash2[lz.two] = cur;
                        if (config.chain == 4) hash3[lz.three] = cur;
                        h4 = if (config.chain == 4) lz.four else match.LzmaHashes.threeOf(word, (@as(u32, 1) << bits4) - 1);
                    } else {
                        hash3[match.hash(word & 0xff_ffff, bits3)] = cur;
                        h4 = match.hash(word, bits4);
                    }
                    prev[slot(cur, mask)] = hash4[h4];
                    hash4[h4] = cur;
                }
            }
        }
    };
}
