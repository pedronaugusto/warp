//! The DEFLATE (RFC 1951) encode engine: a whole input at once, at levels
//! 0-12 and with zlib's strategies, into a bit writer.

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

/// What the engine needs for `level` and `strategy`, sized for inputs of
/// at most `max_input` bytes (null: any).
pub const Sizes = struct {
    hash4_bits: u5 = 0,
    hash3_bits: u5 = 0,
    ht_bits: u5 = 0,
    short_bits: u5 = 0,
    sequences: usize = 0,
    chains: bool = false,

    pub fn of(level: u4, strategy: Strategy, max_input: ?usize) Sizes {
        const lv = levels[@min(level, 12)];
        const n = max_input orelse std.math.maxInt(usize);
        // Tables twice the input's size in entries, and at least 1 KiB.
        const fit: u5 = @intCast(@min(31, std.math.log2_int_ceil(usize, @max(n, 2)) + 1));
        var s: Sizes = .{};
        if (lv.parser == .stored) return s;
        const most: usize = if (lv.parser == .fastest) fast_sequences_max else sequences_max;
        s.sequences = @min(most, n / 3 + 2);
        switch (strategy) {
            .huffman_only, .rle => return s,
            else => {},
        }
        if (lv.parser == .fastest) {
            s.ht_bits = @max(10, @min(ht_bits_max, fit));
            s.short_bits = s.ht_bits - 2;
        } else {
            s.chains = true;
            s.hash4_bits = @max(10, @min(hash4_bits_max, fit));
            s.hash3_bits = @max(10, @min(hash3_bits_max, fit));
        }
        return s;
    }

    pub fn memory(s: Sizes) usize {
        var total = s.sequences * @sizeOf(block.Sequence);
        if (s.chains) total += match.HashChains.memory(s.hash4_bits, s.hash3_bits);
        if (s.ht_bits != 0) total += match.HashTable.memory(s.ht_bits, s.short_bits);
        return total;
    }
};

/// The engine's tables, in memory the caller gives.
pub const Engine = struct {
    sizes: Sizes,
    seqs: []block.Sequence,
    hc: match.HashChains,
    ht: match.HashTable,

    /// Lay the tables out in `buffer` (`buffer.len >= sizes.memory()`).
    pub fn init(buffer: []align(64) u8, sizes: Sizes) Engine {
        var at: usize = 0;
        const Take = struct {
            fn take(comptime T: type, buf: []align(64) u8, offset: *usize, count: usize) []T {
                const bytes = buf[offset.*..][0 .. count * @sizeOf(T)];
                offset.* += bytes.len;
                return @alignCast(std.mem.bytesAsSlice(T, bytes)); // safe: every table starts at a multiple of 2 KiB in a 64-byte aligned buffer
            }
        };
        var e: Engine = .{ .sizes = sizes, .seqs = &.{}, .hc = undefined, .ht = undefined };
        if (sizes.chains) {
            e.hc = .{
                .prev = Take.take(i16, buffer, &at, match.window)[0..match.window],
                .hash4 = Take.take(i16, buffer, &at, @as(usize, 1) << sizes.hash4_bits),
                .hash3 = Take.take(i16, buffer, &at, @as(usize, 1) << sizes.hash3_bits),
            };
        }
        if (sizes.ht_bits != 0) e.ht = .{
            .table = Take.take([2]i16, buffer, &at, @as(usize, 1) << sizes.ht_bits),
            .short = Take.take(i16, buffer, &at, @as(usize, 1) << sizes.short_bits),
        };
        e.seqs = Take.take(block.Sequence, buffer, &at, sizes.sequences);
        return e;
    }

    /// One complete raw DEFLATE stream of `in` into `w`, whose matches may
    /// reach into the last 32 KiB of `dictionary`.
    pub fn compress(e: *Engine, in: []const u8, dictionary: []const u8, w: *bits.Writer, level: u4, strategy: Strategy) void {
        const lv = levels[@min(level, 12)];
        if (lv.parser == .stored) {
            block.writeStored(w, in, true);
            return;
        }
        const h: match.History = .{ .in = in, .dict = dictionary[dictionary.len -| match.window..] };
        var b: parse_.Builder = .{ .w = w, .in = in, .kinds = if (strategy == .fixed) .no_dynamic else .any, .seqs = e.seqs };
        var c: parse_.Cursor = .{ .b = &b };
        switch (strategy) {
            .huffman_only => parse_.huffmanOnly(&c),
            .rle => parse_.rle(&c),
            .default, .filtered, .fixed => {
                const min_len: u32 = if (strategy == .filtered) 6 else 3;
                // Small inputs use the tables' first entries only.
                const fit: u5 = @intCast(@min(31, std.math.log2_int_ceil(usize, @max(in.len + h.dict.len, 2)) + 1));
                const first: isize = -@as(isize, @intCast(h.dict.len));
                if (lv.parser == .fastest) {
                    const bits_ = @max(10, @min(e.sizes.ht_bits, fit));
                    e.ht.reset(first, bits_, @min(e.sizes.short_bits, bits_));
                    primeTable(&e.ht, h);
                } else {
                    e.hc.reset(first, @max(10, @min(e.sizes.hash4_bits, fit)), @max(10, @min(e.sizes.hash3_bits, fit)));
                    primeTable(&e.hc, h);
                }
                // Each parser twice: without a dictionary every position is in
                // the input, and its loads need no check.
                if (h.dict.len != 0) e.parse(true, &c, h, lv, min_len) else e.parse(false, &c, h, lv, min_len);
            },
        }
        c.finish();
    }

    fn parse(e: *Engine, comptime dictionary: bool, c: *parse_.Cursor, h: match.History, lv: Level, min_len: u32) void {
        const params: parse_.Params = .{ .depth = lv.depth, .nice = lv.nice };
        switch (lv.parser) {
            .fastest => parse_.fastest(dictionary, c, &e.ht, h),
            .greedy => parse_.greedy(dictionary, c, &e.hc, h, params, min_len),
            .lazy => parse_.lazy(dictionary, c, &e.hc, h, params, min_len),
            .stored => unreachable,
        }
    }
};

/// The dictionary's positions into a matchfinder, those with four bytes
/// to hash.
fn primeTable(table: anytype, h: match.History) void {
    if (h.dict.len == 0) return;
    const first: isize = -@as(isize, @intCast(h.dict.len));
    // Positions -3..-1 hash bytes of the input too.
    const last: isize = @min(-1, @as(isize, @intCast(h.in.len)) - 4);
    if (last < first) return;
    table.prime(h, first, @intCast(last - first + 1));
}
