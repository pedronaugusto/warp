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
    var records: [1]zstd.seekable.Record = undefined;
    sink = .fixed(&bytes);
    _ = try p.writeSeekable(testing.io, "hello", &sink, &records, 128, true);
    reader = .fixed("hello");
    sink = .fixed(&bytes);
    _ = try p.writeSeekableReader(testing.io, &reader, &sink, &records, 128, true);
    var tiny: std.Io.Writer = .fixed(bytes[0..2]);
    try testing.expectError(error.WriteFailed, p.compress(testing.io, "hello", &tiny));
    try testing.expectEqual(allocations, counter.allocations);
}

test "zstd parallel: allocation failures and invalid options" {
    try testing.checkAllAllocationFailures(testing.allocator, allocationFailures, .{});
    for ([_]zstd.parallel.Options{ .{ .concurrency = 0 }, .{ .overlap_log = 10 }, .{ .job_len = 0 }, .{ .job_len = (1 << 30) + 1 } }) |options| {
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
    var input: [1000]u8 = @splat('a');
    var bytes: [4096]u8 = undefined;
    // A native scheduler may finish all jobs before Group.await, which
    // then bypasses the Io call. Deferred starts guarantee outstanding
    // jobs at the injected cancellation, for both batch and ring paths.
    for ([_]usize{ 256, 1000 }) |length| for ([_]bool{ false, true }) |read| {
        var p = try zstd.parallel.Compressor.init(gpa, .{ .job_len = 128, .concurrency = 3, .tuning = .{ .window_log = 10 } });
        defer p.deinit();
        const sim = try shakedown.Sim.init(gpa, .{
            .async_start = .deferred,
            .faults = &.{.{ .at = .{ .nth = .{ .call = .groupAwait, .n = 1 } }, .fault = .cancel }},
        });
        defer sim.deinit();
        const outcome = sim.run(canceledCompression, .{ sim.io(), &p, input[0..length], &bytes, read });
        switch (outcome) {
            .finished => {},
            .failed => |err| return err,
            else => return error.UnfinishedCancellation,
        }
        try testing.expectEqual(@as(u64, 1), sim.faults().?.count(.groupAwait));
        var sink: std.Io.Writer = .fixed(&bytes);
        var reader: std.Io.Reader = .fixed(input[0..length]);
        if (read) try p.compressReader(testing.io, &reader, &sink) else try p.compress(testing.io, input[0..length], &sink);
        var decoded: [1000]u8 = undefined;
        var d: zstd.Decompressor = .init;
        const result = try d.decompress(sink.buffered(), &decoded, .{});
        try testing.expectEqual(length, result.out_len);
        try testing.expectEqualSlices(u8, input[0..length], decoded[0..result.out_len]);
    };
}

fn canceledCompression(io: std.Io, p: *zstd.parallel.Compressor, input: []const u8, bytes: []u8, read: bool) !void {
    var sink: std.Io.Writer = .fixed(bytes);
    var reader: std.Io.Reader = .fixed(input);
    if (read) try testing.expectError(error.Canceled, p.compressReader(io, &reader, &sink)) else try testing.expectError(error.Canceled, p.compress(io, input, &sink));
}

test "zstd parallel: output failure joins jobs and allows both APIs to be reused" {
    const gpa = testing.allocator;
    const input = try gen.alloc(gpa, .text, 33, 8192);
    defer gpa.free(input);
    var p = try zstd.parallel.Compressor.init(gpa, .{ .job_len = 1024, .concurrency = 3, .tuning = .{ .window_log = 10 }, .frame = .{ .content_size = false } });
    defer p.deinit();
    var out: [16384]u8 = undefined;
    var expected: [16384]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&expected);
    try p.compress(testing.io, input, &sink);
    const n = sink.buffered().len;
    for ([_]bool{ false, true }) |read| {
        // The header fits, while the jobs' output cannot all fit. Both
        // early and later output failures leave worker memory reusable.
        for ([_]usize{ 18, n / 2 }) |capacity| {
            var small: std.Io.Writer = .fixed(out[0..capacity]);
            var reader: std.Io.Reader = .fixed(input);
            if (read) try testing.expectError(error.WriteFailed, p.compressReader(testing.io, &reader, &small)) else try testing.expectError(error.WriteFailed, p.compress(testing.io, input, &small));
            sink = .fixed(&out);
            reader = .fixed(input);
            if (read) try p.compressReader(testing.io, &reader, &sink) else try p.compress(testing.io, input, &sink);
            try testing.expectEqualSlices(u8, expected[0..n], sink.buffered());
        }
    }
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
    var serial_diagnostic: zstd.Diagnostic = .{};
    var pipeline_diagnostic: zstd.Diagnostic = .{};
    const expected = serial.decompress(encoded[0..n], serial_out, .{ .diagnostic = &serial_diagnostic }) catch |err| {
        try testing.expectError(err, p.decompress(testing.io, encoded[0..n], pipeline_out, .{ .diagnostic = &pipeline_diagnostic }));
        try testing.expectEqual(serial_diagnostic, pipeline_diagnostic);
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

test "zstd parallel seekable: independent dictionary frames, reader parity and concurrency" {
    const gpa = testing.allocator;
    const input = try gen.alloc(gpa, .text, 413, 20_000);
    defer gpa.free(input);
    const dictionary = try gpa.create(zstd.Dictionary);
    defer gpa.destroy(dictionary);
    dictionary.* = try .parse(input[0..4096]);
    var reference: ?[]u8 = null;
    defer if (reference) |bytes| gpa.free(bytes);
    for ([_]u16{ 1, 2, 7 }) |concurrency| {
        var p = try zstd.parallel.Compressor.init(gpa, .{ .job_len = 4096, .concurrency = concurrency, .dictionary = dictionary, .tuning = .{ .window_log = 12 }, .frame = .{ .format = .magicless } });
        defer p.deinit();
        var records: [20]zstd.seekable.Record = undefined;
        var sink: std.Io.Writer.Allocating = .init(gpa);
        defer sink.deinit();
        const count = try p.writeSeekable(testing.io, input, &sink.writer, &records, 1024, true);
        try testing.expectEqual(@as(usize, 20), count);
        if (reference) |bytes| try testing.expectEqualSlices(u8, bytes, sink.written()) else reference = try gpa.dupe(u8, sink.written());
        var index = try zstd.seekable.Index.init(gpa, sink.written());
        defer index.deinit();
        const reader = try gpa.create(zstd.seekable.Reader);
        defer gpa.destroy(reader);
        var window: [1024]u8 = undefined;
        reader.* = .init(&index, &window, .{ .dictionaries = &.{dictionary} });
        var output: [2000]u8 = undefined;
        try testing.expectEqual(output.len, try reader.read(957, &output));
        try testing.expectEqualSlices(u8, input[957..][0..output.len], &output);
        var streamed: std.Io.Writer.Allocating = .init(gpa);
        defer streamed.deinit();
        var source: std.Io.Reader = .fixed(input);
        try testing.expectEqual(count, try p.writeSeekableReader(testing.io, &source, &streamed.writer, &records, 1024, true));
        try testing.expectEqualSlices(u8, sink.written(), streamed.written());
        try testing.expectError(error.TooManyFrames, p.writeSeekable(testing.io, input, &streamed.writer, records[0..19], 1024, true));
    }
}

test "zstd parallel seekable: cancellation, output errors, empty input and reuse" {
    const gpa = testing.allocator;
    var p = try zstd.parallel.Compressor.init(gpa, .{ .job_len = 128, .concurrency = 3, .tuning = .{ .window_log = 10 } });
    defer p.deinit();
    const fio = try shakedown.FaultIo.init(gpa, testing.io, .{ .plan = &.{.{ .at = .{ .nth = .{ .call = .groupAwait, .n = 1 } }, .fault = .cancel }} });
    defer fio.deinit();
    var records: [4]zstd.seekable.Record = undefined;
    var output: [4096]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&output);
    try testing.expectError(error.Canceled, p.writeSeekable(fio.io(), "four frames of borrowed content", &sink, &records, 8, false));
    sink = .fixed(output[0..0]);
    try testing.expectError(error.WriteFailed, p.writeSeekable(testing.io, "content", &sink, &records, 8, false));
    for ([_]bool{ true, false }) |stream| {
        sink = .fixed(&output);
        var source: std.Io.Reader = .fixed("");
        const n = if (stream) try p.writeSeekableReader(testing.io, &source, &sink, &records, 8, false) else try p.writeSeekable(testing.io, "", &sink, &records, 8, false);
        try testing.expectEqual(@as(usize, 1), n);
        var index = try zstd.seekable.Index.init(gpa, sink.buffered());
        defer index.deinit();
        try testing.expectEqual(@as(u64, 0), index.content_size);
        try testing.expectEqual(@as(usize, 1), index.entries.len);
    }
}

test "zstd parallel: large windows use bounded default jobs" {
    for ([_]u5{ 28, 29, 30, 31 }) |log| {
        const size = zstd.parallel.Compressor.memory(.{ .concurrency = 1, .tuning = .{ .window_log = log } });
        if (@bitSizeOf(usize) == 64) try testing.expect(size != std.math.maxInt(usize));
    }
}
