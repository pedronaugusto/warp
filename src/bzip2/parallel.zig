//! bzip2 decoding over workers: blocks found by their magic and decoded
//! each on its own, joined in order where each one before ended.

/// Whole-buffer decoding with blocks decoded in parallel.
pub const Decompressor = @import("parallel/Decompressor.zig");
