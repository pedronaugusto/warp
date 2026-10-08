//! Ordered chunk streams, their concurrency invariance and allocation bounds.
const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const gen = @import("gen");
const parallel = @import("../parallel.zig");
const Decompressor = @import("../Decompressor.zig");
const container = @import("../container.zig");

fn encode(gpa: std.mem.Allocator, io: std.Io, in: []const u8, options: parallel.Options) ![]u8 {
    var p = try parallel.Compressor.init(gpa, options);
    defer p.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try p.compress(io, in, &out.writer);
    return out.toOwnedSlice();
}

test "parallel compression round-trips with identical bytes at any concurrency" {
    const gpa = testing.allocator;
    const in = try gen.alloc(gpa, .text, 19, 190000);
    defer gpa.free(in);
    const decoded = try gpa.alloc(u8, in.len);
    defer gpa.free(decoded);
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    for ([_]u4{ 0, 1, 6, 10, 12 }) |level| for (std.enums.values(container.Container)) |kind| for ([_]bool{ false, true }) |independent| {
        var options: parallel.Options = .{ .level = level, .container = kind, .chunk_len = 16384, .concurrency = 1, .independent = independent };
        const serial = try encode(gpa, testing.io, in, options);
        defer gpa.free(serial);
        options.concurrency = 4;
        const many = try encode(gpa, threaded.io(), in, options);
        defer gpa.free(many);
        try testing.expectEqualSlices(u8, serial, many);
        var d: Decompressor = .init;
        const accept: container.Accept = switch (kind) {
            .raw => .raw,
            .zlib => .zlib,
            .gzip => .gzip,
        };
        const r = try d.inflate(many, decoded, .{ .accept = accept });
        try testing.expectEqualSlices(u8, in, decoded[0..r.out_len]);
        try testing.expectEqual(many.len, r.in_len);
    };
}

test "parallel compression reuses its exact allocation, including empty input" {
    var counting: shakedown.alloc.Counting = .init(testing.allocator);
    const options: parallel.Options = .{ .chunk_len = 100, .concurrency = 3 };
    var p = try parallel.Compressor.init(counting.allocator(), options);
    defer p.deinit();
    try testing.expectEqual(parallel.Compressor.memory(options), counting.live_bytes);
    const before = counting.allocations;
    var bytes: [1000]u8 = undefined;
    var writer: std.Io.Writer = .fixed(&bytes);
    try p.compress(testing.io, "", &writer);
    try p.compress(testing.io, "abcabc", &writer);
    try testing.expectEqual(before, counting.allocations);
    var no_resize: shakedown.alloc.NoResize = .init(testing.allocator);
    try testing.checkAllAllocationFailures(no_resize.allocator(), struct {
        fn once(gpa: std.mem.Allocator) !void {
            var c = try parallel.Compressor.init(gpa, options);
            c.deinit();
        }
    }.once, .{});
}

test "parallel compressor caller memory survives a failed sink and reuse" {
    var threaded: std.Io.Threaded = .init(testing.allocator, .{});
    defer threaded.deinit();
    const input = try gen.alloc(testing.allocator, .noise, 47, 100000);
    defer testing.allocator.free(input);
    const options: parallel.Options = .{ .chunk_len = 8192, .concurrency = 2 };
    const memory = try testing.allocator.alignedAlloc(u8, .@"64", parallel.Compressor.memory(options));
    defer testing.allocator.free(memory);
    var p = parallel.Compressor.initBuffer(memory, options);
    defer p.deinit();
    var tiny: [1000]u8 = undefined;
    var failed: std.Io.Writer = .fixed(&tiny);
    try testing.expectError(error.WriteFailed, p.compress(threaded.io(), input, &failed));
    var storage: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&storage);
    try p.compress(threaded.io(), "hello", &sink);
    var back: [5]u8 = undefined;
    var d: Decompressor = .init;
    _ = try d.inflate(sink.buffered(), &back, .{ .accept = .gzip });
    try testing.expectEqualStrings("hello", &back);
}
