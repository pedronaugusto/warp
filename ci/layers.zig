//! Source layers, lowest first. Every production source has one explicit place.
const gantry = @import("gantry");

pub const layers: []const gantry.rules.Layer = &.{
    .{ .name = "fold", .patterns = &.{"src/kernels/fold.zig"} },
    .{ .name = "kernels", .patterns = &.{
        "src/kernels/arm_crc.zig",
        "src/kernels/arm_pmull.zig",
        "src/kernels/arm_eor3.zig",
        "src/kernels/arm_dotprod.zig",
        "src/kernels/x86_crc.zig",
        "src/kernels/x86_sse.zig",
        "src/kernels/x86_avx2.zig",
    } },
    .{ .name = "cpu", .patterns = &.{"src/cpu.zig"} },
    .{ .name = "diagnostic", .patterns = &.{"src/Diagnostic.zig"} },
    .{ .name = "checksum kernel names", .patterns = &.{"src/checksum/kernel.zig"} },
    .{ .name = "crc", .patterns = &.{"src/checksum/crc.zig"} },
    .{ .name = "checksums", .patterns = &.{ "src/checksum/crc32.zig", "src/checksum/crc32c.zig", "src/checksum/adler32.zig" } },
    .{ .name = "checksum", .patterns = &.{"src/checksum.zig"} },
    .{ .name = "bits", .patterns = &.{"src/bits.zig"} },
    .{ .name = "huffman codes", .patterns = &.{ "src/huffman/decode.zig", "src/huffman/encode.zig" } },
    .{ .name = "huffman", .patterns = &.{"src/huffman.zig"} },
    .{ .name = "match history", .patterns = &.{"src/match/history.zig"} },
    .{ .name = "matchfinders", .patterns = &.{ "src/match/HashChains.zig", "src/match/HashTable.zig" } },
    .{ .name = "match", .patterns = &.{"src/match.zig"} },
    .{ .name = "encode parts", .patterns = &.{ "src/deflate/block.zig", "src/deflate/split.zig" } },
    .{ .name = "encode parsers", .patterns = &.{"src/deflate/parse.zig"} },
    .{ .name = "engines", .patterns = &.{ "src/inflate.zig", "src/deflate.zig" } },
    .{ .name = "containers", .patterns = &.{ "src/container.zig", "src/gzip.zig" } },
    .{ .name = "unwrap", .patterns = &.{"src/unwrap.zig"} },
    .{ .name = "frame", .patterns = &.{ "src/Decompressor.zig", "src/Compressor.zig", "src/stream/Inflate.zig", "src/stream/Deflate.zig" } },
    .{ .name = "stream", .patterns = &.{"src/stream.zig"} },
    .{ .name = "public", .patterns = &.{"src/warp.zig"} },
};

pub const entries: []const []const u8 = &.{};

pub const modules: []const gantry.NamedModule = &.{
    .{ .name = "kernels_fold", .path = "src/kernels/fold.zig" },
    .{ .name = "kernels_arm_crc", .path = "src/kernels/arm_crc.zig" },
    .{ .name = "kernels_arm_pmull", .path = "src/kernels/arm_pmull.zig" },
    .{ .name = "kernels_arm_eor3", .path = "src/kernels/arm_eor3.zig" },
    .{ .name = "kernels_arm_dotprod", .path = "src/kernels/arm_dotprod.zig" },
    .{ .name = "kernels_x86_crc", .path = "src/kernels/x86_crc.zig" },
    .{ .name = "kernels_x86_sse", .path = "src/kernels/x86_sse.zig" },
    .{ .name = "kernels_x86_avx2", .path = "src/kernels/x86_avx2.zig" },
};

pub const references: []const gantry.rules.ReferenceRule = &.{
    .{ .name = "named dependencies", .unresolved_only = true, .except_targets = &.{
        "builtin",
        "gen",
        "shakedown",
        "std",
        "streams.corpus",
        "sizes.corpus",
        "invalid.corpus",
    } },
    .{ .name = "source siblings", .suffix = ".zig", .relative = true, .except_targets = &.{"src/**"} },
};

pub const required = blk: {
    var count: usize = 0;
    for (layers) |layer| count += layer.patterns.len;
    var paths: [count][]const u8 = undefined;
    var i: usize = 0;
    for (layers) |layer| for (layer.patterns) |path| {
        paths[i] = path;
        i += 1;
    };
    break :blk paths;
};

pub const owned: []const gantry.rules.TokenRule = &.{};
