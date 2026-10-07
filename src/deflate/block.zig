//! A block's contents and how they are written: the matches and literal
//! runs a parser chose, their symbol counts, and the cheapest of a stored,
//! fixed-code or dynamic-code block for them, by exact bit cost.

const std = @import("std");
const bits = @import("../bits.zig");
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
pub const Kinds = enum { any, no_dynamic, stored_only };

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
/// `codewords` makes the codewords.
fn dynamicCode(counts: *const Counts, code: *Code, header: *Header) u64 {
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

    var cost: u64 = 5 + 5 + 4 + 3 * hclen;
    for (header.items[0..n]) |item| {
        const sym = item & 0xff;
        cost += header.pre_lens[sym] + @as(u64, switch (sym) {
            16 => 2,
            17 => 3,
            18 => 7,
            else => 0,
        });
    }
    return cost + dataCost(counts, code);
}

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

/// Write one block of `data`: the matches in `seqs`, each after its
/// literals, then `tail` literals; the cheapest kind `kinds` allows for
/// `counts`, which do not include the end of the block.
pub fn write(w: *bits.Writer, data: []const u8, seqs: []const Sequence, tail: u32, counts_in: *const Counts, final: bool, kinds: Kinds) void {
    var counts = counts_in.*;
    counts.litlen[end_of_block] += 1;
    if (kinds == .stored_only) return writeStored(w, data, final);
    var code: Code = undefined;
    var header: Header = undefined;
    const fixed_cost = 3 + dataCost(&counts, &fixed);
    const dynamic_cost = if (kinds == .any) 3 + dynamicCode(&counts, &code, &header) else std.math.maxInt(u64);
    const stored_cost = storedCost(data.len, w.bitPosition());
    if (stored_cost < @min(fixed_cost, dynamic_cost)) return writeStored(w, data, final);
    if (fixed_cost <= dynamic_cost) {
        w.add(@as(u64, @intFromBool(final)) | 2, 3);
        writeData(w, data, seqs, tail, &fixed);
    } else {
        w.add(@as(u64, @intFromBool(final)) | 4, 3);
        codewords(&code, &header);
        writeHeader(w, &header);
        writeData(w, data, seqs, tail, &code);
    }
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

fn writeData(out: *bits.Writer, data: []const u8, seqs: []const Sequence, tail: u32, code: *const Code) void {
    // A small block costs less written symbol by symbol than its tables.
    if (data.len < 2048 and seqs.len < 128) return writeFew(out, data, seqs, tail, code);
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
        at += s.length;
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
fn writeFew(w: *bits.Writer, data: []const u8, seqs: []const Sequence, tail: u32, code: *const Code) void {
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
        at += s.length;
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
