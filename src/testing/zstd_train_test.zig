//! Trained dictionaries: held-out size, interoperability of their tables,
//! deterministic search, finalization and temporary allocation failures.
const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const zstd = @import("../zstd.zig");
const gen = @import("gen");

fn samples(gpa: std.mem.Allocator, count: usize) ![][]const u8 {
    const values = try gpa.alloc([]const u8, count);
    errdefer gpa.free(values);
    var done: usize = 0;
    errdefer for (values[0..done]) |value| gpa.free(value);
    for (values, 0..) |*value, seed| {
        value.* = try gen.alloc(gpa, .json, @intCast(seed), 256 + seed % 300);
        done += 1;
    }
    return values;
}

fn freeSamples(gpa: std.mem.Allocator, values: [][]const u8) void {
    for (values) |value| gpa.free(value);
    gpa.free(values);
}

fn roundTrip(gpa: std.mem.Allocator, dictionary: *const zstd.Dictionary, values: []const []const u8) !usize {
    var c = try zstd.Compressor.init(gpa, .{ .max_input = 1024, .dictionary = dictionary });
    defer c.deinit();
    var d: zstd.Decompressor = .init;
    var out: [2048]u8 = undefined;
    var back: [1024]u8 = undefined;
    var total: usize = 0;
    for (values) |value| {
        const n = try c.compress(value, &out, .{});
        const result = try d.decompress(out[0..n], back[0..value.len], .{ .dictionaries = &.{dictionary} });
        try testing.expectEqual(value.len, result.out_len);
        try testing.expectEqualSlices(u8, value, back[0..value.len]);
        total += n;
    }
    return total;
}

test "zstd training: both coverage algorithms search deterministically and improve held-out samples" {
    const gpa = testing.allocator;
    const values = try samples(gpa, 24);
    defer freeSamples(gpa, values);
    var out: [2048]u8 = undefined;
    var again: [2048]u8 = undefined;
    const d = try gpa.create(zstd.Dictionary);
    defer gpa.destroy(d);
    var plain = try zstd.Compressor.init(gpa, .{ .max_input = 1024 });
    defer plain.deinit();
    var encoded: [2048]u8 = undefined;
    var baseline: usize = 0;
    for (values[20..]) |value| baseline += try plain.compress(value, &encoded, .{});
    for ([_]zstd.train.Options{ .{ .steps = 3, .id = 1234 }, .{ .algorithm = .cover, .steps = 3, .id = 1234 } }) |options| {
        const n = try zstd.train.train(gpa, values[0..20], &out, options);
        const m = try zstd.train.train(gpa, values[0..20], &again, options);
        try testing.expectEqual(n, m);
        try testing.expectEqualSlices(u8, out[0..n], again[0..m]);
        d.* = try zstd.Dictionary.parse(out[0..n]);
        try testing.expectEqual(@as(u32, 1234), d.id);
        try testing.expect(try roundTrip(gpa, d, values[20..]) < baseline);
    }
}

test "zstd training: finalization supports overlapping content and defaults to a stable nonzero ID" {
    const gpa = testing.allocator;
    const values = try samples(gpa, 8);
    defer freeSamples(gpa, values);
    var out: [1024]u8 = undefined;
    @memcpy(out[0..values[0].len], values[0]);
    const n = try zstd.train.finalize(gpa, out[0..values[0].len], values, &out, .{});
    const d = try gpa.create(zstd.Dictionary);
    defer gpa.destroy(d);
    d.* = try zstd.Dictionary.parse(out[0..n]);
    try testing.expect(d.id != 0);
    try testing.expectEqualSlices(u8, values[0], d.content);
    _ = try roundTrip(gpa, d, values);
}

fn allocation(gpa: std.mem.Allocator) !void {
    const values: []const []const u8 = &.{ "dictionary samples repeat dictionary samples", "dictionary samples vary dictionary samples" };
    var out: [1024]u8 = undefined;
    _ = try zstd.train.train(gpa, values, &out, .{ .algorithm = .cover, .k = 16, .d = 6 });
}

test "zstd training: every temporary allocation failure is cleaned up without resize" {
    var allocator: shakedown.alloc.NoResize = .init(testing.allocator);
    try testing.checkAllAllocationFailures(allocator.allocator(), allocation, .{});
}

test "zstd training: impossible options and insufficient samples fail before allocation" {
    var out: [1024]u8 = undefined;
    try testing.expectError(error.NotEnoughSamples, zstd.train.train(testing.failing_allocator, &.{}, &out, .{}));
    try testing.expectError(error.InvalidParameters, zstd.train.train(testing.failing_allocator, &.{"enough sample bytes"}, &out, .{ .d = 3 }));
    try testing.expectError(error.InvalidParameters, zstd.train.train(testing.failing_allocator, &.{"enough sample bytes"}, &out, .{ .id = 0 }));
}

test "zstd training: finalization learns repeat offsets from sample matches" {
    const values: []const []const u8 = &.{
        "abcdefghijklmnopq!abcdefghijklmnopq?",
        "abcdefghijklmnopq@abcdefghijklmnopq#",
        "abcdefghijklmnopq$abcdefghijklmnopq%",
        "abcdefghijklmnopq^abcdefghijklmnopq&",
    };
    var out: [1024]u8 = undefined;
    const n = try zstd.train.finalize(testing.allocator, "abcdefghijklmnopq", values, &out, .{});
    const dictionary = try testing.allocator.create(zstd.Dictionary);
    defer testing.allocator.destroy(dictionary);
    dictionary.* = try .parse(out[0..n]);
    try testing.expectEqual(@as(u32, 17), dictionary.entropy.reps[0]);
    _ = try roundTrip(testing.allocator, dictionary, values);
}

test "zstd training: 256-byte dictionary buffers support training and finalization" {
    const values = try samples(testing.allocator, 24);
    defer freeSamples(testing.allocator, values);
    var out: [256]u8 = undefined;
    const dictionary = try testing.allocator.create(zstd.Dictionary);
    defer testing.allocator.destroy(dictionary);
    for ([_]zstd.train.Options{ .{ .k = 64, .d = 6 }, .{ .algorithm = .cover, .k = 64, .d = 6 } }) |options| {
        const n = try zstd.train.train(testing.allocator, values[0..20], &out, options);
        dictionary.* = try .parse(out[0..n]);
        _ = try roundTrip(testing.allocator, dictionary, values[20..]);
    }
    const n = try zstd.train.finalize(testing.allocator, values[0], values[0..20], &out, .{});
    dictionary.* = try .parse(out[0..n]);
    try testing.expectEqualSlices(u8, values[0][values[0].len - dictionary.content.len ..], dictionary.content);
    _ = try roundTrip(testing.allocator, dictionary, values[20..]);
}
