//! Hash chains (levels 2-9): a table of the latest position for each hash
//! of four bytes, each position linked to the one before it with the same
//! hash, and a table of the latest position for each hash of three bytes
//! (one candidate for a three-byte match).
//!
//! Only the hash tables are cleared per stream, sized to the input: the
//! chain links are written before they are read, so a short stream clears
//! a few kilobytes, not the window.

const HashChains = @This();

const std = @import("std");
const match = @import("history.zig");

const window_mask = match.window - 1;

/// Private: the latest position per four-byte hash.
hash4: []i16,
/// Private: the latest position per three-byte hash.
hash3: []i16,
/// Private: the previous position with the same four-byte hash, by
/// position modulo the window.
prev: *[match.window]i16,
/// Private: the hash tables' sizes in use, in bits.
hash4_bits: u5 = 0,
hash3_bits: u5 = 0,
/// Private: positions are stored relative to this.
base: isize = 0,

/// The memory for tables of at most `hash4_bits` and `hash3_bits`.
pub fn memory(hash4_bits: u5, hash3_bits: u5) usize {
    return (@as(usize, 1) << hash4_bits) * 2 + (@as(usize, 1) << hash3_bits) * 2 + match.window * 2;
}

/// Start over for a stream that begins at `first` (negative with a
/// dictionary), with tables of `hash4_bits` and `hash3_bits`.
pub fn reset(hc: *HashChains, first: isize, hash4_bits: u5, hash3_bits: u5) void {
    std.debug.assert(first >= -match.window);
    hc.hash4_bits = hash4_bits;
    hc.hash3_bits = hash3_bits;
    @memset(hc.hash4[0 .. @as(usize, 1) << hash4_bits], match.none);
    @memset(hc.hash3[0 .. @as(usize, 1) << hash3_bits], match.none);
    // A multiple of the window: a dictionary's positions start a window
    // before the input.
    hc.base = if (first < 0) -match.window else 0;
}

/// A stored position's link in `prev`. The base is always a multiple of
/// the window, so a position relative to it is in the same slot as the
/// position itself.
inline fn slot(rel: i16) usize {
    return @as(u16, @bitCast(rel)) & window_mask;
}

/// Keep positions storable: once `p` is a window past the base, move it.
inline fn advance(hc: *HashChains, p: isize) void {
    if (p - hc.base >= match.window) {
        @branchHint(.unlikely);
        match.rebase(hc.hash4[0 .. @as(usize, 1) << hc.hash4_bits]);
        match.rebase(hc.hash3[0 .. @as(usize, 1) << hc.hash3_bits]);
        match.rebase(hc.prev);
        hc.base += match.window;
    }
}

/// The longest match for `p` (`p >= 0`) of more than `best_len` bytes and
/// at most `max_len` (`p + max_len <= in.len`, `max_len >= 4`), following
/// at most `depth` links and stopping at `nice_len`; inserts `p`. Returns
/// the length (`best_len` if none longer) and sets `distance` when it
/// found one. Without `dictionary` every position is in the input, and the
/// loads go straight to it.
pub inline fn longestMatch(hc: *HashChains, comptime dictionary: bool, h: match.History, p: isize, best_len_in: u32, max_len: u32, nice_len_in: u32, depth: u32, distance: *u32) u32 {
    hc.advance(p);
    // Locals, so that no store through `distance` or the tables makes the
    // compiler reload them.
    const base = hc.base;
    const prev = hc.prev;
    // A match as long as the input allows ends the search too.
    const nice_len = @min(nice_len_in, max_len);
    var best_len = best_len_in;
    var best_dist: u32 = 0;
    const cur: i16 = @intCast(p - base);
    const cutoff: i32 = @as(i32, cur) - match.window;
    const word = h.load32Of(false, p);
    const h3 = match.hash(word & 0xff_ffff, hc.hash3_bits);
    const h4 = match.hash(word, hc.hash4_bits);
    const cand3 = hc.hash3[h3];
    hc.hash3[h3] = cur;
    var cand = hc.hash4[h4];
    hc.hash4[h4] = cur;
    prev[slot(cur)] = cand;
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
                cand = prev[slot(cand)];
                if (cand <= cutoff) break :search;
            }
            const c = base + cand;
            best_len = h.matchLengthOf(dictionary, c, p, 4, max_len);
            best_dist = @intCast(p - c);
            if (best_len >= nice_len) break :search;
            left -= 1;
            if (left == 0) break :search;
            cand = prev[slot(cand)];
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
                cand = prev[slot(cand)];
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
            cand = prev[slot(cand)];
            if (cand <= cutoff) break :search;
        }
    }
    if (best_dist != 0) distance.* = best_dist;
    return best_len;
}

/// Insert `count` positions from `p` (`p >= 0`) without searching (`p +
/// count + 3 <= in.len`).
pub inline fn skip(hc: *HashChains, h: match.History, p: isize, count: u32) void {
    hc.insert(false, h, p, count);
}

/// Insert a dictionary's positions, which lie before the input.
pub fn prime(hc: *HashChains, h: match.History, p: isize, count: u32) void {
    hc.insert(true, h, p, count);
}

inline fn insert(hc: *HashChains, comptime dictionary: bool, h: match.History, p: isize, count: u32) void {
    var q = p;
    const end = p + match.offset(count);
    while (q < end) {
        hc.advance(q);
        // Up to the next window boundary, with every table in a local: no
        // store into a table makes the compiler reload them.
        const base = hc.base;
        const stop = @min(end, base + match.window);
        const hash3 = hc.hash3;
        const hash4 = hc.hash4;
        const prev = hc.prev;
        const bits3 = hc.hash3_bits;
        const bits4 = hc.hash4_bits;
        while (q < stop) : (q += 1) {
            const cur: i16 = @intCast(q - base);
            const word = h.load32Of(dictionary, q);
            hash3[match.hash(word & 0xff_ffff, bits3)] = cur;
            const h4 = match.hash(word, bits4);
            prev[slot(cur)] = hash4[h4];
            hash4[h4] = cur;
        }
    }
}
