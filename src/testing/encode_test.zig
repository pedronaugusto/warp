//! The compressor: every level, strategy and container round-trips through
//! warp's decoder and std's, the same input always gives the same bytes,
//! and the output is no larger than zlib 1.3.1's at levels 1-9 and
//! zlib level 9 at 10-12.

const std = @import("std");
const testing = std.testing;
const gen = @import("gen");
const corpus = @import("corpus.zig");
const Compressor = @import("../Compressor.zig");
const Decompressor = @import("../Decompressor.zig");
const container = @import("../container.zig");

const strategies = std.enums.values(Compressor.Strategy);
const containers = std.enums.values(container.Container);

fn roundTrip(gpa: std.mem.Allocator, c: *Compressor, d: *Decompressor, in: []const u8, frame: Compressor.Frame) !usize {
    const out = try gpa.alloc(u8, Compressor.bound(in.len, frame));
    defer gpa.free(out);
    const n = try c.compress(in, out, frame);
    const back = try gpa.alloc(u8, in.len);
    defer gpa.free(back);
    const accept: container.Accept = switch (frame.container) {
        .raw => .raw,
        .zlib => .zlib,
        .gzip => .gzip,
    };
    const r = try d.inflate(out[0..n], back, .{ .accept = accept, .dictionary = frame.dictionary });
    try testing.expectEqual(n, r.in_len);
    try testing.expectEqual(in.len, r.out_len);
    try testing.expectEqualSlices(u8, in, back);
    // The same input again: the same bytes.
    const again = try gpa.alloc(u8, n);
    defer gpa.free(again);
    try testing.expectEqual(n, try c.compress(in, again, frame));
    try testing.expectEqualSlices(u8, out[0..n], again);
    return n;
}

test "every level, strategy and container round-trips every kind of input" {
    const gpa = testing.allocator;
    const d = try gpa.create(Decompressor);
    defer gpa.destroy(d);
    d.* = .init;
    var inputs: std.ArrayList([]u8) = .empty;
    defer {
        for (inputs.items) |in| gpa.free(in);
        inputs.deinit(gpa);
    }
    for (std.enums.values(gen.Kind)) |kind| for ([_]usize{ 0, 1, 2, 3, 4, 5, 37, 300, 4096, 70_000 }) |n| {
        try inputs.append(gpa, try gen.alloc(gpa, kind, 11, n));
    };
    for (0..13) |level| for (strategies) |strategy| {
        var c = try Compressor.init(gpa, .{ .level = @intCast(level), .strategy = strategy });
        defer c.deinit();
        for (inputs.items, 0..) |in, i| {
            const frame: Compressor.Frame = .{ .container = containers[i % 3] };
            _ = roundTrip(gpa, &c, d, in, frame) catch |err| {
                std.debug.print("level {d} {t} {t} input {d} ({d} bytes)\n", .{ level, strategy, frame.container, i, in.len });
                return err;
            };
        }
    };
}

test "inputs past the window and past a block round-trip, and long runs" {
    const gpa = testing.allocator;
    const d = try gpa.create(Decompressor);
    defer gpa.destroy(d);
    d.* = .init;
    const big = try gen.alloc(gpa, .text, 3, 700_000);
    defer gpa.free(big);
    const zeros = try gpa.alloc(u8, 400_000);
    defer gpa.free(zeros);
    @memset(zeros, 0);
    for ([_]u4{ 1, 2, 4, 6, 9, 10, 11, 12 }) |level| {
        var c = try Compressor.init(gpa, .{ .level = level });
        defer c.deinit();
        _ = try roundTrip(gpa, &c, d, big, .{});
        _ = try roundTrip(gpa, &c, d, zeros, .{ .container = .gzip });
    }
}

test "a dictionary: a zlib stream names it and refers into it, a raw one refers into it" {
    const gpa = testing.allocator;
    const d = try gpa.create(Decompressor);
    defer gpa.destroy(d);
    d.* = .init;
    const dictionary = try gen.alloc(gpa, .json, 5, 40_000);
    defer gpa.free(dictionary);
    const message = try gen.alloc(gpa, .json, 6, 3000);
    defer gpa.free(message);
    for ([_]u4{ 1, 6, 9, 10, 11, 12 }) |level| {
        var c = try Compressor.init(gpa, .{ .level = level });
        defer c.deinit();
        const plain = try roundTrip(gpa, &c, d, message, .{});
        for ([_]container.Container{ .zlib, .raw }) |kind| {
            const primed = try roundTrip(gpa, &c, d, message, .{ .container = kind, .dictionary = dictionary });
            // The dictionary helps: the same kind of text compresses better.
            try testing.expect(primed < plain);
        }
        // Tiny inputs with a dictionary.
        for ([_][]const u8{ "", "a", "ab", "abc", "abcd" }) |tiny| _ = try roundTrip(gpa, &c, d, tiny, .{ .dictionary = dictionary });
    }
}

test "the empty input is zlib's empty stream" {
    var c = try Compressor.init(testing.allocator, .{});
    defer c.deinit();
    var out: [32]u8 = undefined;
    const n = try c.compress("", &out, .{});
    try testing.expectEqualSlices(u8, &.{ 0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01 }, out[0..n]);
}

test "an output shorter than the stream is OutputTooSmall" {
    var c = try Compressor.init(testing.allocator, .{});
    defer c.deinit();
    const in = "hello hello hello hello, world";
    var out: [64]u8 = undefined;
    const n = try c.compress(in, &out, .{});
    for (0..n) |short| try testing.expectError(error.OutputTooSmall, c.compress(in, out[0..short], .{}));
}

test "std decodes what warp writes, at every level and strategy" {
    const gpa = testing.allocator;
    const in = try gen.alloc(gpa, .text, 21, 100_000);
    defer gpa.free(in);
    const out = try gpa.alloc(u8, Compressor.bound(in.len, .{ .container = .raw }));
    defer gpa.free(out);
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    const back = try gpa.alloc(u8, in.len);
    defer gpa.free(back);
    for (0..13) |level| for (strategies) |strategy| {
        var c = try Compressor.init(gpa, .{ .level = @intCast(level), .strategy = strategy });
        defer c.deinit();
        const n = try c.compress(in, out, .{ .container = .raw });
        var r: std.Io.Reader = .fixed(out[0..n]);
        var sd: std.compress.flate.Decompress = .init(&r, .raw, window);
        try sd.reader.readSliceAll(back);
        try testing.expectEqualSlices(u8, in, back);
    };
}

test "memory is what init takes, and a compression allocates nothing" {
    const gpa = testing.allocator;
    for (0..13) |level| for (strategies) |strategy| for ([_]?usize{ null, 37, 4096, 1 << 20 }) |max_input| {
        const options: Compressor.Options = .{ .level = @intCast(level), .strategy = strategy, .max_input = max_input };
        var counting: std.testing.FailingAllocator = .init(gpa, .{});
        var c = try Compressor.init(counting.allocator(), options);
        defer c.deinit();
        try testing.expectEqual(Compressor.memory(options), counting.allocated_bytes);
        const allocations = counting.allocations;
        var out: [1024]u8 = undefined;
        _ = try c.compress("abcabcabcabcabcabc", &out, .{});
        try testing.expectEqual(allocations, counting.allocations);
    };
}

/// Level `level`'s output, summed per kind of input over the size corpus,
/// is no larger than the captured size reference at that level.
fn expectContract(level: u4) !void {
    const gpa = testing.allocator;
    const c_ = try corpus.Corpus.parse(corpus.sizes);
    const kinds = std.enums.values(gen.Kind);
    var totals: [kinds.len][2]u64 = std.mem.zeroes([kinds.len][2]u64);
    var c = try Compressor.init(gpa, .{ .level = level });
    defer c.deinit();
    var it = c_.records();
    var out: []u8 = &.{};
    defer gpa.free(out);
    while (it.next()) |r| {
        const spec = try gen.Spec.parse(r.fields[0]);
        const in = try gen.alloc(gpa, spec.kind, spec.seed, spec.len);
        defer gpa.free(in);
        if (out.len < Compressor.bound(in.len, .{})) {
            gpa.free(out);
            out = try gpa.alloc(u8, Compressor.bound(in.len, .{}));
        }
        var sizes = std.mem.tokenizeScalar(u8, r.fields[1], ' ');
        for (1..@min(level, 9)) |_| _ = sizes.next();
        const zlib_size = try std.fmt.parseInt(u64, sizes.next().?, 10);
        const total = &totals[@backingInt(spec.kind)];
        const written = try c.compress(in, out, .{});
        total[0] += written;
        total[1] += zlib_size;
    }
    var failed = false;
    for (kinds, totals) |kind, t| if (t[0] > t[1]) {
        std.debug.print("level {d} {t}: warp {d}, {s} {d} ({d:.2}%)\n", .{ level, kind, t[0], "zlib", t[1], 100.0 * (@as(f64, @floatFromInt(t[0])) / @as(f64, @floatFromInt(t[1])) - 1) });
        failed = true;
    };
    try testing.expect(!failed);
}

test "level contract: level 1 is no larger than zlib 1.3.1's, per kind of input" {
    try expectContract(1);
}

test "level contract: level 2 is no larger than zlib 1.3.1's, per kind of input" {
    try expectContract(2);
}

test "level contract: level 3 is no larger than zlib 1.3.1's, per kind of input" {
    try expectContract(3);
}

test "level contract: level 4 is no larger than zlib 1.3.1's, per kind of input" {
    try expectContract(4);
}

test "level contract: level 5 is no larger than zlib 1.3.1's, per kind of input" {
    try expectContract(5);
}

test "level contract: level 6 is no larger than zlib 1.3.1's, per kind of input" {
    try expectContract(6);
}

test "level contract: level 7 is no larger than zlib 1.3.1's, per kind of input" {
    try expectContract(7);
}

test "level contract: level 8 is no larger than zlib 1.3.1's, per kind of input" {
    try expectContract(8);
}

test "level contract: level 9 is no larger than zlib 1.3.1's, per kind of input" {
    try expectContract(9);
}

test "level contract: level 10 is no larger than zlib level 9, per kind of input" {
    try expectContract(10);
}

test "level contract: level 11 is no larger than zlib level 9, per kind of input" {
    try expectContract(11);
}

test "level contract: level 12 is no larger than zlib level 9, per kind of input" {
    try expectContract(12);
}

test "extra optimal passes preserve the best single-block size and round-trip" {
    const gpa = testing.allocator;
    var normal = try Compressor.init(gpa, .{ .level = 12, .max_input = 20000 });
    defer normal.deinit();
    var extra = try Compressor.init(gpa, .{ .level = 12, .max_input = 20000, .passes = 40 });
    defer extra.deinit();
    var out: [24000]u8 = undefined;
    var back: [20000]u8 = undefined;
    var d: Decompressor = .init;
    for ([_]gen.Kind{ .text, .png, .json, .noise }) |kind| {
        const in = try gen.alloc(gpa, kind, 33, 20000);
        defer gpa.free(in);
        const n = try normal.compress(in, &out, .{});
        const m = try extra.compress(in, &out, .{});
        try testing.expect(m <= n);
        const r = try d.inflate(out[0..m], &back, .{});
        try testing.expectEqualSlices(u8, in, back[0..r.out_len]);
    }
}
