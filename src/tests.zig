//! Every test in warp, from one root.

test {
    _ = @import("cpu.zig");
    _ = @import("checksum.zig");
    _ = @import("container.zig");
    _ = @import("huffman.zig");
    _ = @import("bits.zig");
    _ = @import("match.zig");
    _ = @import("deflate/block.zig");
    _ = @import("testing/decode_test.zig");
    _ = @import("testing/encode_test.zig");
    _ = @import("testing/api_test.zig");
    _ = @import("zstd.zig");
    _ = @import("testing/zstd_decode_test.zig");
    _ = @import("testing/zstd_encode_test.zig");
    _ = @import("testing/zstd_stream_test.zig");
    _ = @import("testing/zstd_train_test.zig");
    _ = @import("testing/zstd_seekable_test.zig");
    _ = @import("testing/zstd_parallel_test.zig");
}
