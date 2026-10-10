//! Zstandard (RFC 8878): frames compressed and decompressed, dictionaries,
//! skippable frames and content checksums.

const frame_ = @import("zstd/frame.zig");

const params_ = @import("zstd/params.zig");

/// The fastest supported level.
pub const min_level = params_.min_level;
/// The highest level on the format's scale.
pub const max_level = params_.max_level;
/// The default level (0 selects this too).
pub const default_level = params_.default_level;
/// Match search and parsing strategy.
pub const Strategy = Compressor.Strategy;
/// Parameter overrides.
pub const Tuning = Compressor.Tuning;
/// Spare output room for the decoder's fast loop.
pub const decompress_margin = @import("zstd/decode.zig").margin;

/// Whether frames start with the magic number.
pub const Format = frame_.Format;
/// Where a frame was refused, and why.
pub const Diagnostic = @import("zstd/Diagnostic.zig");
/// A dictionary: content frames refer back into, with entropy tables when
/// formatted.
pub const Dictionary = @import("zstd/Dictionary.zig");
/// Dictionary selection, parameter search and entropy finalization.
pub const train = @import("zstd/train.zig");
/// Independent frames, indexed ranges and seek table output.
pub const seekable = @import("zstd/seekable.zig");
/// Ordered jobs in one frame, with deterministic worker counts.
pub const parallel = @import("zstd/parallel.zig");
/// Whole-buffer decoding.
pub const Decompressor = @import("zstd/Decompressor.zig");
/// Resumable decoding and its reader adapter.
pub const Decompress = @import("zstd/Decompress.zig");
/// Whole-buffer compression.
pub const Compressor = @import("zstd/Compressor.zig");
/// Resumable compression and its writer adapter.
pub const Compress = @import("zstd/Compress.zig");
/// How many frames a decoder reads.
pub const Frames = Decompressor.Frames;

/// What a frame header says.
pub const FrameHeader = frame_.Header;
/// A frame at the start of an input: a zstd frame or a skippable one.
pub const Frame = frame_.Frame;
/// A skippable frame's header.
pub const Skippable = frame_.Skippable;
/// Frame inspection errors.
pub const FrameError = frame_.FrameError;
/// Inspect the first frame header.
pub const frameHeader = frame_.frameHeader;
/// The first frame's compressed length.
pub const frameLength = frame_.frameLength;
/// Total declared content size, or null when a frame omits it.
pub const contentSize = frame_.contentSize;
/// Upper bound on every frame's decoded size.
pub const decompressBound = frame_.decompressBound;
/// Write a skippable frame.
pub const writeSkippable = frame_.writeSkippable;

test {
    _ = @import("zstd/Encoder.zig");
    _ = @import("zstd/bits.zig");
    _ = @import("zstd/codes.zig");
    _ = @import("zstd/fse.zig");
    _ = @import("zstd/huffman.zig");
    _ = @import("zstd/frame.zig");
    _ = Dictionary;
    _ = @import("zstd/params.zig");
    _ = @import("zstd/match/window.zig");
    _ = @import("zstd/match/lazy.zig");
    _ = @import("zstd/match/opt.zig");
    _ = @import("zstd/split.zig");
}
