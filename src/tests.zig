//! Every test in warp. The `concurrent` step builds this root with only the
//! tests whose work is shared between threads (`build.zig`), for
//! ThreadSanitizer.

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
    _ = @import("testing/parallel_test.zig");
    _ = @import("testing/speculative_test.zig");
    _ = @import("testing/zstd_parallel_test.zig");
    _ = @import("testing/index_test.zig");
    _ = @import("testing/api_test.zig");
    _ = @import("lz4.zig");
    _ = @import("testing/lz4_test.zig");
    _ = @import("brotli.zig");
    _ = @import("testing/brotli_decode_test.zig");
    _ = @import("gdeflate.zig");
    _ = @import("testing/gdeflate_test.zig");
    _ = @import("testing/brotli_encode_test.zig");
    _ = @import("bzip2.zig");
    _ = @import("testing/bzip2_test.zig");
    _ = @import("lzma.zig");
    _ = @import("xz.zig");
    _ = @import("Bcj2.zig");
    _ = @import("snappy.zig");
    _ = @import("testing/snappy_test.zig");
    _ = @import("testing/zstd_fse_test.zig");
    _ = @import("testing/snappy_stream_test.zig");
    _ = @import("testing/lzma_test.zig");
    _ = @import("testing/lzma_encode_test.zig");
    _ = @import("testing/xz_filter_test.zig");
    _ = @import("testing/bcj2_test.zig");
}
