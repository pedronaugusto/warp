//! Parsers: what each level chooses at each position (a literal, or a
//! match of some length and distance), gathered into blocks.
//!
//!   level 1     two candidates per position from a hash table, greedy
//!   levels 2-3  hash chains, greedy: the longest match found is taken
//!   levels 4-9  hash chains, lazy: a match is taken unless the next
//!               position has a better one
//!
//! and the strategies: Huffman-only (literals), RLE (distance one only),
//! filtered (matches shorter than six are literals).

const std = @import("std");
const bits = @import("../bits.zig");
const match = @import("../match.zig");
const block = @import("block.zig");
const split = @import("split.zig");
const Splitter = split.Splitter;

/// A block in the making: its sequences, counts and split observations.
/// The parsers keep the per-symbol state (the literal run, the symbols
/// since the last split check) in a `Cursor` of their own, in registers.
pub const Builder = struct {
    w: *bits.Writer,
    in: []const u8,
    kinds: block.Kinds,
    seqs: []block.Sequence,
    n: usize = 0,
    counts: block.Counts = .{},
    split: Splitter = .{},
    /// Where the block starts in the input.
    start: usize = 0,

    /// Nor shorter than this, unless the input ends.
    const min_len = 5000;

    /// Write the block ending at `p`, whose last `run` bytes are literals.
    pub fn end(b: *Builder, p: usize, run: u32, final: bool) void {
        block.write(b.w, b.in[b.start..p], b.seqs[0..b.n], run, &b.counts, final, b.kinds);
        b.n = 0;
        b.counts = .{};
        b.split.startBlock();
        b.start = p;
    }
};

/// What a parser carries from symbol to symbol.
pub const Cursor = struct {
    b: *Builder,
    /// Literals since the last match.
    run: u32 = 0,
    /// Symbols since the last split check.
    pending: u32 = 0,

    pub inline fn literal(c: *Cursor, byte: u8) void {
        c.b.counts.literal(byte);
        c.b.split.literal(byte);
        c.run += 1;
        c.pending += 1;
    }

    /// A literal for the fastest parser, which does not split blocks by
    /// their statistics.
    pub inline fn literalUnobserved(c: *Cursor, byte: u8) void {
        c.b.counts.literal(byte);
        c.run += 1;
    }

    pub inline fn matchUnobserved(c: *Cursor, length: u32, distance: u32) void {
        const b = c.b;
        b.counts.match(length, distance);
        b.seqs[b.n] = .{ .literals = c.run, .length = @intCast(length), .distance = @intCast(distance) };
        b.n += 1;
        c.run = 0;
    }

    /// The fastest parser's blocks: at most 64 KiB of input, or as many
    /// matches as the buffer holds (8,192), whichever comes first.
    pub inline fn maybeEndFast(c: *Cursor, p: usize) void {
        const b = c.b;
        if (b.n >= b.seqs.len or p - b.start >= 65535) c.endBlock(p);
    }

    pub inline fn addMatch(c: *Cursor, length: u32, distance: u32) void {
        const b = c.b;
        b.counts.match(length, distance);
        b.split.match(length);
        b.seqs[b.n] = .{ .literals = c.run, .length = @intCast(length), .distance = @intCast(distance) };
        b.n += 1;
        c.run = 0;
        c.pending += 1;
    }

    /// End the block at `p` if it is full, long, or changing. Called after
    /// every match, and between matches every so many literals.
    pub inline fn maybeEnd(c: *Cursor, p: usize) void {
        const b = c.b;
        const len = p - b.start;
        if (b.n >= b.seqs.len) return c.endBlock(p);
        if (c.pending < split.check_every) return;
        c.pending = 0;
        if (len >= Builder.min_len and b.in.len - p >= Builder.min_len and b.split.differs()) c.endBlock(p);
    }

    /// `maybeEnd` after a literal: only once enough symbols are pending.
    pub inline fn maybeEndLiteral(c: *Cursor, p: usize) void {
        if (c.pending >= split.check_every) c.maybeEnd(p);
    }

    fn endBlock(c: *Cursor, p: usize) void {
        c.b.end(p, c.run, false);
        c.run = 0;
        c.pending = 0;
    }

    /// The final block, at the end of the input.
    pub fn finish(c: *Cursor) void {
        c.b.end(c.b.in.len, c.run, true);
    }
};

/// How a level searches.
pub const Params = struct {
    depth: u32,
    nice: u32,
};

/// The longest match a position can have: 258, or what is left.
inline fn maxLen(n: usize, p: usize) u32 {
    return @intCast(@min(match.max_match, n - p));
}

/// zlib's rule: a three-byte match further than this costs more than its
/// literals.
const too_far = 4096;

inline fn worthIt(len: u32, distance: u32, min_len: u32) bool {
    return len >= min_len and (len > 3 or distance <= too_far);
}

/// Level 1.
pub fn fastest(comptime dictionary: bool, c: *Cursor, ht: *match.HashTable, h: match.History) void {
    const n = h.in.len;
    var p: usize = 0;
    while (p < n) {
        const max = maxLen(n, p);
        if (max >= 5) {
            var distance: u32 = 0;
            const len = ht.longestMatch(dictionary, h, @intCast(p), max, &distance);
            if (len >= 3) {
                c.matchUnobserved(len, distance);
                ht.skip(h, @intCast(p + 1), @intCast(@min(len - 1, n - 4 - p - 1 + 1)));
                p += len;
                c.maybeEndFast(p);
                continue;
            }
        }
        c.literalUnobserved(h.in[p]);
        p += 1;
        c.maybeEndFast(p);
    }
}

/// Levels 2-3 (and any level's parse under `filtered`, with `min_len` 6).
pub fn greedy(comptime dictionary: bool, c: *Cursor, hc: *match.HashChains, h: match.History, params: Params, min_len: u32) void {
    const n = h.in.len;
    var p: usize = 0;
    while (p < n) {
        const max = maxLen(n, p);
        if (max >= 4) {
            var distance: u32 = 0;
            const len = hc.longestMatch(dictionary, h, @intCast(p), 2, max, params.nice, params.depth, &distance);
            if (worthIt(len, distance, min_len)) {
                c.addMatch(len, distance);
                skipInside(hc, h, p, len);
                p += len;
                c.maybeEnd(p);
                continue;
            }
        }
        c.literal(h.in[p]);
        p += 1;
        c.maybeEndLiteral(p);
    }
}

/// Insert the positions inside a match taken at `p`, as far as four bytes
/// remain to hash.
inline fn skipInside(hc: *match.HashChains, h: match.History, p: usize, len: u32) void {
    const n = h.in.len;
    if (n < 4) return;
    const last = n - 4;
    if (p + 1 > last) return;
    hc.skip(h, @intCast(p + 1), @intCast(@min(len - 1, last - p)));
}

/// How much better a match is than another: four per byte of length, less
/// one per doubling of distance (its extra bits), as libraries of this
/// family weigh them.
inline fn score(len: u32, distance: u32) i32 {
    return 4 * @as(i32, @intCast(len)) - std.math.log2_int(u32, distance);
}

/// Levels 4-9: a match is held while the next position is searched, with
/// half the depth; a clearly better match there makes the held position a
/// literal. A match of `nice` bytes is taken at once.
pub fn lazy(comptime dictionary: bool, c: *Cursor, hc: *match.HashChains, h: match.History, params: Params, min_len: u32) void {
    const n = h.in.len;
    const look = @max(1, params.depth / 2);
    var p: usize = 0;
    while (p < n) {
        if (maxLen(n, p) < 4) {
            c.literal(h.in[p]);
            p += 1;
            c.maybeEndLiteral(p);
            continue;
        }
        var cur_dist: u32 = 0;
        var cur_len = hc.longestMatch(dictionary, h, @intCast(p), min_len - 1, maxLen(n, p), params.nice, params.depth, &cur_dist);
        if (!worthIt(cur_len, cur_dist, min_len)) {
            c.literal(h.in[p]);
            p += 1;
            c.maybeEndLiteral(p);
            continue;
        }
        while (cur_len < params.nice and p + 1 < n and maxLen(n, p + 1) >= 4) {
            var next_dist: u32 = 0;
            const next_len = hc.longestMatch(dictionary, h, @intCast(p + 1), cur_len - 1, maxLen(n, p + 1), params.nice, look, &next_dist);
            if (next_len < cur_len or score(next_len, next_dist) - score(cur_len, cur_dist) <= 2) {
                // `p + 1` is in the tables now; the rest of the match next.
                c.addMatch(cur_len, cur_dist);
                skipInside(hc, h, p + 1, cur_len - 1);
                p += cur_len;
                break;
            }
            c.literal(h.in[p]);
            p += 1;
            cur_len = next_len;
            cur_dist = next_dist;
        } else {
            c.addMatch(cur_len, cur_dist);
            skipInside(hc, h, p, cur_len);
            p += cur_len;
        }
        c.maybeEnd(p);
    }
}

/// Literals only.
pub fn huffmanOnly(c: *Cursor) void {
    for (c.b.in, 0..) |byte, p| {
        c.literal(byte);
        c.maybeEndLiteral(p + 1);
    }
}

/// Runs: matches at distance one only.
pub fn rle(c: *Cursor) void {
    const in = c.b.in;
    var p: usize = 0;
    while (p < in.len) {
        if (p > 0 and in.len - p >= 3) {
            const max = maxLen(in.len, p);
            var len: u32 = 0;
            while (len < max and in[p + len] == in[p - 1]) len += 1;
            if (len >= 3) {
                c.addMatch(len, 1);
                p += len;
                c.maybeEnd(p);
                continue;
            }
        }
        c.literal(in[p]);
        p += 1;
        c.maybeEndLiteral(p);
    }
}
