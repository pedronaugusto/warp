//! Seek table validation, independent frames and random-access ranges.
const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const zstd = @import("../zstd.zig");
const gen = @import("gen");

fn encode(gpa: std.mem.Allocator, in: []const u8, checksum: bool, chunk: usize) ![]u8 {
    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    var writer = try zstd.seekable.Writer.init(gpa, &sink.writer, .{ .frame_len = 1024, .max_frames = 24, .checksum = checksum });
    defer writer.deinit();
    var at: usize = 0;
    while (at < in.len) {
        const n = @min(chunk, in.len - at);
        try writer.interface.writeAll(in[at..][0..n]);
        at += n;
    }
    try writer.finish();
    return gpa.dupe(u8, sink.written());
}

test "zstd seekable: frame indexing, arbitrary ranges and chunking invariance" {
    const gpa = testing.allocator;
    const in = try gen.alloc(gpa, .json, 17, 20_000);
    defer gpa.free(in);
    const reader = try gpa.create(zstd.seekable.Reader);
    defer gpa.destroy(reader);
    var window: [1024]u8 = undefined;
    var out: [20_000]u8 = undefined;
    for ([_]bool{ true, false }) |checksum| {
        const encoded = try encode(gpa, in, checksum, 307);
        defer gpa.free(encoded);
        const again = try encode(gpa, in, checksum, 1);
        defer gpa.free(again);
        try testing.expectEqualSlices(u8, encoded, again);
        var index = try zstd.seekable.Index.init(gpa, encoded);
        defer index.deinit();
        try testing.expectEqual(@as(u64, in.len), index.content_size);
        try testing.expectEqual(@as(usize, 20), index.entries.len);
        reader.* = .init(&index, &window, .{});
        try testing.expectEqual(in.len, try reader.read(0, &out));
        try testing.expectEqualSlices(u8, in, &out);
        for ([_]usize{ 0, 1, 1023, 1024, 1501, 19_999, 20_000 }) |offset| {
            const n = try reader.read(offset, out[0..17]);
            try testing.expectEqual(@min(17, in.len - offset), n);
            try testing.expectEqualSlices(u8, in[offset..][0..n], out[0..n]);
        }
        try testing.expectError(error.FrameOutOfRange, reader.readFrame(20, &out));
        var d: zstd.Decompressor = .init;
        const all = try d.decompress(encoded, &out, .{});
        try testing.expectEqual(encoded.len, all.in_len);
        try testing.expectEqualSlices(u8, in, &out);
        // Ignore the footer's two unused bits; refuse reserved bits.
        encoded[encoded.len - 5] |= 3;
        var valid = try zstd.seekable.Index.init(gpa, encoded);
        valid.deinit();
        encoded[encoded.len - 5] |= 4;
        try testing.expectError(error.InvalidSeekTable, zstd.seekable.Index.init(gpa, encoded));
    }
}

test "zstd seekable: every missing footer byte, altered sizes and checksum failures" {
    const gpa = testing.allocator;
    const encoded = try encode(gpa, "frame with its checksum in the seek table", true, 1);
    defer gpa.free(encoded);
    for (0..encoded.len) |len| {
        if (zstd.seekable.Index.init(gpa, encoded[0..len])) |value| {
            var index = value;
            index.deinit();
            return error.AcceptedTruncation;
        } else |_| {}
    }
    const reader = try gpa.create(zstd.seekable.Reader);
    defer gpa.destroy(reader);
    var window: [128]u8 = undefined;
    const table_start = encoded.len - 29;
    encoded[table_start + 16] ^= 1;
    var index = try zstd.seekable.Index.init(gpa, encoded);
    defer index.deinit();
    reader.* = .init(&index, &window, .{});
    try testing.expectError(error.ChecksumMismatch, reader.read(0, &window));
    encoded[table_start + 8] ^= 1;
    try testing.expectError(error.InvalidSeekTable, zstd.seekable.Index.init(gpa, encoded));
}

fn allocation(gpa: std.mem.Allocator) !void {
    var output: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&output);
    var writer = try zstd.seekable.Writer.init(gpa, &sink, .{ .frame_len = 64, .max_frames = 2 });
    defer writer.deinit();
    try writer.interface.writeAll("dictionary-free seekable frames");
    try writer.finish();
    var index = try zstd.seekable.Index.init(gpa, sink.buffered());
    defer index.deinit();
}

test "zstd seekable: exact allocation, failures and caller entries" {
    var allocator: shakedown.alloc.NoResize = .init(testing.allocator);
    try testing.checkAllAllocationFailures(allocator.allocator(), allocation, .{});
    const options: zstd.seekable.Writer.Options = .{ .frame_len = 64, .max_frames = 2 };
    var counter: testing.FailingAllocator = .init(testing.allocator, .{});
    var output: [256]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&output);
    var writer = try zstd.seekable.Writer.init(counter.allocator(), &sink, options);
    defer writer.deinit();
    try testing.expectEqual(zstd.seekable.Writer.memory(options), counter.allocated_bytes);
    const count = counter.allocations;
    try writer.interface.writeAll("hello");
    try writer.finish();
    try testing.expectEqual(count, counter.allocations);
    var entries: [1]zstd.seekable.Entry = undefined;
    var index = try zstd.seekable.Index.initBuffer(&entries, sink.buffered());
    defer index.deinit();
    try testing.expectEqual(@sizeOf(zstd.seekable.Entry), try zstd.seekable.Index.memory(sink.buffered()));
    try testing.expectEqual(@as(u64, 5), index.content_size);
}

test "zstd seekable: output and frame-capacity failures are sticky" {
    const gpa = testing.allocator;
    var output: [2]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&output);
    var writer = try zstd.seekable.Writer.init(gpa, &sink, .{ .frame_len = 64, .max_frames = 1 });
    defer writer.deinit();
    try writer.interface.writeAll("hello");
    try testing.expectError(error.WriteFailed, writer.finish());
    try testing.expectEqual(error.OutputFailed, writer.err().?);
    try testing.expectError(error.WriteFailed, writer.finish());
    var large: [256]u8 = undefined;
    var enough: std.Io.Writer = .fixed(&large);
    var capped = try zstd.seekable.Writer.init(gpa, &enough, .{ .frame_len = 1, .max_frames = 1 });
    defer capped.deinit();
    try testing.expectError(error.WriteFailed, capped.interface.writeAll("three"));
    try testing.expectEqual(error.TooManyFrames, capped.err().?);
}

fn property(_: void, case: *shakedown.Case) !void {
    const in = try shakedown.gen.string(case.source, case.gpa, .{ .kind = .bytes, .min_len = 0, .max_len = 8192, .average = 2048 });
    const encoded = try encode(case.gpa, in, shakedown.gen.boolean(case.source), shakedown.gen.intRange(case.source, usize, 1, 128));
    var index = try zstd.seekable.Index.init(case.gpa, encoded);
    defer index.deinit();
    const reader = try case.gpa.create(zstd.seekable.Reader);
    var window: [1024]u8 = undefined;
    reader.* = .init(&index, &window, .{});
    var out: [2048]u8 = undefined;
    for (0..20) |_| {
        const offset = shakedown.gen.intRange(case.source, usize, 0, in.len + 32);
        const capacity = shakedown.gen.intRange(case.source, usize, 0, out.len);
        const n = try reader.read(offset, out[0..capacity]);
        if (offset >= in.len) {
            try testing.expectEqual(@as(usize, 0), n);
        } else {
            try testing.expectEqual(@min(capacity, in.len - offset), n);
            try testing.expectEqualSlices(u8, in[offset..][0..n], out[0..n]);
        }
    }
}

test "zstd seekable: seeded generated ranges agree with uncompressed input" {
    try shakedown.check(testing.allocator, {}, property, .{ .cases = 100, .seed = 0x687342 });
}
