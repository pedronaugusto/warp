//! A block's contents and how they are written: the matches and literal
//! runs a parser chose, their symbol counts, and the cheapest of a stored,
//! fixed-code or dynamic-code block for them, by exact bit cost.

const std = @import("std");
const gen = @import("gen");
const bits = @import("bits");
const huffman = @import("../huffman.zig");

const decode = huffman.decode;
const encode = huffman.encode;

/// A match and the literals before it. The literals are the input's own
/// bytes, read again when the block is written.
pub const Sequence = struct {
    literals: u32,
    /// 3-258.
    length: u16,
    /// 1-32768.
    distance: u16,
};

pub const litlen_symbols = 288;
pub const dist_symbols = 30;
const end_of_block = 256;

/// Each length's litlen symbol (257-285).
const length_symbol: [259]u16 = blk: {
    var t: [259]u16 = @splat(0);
    for (0..29) |i| {
        const span: usize = @as(usize, 1) << decode.length_extra[i];
        for (decode.length_base[i]..@min(decode.length_base[i] + span, 259)) |len| t[len] = @intCast(257 + i);
    }
    // 258 has its own symbol, though 284's extra bits reach it.
    t[258] = 285;
    break :blk t;
};

/// Each distance's symbol: distances 1-256 directly, longer ones by their
/// value divided by 128 (zlib's `_dist_code`).
const dist_symbol_small: [256]u8 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [256]u8 = undefined;
    for (0..30) |s| {
        const span: usize = @as(usize, 1) << decode.dist_extra[s];
        for (decode.dist_base[s]..decode.dist_base[s] + span) |d| {
            if (d <= 256) t[d - 1] = s;
        }
    }
    break :blk t;
};
const dist_symbol_large: [256]u8 = blk: {
    @setEvalBranchQuota(100_000);
    var t: [256]u8 = undefined;
    for (0..30) |s| {
        const span: usize = @as(usize, 1) << decode.dist_extra[s];
        for (decode.dist_base[s]..decode.dist_base[s] + span) |d| {
            if (d > 256) t[(d - 1) >> 7] = s;
        }
    }
    break :blk t;
};

pub inline fn distSymbol(distance: u32) u32 {
    return if (distance <= 256) dist_symbol_small[distance - 1] else dist_symbol_large[(distance - 1) >> 7];
}

pub inline fn lengthSymbol(length: u32) u32 {
    return length_symbol[length];
}

/// How often each symbol occurs in a block.
pub const Counts = struct {
    litlen: [litlen_symbols]u32 = @splat(0),
    dist: [dist_symbols]u32 = @splat(0),

    pub inline fn literal(c: *Counts, byte: u8) void {
        c.litlen[byte] += 1;
    }

    pub inline fn match(c: *Counts, length: u32, distance: u32) void {
        c.litlen[lengthSymbol(length)] += 1;
        c.dist[distSymbol(distance)] += 1;
    }
};

/// Which block types a writer may choose.
pub const Kinds = enum { any, optimal, no_dynamic, stored_only };

/// One code: each symbol's codeword (bit-reversed) and length.
const Code = struct {
    litlen_codes: [litlen_symbols]u16,
    litlen_lens: [litlen_symbols]u8,
    dist_codes: [32]u16,
    dist_lens: [32]u8,
};

const fixed: Code = blk: {
    var c: Code = undefined;
    @memset(c.litlen_lens[0..144], 8);
    @memset(c.litlen_lens[144..256], 9);
    @memset(c.litlen_lens[256..280], 7);
    @memset(c.litlen_lens[280..288], 8);
    @memset(&c.dist_lens, 5);
    @setEvalBranchQuota(100_000);
    encode.canonicalCodes(&c.litlen_lens, &c.litlen_codes);
    encode.canonicalCodes(&c.dist_lens, &c.dist_codes);
    break :blk c;
};

/// A dynamic block's header, as written: the code lengths run-length
/// coded with the code-length code.
const Header = struct {
    hlit: u16,
    hdist: u16,
    hclen: u16,
    /// Code-length symbols, each with its extra bits in the high byte.
    items: [288 + 32]u16,
    n_items: u16,
    pre_lens: [19]u8,
    pre_codes: [19]u16,
};

const precode_order = [19]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

/// The dynamic code's lengths for `counts`, its header and its cost in bits;
/// `codewords` makes the codewords. A cost of `beat` or more is not made
/// exact: the caller has a cheaper choice, and only the header is left to
/// refine, which can save no more than its own cost less the fewest bits a
/// header takes.
fn dynamicCode(counts: *const Counts, code: *Code, header: *Header, optimize_header: bool, beat: u64) u64 {
    var lit_counts = counts.litlen;
    var dist_counts: [32]u32 = @splat(0);
    @memcpy(dist_counts[0..dist_symbols], &counts.dist);
    // At least two codes each, so neither code is incomplete (zlib's rule
    // for the codes it writes; some decoders refuse a one-code code).
    ensureTwo(lit_counts[0..286]);
    ensureTwo(dist_counts[0..30]);
    encode.buildLengths(&lit_counts, 15, &code.litlen_lens);
    encode.buildLengths(&dist_counts, 15, &code.dist_lens);

    var hlit: usize = 286;
    while (hlit > 257 and code.litlen_lens[hlit - 1] == 0) hlit -= 1;
    var hdist: usize = 30;
    while (hdist > 1 and code.dist_lens[hdist - 1] == 0) hdist -= 1;
    header.hlit = @intCast(hlit);
    header.hdist = @intCast(hdist);

    // The lengths, run-length coded: 16 repeats the last length 3-6
    // times, 17 writes 3-10 zeros, 18 writes 11-138.
    var lens: [286 + 30]u8 = undefined;
    @memcpy(lens[0..hlit], code.litlen_lens[0..hlit]);
    @memcpy(lens[hlit..][0..hdist], code.dist_lens[0..hdist]);
    var pre_counts: [19]u32 = @splat(0);
    var n: usize = 0;
    var i: usize = 0;
    const total = hlit + hdist;
    while (i < total) {
        const l = lens[i];
        var run: usize = 1;
        while (i + run < total and lens[i + run] == l) run += 1;
        i += run;
        if (l == 0) {
            while (run >= 11) {
                const r = @min(run, 138);
                header.items[n] = 18 | @as(u16, @intCast(r - 11)) << 8;
                n += 1;
                run -= r;
            }
            if (run >= 3) {
                header.items[n] = 17 | @as(u16, @intCast(run - 3)) << 8;
                n += 1;
                run = 0;
            }
        } else {
            header.items[n] = l;
            n += 1;
            run -= 1;
            while (run >= 3) {
                const r = @min(run, 6);
                header.items[n] = 16 | @as(u16, @intCast(r - 3)) << 8;
                n += 1;
                run -= r;
            }
        }
        for (0..run) |_| {
            header.items[n] = l;
            n += 1;
        }
    }
    header.n_items = @intCast(n);
    for (header.items[0..n]) |item| pre_counts[item & 0xff] += 1;
    encode.buildLengths(&pre_counts, 7, &header.pre_lens);
    var hclen: usize = 19;
    while (hclen > 4 and header.pre_lens[precode_order[hclen - 1]] == 0) hclen -= 1;
    header.hclen = @intCast(hclen);

    const data = dataCost(counts, code);
    if (optimize_header and header.n_items > 16) {
        const unrefined = headerCost(header);
        if (14 + unrefined + data -| (unrefined -| min_header_cost) < beat) optimizeHeader(header, lens[0..total]);
    }
    return 14 + headerCost(header) + data;
}

/// The fewest bits any header takes after its 14 fixed ones: four code-length
/// code lengths of three bits, and the two items that 258 lengths need.
const min_header_cost = 3 * 4 + 2;

/// Price the header's run symbols under its current code, then rebuild
/// that code. Keep only an exact improvement, including HCLEN's cost.
fn optimizeHeader(header: *Header, lens: []const u8) void {
    var pass: usize = 0;
    while (pass < 3) : (pass += 1) {
        var cost: [321]u32 = undefined;
        var item: [320]u16 = undefined;
        var take: [320]u8 = undefined;
        cost[lens.len] = 0;
        var i = lens.len;
        while (i > 0) {
            i -= 1;
            const l = lens[i];
            cost[i] = preCost(header, l) + cost[i + 1];
            item[i] = l;
            take[i] = 1;
            var run: usize = 1;
            while (i + run < lens.len and lens[i + run] == l and run < 138) run += 1;
            if (i != 0 and lens[i - 1] == l) considerRun(header, &cost, &item, &take, i, run, 16, 3, 6, 2);
            if (l == 0) {
                considerRun(header, &cost, &item, &take, i, run, 17, 3, 10, 3);
                considerRun(header, &cost, &item, &take, i, run, 18, 11, 138, 7);
            }
        }
        var candidate = header.*;
        var counts: [19]u32 = @splat(0);
        candidate.n_items = 0;
        i = 0;
        while (i < lens.len) {
            candidate.items[candidate.n_items] = item[i];
            candidate.n_items += 1;
            counts[item[i] & 255] += 1;
            i += take[i];
        }
        encode.buildLengths(&counts, 7, &candidate.pre_lens);
        var hclen: usize = 19;
        while (hclen > 4 and candidate.pre_lens[precode_order[hclen - 1]] == 0) hclen -= 1;
        candidate.hclen = @intCast(hclen);
        if (headerCost(&candidate) >= headerCost(header)) return;
        header.* = candidate;
    }
}

fn preCost(header: *const Header, symbol: usize) u32 {
    const n = header.pre_lens[symbol];
    return if (n == 0) 8 else n;
}

fn considerRun(header: *const Header, cost: *[321]u32, items: *[320]u16, takes: *[320]u8, at: usize, run: usize, symbol: u16, min: usize, max: usize, extra: u32) void {
    if (run < min) return;
    for (min..@min(run, max) + 1) |n| {
        const price = preCost(header, symbol) + extra + cost[at + n];
        if (price < cost[at]) {
            cost[at] = price;
            items[at] = symbol | @as(u16, @intCast(n - min)) << 8;
            takes[at] = @intCast(n);
        }
    }
}

fn headerCost(header: *const Header) u32 {
    var cost: u32 = 3 * @as(u32, header.hclen);
    for (header.items[0..header.n_items]) |item| {
        const symbol = item & 255;
        cost += header.pre_lens[symbol] + @as(u32, switch (symbol) {
            16 => 2,
            17 => 3,
            18 => 7,
            else => 0,
        });
    }
    return cost;
}

/// The code lengths `write` builds for a dynamic block of `counts_in`
/// (which do not include the end of the block), and the block's cost in
/// bits after its three header bits.
pub const Lengths = struct { litlen: [litlen_symbols]u8, dist: [32]u8, cost: u64 };

pub fn dynamicLengths(counts_in: *const Counts) Lengths {
    var counts = counts_in.*;
    counts.litlen[end_of_block] += 1;
    var code: Code = undefined;
    var header: Header = undefined;
    const cost = dynamicCode(&counts, &code, &header, true, std.math.maxInt(u64));
    return .{ .litlen = code.litlen_lens, .dist = code.dist_lens, .cost = cost };
}

/// The fixed code's lengths.
pub const fixed_lengths: Lengths = .{ .litlen = fixed.litlen_lens, .dist = fixed.dist_lens, .cost = 0 };

/// The codewords of a dynamic code whose lengths `dynamicCode` chose: made
/// only for the block that is written with it.
fn codewords(code: *Code, header: *Header) void {
    encode.canonicalCodes(&code.litlen_lens, &code.litlen_codes);
    encode.canonicalCodes(&code.dist_lens, &code.dist_codes);
    encode.canonicalCodes(&header.pre_lens, &header.pre_codes);
}

/// Two used symbols at least: the first unused symbols of the range get a
/// count of one.
fn ensureTwo(counts: []u32) void {
    var used: usize = 0;
    for (counts) |c| used += @intFromBool(c != 0);
    var s: usize = 0;
    while (used < 2) : (s += 1) {
        if (counts[s] == 0) {
            counts[s] = 1;
            used += 1;
        }
    }
}

/// Each litlen symbol's extra bits: the lengths'.
const litlen_extra: [litlen_symbols]u8 = blk: {
    var e: [litlen_symbols]u8 = @splat(0);
    @memcpy(e[257..286], &decode.length_extra);
    break :blk e;
};

/// Each distance symbol's extra bits, padded to 32.
const dist_extra: [32]u8 = decode.dist_extra ++ [2]u8{ 0, 0 };

/// The bits of the block's symbols and extra bits with `code`: sixteen
/// symbols a step.
fn dataCost(counts: *const Counts, code: *const Code) u64 {
    const u64x16 = @Vector(16, u64);
    var acc: u64x16 = @splat(0);
    var i: usize = 0;
    while (i < litlen_symbols) : (i += 16) {
        const c: u64x16 = @as(@Vector(16, u32), counts.litlen[i..][0..16].*);
        const l: u64x16 = @as(@Vector(16, u8), code.litlen_lens[i..][0..16].*);
        const e: u64x16 = @as(@Vector(16, u8), litlen_extra[i..][0..16].*);
        acc += c * (l + e);
    }
    var dist: [32]u32 = @splat(0);
    @memcpy(dist[0..dist_symbols], &counts.dist);
    inline for (0..2) |half| {
        const c: u64x16 = @as(@Vector(16, u32), dist[half * 16 ..][0..16].*);
        const l: u64x16 = @as(@Vector(16, u8), code.dist_lens[half * 16 ..][0..16].*);
        const e: u64x16 = @as(@Vector(16, u8), dist_extra[half * 16 ..][0..16].*);
        acc += c * (l + e);
    }
    return @reduce(.Add, acc);
}

/// The bits of stored blocks for `len` bytes starting at bit `position`.
fn storedCost(len: usize, position: u64) u64 {
    var cost: u64 = 0;
    var left = len;
    var pos = position;
    while (true) {
        const chunk = @min(left, 65535);
        const header_end = pos + 3;
        const chunk_cost = 3 + (8 - header_end % 8) % 8 + 32 + 8 * @as(u64, chunk);
        cost += chunk_cost;
        pos += chunk_cost;
        left -= chunk;
        if (left == 0) return cost;
    }
}

/// A block's bytes for the writer.
pub const Data = struct {
    /// The literals' bytes: the block's own bytes, which the matches skip
    /// over (`interleaved`), or its literals alone, kept as they were
    /// parsed.
    bytes: []const u8,
    /// The block's bytes as they are, for a stored block; null when they
    /// are no longer at hand (a streaming window moved past them).
    raw: ?[]const u8,
};

/// Write one block: the matches in `seqs`, each after its literals, then
/// `tail` literals; the cheapest kind `kinds` allows for `counts`, which
/// do not include the end of the block.
pub fn write(comptime interleaved: bool, w: *bits.Writer, data: Data, seqs: []const Sequence, tail: u32, counts_in: *const Counts, final: bool, kinds: Kinds) void {
    if (kinds == .stored_only) return writeStored(w, data.raw.?, final);
    // A block with nothing in it is the fixed code's end of block: no other
    // block is as short.
    if (seqs.len == 0 and tail == 0) {
        w.add(@as(u64, @intFromBool(final)) | 2, 3);
        writeData(interleaved, w, data.bytes, seqs, tail, &fixed);
        return;
    }
    var counts = counts_in.*;
    counts.litlen[end_of_block] += 1;
    var code: Code = undefined;
    var header: Header = undefined;
    const fixed_cost = 3 + dataCost(&counts, &fixed);
    const dynamic_cost = if (kinds == .any or kinds == .optimal) 3 + dynamicCode(&counts, &code, &header, kinds == .optimal, fixed_cost - 3) else std.math.maxInt(u64);
    if (data.raw) |raw| {
        if (storedCost(raw.len, w.bitPosition()) < @min(fixed_cost, dynamic_cost)) return writeStored(w, raw, final);
    }
    if (fixed_cost <= dynamic_cost) {
        w.add(@as(u64, @intFromBool(final)) | 2, 3);
        writeData(interleaved, w, data.bytes, seqs, tail, &fixed);
    } else {
        w.add(@as(u64, @intFromBool(final)) | 4, 3);
        codewords(&code, &header);
        writeHeader(w, &header);
        writeData(interleaved, w, data.bytes, seqs, tail, &code);
    }
}

/// The most bits `write` writes for a block of `literals` literals and
/// `matches` matches: fixed codes at their longest, which every choice
/// costs no more than.
pub fn bound(literals: usize, matches: usize) usize {
    return 3 + 9 * literals + (8 + 5 + 5 + 13) * matches + 7;
}

fn writeHeader(w: *bits.Writer, header: *const Header) void {
    w.add(header.hlit - 257, 5);
    w.add(header.hdist - 1, 5);
    w.add(header.hclen - 4, 4);
    w.flush();
    for (precode_order[0..header.hclen]) |sym| {
        w.add(header.pre_lens[sym], 3);
        w.flush();
    }
    for (header.items[0..header.n_items]) |item| {
        const sym = item & 0xff;
        w.add(header.pre_codes[sym], @intCast(header.pre_lens[sym]));
        switch (sym) {
            16 => w.add(item >> 8, 2),
            17 => w.add(item >> 8, 3),
            18 => w.add(item >> 8, 7),
            else => {},
        }
        w.flush();
    }
}

fn writeData(comptime interleaved: bool, out: *bits.Writer, data: []const u8, seqs: []const Sequence, tail: u32, code: *const Code) void {
    // A small block costs less written symbol by symbol than its tables.
    if (data.len < 2048 and seqs.len < 128) return writeFew(interleaved, out, data, seqs, tail, code);
    // Each literal's codeword and length in one entry, each match length's
    // codeword with its extra bits after it, each distance symbol's
    // codeword and length: one load and one add per field.
    var literal: [256]u32 = undefined;
    for (&literal, code.litlen_codes[0..256], code.litlen_lens[0..256]) |*e, c, l| e.* = @as(u32, l) << 16 | c;
    var length: [259]u32 = undefined;
    for (3..259) |len| {
        const sym = lengthSymbol(@intCast(len));
        const i = sym - 257;
        const clen: u32 = code.litlen_lens[sym];
        const extra: u32 = @intCast(len - decode.length_base[i]);
        length[len] = (clen + decode.length_extra[i]) << 24 | extra << @intCast(clen) | code.litlen_codes[sym];
    }
    var dist: [30]u32 = undefined;
    for (&dist, code.dist_codes[0..30], code.dist_lens[0..30]) |*e, c, l| e.* = @as(u32, l) << 16 | c;

    // A local writer: its fields stay in registers, where stores to the
    // output could not move them.
    var local = out.*;
    defer out.* = local;
    const w = &local;
    var at: usize = 0;
    for (seqs) |s| {
        // Three literals at most between flushes: 45 bits.
        var left = s.literals;
        while (left >= 3) : (left -= 3) {
            inline for (0..3) |k| {
                const e = literal[data[at + k]];
                w.add(e & 0xffff, @intCast(e >> 16));
            }
            at += 3;
            w.flush();
        }
        // Up to two more (30 bits), then the length (20): under 64 with the
        // seven bits a flush may leave.
        while (left > 0) : (left -= 1) {
            const e = literal[data[at]];
            w.add(e & 0xffff, @intCast(e >> 16));
            at += 1;
        }
        const l = length[s.length];
        w.add(l & 0xff_ffff, @intCast(l >> 24));
        w.flush();
        const ds = distSymbol(s.distance);
        const d = dist[ds];
        const dlen: u6 = @intCast(d >> 16);
        w.add(@as(u64, s.distance - decode.dist_base[ds]) << dlen | (d & 0xffff), dlen + @as(u6, @intCast(decode.dist_extra[ds])));
        w.flush();
        if (interleaved) at += s.length;
    }
    for (data[at..][0..tail]) |b| {
        const e = literal[b];
        w.add(e & 0xffff, @intCast(e >> 16));
        w.flush();
    }
    w.add(code.litlen_codes[end_of_block], @intCast(code.litlen_lens[end_of_block]));
    w.flush();
}

/// `writeData` for a few symbols: each looked up where it is written.
fn writeFew(comptime interleaved: bool, w: *bits.Writer, data: []const u8, seqs: []const Sequence, tail: u32, code: *const Code) void {
    var at: usize = 0;
    for (seqs) |s| {
        for (data[at..][0..s.literals]) |b| {
            w.add(code.litlen_codes[b], @intCast(code.litlen_lens[b]));
            w.flush();
        }
        at += s.literals;
        const ls = lengthSymbol(s.length);
        const li = ls - 257;
        w.add(code.litlen_codes[ls], @intCast(code.litlen_lens[ls]));
        w.add(s.length - decode.length_base[li], @intCast(decode.length_extra[li]));
        const ds = distSymbol(s.distance);
        w.add(code.dist_codes[ds], @intCast(code.dist_lens[ds]));
        w.flush();
        w.add(s.distance - decode.dist_base[ds], @intCast(decode.dist_extra[ds]));
        w.flush();
        if (interleaved) at += s.length;
    }
    for (data[at..][0..tail]) |b| {
        w.add(code.litlen_codes[b], @intCast(code.litlen_lens[b]));
        w.flush();
    }
    w.add(code.litlen_codes[end_of_block], @intCast(code.litlen_lens[end_of_block]));
    w.flush();
}

/// Stored blocks of at most 65,535 bytes each.
pub fn writeStored(w: *bits.Writer, data: []const u8, final: bool) void {
    var rest = data;
    while (true) {
        const chunk = rest[0..@min(rest.len, 65535)];
        rest = rest[chunk.len..];
        const last = final and rest.len == 0;
        w.add(@intFromBool(last), 3);
        w.alignToByte();
        const len: u16 = @intCast(chunk.len);
        w.add(len, 16);
        w.add(~len, 16);
        w.flush();
        w.writeBytes(chunk);
        if (rest.len == 0) return;
    }
}

test "length and distance symbols are RFC 1951's" {
    try std.testing.expectEqual(@as(u32, 257), lengthSymbol(3));
    try std.testing.expectEqual(@as(u32, 265), lengthSymbol(11));
    try std.testing.expectEqual(@as(u32, 265), lengthSymbol(12));
    try std.testing.expectEqual(@as(u32, 284), lengthSymbol(257));
    try std.testing.expectEqual(@as(u32, 285), lengthSymbol(258));
    try std.testing.expectEqual(@as(u32, 0), distSymbol(1));
    try std.testing.expectEqual(@as(u32, 4), distSymbol(5));
    try std.testing.expectEqual(@as(u32, 15), distSymbol(256));
    try std.testing.expectEqual(@as(u32, 16), distSymbol(257));
    try std.testing.expectEqual(@as(u32, 29), distSymbol(32768));
    try std.testing.expectEqual(@as(u32, 29), distSymbol(24577));
    try std.testing.expectEqual(@as(u32, 28), distSymbol(24576));
}

test "refined dynamic header cost matches its serialized bits" {
    for (0..64) |seed| {
        const input = try gen.alloc(std.testing.allocator, .text, seed, 1024);
        defer std.testing.allocator.free(input);
        var counts: Counts = .{};
        for (input) |byte| counts.literal(byte);
        counts.litlen[end_of_block] += 1;
        var code: Code = undefined;
        var header: Header = undefined;
        const expected = dynamicCode(&counts, &code, &header, true, std.math.maxInt(u64));
        codewords(&code, &header);
        var buffer: [2048]u8 = undefined;
        var writer: bits.Writer = .init(&buffer, 0);
        writeHeader(&writer, &header);
        writeData(false, &writer, input, &.{}, @intCast(input.len), &code);
        try std.testing.expectEqual(expected, writer.bitPosition());
    }
}

test "a block with nothing in it is the fixed code's end of block, whatever may be chosen" {
    for ([_]Kinds{ .any, .optimal, .no_dynamic }) |kinds| {
        for ([_]bool{ true, false }) |final| {
            var buffer: [16]u8 = undefined;
            var writer: bits.Writer = .init(&buffer, 0);
            const counts: Counts = .{};
            write(false, &writer, .{ .bytes = &.{}, .raw = &.{} }, &.{}, 0, &counts, final, kinds);
            writer.alignToByte();
            try std.testing.expectEqualSlices(u8, &.{ if (final) 3 else 2, 0 }, buffer[0..writer.at]);
        }
    }
}

test "a dynamic cost that cannot beat the bound is not refined, and is never below the exact one" {
    for (0..16) |seed| {
        const input = try gen.alloc(std.testing.allocator, .text, seed, 600 + 40 * seed);
        defer std.testing.allocator.free(input);
        var counts: Counts = .{};
        for (input) |byte| counts.literal(byte);
        counts.litlen[end_of_block] += 1;
        var code: Code = undefined;
        var header: Header = undefined;
        const exact = dynamicCode(&counts, &code, &header, true, std.math.maxInt(u64));
        for ([_]u64{ 0, exact -| 40, exact -| 1, exact, exact + 1, exact + 40 }) |beat| {
            const cost = dynamicCode(&counts, &code, &header, true, beat);
            try std.testing.expect(cost >= exact);
            // Whatever is below the bound is the exact cost.
            if (cost < beat or exact < beat) try std.testing.expectEqual(exact, cost);
        }
    }
}
