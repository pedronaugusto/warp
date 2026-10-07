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
        out[op] = symbol(cells, &s1, &r);
        out[op + 1] = symbol(cells, &s2, &r);
        out[op + 2] = symbol(cells, &s1, &r);
        out[op + 3] = symbol(cells, &s2, &r);
    }
    while (true) {
        if (op + 2 > omax) return error.InvalidStream;
        out[op] = symbol(cells, &s1, &r);
        op += 1;
        if (r.reload() == .overflow) {
            out[op] = symbol(cells, &s2, &r);
            op += 1;
            break;
        }
        if (op + 2 > omax) return error.InvalidStream;
        out[op] = symbol(cells, &s2, &r);
        op += 1;
        if (r.reload() == .overflow) {
            out[op] = symbol(cells, &s1, &r);
            op += 1;
            break;
        }
    }
    return op;
}

inline fn symbol(cells: []const fse.Cell, state: *u32, r: *bits.Reader) u8 {
    const c = cells[state.*];
    state.* = c.next_state + @as(u32, @intCast(r.read(@intCast(c.nb_bits))));
    return c.symbol;
}

/// A decoding table of single symbols: indexed by the next `log` bits,
/// each cell is a symbol and its code's length.
pub const Table = struct {
    /// symbol | length << 8
    cells: [1 << max_log]u16,
    log: u4,

    pub fn build(t: *Table, w: *const Weights) void {
        const log = w.log;
        t.log = log;
        // Cells in order of weight, then symbol: weight w fills 2^(w-1)
        // cells, its code `log + 1 - w` bits long.
        var start: [max_log + 2]u32 = undefined;
        var next: u32 = 0;
        for (1..@as(usize, log) + 1) |weight| {
            start[weight] = next;
            next += w.rank[weight] << @intCast(weight - 1);
        }
        for (w.weights[0..w.count], 0..) |weight, s| {
            if (weight == 0) continue;
            const len = @as(u32, 1) << @intCast(weight - 1);
            const cell: u16 = @as(u16, @intCast(s)) | @as(u16, log + 1 - weight) << 8;
            @memset(t.cells[start[weight]..][0..len], cell);
            start[weight] += len;
        }
    }
};

/// Decode one stream of exactly `out.len` symbols.
pub fn decode1(t: *const Table, stream: []const u8, out: []u8) Error!void {
    var r = try bits.Reader.init(stream);
    decodeStream(t, &r, out);
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
    const s1 = in[6..][0..l1];
    const s2 = in[6 + l1 ..][0..l2];
    const s3 = in[6 + l1 + l2 ..][0..l3];
    const s4 = in[6 + l1 + l2 + l3 ..];
    var r1 = try bits.Reader.init(s1);
    var r2 = try bits.Reader.init(s2);
    var r3 = try bits.Reader.init(s3);
    var r4 = try bits.Reader.init(s4);
    const o1 = out[0..segment];
    const o2 = out[segment..][0..segment];
    const o3 = out[2 * segment ..][0..segment];
    const o4 = out[3 * segment ..];
    // In lock step while every stream has a full register: four symbols
    // per stream per reload (4 x 12 bits fit the 57 a reload guarantees).
    const cells = &t.cells;
    const log = t.log;
    var i: usize = 0;
    const lockstep = if (o4.len >= 4) o4.len - 3 else 0;
    while (i + 4 <= lockstep) : (i += 4) {
        if (r1.reload() != .unfinished or r2.reload() != .unfinished or r3.reload() != .unfinished or r4.reload() != .unfinished) break;
        inline for (0..4) |k| {
            o1[i + k] = decodeSymbol(cells, log, &r1);
            o2[i + k] = decodeSymbol(cells, log, &r2);
            o3[i + k] = decodeSymbol(cells, log, &r3);
            o4[i + k] = decodeSymbol(cells, log, &r4);
        }
    }
    decodeStream(t, &r1, o1[i..]);
    decodeStream(t, &r2, o2[i..]);
    decodeStream(t, &r3, o3[i..]);
    decodeStream(t, &r4, o4[i..]);
    if (!(r1.finished() and r2.finished() and r3.finished() and r4.finished())) return error.InvalidStream;
}

inline fn decodeSymbol(cells: *const [1 << max_log]u16, log: u4, r: *bits.Reader) u8 {
    const c = cells[@intCast(r.peek(log))];
    r.skip(c >> 8);
    return @truncate(c);
}

/// Decode `out.len` symbols from `r`, reloading while the stream has
/// bytes left; past its start the reader gives zeros and the caller's
/// end check refuses the stream.
fn decodeStream(t: *const Table, r: *bits.Reader, out: []u8) void {
    const cells = &t.cells;
    const log = t.log;
    var i: usize = 0;
    while (out.len - i >= 4) {
        if (r.reload() != .unfinished) break;
        inline for (0..4) |k| out[i + k] = decodeSymbol(cells, log, r);
        i += 4;
    }
    // At most 4 x 12 bits remain to read, or the register holds the
    // stream's first byte: no further reload can add bits.
    _ = r.reload();
    while (i < out.len) : (i += 1) out[i] = decodeSymbol(cells, log, r);
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
    t.build(&w);
    // Codes: 0 -> 1, 1 -> 01, 2 -> 001, 4 -> 0000, 5 -> 0001.
    const want = [_]struct { u16, u8, u8 }{ .{ 0b1000, 0, 1 }, .{ 0b0100, 1, 2 }, .{ 0b0010, 2, 3 }, .{ 0b0000, 4, 4 }, .{ 0b0001, 5, 4 } };
    for (want) |c| {
        try std.testing.expectEqual(@as(u16, c[1]) | @as(u16, c[2]) << 8, t.cells[c[0]]);
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
