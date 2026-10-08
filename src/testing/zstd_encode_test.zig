//! Whole-buffer zstd encoding: independent decoding, bounded output,
//! continued positions, exact memory and allocation failures.
const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const inputs = @import("gen");
const zstd = @import("../zstd.zig");
const Compressor = zstd.Compressor;

fn roundTrip(gpa: std.mem.Allocator, c: *Compressor, in: []const u8, f: Compressor.Frame) !void {
    const out = try gpa.alloc(u8, Compressor.bound(in.len));
    defer gpa.free(out);
    const n = try c.compress(in, out, f);
    const back = try gpa.alloc(u8, in.len);
    defer gpa.free(back);
    const d = try gpa.create(zstd.Decompressor);
    defer gpa.destroy(d);
    d.* = .init;
    const r = try d.decompress(out[0..n], back, .{ .format = f.format });
    try testing.expectEqual(n, r.in_len);
    try testing.expectEqual(in.len, r.out_len);
    try testing.expectEqualSlices(u8, in, back);
    if (f.format == .standard) {
        var reader: std.Io.Reader = .fixed(out[0..n]);
        const window = try gpa.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max);
        defer gpa.free(window);
        var oracle: std.compress.zstd.Decompress = .init(&reader, window, .{});
        try oracle.reader.readSliceAll(back);
        try testing.expectEqualSlices(u8, in, back);
    }
    // Reuse after another frame, into the exact compressed capacity.
    const again = try gpa.alloc(u8, n);
    defer gpa.free(again);
    try testing.expectEqual(n, try c.compress(in, again, f));
    try testing.expectEqualSlices(u8, out[0..n], again);
}

test "zstd encoder: implemented strategies round-trip boundary lengths and frame options" {
    const gpa = testing.allocator;
    const strategies = [_]Compressor.Strategy{ .fast, .dfast, .greedy, .lazy, .lazy2, .btlazy2, .btopt, .btultra, .btultra2 };
    for (strategies) |strategy| {
        var c = try Compressor.init(gpa, .{ .level = 6, .tuning = .{ .strategy = strategy }, .max_input = 300_000 });
        defer c.deinit();
        for (std.enums.values(inputs.Kind)) |kind| for ([_]usize{ 0, 1, 6, 7, 16, 37, 255, 256, 1024, 16384, 65535, 131072, 300_000 }) |len| {
            const in = try inputs.alloc(gpa, kind, 4, len);
            defer gpa.free(in);
            try roundTrip(gpa, &c, in, .{ .checksum = len & 1 == 0, .content_size = len % 3 == 0, .format = if (len % 5 == 0) .magicless else .standard });
        };
    }
}

test "zstd encoder: input beyond max_input stays inside caller memory" {
    const gpa = testing.allocator;
    const in = try inputs.alloc(gpa, .json, 22, 20_000);
    defer gpa.free(in);
    for ([_]i32{ 1, 3, 6, 9, 13, 15, 16, 19, 22 }) |level| {
        var c = try Compressor.init(gpa, .{ .level = level, .max_input = 37 });
        defer c.deinit();
        try roundTrip(gpa, &c, in, .{});
    }
}

test "zstd encoder: small and large calls can change the level's strategy" {
    const gpa = testing.allocator;
    for ([_]i32{ 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22 }) |level| {
        var c = try Compressor.init(gpa, .{ .level = level, .max_input = 300_000 });
        defer c.deinit();
        for ([_]usize{ 300_000, 200, 100_000, 4096, 300_000 }) |len| {
            const in = try inputs.alloc(gpa, .text, 9, len);
            defer gpa.free(in);
            try roundTrip(gpa, &c, in, .{});
        }
    }
}

test "zstd encoder: every output prefix fails cleanly and a retry is deterministic" {
    const gpa = testing.allocator;
    var c = try Compressor.init(gpa, .{ .max_input = 1024 });
    defer c.deinit();
    var out: [1024]u8 = undefined;
    const in = "abcabcabcabcabcabcabcabcabcabcabcabcabcabc";
    const n = try c.compress(in, &out, .{});
    const expected = try gpa.dupe(u8, out[0..n]);
    defer gpa.free(expected);
    for (0..n) |len| try testing.expectError(error.OutputTooSmall, c.compress(in, out[0..len], .{}));
    try testing.expectEqual(n, try c.compress(in, &out, .{}));
    try testing.expectEqualSlices(u8, expected, out[0..n]);
}

fn allocation(gpa: std.mem.Allocator) !void {
    var c = try Compressor.init(gpa, .{ .level = 3, .max_input = 1024 });
    defer c.deinit();
    var out: [128]u8 = undefined;
    _ = try c.compress("abcabcabcabcabcabc", &out, .{});
}

test "zstd encoder: allocation failure and exact memory with no allocations per call" {
    var no_resize: shakedown.alloc.NoResize = .init(testing.allocator);
    try testing.checkAllAllocationFailures(no_resize.allocator(), allocation, .{});
    for ([_]i32{ -131072, -5, 1, 3, 6, 9, 13, 15, 16, 19, 22 }) |level| {
        const options: Compressor.Options = .{ .level = level, .max_input = 1024 };
        var counter: testing.FailingAllocator = .init(testing.allocator, .{});
        var c = try Compressor.init(counter.allocator(), options);
        defer c.deinit();
        try testing.expectEqual(Compressor.memory(options), counter.allocated_bytes);
        const n = counter.allocations;
        var out: [128]u8 = undefined;
        _ = try c.compress("abcabcabcabcabcabc", &out, .{});
        try testing.expectEqual(n, counter.allocations);
    }
}

fn property(_: void, case: *shakedown.Case) !void {
    const level = shakedown.gen.intRange(case.source, i32, -10, 22);
    const len = shakedown.gen.intRange(case.source, usize, 0, 8192);
    const in = try case.gpa.alloc(u8, len);
    const pattern = try shakedown.gen.string(case.source, case.gpa, .{ .kind = .bytes, .min_len = 1, .max_len = 100, .average = 30 });
    for (in, 0..) |*b, i| b.* = pattern[i % pattern.len];
    var c = try Compressor.init(case.gpa, .{ .level = level, .max_input = len });
    defer c.deinit();
    try roundTrip(case.gpa, &c, in, .{ .checksum = shakedown.gen.boolean(case.source), .content_size = shakedown.gen.boolean(case.source) });
}

test "zstd encoder: generated round trips shrink through shakedown" {
    try shakedown.check(testing.allocator, {}, property, .{ .cases = 100, .seed = 0x893402 });
}

test "zstd encoder: fast and lazy levels meet captured size bounds" {
    const gpa = testing.allocator;
    const corpus = @import("corpus.zig");
    const sizes = try corpus.Corpus.parse(@embedFile("zstd-sizes.corpus"));
    const kinds = std.enums.values(inputs.Kind);
    for ([_]i32{ -7, -6, -5, -4, -3, -2, -1, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22 }) |level| {
        var c = try Compressor.init(gpa, .{ .level = level });
        defer c.deinit();
        var totals: [kinds.len][2]u64 = std.mem.zeroes([kinds.len][2]u64);
        var records = sizes.records();
        while (records.next()) |r| {
            const spec = try inputs.Spec.parse(r.fields[0]);
            const in = try inputs.alloc(gpa, spec.kind, spec.seed, spec.len);
            defer gpa.free(in);
            const out = try gpa.alloc(u8, Compressor.bound(in.len));
            defer gpa.free(out);
            var values = std.mem.tokenizeScalar(u8, r.fields[1], ' ');
            const index: usize = @intCast(if (level < 0) level + 7 else level + 6);
            for (0..index) |_| _ = values.next();
            const reference = try std.fmt.parseInt(u64, values.next().?, 10);
            const n = try c.compress(in, out, .{ .checksum = false });
            const total = &totals[@backingInt(spec.kind)];
            total[0] += n;
            total[1] += reference;
            if (n * 100 > reference * 102 + 800) {
                std.debug.print("zstd level {d} {s}: {d} bytes, captured {d}\n", .{ level, r.fields[0], n, reference });
                return error.SizeContract;
            }
        }
        for (totals, kinds) |t, kind| if (t[0] * 1000 > t[1] * 1005) {
            std.debug.print("zstd level {d} {t}: total {d} bytes, captured {d}\n", .{ level, kind, t[0], t[1] });
            return error.SizeContract;
        };
    }
}
