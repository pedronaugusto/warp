//! Resumable decoding across input and output boundaries.
const std = @import("std");
const testing = std.testing;
const zstd = @import("../zstd.zig");
const fixtures = @import("zstd_decode_test.zig");
const corpus = @import("corpus.zig");
const gen = @import("gen");
const shakedown = @import("shakedown");

fn windowSize(in: []const u8, format: zstd.Format) !usize {
    var at: usize = 0;
    var size: u64 = 0;
    while (at < in.len) {
        const head = try zstd.frameHeader(in[at..], format);
        if (head == .zstd) size = @max(size, head.zstd.window_size + head.zstd.blockMax());
        at += try zstd.frameLength(in[at..], format);
    }
    return @intCast(size);
}

fn chunked(gpa: std.mem.Allocator, in: []const u8, expected: []const u8, options: zstd.Decompress.Options, input_chunk: usize, output_chunk: usize) !void {
    const window = try gpa.alloc(u8, try windowSize(in, options.format));
    defer gpa.free(window);
    const state = try gpa.create(zstd.Decompress);
    defer gpa.destroy(state);
    state.* = .init(window, options);
    const out = try gpa.alloc(u8, expected.len + 1);
    defer gpa.free(out);
    var ip: usize = 0;
    var op: usize = 0;
    while (true) {
        const step = try state.decode(in[ip..][0..@min(input_chunk, in.len - ip)], out[op..][0..@min(output_chunk, out.len - op)]);
        ip += step.in_len;
        op += step.out_len;
        if (step.status == .done) break;
        if (ip == in.len and step.status == .need_input) break;
        try testing.expect(step.in_len != 0 or step.out_len != 0 or step.status == .frame_end);
    }
    try state.finish();
    try testing.expectEqual(in.len, ip);
    try testing.expectEqualSlices(u8, expected, out[0..op]);
}

test "zstd streaming decode: captured frames, dictionaries and concatenation" {
    const gpa = testing.allocator;
    var dictionaries = try fixtures.Dictionaries.load(gpa);
    defer dictionaries.deinit(gpa);
    const captured = try corpus.Corpus.parse(fixtures.frames);
    var records = captured.records();
    while (records.next()) |record| {
        const plain = try fixtures.input(gpa, record.fields[2]);
        defer gpa.free(plain);
        const options: zstd.Decompress.Options = .{ .dictionaries = dictionaries.get(record.fields[3]), .format = if (std.mem.containsAtLeast(u8, record.fields[1], 1, "magicless")) .magicless else .standard };
        try chunked(gpa, record.fields[4], plain, options, 173, 1024);
    }
}

test "zstd streaming decode: single-byte chunks and sliding history" {
    const gpa = testing.allocator;
    const in = try gen.alloc(gpa, .json, 81, 20_000);
    defer gpa.free(in);
    var c = try zstd.Compressor.init(gpa, .{ .level = 6, .tuning = .{ .window_log = 10 }, .max_input = in.len });
    defer c.deinit();
    const encoded = try gpa.alloc(u8, zstd.Compressor.bound(in.len));
    defer gpa.free(encoded);
    const n = try c.compress(in, encoded, .{ .content_size = false });
    for ([_]usize{ 1, 7, 301, 8192 }) |input_chunk| for ([_]usize{ 1, 13, 1024, 4096 }) |output_chunk| {
        try chunked(gpa, encoded[0..n], in, .{}, input_chunk, output_chunk);
    };
}

test "zstd streaming decode: every prefix is truncated, reset clears errors" {
    const gpa = testing.allocator;
    const in = "truncation checks include header, block and checksum";
    var c = try zstd.Compressor.init(gpa, .{ .max_input = in.len });
    defer c.deinit();
    var encoded: [128]u8 = undefined;
    const n = try c.compress(in, &encoded, .{});
    var window: [1024]u8 = undefined;
    const state = try gpa.create(zstd.Decompress);
    defer gpa.destroy(state);
    state.* = .init(&window, .{ .frames = .one });
    var out: [128]u8 = undefined;
    for (0..n) |cut| {
        state.reset();
        const step = try state.decode(encoded[0..cut], &out);
        try testing.expectEqual(zstd.Decompress.Status.need_input, step.status);
        try testing.expectError(error.Truncated, state.finish());
    }
    state.reset();
    const done = try state.decode(encoded[0..n], &out);
    try testing.expectEqual(zstd.Decompress.Status.done, done.status);
    try state.finish();
    try testing.expectEqualSlices(u8, in, out[0..done.out_len]);
}

test "zstd streaming reader: buffered reads and codec errors" {
    const gpa = testing.allocator;
    const in = try gen.alloc(gpa, .text, 16, 200_000);
    defer gpa.free(in);
    var c = try zstd.Compressor.init(gpa, .{ .level = 3, .max_input = in.len });
    defer c.deinit();
    const encoded = try gpa.alloc(u8, zstd.Compressor.bound(in.len));
    defer gpa.free(encoded);
    const n = try c.compress(in, encoded, .{});
    const window = try gpa.alloc(u8, 4096 + try windowSize(encoded[0..n], .standard));
    defer gpa.free(window);
    const reader = try gpa.create(zstd.Decompress.Reader);
    defer gpa.destroy(reader);
    var input: std.Io.Reader = .fixed(encoded[0..n]);
    reader.* = .init(&input, window, .{});
    const out = try gpa.alloc(u8, in.len);
    defer gpa.free(out);
    for (out) |*b| b.* = try reader.interface.takeByte();
    try testing.expectError(error.EndOfStream, reader.interface.takeByte());
    try testing.expectEqualSlices(u8, in, out);
    input = .fixed(encoded[0 .. n - 1]);
    reader.* = .init(&input, window, .{});
    var sink: std.Io.Writer.Discarding = .init(&.{});
    try testing.expectError(error.ReadFailed, reader.interface.streamRemaining(&sink.writer));
    try testing.expectEqual(error.Truncated, reader.err().?);
}

fn property(_: void, case: *shakedown.Case) anyerror!void {
    const in = try shakedown.gen.string(case.source, case.gpa, .{ .kind = .bytes, .min_len = 0, .max_len = 4096, .average = 512 });
    defer case.gpa.free(in);
    var c = try zstd.Compressor.init(case.gpa, .{ .max_input = in.len });
    defer c.deinit();
    const encoded = try case.gpa.alloc(u8, zstd.Compressor.bound(in.len));
    defer case.gpa.free(encoded);
    const n = try c.compress(in, encoded, .{});
    try chunked(case.gpa, encoded[0..n], in, .{}, shakedown.gen.intRange(case.source, usize, 1, 257), shakedown.gen.intRange(case.source, usize, 1, 257));
    const stream = try streamEncode(case.gpa, in, .{ .pledged_size = in.len }, shakedown.gen.intRange(case.source, usize, 1, 257), shakedown.gen.intRange(case.source, usize, 1, 257));
    defer case.gpa.free(stream);
    try testing.expectEqualSlices(u8, encoded[0..n], stream);
}

test "zstd streaming decode: chunking property" {
    try shakedown.check(testing.allocator, {}, property, .{ .cases = 100, .seed = 0x44ce03 });
}

fn streamEncode(gpa: std.mem.Allocator, in: []const u8, options: zstd.Compress.Options, input_chunk: usize, output_chunk: usize) ![]u8 {
    var s = try zstd.Compress.init(gpa, options);
    defer s.deinit();
    var encoded: std.ArrayList(u8) = .empty;
    errdefer encoded.deinit(gpa);
    const buffer = try gpa.alloc(u8, output_chunk);
    defer gpa.free(buffer);
    var ip: usize = 0;
    while (ip < in.len) {
        const step = try s.write(in[ip..][0..@min(input_chunk, in.len - ip)], buffer);
        ip += step.in_len;
        try encoded.appendSlice(gpa, buffer[0..step.out_len]);
        try testing.expect(step.in_len != 0 or step.out_len != 0);
    }
    while (true) {
        const drain = try s.finish(buffer);
        try encoded.appendSlice(gpa, buffer[0..drain.out_len]);
        if (drain.done) break;
    }
    return encoded.toOwnedSlice(gpa);
}

test "zstd streaming encode: chunking and whole-buffer engines agree" {
    const gpa = testing.allocator;
    const in = try gen.alloc(gpa, .json, 12, 300_000);
    defer gpa.free(in);
    const out = try gpa.alloc(u8, zstd.Compressor.bound(in.len));
    defer gpa.free(out);
    for ([_]i32{ -5, 1, 3, 6, 9, 13, 16, 19, 22 }) |level| {
        const options: zstd.Compress.Options = .{ .level = level, .pledged_size = in.len };
        var c = try zstd.Compressor.init(gpa, .{ .level = level, .max_input = in.len });
        defer c.deinit();
        const n = try c.compress(in, out, .{});
        for ([_]usize{ 1, 257, 8192, in.len }) |chunk| {
            const encoded = try streamEncode(gpa, in, options, chunk, 307);
            defer gpa.free(encoded);
            try testing.expectEqualSlices(u8, out[0..n], encoded);
            try chunked(gpa, encoded, in, .{}, 301, 509);
        }
    }
}

test "zstd streaming encode: flush, unknown sizes, magicless and reset" {
    const gpa = testing.allocator;
    var s = try zstd.Compress.init(gpa, .{ .level = 6, .tuning = .{ .window_log = 10 }, .frame = .{ .format = .magicless } });
    defer s.deinit();
    const in = try gen.alloc(gpa, .text, 74, 20_000);
    defer gpa.free(in);
    var output: [256]u8 = undefined;
    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(gpa);
    for (0..2) |_| {
        encoded.clearRetainingCapacity();
        var ip: usize = 0;
        while (ip < in.len) {
            const step = try s.write(in[ip..][0..@min(317, in.len - ip)], &output);
            ip += step.in_len;
            try encoded.appendSlice(gpa, output[0..step.out_len]);
            while (true) {
                const flushed = try s.flush(&output);
                try encoded.appendSlice(gpa, output[0..flushed.out_len]);
                if (flushed.done) break;
            }
        }
        while (true) {
            const finished = try s.finish(&output);
            try encoded.appendSlice(gpa, output[0..finished.out_len]);
            if (finished.done) break;
        }
        try chunked(gpa, encoded.items, in, .{ .format = .magicless }, 1, 13);
        try testing.expectError(error.Finished, s.write("x", &output));
        s.reset();
    }
}

test "zstd streaming encode: attached dictionaries preserve whole-buffer parity and sliding history" {
    const gpa = testing.allocator;
    var dictionaries = try fixtures.Dictionaries.load(gpa);
    defer dictionaries.deinit(gpa);
    const in = try gen.alloc(gpa, .json, 4, 20_000);
    defer gpa.free(in);
    var raw = zstd.Dictionary.raw(in[0..4096]);
    var out: [24_000]u8 = undefined;
    const choices = [_]*const zstd.Dictionary{ &raw, dictionaries.values[0] };
    for (choices) |dictionary| for ([_]i32{ 1, 3, 9, 19 }) |level| {
        const tuning: zstd.Tuning = .{ .window_log = 10 };
        var c = try zstd.Compressor.init(gpa, .{ .level = level, .tuning = tuning, .dictionary = dictionary, .max_input = in.len });
        defer c.deinit();
        const n = try c.compress(in, &out, .{});
        const encoded = try streamEncode(gpa, in, .{ .level = level, .tuning = tuning, .dictionary = dictionary, .pledged_size = in.len }, 7, 13);
        defer gpa.free(encoded);
        try testing.expectEqualSlices(u8, out[0..n], encoded);
        try chunked(gpa, encoded, in, .{ .dictionaries = &.{dictionary} }, 1, 1);
    };
}

test "zstd streaming encode: long-distance state survives chunking and window compaction" {
    const gpa = testing.allocator;
    const in = try gen.alloc(gpa, .noise, 78, 600_000);
    defer gpa.free(in);
    @memcpy(in[400_000..], in[0..200_000]);
    const out = try gpa.alloc(u8, zstd.Compressor.bound(in.len));
    defer gpa.free(out);
    for ([_]i32{ 1, 19 }) |level| {
        const tuning: zstd.Tuning = .{ .long_distance = true, .window_log = 19 };
        var c = try zstd.Compressor.init(gpa, .{ .level = level, .tuning = tuning, .max_input = in.len });
        defer c.deinit();
        const n = try c.compress(in, out, .{});
        const encoded = try streamEncode(gpa, in, .{ .level = level, .tuning = tuning, .pledged_size = in.len }, 307, 257);
        defer gpa.free(encoded);
        try testing.expectEqualSlices(u8, out[0..n], encoded);
        try chunked(gpa, encoded, in, .{}, 509, 1024);
    }
}

test "zstd streaming encode: pledge mismatch and single-byte finish" {
    const gpa = testing.allocator;
    var s = try zstd.Compress.init(gpa, .{ .pledged_size = 3 });
    defer s.deinit();
    var output: [128]u8 = undefined;
    _ = try s.write("ab", &output);
    try testing.expectError(error.SizeMismatch, s.finish(&output));
    s.reset();
    const encoded = try streamEncode(gpa, "abc", .{ .pledged_size = 3 }, 1, 1);
    defer gpa.free(encoded);
    try chunked(gpa, encoded, "abc", .{}, 1, 1);
}

test "zstd streaming writer: buffered, unbuffered and splatted input" {
    const gpa = testing.allocator;
    for ([_]usize{ 0, 13, 4096 }) |buffer_len| {
        var s = try zstd.Compress.init(gpa, .{ .pledged_size = 13 });
        defer s.deinit();
        var sink: std.Io.Writer.Allocating = .init(gpa);
        defer sink.deinit();
        var buffer: [4096]u8 = undefined;
        var writer: zstd.Compress.Writer = .init(&s, &sink.writer, buffer[0..buffer_len]);
        try writer.interface.writeAll("start");
        try writer.interface.splatByteAll('x', 8);
        try writer.finish();
        try chunked(gpa, sink.written(), "startxxxxxxxx", .{}, 1, 1);
    }
}

fn initStream(gpa: std.mem.Allocator) !void {
    var no_resize = shakedown.alloc.NoResize.init(gpa);
    var s = try zstd.Compress.init(no_resize.allocator(), .{ .level = 6, .pledged_size = 2000 });
    defer s.deinit();
    var in: [2000]u8 = @splat('a');
    var out: [32]u8 = undefined;
    _ = try s.write(&in, &out);
    while (!(try s.finish(&out)).done) {}
}

test "zstd streaming encode: allocation failures and caller storage" {
    try testing.checkAllAllocationFailures(testing.allocator, initStream, .{});
    const options: zstd.Compress.Options = .{ .level = 6, .pledged_size = 37 };
    const buffer = try testing.allocator.alignedAlloc(u8, .@"64", zstd.Compress.memory(options));
    defer testing.allocator.free(buffer);
    var s: zstd.Compress = .initBuffer(buffer, options);
    defer s.deinit();
    var out: [128]u8 = undefined;
    const in: [37]u8 = @splat('z');
    _ = try s.write(&in, &out);
    try testing.expect((try s.finish(&out)).done);
    var counter: testing.FailingAllocator = .init(testing.allocator, .{});
    var owned = try zstd.Compress.init(counter.allocator(), options);
    defer owned.deinit();
    try testing.expectEqual(zstd.Compress.memory(options), counter.allocated_bytes);
    const allocations = counter.allocations;
    _ = try owned.write(&in, &out);
    _ = try owned.finish(&out);
    owned.reset();
    try testing.expectEqual(allocations, counter.allocations);
}
