//! Every test in warp, from one root.

test {
    _ = @import("cpu.zig");
    _ = @import("checksum.zig");
    _ = @import("container.zig");
    _ = @import("gzip.zig");
    _ = @import("inflate.zig");
    _ = @import("stream.zig");
    _ = @import("huffman.zig");
    _ = @import("bits.zig");
    _ = @import("match.zig");
    _ = @import("deflate/block.zig");
    _ = @import("testing/decode_test.zig");
    _ = @import("testing/encode_test.zig");
    _ = @import("testing/api_test.zig");
    _ = @import("testing/inflate_test.zig");
}
