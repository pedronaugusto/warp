//! Caller memory: every `initBuffer` refuses a buffer one byte shorter than
//! its `memory`, and lays itself out in exactly `memory` bytes.

const std = @import("std");
const testing = std.testing;
const aegis = @import("aegis");
const Bgzf = @import("../Bgzf.zig");
const Compressor = @import("../Compressor.zig");
const Deflate = @import("../stream/Deflate.zig");
const parallel = @import("../parallel.zig");
const Speculative = @import("../parallel/Speculative.zig");
const gdeflate = @import("../gdeflate.zig");
const lz4 = @import("../lz4.zig");
const snappy = @import("../snappy.zig");
const zstd = @import("../zstd.zig");
const lzma = @import("../lzma.zig");
const bzip2 = @import("../bzip2.zig");

/// `T.initBuffer(buffer, args...)` refused one byte short of `memory`, and
/// made in exactly `memory` bytes.
fn exact(comptime T: type, memory: usize, args: anytype) !void {
    const buffer = try testing.allocator.alignedAlloc(u8, .@"64", memory);
    defer testing.allocator.free(buffer);
    try testing.expectError(error.BufferTooSmall, @call(.auto, T.initBuffer, .{buffer[0 .. memory - 1]} ++ args));
    var value = try @call(.auto, T.initBuffer, .{buffer} ++ args);
    if (@hasDecl(T, "deinit")) value.deinit();
}

test "deflate: Compressor, Deflate, Bgzf and gdeflate in exactly their memory" {
    for ([_]u4{ 1, 4, 6, 9, 10, 12 }) |level| {
        const o: Compressor.Options = .{ .level = level, .max_input = .literal("64KiB") };
        try exact(Compressor, Compressor.memory(o), .{o});
        const g: gdeflate.Compressor.Options = .{ .level = level };
        try exact(gdeflate.Compressor, gdeflate.Compressor.memory(g), .{g});
        const b: Bgzf.Options = .{ .level = level };
        try exact(Bgzf, Bgzf.memory(b), .{b});
    }
    for ([_]Deflate.Options{ .{}, .{ .window_bits = 9 }, .{ .level = 12, .max_level = 12 }, .{ .window_bits = 10, .max_level = 12 } }) |o| {
        try exact(Deflate, Deflate.memory(o), .{o});
    }
}

test "parallel deflate: compressor, decompressor and speculative markers in exactly their memory" {
    for ([_]u4{ 1, 6, 12 }) |level| {
        const o: parallel.Options = .{ .level = level, .concurrency = 2, .chunk_len = .literal("64KiB") };
        try exact(parallel.Compressor, parallel.Compressor.memory(o), .{o});
    }
    const spec: Speculative.Options = .{ .chunk_len = .literal("64KiB"), .search_len = .literal("16KiB"), .max_blocks = 64 };
    for ([_]parallel.Decompressor.Options{ .{ .concurrency = 2 }, .{ .concurrency = 3, .speculative = spec } }) |o| {
        try exact(parallel.Decompressor, parallel.Decompressor.memory(o), .{o});
    }
    try exact(Speculative, Speculative.memory(3, spec), .{ @as(u16, 3), spec });
}

test "lz4: Compressor and Compress in exactly their memory" {
    const dictionary = "a dictionary of a few bytes, a dictionary";
    for ([_]lz4.Compressor.Options{ .{ .level = 1 }, .{ .level = 2 }, .{ .level = 9 }, .{ .level = 12 }, .{ .level = 1, .max_level = 12, .dictionary = dictionary }, .{ .level = 2, .dictionary = dictionary } }) |o| {
        try exact(lz4.Compressor, lz4.Compressor.memory(o), .{o});
        const s: lz4.Compress.Options = .{ .compressor = o };
        try exact(lz4.Compress, lz4.Compress.memory(s), .{s});
    }
}

test "snappy: Compressor and Compress in exactly their memory" {
    const o: snappy.Compressor.Options = .{};
    try exact(snappy.Compressor, snappy.Compressor.memory(o), .{o});
    const s: snappy.Compress.Options = .{};
    try exact(snappy.Compress, snappy.Compress.memory(s), .{s});
}

test "zstd: Compressor, Compress, seekable, parallel in exactly their memory" {
    const dictionary = zstd.Dictionary.raw("a dictionary of a few bytes, a dictionary");
    const tunings = [_]zstd.Compressor.Options{
        .{ .level = 1, .max_input = .literal("64KiB") },
        .{ .level = 3, .max_input = .literal("64KiB") },
        .{ .level = 19, .max_input = .literal("64KiB") },
        .{ .level = 1, .max_input = .literal("64KiB"), .tuning = .{ .long_distance = true, .window_log = 20 } },
        .{ .level = 19, .max_input = .literal("64KiB"), .dictionary = &dictionary },
    };
    for (tunings) |o| {
        try exact(zstd.Compressor, zstd.Compressor.memory(o), .{o});
        const s: zstd.Compress.Options = .{ .level = o.level, .tuning = o.tuning, .dictionary = o.dictionary, .pledged_size = .literal("64KiB") };
        try exact(zstd.Compress, zstd.Compress.memory(s), .{s});
    }
    var sink: [16]u8 = undefined;
    var output: std.Io.Writer = .fixed(&sink);
    const w: zstd.seekable.Writer.Options = .{ .frame_len = .literal("64KiB"), .max_frames = 16 };
    try exact(zstd.seekable.Writer, zstd.seekable.Writer.memory(w), .{ &output, w });
    const p: zstd.parallel.Options = .{ .concurrency = 2, .tuning = .{ .window_log = 16 } };
    try exact(zstd.parallel.Compressor, zstd.parallel.Compressor.memory(p), .{p});
    const d: zstd.parallel.Decompressor.Options = .{ .concurrency = 2 };
    try exact(zstd.parallel.Decompressor, zstd.parallel.Decompressor.memory(d), .{d});
}

test "lzma: Compressor and Compress in exactly their memory" {
    for ([_]lzma.Compressor.Options{ .{ .dictionary = 1 << 16 }, .{ .dictionary = 1 << 16, .match_finder = .hc4 } }) |o| {
        try exact(lzma.Compressor, lzma.Compressor.memory(o, null), .{ o, null });
        const small: aegis.units.Bytes(usize) = .literal("4KiB");
        try exact(lzma.Compressor, lzma.Compressor.memory(o, small), .{ o, small });

        const s: lzma.Compress.Options = .{ .lzma = o };
        try exact(lzma.Compress, lzma.Compress.memory(s), .{s});
    }
}

test "bzip2: Decompressor and the parallel one in exactly their memory" {
    try exact(bzip2.Decompressor, bzip2.Decompressor.memory, .{});
    const o: bzip2.parallel.Decompressor.Options = .{ .concurrency = 2, .block_out = .literal("1MiB") };
    try exact(bzip2.parallel.Decompressor, bzip2.parallel.Decompressor.memory(o), .{o});
}
