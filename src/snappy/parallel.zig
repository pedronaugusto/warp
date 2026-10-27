//! Snappy and S2 streams over workers: blocks encoded each on its own and
//! written out in order, and blocks decoded each on its own, straight into
//! its range of the output.

/// Whole-buffer stream encoding with blocks encoded in parallel.
pub const Compressor = @import("parallel/Compressor.zig");
/// Whole-buffer stream decoding with blocks decoded in parallel.
pub const Decompressor = @import("parallel/Decompressor.zig");
