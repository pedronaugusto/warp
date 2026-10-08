//! Huffman-coded literals, decoding side: the tree description (weights,
//! written directly or FSE-compressed), the decoding table, and the one-
//! and four-stream decoders. Codes are at most 12 bits: the format allows
//! 11, the format's reference decoder accepts 12, and acceptance follows
//! it.

const std = @import("std");
const bits = @import("bits.zig");
const fse = @import("fse.zig");

pub const max_log = 12;
pub const max_symbols = 256;

pub const Error = error{InvalidStream};

/// A tree description, read.
pub const Weights = struct {
    /// Per symbol, 0 for absent; `count` of them are meaningful.
    weights: [max_symbols]u8,
    count: u32,
    /// Bits of the longest code.
    log: u4,
    /// Symbols per weight.
    rank: [max_log + 1]u32,
    /// Bytes of the description.
    len: usize,
};

/// Read a tree description from the start of `in`.
pub fn readWeights(in: []const u8, w: *Weights) Error!void {
    if (in.len == 0) return error.InvalidStream;
    const header = in[0];
    var n: usize = undefined;
    if (header >= 128) {
        // Four bits per weight, two to a byte.
        n = header - 127;
        const size = (n + 1) / 2;
        if (size + 1 > in.len) return error.InvalidStream;
        if (n >= max_symbols) return error.InvalidStream;
        for (0..size) |i| {
            w.weights[2 * i] = in[1 + i] >> 4;
            w.weights[2 * i + 1] = in[1 + i] & 15;
        }
        w.len = size + 1;
    } else {
        if (@as(usize, header) + 1 > in.len) return error.InvalidStream;
        n = try decodeWeights(in[1..][0..header], w.weights[0 .. max_symbols - 1]);
        w.len = @as(usize, header) + 1;
    }
    @memset(&w.rank, 0);
    var total: u32 = 0;
    for (w.weights[0..n]) |weight| {
        if (weight > max_log) return error.InvalidStream;
        w.rank[weight] += 1;
        total += (@as(u32, 1) << @intCast(weight)) >> 1;
    }
    if (total == 0) return error.InvalidStream;
    // The last weight is implied: the total must be a power of two.
    const log = std.math.log2_int(u32, total) + 1;
    if (log > max_log) return error.InvalidStream;
    const rest = (@as(u32, 1) << log) - total;
    const rest_log = std.math.log2_int(u32, rest);
    if (@as(u32, 1) << rest_log != rest) return error.InvalidStream;
    const last: u8 = @intCast(rest_log + 1);
    w.weights[n] = last;
    w.rank[last] += 1;
    if (w.rank[1] < 2 or w.rank[1] & 1 != 0) return error.InvalidStream;
    w.count = @intCast(n + 1);
    w.log = @intCast(log);
}

/// FSE-compressed weights: two interleaved states, decoded until the
/// stream overruns, the way the format's reference decoder counts them.
fn decodeWeights(in: []const u8, out: []u8) Error!usize {
    var counts: fse.Counts = undefined;
    try fse.readCounts(in, 255, &counts);
    if (counts.log > 6) return error.InvalidStream;
    var table: fse.Table(6) = undefined;
    table.build(counts.norm[0 .. @as(usize, counts.max_symbol) + 1], counts.log);
    var r = try bits.Reader.init(in[counts.len..]);
    var s1: u32 = @intCast(r.read(counts.log));
    _ = r.reload();
    var s2: u32 = @intCast(r.read(counts.log));
    _ = r.reload();
    if (r.reload() == .overflow) return error.InvalidStream;
    const cells = &table.cells;
    var op: usize = 0;
    const omax = out.len;
    while (r.reload() == .unfinished and op + 3 < omax) : (op += 4) {
        out[op] = weightSymbol(cells, &s1, &r);
        out[op + 1] = weightSymbol(cells, &s2, &r);
        out[op + 2] = weightSymbol(cells, &s1, &r);
        out[op + 3] = weightSymbol(cells, &s2, &r);
    }
    while (true) {
        if (op + 2 > omax) return error.InvalidStream;
        out[op] = weightSymbol(cells, &s1, &r);
        op += 1;
        if (r.reload() == .overflow) {
            out[op] = weightSymbol(cells, &s2, &r);
            op += 1;
            break;
        }
        if (op + 2 > omax) return error.InvalidStream;
        out[op] = weightSymbol(cells, &s2, &r);
        op += 1;
        if (r.reload() == .overflow) {
            out[op] = weightSymbol(cells, &s1, &r);
            op += 1;
            break;
        }
    }
    return op;
}

inline fn weightSymbol(cells: []const fse.Cell, state: *u32, r: *bits.Reader) u8 {
    const c = cells[state.*];
    state.* = c.next_state + @as(u32, @intCast(r.read(@intCast(c.nb_bits))));
    return c.symbol;
}

/// How a table decodes: one symbol per lookup, or two where both codes
/// fit the lookup's bits.
pub const Kind = enum { single, double };

/// A decoding table, indexed by the next `log` bits of a stream.
pub const Table = struct {
    kind: Kind,
    log: u4,
    cells: extern union {
        /// symbol | length << 8
        single: [1 << max_log]u16,
        /// symbols (first in the low byte) | bits << 16 | symbol count << 24
        double: [1 << max_log]u32,
    },

    /// One symbol per lookup, `log` the longest code.
    pub fn buildSingle(t: *Table, w: *const Weights) void {
        t.kind = .single;
        t.log = w.log;
        fillSingle(w, w.log, &t.cells.single);
    }

    /// Two symbols per lookup where they fit, over 11 bits (12 when a code
    /// is that long), as the format's reference decoder builds it.
    pub fn buildDouble(t: *Table, w: *const Weights) void {
        const log: u4 = if (w.log <= 11) 11 else 12;
        t.kind = .double;
        t.log = log;
        var single: [1 << max_log]u16 = undefined;
        fillSingle(w, log, &single);
        const limit = @as(usize, 1) << log;
        var at: usize = 0;
        while (at < limit) {
            const first = single[at];
            const len1: u5 = @intCast(first >> 8);
            const span = @as(usize, 1) << (log - len1);
            var sub: usize = 0;
            while (sub < span) {
                const second = single[sub << len1];
                const len2: u5 = @intCast(second >> 8);
                const pair = len1 + len2 <= log;
                const size = if (pair) span >> len2 else 1;
                const cell = if (pair)
                    @as(u32, @as(u8, @truncate(first))) | @as(u32, @as(u8, @truncate(second))) << 8 | @as(u32, len1 + len2) << 16 | 2 << 24
                else
                    @as(u32, @as(u8, @truncate(first))) | @as(u32, len1) << 16 | 1 << 24;
                @memset(t.cells.double[at + sub ..][0..size], cell);
                sub += size;
            }
            at += span;
        }
    }
};

/// Single-symbol cells over `log` bits (at least the longest code): in
/// order of weight, then symbol, weight w filling 2^(w-1) cells scaled to
/// `log`, its code `w.log + 1 - w` bits long.
fn fillSingle(w: *const Weights, log: u4, cells: *[1 << max_log]u16) void {
    const scale: u4 = log - w.log;
    var start: [max_log + 2]u32 = undefined;
    var next: u32 = 0;
    for (1..@as(usize, w.log) + 1) |weight| {
        start[weight] = next;
        next += w.rank[weight] << @intCast(weight - 1 + scale);
    }
    for (w.weights[0..w.count], 0..) |weight, s| {
        if (weight == 0) continue;
        const len = @as(u32, 1) << @intCast(weight - 1 + scale);
        const cell: u16 = @as(u16, @intCast(s)) | @as(u16, w.log + 1 - weight) << 8;
        @memset(cells[start[weight]..][0..len], cell);
        start[weight] += len;
    }
}

/// Whether two symbols per lookup decode faster than one, from the
/// section's sizes: the format's reference decoder's measured costs, so a
/// table is built the same way, and treeless sections after it decode the
/// same way.
pub fn chooseDouble(len: usize, csize: usize) bool {
    const Cost = struct { table: u32, per256: u32 };
    const costs = [16][2]Cost{
        .{ .{ .table = 0, .per256 = 0 }, .{ .table = 1, .per256 = 1 } },
        .{ .{ .table = 0, .per256 = 0 }, .{ .table = 1, .per256 = 1 } },
        .{ .{ .table = 150, .per256 = 216 }, .{ .table = 381, .per256 = 119 } },
        .{ .{ .table = 170, .per256 = 205 }, .{ .table = 514, .per256 = 112 } },
        .{ .{ .table = 177, .per256 = 199 }, .{ .table = 539, .per256 = 110 } },
        .{ .{ .table = 197, .per256 = 194 }, .{ .table = 644, .per256 = 107 } },
        .{ .{ .table = 221, .per256 = 192 }, .{ .table = 735, .per256 = 107 } },
        .{ .{ .table = 256, .per256 = 189 }, .{ .table = 881, .per256 = 106 } },
        .{ .{ .table = 359, .per256 = 188 }, .{ .table = 1167, .per256 = 109 } },
        .{ .{ .table = 582, .per256 = 187 }, .{ .table = 1570, .per256 = 114 } },
        .{ .{ .table = 688, .per256 = 187 }, .{ .table = 1712, .per256 = 122 } },
        .{ .{ .table = 825, .per256 = 186 }, .{ .table = 1965, .per256 = 136 } },
        .{ .{ .table = 976, .per256 = 185 }, .{ .table = 2131, .per256 = 150 } },
        .{ .{ .table = 1180, .per256 = 186 }, .{ .table = 2070, .per256 = 175 } },
        .{ .{ .table = 1377, .per256 = 185 }, .{ .table = 1731, .per256 = 202 } },
        .{ .{ .table = 1412, .per256 = 185 }, .{ .table = 1695, .per256 = 202 } },
    };
    const q: usize = if (csize >= len) 15 else csize * 16 / len;
    const d256: u32 = @intCast(len >> 8);
    const one = costs[q][0].table + costs[q][0].per256 * d256;
    var two = costs[q][1].table + costs[q][1].per256 * d256;
    two += two >> 5;
    return two < one;
}

/// Decode one stream of exactly `out.len` symbols.
pub fn decode1(t: *const Table, stream: []const u8, out: []u8) Error!void {
    var r = try bits.Reader.init(stream);
    switch (t.kind) {
        .single => streamSingle(t, &r, out),
        .double => streamDouble(t, &r, out),
    }
    if (!r.finished()) return error.InvalidStream;
}

/// Decode four streams behind a six-byte jump table into `out`, a quarter
/// each (the last takes what remains). `out.len >= 6`.
pub fn decode4(t: *const Table, in: []const u8, out: []u8) Error!void {
    if (in.len < 10) return error.InvalidStream;
    if (out.len < 6) return error.InvalidStream;
    const l1: usize = std.mem.readInt(u16, in[0..2], .little);
    const l2: usize = std.mem.readInt(u16, in[2..4], .little);
    const l3: usize = std.mem.readInt(u16, in[4..6], .little);
    if (l1 + l2 + l3 + 6 > in.len) return error.InvalidStream;
    const segment = (out.len + 3) / 4;
    if (3 * segment > out.len) return error.InvalidStream;
    var r: [4]bits.Reader = undefined;
    r[0] = try .init(in[6..][0..l1]);
    r[1] = try .init(in[6 + l1 ..][0..l2]);
    r[2] = try .init(in[6 + l1 + l2 ..][0..l3]);
    r[3] = try .init(in[6 + l1 + l2 + l3 ..]);
    const ends = [4]usize{ segment, 2 * segment, 3 * segment, out.len };
    var op = [4]usize{ 0, segment, 2 * segment, 3 * segment };
    switch (t.kind) {
        .single => lockstepSingle(t, &r, out, &op),
        .double => {
            lockstepDouble(t, &r, out, &op);
            // Only a broken stream runs past its quarter in lock step.
            for (0..3) |i| if (op[i] > ends[i]) return error.InvalidStream;
        },
    }
    for (0..4) |i| switch (t.kind) {
        .single => streamSingle(t, &r[i], out[op[i]..ends[i]]),
        .double => streamDouble(t, &r[i], out[op[i]..ends[i]]),
    };
    for (r) |x| if (!x.finished()) return error.InvalidStream;
}

inline fn lookupSingle(cells: *const [1 << max_log]u16, log: u4, r: *bits.Reader) u8 {
    const c = cells[@intCast(r.peek(log))];
    r.skip(c >> 8);
    return @truncate(c);
}

/// Two symbols' bytes written (the second may be overwritten next); the
/// count returned.
inline fn lookupDouble(cells: *const [1 << max_log]u32, log: u4, r: *bits.Reader, out: [*]u8) u32 {
    const c = cells[@intCast(r.peek(log))];
    std.mem.writeInt(u16, out[0..2], @truncate(c), .little);
    r.skip((c >> 16) & 0xff);
    return c >> 24;
}

/// Four streams in lock step, four symbols each per reload, while every
/// stream's register is full.
fn lockstepSingle(t: *const Table, r: *[4]bits.Reader, out: []u8, op: *[4]usize) void {
    const cells = &t.cells.single;
    const log = t.log;
    if (out.len - op[3] < 8) return;
    const limit = out.len - 3;
    while (op[3] < limit) {
        inline for (0..4) |k| {
            inline for (0..4) |s| out[op[s] + k] = lookupSingle(cells, log, &r[s]);
        }
        inline for (0..4) |s| op[s] += 4;
        var full = true;
        inline for (0..4) |s| full = full and r[s].reloadFast() == .unfinished;
        if (!full) break;
    }
}

fn lockstepDouble(t: *const Table, r: *[4]bits.Reader, out: []u8, op: *[4]usize) void {
    const cells = &t.cells.double;
    const log = t.log;
    if (out.len - op[3] < 8) return;
    const limit = out.len - 7;
    while (op[3] < limit) {
        inline for (0..4) |_| {
            inline for (0..4) |s| op[s] += lookupDouble(cells, log, &r[s], out[op[s]..].ptr);
        }
        var full = true;
        inline for (0..4) |s| full = full and r[s].reloadFast() == .unfinished;
        if (!full) break;
    }
}

/// Decode `out.len` symbols from `r`, reloading while the stream has
/// bytes left; past its start the reader gives zeros and the caller's
/// end check refuses the stream.
fn streamSingle(t: *const Table, r: *bits.Reader, out: []u8) void {
    const cells = &t.cells.single;
    const log = t.log;
    var i: usize = 0;
    while (out.len - i >= 4) {
        if (r.reload() != .unfinished) break;
        inline for (0..4) |k| out[i + k] = lookupSingle(cells, log, r);
        i += 4;
    }
    // Four 12-bit codes fit one reload, or the register holds the stream's
    // first byte and no reload can add bits.
    _ = r.reload();
    while (i < out.len) : (i += 1) out[i] = lookupSingle(cells, log, r);
}

fn streamDouble(t: *const Table, r: *bits.Reader, out: []u8) void {
    const cells = &t.cells.double;
    const log = t.log;
    var p: usize = 0;
    const end = out.len;
    if (end >= 8) {
        while (p + 8 <= end) {
            if (r.reload() != .unfinished) break;
            inline for (0..4) |_| p += lookupDouble(cells, log, r, out[p..].ptr);
        }
    } else _ = r.reload();
    if (end - p >= 2) {
        while (p + 2 <= end) {
            if (r.reload() != .unfinished) break;
            p += lookupDouble(cells, log, r, out[p..].ptr);
        }
        while (p + 2 <= end) p += lookupDouble(cells, log, r, out[p..].ptr);
    }
    if (p < end) {
        // The last symbol: a lookup may hold two, of which one is wanted;
        // its bits are taken up to the stream's start and no further.
        const c = cells[@intCast(r.peek(log))];
        out[p] = @truncate(c);
        if (c >> 24 == 1) {
            r.skip((c >> 16) & 0xff);
        } else if (r.consumed < 64) {
            r.skip((c >> 16) & 0xff);
            if (r.consumed > 64) r.consumed = 64;
        }
    }
}

// ---- encoding ----

const Writer = @import("../bits.zig").Writer;

/// The longest code the encoder makes.
pub const encode_log = 11;

/// The byte histogram of `bytes`: `counts` filled, the largest symbol
/// present and the largest count returned.
pub fn histogram(bytes: []const u8, counts: *[max_symbols]u32) struct { max_symbol: u8, largest: u32 } {
    // Four tables break the store-to-load chain of repeated bytes.
    var c: [4][max_symbols]u32 = @splat(@splat(0));
    var i: usize = 0;
    while (i + 8 <= bytes.len) : (i += 8) {
        const v = std.mem.readInt(u64, bytes[i..][0..8], .little);
        inline for (0..8) |k| c[k & 3][@as(u8, @truncate(v >> (8 * k)))] += 1;
    }
    while (i < bytes.len) : (i += 1) c[0][bytes[i]] += 1;
    var max_symbol: u8 = 0;
    var largest: u32 = 0;
    for (counts, 0..) |*x, sym| {
        x.* = c[0][sym] + c[1][sym] + c[2][sym] + c[3][sym];
        if (x.* != 0) max_symbol = @intCast(sym);
        largest = @max(largest, x.*);
    }
    return .{ .max_symbol = max_symbol, .largest = largest };
}

/// A code for encoding: each symbol's codeword and length.
pub const EncodeTable = struct {
    codes: [max_symbols]u16,
    lens: [max_symbols]u8,
    /// code << 8 | length: one load per symbol when coding.
    cells: [max_symbols]u32,
    /// The largest symbol it was built for: the description's implied one.
    max_symbol: u8,
    /// The longest code.
    log: u4,

    const Node = struct { count: u32, parent: u16, symbol: u8, bits: u8 };

    /// Canonical encoding codewords for a parsed dictionary's weights.
    pub fn fromWeights(t: *EncodeTable, w: *const Weights) void {
        @memset(&t.lens, 0);
        var counts: [max_log + 2]u16 = @splat(0);
        for (w.weights[0..w.count], 0..) |weight, symbol| {
            if (weight == 0) continue;
            const len = w.log + 1 - weight;
            t.lens[symbol] = len;
            counts[len] += 1;
        }
        var values: [max_log + 2]u16 = @splat(0);
        var value: u16 = 0;
        var len: usize = w.log;
        while (len != 0) : (len -= 1) {
            values[len] = value;
            value = (value + counts[len]) >> 1;
        }
        for (&t.lens, &t.codes, &t.cells) |length, *code, *cell| {
            code.* = if (length == 0) 0 else values[length];
            cell.* = @as(u32, code.*) << 8 | length;
            if (length != 0) values[length] += 1;
        }
        t.max_symbol = @intCast(w.count - 1);
        t.log = w.log;
    }

    /// A code for `counts` (symbols 0 to `counts.len - 1`, the last present),
    /// no code longer than `max_bits`; two or more symbols present.
    pub fn build(t: *EncodeTable, counts: []const u32, max_bits: u4) void {
        // Leaves by count, most frequent first, at 1..n; 0 is a sentinel.
        var nodes: [2 * max_symbols + 2]Node = undefined;
        nodes[0] = .{ .count = 1 << 31, .parent = 0, .symbol = 0, .bits = 0 };
        const n = sortLeaves(counts, nodes[1..]);
        std.debug.assert(n >= 2);
        // Internal nodes from `start`, merged from the two queues.
        const start = max_symbols + 1;
        var low_s: usize = n;
        var low_n: usize = start;
        var next: usize = start;
        const root = start + n - 2;
        nodes[next].count = nodes[low_s].count + nodes[low_s - 1].count;
        nodes[low_s].parent = @intCast(next);
        nodes[low_s - 1].parent = @intCast(next);
        next += 1;
        low_s -= 2;
        for (next..root + 1) |j| nodes[j].count = 1 << 30;
        while (next <= root) : (next += 1) {
            var pick: [2]usize = undefined;
            for (&pick) |*x| {
                if (nodes[low_s].count < nodes[low_n].count) {
                    x.* = low_s;
                    low_s -= 1;
                } else {
                    x.* = low_n;
                    low_n += 1;
                }
            }
            nodes[next].count = nodes[pick[0]].count + nodes[pick[1]].count;
            nodes[pick[0]].parent = @intCast(next);
            nodes[pick[1]].parent = @intCast(next);
        }
        nodes[root].bits = 0;
        var j = root;
        while (j > start) {
            j -= 1;
            nodes[j].bits = nodes[nodes[j].parent].bits + 1;
        }
        for (nodes[1 .. n + 1]) |*leaf| leaf.bits = nodes[leaf.parent].bits + 1;
        const max = limitHeight(nodes[1 .. n + 1], max_bits);
        // Codewords: per length from the longest, values in symbol order.
        var per_len: [max_log + 2]u16 = @splat(0);
        @memset(&t.lens, 0);
        for (nodes[1 .. n + 1]) |leaf| {
            per_len[leaf.bits] += 1;
            t.lens[leaf.symbol] = leaf.bits;
        }
        var value: [max_log + 2]u16 = @splat(0);
        var min: u16 = 0;
        var l: usize = max;
        while (l > 0) : (l -= 1) {
            value[l] = min;
            min += per_len[l];
            min >>= 1;
        }
        for (t.lens[0..counts.len], t.codes[0..counts.len], t.cells[0..counts.len]) |len, *code, *cell| {
            if (len == 0) {
                code.* = 0;
                cell.* = 0;
                continue;
            }
            code.* = value[len];
            cell.* = @as(u32, code.*) << 8 | len;
            value[len] += 1;
        }
        t.max_symbol = @intCast(counts.len - 1);
        t.log = max;
    }

    /// Bucket of a count: small counts each their own, larger ones by
    /// power of two (the reference encoder's buckets).
    fn bucket(c: u32) u32 {
        const distinct = 165;
        return if (c < distinct) c else @as(u32, std.math.log2_int(u32, c)) + 158;
    }

    /// The present symbols as leaves, by count, most frequent first, ties
    /// in symbol order: a counting sort by bucket, then each power-of-two
    /// bucket sorted in place (they are small). Returns how many.
    fn sortLeaves(counts: []const u32, leaves: []Node) usize {
        const buckets = 192;
        var size: [buckets + 1]u16 = @splat(0);
        var n: usize = 0;
        for (counts) |c| {
            if (c == 0) continue;
            size[bucket(c)] += 1;
            n += 1;
        }
        // Start of each bucket, from the highest down.
        var at: [buckets + 1]u16 = undefined;
        var sum: u16 = 0;
        var k: usize = buckets + 1;
        while (k > 0) {
            k -= 1;
            at[k] = sum;
            sum += size[k];
        }
        for (counts, 0..) |c, sym| {
            if (c == 0) continue;
            const b = bucket(c);
            leaves[at[b]] = .{ .count = c, .parent = 0, .symbol = @intCast(sym), .bits = 0 };
            at[b] += 1;
        }
        for (165..buckets) |bk| {
            if (size[bk] < 2) continue;
            const end = at[bk];
            const begin = end - size[bk];
            // Insertion sort, stable: descending count.
            var i = begin + 1;
            while (i < end) : (i += 1) {
                const x = leaves[i];
                var j = i;
                while (j > begin and leaves[j - 1].count < x.count) : (j -= 1) leaves[j] = leaves[j - 1];
                leaves[j] = x;
            }
        }
        return n;
    }

    /// Lengths of leaves sorted by count (most frequent first) cut to
    /// `target` bits, the cost moved onto the cheapest shorter codes, as
    /// the format's reference encoder does; returns the longest length.
    fn limitHeight(leaves: []Node, target: u4) u4 {
        const last = leaves.len - 1;
        const largest: u32 = leaves[last].bits;
        if (largest <= target) return @intCast(largest);
        var total: i32 = 0;
        const base_cost: i32 = @as(i32, 1) << @intCast(largest - target);
        var n: isize = @intCast(last);
        while (leaves[@intCast(n)].bits > target) : (n -= 1) {
            total += base_cost - (@as(i32, 1) << @intCast(largest - leaves[@intCast(n)].bits));
            leaves[@intCast(n)].bits = target;
        }
        while (leaves[@intCast(n)].bits == target) n -= 1;
        total >>= @intCast(largest - target);
        const none: u32 = 0xf0f0f0f0;
        var rank_last: [max_log + 2]u32 = @splat(none);
        {
            var current: u32 = target;
            var pos = n;
            while (pos >= 0) : (pos -= 1) {
                const b = leaves[@intCast(pos)].bits;
                if (b >= current) continue;
                current = b;
                rank_last[target - current] = @intCast(pos);
            }
        }
        while (total > 0) {
            var decrease: u32 = std.math.log2_int(u32, @intCast(total)) + 1;
            while (decrease > 1) : (decrease -= 1) {
                const high = rank_last[decrease];
                const low = rank_last[decrease - 1];
                if (high == none) continue;
                if (low == none) break;
                if (leaves[high].count <= 2 * leaves[low].count) break;
            }
            while (decrease <= max_log and rank_last[decrease] == none) decrease += 1;
            total -= @as(i32, 1) << @intCast(decrease - 1);
            leaves[rank_last[decrease]].bits += 1;
            if (rank_last[decrease - 1] == none) rank_last[decrease - 1] = rank_last[decrease];
            if (rank_last[decrease] == 0) {
                rank_last[decrease] = none;
            } else {
                rank_last[decrease] -= 1;
                if (leaves[rank_last[decrease]].bits != target - decrease) rank_last[decrease] = none;
            }
        }
        while (total < 0) {
            if (rank_last[1] == none) {
                while (leaves[@intCast(n)].bits == target) n -= 1;
                leaves[@intCast(n + 1)].bits -= 1;
                rank_last[1] = @intCast(n + 1);
                total += 1;
                continue;
            }
            leaves[rank_last[1] + 1].bits -= 1;
            rank_last[1] += 1;
            total += 1;
        }
        return target;
    }

    /// Whether every symbol of `counts` has a code here.
    pub fn covers(t: *const EncodeTable, counts: []const u32) bool {
        if (counts.len > @as(usize, t.max_symbol) + 1) return false;
        for (counts, t.lens[0..counts.len]) |c, len| if (c != 0 and len == 0) return false;
        return true;
    }

    /// The bytes `counts` take in this code, rounded down.
    pub fn estimate(t: *const EncodeTable, counts: []const u32) usize {
        var bits_total: usize = 0;
        for (counts, t.lens[0..counts.len]) |c, len| bits_total += @as(usize, c) * len;
        return bits_total >> 3;
    }

    /// The tree description (RFC 8878 4.2.1.1): weights FSE-compressed when
    /// that is smaller, else four bits each. Null when neither fits.
    pub fn writeDescription(t: *const EncodeTable, out: []u8) ?usize {
        var weights: [max_symbols]u8 = undefined;
        const n = t.max_symbol;
        for (t.lens[0..n], weights[0..n]) |len, *w| w.* = if (len == 0) 0 else @as(u8, t.log) + 1 - len;
        if (out.len < 1) return null;
        if (compressWeights(weights[0..n], out[1..])) |size| {
            if (size > 1 and size < n / 2) {
                out[0] = @intCast(size);
                return size + 1;
            }
        }
        if (n > 128) return null;
        const size = (@as(usize, n) + 1) / 2;
        if (size + 1 > out.len) return null;
        out[0] = 128 + (n - 1);
        weights[n] = 0;
        var k: usize = 0;
        while (k < n) : (k += 2) out[k / 2 + 1] = weights[k] << 4 | weights[k + 1];
        return size + 1;
    }
};

/// Weights FSE-compressed with two interleaved states (6-bit tables at
/// most); null when not worth it or no room.
fn compressWeights(weights: []const u8, out: []u8) ?usize {
    if (weights.len <= 1) return null;
    var counts: [max_log + 1]u32 = @splat(0);
    var max_symbol: u8 = 0;
    var largest: u32 = 0;
    for (weights) |w| {
        counts[w] += 1;
        max_symbol = @max(max_symbol, w);
    }
    for (counts[0 .. @as(usize, max_symbol) + 1]) |c| largest = @max(largest, c);
    if (largest == weights.len) return 1;
    if (largest == 1) return null;
    const log = fse.optimalLog(6, weights.len, max_symbol, 2);
    var norm: [max_log + 1]i16 = undefined;
    const used = norm[0 .. @as(usize, max_symbol) + 1];
    fse.normalize(used, log, counts[0..used.len], weights.len, false) catch return null;
    if (out.len < fse.countsBound(max_symbol, log)) return null;
    var o = fse.writeCounts(out, used, log);
    var table: fse.EncodeTable(6, max_log) = undefined;
    table.build(used, log);
    if (weights.len <= 2) return null;
    if (out.len - o < 8) return null;
    var w: Writer = .init(out, o);
    var s1: u32 = undefined;
    var s2: u32 = undefined;
    var i = weights.len;
    if (i & 1 != 0) {
        s1 = table.initState(weights[i - 1]);
        s2 = table.initState(weights[i - 2]);
        encodeFse(&w, &table, &s1, weights[i - 3]);
        w.flush();
        i -= 3;
    } else {
        s2 = table.initState(weights[i - 1]);
        s1 = table.initState(weights[i - 2]);
        i -= 2;
    }
    if ((i) & 2 != 0) {
        encodeFse(&w, &table, &s2, weights[i - 1]);
        encodeFse(&w, &table, &s1, weights[i - 2]);
        w.flush();
        i -= 2;
    }
    while (i > 0) : (i -= 4) {
        encodeFse(&w, &table, &s2, weights[i - 1]);
        encodeFse(&w, &table, &s1, weights[i - 2]);
        encodeFse(&w, &table, &s2, weights[i - 3]);
        encodeFse(&w, &table, &s1, weights[i - 4]);
        w.flush();
    }
    w.add(s2 & ((@as(u32, 1) << table.log) - 1), table.log);
    w.add(s1 & ((@as(u32, 1) << table.log) - 1), table.log);
    w.add(1, 1);
    w.alignToByte();
    if (w.overflow) return null;
    o = w.at;
    return o;
}

/// `w.flush()` where the output is known to have room: no check.
pub inline fn flushUnchecked(w: *Writer) void {
    std.mem.writeInt(u64, w.out[w.at..][0..8], w.bitbuf, .little);
    const n = w.count >> 3;
    w.at += n;
    w.bitbuf >>= @intCast(@as(u7, n) << 3);
    w.count &= 7;
}

/// One FSE symbol into `w`: the state's low bits out, the next state in.
pub inline fn encodeFse(w: *Writer, table: anytype, state: *u32, symbol: u8) void {
    const tt = table.transforms[symbol];
    const nb: u5 = @intCast((state.* +% tt.delta_nb_bits) >> 16);
    w.add(state.* & ((@as(u32, 1) << nb) - 1), nb);
    state.* = table.states[@intCast(@as(i32, @intCast(state.* >> nb)) + tt.delta_find_state)];
}

/// One stream of `src` into `out`, last symbol first; 0 when it does not
/// fit.
pub fn compress1(t: *const EncodeTable, src: []const u8, out: []u8) usize {
    if (out.len == 0) return 0;
    // With room for every symbol at the longest code, no write is checked.
    if (out.len >= (src.len * max_log) / 8 + 16) return encodeStream(false, t, src, out);
    return encodeStream(true, t, src, out);
}

fn encodeStream(comptime checked: bool, t: *const EncodeTable, src: []const u8, out: []u8) usize {
    var w: Writer = .init(out, 0);
    var i = src.len;
    const cells = &t.cells;
    while (i >= 4) {
        inline for (1..5) |k| {
            const cell = cells[src[i - k]];
            w.add(cell >> 8, @truncate(cell));
        }
        if (checked) w.flush() else flushUnchecked(&w);
        i -= 4;
    }
    while (i > 0) {
        i -= 1;
        const cell = cells[src[i]];
        w.add(cell >> 8, @truncate(cell));
    }
    w.add(1, 1);
    w.alignToByte();
    if (w.overflow) return 0;
    return w.at;
}

/// Four streams behind a jump table; 0 when they do not fit.
pub fn compress4(t: *const EncodeTable, src: []const u8, out: []u8) usize {
    if (out.len < 6 + 4) return 0;
    if (src.len < 12) return 0;
    const segment = (src.len + 3) / 4;
    var o: usize = 6;
    for (0..4) |k| {
        const part = if (k < 3) src[k * segment ..][0..segment] else src[3 * segment ..];
        const n = compress1(t, part, out[o..]);
        if (n == 0 or n > 65535) return 0;
        if (k < 3) std.mem.writeInt(u16, out[2 * k ..][0..2], @intCast(n), .little);
        o += n;
    }
    return o;
}

/// The table log the reference encoder picks for `len` literals of
/// symbols up to `max_symbol`, at most `max`.
pub fn optimalLog(max: u4, len: usize, max_symbol: u8) u4 {
    return fse.optimalLog(max, len, max_symbol, 1);
}

test "a direct description: weights read, the last implied, and the table's codes" {
    // Weights 4, 3, 2, 0, 1 (the format's example); the sixth, 1, is
    // implied. Five weights in three bytes behind the header 127 + 5.
    const desc = [_]u8{ 127 + 5, 0x43, 0x20, 0x10 };
    var w: Weights = undefined;
    try readWeights(&desc, &w);
    try std.testing.expectEqual(@as(u32, 6), w.count);
    try std.testing.expectEqual(@as(u4, 4), w.log);
    try std.testing.expectEqualSlices(u8, &.{ 4, 3, 2, 0, 1, 1 }, w.weights[0..6]);
    var t: Table = undefined;
    t.buildSingle(&w);
    // Codes: 0 -> 1, 1 -> 01, 2 -> 001, 4 -> 0000, 5 -> 0001.
    const want = [_]struct { u16, u8, u8 }{ .{ 0b1000, 0, 1 }, .{ 0b0100, 1, 2 }, .{ 0b0010, 2, 3 }, .{ 0b0000, 4, 4 }, .{ 0b0001, 5, 4 } };
    for (want) |c| {
        try std.testing.expectEqual(@as(u16, c[1]) | @as(u16, c[2]) << 8, t.cells.single[c[0]]);
    }
    // Over 11 bits, two symbols where they fit: "1" then "01" is 0b101
    // followed by anything, three bits.
    t.buildDouble(&w);
    try std.testing.expectEqual(@as(u4, 11), t.log);
    const pair = t.cells.double[0b101 << 8];
    try std.testing.expectEqual(@as(u32, 0 | 1 << 8 | 3 << 16 | 2 << 24), pair);
}

test "double tables agree with two single lookups at every code length" {
    var single: Table = undefined;
    var double: Table = undefined;
    for (1..max_log + 1) |log| {
        var w: Weights = .{ .log = @intCast(log), .count = @intCast(log + 1), .weights = @splat(0), .rank = @splat(0), .len = 0 };
        w.weights[0] = 1;
        w.weights[1] = 1;
        w.rank[1] = 2;
        for (2..log + 1) |weight| {
            w.weights[weight] = @intCast(weight);
            w.rank[weight] = 1;
        }
        single.buildSingle(&w);
        double.buildDouble(&w);
        const shift: u4 = double.log - single.log;
        const mask = (@as(usize, 1) << double.log) - 1;
        for (double.cells.double[0 .. mask + 1], 0..) |cell, index| {
            const first = single.cells.single[index >> shift];
            const len1 = first >> 8;
            try std.testing.expectEqual(@as(u8, @truncate(first)), @as(u8, @truncate(cell)));
            const second_index = ((index << @intCast(len1)) & mask) >> shift;
            const second = single.cells.single[second_index];
            const len2 = second >> 8;
            if (len1 + len2 <= double.log) {
                try std.testing.expectEqual(@as(u32, 2), cell >> 24);
                try std.testing.expectEqual(@as(u8, @truncate(second)), @as(u8, @truncate(cell >> 8)));
                try std.testing.expectEqual(@as(u32, len1 + len2), (cell >> 16) & 255);
            } else {
                try std.testing.expectEqual(@as(u32, 1), cell >> 24);
                try std.testing.expectEqual(@as(u32, len1), (cell >> 16) & 255);
            }
        }
    }
}

test "descriptions whose weights do not form a code are refused" {
    var w: Weights = undefined;
    // Weights 3 and 1 leave 3 to a power of two: no last weight does it.
    try std.testing.expectError(error.InvalidStream, readWeights(&.{ 127 + 2, 0x31 }, &w));
    // Weight 2 alone: the last is 2 as well, and no code has two symbols
    // of length 1 and none longer.
    try std.testing.expectError(error.InvalidStream, readWeights(&.{ 127 + 1, 0x20 }, &w));
    // All zero.
    try std.testing.expectError(error.InvalidStream, readWeights(&.{ 127 + 2, 0x00 }, &w));
    // Truncated.
    try std.testing.expectError(error.InvalidStream, readWeights(&.{ 127 + 4, 0x11 }, &w));
}

/// Sequential symbols for partial decoding: literals are read directly
/// into their final output positions, without a temporary literal buffer.
pub const Symbols = struct {
    table: *const Table,
    streams: [4]bits.Reader,
    ends: [4]usize,
    index: usize = 0,
    at: usize = 0,
    pending: ?u8 = null,

    pub fn init(t: *const Table, in: []const u8, len: usize, single: bool) Error!Symbols {
        var s: Symbols = .{ .table = t, .streams = undefined, .ends = undefined };
        if (single) {
            s.streams[0] = try .init(in);
            s.ends = @splat(len);
            return s;
        }
        if (in.len < 10 or len < 6) return error.InvalidStream;
        const a: usize = std.mem.readInt(u16, in[0..2], .little);
        const b: usize = std.mem.readInt(u16, in[2..4], .little);
        const c: usize = std.mem.readInt(u16, in[4..6], .little);
        if (6 + a + b + c > in.len) return error.InvalidStream;
        s.streams[0] = try .init(in[6..][0..a]);
        s.streams[1] = try .init(in[6 + a ..][0..b]);
        s.streams[2] = try .init(in[6 + a + b ..][0..c]);
        s.streams[3] = try .init(in[6 + a + b + c ..]);
        const quarter = (len + 3) / 4;
        if (3 * quarter > len) return error.InvalidStream;
        s.ends = .{ quarter, 2 * quarter, 3 * quarter, len };
        return s;
    }

    pub fn read(s: *Symbols, out: []u8) Error!void {
        for (out) |*byte| {
            if (s.at >= s.ends[3]) return error.InvalidStream;
            if (s.at == s.ends[s.index]) s.index += 1;
            const r = &s.streams[s.index];
            if (s.pending) |next| {
                byte.* = next;
                s.pending = null;
            } else {
                if (r.reload() == .overflow) return error.InvalidStream;
                switch (s.table.kind) {
                    .single => byte.* = lookupSingle(&s.table.cells.single, s.table.log, r),
                    .double => {
                        const cell = s.table.cells.double[@intCast(r.peek(s.table.log))];
                        byte.* = @truncate(cell);
                        r.skip((cell >> 16) & 0xff);
                        if (cell >> 24 == 2) {
                            if (s.at + 1 < s.ends[s.index]) {
                                s.pending = @truncate(cell >> 8);
                            } else if (r.consumed > 64) {
                                // The final lookup may contain two symbols;
                                // only the first belongs to this stream.
                                r.consumed = 64;
                            }
                        }
                    },
                }
            }
            s.at += 1;
            if (s.at == s.ends[s.index] and !r.finished()) return error.InvalidStream;
        }
    }
};
