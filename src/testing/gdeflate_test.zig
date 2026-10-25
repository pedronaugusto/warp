//! GDeflate against Microsoft's reference codec (testdata/gdeflate.corpus,
//! captured in trials warp/gdeflate): every tile stream it wrote at levels
//! 1-12 decodes to its input, page by page and whole; and each page is
//! what warp's lane writer writes for the blocks and symbols the page
//! holds, byte for byte, so the writer lays out the format and not only
//! something one decoder reads. warp's own streams round-trip at every
//! level. Fuzzing checks the decoder against a plain one written here,
//! which also reads the reference's pages for the writer.

const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const gen = @import("gen");
const corpus = @import("corpus.zig");
const gdeflate = @import("../gdeflate.zig");
const lanes = @import("../gdeflate/lanes.zig");
const block = @import("../deflate/block.zig");
const huffman = @import("../huffman.zig");

const captured = @embedFile("gdeflate.corpus");

const Error = gdeflate.Error || error{OutOfMemory};

/// A code as the plain decoder reads it, a bit at a time (puff's way):
/// how many codes of each length, and the symbols in canonical order.
const Code = struct {
    count: [16]u16 = @splat(0),
    symbol: [320]u16 = undefined,
    /// No symbols: every bit pattern is refused.
    empty: bool = false,

    /// The code for `lens`, or why warp refuses it: oversubscribed, or
    /// incomplete but for a single one-bit code (or none) outside the
    /// precode.
    fn init(lens: []const u8, precode: bool) error{InvalidStream}!Code {
        var c: Code = .{};
        for (lens) |l| c.count[l] += 1;
        c.count[0] = 0;
        var max: usize = 0;
        for (1..16) |l| {
            if (c.count[l] != 0) max = l;
        }
        if (max == 0) {
            c.empty = true;
            return c;
        }
        var left: i32 = 1;
        for (1..16) |l| {
            left = left * 2 - c.count[l];
            if (left < 0) return error.InvalidStream;
        }
        if (left > 0 and (precode or max != 1)) return error.InvalidStream;
        var offs: [16]u16 = undefined;
        offs[1] = 0;
        for (1..15) |l| offs[l + 1] = offs[l] + c.count[l];
        for (lens, 0..) |l, sym| {
            if (l == 0) continue;
            c.symbol[offs[l]] = @intCast(sym);
            offs[l] += 1;
        }
        return c;
    }
};

/// One block as the plain decoder read it.
const Block = struct {
    final: bool,
    kind: u2,
    /// Stored: the bytes. Dynamic: the header and the code lengths.
    stored: []const u8 = &.{},
    header: block.Header = undefined,
    lens: [320]u8 = @splat(0),
    hlit: usize = 0,
    tokens: std.ArrayList(lanes.Token) = .empty,
};

/// A GDeflate page decoder written from the format's description, a bit
/// and a lane at a time, recording what it reads.
const Plain = struct {
    in: []const u8,
    ip: usize = 0,
    buf: [32]u64 = @splat(0),
    left: [32]u8 = @splat(0),
    lane: u5 = 0,
    gpa: std.mem.Allocator,
    blocks: std.ArrayList(Block) = .empty,

    fn ensure(p: *Plain, lane: u5) Error!void {
        if (p.left[lane] >= 32) return;
        if (p.in.len - p.ip < 4) return error.Truncated;
        p.buf[lane] |= @as(u64, std.mem.readInt(u32, p.in[p.ip..][0..4], .little)) << @intCast(p.left[lane]);
        p.left[lane] += 32;
        p.ip += 4;
    }

    fn bit(p: *Plain) u1 {
        const b: u1 = @truncate(p.buf[p.lane]);
        p.buf[p.lane] >>= 1;
        p.left[p.lane] -= 1;
        return b;
    }

    fn bitsOf(p: *Plain, n: usize) u32 {
        var v: u32 = 0;
        for (0..n) |i| v |= @as(u32, p.bit()) << @intCast(i);
        return v;
    }

    fn advance(p: *Plain) Error!void {
        try p.ensure(p.lane);
        p.lane +%= 1;
    }

    /// The next symbol of `c`, its codeword read a bit at a time.
    fn decodeSym(p: *Plain, c: *const Code) Error!u16 {
        if (c.empty) return error.InvalidStream;
        var code: i32 = 0;
        var first: i32 = 0;
        var index: i32 = 0;
        // Peek a bit at a time without consuming past the codeword.
        const saved = p.buf[p.lane];
        for (1..16) |len| {
            code |= @as(i32, @intCast((saved >> @intCast(len - 1)) & 1));
            const count: i32 = c.count[len];
            if (code - first < count) {
                p.buf[p.lane] = saved >> @intCast(len);
                p.left[p.lane] -= @intCast(len);
                return c.symbol[@intCast(index + code - first)];
            }
            index += count;
            first += count;
            first <<= 1;
            code <<= 1;
        }
        return error.InvalidStream;
    }

    fn page(p: *Plain, out: []u8) Error!usize {
        for (0..32) |l| try p.ensure(@intCast(l));
        var op: usize = 0;
        while (true) {
            p.lane = 0;
            var b: Block = .{ .final = p.bit() == 1, .kind = @intCast(p.bitsOf(2)) };
            try p.ensure(0);
            var lit: Code = undefined;
            var dist: Code = undefined;
            switch (b.kind) {
                0 => {
                    const len = p.bitsOf(16);
                    if (len > out.len - op) return error.OutputTooSmall;
                    for (0..len) |i| {
                        out[op + i] = @intCast(p.bitsOf(8));
                        try p.advance();
                    }
                    b.stored = out[op..][0..len];
                    op += len;
                },
                1 => {
                    var lens: [320]u8 = undefined;
                    @memset(lens[0..144], 8);
                    @memset(lens[144..256], 9);
                    @memset(lens[256..280], 7);
                    @memset(lens[280..288], 8);
                    // unreachable: the fixed codes are complete
                    lit = Code.init(lens[0..288], false) catch unreachable;
                    @memset(lens[0..32], 5);
                    // unreachable: the fixed codes are complete
                    dist = Code.init(lens[0..32], false) catch unreachable;
                },
                2 => {
                    try p.dynamicHeader(&b);
                    lit = try Code.init(b.lens[0..b.hlit], false);
                    dist = try Code.init(b.lens[b.hlit .. b.hlit + b.header.hdist], false);
                },
                else => return error.InvalidStream,
            }
            var pending: [32]?struct { at: usize, len: usize, sym: u16, extra: u32, token: usize } = @splat(null);
            if (b.kind != 0) {
                p.lane = 0;
                while (true) {
                    if (pending[p.lane]) |m| {
                        try p.copy(out, &b, m.at, m.len, m.token, &dist);
                        pending[p.lane] = null;
                    } else {
                        const sym = try p.decodeSym(&lit);
                        if (sym < 256) {
                            if (op == out.len) return error.OutputTooSmall;
                            out[op] = @intCast(sym);
                            op += 1;
                            try b.tokens.append(p.gpa, .{ .literal = @intCast(sym) });
                        } else if (sym == 256) {
                            break;
                        } else {
                            if (sym > 285) return error.InvalidStream;
                            const i = sym - 257;
                            const extra_bits: usize = if (sym == 285) 16 else huffman.decode.length_extra[i];
                            const base: usize = if (sym == 285) 3 else huffman.decode.length_base[i];
                            const extra = p.bitsOf(extra_bits);
                            const len = base + extra;
                            if (len > out.len - op) return error.OutputTooSmall;
                            try b.tokens.append(p.gpa, .{ .match = .{ .length_symbol = sym, .length_extra = extra, .distance_symbol = 0, .distance_extra = 0 } });
                            pending[p.lane] = .{ .at = op, .len = len, .sym = sym, .extra = extra, .token = b.tokens.items.len - 1 };
                            op += len;
                        }
                    }
                    try p.advance();
                }
            }
            for (0..32) |_| {
                if (pending[p.lane]) |m| {
                    try p.copy(out, &b, m.at, m.len, m.token, &dist);
                    pending[p.lane] = null;
                }
                try p.advance();
            }
            try p.blocks.append(p.gpa, b);
            if (b.final) return op;
        }
    }

    fn copy(p: *Plain, out: []u8, b: *Block, at: usize, len: usize, token: usize, dist: *const Code) Error!void {
        const sym = try p.decodeSym(dist);
        const extra_bits: usize = if (sym >= 30) 14 else huffman.decode.dist_extra[sym];
        const base: usize = if (sym == 30) 32769 else if (sym == 31) 49153 else huffman.decode.dist_base[sym];
        const extra = p.bitsOf(extra_bits);
        const d = base + extra;
        if (d > at) return error.InvalidStream;
        for (0..len) |i| out[at + i] = out[at + i - d];
        b.tokens.items[token].match.distance_symbol = @intCast(sym);
        b.tokens.items[token].match.distance_extra = extra;
    }

    fn dynamicHeader(p: *Plain, b: *Block) Error!void {
        const h = &b.header;
        h.hlit = @intCast(p.bitsOf(5) + 257);
        h.hdist = @intCast(p.bitsOf(5) + 1);
        h.hclen = @intCast(p.bitsOf(4) + 4);
        if (h.hlit > 286) return error.InvalidStream;
        try p.ensure(0);
        h.pre_lens = @splat(0);
        for (block.precode_order[0..h.hclen]) |sym| {
            h.pre_lens[sym] = @intCast(p.bitsOf(3));
            try p.advance();
        }
        const pre = try Code.init(&h.pre_lens, true);
        p.lane = 0;
        const total: usize = h.hlit + h.hdist;
        var i: usize = 0;
        var n: usize = 0;
        while (i < total) {
            // An empty precode reads every bit as symbol 0, one bit long.
            const sym: u16 = if (pre.empty) blk: {
                _ = p.bit();
                break :blk 0;
            } else try p.decodeSym(&pre);
            if (sym < 16) {
                b.lens[i] = @intCast(sym);
                i += 1;
                h.items[n] = sym;
            } else {
                const extra = switch (sym) {
                    16 => p.bitsOf(2),
                    17 => p.bitsOf(3),
                    else => p.bitsOf(7),
                };
                const repeat: usize = switch (sym) {
                    16 => 3 + extra,
                    17 => 3 + extra,
                    else => 11 + extra,
                };
                if (sym == 16 and i == 0) return error.InvalidStream;
                const fill: u8 = if (sym == 16) b.lens[i - 1] else 0;
                if (i + repeat > total) return error.InvalidStream;
                @memset(b.lens[i..][0..repeat], fill);
                i += repeat;
                h.items[n] = sym | @as(u16, @intCast(extra)) << 8;
            }
            n += 1;
            try p.advance();
        }
        h.n_items = @intCast(n);
        b.hlit = h.hlit;
        if (b.lens[256] == 0) return error.InvalidStream;
    }

    fn deinit(p: *Plain) void {
        for (p.blocks.items) |*b| b.tokens.deinit(p.gpa);
        p.blocks.deinit(p.gpa);
    }
};

/// The plain decoder's answer for a page: its output, or its error.
fn plainPage(gpa: std.mem.Allocator, in: []const u8, out: []u8) Error!usize {
    var p: Plain = .{ .in = in, .gpa = gpa };
    defer p.deinit();
    return p.page(out);
}

/// The pages of a tile stream, as `gdeflate.Decompressor` finds them.
fn pages(gpa: std.mem.Allocator, stream: []const u8) ![]const []const u8 {
    const tiles = std.mem.readInt(u16, stream[2..4], .little);
    const data = 8 + 4 * @as(usize, tiles);
    const list = try gpa.alloc([]const u8, tiles);
    for (0..tiles) |i| {
        const entry = struct {
            fn at(s: []const u8, k: usize) usize {
                return std.mem.readInt(u32, s[8 + 4 * k ..][0..4], .little);
            }
        }.at;
        const start = if (i == 0) 0 else entry(stream, i);
        const end = if (i + 1 < tiles) entry(stream, i + 1) else start + entry(stream, 0);
        list[i] = stream[data + start .. data + end];
    }
    return list;
}

test "the reference's tile streams decode to their inputs, whole and page by page" {
    const gpa = testing.allocator;
    var d: gdeflate.Decompressor = .init;
    const c = try corpus.Corpus.parse(captured);
    var it = c.records();
    var count: usize = 0;
    while (it.next()) |r| : (count += 1) {
        errdefer std.debug.print("{s} level {s}: {s}\n", .{ r.fields[0], r.fields[1], r.fields[2] });
        const in = try corpus.input(gpa, r.fields[2]);
        defer gpa.free(in);
        const stream = r.fields[3];
        const info = try gdeflate.inspect(stream, null);
        try testing.expectEqual(in.len, info.size);
        const out = try gpa.alloc(u8, in.len + 1);
        defer gpa.free(out);
        try testing.expectEqual(in.len, try d.decompress(stream, out, .{}));
        try testing.expectEqualSlices(u8, in, out[0..in.len]);
        // Room for one byte less is refused.
        try testing.expectError(error.OutputTooSmall, d.decompress(stream, out[0 .. in.len - 1], .{}));
        const list = try pages(gpa, stream);
        defer gpa.free(list);
        for (list, 0..) |page, i| {
            const tile = in[i * gdeflate.tile_size .. @min(in.len, (i + 1) * gdeflate.tile_size)];
            const n = try d.decompressPage(page, out, .{});
            try testing.expectEqualSlices(u8, tile, out[0..n]);
            try testing.expectEqual(n, try plainPage(gpa, page, out));
            try testing.expectEqualSlices(u8, tile, out[0..n]);
        }
    }
    try testing.expectEqual(144, count);
}

test "each reference page is what the lane writer writes for its blocks and symbols, byte for byte" {
    const gpa = testing.allocator;
    const c = try corpus.Corpus.parse(captured);
    var it = c.records();
    const out = try gpa.alloc(u8, gdeflate.tile_size);
    defer gpa.free(out);
    const again = try gpa.alloc(u8, gdeflate.pageBound(gdeflate.tile_size));
    defer gpa.free(again);
    var kinds: [3]usize = @splat(0);
    var long_matches: usize = 0;
    while (it.next()) |r| {
        errdefer std.debug.print("{s} level {s}: {s}\n", .{ r.fields[0], r.fields[1], r.fields[2] });
        const list = try pages(gpa, r.fields[3]);
        defer gpa.free(list);
        for (list) |page| {
            var p: Plain = .{ .in = page, .gpa = gpa };
            defer p.deinit();
            _ = try p.page(out);
            var w: lanes.Writer = .init(again);
            for (p.blocks.items) |*b| {
                kinds[b.kind] += 1;
                var tokens: Tokens = .{ .list = b.tokens.items };
                for (b.tokens.items) |t| long_matches += @intFromBool(t == .match and t.match.length_symbol == 285);
                switch (b.kind) {
                    0 => w.writeStored(b.stored, b.final),
                    1 => {
                        w.blockHeader(b.final, 1);
                        w.writeTokens(&tokens, &block.fixed);
                    },
                    2 => {
                        huffman.encode.canonicalCodes(&b.header.pre_lens, &b.header.pre_codes);
                        var code: block.Code = .{ .litlen_codes = undefined, .litlen_lens = @splat(0), .dist_codes = undefined, .dist_lens = @splat(0) };
                        @memcpy(code.litlen_lens[0..b.hlit], b.lens[0..b.hlit]);
                        @memcpy(code.dist_lens[0..b.header.hdist], b.lens[b.hlit..][0..b.header.hdist]);
                        huffman.encode.canonicalCodes(&code.litlen_lens, &code.litlen_codes);
                        huffman.encode.canonicalCodes(&code.dist_lens, &code.dist_codes);
                        w.blockHeader(b.final, 2);
                        w.writeHeader(&b.header);
                        w.writeTokens(&tokens, &code);
                    },
                    else => unreachable,
                }
            }
            try testing.expect(!w.overflow);
            const n = w.finish();
            try testing.expectEqualSlices(u8, page, again[0..n]);
        }
    }
    // Every kind of block, and the reference's length symbol 285, were seen.
    for (kinds) |k| try testing.expect(k > 0);
    try testing.expect(long_matches > 0);
}

/// Recorded tokens, as `lanes.Writer.writeTokens` takes them.
const Tokens = struct {
    list: []const lanes.Token,
    i: usize = 0,

    pub fn next(t: *Tokens) ?lanes.Token {
        if (t.i == t.list.len) return null;
        t.i += 1;
        return t.list[t.i - 1];
    }
};

test "warp's tile streams round-trip at every level, through both decoders" {
    const gpa = testing.allocator;
    var d: gdeflate.Decompressor = .init;
    for ([_][]const u8{ "", "text 1 1", "text 2 70000", "noise 3 70000", "zeros 4 200000", "runs 5 131072", "json 6 40000 + noise 7 30000 + json 6 40000" }) |spec| {
        const in = if (spec.len == 0) try gpa.alloc(u8, 0) else try corpus.input(gpa, spec);
        defer gpa.free(in);
        const out = try gpa.alloc(u8, gdeflate.bound(in.len));
        defer gpa.free(out);
        const back = try gpa.alloc(u8, in.len);
        defer gpa.free(back);
        for (0..13) |level| {
            errdefer std.debug.print("{s} level {d}\n", .{ spec, level });
            var c: gdeflate.Compressor = try .init(gpa, .{ .level = @intCast(level) });
            defer c.deinit();
            const n = try c.compress(in, out);
            try testing.expectEqual(in.len, try d.decompress(out[0..n], back, .{}));
            try testing.expectEqualSlices(u8, in, back);
            const list = try pages(gpa, out[0..n]);
            defer gpa.free(list);
            for (list, 0..) |page, i| {
                const m = try plainPage(gpa, page, back);
                try testing.expectEqualSlices(u8, in[i * gdeflate.tile_size ..][0..m], back[0..m]);
            }
            // One byte less room is refused, never overrun.
            if (n > 0) try testing.expectError(error.OutputTooSmall, c.compress(in, out[0 .. n - 1]));
        }
    }
}

test "pages stay within their bound, and the stream within its own" {
    const gpa = testing.allocator;
    var c: gdeflate.Compressor = try .init(gpa, .{ .level = 6 });
    defer c.deinit();
    for ([_]gen.Kind{ .noise, .text, .runs }) |kind| {
        for ([_]usize{ 0, 1, 127, 4096, 65535, 65536 }) |len| {
            const in = try gen.alloc(gpa, kind, 9, len);
            defer gpa.free(in);
            const out = try gpa.alloc(u8, gdeflate.pageBound(len));
            defer gpa.free(out);
            _ = try c.compressPage(in, out);
        }
    }
    const in = try gen.alloc(gpa, .noise, 10, 3 * gdeflate.tile_size + 5);
    defer gpa.free(in);
    const out = try gpa.alloc(u8, gdeflate.bound(in.len));
    defer gpa.free(out);
    _ = try c.compress(in, out);
}

test "tile stream headers: the codec ID, the tile size, offsets within the input" {
    var d: gdeflate.Decompressor = .init;
    var out: [16]u8 = undefined;
    var diag: gdeflate.Diagnostic = .{};
    // No tiles: no bytes.
    try testing.expectEqual(0, try d.decompress(&.{ 4, 0xfb, 0, 0, 1, 0, 0, 0 }, &out, .{}));
    try testing.expectError(error.Truncated, d.decompress(&.{ 4, 0xfb, 0 }, &out, .{ .diagnostic = &diag }));
    try testing.expectEqual(.truncated, diag.reason);
    try testing.expectError(error.InvalidStream, d.decompress(&.{ 4, 0xfa, 0, 0, 1, 0, 0, 0 }, &out, .{ .diagnostic = &diag }));
    try testing.expectEqual(.bad_magic, diag.reason);
    try testing.expectError(error.InvalidStream, d.decompress(&.{ 4, 0xfb, 0, 0, 2, 0, 0, 0 }, &out, .{ .diagnostic = &diag }));
    try testing.expectEqual(.bad_tile_size, diag.reason);
    // One tile of 5 bytes whose page is 200 bytes long, past the input.
    try testing.expectError(error.InvalidStream, d.decompress(&.{ 4, 0xfb, 1, 0, 1 | 5 << 2, 0, 0, 0, 200, 0, 0, 0 }, &out, .{ .diagnostic = &diag }));
    try testing.expectEqual(.bad_tile_offsets, diag.reason);
}

fn pageAgrees(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    var input: []u8 = undefined;
    if (shakedown.gen.boolean(s)) {
        input = try shakedown.gen.string(s, case.gpa, .{ .kind = .bytes, .max_len = 1200, .average = 200 });
    } else {
        const plain = try gen.alloc(case.gpa, shakedown.gen.enumValue(s, gen.Kind), shakedown.gen.int(s, u16), shakedown.gen.intRange(s, usize, 0, 5000));
        var c: gdeflate.Compressor = try .init(case.gpa, .{ .level = shakedown.gen.intRange(s, u4, 0, 12) });
        defer c.deinit();
        const out = try case.gpa.alloc(u8, gdeflate.pageBound(plain.len));
        input = out[0..try c.compressPage(plain, out)];
        for (0..shakedown.gen.intRange(s, usize, 0, 3)) |_| {
            if (input.len == 0) break;
            input[shakedown.gen.intRange(s, usize, 0, input.len - 1)] ^= @as(u8, 1) << shakedown.gen.intRange(s, u3, 0, 7);
        }
        if (shakedown.gen.boolean(s)) input = input[0..shakedown.gen.intRange(s, usize, 0, input.len)];
    }
    const room = shakedown.gen.intRange(s, usize, 0, 8192);
    const left = try case.gpa.alloc(u8, room);
    const right = try case.gpa.alloc(u8, room);
    var d: gdeflate.Decompressor = .init;
    const expected = plainPage(case.gpa, input, left);
    const got = d.decompressPage(input, right, .{});
    if (expected) |n| {
        try testing.expectEqual(n, try got);
        try testing.expectEqualSlices(u8, left[0..n], right[0..n]);
    } else |err| try testing.expectError(err, got);
}

test "fuzz: any bytes into the page decoder answer as the plain decoder" {
    try shakedown.check(testing.allocator, {}, pageAgrees, .{ .cases = 2000, .seed = 0x6def1a7e });
}

fn streamAgrees(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const c = try corpus.Corpus.parse(captured);
    var it = c.records();
    var r = it.next().?;
    for (0..shakedown.gen.intRange(s, usize, 0, 143)) |_| r = it.next().?;
    const stream = try case.gpa.dupe(u8, r.fields[3]);
    for (0..shakedown.gen.intRange(s, usize, 1, 3)) |_| {
        stream[shakedown.gen.intRange(s, usize, 0, stream.len - 1)] ^= @as(u8, 1) << shakedown.gen.intRange(s, u3, 0, 7);
    }
    const cut = stream[0..if (shakedown.gen.boolean(s)) shakedown.gen.intRange(s, usize, 0, stream.len) else stream.len];
    var d: gdeflate.Decompressor = .init;
    const info = gdeflate.inspect(cut, null) catch |err| {
        try testing.expectError(err, d.decompress(cut, &.{}, .{}));
        return;
    };
    // A header that claims more than the corpus holds is not worth the
    // output it asks for.
    if (info.size > 1 << 20) return;
    const out = try case.gpa.alloc(u8, info.size);
    const n = d.decompress(cut, out, .{}) catch return;
    // Accepted: every tile is as the plain decoder reads it.
    const list = try pages(case.gpa, cut);
    const page_out = try case.gpa.alloc(u8, gdeflate.tile_size);
    for (list, 0..) |page, i| {
        const m = try plainPage(case.gpa, page, page_out);
        try testing.expectEqualSlices(u8, out[i * gdeflate.tile_size ..][0..m], page_out[0..m]);
    }
    try testing.expectEqual(info.size, n);
}

test "fuzz: mutated reference streams are refused or decode as the plain decoder reads their pages" {
    try shakedown.check(testing.allocator, {}, streamAgrees, .{ .cases = 600, .seed = 0x6def1a7f });
}
