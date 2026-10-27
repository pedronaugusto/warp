//! bzip2: streams decoded, as libbz2 1.0.8 reads them. Encoding is out of
//! scope: nobody writes new bzip2, and old files and archive entries are
//! what this reads.

/// Where a stream was refused, and why.
pub const Diagnostic = @import("bzip2/Diagnostic.zig");
/// Whole-buffer decoding.
pub const Decompressor = @import("bzip2/Decompressor.zig");
/// Resumable decoding and its reader adapter.
pub const Decompress = @import("bzip2/Decompress.zig");
/// Whole-buffer decoding with blocks decoded in parallel.
pub const parallel = @import("bzip2/parallel.zig");
/// How many streams a decoder reads.
pub const Streams = Decompressor.Streams;

test {
    _ = @import("bzip2/bits.zig");
    _ = @import("bzip2/huffman.zig");
    _ = @import("bzip2/decode.zig");
}
