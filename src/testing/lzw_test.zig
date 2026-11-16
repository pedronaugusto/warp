//! GIF's LZW against Wuffs 0.4.0-alpha.12 (testdata/lzw-streams.corpus,
//! captured in trials warp/lzw): every record's verdict, bytes read and
//! output, whole and in pieces. Then a plain decoder written here from
//! Wuffs's rules (its `std/lzw` README and decoder), an encoder that
//! writes every shape a GIF stream takes (clears early, late or never, a
//! full table kept, no end code, bytes after it), and the properties both
//! hold for warp's decoder whole and in pieces.

const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const lzw = @import("../lzw.zig");
const corpus = @import("corpus.zig");

const streams = @embedFile("lzw-streams.corpus");

const Verdict = enum { ok, bad_code, truncated };

const Plain = struct {
    out: []u8,
    /// The bytes read: through the byte holding the last bit of the last
    /// code read whole (the end code, a refused code, or the last before
    /// the input ends).
    in_len: usize,
    verdict: Verdict,
};

/// The plain decoder: each code's bytes kept whole, read bit by bit.
fn plainDecode(gpa: std.mem.Allocator, literal_width: u4, in: []const u8) !Plain {
    const clear: usize = @as(usize, 1) << literal_width;
    const end = clear + 1;
    var strings: [4096]?[]const u8 = @splat(null);
    var literals: [256]u8 = undefined;
    for (&literals, 0..) |*l, i| l.* = @truncate(i);
    for (0..clear) |i| strings[i] = literals[i..][0..1];
    var out: std.ArrayList(u8) = .empty;
    var bit: usize = 0;
    var width: usize = @as(usize, literal_width) + 1;
    var next = end;
    var prev: ?usize = null;
    while (true) {
        // Wuffs gives back the whole bytes after the last code it read.
        if (bit + width > in.len * 8) return .{ .out = try out.toOwnedSlice(gpa), .in_len = (bit + 7) / 8, .verdict = .truncated };
        var code: usize = 0;
        for (0..width) |k| code |= @as(usize, (in[(bit + k) / 8] >> @intCast((bit + k) % 8)) & 1) << @intCast(k);
        bit += width;
        const read = (bit + 7) / 8;
        var bytes: []const u8 = undefined;
        if (code == clear) {
            for (end..4096) |i| strings[i] = null;
            next = end;
            prev = null;
            width = @as(usize, literal_width) + 1;
            continue;
        } else if (code == end) {
            return .{ .out = try out.toOwnedSlice(gpa), .in_len = read, .verdict = .ok };
        } else if (code < next and strings[code] != null) {
            bytes = strings[code].?;
        } else if (code == next and next < 4096 and prev != null) {
            const p = strings[prev.?].?;
            const s = try gpa.alloc(u8, p.len + 1);
            @memcpy(s[0..p.len], p);
            s[p.len] = p[0];
            bytes = s;
        } else {
            return .{ .out = try out.toOwnedSlice(gpa), .in_len = read, .verdict = .bad_code };
        }
        try out.appendSlice(gpa, bytes);
        if (next < 4096) {
            if (prev) |p| {
                const before = strings[p].?;
                const s = try gpa.alloc(u8, before.len + 1);
                @memcpy(s[0..before.len], before);
                s[before.len] = bytes[0];
                strings[next] = s;
            }
            next += 1;
            if (width < 12) width += (next >> @intCast(width)) & 1;
            prev = code;
        }
    }
}

const EncodeOptions = struct {
    literal_width: u4 = 8,
    /// A clear code first, as GIF encoders write.
    clear_first: bool = true,
    /// A clear code after this many codes since the last, besides a full
    /// table's.
    clear_every: ?usize = null,
    /// Keep a full table and go on without adding (a "deferred clear"),
    /// where encoders clear.
    keep_full: bool = false,
    end: bool = true,
};

/// A GIF LZW encoder that tracks the decoder's table and widths.
fn encode(gpa: std.mem.Allocator, data: []const u8, options: EncodeOptions) ![]u8 {
    const lw = options.literal_width;
    const clear: u16 = @as(u16, 1) << lw;
    const end = clear + 1;
    var w: Bits = .{};
    var dict: std.AutoHashMapUnmanaged(u32, u16) = .empty;
    var next: u16 = end;
    var width: u5 = @as(u5, lw) + 1;
    var since: usize = 0;
    if (options.clear_first) try w.put(gpa, clear, width);
    var at: usize = 0;
    while (at < data.len) {
        // The longest string the table holds from here.
        var code: u16 = data[at] & @as(u8, @truncate(clear - 1));
        at += 1;
        while (at < data.len) {
            const key = (@as(u32, code) << 8) | (data[at] & @as(u8, @truncate(clear - 1)));
            const found = dict.get(key) orelse break;
            code = found;
            at += 1;
        }
        try w.put(gpa, code, width);
        since += 1;
        if (next < 4096) {
            next += 1;
            if (width < 12) width += @intCast((next >> @intCast(width)) & 1);
        }
        // The decoder adds this code and the next one's first byte when it
        // reads the next one, at `next` as it stands now; the encoder adds
        // it at once, at that index.
        if (at < data.len and next < 4096) {
            const key = (@as(u32, code) << 8) | (data[at] & @as(u8, @truncate(clear - 1)));
            try dict.put(gpa, key, next);
        }
        const full = next >= 4096;
        const due = if (options.clear_every) |n| since >= n else false;
        if (at < data.len and ((full and !options.keep_full) or due)) {
            try w.put(gpa, clear, width);
            dict.clearRetainingCapacity();
            next = end;
            width = @as(u5, lw) + 1;
            since = 0;
        }
    }
    if (options.end) try w.put(gpa, end, width);
    return w.finish(gpa);
}

/// Bits least significant first.
const Bits = struct {
    out: std.ArrayList(u8) = .empty,
    acc: u32 = 0,
    n: u5 = 0,

    fn put(b: *Bits, gpa: std.mem.Allocator, code: u16, width: u5) !void {
        // Literal width 0 reads 1-bit codes after a clear, where its end
        // code (2) is not one: such a stream cannot end there.
        if (@as(u32, code) >> width != 0) return error.Unencodable;
        b.acc |= @as(u32, code) << b.n;
        b.n += width;
        while (b.n >= 8) {
            try b.out.append(gpa, @truncate(b.acc));
            b.acc >>= 8;
            b.n -= 8;
        }
    }

    fn finish(b: *Bits, gpa: std.mem.Allocator) ![]u8 {
        if (b.n > 0) try b.out.append(gpa, @truncate(b.acc));
        return b.out.toOwnedSlice(gpa);
    }
};

/// warp's verdict on `in`, whole: the output, the bytes read and the verdict.
fn warpWhole(gpa: std.mem.Allocator, literal_width: u4, in: []const u8, cap: usize) !Plain {
    const out = try gpa.alloc(u8, cap);
    var diag: lzw.Diagnostic = .{};
    if (lzw.decompress(in, out, .{ .literal_width = literal_width, .diagnostic = &diag })) |r| {
        return .{ .out = out[0..r.out_len], .in_len = r.in_len, .verdict = .ok };
    } else |err| {
        const n: usize = @intCast(diag.output.raw());
        return switch (err) {
            error.InvalidStream => .{ .out = out[0..n], .in_len = @intCast(diag.offset.raw() + 1), .verdict = .bad_code },
            error.Truncated => .{ .out = out[0..n], .in_len = @intCast(diag.offset.raw()), .verdict = .truncated },
            else => err,
        };
    }
}

/// Piece sizes from a fuzz case's source.
const SourceCuts = struct {
    s: *shakedown.Source,
    fn size(c: SourceCuts, lo: usize, hi: usize) usize {
        return shakedown.gen.intRange(c.s, usize, lo, hi);
    }
};

/// Piece sizes from a seeded generator.
const RandomCuts = struct {
    r: std.Random,
    fn size(c: RandomCuts, lo: usize, hi: usize) usize {
        return c.r.intRangeAtMost(usize, lo, hi);
    }
};

/// warp's verdict on `in` fed in pieces of sizes `cuts` draws, with
/// output in pieces too.
fn warpPieces(gpa: std.mem.Allocator, literal_width: u4, in: []const u8, cuts: anytype) !Plain {
    var diag: lzw.Diagnostic = .{};
    var d: lzw.Decompress = try .init(.{ .literal_width = literal_width, .diagnostic = &diag });
    var out: std.ArrayList(u8) = .empty;
    var at: usize = 0;
    var buf: [600]u8 = undefined;
    while (true) {
        const take = @min(in.len - at, cuts.size(1, 40));
        const room = cuts.size(1, buf.len);
        const step = d.decode(in[at..][0..take], buf[0..room]) catch |err| switch (err) {
            error.InvalidStream => {
                // The failing call's bytes before the refused code are in
                // `buf`: the diagnostic counts every byte given.
                const given: usize = @intCast(diag.output.raw());
                try out.appendSlice(gpa, buf[0 .. given - out.items.len]);
                return .{ .out = try out.toOwnedSlice(gpa), .in_len = @intCast(diag.offset.raw() + 1), .verdict = .bad_code };
            },
            else => return err,
        };
        try out.appendSlice(gpa, buf[0..step.out_len]);
        at += step.in_len;
        switch (step.status) {
            .end => return .{ .out = try out.toOwnedSlice(gpa), .in_len = at, .verdict = .ok },
            .output_full => {},
            .need_input => if (at == in.len and take == 0) {
                d.finish() catch |err| switch (err) {
                    error.Truncated => return .{ .out = try out.toOwnedSlice(gpa), .in_len = @intCast(diag.offset.raw()), .verdict = .truncated },
                    else => return err,
                };
                return error.TestUnexpectedResult;
            },
        }
    }
}

fn expectSame(want: Plain, got: Plain, check_in_len: bool) !void {
    try testing.expectEqual(want.verdict, got.verdict);
    try testing.expectEqualSlices(u8, want.out, got.out);
    if (check_in_len) try testing.expectEqual(want.in_len, got.in_len);
}

test "Wuffs's verdicts: every captured stream is read as Wuffs reads it, whole and in pieces" {
    const c = try corpus.Corpus.parse(streams);
    try testing.expectEqual(@as(usize, 7), c.fields);
    var prng: std.Random.DefaultPrng = .init(0x77ff);
    var it = c.records();
    var n: usize = 0;
    while (it.next()) |rec| : (n += 1) {
        var arena: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena.deinit();
        const gpa = arena.allocator();
        const f = rec.fields;
        const lw = try std.fmt.parseInt(u4, f[1], 10);
        const want_verdict: Verdict = if (std.mem.eql(u8, f[3], "ok")) .ok else if (std.mem.eql(u8, f[3], "bad code")) .bad_code else if (std.mem.eql(u8, f[3], "truncated input")) .truncated else return error.BadCorpus;
        const in_len = try std.fmt.parseInt(usize, f[4], 10);
        const out_len = try std.fmt.parseInt(usize, f[5], 10);
        for ([_]bool{ false, true }) |pieces| {
            const got = if (pieces)
                try warpPieces(gpa, lw, f[2], RandomCuts{ .r = prng.random() })
            else
                try warpWhole(gpa, lw, f[2], out_len);
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(got.out, &hash, .{});
            var want_hash: [32]u8 = undefined;
            _ = try std.fmt.hexToBytes(&want_hash, f[6]);
            if (got.verdict != want_verdict or got.in_len != in_len or got.out.len != out_len or !std.mem.eql(u8, &want_hash, &hash)) {
                std.debug.print("record {d} ({s}, width {d}, {s}): Wuffs {s} read {d} wrote {d}; warp {t} read {d} wrote {d}\n", .{ rec.index, f[0], lw, if (pieces) "in pieces" else "whole", f[3], in_len, out_len, got.verdict, got.in_len, got.out.len });
                return error.TestUnexpectedResult;
            }
        }
    }
    try testing.expect(n > 5000);
}

test "every literal width round-trips, with clears early, late and never" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    var prng: std.Random.DefaultPrng = .init(0x1a2b);
    for (0..9) |lw_| {
        const lw: u4 = @intCast(lw_);
        for ([_]usize{ 0, 1, 2, 7, 300, 9000, 70_000 }) |len| {
            const data = try gpa.alloc(u8, len);
            for (data, 0..) |*b, i| b.* = if (i % 3 == 0) @truncate(i / 7) else prng.random().int(u8);
            for (data) |*b| b.* &= @truncate((@as(u16, 1) << lw) - 1);
            for ([_]EncodeOptions{
                .{ .literal_width = lw },
                .{ .literal_width = lw, .clear_first = false },
                .{ .literal_width = lw, .keep_full = true },
                .{ .literal_width = lw, .clear_every = 5 },
            }) |o| {
                const stream = encode(gpa, data, o) catch |err| switch (err) {
                    error.Unencodable => {
                        try testing.expect(lw == 0);
                        continue;
                    },
                    else => return err,
                };
                const out = try gpa.alloc(u8, len + 1);
                const r = try lzw.decompress(stream, out, .{ .literal_width = lw });
                try testing.expectEqualSlices(u8, data, out[0..r.out_len]);
                try testing.expectEqual(stream.len, r.in_len);
                try expectSame(try plainDecode(gpa, lw, stream), .{ .out = out[0..r.out_len], .in_len = r.in_len, .verdict = .ok }, true);
            }
        }
    }
}

test "the code the table adds next repeats its prefix's first byte" {
    // Literal width 2: clear 4, end 5. Zeros encode as 0, then 6 ("00",
    // read as the table's next code before it holds it), then longer runs.
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const data: [10]u8 = @splat(0);
    const stream = try encode(gpa, &data, .{ .literal_width = 2 });
    var out: [16]u8 = undefined;
    const r = try lzw.decompress(stream, &out, .{ .literal_width = 2 });
    try testing.expectEqualSlices(u8, &data, out[0..r.out_len]);
}

test "a code past the next one is refused, after every byte before it" {
    // Literal width 2, 3-bit codes: clear, 0 (the first code adds no entry
    // and the next is 6), then 7, past 6. Its last bit is in byte 1.
    const codes = [_]u16{ 4, 0, 7 };
    var b: Bits = .{};
    for (codes) |c| try b.put(testing.allocator, c, 3);
    const stream = try b.finish(testing.allocator);
    defer testing.allocator.free(stream);
    var out: [8]u8 = undefined;
    var diag: lzw.Diagnostic = .{};
    try testing.expectError(error.InvalidStream, lzw.decompress(stream, &out, .{ .literal_width = 2, .diagnostic = &diag }));
    try testing.expectEqual(lzw.Diagnostic.Reason.bad_code, diag.reason);
    try testing.expectEqual(@as(u64, 1), diag.output.raw());
    try testing.expectEqual(@as(u64, 1), diag.offset.raw());
}

test "an input that ends before the end code is truncated, its bytes handed out" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const data = "the input ends before the end code";
    const stream = try encode(gpa, data, .{ .end = false });
    var out: [64]u8 = undefined;
    var diag: lzw.Diagnostic = .{};
    try testing.expectError(error.Truncated, lzw.decompress(stream, &out, .{ .diagnostic = &diag }));
    try testing.expectEqual(lzw.Diagnostic.Reason.truncated, diag.reason);
    // The last byte holds no whole code past the last one read.
    try testing.expect(diag.offset.raw() == stream.len or diag.offset.raw() + 1 == stream.len);
    try testing.expectEqualStrings(data, out[0..@intCast(diag.output.raw())]);
}

test "bytes after the end code are not read" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const gpa = arena.allocator();
    const stream = try encode(gpa, "after the end", .{});
    const more = try std.mem.concat(gpa, u8, &.{ stream, "\xff\x00 trailing" });
    var out: [32]u8 = undefined;
    const r = try lzw.decompress(more, &out, .{});
    try testing.expectEqual(stream.len, r.in_len);
    try testing.expectEqualStrings("after the end", out[0..r.out_len]);
}

test "a stream longer than the output is OutputTooSmall" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const stream = try encode(arena.allocator(), "twelve bytes", .{});
    var out: [11]u8 = undefined;
    try testing.expectError(error.OutputTooSmall, lzw.decompress(stream, &out, .{}));
    var exact: [12]u8 = undefined;
    _ = try lzw.decompress(stream, &exact, .{});
}

test "a literal width past 8 is refused" {
    for (9..16) |lw| try testing.expectError(error.InvalidOptions, lzw.Decompress.init(.{ .literal_width = @intCast(lw) }));
}

test "a decoder reset reads a second stream as the first" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const stream = try encode(arena.allocator(), "once and again, once and again", .{ .literal_width = 7 });
    var d: lzw.Decompress = try .init(.{ .literal_width = 7 });
    var out: [64]u8 = undefined;
    for (0..2) |_| {
        const step = try d.decode(stream, &out);
        try testing.expectEqual(lzw.Decompress.Status.end, step.status);
        try testing.expectEqualStrings("once and again, once and again", out[0..step.out_len]);
        try testing.expect(d.ended());
        d.reset();
    }
}

/// Any bytes, any literal width, and encoded streams cut, flipped and
/// followed by more: warp answers as the plain decoder, whole and in
/// pieces of any size.
fn agrees(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const lw = shakedown.gen.intRange(s, u4, 0, 8);
    var input: []u8 = undefined;
    if (shakedown.gen.boolean(s)) {
        input = try shakedown.gen.string(s, case.gpa, .{ .kind = .bytes, .max_len = 300, .average = 30 });
    } else {
        const data = try shakedown.gen.string(s, case.gpa, .{ .kind = .bytes, .max_len = 6000, .average = 400 });
        if (shakedown.gen.boolean(s)) {
            for (data, 0..) |*b, i| b.* = @truncate(i / shakedown.gen.intRange(s, usize, 1, 9));
        }
        input = encode(case.gpa, data, .{
            .literal_width = lw,
            .clear_first = shakedown.gen.boolean(s),
            .clear_every = if (shakedown.gen.boolean(s)) shakedown.gen.intRange(s, usize, 1, 5000) else null,
            .keep_full = shakedown.gen.boolean(s),
            .end = shakedown.gen.intRange(s, u8, 0, 9) != 0,
        }) catch |err| switch (err) {
            error.Unencodable => data,
            else => return err,
        };
        for (0..shakedown.gen.intRange(s, usize, 0, 3)) |_| {
            if (input.len > 0) input[shakedown.gen.intRange(s, usize, 0, input.len - 1)] ^= @as(u8, 1) << shakedown.gen.intRange(s, u3, 0, 7);
        }
        if (shakedown.gen.intRange(s, u8, 0, 3) == 0) input = input[0..shakedown.gen.intRange(s, usize, 0, input.len)];
        if (shakedown.gen.boolean(s)) input = try std.mem.concat(case.gpa, u8, &.{ input, "\x00\xff\x5a" });
    }
    const want = try plainDecode(case.gpa, lw, input);
    // The plain decoder's output is the room: a decoder that gives more
    // fails as OutputTooSmall.
    try expectSame(want, try warpWhole(case.gpa, lw, input, want.out.len), true);
    try expectSame(want, try warpPieces(case.gpa, lw, input, SourceCuts{ .s = s }), true);
}

test "fuzz: any bytes and encoded streams, cut, flipped and followed by more, answer as the plain decoder, whole and in pieces" {
    try shakedown.check(testing.allocator, {}, agrees, .{ .cases = 3000, .seed = 0x1e3f });
}
