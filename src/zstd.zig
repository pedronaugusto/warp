//! Zstandard (RFC 8878): frames compressed and decompressed, dictionaries,
//! skippable frames and content checksums.

const frame_ = @import("zstd/frame.zig");

/// Whether frames start with the magic number.
pub const Format = frame_.Format;
/// Where a frame was refused, and why.
pub const Diagnostic = @import("zstd/Diagnostic.zig");
/// A dictionary: content frames refer back into, with entropy tables when
/// formatted.
pub const Dictionary = @import("zstd/Dictionary.zig");
/// Whole-buffer decoding.
pub const Decompressor = @import("zstd/Decompressor.zig");
/// Whole-buffer compression.
pub const Compressor = @import("zstd/Compressor.zig");
/// How many frames a decoder reads.
pub const Frames = Decompressor.Frames;

/// What a frame header says.
pub const FrameHeader = frame_.Header;
/// A frame at the start of an input: a zstd frame or a skippable one.
pub const Frame = frame_.Frame;
/// A skippable frame's header.
pub const Skippable = frame_.Skippable;
/// Write a skippable frame.
pub const writeSkippable = frame_.writeSkippable;

test {
    _ = @import("zstd/bits.zig");
    _ = @import("zstd/codes.zig");
    _ = @import("zstd/fse.zig");
    _ = @import("zstd/huffman.zig");
    _ = @import("zstd/frame.zig");
    _ = Dictionary;
    _ = @import("zstd/params.zig");
    _ = @import("zstd/match/window.zig");
    _ = @import("zstd/split.zig");
}
