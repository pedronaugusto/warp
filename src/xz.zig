//! `.xz`: streams of blocks of LZMA2, with Delta and the branch
//! converters before it, decoded as liblzma 5.8.4 reads them.

/// Where a stream was refused, and why (shared with `warp.lzma`).
pub const Diagnostic = @import("lzma/Diagnostic.zig");
/// Whole-buffer decoding into the caller's output.
pub const Decompressor = @import("xz/Decompressor.zig");
/// Resumable decoding.
pub const Decompress = @import("xz/Decompress.zig");
/// Whole-buffer decoding with blocks decoded in parallel.
pub const parallel = @import("xz/parallel.zig");
/// How many streams a decoder reads.
pub const Streams = Decompressor.Streams;

test {
    _ = @import("xz/format.zig");
    _ = @import("xz/filter.zig");
}
