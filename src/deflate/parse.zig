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
//!
//! Every parser stops and resumes at any position: where it is and a lazy
//! parser's held match are the builder's. A position is searched only when
//! every byte a match there may read is at hand (`lookahead` of them), or
//! the bytes end there: so a stream comes out the same however its input
//! arrives.

const std = @import("std");
const bits = @import("../bits.zig");
const match = @import("../match.zig");
const block = @import("block.zig");
const split = @import("split.zig");
const Splitter = split.Splitter;

/// The bytes past a position that searching it may read: the longest
/// match, the four bytes a hash of the last position inside it reads, and
/// the next position, which a lazy parser searches before deciding.
pub const lookahead = match.max_match + 4;

/// Literals a parser may add between two checks of a full block: the most
/// a run reaches before its check, and the most a lazy parser adds while it
/// holds a match.
const literal_slack = 1024;

/// A block in the making, and where the parse is: its sequences, its
/// literals when they are kept apart, its counts and split observations.
pub const Builder = struct {
    seqs: []block.Sequence,
    n: usize = 0,
    /// The block's literals as they are parsed, when the bytes will not
    /// stay at hand until the block is written (streaming).
    lits: []u8 = &.{},
    n_lits: usize = 0,
    counts: block.Counts = .{},
    split: Splitter = .{},
    kinds: block.Kinds = .any,
    /// The longest stored block (level 0).
    stored_max: usize = 65535,
    /// Where the block starts in the bytes; negative once a streaming
    /// window has moved past it.
    start: isize = 0,
    /// Literals since the last match, and symbols since the last split
    /// check.
    run: u32 = 0,
    pending: u32 = 0,
    /// The next position to parse.
    p: usize = 0,
    /// A lazy parser's match at `p`, held while the next position waits
    /// for its bytes; 0 for none.
    held_len: u32 = 0,
    held_dist: u32 = 0,
    /// A block was written since the parser started.
    ended: bool = false,

    /// Nor shorter than this, unless the input ends.
    const min_len = 5000;

    /// Start over at `p`, with nothing in the block.
    pub fn restart(b: *Builder, p: usize) void {
        b.n = 0;
        b.n_lits = 0;
        b.counts = .{};
        b.split.startBlock();
        b.start = @intCast(p);
        b.run = 0;
        b.pending = 0;
        b.p = p;
        b.held_len = 0;
        b.held_dist = 0;
    }

    /// The positions moved back `n`: the bytes slid by `n`.
    pub fn slide(b: *Builder, n: usize) void {
        b.p -= n;
        b.start -= @intCast(n);
    }
};

/// What a parser carries from symbol to symbol, in registers, over the
/// bytes `in`: `final` when they end there (the input's end, or a flush).
/// With `keep_literals` the literals are kept in the builder, as a
/// streaming window moves on before a block is written.
pub fn Cursor(comptime keep_literals: bool) type {
    return struct {
        b: *Builder,
        w: *bits.Writer,
        in: []const u8,
        final: bool,
        run: u32,
        pending: u32,

        const Self = @This();
        pub const keeps_literals = keep_literals;

        pub fn init(b: *Builder, w: *bits.Writer, in: []const u8, final: bool) Self {
            return .{ .b = b, .w = w, .in = in, .final = final, .run = b.run, .pending = b.pending };
        }

        /// Put the per-symbol state back in the builder.
        pub fn save(c: *const Self) void {
            c.b.run = c.run;
            c.b.pending = c.pending;
        }

        /// Positions before this may be searched.
        pub inline fn stop(c: *const Self) usize {
            return if (c.final) c.in.len else c.in.len -| (lookahead - 1);
        }

        pub inline fn literal(c: *Self, byte: u8) void {
            c.b.counts.literal(byte);
            c.b.split.literal(byte);
            c.keep(byte);
            c.run += 1;
            c.pending += 1;
        }

        /// A literal for the fastest parser, which does not split blocks
        /// by their statistics.
        pub inline fn literalUnobserved(c: *Self, byte: u8) void {
            c.b.counts.literal(byte);
            c.keep(byte);
            c.run += 1;
        }

        inline fn keep(c: *Self, byte: u8) void {
            if (!keep_literals) return;
            c.b.lits[c.b.n_lits] = byte;
            c.b.n_lits += 1;
        }

        pub inline fn matchUnobserved(c: *Self, length: u32, distance: u32) void {
            const b = c.b;
            b.counts.match(length, distance);
            b.seqs[b.n] = .{ .literals = c.run, .length = @intCast(length), .distance = @intCast(distance) };
            b.n += 1;
            c.run = 0;
        }

        pub inline fn addMatch(c: *Self, length: u32, distance: u32) void {
            const b = c.b;
            b.counts.match(length, distance);
            b.split.match(length);
            b.seqs[b.n] = .{ .literals = c.run, .length = @intCast(length), .distance = @intCast(distance) };
            b.n += 1;
            c.run = 0;
            c.pending += 1;
        }

        /// Whether the literals kept are near their room.
        inline fn literalsFull(c: *const Self) bool {
            return keep_literals and c.b.n_lits + literal_slack > c.b.lits.len;
        }

        /// The fastest parser's blocks: at most 64 KiB of input, or as many
        /// matches as the buffer holds, whichever comes first. Whether the
        /// block ended at `p`.
        pub inline fn maybeEndFast(c: *Self, p: usize) bool {
            const b = c.b;
            if (b.n >= b.seqs.len or @as(isize, @intCast(p)) - b.start >= 65535 or c.literalsFull()) {
                c.endBlock(p);
                return true;
            }
            return false;
        }

        /// End the block at `p` if it is full, long, or changing; whether
        /// it ended. Called after every match, and between matches every
        /// so many literals.
        pub inline fn maybeEnd(c: *Self, p: usize) bool {
            const b = c.b;
            if (b.n >= b.seqs.len or c.literalsFull()) {
                c.endBlock(p);
                return true;
            }
            if (c.pending < split.check_every) return false;
            c.pending = 0;
            const len: usize = @intCast(@as(isize, @intCast(p)) - b.start);
            if (len >= Builder.min_len and c.remaining(p) >= Builder.min_len and b.split.differs()) {
                c.endBlock(p);
                return true;
            }
            return false;
        }

        /// `maybeEnd` after a literal: only once enough symbols are pending.
        pub inline fn maybeEndLiteral(c: *Self, p: usize) bool {
            if (c.pending >= split.check_every) return c.maybeEnd(p);
            return false;
        }

        /// The bytes after `p`, as far as is known: unknown, so many,
        /// until the input ends.
        inline fn remaining(c: *const Self, p: usize) usize {
            return if (c.final) c.in.len - p else std.math.maxInt(usize);
        }

        fn endBlock(c: *Self, p: usize) void {
            c.write(p, false);
            c.b.ended = true;
        }

        /// Write the block ending at `p`, and start the next there.
        pub fn write(c: *Self, p: usize, final: bool) void {
            c.emit(p, final);
            c.b.restart(p);
        }

        /// Write the block from its start to `end` with what the builder
        /// holds (its sequences, counts and literals, and `run` literals
        /// after the last match); the next block starts at `end`, and the
        /// parse position and statistics are the parser's.
        pub fn emit(c: *Self, end: usize, final: bool) void {
            const b = c.b;
            const raw: ?[]const u8 = if (b.start >= 0) c.in[@intCast(b.start)..end] else null;
            const data: block.Data = .{ .bytes = if (keep_literals) b.lits[0..b.n_lits] else raw.?, .raw = raw };
            block.write(!keep_literals, c.w, data, b.seqs[0..b.n], c.run, &b.counts, final, b.kinds);
            b.n = 0;
            b.n_lits = 0;
            b.counts = .{};
            b.start = @intCast(end);
            c.run = 0;
            c.pending = 0;
        }
    };
}

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
pub fn fastest(comptime dictionary: bool, comptime full_window: bool, c: anytype, ht: *match.HashTable, h: match.History) void {
    const n = h.in.len;
    const stop = c.stop();
    var p = c.b.p;
    defer c.b.p = p;
    while (p < stop) {
        const max = maxLen(n, p);
        if (max >= 5) {
            var distance: u32 = 0;
            const len = ht.longestMatch(dictionary, full_window, h, @intCast(p), max, &distance);
            if (len >= 3) {
                c.matchUnobserved(len, distance);
                ht.skip(h, @intCast(p + 1), @intCast(@min(len - 1, n - 4 - p - 1 + 1)));
                p += len;
                if (c.maybeEndFast(p)) return;
                continue;
            }
        }
        c.literalUnobserved(h.in[p]);
        p += 1;
        if (c.maybeEndFast(p)) return;
    }
}

/// Levels 2-3 (and any level's parse under `filtered`, with `min_len` 6).
pub fn greedy(comptime dictionary: bool, comptime full_window: bool, c: anytype, hc: *match.HashChains, h: match.History, params: Params, min_len: u32) void {
    const n = h.in.len;
    const stop = c.stop();
    var p = c.b.p;
    defer c.b.p = p;
    while (p < stop) {
        const max = maxLen(n, p);
        if (max >= 4) {
            var distance: u32 = 0;
            const len = hc.longestMatch(dictionary, full_window, h, @intCast(p), 2, max, params.nice, params.depth, &distance);
            if (worthIt(len, distance, min_len)) {
                c.addMatch(len, distance);
                skipInside(full_window, hc, h, p, len);
                p += len;
                if (c.maybeEnd(p)) return;
                continue;
            }
        }
        c.literal(h.in[p]);
        p += 1;
        if (c.maybeEndLiteral(p)) return;
    }
}

/// Insert the positions inside a match taken at `p`, as far as four bytes
/// remain to hash.
inline fn skipInside(comptime full_window: bool, hc: *match.HashChains, h: match.History, p: usize, len: u32) void {
    const n = h.in.len;
    if (n < 4) return;
    const last = n - 4;
    if (p + 1 > last) return;
    hc.skip(full_window, h, @intCast(p + 1), @intCast(@min(len - 1, last - p)));
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
pub fn lazy(comptime dictionary: bool, comptime full_window: bool, c: anytype, hc: *match.HashChains, h: match.History, params: Params, min_len: u32) void {
    const n = h.in.len;
    const stop = c.stop();
    const look = @max(1, params.depth / 2);
    var p = c.b.p;
    var cur_len = c.b.held_len;
    var cur_dist = c.b.held_dist;
    defer {
        c.b.p = p;
        c.b.held_len = cur_len;
        c.b.held_dist = cur_dist;
    }
    while (true) {
        if (cur_len == 0) {
            if (p >= stop) return;
            if (maxLen(n, p) < 4) {
                c.literal(h.in[p]);
                p += 1;
                if (c.maybeEndLiteral(p)) return;
                continue;
            }
            cur_len = hc.longestMatch(dictionary, full_window, h, @intCast(p), min_len - 1, maxLen(n, p), params.nice, params.depth, &cur_dist);
            if (!worthIt(cur_len, cur_dist, min_len)) {
                cur_len = 0;
                c.literal(h.in[p]);
                p += 1;
                if (c.maybeEndLiteral(p)) return;
                continue;
            }
        }
        // A match is held at `p`: the next position may have a better one.
        if (cur_len < params.nice) {
            // Its bytes are not all here yet: hold the match until they are.
            if (p + 1 >= stop and !c.final) return;
            if (p + 1 < n and maxLen(n, p + 1) >= 4) {
                var next_dist: u32 = 0;
                const next_len = hc.longestMatch(dictionary, full_window, h, @intCast(p + 1), cur_len - 1, maxLen(n, p + 1), params.nice, look, &next_dist);
                if (next_len >= cur_len and score(next_len, next_dist) - score(cur_len, cur_dist) > 2) {
                    c.literal(h.in[p]);
                    p += 1;
                    cur_len = next_len;
                    cur_dist = next_dist;
                    continue;
                }
                // `p + 1` is in the tables now; the rest of the match next.
                c.addMatch(cur_len, cur_dist);
                skipInside(full_window, hc, h, p + 1, cur_len - 1);
                p += cur_len;
                cur_len = 0;
                if (c.maybeEnd(p)) return;
                continue;
            }
        }
        c.addMatch(cur_len, cur_dist);
        skipInside(full_window, hc, h, p, cur_len);
        p += cur_len;
        cur_len = 0;
        if (c.maybeEnd(p)) return;
    }
}

/// Literals only.
pub fn huffmanOnly(c: anytype, h: match.History) void {
    const stop = c.stop();
    var p = c.b.p;
    defer c.b.p = p;
    while (p < stop) {
        c.literal(h.in[p]);
        p += 1;
        if (c.maybeEndLiteral(p)) return;
    }
}

/// Runs: matches at distance one only, never reaching before `first`
/// (the stream's first byte).
pub fn rle(c: anytype, h: match.History, first: usize) void {
    const in = h.in;
    const stop = c.stop();
    var p = c.b.p;
    defer c.b.p = p;
    while (p < stop) {
        if (p > first and in.len - p >= 3) {
            const max = maxLen(in.len, p);
            var len: u32 = 0;
            while (len < max and in[p + len] == in[p - 1]) len += 1;
            if (len >= 3) {
                c.addMatch(len, 1);
                p += len;
                if (c.maybeEnd(p)) return;
                continue;
            }
        }
        c.literal(in[p]);
        p += 1;
        if (c.maybeEndLiteral(p)) return;
    }
}

/// Stored blocks only (level 0): the bytes as they are, a block every
/// 65,535.
pub fn stored(c: anytype) void {
    const stop = c.stop();
    var p = c.b.p;
    defer c.b.p = p;
    while (p < stop) {
        const start: usize = @intCast(c.b.start);
        p = @min(stop, start + c.b.stored_max);
        // The last block is the final one, however long.
        if (p - start == c.b.stored_max and p < c.in.len) {
            c.endBlock(p);
            return;
        }
    }
}
