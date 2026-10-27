//! LZMA and LZMA2: raw streams with their properties given apart (as 7z
//! and zip store them) and `.lzma` files, decoded as liblzma 5.8.4 reads
//! them. `warp.xz` reads the `.xz` container around LZMA2.

/// Where a stream was refused, and why.
pub const Diagnostic = @import("lzma/Diagnostic.zig");
/// Whole-buffer decoding into the caller's output.
pub const Decompressor = @import("lzma/Decompressor.zig");
/// Resumable decoding.
pub const Decompress = @import("lzma/Decompress.zig");
/// lc, lp and pb.
pub const Properties = Decompressor.Properties;

test {
    _ = @import("lzma/range.zig");
    _ = @import("lzma/decode.zig");
}
