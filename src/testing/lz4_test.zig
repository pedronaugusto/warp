//! LZ4 against lz4 1.10.0 (testdata/lz4-*.corpus, captured in trials
//! warp/lz4): every block it wrote is the block warp writes at that level,
//! every frame it wrote decodes through every decoder entry, and every
//! mutated block and frame gets its verdict, but where the format lets the
//! two differ. Fuzzing checks the decoders against a plain one written here.

const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const gen = @import("gen");
const corpus = @import("corpus.zig");
const lz4 = @import("../lz4.zig");

const blocks = @embedFile("lz4-blocks.corpus");
const frames = @embedFile("lz4-frames.corpus");
const invalid = @embedFile("lz4-invalid.corpus");

fn param(params: []const u8, name: []const u8) ?i64 {
    var it = std.mem.tokenizeScalar(u8, params, ' ');
    while (it.next()) |kv| {
        const eq = std.mem.findScalar(u8, kv, '=') orelse continue;
        if (std.mem.eql(u8, kv[0..eq], name)) return std.fmt.parseInt(i64, kv[eq + 1 ..], 10) catch null;
    }
    return null;
}

test "lz4's blocks are warp's, at every level and destSize budget, and decode to their input" {
    const gpa = testing.allocator;
    var c: lz4.Compressor = try .init(gpa, .{ .level = 1, .max_level = 12 });
    defer c.deinit();
    const parsed = try corpus.Corpus.parse(blocks);
    var it = parsed.records();
    var count: usize = 0;
    while (it.next()) |r| : (count += 1) {
        errdefer std.debug.print("{s} {s}: {s}\n", .{ r.fields[0], r.fields[1], r.fields[2] });
        const in = try corpus.input(gpa, r.fields[2]);
        defer gpa.free(in);
        const block = r.fields[3];
        const consumed = try std.fmt.parseInt(usize, r.fields[4], 10);
        c.setLevel(@intCast(param(r.fields[1], "level").?));
        const out = try gpa.alloc(u8, lz4.blockBound(in.len));
        defer gpa.free(out);
        if (param(r.fields[1], "dest")) |budget| {
            const f = c.compressBlockDestSize(in, out[0..@intCast(budget)], .{});
            try testing.expectEqual(consumed, f.in_len);
            try testing.expectEqualSlices(u8, block, out[0..f.out_len]);
        } else {
            const n = try c.compressBlock(in, out, .{});
            try testing.expectEqualSlices(u8, block, out[0..n]);
            // A block one byte short of it is refused.
            if (n > 0) try testing.expectError(error.OutputTooSmall, c.compressBlock(in, out[0 .. n - 1], .{}));
        }
        const back = try gpa.alloc(u8, consumed + lz4.decompress_margin);
        defer gpa.free(back);
        for ([_]usize{ consumed, back.len }) |room| {
            const d = try lz4.decompressBlock(block, back[0..room], .{});
            try testing.expect(d.finished);
            try testing.expectEqualSlices(u8, in[0..consumed], back[0..d.out_len]);
        }
    }
    try testing.expect(count > 800);
}

/// Decode `stream` through `Decompress`, `in_step` bytes of input and
/// `out_step` of output a call.
fn streamed(gpa: std.mem.Allocator, stream: []const u8, options: lz4.Decompress.Options, in_step: usize, out_step: usize) ![]u8 {
    const window = try gpa.alloc(u8, lz4.Decompress.memory(options.max_block_size));
    defer gpa.free(window);
    var d: lz4.Decompress = try .init(window, options);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const chunk = try gpa.alloc(u8, out_step);
    defer gpa.free(chunk);
    var at: usize = 0;
    while (true) {
        const step = try d.decode(stream[at..@min(stream.len, at + in_step)], chunk);
        at += step.in_len;
        try out.appendSlice(gpa, chunk[0..step.out_len]);
        if (step.status == .done) break;
        if (at == stream.len and step.status != .output_full) {
            try d.finish();
            break;
        }
    }
    return out.toOwnedSlice(gpa);
}

test "lz4's frames decode whole, streamed at any cut and through a reader, with their dictionary" {
    const gpa = testing.allocator;
    const parsed = try corpus.Corpus.parse(frames);
    var it = parsed.records();
    var count: usize = 0;
    while (it.next()) |r| : (count += 1) {
        errdefer std.debug.print("{s} {s}: {s}\n", .{ r.fields[0], r.fields[1], r.fields[2] });
        const in = try corpus.input(gpa, r.fields[2]);
        defer gpa.free(in);
        const dictionary = if (r.fields[3].len > 0) try corpus.input(gpa, r.fields[3]) else try gpa.alloc(u8, 0);
        defer gpa.free(dictionary);
        const frame = r.fields[4];
        const legacy = std.mem.startsWith(u8, r.fields[1], "-l");
        const max: @FieldType(lz4.Options, "max_block_size") = if (legacy) .literal("8MiB") else .literal("4MiB");
        const out = try gpa.alloc(u8, in.len + lz4.decompress_margin);
        defer gpa.free(out);
        const whole = try lz4.decompress(frame, out, .{ .dictionary = dictionary, .max_block_size = max });
        try testing.expect(whole.finished);
        try testing.expectEqual(frame.len, whole.in_len);
        try testing.expectEqualSlices(u8, in, out[0..whole.out_len]);
        // Exactly the content's room works too.
        const exact = try lz4.decompress(frame, out[0..in.len], .{ .dictionary = dictionary, .max_block_size = max });
        try testing.expectEqual(in.len, exact.out_len);
        for ([_][2]usize{ .{ 1, 4096 }, .{ 4096, 1 }, .{ 7, 300 }, .{ frame.len, 1 << 16 } }) |cut| {
            if ((cut[0] == 1 or cut[1] == 1) and in.len > 100_000) continue; // a byte at a time: the small ones say it
            const back = try streamed(gpa, frame, .{ .dictionary = dictionary, .max_block_size = max }, cut[0], cut[1]);
            defer gpa.free(back);
            try testing.expectEqualSlices(u8, in, back);
        }
        var input_buffer: [64]u8 = undefined;
        var input: std.testing.Reader = .init(&input_buffer, &.{.{ .buffer = frame }});
        const buffer = try gpa.alloc(u8, 4096 + lz4.Decompress.memory(max));
        defer gpa.free(buffer);
        var reader: lz4.Decompress.Reader = try .init(&input.interface, buffer, .{ .dictionary = dictionary, .max_block_size = max });
        const read = try reader.interface.allocRemaining(gpa, .unlimited);
        defer gpa.free(read);
        try testing.expectEqualSlices(u8, in, read);
    }
    try testing.expect(count > 140);
}

/// Whether a block breaks the encoder's end-of-block rules (its last five
/// bytes literals, its last match twelve before its end), which the format
/// lets a decoder refuse, and lz4's does relative to its output buffer.
fn endRulesBroken(block: []const u8) bool {
    var ip: usize = 0;
    var op: usize = 0;
    var last_match_start: ?usize = null;
    var last_lits: usize = 0;
    while (ip < block.len) {
        const token = block[ip];
        ip += 1;
        var lit: usize = token >> 4;
        if (lit == 15) while (ip < block.len) {
            lit += block[ip];
            ip += 1;
            if (block[ip - 1] != 255) break;
        };
        ip += lit;
        op += lit;
        last_lits = lit;
        if (ip >= block.len) break;
        ip += 2;
        var len: usize = token & 15;
        if (len == 15) while (ip < block.len) {
            len += block[ip];
            ip += 1;
            if (block[ip - 1] != 255) break;
        };
        last_match_start = op;
        op += len + 4;
        last_lits = 0;
    }
    if (last_match_start) |start| return last_lits < 5 or op - start < 12 or op < 13;
    return false;
}

/// The same for every compressed block of a frame.
fn frameEndRulesBroken(stream: []const u8) bool {
    var at: usize = 0;
    while (at < stream.len) {
        const f = lz4.frameHeader(stream[at..]) catch return false;
        switch (f) {
            .skippable => |s| at += 8 + s.len,
            .legacy => return false,
            .standard => |s| {
                at += s.header_len;
                while (at + 4 <= stream.len) {
                    const v = std.mem.readInt(u32, stream[at..][0..4], .little);
                    at += 4;
                    if (v == 0) break;
                    const len = v & 0x7fff_ffff;
                    if (at + len > stream.len) return false;
                    if (v & 0x8000_0000 == 0 and endRulesBroken(stream[at..][0..len])) return true;
                    at += len + @as(usize, if (s.header.block_checksum) 4 else 0);
                }
                if (s.header.content_checksum) at += 4;
            },
        }
    }
    return false;
}

test "mutated blocks and frames get lz4's verdict, where the format lets the two differ said why" {
    const gpa = testing.allocator;
    const parsed = try corpus.Corpus.parse(invalid);
    var it = parsed.records();
    const out = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(out);
    var count: usize = 0;
    var differ: usize = 0;
    while (it.next()) |r| : (count += 1) {
        errdefer std.debug.print("{s}: {s}\n", .{ r.fields[0], r.fields[4] });
        const dictionary = if (r.fields[2].len > 0) try corpus.input(gpa, r.fields[2]) else try gpa.alloc(u8, 0);
        defer gpa.free(dictionary);
        const stream = r.fields[3];
        const verdict = r.fields[4];
        const is_block = std.mem.eql(u8, r.fields[1], "block");
        var diagnostic: lz4.Diagnostic = .{};
        const ours: anyerror!usize = if (is_block)
            (if (lz4.decompressBlock(stream, out, .{ .history = dictionary, .diagnostic = &diagnostic })) |d| d.out_len else |e| e)
        else
            (if (lz4.decompress(stream, out, .{ .dictionary = dictionary, .diagnostic = &diagnostic })) |d| d.out_len else |e| e);
        // The streaming decoder answers as the whole-buffer one.
        if (!is_block) {
            const back = streamed(gpa, stream, .{ .dictionary = dictionary }, 13, 777);
            if (ours) |n| {
                const b = try back;
                defer gpa.free(b);
                try testing.expectEqualSlices(u8, out[0..n], b);
            } else |e| try testing.expectError(e, back);
        }
        if (std.mem.startsWith(u8, verdict, "ok ")) {
            var fields = std.mem.tokenizeScalar(u8, verdict[3..], ' ');
            const len = try std.fmt.parseInt(usize, fields.next().?, 10);
            const crc = try std.fmt.parseInt(u32, fields.next().?, 10);
            const n = ours catch |err| {
                // lz4 fills an offset of zero with zeros; the format calls it
                // invalid, and warp refuses it.
                try testing.expectEqual(error.InvalidStream, err);
                try testing.expectEqual(lz4.Diagnostic.Reason.zero_offset, diagnostic.reason);
                differ += 1;
                continue;
            };
            try testing.expectEqual(len, n);
            try testing.expectEqual(crc, std.hash.Crc32.hash(out[0..n]));
        } else {
            if (ours) |_| {
                // Decoded where lz4 refused: only a block the encoder's end
                // rules forbid, which the format lets a decoder take.
                try testing.expect(if (is_block) endRulesBroken(stream) else frameEndRulesBroken(stream));
                differ += 1;
            } else |_| {}
        }
    }
    try testing.expect(count > 700);
    // The differences are the exception.
    try testing.expect(differ * 20 < count);
}

test "skippable frames, concatenation, one frame at a time and the dictionary's ID" {
    const gpa = testing.allocator;
    var c: lz4.Compressor = try .init(gpa, .{ .dictionary = "a dictionary of words the input repeats" });
    defer c.deinit();
    const in = "the input repeats words of a dictionary, a dictionary of words";
    var buf: [4096]u8 = undefined;
    var at = try lz4.writeSkippable(&buf, 3, "skip me");
    at += try c.compress(in, buf[at..], .{ .dictionary_id = 7 });
    const first_end = at;
    at += try lz4.writeSkippable(buf[at..], 0, "");
    at += try c.compress(in, buf[at..], .{ .independent = false, .block_checksum = true });
    var out: [256]u8 = undefined;
    const all = try lz4.decompress(buf[0..at], &out, .{ .dictionary = "a dictionary of words the input repeats" });
    try testing.expectEqualStrings(in ++ in, out[0..all.out_len]);
    const one = try lz4.decompress(buf[0..at], &out, .{ .frames = .one, .dictionary = "a dictionary of words the input repeats" });
    try testing.expectEqual(first_end, one.in_len);
    try testing.expectEqualStrings(in, out[0..one.out_len]);
    var diagnostic: lz4.Diagnostic = .{};
    try testing.expectError(error.DictionaryMismatch, lz4.decompress(buf[0..at], &out, .{ .diagnostic = &diagnostic }));
    try testing.expectEqual(lz4.Diagnostic.Reason.dictionary_mismatch, diagnostic.reason);
    try testing.expectError(error.DictionaryMismatch, lz4.decompress(buf[0..at], &out, .{ .dictionary = "x", .dictionary_id = 8 }));
    // Trailing bytes that start no frame.
    try testing.expectError(error.InvalidStream, lz4.decompress(buf[0 .. at + 3], &out, .{ .dictionary = "a dictionary of words the input repeats", .diagnostic = &diagnostic }));
    try testing.expectEqual(lz4.Diagnostic.Reason.trailing_data, diagnostic.reason);
    // Partial output stops at a full buffer with a prefix.
    const partial = try lz4.decompress(buf[0..at], out[0..10], .{ .partial = true, .dictionary = "a dictionary of words the input repeats" });
    try testing.expect(!partial.finished);
    try testing.expectEqualStrings(in[0..10], out[0..10]);
    try testing.expectError(error.OutputTooSmall, lz4.decompress(buf[0..at], out[0..10], .{ .dictionary = "a dictionary of words the input repeats" }));
    // Every cut of the input is truncated, but where a frame ends.
    for (0..at) |n| {
        const complete = n == 15 or n == first_end or n == first_end + 8;
        if (lz4.decompress(buf[0..n], &out, .{ .dictionary = "a dictionary of words the input repeats" })) |_| {
            try testing.expect(complete);
        } else |err| {
            try testing.expect(!complete);
            try testing.expectEqual(error.Truncated, err);
        }
    }
}

test "legacy frames round-trip, end at the input's end or at a frame, and need an 8 MiB window" {
    const gpa = testing.allocator;
    const in = try gen.alloc(gpa, .runs, 3, 9 << 20);
    defer gpa.free(in);
    var c: lz4.Compressor = try .init(gpa, .{ .level = 2 });
    defer c.deinit();
    const f: lz4.Compressor.Frame = .{ .format = .legacy };
    const frame = try gpa.alloc(u8, lz4.Compressor.bound(in.len, f) + 64);
    defer gpa.free(frame);
    var n = try c.compress(in, frame, f);
    n += try c.compress("tail", frame[n..], .{});
    const out = try gpa.alloc(u8, in.len + 4);
    defer gpa.free(out);
    const r = try lz4.decompress(frame[0..n], out, .{ .max_block_size = .literal("8MiB") });
    try testing.expectEqualSlices(u8, in, out[0..in.len]);
    try testing.expectEqualStrings("tail", out[in.len..r.out_len]);
    const back = try streamed(gpa, frame[0..n], .{ .max_block_size = .literal("8MiB") }, 100_000, 1 << 20);
    defer gpa.free(back);
    try testing.expectEqualSlices(u8, out[0..r.out_len], back);
    try testing.expectError(error.InvalidStream, streamed(gpa, frame[0..n], .{}, 100_000, 1 << 20));
}

/// Compress `in` through `Compress`, `step` bytes of input a call and
/// with a flush every `flush_every` calls (0: none).
fn compressStreamed(gpa: std.mem.Allocator, in: []const u8, options: lz4.Compress.Options, step: usize, flush_every: usize) ![]u8 {
    var s: lz4.Compress = try .init(gpa, options);
    defer s.deinit();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var chunk: [1000]u8 = undefined;
    var at: usize = 0;
    var calls: usize = 0;
    while (at < in.len) : (calls += 1) {
        const w = try s.write(in[at..@min(in.len, at + step)], &chunk);
        at += w.in_len;
        try out.appendSlice(gpa, chunk[0..w.out_len]);
        if (flush_every != 0 and calls % flush_every == 0) while (true) {
            const d = try s.flush(&chunk);
            try out.appendSlice(gpa, chunk[0..d.out_len]);
            if (d.done) break;
        };
    }
    while (true) {
        const d = try s.finish(&chunk);
        try out.appendSlice(gpa, chunk[0..d.out_len]);
        if (d.done) break;
    }
    return out.toOwnedSlice(gpa);
}

test "streamed compression writes the whole-buffer frame however the input arrives, and flushes decode" {
    const gpa = testing.allocator;
    const in = try gen.alloc(gpa, .text, 4, 300_000);
    defer gpa.free(in);
    for ([_]i32{ 1, 2, 9, 10 }) |level| for ([_]bool{ true, false }) |independent| {
        const frame: lz4.Compressor.Frame = .{ .block_size = .@"64KiB", .independent = independent, .block_checksum = true };
        var c: lz4.Compressor = try .init(gpa, .{ .level = level });
        defer c.deinit();
        const whole = try gpa.alloc(u8, lz4.Compressor.bound(in.len, frame));
        defer gpa.free(whole);
        const n = try c.compress(in, whole, frame);
        for ([_]usize{ 1, 777, 65536, in.len }) |step| {
            if (step == 1 and level > 2) continue;
            const s = try compressStreamed(gpa, in, .{ .compressor = .{ .level = level }, .frame = frame, .pledged_size = .fromRaw(in.len) }, step, 0);
            defer gpa.free(s);
            try testing.expectEqualSlices(u8, whole[0..n], s);
        }
        const flushed = try compressStreamed(gpa, in, .{ .compressor = .{ .level = level }, .frame = frame }, 5000, 3);
        defer gpa.free(flushed);
        const out = try gpa.alloc(u8, in.len);
        defer gpa.free(out);
        const r = try lz4.decompress(flushed, out, .{});
        try testing.expectEqualSlices(u8, in, out[0..r.out_len]);
    };
    // A pledge the content does not keep is refused.
    var s: lz4.Compress = try .init(gpa, .{ .pledged_size = .fromRaw(10) });
    defer s.deinit();
    var chunk: [64]u8 = undefined;
    _ = try s.write("short", &chunk);
    try testing.expectError(error.SizeMismatch, s.finish(&chunk));
}

test "a compressor in caller memory allocates nothing, and memory says what it needs" {
    for ([_]i32{ -5, 1, 2, 6, 12 }) |level| {
        const options: lz4.Compressor.Options = .{ .level = level, .dictionary = "a dictionary" };
        const buffer = try testing.allocator.alignedAlloc(u8, .@"64", lz4.Compressor.memory(options));
        defer testing.allocator.free(buffer);
        var c: lz4.Compressor = try .initBuffer(buffer, options);
        var out: [128]u8 = undefined;
        const n = try c.compressBlock("a dictionary, and a dictionary again", &out, .{ .history = .dictionary });
        var back: [64]u8 = undefined;
        const d = try lz4.decompressBlock(out[0..n], &back, .{ .history = "a dictionary" });
        try testing.expectEqualStrings("a dictionary, and a dictionary again", back[0..d.out_len]);
    }
}

// ---- Fuzzing ----

/// A plain decoder, one byte at a time: the oracle for the fast one.
fn reference(in: []const u8, out: []u8, history: []const u8) error{ Invalid, Truncated, Overflow }!usize {
    if (in.len == 0) return error.Truncated;
    var ip: usize = 0;
    var op: usize = 0;
    while (true) {
        if (ip >= in.len) return error.Truncated;
        const token = in[ip];
        ip += 1;
        var lit: usize = token >> 4;
        if (lit == 15) while (true) {
            if (ip >= in.len) return error.Truncated;
            lit += in[ip];
            ip += 1;
            if (in[ip - 1] != 255) break;
        };
        if (lit > in.len - ip) return error.Truncated;
        if (lit > out.len - op) return error.Overflow;
        @memcpy(out[op..][0..lit], in[ip..][0..lit]);
        ip += lit;
        op += lit;
        if (ip == in.len) return op;
        if (in.len - ip < 2) return error.Truncated;
        const offset = std.mem.readInt(u16, in[ip..][0..2], .little);
        ip += 2;
        var len: usize = token & 15;
        if (len == 15) while (true) {
            if (ip >= in.len) return error.Truncated;
            len += in[ip];
            ip += 1;
            if (in[ip - 1] != 255) break;
        };
        len += 4;
        if (offset == 0 or offset > op + history.len) return error.Invalid;
        if (len > out.len - op) return error.Overflow;
        for (0..len) |_| {
            out[op] = if (offset > op) history[history.len - (offset - op)] else out[op - offset];
            op += 1;
        }
    }
}

/// Arbitrary bytes, and real blocks cut and mutated, into the block
/// decoder with and without history and spare output, and partial: the
/// plain decoder's answer.
fn blockAgrees(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    var input: []u8 = undefined;
    if (shakedown.gen.boolean(s)) {
        input = try shakedown.gen.string(s, case.gpa, .{ .kind = .bytes, .max_len = 600, .average = 64 });
    } else {
        const plain = try gen.alloc(case.gpa, shakedown.gen.enumValue(s, gen.Kind), shakedown.gen.int(s, u16), shakedown.gen.intRange(s, usize, 0, 3000));
        var c: lz4.Compressor = try .init(case.gpa, .{ .level = shakedown.gen.intRange(s, i32, -3, 12) });
        const block = try case.gpa.alloc(u8, lz4.blockBound(plain.len));
        const n = try c.compressBlock(plain, block, .{});
        input = block[0..n];
        for (0..shakedown.gen.intRange(s, usize, 0, 3)) |_| {
            if (input.len == 0) break;
            input[shakedown.gen.intRange(s, usize, 0, input.len - 1)] ^= @as(u8, 1) << shakedown.gen.intRange(s, u3, 0, 7);
        }
        if (shakedown.gen.boolean(s)) input = input[0..shakedown.gen.intRange(s, usize, 0, input.len)];
    }
    const history = if (shakedown.gen.boolean(s)) try gen.alloc(case.gpa, .text, 9, shakedown.gen.intRange(s, usize, 0, 70000)) else &.{};
    const room = shakedown.gen.intRange(s, usize, 0, 8192);
    case.note("{d} bytes, {d} of history, {d} of output", .{ input.len, history.len, room });
    const want = try case.gpa.alloc(u8, room);
    const expected = reference(input, want, history[history.len -| 65535..]);
    for ([_]usize{ 0, 64 }) |spare| {
        const got = try case.gpa.alloc(u8, room + spare);
        const r = lz4.decompressBlock(input, got[0..room], .{ .history = history });
        if (expected) |n| {
            try testing.expectEqual(n, (try r).out_len);
            try testing.expectEqualSlices(u8, want[0..n], got[0..n]);
        } else |err| switch (err) {
            error.Invalid => try testing.expectError(error.InvalidStream, r),
            error.Truncated => try testing.expectError(error.Truncated, r),
            error.Overflow => try testing.expectError(error.OutputTooSmall, r),
        }
        // Spare output changes nothing.
        const wide = lz4.decompressBlock(input, got, .{ .history = history });
        if (expected) |n| try testing.expectEqual(n, (try wide).out_len) else |err| if (err != error.Overflow) try testing.expect(std.meta.isError(wide));
    }
    // Partial: a prefix of what a larger output gets.
    const p = try case.gpa.alloc(u8, room);
    if (lz4.decompressBlock(input, p, .{ .history = history, .partial = true })) |r| {
        const big = try case.gpa.alloc(u8, 1 << 20);
        if (reference(input, big, history[history.len -| 65535..])) |n| {
            try testing.expect(r.out_len <= n);
            try testing.expectEqualSlices(u8, big[0..r.out_len], p[0..r.out_len]);
            try testing.expectEqual(r.out_len == n, r.finished);
        } else |_| {}
    } else |_| {}
}

test "fuzz: any bytes into the block decoder, with any history and output, answer as the plain decoder" {
    try shakedown.check(testing.allocator, {}, blockAgrees, .{ .cases = 2000, .seed = 0x14b10c });
}

/// Arbitrary bytes, and real frames mutated: the streaming decoder at any
/// cut answers as the whole-buffer one.
fn framesAgree(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    var input: []u8 = undefined;
    if (shakedown.gen.boolean(s)) {
        input = try shakedown.gen.string(s, case.gpa, .{ .kind = .bytes, .max_len = 600, .average = 64 });
        if (input.len >= 4 and shakedown.gen.boolean(s)) std.mem.writeInt(u32, input[0..4], 0x184D2204, .little);
    } else {
        const plain = try gen.alloc(case.gpa, shakedown.gen.enumValue(s, gen.Kind), shakedown.gen.int(s, u16), shakedown.gen.intRange(s, usize, 0, 100_000));
        var c: lz4.Compressor = try .init(case.gpa, .{ .level = shakedown.gen.intRange(s, i32, -3, 12) });
        const f: lz4.Compressor.Frame = .{
            .block_size = shakedown.gen.enumValue(s, lz4.BlockSize),
            .independent = shakedown.gen.boolean(s),
            .block_checksum = shakedown.gen.boolean(s),
            .content_checksum = shakedown.gen.boolean(s),
            .content_size = shakedown.gen.boolean(s),
        };
        const frame = try case.gpa.alloc(u8, lz4.Compressor.bound(plain.len, f));
        input = frame[0..try c.compress(plain, frame, f)];
        for (0..shakedown.gen.intRange(s, usize, 0, 3)) |_| input[shakedown.gen.intRange(s, usize, 0, input.len - 1)] ^= @as(u8, 1) << shakedown.gen.intRange(s, u3, 0, 7);
        if (shakedown.gen.boolean(s)) input = input[0..shakedown.gen.intRange(s, usize, 0, input.len)];
    }
    const in_step = shakedown.gen.intRange(s, usize, 1, 5000);
    const out_step = shakedown.gen.intRange(s, usize, 1, 5000);
    case.note("{d} bytes, {d} in, {d} out a step", .{ input.len, in_step, out_step });
    const out = try case.gpa.alloc(u8, 1 << 20);
    const whole = lz4.decompress(input, out, .{});
    const back = streamed(case.gpa, input, .{}, in_step, out_step);
    if (whole) |r| {
        try testing.expectEqualSlices(u8, out[0..r.out_len], try back);
    } else |err| switch (err) {
        error.OutputTooSmall => {},
        else => try testing.expectError(err, back),
    }
}

test "fuzz: any bytes into the frame decoders, whole and streamed, get one answer" {
    try shakedown.check(testing.allocator, {}, framesAgree, .{ .cases = 500, .seed = 0x14f4a3 });
}

/// Any input at any level, history and frame comes back whole.
fn roundTrip(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const plain = if (shakedown.gen.boolean(s))
        try shakedown.gen.string(s, case.gpa, .{ .kind = .bytes, .max_len = 5000, .average = 300 })
    else
        try gen.alloc(case.gpa, shakedown.gen.enumValue(s, gen.Kind), shakedown.gen.int(s, u16), shakedown.gen.intRange(s, usize, 0, 200_000));
    const level = shakedown.gen.intRange(s, i32, -20, 13);
    const dictionary = try gen.alloc(case.gpa, .text, 5, shakedown.gen.intRange(s, usize, 0, 100_000));
    var c: lz4.Compressor = try .init(case.gpa, .{ .level = level, .dictionary = dictionary });
    case.note("{d} bytes, level {d}, {d} of dictionary", .{ plain.len, level, dictionary.len });
    // A block, with each history.
    const block = try case.gpa.alloc(u8, lz4.blockBound(plain.len));
    const back = try case.gpa.alloc(u8, plain.len);
    for ([_]lz4.Compressor.History{ .none, .dictionary, .{ .bytes = dictionary } }) |h| {
        const n = try c.compressBlock(plain, block, .{ .history = h });
        const history: []const u8 = if (h == .none) &.{} else dictionary;
        const d = try lz4.decompressBlock(block[0..n], back, .{ .history = history });
        try testing.expectEqualSlices(u8, plain, back[0..d.out_len]);
    }
    // Linked blocks in pieces, each history the last's input.
    var at: usize = 0;
    var produced: std.ArrayList(u8) = .empty;
    while (at < plain.len) {
        const piece = plain[at..@min(plain.len, at + shakedown.gen.intRange(s, usize, 1, 70000))];
        const n = try c.compressBlock(piece, block, .{ .history = if (at == 0) .none else .previous });
        const out = try case.gpa.alloc(u8, piece.len);
        const d = try lz4.decompressBlock(block[0..n], out, .{ .history = produced.items });
        try testing.expectEqualSlices(u8, piece, out[0..d.out_len]);
        try produced.appendSlice(case.gpa, piece);
        at += piece.len;
    }
    // A frame.
    const f: lz4.Compressor.Frame = .{
        .block_size = shakedown.gen.enumValue(s, lz4.BlockSize),
        .independent = shakedown.gen.boolean(s),
        .block_checksum = shakedown.gen.boolean(s),
        .dictionary_id = if (dictionary.len > 0 and shakedown.gen.boolean(s)) 9 else null,
    };
    const frame = try case.gpa.alloc(u8, lz4.Compressor.bound(plain.len, f));
    const n = try c.compress(plain, frame, f);
    const d = try lz4.decompress(frame[0..n], back, .{ .dictionary = dictionary });
    try testing.expectEqualSlices(u8, plain, back[0..d.out_len]);
    // destSize: a prefix that decodes.
    const budget = shakedown.gen.intRange(s, usize, 1, lz4.blockBound(plain.len));
    const filled = c.compressBlockDestSize(plain, block[0..budget], .{});
    try testing.expect(filled.out_len <= budget);
    const fd = try lz4.decompressBlock(block[0..filled.out_len], back, .{});
    try testing.expectEqualSlices(u8, plain[0..filled.in_len], back[0..fd.out_len]);
}

test "fuzz: any input at any level, history, frame and budget comes back whole" {
    try shakedown.check(testing.allocator, {}, roundTrip, .{ .cases = 200, .seed = 0x140a7d });
}

test "lz4 resumable decoder: a short buffer is refused, a maximum past a legacy block sized as one" {
    const gpa = testing.allocator;
    const window = try gpa.alloc(u8, lz4.Decompress.memory(.literal("64KiB")));
    defer gpa.free(window);
    try testing.expectError(error.BufferTooSmall, lz4.Decompress.init(window[0 .. window.len - 1], .{ .max_block_size = .literal("64KiB") }));
    _ = try lz4.Decompress.init(window, .{ .max_block_size = .literal("64KiB") });
    var source: std.Io.Reader = .fixed("");
    try testing.expectError(error.BufferTooSmall, lz4.Decompress.Reader.init(&source, window[0..4095], .{}));
    // No block is longer than a legacy one: a larger maximum needs no more.
    try testing.expectEqual(lz4.Decompress.memory(.literal("8MiB")), lz4.Decompress.memory(.fromRaw(std.math.maxInt(usize))));
}
