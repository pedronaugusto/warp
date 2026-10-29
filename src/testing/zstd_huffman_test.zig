//! zstd's Huffman streams decoded on their own: `decode1` and `decode4` on
//! tables read back from the encoder's own descriptions, both kinds of
//! table, and `Symbols`, the partial decoder, read in pieces. The encoder's
//! streams round-trip; cut, extended and flipped ones are refused or decode
//! alike, with one difference the reference decoder has too: a double
//! table's last lookup may hold two symbols, and like `HUF_decodeLastSymbolX2`
//! it takes both codes' bits up to the stream's start, so it accepts a few
//! stray bits there that a single table refuses. A single table is the
//! strict one: what it accepts, a double table decodes to the same bytes.

const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const huffman = @import("../zstd/huffman.zig");

/// Bytes over a skewed alphabet of two or more symbols.
fn literals(case: *shakedown.Case, min_len: usize) ![]u8 {
    const s = case.source;
    var alphabet: [256]u8 = undefined;
    const size = shakedown.gen.intRange(s, usize, 2, 256);
    for (alphabet[0..size]) |*a| a.* = shakedown.gen.int(s, u8);
    const out = try case.gpa.alloc(u8, shakedown.gen.intRange(s, usize, min_len, 3000));
    for (out) |*b| {
        // The smallest of a few draws: early symbols are common.
        var k = shakedown.gen.intRange(s, usize, 0, size - 1);
        for (0..shakedown.gen.intRange(s, usize, 0, 3)) |_| k = @min(k, shakedown.gen.intRange(s, usize, 0, size - 1));
        b.* = alphabet[k];
    }
    // Two symbols at least, as a Huffman literals block has.
    out[0] = alphabet[0];
    out[out.len - 1] = alphabet[1] +% @intFromBool(alphabet[1] == alphabet[0]);
    return out;
}

const Tables = struct { single: huffman.Table, double: huffman.Table };

/// The decoder's tables for `data`, from the encoder's description; null
/// when the encoder writes none.
fn tablesFor(case: *shakedown.Case, data: []const u8, code: *huffman.EncodeTable) !?*Tables {
    var counts: [huffman.max_symbols]u32 = undefined;
    const h = huffman.histogram(data, &counts);
    code.build(counts[0 .. @as(usize, h.max_symbol) + 1], huffman.optimalLog(huffman.encode_log, data.len, h.max_symbol));
    var description: [256]u8 = undefined;
    const n = code.writeDescription(&description) orelse return null;
    const weights = try huffman.readWeights({}, description[0..n]);
    const t = try case.gpa.create(Tables);
    t.single.buildSingle(&weights);
    t.double.buildDouble(&weights);
    return t;
}

/// `stream` cut, extended or with bits flipped.
fn damaged(case: *shakedown.Case, stream: []const u8) ![]u8 {
    const s = case.source;
    var out = try case.gpa.alloc(u8, stream.len + 4);
    @memcpy(out[0..stream.len], stream);
    for (out[stream.len..]) |*b| b.* = shakedown.gen.int(s, u8);
    var len = stream.len;
    switch (shakedown.gen.intRange(s, u8, 0, 2)) {
        0 => len = shakedown.gen.intRange(s, usize, 0, stream.len),
        1 => len = stream.len + shakedown.gen.intRange(s, usize, 1, 4),
        else => {},
    }
    for (0..shakedown.gen.intRange(s, usize, 0, 3)) |_| {
        if (len > 0) out[shakedown.gen.intRange(s, usize, 0, len - 1)] ^= @as(u8, 1) << shakedown.gen.intRange(s, u3, 0, 7);
    }
    return out[0..len];
}

/// What one path made of a stream: refused, or these bytes.
fn decoded(gpa: std.mem.Allocator, t: *const huffman.Table, four: bool, stream: []const u8, len: usize) !?[]u8 {
    const out = try gpa.alloc(u8, len);
    const result = if (four) huffman.decode4(t, stream, out) else huffman.decode1(t, stream, out);
    result catch return null;
    return out;
}

/// `Symbols` read in pieces whose sizes the case draws.
fn inPieces(case: *shakedown.Case, t: *const huffman.Table, four: bool, stream: []const u8, len: usize) !?[]u8 {
    const out = try case.gpa.alloc(u8, len);
    var symbols = huffman.Symbols.init(t, stream, len, !four) catch return null;
    var at: usize = 0;
    while (at < len) {
        const n = shakedown.gen.intRange(case.source, usize, 1, len - at);
        symbols.read(out[at..][0..n]) catch return null;
        at += n;
    }
    return out;
}

fn expectSame(a: ?[]const u8, b: ?[]const u8) !void {
    try testing.expectEqual(a == null, b == null);
    if (a) |x| try testing.expectEqualSlices(u8, x, b.?);
}

fn decodesAlike(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const four = shakedown.gen.boolean(s);
    const data = try literals(case, if (four) 12 else 2);
    const code = try case.gpa.create(huffman.EncodeTable);
    const tables = try tablesFor(case, data, code) orelse return;
    const room = try case.gpa.alloc(u8, data.len * 2 + 64);
    const n = if (four) huffman.compress4(code, data, room) else huffman.compress1(code, data, room);
    if (n == 0) return;
    const stream = room[0..n];
    case.note("{d} symbols, {s}, stream of {d}", .{ data.len, if (four) "four streams" else "one stream", n });

    // The encoder's stream, back by every path.
    for ([_]*const huffman.Table{ &tables.single, &tables.double }) |t| {
        try expectSame(data, try decoded(case.gpa, t, four, stream, data.len));
        try expectSame(data, try inPieces(case, t, four, stream, data.len));
    }

    // Damaged, and asked for a length near the real one: each table's
    // partial decoder agrees with it, and the double table accepts what the
    // single one does, with the same bytes.
    const bad = try damaged(case, stream);
    const min_len: usize = if (four) 6 else 1;
    const len = @max(min_len, data.len -| 2 + shakedown.gen.intRange(s, usize, 0, 4));
    const strict = try decoded(case.gpa, &tables.single, four, bad, len);
    const lenient = try decoded(case.gpa, &tables.double, four, bad, len);
    if (strict) |bytes| try expectSame(bytes, lenient);
    try expectSame(strict, try inPieces(case, &tables.single, four, bad, len));
    try expectSame(lenient, try inPieces(case, &tables.double, four, bad, len));
}

test "fuzz: Huffman streams round-trip through decode1/decode4, and damaged ones decode alike by every path or are refused" {
    try shakedown.check(testing.allocator, {}, decodesAlike, .{ .cases = 3000, .seed = 0x4f7 });
}
