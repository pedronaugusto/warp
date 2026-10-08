//! Ordered jobs, overlap priming and concurrency invariance.
const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const gen = @import("gen");
const zstd = @import("../zstd.zig");
const captured = @import("zstd_decode_test.zig");
const corpus = @import("corpus.zig");

fn run(gpa: std.mem.Allocator, input: []const u8, options: zstd.parallel.Options, reader: bool) ![]u8 {
    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    var p = try zstd.parallel.Compressor.init(gpa, options);
    defer p.deinit();
    if (reader) {
        var in: std.Io.Reader = .fixed(input);
        try p.compressReader(testing.io, &in, &sink.writer);
    } else try p.compress(testing.io, input, &sink.writer);
    return gpa.dupe(u8, sink.written());
}

test "zstd parallel: all strategies, dictionary, rsyncable and concurrency 1-16" {
    const gpa = testing.allocator;
    const in = try gen.alloc(gpa, .json, 18, 8192);
    defer gpa.free(in);
    const dict = zstd.Dictionary.raw(in[0..1024]);
    var decoded: [8192]u8 = undefined;
    var d: zstd.Decompressor = .init;
    inline for (std.meta.tags(zstd.Strategy)) |strategy| {
        for ([_]bool{ false, true }) |rsyncable| {
            var options: zstd.parallel.Options = .{ .job_len = 1024, .concurrency = 1, .tuning = .{ .strategy = strategy, .window_log = 10 }, .dictionary = &dict, .rsyncable = rsyncable, .frame = .{ .content_size = false } };
            const baseline = try run(gpa, in, options, false);
            defer gpa.free(baseline);
            const result = try d.decompress(baseline, &decoded, .{ .dictionaries = &.{&dict} });
            try testing.expectEqualSlices(u8, in, decoded[0..result.out_len]);
            try testing.expectEqual(baseline.len, try zstd.frameLength(baseline, .standard));
            for (2..17) |concurrency| {
                options.concurrency = @intCast(concurrency);
                const encoded = try run(gpa, in, options, false);
                defer gpa.free(encoded);
                try testing.expectEqualSlices(u8, baseline, encoded);
            }
            options.concurrency = 3;
            const read = try run(gpa, in, options, true);
            defer gpa.free(read);
            try testing.expectEqualSlices(u8, baseline, read);
        }
    }
}

test "zstd parallel: empty, short, magicless, checksums and reuse" {
    const gpa = testing.allocator;
    var out: [4096]u8 = undefined;
    var decoded: [1000]u8 = undefined;
    var d: zstd.Decompressor = .init;
    for ([_]zstd.Format{ .standard, .magicless }) |format| {
        for ([_]bool{ false, true }) |checksum| {
            var p = try zstd.parallel.Compressor.init(gpa, .{ .job_len = 128, .concurrency = 3, .tuning = .{ .window_log = 10 }, .frame = .{ .format = format, .checksum = checksum } });
            defer p.deinit();
            for ([_]usize{ 0, 1, 127, 128, 129, 1000 }) |len| {
                @memset(decoded[0..len], 'a');
                var sink: std.Io.Writer = .fixed(&out);
                try p.compress(testing.io, decoded[0..len], &sink);
                const n = sink.buffered().len;
                const result = try d.decompress(out[0..n], &decoded, .{ .format = format });
                try testing.expectEqual(len, result.out_len);
                for (decoded[0..len]) |byte| try testing.expectEqual(@as(u8, 'a'), byte);
                var again: [4096]u8 = undefined;
                sink = .fixed(&again);
                try p.compress(testing.io, decoded[0..len], &sink);
                try testing.expectEqualSlices(u8, out[0..n], sink.buffered());
            }
        }
    }
}

fn allocationFailures(gpa: std.mem.Allocator) !void {
    var no_resize = shakedown.alloc.NoResize.init(gpa);
    var counter: testing.FailingAllocator = .init(no_resize.allocator(), .{});
    const options: zstd.parallel.Options = .{ .job_len = 128, .concurrency = 2, .tuning = .{ .window_log = 10 } };
    var p = try zstd.parallel.Compressor.init(counter.allocator(), .{ .job_len = 128, .concurrency = 2, .tuning = .{ .window_log = 10 } });
    defer p.deinit();
    try testing.expectEqual(zstd.parallel.Compressor.memory(options), counter.allocated_bytes);
    const allocations = counter.allocations;
    var bytes: [128]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&bytes);
    try p.compress(testing.io, "hello", &sink);
    var reader: std.Io.Reader = .fixed("hello");
    sink = .fixed(&bytes);
    try p.compressReader(testing.io, &reader, &sink);
    var tiny: std.Io.Writer = .fixed(bytes[0..2]);
    try testing.expectError(error.WriteFailed, p.compress(testing.io, "hello", &tiny));
    try testing.expectEqual(allocations, counter.allocations);
}

test "zstd parallel: allocation failures and invalid options" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationFailures, .{});
    for ([_]zstd.parallel.Options{ .{ .concurrency = 0 }, .{ .overlap_log = 10 }, .{ .job_len = 0 }, .{ .job_len = 1 << 30 } }) |options| {
        try testing.expectEqual(std.math.maxInt(usize), zstd.parallel.Compressor.memory(options));
        try testing.expectError(error.InvalidOptions, zstd.parallel.Compressor.init(testing.allocator, options));
    }
}

test "zstd parallel: formatted dictionaries across jobs and long-distance priming" {
    const gpa = testing.allocator;
    var dictionaries = try captured.Dictionaries.load(gpa);
    defer dictionaries.deinit(gpa);
    const input = try gen.alloc(gpa, .text, 81, 20_000);
    defer gpa.free(input);
    var decoded: [20_000]u8 = undefined;
    var d: zstd.Decompressor = .init;
    for (dictionaries.values[0..dictionaries.count]) |dictionary| {
        const encoded = try run(gpa, input, .{ .dictionary = dictionary, .job_len = 1024, .concurrency = 3, .tuning = .{ .window_log = 10 } }, false);
        defer gpa.free(encoded);
        _ = try d.decompress(encoded, &decoded, .{ .dictionaries = &.{dictionary} });
        try testing.expectEqualSlices(u8, input, &decoded);
    }
    const encoded = try run(gpa, input, .{ .job_len = 1024, .concurrency = 3, .tuning = .{ .window_log = 10, .long_distance = true } }, false);
    defer gpa.free(encoded);
    var reader: std.Io.Reader = .fixed(encoded);
    const window = try gpa.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max);
    defer gpa.free(window);
    var oracle: std.compress.zstd.Decompress = .init(&reader, window, .{});
    try oracle.reader.readSliceAll(&decoded);
    try testing.expectEqualSlices(u8, input, &decoded);
}

test "zstd parallel: canceled jobs are joined and the compressor can be reused" {
    const gpa = testing.allocator;
    const fio = try shakedown.FaultIo.init(gpa, testing.io, .{ .plan = &.{.{ .at = .{ .nth = .{ .call = .groupAwait, .n = 1 } }, .fault = .cancel }} });
    defer fio.deinit();
    var p = try zstd.parallel.Compressor.init(gpa, .{ .job_len = 128, .concurrency = 3, .tuning = .{ .window_log = 10 } });
    defer p.deinit();
    var input: [1000]u8 = @splat('a');
    var bytes: [4096]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&bytes);
    try testing.expectError(error.Canceled, p.compress(fio.io(), &input, &sink));
    sink = .fixed(&bytes);
    try p.compress(testing.io, &input, &sink);
    var decoded: [1000]u8 = undefined;
    var d: zstd.Decompressor = .init;
    _ = try d.decompress(sink.buffered(), &decoded, .{});
    try testing.expectEqualSlices(u8, &input, &decoded);
}

test "zstd parallel decode: every captured frame, exact output and dictionaries" {
    const gpa = testing.allocator;
    var dictionaries = try captured.Dictionaries.load(gpa);
    defer dictionaries.deinit(gpa);
    var p = try zstd.parallel.Decompressor.init(gpa, .{});
    defer p.deinit();
    const c = try corpus.Corpus.parse(captured.frames);
    var it = c.records();
    while (it.next()) |record| {
        const input = try captured.input(gpa, record.fields[2]);
        defer gpa.free(input);
        const output = try gpa.alloc(u8, input.len);
        defer gpa.free(output);
        const format: zstd.Format = if (std.mem.find(u8, record.fields[1], "magicless=true") != null) .magicless else .standard;
        const result = p.decompress(testing.io, record.fields[4], output, .{ .dictionaries = dictionaries.get(record.fields[3]), .format = format }) catch |err| {
            std.debug.print("pipeline {s} | {s} | {s}: {t}\n", .{ record.fields[1], record.fields[2], record.fields[3], err });
            return err;
        };
        try testing.expectEqual(record.fields[4].len, result.in_len);
        try testing.expectEqual(input.len, result.out_len);
        if (!std.mem.eql(u8, input, output)) {
            std.debug.print("wrong pipeline {s} | {s} | {s}\n", .{ record.fields[1], record.fields[2], record.fields[3] });
            try testing.expectEqualSlices(u8, input, output);
        }
    }
}

fn decodeProperty(_: void, case: *shakedown.Case) anyerror!void {
    const kinds = [_]gen.Kind{ .text, .json, .noise };
    const kind = kinds[shakedown.gen.intRange(case.source, usize, 0, kinds.len - 1)];
    const input = try gen.alloc(case.gpa, kind, shakedown.gen.intRange(case.source, u64, 0, 1000), 200_000);
    var c = try zstd.Compressor.init(case.gpa, .{ .max_input = input.len });
    defer c.deinit();
    const encoded = try case.gpa.alloc(u8, zstd.Compressor.bound(input.len));
    const n = try c.compress(input, encoded, .{});
    if (shakedown.gen.boolean(case.source)) encoded[shakedown.gen.intRange(case.source, usize, 0, n - 1)] ^= @as(u8, 1) << shakedown.gen.intRange(case.source, u3, 0, 7);
    const capacities = [_]usize{ 0, 1, 1000, 100_000, 200_000 };
    const capacity = capacities[shakedown.gen.intRange(case.source, usize, 0, capacities.len - 1)];
    const serial_out = try case.gpa.alloc(u8, capacity);
    const pipeline_out = try case.gpa.alloc(u8, capacity);
    var serial: zstd.Decompressor = .init;
    var p = try zstd.parallel.Decompressor.init(case.gpa, .{});
    defer p.deinit();
    const expected = serial.decompress(encoded[0..n], serial_out, .{}) catch |err| {
        try testing.expectError(err, p.decompress(testing.io, encoded[0..n], pipeline_out, .{}));
        return;
    };
    const actual = try p.decompress(testing.io, encoded[0..n], pipeline_out, .{});
    try testing.expectEqual(expected, actual);
    try testing.expectEqualSlices(u8, serial_out[0..actual.out_len], pipeline_out[0..actual.out_len]);
}

test "zstd parallel decode: mutations and capacity errors agree with the core" {
    try shakedown.check(testing.allocator, {}, decodeProperty, .{ .cases = 100, .seed = 0x713032, .regressions = &.{"0:0:1:8ab"} });
}

fn decodeAllocationFailures(gpa: std.mem.Allocator) !void {
    var no_resize = shakedown.alloc.NoResize.init(gpa);
    var counter: testing.FailingAllocator = .init(no_resize.allocator(), .{});
    const options: zstd.parallel.Decompressor.Options = .{};
    var p = try zstd.parallel.Decompressor.init(counter.allocator(), options);
    defer p.deinit();
    try testing.expectEqual(zstd.parallel.Decompressor.memory(options), counter.allocated_bytes);
    const allocations = counter.allocations;
    var out: [16]u8 = undefined;
    const frame = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd, 0x20, 0, 1, 0, 0 };
    _ = try p.decompress(testing.io, &frame, &out, .{});
    try testing.expectEqual(allocations, counter.allocations);
}

test "zstd parallel decode: exact storage, allocation failures and canceled workers" {
    try testing.checkAllAllocationFailures(testing.allocator, decodeAllocationFailures, .{});
    const gpa = testing.allocator;
    const input = try gen.alloc(gpa, .text, 64, 200_000);
    defer gpa.free(input);
    const encoded = try gpa.alloc(u8, zstd.Compressor.bound(input.len));
    defer gpa.free(encoded);
    const decoded = try gpa.alloc(u8, input.len);
    defer gpa.free(decoded);
    var c = try zstd.Compressor.init(gpa, .{ .max_input = input.len });
    defer c.deinit();
    const n = try c.compress(input, encoded, .{});
    var p = try zstd.parallel.Decompressor.init(gpa, .{});
    defer p.deinit();
    const fio = try shakedown.FaultIo.init(gpa, testing.io, .{ .plan = &.{.{ .at = .{ .nth = .{ .call = .groupAwait, .n = 1 } }, .fault = .cancel }} });
    defer fio.deinit();
    try testing.expectError(error.Canceled, p.decompress(fio.io(), encoded[0..n], decoded, .{}));
    _ = try p.decompress(testing.io, encoded[0..n], decoded, .{});
    try testing.expectEqualSlices(u8, input, decoded);
    try testing.expectError(error.InvalidOptions, zstd.parallel.Decompressor.init(gpa, .{ .concurrency = 0 }));
}
