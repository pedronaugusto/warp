//! CRC-32 and CRC-32C folding on AArch64 with PMULL, built with SHA3 so
//! that the lanes join with EOR3. Run only where the CPU has both.

const fold = @import("kernels_fold");

/// The fewest bytes the folds take.
pub const min_len = fold.Arm.width * fold.Arm.lanes;

/// The bulk of `bytes` as one CRC-32 lane; `bytes.len >= min_len`.
pub fn crc32Fold(reg: u32, bytes: []const u8) fold.Folded {
    return fold.fold(fold.Arm, fold.crc32_polynomial, reg, bytes);
}

/// The bulk of `bytes` as one CRC-32C lane; `bytes.len >= min_len`.
pub fn crc32cFold(reg: u32, bytes: []const u8) fold.Folded {
    return fold.fold(fold.Arm, fold.crc32c_polynomial, reg, bytes);
}
