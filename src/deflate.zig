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

const Parser = enum { stored, fastest, greedy, lazy };

const Level = struct {
    parser: Parser,
    /// Chain links followed per search; a lazy parser's look at the next
    /// position follows half as many.
    depth: u32 = 0,
    /// A match this long ends a search, and is taken without looking past
    /// it.
    nice: u32 = 0,
};

/// Each level's parser and search bounds: the least search that keeps
/// every level's output no larger than zlib's at that level, on every kind
/// of input in the size corpus and on the benchmark corpora. Levels 10-12
/// parse as 9 until their near-optimal parser exists.
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
    .{ .parser = .lazy, .depth = 4096, .nice = 258 },
    .{ .parser = .lazy, .depth = 4096, .nice = 258 },
    .{ .parser = .lazy, .depth = 4096, .nice = 258 },
};

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
pub const Finder = enum { none, table, chains };

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
    };
}

/// What the engine needs, in table sizes and buffer lengths.
pub const Sizes = struct {
    hash4_bits: u5 = 0,
    hash3_bits: u5 = 0,
    ht_bits: u5 = 0,
    short_bits: u5 = 0,
    /// The farthest a match reaches, a power of two.
    window: usize = match.window,
    sequences: usize = 0,
    /// Literals kept apart from the input (streaming), at most.
    literals: usize = 0,
    table: bool = false,
    chains: bool = false,

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
        }
        return s;
    }

    /// For a stream over a window of 2^`window_bits` with hash tables of
    /// 2^`hash_bits` entries, whose level may change to any of 1-9: every
    /// matchfinder those levels use, in one region.
    pub fn stream(window_bits: u4, hash_bits: u5) Sizes {
        const window = @as(usize, 1) << window_bits;
        return .{
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
    }

    fn chainsMemory(s: Sizes) usize {
        return if (s.chains) match.HashChains.memory(s.hash4_bits, s.hash3_bits, s.window) else 0;
    }

    fn tableMemory(s: Sizes) usize {
        return if (s.table) match.HashTable.memory(s.ht_bits, s.short_bits) else 0;
    }

    /// The matchfinders share one region: one of them is in use at a time.
    fn finderMemory(s: Sizes) usize {
        return std.mem.alignForward(usize, @max(s.chainsMemory(), s.tableMemory()), 64);
    }

    pub fn memory(s: Sizes) usize {
        return s.finderMemory() + s.sequences * @sizeOf(block.Sequence) + s.literals;
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
        var e: Engine = .{ .sizes = sizes, .hc = undefined, .ht = undefined, .b = .{ .seqs = &.{} } };
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
        var at = sizes.finderMemory();
        e.b.seqs = take(block.Sequence, buffer, &at, sizes.sequences);
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
        }
        e.primed = lowest;
        e.prime(h);
    }

    /// The level and strategy from the next block on.
    pub fn setLevel(e: *Engine, level: u4, strategy: Strategy) void {
        e.level = levels[@min(level, 12)];
        e.strategy = strategy;
        e.finder = finder(level, strategy);
        e.b.kinds = if (e.level.parser == .stored) .stored_only else if (strategy == .fixed) .no_dynamic else .any;
    }

    /// Insert the history's positions not yet in the matchfinder, those
    /// with four bytes at hand to hash.
    fn prime(e: *Engine, h: match.History) void {
        // The last positions before the stream hash bytes of it too.
        const last: isize = @min(@as(isize, @intCast(e.first)) - 1, @as(isize, @intCast(h.in.len)) - 4);
        if (last < e.primed) return;
        const count: u32 = @intCast(last - e.primed + 1);
        switch (e.finder) {
            .none => {},
            .table => e.ht.prime(h, e.primed, count),
            .chains => e.hc.prime(h, e.primed, count),
        }
        e.primed = last + 1;
    }

    /// Forget the history: no match reaches before the next position.
    pub fn forget(e: *Engine) void {
        switch (e.finder) {
            .none => {},
            .table => e.ht.forget(),
            .chains => e.hc.forget(),
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
        switch (e.finder) {
            .none => {},
            .table => e.ht.slide(n),
            .chains => e.hc.slide(n),
        }
    }

    /// Parse from where the last call stopped, writing blocks to `w`; stop
    /// after a block, or where `end` says. With `keep_literals` the
    /// literals are kept apart (the bytes will move on before a block is
    /// written).
    pub fn parse(e: *Engine, comptime keep_literals: bool, h: match.History, w: *bits.Writer, end: End) Progress {
        if (e.primed < e.first) e.prime(h);
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
        if (@as(isize, @intCast(e.b.p)) > e.b.start) c.write(e.b.p, false);
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
        }
    }

    /// One complete raw DEFLATE stream of `in` into `w`, whose matches may
    /// reach into the last 32 KiB of `dictionary`.
    pub fn compress(e: *Engine, in: []const u8, dictionary: []const u8, w: *bits.Writer, level: u4, strategy: Strategy) void {
        const h: match.History = .{ .in = in, .dict = dictionary[dictionary.len -| match.window..] };
        // Small inputs use the tables' first entries only.
        e.start(h, 0, in.len + h.dict.len, level, strategy);
        while (e.parse(false, h, w, .final) == .block) {}
    }
};
