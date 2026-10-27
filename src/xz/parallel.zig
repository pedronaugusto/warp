//! .xz over workers: blocks with their sizes in their headers decoded
//! each on its own, straight into its range of the output; and blocks
//! encoded each on its own, written out in order.

/// Whole-buffer decoding with blocks decoded in parallel.
pub const Decompressor = @import("parallel/Decompressor.zig");
/// Whole-buffer encoding with blocks encoded in parallel.
pub const Compressor = @import("parallel/Compressor.zig");
