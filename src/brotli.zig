//! Brotli (RFC 7932): streams decoded, with the large-window extension and
//! raw prefix dictionaries.

/// Where a stream was refused, and why.
pub const Diagnostic = @import("brotli/Diagnostic.zig");
/// Whole-buffer decoding.
pub const Decompressor = @import("brotli/Decompressor.zig");
/// Resumable decoding and its reader adapter.
pub const Decompress = @import("brotli/Decompress.zig");
/// How many streams a decoder reads.
pub const Streams = Decompressor.Streams;

test {
    _ = @import("brotli/bits.zig");
    _ = @import("brotli/codes.zig");
    _ = @import("brotli/context.zig");
    _ = @import("brotli/dictionary.zig");
    _ = @import("brotli/huffman.zig");
    _ = @import("brotli/decode.zig");
}
