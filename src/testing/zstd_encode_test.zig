//! Whole-buffer zstd encoding: independent decoding, bounded output,
//! continued positions, exact memory and allocation failures.
const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const inputs = @import("gen");
const zstd = @import("../zstd.zig");
const Compressor = zstd.Compressor;

test "zstd encoder: long-distance anchors recover distant random content at every strategy" {
    const gpa = testing.allocator;
    const in = try inputs.alloc(gpa, .noise, 92, 600_000);
    defer gpa.free(in);
    @memcpy(in[400_000..], in[0..200_000]);
    var c = try Compressor.init(gpa, .{ .level = 1, .max_input = in.len, .tuning = .{ .hash_log = 6, .chain_log = 6, .window_log = 20 } });
    defer c.deinit();
    const out = try gpa.alloc(u8, Compressor.bound(in.len));
    defer gpa.free(out);
    const baseline = try c.compress(in, out, .{});
    for (std.enums.values(Compressor.Strategy)) |strategy| {
        var long = try Compressor.init(gpa, .{ .level = 1, .max_input = in.len, .tuning = .{ .strategy = strategy, .long_distance = true, .window_log = 20, .hash_log = 6, .chain_log = 6 } });
        defer long.deinit();
        const n = try long.compress(in, out, .{});
        if (n + 150_000 >= baseline) std.debug.print("long {t}: {d} bytes; baseline {d}\n", .{ strategy, n, baseline });
        try testing.expect(n + 150_000 < baseline);
        try roundTrip(gpa, &long, in, .{});
    }
}

test "zstd encoder: long-distance bucket wrap is deterministic across frames" {
    const gpa = testing.allocator;
    for ([_]inputs.Kind{ .text, .json, .periodic }) |kind| {
        const in = try inputs.alloc(gpa, kind, 2, 600_000);
        defer gpa.free(in);
        var c = try Compressor.init(gpa, .{ .max_input = in.len, .tuning = .{ .long_distance = true } });
        defer c.deinit();
        try roundTrip(gpa, &c, in, .{});
    }
    const mixed = try inputs.alloc(gpa, .noise, 91, 1025 * 1024);
    defer gpa.free(mixed);
    for (1..1025) |packet| @memcpy(mixed[packet * 1024 ..][0..512], mixed[0..512]);
    var c = try Compressor.init(gpa, .{ .max_input = mixed.len, .tuning = .{ .long_distance = true } });
    defer c.deinit();
    try roundTrip(gpa, &c, mixed, .{});
}

test "zstd encoder: attached dictionaries, repeat histories and suppressed IDs" {
    const gpa = testing.allocator;
    const captured = @import("zstd_decode_test.zig");
    var dictionaries = try captured.Dictionaries.load(gpa);
    defer dictionaries.deinit(gpa);
    const plain = try inputs.alloc(gpa, .json, 4, 4096);
    defer gpa.free(plain);
    var raw = zstd.Dictionary.raw(plain);
    const all = try gpa.alloc(*const zstd.Dictionary, dictionaries.count + 1);
    defer gpa.free(all);
    for (dictionaries.values[0..dictionaries.count], all[0..dictionaries.count]) |d, *slot| slot.* = d;
    all[dictionaries.count] = &raw;
    const d = try gpa.create(zstd.Decompressor);
    defer gpa.destroy(d);
    var out: [8192]u8 = undefined;
    var back: [4096]u8 = undefined;
    for (all) |dictionary| for (std.enums.values(Compressor.Strategy)) |strategy| {
        const options: Compressor.Options = .{ .max_input = plain.len, .dictionary = dictionary, .tuning = .{ .strategy = strategy } };
        var counter: testing.FailingAllocator = .init(gpa, .{});
        var c = try Compressor.init(counter.allocator(), options);
        defer c.deinit();
        try testing.expectEqual(Compressor.memory(options), counter.allocated_bytes);
        const allocations = counter.allocations;
        for ([_]bool{ true, false }) |id| {
            const n = try c.compress(plain, &out, .{ .dictionary_id = id });
            const header = (try zstd.frameHeader(out[0..n], .standard)).zstd;
            try testing.expectEqual(if (id) dictionary.id else 0, header.dictionary_id);
            d.* = .init;
            const result = try d.decompress(out[0..n], &back, .{ .dictionaries = &.{dictionary} });
            try testing.expectEqual(plain.len, result.out_len);
            try testing.expectEqualSlices(u8, plain, &back);
            if (dictionary == &raw) try testing.expect(n < 100);
        }
        try testing.expectEqual(allocations, counter.allocations);
    };
}

test "zstd encoder: dictionary matches continue into the frame's prefix" {
    const gpa = testing.allocator;
    const dictionary = zstd.Dictionary.raw("abcdefgh");
    var c = try Compressor.init(gpa, .{ .dictionary = &dictionary, .max_input = 48 });
    defer c.deinit();
    const plain = "abcdefghabcdefghabcdefghabcdefghabcdefghabcdefgh";
    var out: [128]u8 = undefined;
    var back: [48]u8 = undefined;
    const n = try c.compress(plain, &out, .{});
    var d: zstd.Decompressor = .init;
    _ = try d.decompress(out[0..n], &back, .{ .dictionaries = &.{&dictionary} });
    try testing.expectEqualSlices(u8, plain, &back);
    try testing.expect(n < 30);
}

test "zstd encoder: an unrelated dictionary preserves three-byte prefix matches" {
    const gpa = testing.allocator;
    var input: [2000]u8 = undefined;
    // Repeated three-byte markers with a changing fourth byte: matches
    // of length three must survive the dictionary candidate pass.
    for (&input, 0..) |*byte, i| byte.* = if (i % 4 < 3) @intCast(i % 4 + 'A') else @truncate(i / 4);
    const dictionary = zstd.Dictionary.raw("unrelated dictionary content for this input");
    const tuning: Compressor.Tuning = .{ .min_match = 3, .strategy = .btultra2 };
    var plain = try Compressor.init(gpa, .{ .level = 19, .max_input = input.len, .tuning = tuning });
    defer plain.deinit();
    var attached = try Compressor.init(gpa, .{ .level = 19, .dictionary = &dictionary, .max_input = input.len, .tuning = tuning });
    defer attached.deinit();
    var encoded: [3000]u8 = undefined;
    const baseline = try plain.compress(&input, &encoded, .{ .checksum = false });
    const len = try attached.compress(&input, &encoded, .{ .checksum = false });
    try testing.expect(len <= baseline);
    var decoded: [input.len]u8 = undefined;
    const decoder = try gpa.create(zstd.Decompressor);
    defer gpa.destroy(decoder);
    decoder.* = .init;
    _ = try decoder.decompress(encoded[0..len], &decoded, .{ .dictionaries = &.{&dictionary} });
    try testing.expectEqualSlices(u8, &input, &decoded);
}

test "zstd encoder: tuning extremes normalize before sizing or searching" {
    const gpa = testing.allocator;
    const in = try inputs.alloc(gpa, .json, 4, 2048);
    defer gpa.free(in);
    for (std.enums.values(Compressor.Strategy)) |strategy| {
        var c = try Compressor.init(gpa, .{ .max_input = in.len, .tuning = .{ .strategy = strategy, .window_log = 0, .hash_log = 0, .chain_log = 0, .search_log = 0, .min_match = 0 } });
        defer c.deinit();
        try roundTrip(gpa, &c, in, .{});
    }
}

test "zstd encoder: bounds saturate at the address space limit" {
    try testing.expectEqual(std.math.maxInt(usize), Compressor.bound(std.math.maxInt(usize)));
}

test "zstd encoder: unrepresentable table storage fails before allocation on 32-bit targets" {
    if (@sizeOf(usize) != 4) return;
    const tuning: zstd.Tuning = .{ .hash_log = 30, .chain_log = 29 };
    try testing.expectEqual(std.math.maxInt(usize), Compressor.memory(.{ .tuning = tuning }));
    try testing.expectError(error.OutOfMemory, Compressor.init(testing.failing_allocator, .{ .tuning = tuning }));
    try testing.expectEqual(std.math.maxInt(usize), zstd.Compress.memory(.{ .tuning = tuning }));
    try testing.expectError(error.OutOfMemory, zstd.Compress.init(testing.failing_allocator, .{ .tuning = tuning }));
}

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
