//! Unindexed decoding: captured references, arbitrary boundaries, unknown
//! history, false starts and bounded-work fallbacks.
const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const gen = @import("gen");
const corpus = @import("corpus.zig");
const parallel = @import("../parallel.zig");
const Native = @import("../Decompressor.zig");
const Deflate = @import("../stream/Deflate.zig");
const container = @import("../container.zig");
const Diagnostic = @import("../Diagnostic.zig");

fn accept(kind: container.Container) container.Accept {
    return switch (kind) {
        .raw => .raw,
        .zlib => .zlib,
        .gzip => .gzip,
    };
}

fn compressed(input: []const u8, kind: container.Container, strategy: Deflate.Strategy) ![]u8 {
    const a = testing.allocator;
    var encoder = try Deflate.init(a, .{ .level = 6, .strategy = strategy, .container = kind });
    defer encoder.deinit();
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(a);
    var piece: [32768]u8 = undefined;
    var at: usize = 0;
    while (at < input.len) {
        const end = @min(at + 8192, input.len);
        while (at < end) {
            const step = encoder.write(input[at..end], &piece);
            at += step.in_len;
            try result.appendSlice(a, piece[0..step.out_len]);
        }
        while (true) {
            const step = encoder.flush(.block, &piece);
            try result.appendSlice(a, piece[0..step.out_len]);
            if (step.done) break;
        }
    }
    while (true) {
        const step = encoder.finish(&piece);
        try result.appendSlice(a, piece[0..step.out_len]);
        if (step.done) break;
    }
    return result.toOwnedSlice(a);
}

test "speculative decoding joins unaligned blocks with shared history in every wrapper" {
    const a = testing.allocator;
    var io: std.Io.Threaded = .init(a, .{});
    defer io.deinit();
    const input = try gen.alloc(a, .text, 81, 260000);
    defer a.free(input);
    const back = try a.alloc(u8, input.len);
    defer a.free(back);
    var stats: parallel.Decompressor.Statistics = .{};
    var decoder = try parallel.Decompressor.init(a, .{ .concurrency = 4, .speculative = .{ .chunk_len = 65536, .search_len = 1024, .statistics = &stats } });
    defer decoder.deinit();
    for (std.enums.values(container.Container)) |kind| for ([_]Deflate.Strategy{ .default, .fixed, .huffman_only }) |strategy| {
        const stream = try compressed(input, kind, strategy);
        defer a.free(stream);
        const result = try decoder.inflate(io.io(), stream, back, .{ .accept = accept(kind) });
        try testing.expectEqual(stream.len, result.in_len);
        try testing.expectEqual(input.len, result.out_len);
        try testing.expectEqualSlices(u8, input, back);
        testing.expect(stats.speculative_bytes > 0) catch |err| {
            std.debug.print("no joins {t} {t} stats {any} stream {d}\n", .{ kind, strategy, stats, stream.len });
            return err;
        };
        try testing.expect(stats.chunks > 0);
    };
}

test "speculative decoding agrees with every captured producer and dictionary" {
    const a = testing.allocator;
    var decoder = try parallel.Decompressor.init(a, .{ .concurrency = 2, .speculative = .{ .chunk_len = 65536, .search_len = 512, .work_limit = 1 } });
    defer decoder.deinit();
    const c = try corpus.Corpus.parse(corpus.streams);
    var records = c.records();
    var count: usize = 0;
    while (records.next()) |r| {
        const input = try corpus.input(a, r.fields[2]);
        defer a.free(input);
        const dict = if (r.fields[3].len > 0) try corpus.input(a, r.fields[3]) else try a.alloc(u8, 0);
        defer a.free(dict);
        const back = try a.alloc(u8, input.len);
        defer a.free(back);
        const result = decoder.inflate(testing.io, r.fields[5], back, .{ .accept = std.meta.stringToEnum(container.Accept, r.fields[4]).?, .dictionary = dict }) catch |err| {
            std.debug.print("record {d} {s} {s} {s} {s} dict {s}: {t} first mismatch {?}\n", .{ r.index, r.fields[0], r.fields[1], r.fields[2], r.fields[4], r.fields[3], err, std.mem.findDiff(u8, input, back) });
            return err;
        };
        try testing.expectEqual(input.len, result.out_len);
        try testing.expectEqual(r.fields[5].len, result.in_len);
        try testing.expectEqualSlices(u8, input, back);
        count += 1;
    }
    try testing.expect(count > 3000);
}

fn compare(io: std.Io, decoder: *parallel.Decompressor, bytes: []const u8, left: []u8, right: []u8, options: Native.Options) !void {
    var ordinary: Native = .init;
    var nd: Diagnostic = .{};
    var pd: Diagnostic = .{};
    var no = options;
    no.diagnostic = &nd;
    var po = options;
    po.diagnostic = &pd;
    const reference = ordinary.inflate(bytes, left, no);
    const result = decoder.inflate(io, bytes, right, po);
    if (reference) |expected| {
        const actual = try result;
        try testing.expectEqual(expected, actual);
        try testing.expectEqualSlices(u8, left[0..expected.out_len], right[0..actual.out_len]);
    } else |err| {
        try testing.expectError(err, result);
        try testing.expectEqual(nd, pd);
    }
}

test "speculative decoding preserves captured invalid-stream verdicts and diagnostics" {
    const a = testing.allocator;
    var decoder = try parallel.Decompressor.init(a, .{ .concurrency = 2, .speculative = .{ .chunk_len = 8192, .search_len = 32, .work_limit = 1 } });
    defer decoder.deinit();
    const left = try a.alloc(u8, 4 << 20);
    defer a.free(left);
    const right = try a.alloc(u8, left.len);
    defer a.free(right);
    const c = try corpus.Corpus.parse(corpus.invalid);
    var records = c.records();
    while (records.next()) |r| {
        if (!std.mem.eql(u8, r.fields[2], "15")) continue;
        const dict = if (r.fields[3].len > 0) try corpus.input(a, r.fields[3]) else try a.alloc(u8, 0);
        defer a.free(dict);
        try compare(testing.io, &decoder, r.fields[4], left, right, .{ .accept = std.meta.stringToEnum(container.Accept, r.fields[1]).?, .dictionary = dict, .members = .one });
    }
}

test "speculative decoding handles concatenation, bad trailers, every truncation and short output" {
    const a = testing.allocator;
    const input = try gen.alloc(a, .text, 9, 20000);
    defer a.free(input);
    const first = try compressed(input, .gzip, .default);
    defer a.free(first);
    const second = try compressed(input, .gzip, .fixed);
    defer a.free(second);
    const stream = try std.mem.concat(a, u8, &.{ first, second });
    defer a.free(stream);
    const left = try a.alloc(u8, input.len * 2);
    defer a.free(left);
    const right = try a.alloc(u8, left.len);
    defer a.free(right);
    var decoder = try parallel.Decompressor.init(a, .{ .concurrency = 3, .speculative = .{ .chunk_len = 32768, .search_len = 128 } });
    defer decoder.deinit();
    try compare(testing.io, &decoder, stream, left, right, .{ .accept = .gzip });
    try compare(testing.io, &decoder, stream, left, right, .{ .accept = .gzip, .members = .one });
    for (0..first.len) |cut| try compare(testing.io, &decoder, first[0..cut], left, right, .{ .accept = .gzip });
    for ([_]usize{ 0, 1, 37, 8192, input.len - 1 }) |len| {
        try compare(testing.io, &decoder, first, left[0..len], right[0..len], .{ .accept = .gzip });
        try compare(testing.io, &decoder, first, left[0..len], right[0..len], .{ .accept = .gzip, .partial = true });
    }
    stream[first.len - 8] ^= 1;
    try compare(testing.io, &decoder, stream, left, right, .{ .accept = .gzip });
}

fn arbitrary(_: void, case: *shakedown.Case) !void {
    const bytes = try shakedown.gen.string(case.source, case.gpa, .{ .kind = .bytes, .max_len = 4096, .average = 128 });
    const output_len = shakedown.gen.intRange(case.source, usize, 0, 8192);
    const left = try case.gpa.alloc(u8, output_len);
    const right = try case.gpa.alloc(u8, output_len);
    var decoder = try parallel.Decompressor.init(case.gpa, .{ .concurrency = 2, .speculative = .{ .chunk_len = 4096, .search_len = 8, .work_limit = 1 } });
    defer decoder.deinit();
    try compare(testing.io, &decoder, bytes, left, right, .{ .accept = shakedown.gen.enumValue(case.source, container.Accept) });
}

test "speculative fuzz: arbitrary bytes retain the native reference verdict" {
    try shakedown.check(testing.allocator, {}, arbitrary, .{ .cases = 1000 });
}

test "speculative storage is exact, allocation failures and bounded fallback permit reuse" {
    const a = testing.allocator;
    const options: parallel.Decompressor.Options = .{ .concurrency = 2, .speculative = .{ .chunk_len = 256, .search_len = 16, .work_limit = 1 } };
    var no_resize: shakedown.alloc.NoResize = .init(a);
    try testing.checkAllAllocationFailures(no_resize.allocator(), struct {
        fn once(allocator: std.mem.Allocator) !void {
            var decoder = try parallel.Decompressor.init(allocator, options);
            decoder.deinit();
        }
    }.once, .{});
    const memory = try a.alignedAlloc(u8, .@"64", parallel.Decompressor.memory(options));
    defer a.free(memory);
    var decoder = parallel.Decompressor.initBuffer(memory, options);
    defer decoder.deinit();
    const input = try gen.alloc(a, .noise, 1, 10000);
    defer a.free(input);
    const stream = try compressed(input, .gzip, .default);
    defer a.free(stream);
    const back = try a.alloc(u8, input.len);
    defer a.free(back);
    const result = try decoder.inflate(testing.io, stream, back, .{ .accept = .gzip });
    try testing.expectEqualSlices(u8, input, back[0..result.out_len]);
    const reused = try decoder.inflate(testing.io, stream, back, .{ .accept = .gzip });
    try testing.expectEqual(result, reused);
}

test "speculative markers preserve the small-window captured stream at every boundary" {
    const Inflate = @import("../stream/Inflate.zig");
    const marked = @import("../marked.zig");
    const a = testing.allocator;
    const c = try corpus.Corpus.parse(corpus.streams);
    var it = c.records();
    while (it.next()) |r| {
        if (r.index != 792) continue;
        const input = try corpus.input(a, r.fields[2]);
        defer a.free(input);
        const back = try a.alloc(u8, input.len);
        defer a.free(back);
        const tokens = try a.alloc(u16, input.len);
        defer a.free(tokens);
        var window: [32768]u8 = undefined;
        var native: Inflate = .init(&window, .{ .accept = .zlib });
        var at: usize = 0;
        var written: usize = 0;
        while (true) {
            const step = try native.decode(r.fields[5][at..], back[written..]);
            at += step.in_len;
            written += step.out_len;
            if (step.status == .done) break;
            if (step.status != .block_end) continue;
            const point = try native.checkpoint();
            const bit: usize = @intCast(point.in_offset * 8 - point.bits);
            try testing.expect(marked.plausible(r.fields[5], bit, false) or marked.plausible(r.fields[5], bit, true));
            var m = marked.Decoder.init(r.fields[5], bit, tokens);
            _ = try m.block(testing.io);
            for (tokens[0..m.written], 0..) |token, i| {
                const value: u8 = if (token < 256) @intCast(token) else point.history[point.history_len - (33024 - token)];
                if (value != input[written + i]) {
                    std.debug.print("marker block start {d}, token {d} index {d} got {d} want {d}\n", .{ written, token, i, value, input[written + i] });
                    return error.WrongMarker;
                }
            }
        }
    }
}

fn validAndMutated(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const input = try gen.alloc(case.gpa, shakedown.gen.enumValue(s, gen.Kind), shakedown.gen.int(s, u16), shakedown.gen.intRange(s, usize, 0, 50000));
    const kind = shakedown.gen.enumValue(s, container.Container);
    const stream = try compressed(input, kind, shakedown.gen.enumValue(s, Deflate.Strategy));
    defer testing.allocator.free(stream);
    const left = try case.gpa.alloc(u8, input.len);
    const right = try case.gpa.alloc(u8, input.len);
    var decoder = try parallel.Decompressor.init(case.gpa, .{ .concurrency = 3, .speculative = .{ .chunk_len = 32768, .search_len = 256, .work_limit = 1 } });
    defer decoder.deinit();
    try compare(testing.io, &decoder, stream, left, right, .{ .accept = accept(kind) });
    if (stream.len > 0) {
        const at = shakedown.gen.intRange(s, usize, 0, stream.len - 1);
        stream[at] ^= @as(u8, 1) << shakedown.gen.int(s, u3);
        try compare(testing.io, &decoder, stream, left, right, .{ .accept = accept(kind) });
    }
}

test "speculative fuzz: valid streams and mutated streams agree with the reference" {
    try shakedown.check(testing.allocator, {}, validAndMutated, .{ .cases = 100 });
}

test "speculative cancellation survives inline and concurrent workers and preserves reuse" {
    const a = testing.allocator;
    const input = try gen.alloc(a, .text, 5, 1 << 20);
    defer a.free(input);
    const stream = try compressed(input, .gzip, .default);
    defer a.free(stream);
    const back = try a.alloc(u8, input.len);
    defer a.free(back);
    var decoder = try parallel.Decompressor.init(a, .{ .concurrency = 4, .speculative = .{ .chunk_len = 65536, .search_len = 1024 } });
    defer decoder.deinit();
    for ([_]std.Io.Limit{ .nothing, .unlimited }) |limit| {
        var threaded: std.Io.Threaded = .init(a, .{ .async_limit = limit });
        defer threaded.deinit();
        const io = threaded.io();
        var ready: std.Io.Event = .unset;
        const Task = struct {
            fn run(task_io: std.Io, p: *parallel.Decompressor, in: []const u8, out: []u8, started: *std.Io.Event) !Native.Result {
                var parked: std.Io.Event = .unset;
                started.set(task_io);
                // Cancellation is pending before inflate, independently of
                // CPU count and whether the caller wakes before decoding ends.
                parked.wait(task_io) catch {
                    task_io.recancel();
                };
                return p.inflate(task_io, in, out, .{ .accept = .gzip });
            }
        };
        var future = try io.concurrent(Task.run, .{ io, &decoder, stream, back, &ready });
        try ready.wait(io);
        try testing.expectError(error.Canceled, future.cancel(io));
        const result = try decoder.inflate(io, stream, back, .{ .accept = .gzip });
        try testing.expectEqual(input.len, result.out_len);
        try testing.expectEqualSlices(u8, input, back);
    }
}
