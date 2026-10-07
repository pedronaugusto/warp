//! CRC-32 and CRC-32C folding on x86-64 with PCLMULQDQ on 128-bit
//! registers. Built with PCLMUL and SSE4.1; run only where the CPU has
//! them.

const fold = @import("kernels_fold");

/// The fewest bytes the folds take.
pub const min_len = fold.X86Sse.width * fold.X86Sse.lanes;

/// The bulk of `bytes` as one CRC-32 lane; `bytes.len >= min_len`.
pub fn crc32Fold(reg: u32, bytes: []const u8) fold.Folded {
    return fold.fold(fold.X86Sse, fold.crc32_polynomial, reg, bytes);
}

/// The bulk of `bytes` as one CRC-32C lane; `bytes.len >= min_len`.
pub fn crc32cFold(reg: u32, bytes: []const u8) fold.Folded {
    return fold.fold(fold.X86Sse, fold.crc32c_polynomial, reg, bytes);
}
