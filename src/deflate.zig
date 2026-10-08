//! The DEFLATE (RFC 1951) encode engine: levels 0-12 and zlib's
//! strategies, into a bit writer, over a whole input at once or over a
//! streaming window that moves on.
//!
//! The engine parses positions into blocks and writes each block when it
//! ends. It stops wherever its caller asks (after a block, or where the
//! bytes at hand end) and resumes there, so the same input gives the same
//! bytes however it arrives.

const std = @import("std");
const bits = @import("bits.zig");
const match = @import("match.zig");
const block = @import("deflate/block.zig");
const parse_ = @import("deflate/parse.zig");
const optimal = @import("deflate/optimal.zig");

/// How matches are chosen, beside the level (zlib's strategies).
pub const Strategy = enum {
    default,
    /// Matches shorter than six bytes are not taken: for data that is
    /// mostly small, noisy values with some repetition, like PNG rows.
    filtered,
    /// No matches: Huffman codes over literals only.
    huffman_only,
    /// Matches at distance one only: runs.
    rle,
    /// No dynamic codes: blocks are fixed-code or stored.
    fixed,
};

/// The bytes past a position that searching it may read.
pub const lookahead = parse_.lookahead;

const Parser = enum { stored, fastest, greedy, lazy, optimal };

const Level = struct {
    parser: Parser,
    /// Chain links followed per search; a lazy parser's look at the next
    /// position follows half as many.
    depth: u32 = 0,
    /// A match this long ends a search, and is taken without looking past
    /// it.
    nice: u32 = 0,
    /// The near-optimal parser's search and passes.
    optimal: optimal.Params = undefined,
};

/// Each level's parser and search bounds. Levels 1-9: the least search
/// that keeps every level's output no larger than zlib's at that level, on
/// every kind of input in the size corpus and on the benchmark corpora.
/// Levels 10-12: the reference's near-optimal parse and its parameters.
const levels = [13]Level{
    .{ .parser = .stored },
    .{ .parser = .fastest },
    .{ .parser = .greedy, .depth = 6, .nice = 10 },
    .{ .parser = .greedy, .depth = 12, .nice = 14 },
    .{ .parser = .lazy, .depth = 8, .nice = 16 },
    .{ .parser = .lazy, .depth = 32, .nice = 64 },
    .{ .parser = .lazy, .depth = 96, .nice = 192 },
    .{ .parser = .lazy, .depth = 192, .nice = 258 },
    .{ .parser = .lazy, .depth = 1024, .nice = 258 },
    .{ .parser = .lazy, .depth = 4096, .nice = 258 },
    .{ .parser = .optimal, .optimal = .{ .depth = 35, .nice = 75, .passes = 2, .min_improvement = 32, .min_bits_earlier = 32, .fixed_max = 1000 } },
    .{ .parser = .optimal, .optimal = .{ .depth = 100, .nice = 150, .passes = 4, .min_improvement = 16, .min_bits_earlier = 16, .fixed_max = 1000 } },
    .{ .parser = .optimal, .optimal = .{ .depth = 300, .nice = 258, .passes = 10, .min_improvement = 1, .min_bits_earlier = 0, .fixed_max = 10000 } },
};

/// The near-optimal parser's blocks: the reference's length for a whole input,
/// a shorter one for a stream (its memory is per stream).
const optimal_block = 300_000;
const optimal_stream_block = 65536;
const min_block = 5000;

/// The table sizes' upper bounds, in bits.
const hash4_bits_max = 16;
const hash3_bits_max = 15;
const ht_bits_max = 15;
/// Sequences per block at most: blocks end when the buffer fills.
const sequences_max = 16384;
/// Level 1 ends a block at this many: its blocks are short, and so its
/// buffer.
const fast_sequences_max = 8192;

/// Which matchfinder a level uses.
pub const Finder = enum { none, table, chains, trees };

fn finder(level: u4, strategy: Strategy) Finder {
    if (levels[@min(level, 12)].parser == .stored) return .none;
    switch (strategy) {
        .huffman_only, .rle => return .none,
        else => {},
    }
    return switch (levels[@min(level, 12)].parser) {
        .stored => .none,
        .fastest => .table,
        .greedy, .lazy => .chains,
        .optimal => .trees,
    };
}

/// What the engine needs, in table sizes and buffer lengths.
pub const Sizes = struct {
    hash4_bits: u5 = 0,
    hash3_bits: u5 = 0,
    ht_bits: u5 = 0,
    short_bits: u5 = 0,
    tree_bits: u5 = 0,
    /// The farthest a match reaches, a power of two.
    window: usize = match.window,
    sequences: usize = 0,
    /// Literals kept apart from the input (streaming), at most.
    literals: usize = 0,
    table: bool = false,
    chains: bool = false,
    trees: bool = false,
    /// The near-optimal parser's matches kept and graph nodes (whose
    /// memory the sequences reuse), its block's length, and the bytes its
    /// statistics scan at a block's start.
    cache: usize = 0,
    nodes: usize = 0,
    block_max: usize = 0,
    scan: usize = 0,

    /// For whole inputs of at most `max_input` bytes (null: any) at `level`
    /// and `strategy`.
    pub fn of(level: u4, strategy: Strategy, max_input: ?usize) Sizes {
        const lv = levels[@min(level, 12)];
        const n = max_input orelse std.math.maxInt(usize);
        // Tables twice the input's size in entries, and at least 1 KiB.
        const fit: u5 = @intCast(@min(31, std.math.log2_int_ceil(usize, @max(n, 2)) + 1));
        var s: Sizes = .{};
        if (lv.parser == .stored) return s;
        const most: usize = if (lv.parser == .fastest) fast_sequences_max else sequences_max;
        s.sequences = @min(most, n / 3 + 2);
        switch (finder(level, strategy)) {
            .none => {},
            .table => {
                s.table = true;
                s.ht_bits = @max(10, @min(ht_bits_max, fit));
                s.short_bits = s.ht_bits - 4;
            },
            .chains => {
                s.chains = true;
                s.hash4_bits = @max(10, @min(hash4_bits_max, fit));
                s.hash3_bits = @max(10, @min(hash3_bits_max, fit));
            },
            .trees => {
                s.trees = true;
                s.tree_bits = @intCast(@max(10, @min(16, @as(u6, fit) + 2)));
                s.optimalSizes(optimal_block, @min(n, optimal_block + min_block + match.max_match), 4096);
            },
        }
        return s;
    }

    /// The near-optimal parser's: blocks of `block_max`, at most `longest`
    /// bytes long.
    fn optimalSizes(s: *Sizes, block_max: usize, longest: usize, scan: usize) void {
        s.block_max = block_max;
        s.scan = scan;
        s.nodes = longest + match.max_match + 1;
        // Five matches a position on average; a block
        // ends when they are kept. Past that, room for one position's
        // matches and a long match's skipped positions.
        s.cache = @min(5 * block_max, longest * (match.BinaryTrees.max_matches + 1)) + match.BinaryTrees.max_matches + match.max_match;
        s.sequences = 0;
    }

    /// The matches a near-optimal block keeps before it ends.
    pub fn cacheLimit(s: Sizes) usize {
        return s.cache - match.BinaryTrees.max_matches - match.max_match;
    }

    /// For a stream over a window of 2^`window_bits` with hash tables of
    /// 2^`hash_bits` entries, whose level may change to any of 1-9, or of
    /// 1-12 with `optimal`: every matchfinder those levels use, in one
    /// region.
    pub fn stream(window_bits: u4, hash_bits: u5, with_optimal: bool) Sizes {
        const window = @as(usize, 1) << window_bits;
        var s: Sizes = .{
            .hash4_bits = hash_bits,
            .hash3_bits = hash_bits - 2,
            .ht_bits = hash_bits,
            .short_bits = hash_bits - 4,
            .window = window,
            // Blocks of up to 4,096 matches and 16 KiB of literals (zlib's
            // 16,384 symbols at its default memLevel), less in a small
            // window.
            .sequences = @min(4096, @max(512, window / 2)),
            .literals = @min(16384, @max(4096, window * 4)),
            .table = true,
            .chains = true,
        };
        if (with_optimal) {
            const sequences = s.sequences;
            s.trees = true;
            s.tree_bits = hash_bits;
            const block_max = @min(optimal_stream_block, window);
            const longest = @min(2 * window + lookahead, block_max + min_block + match.max_match);
            s.optimalSizes(block_max, longest, lookahead - 1);
            s.literals = @max(s.literals, longest);
            // The other levels' sequences lie over the nodes too.
            std.debug.assert(s.nodes >= sequences);
        }
        return s;
    }

    fn chainsMemory(s: Sizes) usize {
        return if (s.chains) match.HashChains.memory(s.hash4_bits, s.hash3_bits, s.window) else 0;
    }

    fn tableMemory(s: Sizes) usize {
        return if (s.table) match.HashTable.memory(s.ht_bits, s.short_bits) else 0;
    }

    fn treesMemory(s: Sizes) usize {
        return if (s.trees) match.BinaryTrees.memory(s.tree_bits, s.tree_bits, s.window) else 0;
    }

    /// The matchfinders share one region: one of them is in use at a time.
    fn finderMemory(s: Sizes) usize {
        return std.mem.alignForward(usize, @max(s.chainsMemory(), s.tableMemory(), s.treesMemory()), 64);
    }

    pub fn memory(s: Sizes) usize {
        const state: usize = if (s.nodes != 0) @sizeOf(optimal.State) else 0;
        return s.finderMemory() + state + s.sequences * @sizeOf(block.Sequence) + s.cache * @sizeOf(optimal.Match) + s.nodes * @sizeOf(optimal.Node) + s.literals;
    }
};

/// What a parse call is to do with the end of the bytes at hand.
pub const End = enum {
    /// More bytes follow: search only positions whose bytes are all here.
    more,
    /// Parse to the end and write the block there, not final (a flush).
    flush,
    /// Parse to the end and write the final block.
    final,
};

/// Whether a parse call wrote a block and should be called again, or
/// parsed everything it could.
pub const Progress = enum { block, done };

/// The engine's tables, in memory the caller gives, and the parse.
pub const Engine = struct {
    sizes: Sizes,
    hc: match.HashChains,
    ht: match.HashTable,
    bt: match.BinaryTrees,
    /// Present in caller storage only when near-optimal parsing is available.
    opt: *optimal.State,
    b: parse_.Builder,
    level: Level = levels[6],
    strategy: Strategy = .default,
    /// The matchfinder in use.
    finder: Finder = .none,
    /// The stream's first byte: a run never reaches before it.
    first: usize = 0,
    /// The history's positions before this are in the matchfinder; the
    /// last few wait for the input's first bytes, which their hashes read.
    primed: isize = 0,

    /// Lay the tables out in `buffer` (`buffer.len >= sizes.memory()`).
    pub fn init(buffer: []align(64) u8, sizes: Sizes) Engine {
        var e: Engine = .{ .sizes = sizes, .hc = undefined, .ht = undefined, .bt = undefined, .opt = undefined, .b = .{ .seqs = &.{} } };
        // The matchfinders overlap: one is in use at a time.
        if (sizes.chains) {
            var at: usize = 0;
            e.hc = .{
                .prev = take(i16, buffer, &at, sizes.window),
                .hash4 = take(i16, buffer, &at, @as(usize, 1) << sizes.hash4_bits),
                .hash3 = take(i16, buffer, &at, @as(usize, 1) << sizes.hash3_bits),
            };
        }
        if (sizes.table) {
            var at: usize = 0;
            e.ht = .{
                .table = take([2]i16, buffer, &at, @as(usize, 1) << sizes.ht_bits),
                .short = take(i16, buffer, &at, @as(usize, 1) << sizes.short_bits),
                .window = @intCast(sizes.window),
            };
        }
        if (sizes.trees) {
            var at: usize = 0;
            e.bt = .{
                .hash3 = take([2]i16, buffer, &at, @as(usize, 1) << sizes.tree_bits),
                .hash4 = take(i16, buffer, &at, @as(usize, 1) << sizes.tree_bits),
                .child = take(i16, buffer, &at, 2 * sizes.window),
                .window = @intCast(sizes.window),
            };
        }
        var at = sizes.finderMemory();
        if (sizes.nodes != 0) {
            e.opt = &take(optimal.State, buffer, &at, 1)[0];
            const nodes = take(optimal.Node, buffer, &at, sizes.nodes);
            e.opt.* = .{
                .nodes = nodes,
                .cache = take(optimal.Match, buffer, &at, sizes.cache),
                .cache_limit = sizes.cacheLimit(),
                .block_max = sizes.block_max,
                .scan = sizes.scan,
            };
            // A block's sequences are made from its path, over the nodes'
            // memory (see `optimal.emitPath`); the other parsers' fit too.
            e.b.seqs = @as([*]block.Sequence, @ptrCast(nodes.ptr))[0..nodes.len]; // safe: two u32 and two u32-aligned u16 pairs, 8 bytes each
        } else e.b.seqs = take(block.Sequence, buffer, &at, sizes.sequences);
        e.b.lits = take(u8, buffer, &at, sizes.literals);
        return e;
    }

    fn take(comptime T: type, buf: []align(64) u8, offset: *usize, count: usize) []T {
        const bytes = buf[offset.*..][0 .. count * @sizeOf(T)];
        offset.* += bytes.len;
        return @alignCast(std.mem.bytesAsSlice(T, bytes)); // safe: every table starts at a multiple of 2 bytes in a 64-byte aligned buffer, and sequences at a multiple of 64
    }

    /// Start a stream at position `first` of `h` (a whole input, its
    /// dictionary before it at negative positions; or a streaming window,
    /// the history before `first`), at `level` and `strategy`. The tables
    /// in use are cleared as far as `fit` positions need.
    pub fn start(e: *Engine, h: match.History, first: usize, fit: usize, level: u4, strategy: Strategy) void {
        e.setLevel(level, strategy);
        e.b.restart(first);
        e.first = first;
        const lowest: isize = -@as(isize, @intCast(h.dict.len));
        // Tables twice the positions' count in entries, at least 1 KiB,
        // at most what was laid out.
        const fit_bits: u5 = @intCast(@max(10, @min(31, std.math.log2_int_ceil(usize, @max(fit, 2)) + 1)));
        switch (e.finder) {
            .none => {},
            .table => {
                const bits_ = @min(e.sizes.ht_bits, fit_bits);
                e.ht.reset(lowest, bits_, @min(e.sizes.short_bits, bits_));
            },
            .chains => e.hc.reset(lowest, @min(e.sizes.hash4_bits, fit_bits), @min(e.sizes.hash3_bits, fit_bits)),
            .trees => {
                // Four times the positions in entries: the trees keep
                // the reference's sizes on whole inputs, a small input clears
                // little.
                const bits_: u5 = @intCast(@min(e.sizes.tree_bits, @as(u6, fit_bits) + 2));
                e.bt.reset(lowest, bits_, bits_);
            },
        }
        if (e.sizes.nodes != 0) e.opt.restart(first);
        e.primed = lowest;
        e.prime(h, true);
    }

    /// The level and strategy from the next block on.
    pub fn setLevel(e: *Engine, level_in: u4, strategy: Strategy) void {
        std.debug.assert(finder(level_in, strategy) != .trees or e.sizes.nodes != 0);
        const level = level_in;
        e.level = levels[@min(level, 12)];
        e.strategy = strategy;
        e.finder = finder(level, strategy);
        e.b.kinds = if (e.level.parser == .stored) .stored_only else if (strategy == .fixed) .no_dynamic else if (e.level.parser == .optimal) .optimal else .any;
        if (e.finder == .trees) {
            e.opt.min_take = if (strategy == .filtered) 6 else match.min_match;
            e.opt.fixed_only = strategy == .fixed;
        }
    }

    /// More cost-model iterations, without changing the level's search.
    pub fn setPasses(e: *Engine, passes: u32) void {
        std.debug.assert(passes > 0);
        if (e.level.parser != .optimal) return;
        e.level.optimal.passes = passes;
        e.level.optimal.min_improvement = 0;
        e.level.optimal.min_bits_earlier = 0;
    }

    /// Insert the history's positions not yet in the matchfinder, those
    /// with four bytes at hand to hash.
    fn prime(e: *Engine, h: match.History, final: bool) void {
        // The last positions before the stream hash bytes of it too; a tree
        // also compares the bytes after a position, which must all be here
        // (or the input end there) for the tree to come out the same.
        const reach: isize = if (e.finder != .trees) 4 else if (final) match.BinaryTrees.required else lookahead;
        const last: isize = @min(@as(isize, @intCast(e.first)) - 1, @as(isize, @intCast(h.in.len)) - reach);
        if (last < e.primed) return;
        const count: u32 = @intCast(last - e.primed + 1);
        switch (e.finder) {
            .none => {},
            .table => e.ht.prime(h, e.primed, count),
            .chains => e.hc.prime(h, e.primed, count),
            .trees => e.bt.prime(h, e.primed, count, e.level.optimal.depth),
        }
        e.primed = last + 1;
    }

    /// Forget the history: no match reaches before the next position.
    pub fn forget(e: *Engine) void {
        switch (e.finder) {
            .none => {},
            .table => e.ht.forget(),
            .chains => e.hc.forget(),
            .trees => e.bt.forget(),
        }
        e.first = e.b.p;
        e.primed = @intCast(e.b.p);
    }

    /// The bytes moved back `n`: a streaming window slid.
    pub fn slide(e: *Engine, n: usize) void {
        e.b.slide(n);
        e.first -|= n;
        // Positions that slide out unprimed are gone.
        e.primed = @max(0, e.primed - @as(isize, @intCast(n)));
        if (e.sizes.nodes != 0) e.opt.slide(n);
        switch (e.finder) {
            .none => {},
            .table => e.ht.slide(n),
            .chains => e.hc.slide(n),
            .trees => e.bt.slide(n),
        }
    }

    /// Parse from where the last call stopped, writing blocks to `w`; stop
    /// after a block, or where `end` says. With `keep_literals` the
    /// literals are kept apart (the bytes will move on before a block is
    /// written).
    pub fn parse(e: *Engine, comptime keep_literals: bool, h: match.History, w: *bits.Writer, end: End) Progress {
        if (e.primed < e.first) e.prime(h, end != .more);
        var c: parse_.Cursor(keep_literals) = .init(&e.b, w, h.in, end != .more);
        defer c.save();
        e.b.ended = false;
        // Without a dictionary every position is in the input, and its
        // loads need no check; over the full window the chains' mask is a
        // constant.
        const full = e.sizes.window == match.window;
        if (h.dict.len != 0) {
            e.run(true, true, &c, h);
        } else if (full) e.run(false, true, &c, h) else e.run(false, false, &c, h);
        if (e.b.ended) return .block;
        if (e.level.parser == .optimal and e.strategy != .huffman_only and e.strategy != .rle) {
            if (end != .more) optimal.finish(&c, e.opt, h, end == .final, e.level.optimal);
            return .done;
        }
        switch (end) {
            .more => {},
            .flush => if (@as(isize, @intCast(e.b.p)) > e.b.start) c.write(e.b.p, false),
            .final => c.write(e.b.p, true),
        }
        return .done;
    }

    /// Write the block in the making at the parse position, not final.
    pub fn endBlock(e: *Engine, w: *bits.Writer, h: match.History) void {
        var c: parse_.Cursor(true) = .init(&e.b, w, h.in, false);
        defer c.save();
        if (e.level.parser == .optimal and e.strategy != .huffman_only and e.strategy != .rle) {
            optimal.finish(&c, e.opt, h, false, e.level.optimal);
        } else if (@as(isize, @intCast(e.b.p)) > e.b.start) c.write(e.b.p, false);
    }

    fn run(e: *Engine, comptime dictionary: bool, comptime full_window: bool, c: anytype, h: match.History) void {
        const lv = e.level;
        const params: parse_.Params = .{ .depth = lv.depth, .nice = lv.nice };
        const min_len: u32 = if (e.strategy == .filtered) 6 else 3;
        // Level 0 stores, whatever the strategy.
        if (lv.parser == .stored) return parse_.stored(c);
        switch (e.strategy) {
            .huffman_only => return parse_.huffmanOnly(c, h),
            .rle => return parse_.rle(c, h, e.first),
            .default, .filtered, .fixed => {},
        }
        switch (lv.parser) {
            .stored => unreachable,
            .fastest => parse_.fastest(dictionary, full_window, c, &e.ht, h),
            .greedy => parse_.greedy(dictionary, full_window, c, &e.hc, h, params, min_len),
            .lazy => parse_.lazy(dictionary, full_window, c, &e.hc, h, params, min_len),
            .optimal => optimal.parse(dictionary, full_window, c, e.opt, &e.bt, h, lv.optimal),
        }
    }

    /// One complete raw DEFLATE stream of `in` into `w`, whose matches may
    /// reach into the last 32 KiB of `dictionary`.
    pub fn compressPasses(e: *Engine, in: []const u8, dictionary: []const u8, w: *bits.Writer, level: u4, strategy: Strategy, passes: ?u32) void {
        const h: match.History = .{ .in = in, .dict = dictionary[dictionary.len -| match.window..] };
        // Small inputs use the tables' first entries only.
        e.start(h, 0, in.len + h.dict.len, level, strategy);
        if (passes) |n| e.setPasses(n);
        if (dictionary.len == 0 and e.level.parser == .optimal and
            strategy != .rle and strategy != .huffman_only and e.periodic(in, w)) return;
        while (e.parse(false, h, w, .final) == .block) {}
    }

    /// A verified short period needs no graph search. Keep its identical
    /// matches in one block rather than adding headers at graph boundaries.
    fn periodic(e: *Engine, in: []const u8, w: *bits.Writer) bool {
        if (in.len < 512) return false;
        const sample = in[0..@min(in.len, 1024)];
        var period: usize = 0;
        for (1..301) |n| {
            if (!std.mem.eql(u8, sample[n..], sample[0 .. sample.len - n])) continue;
            if (!std.mem.eql(u8, in[n..], in[0 .. in.len - n])) continue;
            period = n;
            break;
        }
        if (period == 0) return false;
        var c: parse_.Cursor(false) = .init(&e.b, w, in, true);
        for (in[0..period]) |byte| c.literalUnobserved(byte);
        var at = period;
        const min_len: usize = if (e.strategy == .filtered) 6 else 3;
        while (in.len - at >= min_len) {
            const length = @min(match.max_match, in.len - at);
            c.matchUnobserved(@intCast(length), @intCast(period));
            at += length;
            if (e.b.n == e.b.seqs.len and at < in.len) c.write(at, false);
        }
        for (in[at..]) |byte| c.literalUnobserved(byte);
        c.write(in.len, true);
        return true;
    }
};
