//! The Brotli decoder against the format's reference library (google/brotli
//! 1.2.1): every stream it wrote decodes to its input, whole and in pieces
//! of any size; every stream it judged gets its judgment, for the same
//! reason; every prefix of a stream is `Truncated`.

const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const corpus = @import("corpus.zig");
const zstd_test = @import("zstd_decode_test.zig");
const Decompressor = @import("../brotli/Decompressor.zig");
const Decompress = @import("../brotli/Decompress.zig");
const Diagnostic = @import("../brotli/Diagnostic.zig");

pub const streams = @embedFile("brotli-streams.corpus");
pub const invalid = @embedFile("brotli-invalid.corpus");

const input = zstd_test.input;

fn has(params: []const u8, comptime key: []const u8) bool {
    return std.mem.find(u8, params, key ++ "=true") != null;
}

/// The prefix dictionary a record names ("" for none).
fn dictionary(gpa: std.mem.Allocator, spec: []const u8) ![]u8 {
    if (spec.len == 0) return gpa.alloc(u8, 0);
    return input(gpa, spec);
}

fn newDecompressor(gpa: std.mem.Allocator) !*Decompressor {
    const d = try gpa.create(Decompressor);
    d.* = .init;
    return d;
}

test "every stream the reference wrote decodes to its input, with an exact output and with room past it" {
    const gpa = testing.allocator;
    const d = try newDecompressor(gpa);
    defer gpa.destroy(d);
    const c = try corpus.Corpus.parse(streams);
    var it = c.records();
    var count: usize = 0;
    while (it.next()) |r| {
        const params = r.fields[1];
        const in = try input(gpa, r.fields[2]);
        defer gpa.free(in);
        const dict = try dictionary(gpa, r.fields[3]);
        defer gpa.free(dict);
        const z = r.fields[4];
        const out = try gpa.alloc(u8, in.len + 64);
        defer gpa.free(out);
        for ([_]usize{ in.len, in.len + 64 }) |out_len| {
            var diag: Diagnostic = .{};
            const result = d.decompress(z, out[0..out_len], .{ .dictionary = dict, .large_window = has(params, "large_window"), .streams = .one, .diagnostic = &diag }) catch |err| {
                std.debug.print("{s} | {s}: {t} ({t} at bit {d})\n", .{ params, r.fields[2], err, diag.reason, diag.bit_offset.raw() });
                return err;
            };
            try testing.expectEqual(in.len, result.out_len);
            try testing.expectEqualSlices(u8, in, out[0..in.len]);
            try testing.expectEqual(z.len, result.in_len);
        }
        count += 1;
    }
    try testing.expect(count >= 400);
}

/// The reasons a reference error may be given for.
fn reasons(code: []const u8) []const Diagnostic.Reason {
    const Map = struct { []const u8, []const Diagnostic.Reason };
    const table = [_]Map{
        .{ "_ERROR_FORMAT_EXUBERANT_NIBBLE", &.{.exuberant_nibble} },
        .{ "_ERROR_FORMAT_RESERVED", &.{.reserved} },
        .{ "_ERROR_FORMAT_EXUBERANT_META_NIBBLE", &.{.exuberant_metadata} },
        .{ "_ERROR_FORMAT_SIMPLE_HUFFMAN_ALPHABET", &.{.simple_code_symbol} },
        .{ "_ERROR_FORMAT_SIMPLE_HUFFMAN_SAME", &.{.simple_code_repeat} },
        .{ "_ERROR_FORMAT_CL_SPACE", &.{.code_length_space} },
        .{ "_ERROR_FORMAT_HUFFMAN_SPACE", &.{.code_space} },
        .{ "_ERROR_FORMAT_CONTEXT_MAP_REPEAT", &.{.context_map_repeat} },
        // The reference refuses an overrun at its next output or at the
        // meta-block's end, and a one-type block switch where its window
        // holds 2^24 literals: the same overrun.
        .{ "_ERROR_FORMAT_BLOCK_LENGTH_1", &.{ .block_length, .block_switch } },
        .{ "_ERROR_FORMAT_BLOCK_LENGTH_2", &.{ .block_length, .block_switch } },
        .{ "_ERROR_FORMAT_BLOCK_SWITCH", &.{ .block_length, .block_switch } },
        .{ "_ERROR_FORMAT_TRANSFORM", &.{.transform} },
        .{ "_ERROR_FORMAT_DICTIONARY", &.{.dictionary_word} },
        .{ "_ERROR_FORMAT_WINDOW_BITS", &.{.window_bits} },
        .{ "_ERROR_FORMAT_PADDING_1", &.{.padding} },
        .{ "_ERROR_FORMAT_PADDING_2", &.{.padding} },
        .{ "_ERROR_FORMAT_DISTANCE", &.{.distance} },
        .{ "_ERROR_COMPOUND_DICTIONARY", &.{.prefix_dictionary} },
    };
    for (table) |m| if (std.mem.eql(u8, m[0], code)) return m[1];
    std.debug.panic("unmapped reference error: {s}", .{code});
}

/// Whether warp's reading of a judged stream is the reference's verdict.
fn agrees(verdict: []const u8, got: Decompressor.Error!Decompressor.Result, out: []const u8, diag: Diagnostic) !bool {
    var parts = std.mem.splitScalar(u8, verdict, ' ');
    const kind = parts.next().?;
    if (std.mem.eql(u8, kind, "ok")) {
        const len = try std.fmt.parseInt(usize, parts.next().?, 10);
        const crc = try std.fmt.parseInt(u32, parts.next().?, 10);
        const used = try std.fmt.parseInt(usize, parts.next().?, 10);
        const result = got catch return false;
        return result.out_len == len and result.in_len == used and std.hash.Crc32.hash(out[0..result.out_len]) == crc;
    }
    const err = if (got) |_| return false else |e| e;
    if (std.mem.eql(u8, kind, "truncated")) return err == error.Truncated;
    if (err != error.InvalidStream) return false;
    for (reasons(parts.next().?)) |reason| if (reason == diag.reason) return true;
    return false;
}

test "every stream the reference judged gets its judgment, for the same reason, whole and in pieces" {
    const gpa = testing.allocator;
    const d = try newDecompressor(gpa);
    defer gpa.destroy(d);
    const z = try gpa.create(Decompress);
    defer gpa.destroy(z);
    const window = try gpa.alloc(u8, Decompress.windowLength(24));
    defer gpa.free(window);
    const c = try corpus.Corpus.parse(invalid);
    var it = c.records();
    var failures: usize = 0;
    var count: usize = 0;
    const out = try gpa.alloc(u8, 32 << 20);
    defer gpa.free(out);
    while (it.next()) |r| {
        const params = r.fields[0];
        const case = r.fields[1];
        const stream = r.fields[2];
        const verdict = r.fields[3];
        const dict = try dictionary(gpa, if (std.mem.find(u8, params, "dictionary=text")) |at| params[at + "dictionary=".len ..][0.."text 77 4096".len] else "");
        defer gpa.free(dict);
        const large = has(params, "large_window");
        var diag: Diagnostic = .{};
        const got = d.decompress(stream, out, .{ .dictionary = dict, .large_window = large, .streams = .one, .diagnostic = &diag });
        count += 1;
        if (!try agrees(verdict, got, out, diag)) {
            std.debug.print("{s}: reference says {s}, warp says {any} ({t} at bit {d})\n", .{ case, verdict, got, diag.reason, diag.bit_offset.raw() });
            failures += 1;
            continue;
        }
        // The resumable decoder, fed in three pieces, says the same.
        if (large) continue;
        z.* = .init(window, .{ .dictionary = dict, .streams = .one, .diagnostic = &diag });
        const streamed = streamWhole(z, stream, out, &.{ stream.len / 3, stream.len / 2 });
        if (!try agrees(verdict, streamed, out, diag)) {
            std.debug.print("{s}: reference says {s}, warp streaming says {any} ({t} at bit {d})\n", .{ case, verdict, streamed, diag.reason, diag.bit_offset.raw() });
            failures += 1;
        }
    }
    try testing.expectEqual(0, failures);
    try testing.expect(count >= 1000);
}

/// Decode `stream` with `z`, the input cut at `cuts` and the output given
/// whole: what the whole-buffer call would return.
fn streamWhole(z: *Decompress, stream: []const u8, out: []u8, cuts: []const usize) Decompressor.Error!Decompressor.Result {
    var ip: usize = 0;
    var op: usize = 0;
    var piece: usize = 0;
    while (true) {
        const end = if (piece < cuts.len) @max(ip, cuts[piece]) else stream.len;
        const step = z.decode(stream[ip..end], out[op..]) catch |err| return switch (err) {
            error.InvalidStream => error.InvalidStream,
            error.Truncated => error.Truncated,
            error.WindowTooLarge => error.InvalidStream,
        };
        ip += step.in_len;
        op += step.out_len;
        switch (step.status) {
            .done, .stream_end => return .{ .in_len = ip, .out_len = op },
            .output_full => return error.OutputTooSmall,
            .need_input => {
                if (ip < end) continue;
                if (end == stream.len) {
                    z.finish() catch return error.Truncated;
                    return .{ .in_len = ip, .out_len = op };
                }
                piece += 1;
            },
        }
    }
}

test "every prefix of a stream is Truncated" {
    const gpa = testing.allocator;
    const d = try newDecompressor(gpa);
    defer gpa.destroy(d);
    const c = try corpus.Corpus.parse(streams);
    var it = c.records();
    var checked: usize = 0;
    while (it.next()) |r| {
        const z = r.fields[4];
        if (z.len > 1500) continue;
        const params = r.fields[1];
        const in = try input(gpa, r.fields[2]);
        defer gpa.free(in);
        const dict = try dictionary(gpa, r.fields[3]);
        defer gpa.free(dict);
        const out = try gpa.alloc(u8, in.len + 64);
        defer gpa.free(out);
        for (0..z.len) |n| {
            var diag: Diagnostic = .{};
            if (d.decompress(z[0..n], out, .{ .dictionary = dict, .large_window = has(params, "large_window"), .streams = .one, .diagnostic = &diag })) |_| {
                std.debug.print("{s} {s}: the first {d} of {d} bytes decode\n", .{ params, r.fields[2], n, z.len });
                return error.TestUnexpectedResult;
            } else |err| try testing.expectEqual(error.Truncated, err);
        }
        checked += 1;
    }
    try testing.expect(checked >= 200);
}

test "a stream decodes the same cut anywhere, with output in pieces of any size" {
    const gpa = testing.allocator;
    const z = try gpa.create(Decompress);
    defer gpa.destroy(z);
    const window = try gpa.alloc(u8, Decompress.windowLength(24));
    defer gpa.free(window);
    const c = try corpus.Corpus.parse(streams);
    var it = c.records();
    var prng: std.Random.DefaultPrng = .init(0x6272);
    const rand = prng.random();
    while (it.next()) |r| {
        const params = r.fields[1];
        // A large window's ring is up to 1 GiB: whole-buffer tests take those.
        if (has(params, "large_window")) continue;
        const stream = r.fields[4];
        const in = try input(gpa, r.fields[2]);
        defer gpa.free(in);
        const dict = try dictionary(gpa, r.fields[3]);
        defer gpa.free(dict);
        const out = try gpa.alloc(u8, in.len);
        defer gpa.free(out);
        // Each cut of a short stream into two; random pieces otherwise.
        const cuts: usize = if (stream.len <= 300) stream.len + 1 else 3;
        for (0..cuts) |cut| {
            z.* = .init(window, .{ .dictionary = dict, .streams = .one });
            var ip: usize = 0;
            var op: usize = 0;
            var calls: usize = 0;
            while (true) : (calls += 1) {
                const in_n = if (stream.len <= 300) (if (calls == 0) cut else stream.len - ip) else rand.intRangeAtMost(usize, 0, @min(stream.len - ip, 5000));
                const out_n = rand.intRangeAtMost(usize, 0, @min(out.len - op, 9000));
                const step = try z.decode(stream[ip..][0..in_n], out[op..][0..out_n]);
                ip += step.in_len;
                op += step.out_len;
                if (step.status == .done) break;
                try testing.expect(calls < 1_000_000);
            }
            try testing.expectEqual(stream.len, ip);
            try testing.expectEqualSlices(u8, in, out[0..op]);
        }
    }
}

test "streams one after another: all decoded on their own, or the first and the rest left" {
    const gpa = testing.allocator;
    const d = try newDecompressor(gpa);
    defer gpa.destroy(d);
    const c = try corpus.Corpus.parse(streams);
    var it = c.records();
    var joined: std.ArrayList(u8) = .empty;
    defer joined.deinit(gpa);
    var expect: std.ArrayList(u8) = .empty;
    defer expect.deinit(gpa);
    var n: usize = 0;
    while (it.next()) |r| {
        if (r.fields[3].len != 0 or has(r.fields[1], "large_window") or r.fields[4].len > 4000) continue;
        const in = try input(gpa, r.fields[2]);
        defer gpa.free(in);
        try joined.appendSlice(gpa, r.fields[4]);
        try expect.appendSlice(gpa, in);
        n += 1;
        if (n == 40) break;
    }
    const out = try gpa.alloc(u8, expect.items.len);
    defer gpa.free(out);
    const all = try d.decompress(joined.items, out, .{});
    try testing.expectEqual(joined.items.len, all.in_len);
    try testing.expectEqualSlices(u8, expect.items, out[0..all.out_len]);
    const one = try d.decompress(joined.items, out, .{ .streams = .one });
    try testing.expect(one.in_len < joined.items.len);

    // The resumable decoder reports each stream's end.
    const z = try gpa.create(Decompress);
    defer gpa.destroy(z);
    const window = try gpa.alloc(u8, Decompress.windowLength(24));
    defer gpa.free(window);
    z.* = .init(window, .{});
    var ip: usize = 0;
    var op: usize = 0;
    var ends: usize = 0;
    while (ip < joined.items.len) {
        const step = try z.decode(joined.items[ip..@min(ip + 777, joined.items.len)], out[op..]);
        ip += step.in_len;
        op += step.out_len;
        if (step.status == .stream_end) ends += 1;
    }
    while ((try z.decode(&.{}, out[op..])).status == .stream_end) ends += 1;
    try z.finish();
    try testing.expectEqual(n, ends);
    try testing.expectEqualSlices(u8, expect.items, out[0..op]);
}

test "the reader decodes a stream through std.Io.Reader" {
    const gpa = testing.allocator;
    const c = try corpus.Corpus.parse(streams);
    var it = c.records();
    const buffer = try gpa.alloc(u8, 4096 + Decompress.windowLength(24));
    defer gpa.free(buffer);
    var checked: usize = 0;
    while (it.next()) |r| {
        if (r.fields[3].len != 0 or has(r.fields[1], "large_window")) continue;
        const in = try input(gpa, r.fields[2]);
        defer gpa.free(in);
        var source: std.Io.Reader = .fixed(r.fields[4]);
        const reader = try gpa.create(Decompress.Reader);
        defer gpa.destroy(reader);
        reader.* = .init(&source, buffer, .{ .streams = .one });
        const got = try reader.interface.allocRemaining(gpa, .unlimited);
        defer gpa.free(got);
        try testing.expectEqualSlices(u8, in, got);
        checked += 1;
        if (checked == 60) break;
    }
}

test "a window smaller than the stream's is refused" {
    const gpa = testing.allocator;
    const z = try gpa.create(Decompress);
    defer gpa.destroy(z);
    var window: [1 << 16]u8 = undefined;
    z.* = .init(&window, .{});
    // WBITS 22 and an empty last meta-block.
    var out: [8]u8 = undefined;
    try testing.expectError(error.WindowTooLarge, z.decode(&.{ 0x0b, 0x03 }, &out));
}

test "a one-type block switch is refused: 2^24 literals past a large-window meta-block (CVE-2026-111497's class)" {
    const gpa = testing.allocator;
    const d = try newDecompressor(gpa);
    defer gpa.destroy(d);
    // WBITS 30 (large window), one meta-block of 2^24 bytes: one literal
    // symbol of no bits, one command (504: insert code 23, copy 2) with
    // an insert of 22,594 + (2^24 - 1).
    var w: BitWriter = .{};
    w.put(0b0010001, 7);
    w.put(0, 1);
    w.put(30, 6);
    w.put(1, 1); // last
    w.put(0, 1); // not empty
    w.put(2, 2); // 6 nibbles
    w.put((1 << 24) - 1, 24);
    w.put(0, 3); // one block type each
    w.put(0, 6); // NPOSTFIX, NDIRECT
    w.put(0, 2); // literal mode
    w.put(0, 2); // one literal tree, one distance tree
    for ([_][3]u64{ .{ 'a', 8, 0 }, .{ 504, 10, 0 }, .{ 0, 10, 0 } }) |code| {
        w.put(1, 2); // simple
        w.put(0, 2); // one symbol
        w.put(code[0], @intCast(code[1]));
    }
    w.put((1 << 24) - 1, 24); // insert extra
    const out = try gpa.alloc(u8, (1 << 24) + 64);
    defer gpa.free(out);
    var diag: Diagnostic = .{};
    try testing.expectError(error.InvalidStream, d.decompress(w.bytes(), out, .{ .large_window = true, .diagnostic = &diag }));
    try testing.expectEqual(.block_switch, diag.reason);
}

const BitWriter = struct {
    buf: [64]u8 = @splat(0),
    n: usize = 0,

    fn put(w: *BitWriter, value: u64, count: u6) void {
        for (0..count) |i| {
            if ((value >> @intCast(i)) & 1 != 0) w.buf[w.n / 8] |= @as(u8, 1) << @intCast(w.n % 8);
            w.n += 1;
        }
    }

    fn bytes(w: *const BitWriter) []const u8 {
        return w.buf[0 .. (w.n + 7) / 8];
    }
};

test "the decoder holds its worst case and no stream" {
    try testing.expect(@sizeOf(Decompressor) <= 1400 << 10);
}

/// Arbitrary bytes, a dictionary and the large window or not: refused
/// cleanly or decoded, the same whole and in pieces.
fn decodeAnything(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const bytes = try shakedown.gen.string(s, case.gpa, .{ .kind = .bytes, .max_len = 600, .average = 64 });
    const large = shakedown.gen.boolean(s);
    const dict: []const u8 = if (shakedown.gen.boolean(s)) "a dictionary of a few bytes" else "";
    const d = try newDecompressor(case.gpa);
    const out = try case.gpa.alloc(u8, 1 << 16);
    var diag: Diagnostic = .{};
    const whole = d.decompress(bytes, out, .{ .dictionary = dict, .large_window = large, .streams = .one, .diagnostic = &diag });
    const z = try case.gpa.create(Decompress);
    const window = try case.gpa.alloc(u8, Decompress.windowLength(24));
    z.* = .init(window, .{ .dictionary = dict, .large_window = large, .streams = .one });
    const cut = shakedown.gen.intRange(s, usize, 0, bytes.len);
    const out2 = try case.gpa.alloc(u8, out.len);
    const pieces = streamWhole(z, bytes, out2, &.{cut});
    case.note("{d} bytes, large {}, dictionary {}, cut {d}: {any} / {any}", .{ bytes.len, large, dict.len != 0, cut, whole, pieces });
    // A large window past the test's 16 MiB is the window's refusal alone.
    if (pieces == error.InvalidStream and large and whole != error.InvalidStream) return;
    if (whole) |a| {
        const b = try pieces;
        try testing.expectEqual(a.out_len, b.out_len);
        try testing.expectEqualSlices(u8, out[0..a.out_len], out2[0..b.out_len]);
    } else |err| switch (err) {
        error.OutputTooSmall => {},
        else => try testing.expectError(err, pieces),
    }
}

test "fuzz: any bytes into the decoders are refused cleanly or decoded, the same whole and in pieces" {
    try shakedown.check(testing.allocator, {}, decodeAnything, .{ .cases = 1500 });
}

/// A valid stream with a byte changed: the same answer whole and in pieces.
fn decodeMutated(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const c = try corpus.Corpus.parse(streams);
    const pick = shakedown.gen.intRange(s, usize, 0, 499);
    var it = c.records();
    var r = it.next().?;
    for (0..pick) |_| r = it.next() orelse break;
    if (r.fields[3].len != 0 or has(r.fields[1], "large_window") or r.fields[4].len < 2) return;
    const bytes = try case.gpa.dupe(u8, r.fields[4]);
    const at = shakedown.gen.intRange(s, usize, 0, bytes.len - 1);
    bytes[at] ^= @as(u8, 1) << shakedown.gen.int(s, u3);
    const d = try newDecompressor(case.gpa);
    const out = try case.gpa.alloc(u8, 1 << 20);
    const whole = d.decompress(bytes, out, .{ .streams = .one });
    const z = try case.gpa.create(Decompress);
    const window = try case.gpa.alloc(u8, Decompress.windowLength(24));
    z.* = .init(window, .{ .streams = .one });
    const out2 = try case.gpa.alloc(u8, out.len);
    const pieces = streamWhole(z, bytes, out2, &.{ at, at + 1 });
    case.note("record {d}, bit flipped at byte {d}: {any} / {any}", .{ pick, at, whole, pieces });
    if (whole) |a| {
        const b = try pieces;
        try testing.expectEqualSlices(u8, out[0..a.out_len], out2[0..b.out_len]);
    } else |err| switch (err) {
        error.OutputTooSmall => {},
        else => try testing.expectError(err, pieces),
    }
}

test "fuzz: a valid stream with a bit flipped is read the same whole and in pieces" {
    try shakedown.check(testing.allocator, {}, decodeMutated, .{ .cases = 400 });
}
