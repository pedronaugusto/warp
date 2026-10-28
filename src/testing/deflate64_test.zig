//! Extended alphabet fixtures, written field by field, and the streams
//! 7-Zip writes (testdata/deflate64.corpus): every one decodes to its
//! input whole and streamed, cut anywhere.
const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const deflate64 = @import("../deflate64.zig");
const Decompressor = @import("../Decompressor.zig");
const Inflate = @import("../stream/Inflate.zig");
const bits = @import("../bits.zig");
const corpus = @import("corpus.zig");

const captured = @embedFile("deflate64.corpus");

fn fixedSymbol(w: *bits.Writer, symbol: usize) void {
    const length: u6 = if (symbol < 144) 8 else if (symbol < 256) 9 else if (symbol < 280) 7 else 8;
    const code: u16 = @intCast(if (symbol < 144) symbol + 48 else if (symbol < 256) symbol + 256 else if (symbol < 280) symbol - 256 else symbol - 88);
    w.add(@bitReverse(code) >> @intCast(16 - length), length);
    w.flush();
}

test "Deflate64 length 285 has sixteen extra bits and spans a 64 KiB match" {
    var stream: [64]u8 = undefined;
    var w: bits.Writer = .init(&stream, 0);
    w.add(3, 3); // final fixed block
    fixedSymbol(&w, 'a');
    fixedSymbol(&w, 285);
    w.add(65535, 16); // 65,538 bytes, distance one
    w.add(0, 5);
    fixedSymbol(&w, 256);
    w.alignToByte();
    const out = try testing.allocator.alloc(u8, 65539);
    defer testing.allocator.free(out);
    var d: deflate64.Decompressor = .init;
    const r = try d.inflate(stream[0..w.at], out, .{});
    try testing.expectEqual(out.len, r.out_len);
    for (out) |byte| try testing.expectEqual(@as(u8, 'a'), byte);
    try testing.expectEqual(w.at, r.in_len);
    const partial = try d.inflate(stream[0..w.at], out[0..37], .{ .partial = true });
    try testing.expect(!partial.finished);
    for (0..w.at) |n| try testing.expectError(error.Truncated, d.inflate(stream[0..n], out, .{}));
}

test "Deflate64 distance symbols 30 and 31 reach beyond 32 KiB" {
    const gpa = testing.allocator;
    const dictionary = try gpa.alloc(u8, 65536);
    defer gpa.free(dictionary);
    for (dictionary, 0..) |*byte, i| byte.* = @truncate(i *% 17);
    for ([_]usize{ 30, 31 }) |symbol| {
        var stream: [64]u8 = undefined;
        var w: bits.Writer = .init(&stream, 0);
        w.add(3, 3);
        fixedSymbol(&w, 257); // length three
        w.add(@bitReverse(@as(u16, @intCast(symbol))) >> 11, 5);
        w.add(16383, 14);
        fixedSymbol(&w, 256);
        w.alignToByte();
        var out: [3]u8 = undefined;
        var d: deflate64.Decompressor = .init;
        _ = try d.inflate(stream[0..w.at], &out, .{ .dictionary = dictionary });
        const distance: usize = if (symbol == 30) 49152 else 65536;
        try testing.expectEqualSlices(u8, dictionary[65536 - distance ..][0..3], &out);
        var regular: Decompressor = .init;
        try testing.expectError(error.InvalidStream, regular.inflate(stream[0..w.at], &out, .{ .accept = .raw, .dictionary = dictionary }));
    }
}

test "Deflate64 dynamic tables include the extended distance and length symbols" {
    const dictionary = try testing.allocator.alloc(u8, 65536);
    defer testing.allocator.free(dictionary);
    for (dictionary, 0..) |*byte, i| byte.* = @truncate(i *% 17);
    var stream: [512]u8 = undefined;
    var w: bits.Writer = .init(&stream, 0);
    w.add(5, 3); // final dynamic block
    w.add(29 | (31 << 5) | (14 << 10), 14); // 286 literals, 32 distances, 18 precode lengths
    w.flush();
    const order = [_]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1 };
    for (order) |symbol| {
        w.add(if (symbol == 0) @as(u8, 1) else if (symbol == 1 or symbol == 2) @as(u8, 2) else 0, 3);
        w.flush();
    }
    for (0..318) |i| {
        const length: u8 = if (i == 'a' or i == 286 or i == 317) 1 else if (i == 256 or i == 285) 2 else 0;
        w.add(if (length == 0) @as(u8, 0) else if (length == 1) @as(u8, 1) else 3, if (length == 0) 1 else 2);
        w.flush();
    }
    w.add(3, 2); // literal/length 285
    w.add(0, 16); // length three
    w.add(1, 1); // distance 31
    w.add(16383, 14); // distance 65,536
    w.add(1, 2); // end of block
    w.alignToByte();
    var out: [3]u8 = undefined;
    var d: deflate64.Decompressor = .init;
    const result = try d.inflate(stream[0..w.at], &out, .{ .dictionary = dictionary });
    try testing.expectEqualSlices(u8, dictionary[0..3], &out);
    try testing.expectEqual(w.at, result.in_len);
    for (0..w.at) |n| try testing.expectError(error.Truncated, d.inflate(stream[0..n], &out, .{ .dictionary = dictionary }));
    var regular: Decompressor = .init;
    try testing.expectError(error.InvalidStream, regular.inflate(stream[0..w.at], &out, .{ .accept = .raw, .dictionary = dictionary }));
}

const Streamed = struct { out: []u8, in_len: usize };

/// Stream `in` through a Deflate64 `Inflate`, the input `in_step` bytes and
/// the output `out_step` bytes at a time, to the stream's end.
fn streamedTo(gpa: std.mem.Allocator, in: []const u8, dictionary: []const u8, in_step: usize, out_step: usize) !Streamed {
    const window = try gpa.alloc(u8, Inflate.deflate64_window_len);
    defer gpa.free(window);
    var z: Inflate = .init(window, .{ .accept = .raw, .format = .deflate64, .dictionary = dictionary });
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var chunk: [4096]u8 = undefined;
    var at: usize = 0;
    while (true) {
        const step = try z.decode(in[at..@min(in.len, at + in_step)], chunk[0..out_step]);
        at += step.in_len;
        try out.appendSlice(gpa, chunk[0..step.out_len]);
        switch (step.status) {
            .done => break,
            .need_input => if (at == in.len) return error.Truncated,
            .output_full, .block_end, .member_end => {},
        }
    }
    return .{ .out = try out.toOwnedSlice(gpa), .in_len = at };
}

/// The same, for a stream that is the whole of `in`.
fn streamed(gpa: std.mem.Allocator, in: []const u8, dictionary: []const u8, in_step: usize, out_step: usize) ![]u8 {
    const r = try streamedTo(gpa, in, dictionary, in_step, out_step);
    errdefer gpa.free(r.out);
    if (r.in_len != in.len) return error.TestUnexpectedResult;
    return r.out;
}

test "7-Zip's Deflate64 streams decode whole, streamed at any cut and through a reader" {
    const gpa = testing.allocator;
    const c = try corpus.Corpus.parse(captured);
    var it = c.records();
    var count: usize = 0;
    while (it.next()) |r| : (count += 1) {
        const stream = r.fields[3];
        const plain = try corpus.input(gpa, r.fields[2]);
        defer gpa.free(plain);
        errdefer std.debug.print("{s} {s}: {s}\n", .{ r.fields[0], r.fields[1], r.fields[2] });

        const out = try gpa.alloc(u8, plain.len);
        defer gpa.free(out);
        var d: deflate64.Decompressor = .init;
        const whole = try d.inflate(stream, out, .{});
        try testing.expectEqual(stream.len, whole.in_len);
        try testing.expectEqualSlices(u8, plain, out);

        for ([_][2]usize{ .{ 1, 4096 }, .{ 4096, 1 }, .{ 7, 300 }, .{ stream.len, 4096 } }) |cut| {
            if (cut[1] == 1 and plain.len > 70000) continue; // a byte at a time: the small ones say it
            const back = try streamed(gpa, stream, &.{}, cut[0], cut[1]);
            defer gpa.free(back);
            try testing.expectEqualSlices(u8, plain, back);
        }

        var input_buffer: [64]u8 = undefined;
        var input: std.testing.Reader = .init(&input_buffer, &.{.{ .buffer = stream }});
        const buffer = try gpa.alloc(u8, Inflate.deflate64_window_len + 4096);
        defer gpa.free(buffer);
        var reader: Inflate.Reader = .init(&input.interface, buffer, .{ .accept = .raw, .format = .deflate64 });
        const read = try reader.interface.allocRemaining(gpa, .unlimited);
        defer gpa.free(read);
        try testing.expectEqualSlices(u8, plain, read);
    }
    try testing.expect(count >= 40);
}

test "a streamed Deflate64 stream reaches 64 KiB back, past DEFLATE's window, and a prefix asks for more" {
    const gpa = testing.allocator;
    const dictionary = try gpa.alloc(u8, 65536);
    defer gpa.free(dictionary);
    for (dictionary, 0..) |*byte, i| byte.* = @truncate(i *% 17);
    var stream: [64]u8 = undefined;
    var w: bits.Writer = .init(&stream, 0);
    w.add(3, 3);
    fixedSymbol(&w, 257); // length three
    w.add(@bitReverse(@as(u16, 31)) >> 11, 5);
    w.add(16383, 14); // distance 65,536
    fixedSymbol(&w, 285);
    w.add(65535, 16); // 65,538 bytes
    w.add(0, 5); // distance one
    fixedSymbol(&w, 256);
    w.alignToByte();
    var expected: std.ArrayList(u8) = .empty;
    defer expected.deinit(gpa);
    try expected.appendSlice(gpa, dictionary[0..3]);
    try expected.appendNTimes(gpa, dictionary[2], 65538);
    for ([_]usize{ 1, 2, w.at }) |in_step| {
        const back = try streamed(gpa, stream[0..w.at], dictionary, in_step, 1000);
        defer gpa.free(back);
        try testing.expectEqualSlices(u8, expected.items, back);
    }
    for (0..w.at) |n| try testing.expectError(error.Truncated, streamed(gpa, stream[0..n], dictionary, 3, 1000));
    // The same stream as DEFLATE: distance code 31 does not exist.
    const window = try gpa.alloc(u8, 32768);
    defer gpa.free(window);
    var z: Inflate = .init(window, .{ .accept = .raw, .dictionary = dictionary });
    var out: [64]u8 = undefined;
    try testing.expectError(error.InvalidStream, z.decode(stream[0..w.at], &out));
}

/// Arbitrary bytes, and 7-Zip's streams cut and mutated: the streaming
/// Deflate64 decoder gives the whole-buffer one's answer, at any cut.
fn streamAgrees(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const c = try corpus.Corpus.parse(captured);
    var input: []u8 = undefined;
    if (shakedown.gen.boolean(s)) {
        input = try shakedown.gen.string(s, case.gpa, .{ .kind = .bytes, .max_len = 600, .average = 64 });
    } else {
        var it = c.records();
        var pick = shakedown.gen.intRange(s, usize, 0, 47);
        var r = it.next().?;
        while (pick > 0) : (pick -= 1) r = it.next() orelse break;
        const stream = r.fields[3][0..@min(r.fields[3].len, 3000)];
        input = try case.gpa.dupe(u8, stream);
        const flips = shakedown.gen.intRange(s, usize, 0, 4);
        for (0..flips) |_| {
            if (input.len == 0) break;
            input[shakedown.gen.intRange(s, usize, 0, input.len - 1)] ^= @as(u8, 1) << shakedown.gen.intRange(s, u3, 0, 7);
        }
    }
    const in_step = shakedown.gen.intRange(s, usize, 1, 64);
    const out_step = shakedown.gen.intRange(s, usize, 1, 4096);
    case.note("{d} bytes, {d} in, {d} out a step", .{ input.len, in_step, out_step });
    const out = try case.gpa.alloc(u8, 1 << 20);
    var d: deflate64.Decompressor = .init;
    const whole = d.inflate(input, out, .{ .partial = true });
    if (whole) |res| {
        if (!res.finished) return; // past the scratch output: not compared
    } else |_| {}
    const back = streamedTo(case.gpa, input, &.{}, in_step, out_step);
    if (whole) |res| {
        // Input after the stream's end is not taken.
        const ended = try back;
        try testing.expectEqual(res.in_len, ended.in_len);
        try testing.expectEqualSlices(u8, out[0..res.out_len], ended.out);
    } else |err| switch (err) {
        error.Truncated => try testing.expectError(error.Truncated, back),
        error.InvalidStream => try testing.expectError(error.InvalidStream, back),
        else => return err,
    }
}

test "fuzz: the streaming Deflate64 decoder answers as the whole-buffer one, at any cut" {
    try shakedown.check(testing.allocator, {}, streamAgrees, .{ .cases = 500, .seed = 0x64d64 });
}
