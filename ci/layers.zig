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
    .{ .name = "frame", .patterns = &.{ "src/Decompressor.zig", "src/Compressor.zig" } },
    .{ .name = "zstd bits", .patterns = &.{ "src/zstd/bits.zig", "src/zstd/codes.zig", "src/zstd/Diagnostic.zig" } },
    .{ .name = "zstd fse", .patterns = &.{"src/zstd/fse.zig"} },
    .{ .name = "zstd huffman", .patterns = &.{"src/zstd/huffman.zig"} },
    .{ .name = "zstd frame headers", .patterns = &.{"src/zstd/frame.zig"} },
    .{ .name = "zstd sequences", .patterns = &.{ "src/zstd/sequences.zig", "src/zstd/params.zig", "src/zstd/split.zig", "src/zstd/match/window.zig" } },
    .{ .name = "zstd prices", .patterns = &.{"src/zstd/match/price.zig"} },
    .{ .name = "zstd match", .patterns = &.{ "src/zstd/match/fast.zig", "src/zstd/match/dfast.zig", "src/zstd/match/lazy.zig", "src/zstd/match/opt.zig", "src/zstd/match/dictionary.zig", "src/zstd/match/long.zig" } },
    .{ .name = "zstd match entry", .patterns = &.{"src/zstd/match.zig"} },
    .{ .name = "zstd engines", .patterns = &.{ "src/zstd/decode.zig", "src/zstd/encode.zig" } },
    .{ .name = "zstd partitions", .patterns = &.{"src/zstd/post.zig"} },
    .{ .name = "zstd dictionary", .patterns = &.{"src/zstd/Dictionary.zig"} },
    .{ .name = "zstd encoder state", .patterns = &.{"src/zstd/Encoder.zig"} },
    .{ .name = "zstd dictionary training", .patterns = &.{ "src/zstd/cover.zig", "src/zstd/train.zig" } },
    .{ .name = "zstd frame", .patterns = &.{ "src/zstd/Decompressor.zig", "src/zstd/Compressor.zig" } },
    .{ .name = "zstd streams", .patterns = &.{ "src/zstd/Decompress.zig", "src/zstd/Compress.zig" } },
    .{ .name = "zstd seekable", .patterns = &.{"src/zstd/seekable.zig"} },
    .{ .name = "zstd", .patterns = &.{"src/zstd.zig"} },
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
        "zstd-frames.corpus",
        "zstd-sizes.corpus",
        "zstd-invalid.corpus",
        "zstd-dictionaries.corpus",
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
