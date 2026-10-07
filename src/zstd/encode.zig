//! The block encoder: a block's sequences and literals, as a matchfinder
//! left them in a `SeqStore`, entropy-coded into a compressed block, with
//! the choices the format's reference encoder makes: literals raw, RLE or
//! Huffman-coded in one or four streams (a new table or the previous one,
//! by exact size); each sequence code's table predefined, RLE, new or
//! repeated, by estimated cost; and the whole block abandoned for a raw
//! one when it saves too little.

const std = @import("std");
const Writer = @import("../bits.zig").Writer;
const fse = @import("fse.zig");
const huffman = @import("huffman.zig");
const codes = @import("codes.zig");

pub const block_max = 1 << 17;

/// How matches are searched, from fastest to strongest: the reference
/// encoder's strategies, numbered as it numbers them.
pub const Strategy = enum(u4) {
    fast = 1,
    dfast,
    greedy,
    lazy,
    lazy2,
    btlazy2,
    btopt,
    btultra,
    btultra2,
};

/// One sequence: literals, then a match. `off` is the format's offset
/// value: a repeat code 1-3 or the offset plus 3.
pub const Sequence = struct {
    off: u32,
    /// Literals before the match (the low 16 bits; see `SeqStore.long`).
    lit: u16,
    /// The match length less 3 (low 16 bits).
    ml: u16,
};

/// The sequences of one block and its literals.
pub const SeqStore = struct {
    seqs: []Sequence,
    count: usize = 0,
    lits: []u8,
    lit_len: usize = 0,
    /// The one sequence of a block whose literal or match length does not
    /// fit 16 bits (at most one can, a block being 128 KiB).
    long: ?Long = null,
    ll_codes: []u8,
    ml_codes: []u8,
    of_codes: []u8,

    pub const Long = struct { index: u32, match: bool };

    /// Room for a block of `block` bytes with matches of `min_match` or more.
    pub fn capacity(block: usize, min_match: u32) usize {
        return block / (if (min_match == 3) @as(usize, 3) else 4) + 1;
    }

    pub fn reset(s: *SeqStore) void {
        s.count = 0;
        s.lit_len = 0;
        s.long = null;
    }

    /// A sequence: `literals`, then a match of `match_len` with offset
    /// value `off`.
    pub inline fn store(s: *SeqStore, literals: []const u8, off: u32, match_len: usize) void {
        @memcpy(s.lits[s.lit_len..][0..literals.len], literals);
        s.lit_len += literals.len;
        if (literals.len > 0xffff) s.long = .{ .index = @intCast(s.count), .match = false };
        const ml = match_len - codes.min_match;
        if (ml > 0xffff) s.long = .{ .index = @intCast(s.count), .match = true };
        s.seqs[s.count] = .{ .off = off, .lit = @truncate(literals.len), .ml = @truncate(ml) };
        s.count += 1;
    }

    /// The literals after the last sequence.
    pub fn storeLast(s: *SeqStore, literals: []const u8) void {
        @memcpy(s.lits[s.lit_len..][0..literals.len], literals);
        s.lit_len += literals.len;
    }

    pub fn litLen(s: *const SeqStore, i: usize) u32 {
        const l: u32 = s.seqs[i].lit;
        if (s.long) |long| if (long.index == i and !long.match) return l + 0x10000;
        return l;
    }

    pub fn matchLen(s: *const SeqStore, i: usize) u32 {
        const m: u32 = s.seqs[i].ml;
        if (s.long) |long| if (long.index == i and long.match) return m + 0x10000;
        return m;
    }

    /// The three codes of every sequence.
    fn toCodes(s: *SeqStore) void {
        for (s.seqs[0..s.count], s.ll_codes[0..s.count], s.ml_codes[0..s.count], s.of_codes[0..s.count]) |q, *ll, *ml, *of| {
            ll.* = codes.llCode(q.lit);
            ml.* = codes.mlCode(@as(u32, q.ml) + codes.min_match);
            of.* = codes.ofCode(q.off);
        }
        if (s.long) |long| {
            if (long.match) s.ml_codes[long.index] = codes.max_ml else s.ll_codes[long.index] = codes.max_ll;
        }
    }
};

pub const Repeat = enum {
    /// No table to repeat.
    none,
    /// A table that may lack a symbol: checked before use.
    check,
    /// A table known to code every symbol (a dictionary's).
    valid,
};

pub const LlTable = fse.EncodeTable(codes.max_ll_log, codes.max_ll);
pub const OfTable = fse.EncodeTable(codes.max_of_log, codes.max_of);
pub const MlTable = fse.EncodeTable(codes.max_ml_log, codes.max_ml);

/// The tables a block leaves for the next to repeat.
pub const Entropy = struct {
    huf: huffman.EncodeTable,
    huf_repeat: Repeat = .none,
    ll: LlTable,
    of: OfTable,
    ml: MlTable,
    ll_repeat: Repeat = .none,
    of_repeat: Repeat = .none,
    ml_repeat: Repeat = .none,

    pub fn reset(e: *Entropy) void {
        e.huf_repeat = .none;
        e.ll_repeat = .none;
        e.of_repeat = .none;
        e.ml_repeat = .none;
    }
};

/// The bytes a block saves at least for its compressed form to be kept.
pub fn minGain(len: usize, strategy: Strategy) usize {
    const s = @intFromEnum(strategy);
    const log: u6 = if (s >= @intFromEnum(Strategy.btultra)) s - 1 else 6;
    return (len >> log) + 2;
}

/// Compress the block in `store` (its literals and sequences) into `out`,
/// starting from `prev`'s tables and leaving what it used in `next`.
/// Returns its size, or 0 when a raw block is smaller or as good.
/// `raw_literals` leaves literals uncoded (the negative levels, as the
/// reference encoder does).
pub fn compressBlock(store: *SeqStore, block_len: usize, prev: *const Entropy, next: *Entropy, strategy: Strategy, raw_literals: bool, out: []u8) usize {
    const size = entropyCode(store, prev, next, strategy, raw_literals, out) orelse return 0;
    if (size >= block_len - minGain(block_len, strategy)) return 0;
    return size;
}

fn entropyCode(store: *SeqStore, prev: *const Entropy, next: *Entropy, strategy: Strategy, raw_literals: bool, out: []u8) ?usize {
    const lits = store.lits[0..store.lit_len];
    const count = store.count;
    const suspect = count == 0 or lits.len / count >= 20;
    var o = if (raw_literals) blk: {
        next.huf = prev.huf;
        next.huf_repeat = prev.huf_repeat;
        break :blk rawLiterals(lits, out) orelse return null;
    } else compressLiterals(lits, out, prev, next, strategy, suspect) orelse return null;
    // Sequences header.
    if (out.len - o < 4) return null;
    if (count < 128) {
        out[o] = @intCast(count);
        o += 1;
    } else if (count < 0x7f00) {
        out[o] = @intCast((count >> 8) + 0x80);
        out[o + 1] = @truncate(count);
        o += 2;
    } else {
        out[o] = 0xff;
        std.mem.writeInt(u16, out[o + 1 ..][0..2], @intCast(count - 0x7f00), .little);
        o += 3;
    }
    if (count == 0) {
        next.ll = prev.ll;
        next.of = prev.of;
        next.ml = prev.ml;
        next.ll_repeat = prev.ll_repeat;
        next.of_repeat = prev.of_repeat;
        next.ml_repeat = prev.ml_repeat;
        return o;
    }
    store.toCodes();
    const modes_at = o;
    o += 1;
    var last_table: usize = 0;
    const ll = codeTable(LlTable, store.ll_codes[0..count], codes.max_ll, codes.max_ll_log, &codes.ll_default, codes.ll_default_log, true, &prev.ll, prev.ll_repeat, &next.ll, &next.ll_repeat, strategy, out[o..]) orelse return null;
    o += ll.len;
    if (ll.mode == .compressed) last_table = ll.len;
    const max_of = maxCode(store.of_codes[0..count]);
    const of = codeTable(OfTable, store.of_codes[0..count], codes.max_of, codes.max_of_log, &codes.of_default, codes.of_default_log, max_of <= 28, &prev.of, prev.of_repeat, &next.of, &next.of_repeat, strategy, out[o..]) orelse return null;
    o += of.len;
    if (of.mode == .compressed) last_table = of.len;
    const ml = codeTable(MlTable, store.ml_codes[0..count], codes.max_ml, codes.max_ml_log, &codes.ml_default, codes.ml_default_log, true, &prev.ml, prev.ml_repeat, &next.ml, &next.ml_repeat, strategy, out[o..]) orelse return null;
    o += ml.len;
    if (ml.mode == .compressed) last_table = ml.len;
    out[modes_at] = @as(u8, @intFromEnum(ll.mode)) << 6 | @as(u8, @intFromEnum(of.mode)) << 4 | @as(u8, @intFromEnum(ml.mode)) << 2;
    const stream = encodeSequences(store, &next.ll, &next.of, &next.ml, out[o..]) orelse return null;
    // Decoders up to zstd 1.3.4 refuse a last table description shorter
    // than 4 bytes with the stream; the reference sends such a block raw.
    if (last_table != 0 and last_table + stream < 4) return null;
    return o + stream;
}

fn maxCode(c: []const u8) u8 {
    var m: u8 = 0;
    for (c) |x| m = @max(m, x);
    return m;
}

// ---- literals ----

fn rawLiterals(lits: []const u8, out: []u8) ?usize {
    const header: usize = 1 + @as(usize, @intFromBool(lits.len > 31)) + @intFromBool(lits.len > 4095);
    if (lits.len + header > out.len) return null;
    switch (header) {
        1 => out[0] = @intCast(lits.len << 3),
        2 => std.mem.writeInt(u16, out[0..2], @intCast(1 << 2 | lits.len << 4), .little),
        else => std.mem.writeInt(u24, out[0..3], @intCast(3 << 2 | lits.len << 4), .little),
    }
    @memcpy(out[header..][0..lits.len], lits);
    return header + lits.len;
}

fn rleLiterals(lits: []const u8, out: []u8) ?usize {
    const header: usize = 1 + @as(usize, @intFromBool(lits.len > 31)) + @intFromBool(lits.len > 4095);
    if (out.len < header + 1) return null;
    switch (header) {
        1 => out[0] = @intCast(1 | lits.len << 3),
        2 => std.mem.writeInt(u16, out[0..2], @intCast(1 | 1 << 2 | lits.len << 4), .little),
        else => std.mem.writeInt(u24, out[0..3], @intCast(1 | 3 << 2 | lits.len << 4), .little),
    }
    out[header] = lits[0];
    return header + 1;
}

fn allSame(bytes: []const u8) bool {
    for (bytes[1..]) |b| if (b != bytes[0]) return false;
    return true;
}

/// The literals section; `next` gets the Huffman table the block leaves.
fn compressLiterals(lits: []const u8, out: []u8, prev: *const Entropy, next: *Entropy, strategy: Strategy, suspect: bool) ?usize {
    next.huf = prev.huf;
    next.huf_repeat = prev.huf_repeat;
    const s = @intFromEnum(strategy);
    const min_len: usize = if (prev.huf_repeat == .valid) 6 else @as(usize, 8) << @intCast(@min(9 - s, 3));
    if (lits.len < min_len) return rawLiterals(lits, out);
    const header: usize = 3 + @as(usize, @intFromBool(lits.len >= 1024)) + @intFromBool(lits.len >= 16 * 1024);
    if (out.len < header + 1) return null;
    var single = lits.len < 256;
    if (prev.huf_repeat == .valid and header == 3) single = true;
    const prefer_repeat = s < @intFromEnum(Strategy.lazy) and lits.len <= 1024;
    const optimal_depth = s >= @intFromEnum(Strategy.btultra);
    var repeat = prev.huf_repeat;
    const result = huffmanLiterals(lits, out[header..], &prev.huf, &next.huf, &repeat, single, prefer_repeat, optimal_depth, suspect);
    const size = result orelse 0;
    const kind: u32 = if (repeat != .none) 3 else 2;
    if (size == 0 or size >= lits.len - minGain(lits.len, strategy)) {
        next.huf = prev.huf;
        next.huf_repeat = prev.huf_repeat;
        return rawLiterals(lits, out);
    }
    if (size == 1) {
        if (lits.len >= 8 or allSame(lits)) {
            next.huf = prev.huf;
            next.huf_repeat = prev.huf_repeat;
            return rleLiterals(lits, out);
        }
    }
    if (kind == 2) next.huf_repeat = .check;
    const streams: u32 = if (single) 0 else 1;
    switch (header) {
        3 => std.mem.writeInt(u24, out[0..3], @intCast(kind | streams << 2 | @as(u32, @intCast(lits.len)) << 4 | @as(u32, @intCast(size)) << 14), .little),
        4 => std.mem.writeInt(u32, out[0..4], kind | 2 << 2 | @as(u32, @intCast(lits.len)) << 4 | @as(u32, @intCast(size)) << 18, .little),
        else => {
            std.mem.writeInt(u32, out[0..4], kind | 3 << 2 | @as(u32, @intCast(lits.len)) << 4 | @as(u32, @truncate(size << 22)), .little);
            out[4] = @intCast(size >> 10);
        },
    }
    return header + size;
}

/// Huffman-coded literals: the previous table when it is at least as
/// good, else a new one (written in front). Returns the bytes written, 1
/// for "one symbol" (RLE), or null/0 when not worth coding; `repeat` says
/// whether the previous table was used (not `.none`).
fn huffmanLiterals(
    lits: []const u8,
    out: []u8,
    old: *const huffman.EncodeTable,
    new: *huffman.EncodeTable,
    repeat: *Repeat,
    single: bool,
    prefer_repeat: bool,
    optimal_depth: bool,
    suspect: bool,
) ?usize {
    if (lits.len == 0 or out.len == 0) return null;
    if (prefer_repeat and repeat.* == .valid) return withTable(old, lits, out, 0, single);
    if (suspect and lits.len >= 4096 * 10) {
        var c: [huffman.max_symbols]u32 = undefined;
        const begin = huffman.histogram(lits[0..4096], &c).largest;
        const end = huffman.histogram(lits[lits.len - 4096 ..], &c).largest;
        if (begin + end <= ((2 * 4096) >> 7) + 4) return null;
    }
    var counts: [huffman.max_symbols]u32 = undefined;
    const h = huffman.histogram(lits, &counts);
    if (h.largest == lits.len) {
        out[0] = lits[0];
        return 1;
    }
    if (h.largest <= (lits.len >> 7) + 4) return null;
    const used = counts[0 .. @as(usize, h.max_symbol) + 1];
    if (repeat.* == .check and !old.covers(used)) repeat.* = .none;
    if (prefer_repeat and repeat.* != .none) return withTable(old, lits, out, 0, single);
    var table: huffman.EncodeTable = undefined;
    const log = if (optimal_depth) optimalDepth(used, lits.len, &table) else huffman.optimalLog(huffman.encode_log, lits.len, h.max_symbol);
    table.build(used, log);
    const header = table.writeDescription(out) orelse return null;
    if (repeat.* != .none) {
        const old_size = old.estimate(used);
        const new_size = table.estimate(used);
        if (old_size <= header + new_size or header + 12 >= lits.len) return withTable(old, lits, out, 0, single);
    }
    if (header + 12 >= lits.len) return null;
    repeat.* = .none;
    new.* = table;
    return withTable(new, lits, out, header, single);
}

/// The table log that makes description plus data smallest, searched up
/// from the smallest that holds every symbol (the strongest strategies).
fn optimalDepth(counts: []const u32, len: usize, scratch: *huffman.EncodeTable) u4 {
    var symbols: u32 = 0;
    for (counts) |c| symbols += @intFromBool(c != 0);
    const min: u4 = @intCast(std.math.log2_int(u32, symbols) + 1);
    var best: usize = std.math.maxInt(usize) - 1;
    var best_log: u4 = huffman.encode_log;
    var buf: [256]u8 = undefined;
    var log = min;
    while (log <= huffman.encode_log) : (log += 1) {
        scratch.build(counts, log);
        if (scratch.log < log and log > min) break;
        const header = scratch.writeDescription(&buf) orelse continue;
        const size = scratch.estimate(counts) + header;
        if (size > best + 1) break;
        if (size < best) {
            best = size;
            best_log = log;
        }
    }
    _ = len;
    return best_log;
}

fn withTable(table: *const huffman.EncodeTable, lits: []const u8, out: []u8, header: usize, single: bool) ?usize {
    const n = if (single) huffman.compress1(table, lits, out[header..]) else huffman.compress4(table, lits, out[header..]);
    if (n == 0) return null;
    if (header + n >= lits.len - 1) return null;
    return header + n;
}

// ---- sequences ----

pub const Mode = enum(u2) { predefined, rle, compressed, repeat };

const TableResult = struct { mode: Mode, len: usize };

/// Choose and write one code's table: predefined, RLE, compressed (a new
/// description) or repeated.
fn codeTable(
    comptime T: type,
    symbols: []const u8,
    max: u8,
    max_log: u4,
    default_norm: []const i16,
    default_log: u4,
    default_allowed: bool,
    prev: *const T,
    prev_repeat: Repeat,
    next: *T,
    next_repeat: *Repeat,
    strategy: Strategy,
    out: []u8,
) ?TableResult {
    var counts: [64]u32 = @splat(0);
    for (symbols) |sym| counts[sym] += 1;
    var top: u8 = 0;
    var most: u32 = 0;
    for (counts[0 .. @as(usize, max) + 1], 0..) |c, sym| {
        if (c != 0) top = @intCast(sym);
        most = @max(most, c);
    }
    const used = counts[0 .. @as(usize, top) + 1];
    var repeat = prev_repeat;
    const mode = selectMode(&repeat, used, most, symbols.len, max_log, prev, default_norm, default_log, default_allowed, strategy);
    next_repeat.* = repeat;
    switch (mode) {
        .rle => {
            if (out.len == 0) return null;
            next.rle(top);
            out[0] = top;
            return .{ .mode = .rle, .len = 1 };
        },
        .repeat => {
            next.* = prev.*;
            return .{ .mode = .repeat, .len = 0 };
        },
        .predefined => {
            next.build(default_norm, default_log);
            return .{ .mode = .predefined, .len = 0 };
        },
        .compressed => {
            var total = symbols.len;
            // The last symbol is the state's start, coded for free.
            const last = symbols[symbols.len - 1];
            if (counts[last] > 1) {
                counts[last] -= 1;
                total -= 1;
            }
            const log = fse.optimalLog(max_log, symbols.len, top, 2);
            var norm: [64]i16 = undefined;
            fse.normalize(norm[0..used.len], log, used, total, total >= 2048) catch return null;
            if (out.len < fse.countsBound(top, log)) return null;
            const n = fse.writeCounts(out, norm[0..used.len], log);
            next.build(norm[0..used.len], log);
            return .{ .mode = .compressed, .len = n };
        },
    }
}

const inverse_probability_log256 = [256]u32{
    0,    2048, 1792, 1642, 1536, 1453, 1386, 1329, 1280, 1236, 1197, 1162, 1130, 1100, 1073, 1047,
    1024, 1001, 980,  960,  941,  923,  906,  889,  874,  859,  844,  830,  817,  804,  791,  779,
    768,  756,  745,  734,  724,  714,  704,  694,  685,  676,  667,  658,  650,  642,  633,  626,
    618,  610,  603,  595,  588,  581,  574,  567,  561,  554,  548,  542,  535,  529,  523,  517,
    512,  506,  500,  495,  489,  484,  478,  473,  468,  463,  458,  453,  448,  443,  438,  434,
    429,  424,  420,  415,  411,  407,  402,  398,  394,  390,  386,  382,  377,  373,  370,  366,
    362,  358,  354,  350,  347,  343,  339,  336,  332,  329,  325,  322,  318,  315,  311,  308,
    305,  302,  298,  295,  292,  289,  286,  282,  279,  276,  273,  270,  267,  264,  261,  258,
    256,  253,  250,  247,  244,  241,  239,  236,  233,  230,  228,  225,  222,  220,  217,  215,
    212,  209,  207,  204,  202,  199,  197,  194,  192,  190,  187,  185,  182,  180,  178,  175,
    173,  171,  168,  166,  164,  162,  159,  157,  155,  153,  151,  149,  146,  144,  142,  140,
    138,  136,  134,  132,  130,  128,  126,  123,  121,  119,  117,  115,  114,  112,  110,  108,
    106,  104,  102,  100,  98,   96,   94,   93,   91,   89,   87,   85,   83,   82,   80,   78,
    76,   74,   73,   71,   69,   67,   66,   64,   62,   61,   59,   57,   55,   54,   52,   50,
    49,   47,   46,   44,   42,   41,   39,   37,   36,   34,   33,   31,   30,   28,   26,   25,
    23,   22,   20,   19,   17,   16,   14,   13,   11,   10,   8,    7,    5,    4,    2,    1,
};

/// The reference encoder's choice of table mode.
fn selectMode(
    repeat: *Repeat,
    counts: []const u32,
    most: u32,
    total: usize,
    max_log: u4,
    prev: anytype,
    default_norm: []const i16,
    default_log: u4,
    default_allowed: bool,
    strategy: Strategy,
) Mode {
    if (most == total) {
        repeat.* = .none;
        if (default_allowed and total <= 2) return .predefined;
        return .rle;
    }
    const s = @intFromEnum(strategy);
    if (s < @intFromEnum(Strategy.lazy)) {
        if (default_allowed) {
            const mult: usize = 10 - @as(usize, s);
            const dynamic_min = ((@as(usize, 1) << default_log) * mult) >> 3;
            if (repeat.* == .valid and total < 1000) return .repeat;
            if (total < dynamic_min or most < (total >> @intCast(default_log - 1))) {
                repeat.* = .none;
                return .predefined;
            }
        }
    } else {
        const max_cost = std.math.maxInt(usize);
        const basic = if (default_allowed) crossEntropyCost(default_norm, default_log, counts) else max_cost;
        const repeated = if (repeat.* != .none) fseBitCost(prev, counts) orelse max_cost else max_cost;
        const compressed = (descriptionCost(counts, total, max_log) << 3) + entropyCost(counts, total);
        if (basic <= repeated and basic <= compressed) {
            repeat.* = .none;
            return .predefined;
        }
        if (repeated <= compressed) return .repeat;
    }
    repeat.* = .check;
    return .compressed;
}

fn crossEntropyCost(norm: []const i16, log: u4, counts: []const u32) usize {
    const shift: u3 = @intCast(8 - @as(u4, log));
    var cost: usize = 0;
    for (counts, 0..) |c, sym| {
        const n: u32 = if (sym < norm.len and norm[sym] != -1) @intCast(norm[sym]) else 1;
        cost += @as(usize, c) * inverse_probability_log256[n << shift];
    }
    return cost >> 8;
}

fn fseBitCost(table: anytype, counts: []const u32) ?usize {
    if (counts.len - 1 > table.symbols) return null;
    var cost: usize = 0;
    for (counts, 0..) |c, sym| {
        if (c == 0) continue;
        const bit = table.bitCost(@intCast(sym)) orelse return null;
        cost += @as(usize, c) * bit;
    }
    return cost >> 8;
}

fn entropyCost(counts: []const u32, total: usize) usize {
    var cost: usize = 0;
    for (counts) |c| {
        var norm: usize = (256 * @as(usize, c)) / total;
        if (c != 0 and norm == 0) norm = 1;
        cost += @as(usize, c) * inverse_probability_log256[norm];
    }
    return cost >> 8;
}

fn descriptionCost(counts: []const u32, total: usize, max_log: u4) usize {
    const top: u8 = @intCast(counts.len - 1);
    const log = fse.optimalLog(max_log, total, top, 2);
    var norm: [64]i16 = undefined;
    fse.normalize(norm[0..counts.len], log, counts, total, total >= 2048) catch return std.math.maxInt(usize) >> 4;
    var buf: [128]u8 = undefined;
    return fse.writeCounts(&buf, norm[0..counts.len], log);
}

/// The sequences bitstream: last sequence first, so the decoder reads the
/// first first.
fn encodeSequences(store: *const SeqStore, ll_table: *const LlTable, of_table: *const OfTable, ml_table: *const MlTable, out: []u8) ?usize {
    const n = store.count;
    if (out.len < 8) return null;
    var w: Writer = .init(out, 0);
    const last = n - 1;
    var ll_state = ll_table.initState(store.ll_codes[last]);
    var ml_state = ml_table.initState(store.ml_codes[last]);
    var of_state = of_table.initState(store.of_codes[last]);
    extraBits(&w, store, last);
    var i = last;
    while (i > 0) {
        i -= 1;
        const llc = store.ll_codes[i];
        const ofc = store.of_codes[i];
        const mlc = store.ml_codes[i];
        huffman.encodeFse(&w, of_table, &of_state, ofc);
        huffman.encodeFse(&w, ml_table, &ml_state, mlc);
        huffman.encodeFse(&w, ll_table, &ll_state, llc);
        w.flush();
        extraBits(&w, store, i);
    }
    flushState(&w, ml_state, ml_table.log);
    flushState(&w, of_state, of_table.log);
    flushState(&w, ll_state, ll_table.log);
    w.add(1, 1);
    w.alignToByte();
    if (w.overflow) return null;
    return w.at;
}

inline fn flushState(w: *Writer, state: u32, log: u4) void {
    w.add(state & ((@as(u32, 1) << log) - 1), log);
    w.flush();
}

/// A sequence's extra bits: literal length, match length, offset.
inline fn extraBits(w: *Writer, store: *const SeqStore, i: usize) void {
    const llc = store.ll_codes[i];
    const mlc = store.ml_codes[i];
    const ofc = store.of_codes[i];
    const ll_bits = codes.ll_bits[llc];
    const ml_bits = codes.ml_bits[mlc];
    w.add(store.litLen(i) - codes.ll_base[llc], @intCast(ll_bits));
    w.add(store.matchLen(i) + codes.min_match - codes.ml_base[mlc], @intCast(ml_bits));
    if (@as(u32, ll_bits) + ml_bits + ofc > 56) w.flush();
    w.add(store.seqs[i].off - (@as(u32, 1) << @intCast(ofc)), @intCast(ofc));
    w.flush();
}
