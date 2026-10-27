//! .xz decoding over workers: blocks with their sizes in their headers
//! decoded each on its own, straight into its range of the output.

/// Whole-buffer decoding with blocks decoded in parallel.
pub const Decompressor = @import("parallel/Decompressor.zig");
