//! Costed superblocks preserve matches, entropy and repeat histories.
const std = @import("std");
const testing = std.testing;
const gen = @import("gen");
const zstd = @import("../zstd.zig");
const shakedown = @import("shakedown");

fn encode(input: []const u8, options: zstd.Compress.Options, chunk: usize) ![]u8 {
    const gpa = testing.allocator;
    var s = try zstd.Compress.init(gpa, options);
    defer s.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var encoded: zstd.Compress.Writer = .init(&s, &out.writer, &.{});
    var at: usize = 0;
    while (at < input.len) {
        const n = @min(chunk, input.len - at);
        try encoded.interface.writeAll(input[at..][0..n]);
        at += n;
    }
    try encoded.finish();
    return gpa.dupe(u8, out.written());
}

fn blockSizes(input: []const u8, target: usize) !void {
    const header = (try zstd.frameHeader(input, .standard)).zstd;
    var at: usize = header.header_len;
    var count: usize = 0;
    while (true) {
        const block = std.mem.readInt(u24, input[at..][0..3], .little);
        const size = block >> 3;
        const kind = (block >> 1) & 3;
        if (kind == 2) try testing.expect(size + 3 <= 2 * target);
        if (kind == 0) try testing.expect(size + 3 <= target);
        at += 3 + if (kind == 1) @as(usize, 1) else size;
        count += 1;
        if (block & 1 != 0) break;
    }
    try testing.expect(count > 1);
}

test "zstd superblocks: all strategies, targets and generated kinds" {
    const gpa = testing.allocator;
    const window = try gpa.alloc(u8, std.compress.zstd.default_window_len + std.compress.zstd.block_size_max);
    defer gpa.free(window);
    const decoded = try gpa.alloc(u8, 180_001);
    defer gpa.free(decoded);
    var d: zstd.Decompressor = .init;
    for ([_]gen.Kind{ .noise, .text, .json }) |kind| {
        const in = try gen.alloc(gpa, kind, 4, decoded.len);
        defer gpa.free(in);
        inline for (std.meta.tags(zstd.Strategy)) |strategy| {
            for ([_]u32{ 1340, 4096 }) |target| {
                const options: zstd.Compress.Options = .{ .pledged_size = in.len, .target_block_size = target, .tuning = .{ .strategy = strategy, .window_log = 17 } };
                const compressed = try encode(in, options, 2259);
                defer gpa.free(compressed);
                try blockSizes(compressed, target);
                _ = try d.decompress(compressed, decoded, .{});
                try testing.expectEqualSlices(u8, in, decoded);
                var reader: std.Io.Reader = .fixed(compressed);
                var oracle: std.compress.zstd.Decompress = .init(&reader, window, .{});
                try oracle.reader.readSliceAll(decoded);
                try testing.expectEqualSlices(u8, in, decoded);
            }
        }
    }
}

test "zstd superblocks: long literal cuts, dictionaries and chunking invariance" {
    const gpa = testing.allocator;
    const in = try gen.alloc(gpa, .noise, 43, 200_000);
    defer gpa.free(in);
    @memcpy(in[100_000..][0..50_000], in[0..50_000]);
    const dict = zstd.Dictionary.raw(in[0..1024]);
    const options: zstd.Compress.Options = .{ .pledged_size = in.len, .target_block_size = 1340, .dictionary = &dict, .tuning = .{ .strategy = .btopt, .window_log = 18 } };
    const one = try encode(in, options, 1);
    defer gpa.free(one);
    const many = try encode(in, options, 16_000);
    defer gpa.free(many);
    try testing.expectEqualSlices(u8, one, many);
    const decoded = try gpa.alloc(u8, in.len);
    defer gpa.free(decoded);
    var d: zstd.Decompressor = .init;
    _ = try d.decompress(one, decoded, .{ .dictionaries = &.{&dict} });
    try testing.expectEqualSlices(u8, in, decoded);
}

fn property(_: void, case: *shakedown.Case) anyerror!void {
    const input = try shakedown.gen.string(case.source, case.gpa, .{ .kind = .bytes, .min_len = 0, .max_len = 300_000, .average = 100_000 });
    const options: zstd.Compress.Options = .{ .pledged_size = input.len, .target_block_size = @intCast(shakedown.gen.intRange(case.source, usize, 0, 20_000)), .level = @as(i32, @intCast(shakedown.gen.intRange(case.source, usize, 0, 29))) - 7, .tuning = .{ .window_log = @intCast(10 + shakedown.gen.intRange(case.source, usize, 0, 10)) } };
    const compressed = try encode(input, options, 1 + shakedown.gen.intRange(case.source, usize, 0, 8000));
    defer testing.allocator.free(compressed);
    const decoded = try case.gpa.alloc(u8, input.len);
    var d: zstd.Decompressor = .init;
    _ = try d.decompress(compressed, decoded, .{});
    try testing.expectEqualSlices(u8, input, decoded);
}

test "zstd superblocks: generated inputs, levels, windows and target edges" {
    try shakedown.check(testing.allocator, {}, property, .{ .cases = 30, .seed = 0x964223 });
}
