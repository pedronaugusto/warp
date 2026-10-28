//! `.xz`: streams of blocks of LZMA2, with Delta and the branch
//! converters before it, decoded as liblzma 5.8.4 reads them and encoded
//! as it writes them.

/// Where a stream was refused, and why (shared with `warp.lzma`).
pub const Diagnostic = @import("lzma/Diagnostic.zig");
/// Whole-buffer decoding into the caller's output.
pub const Decompressor = @import("xz/Decompressor.zig");
/// Resumable decoding.
pub const Decompress = @import("xz/Decompress.zig");
/// Whole-buffer encoding.
pub const Compressor = @import("xz/Compressor.zig");
/// Resumable encoding.
pub const Compress = @import("xz/Compress.zig");
/// A block's check.
pub const Check = Compressor.Check;
/// A filter before LZMA2.
pub const Filter = Compressor.Filter;
/// A branch converter's architecture.
pub const Bcj = Compressor.Bcj;
/// One filter decoded as a `std.Io.Reader` over another reader (7z's
/// coders of the same filters).
pub const FilterReader = @import("xz/FilterReader.zig");
/// Whole-buffer decoding with blocks decoded in parallel.
pub const parallel = @import("xz/parallel.zig");
/// How many streams a decoder reads.
pub const Streams = Decompressor.Streams;

test {
    _ = @import("xz/format.zig");
    _ = @import("xz/filter.zig");
    _ = FilterReader;
}
