//! LZMA and LZMA2: raw streams with their properties given apart (as 7z
//! and zip store them) and `.lzma` files, decoded as liblzma 5.8.4 reads
//! them and encoded with its parsers and presets. `warp.xz` reads and
//! writes the `.xz` container around LZMA2.

/// Where a stream was refused, and why.
pub const Diagnostic = @import("lzma/Diagnostic.zig");
/// Whole-buffer decoding into the caller's output.
pub const Decompressor = @import("lzma/Decompressor.zig");
/// Resumable decoding.
pub const Decompress = @import("lzma/Decompress.zig");
/// Whole-buffer encoding.
pub const Compressor = @import("lzma/Compressor.zig");
/// Resumable encoding.
pub const Compress = @import("lzma/Compress.zig");
/// lc, lp and pb.
pub const Properties = Decompressor.Properties;

test {
    _ = @import("lzma/range.zig");
    _ = @import("lzma/decode.zig");
    _ = @import("lzma/encode.zig");
    _ = @import("lzma/Finder.zig");
}
