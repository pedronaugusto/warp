//! Every test in warp but those whose work is shared between threads,
//! which `concurrent_test.zig` holds; the `test` step runs both roots.

test {
    _ = @import("checksum.zig");
    _ = @import("container.zig");
    _ = @import("gzip.zig");
    _ = @import("inflate.zig");
    _ = @import("stream.zig");
    _ = @import("huffman.zig");
    _ = @import("bits.zig");
    _ = @import("checksum/crc.zig");
    _ = @import("match.zig");
    _ = @import("deflate/block.zig");
    _ = @import("deflate/split.zig");
    _ = @import("testing/decode_test.zig");
    _ = @import("testing/encode_test.zig");
    _ = @import("testing/inflate_test.zig");
    _ = @import("testing/deflate_test.zig");
    _ = @import("testing/deflate64_test.zig");
    _ = @import("testing/c_test.zig");
    _ = @import("zstd.zig");
    _ = @import("testing/zstd_decode_test.zig");
    _ = @import("testing/zstd_encode_test.zig");
    _ = @import("testing/zstd_stream_test.zig");
    _ = @import("testing/zstd_train_test.zig");
    _ = @import("testing/zstd_seekable_test.zig");
    _ = @import("testing/zstd_super_test.zig");
    _ = @import("testing/zstd_index_test.zig");
}
