//! Which kernel a checksum runs on.

/// A checksum kernel. Each runs only where the CPU has its instructions;
/// `kernels()` says which one each checksum uses here.
pub const Kernel = enum {
    /// CRC-32 or CRC-32C from eight tables, eight bytes a step: any CPU.
    slicing8,
    /// CRC-32 or CRC-32C with AArch64's CRC32 instructions, eight bytes a
    /// step.
    arm_crc,
    /// CRC-32 or CRC-32C folding 16-byte lanes with PMULL.
    arm_pmull,
    /// CRC-32 or CRC-32C folding with PMULL, the lanes joined with EOR3.
    arm_pmull_eor3,
    /// CRC-32C with x86-64's CRC32 instruction, eight bytes a step.
    x86_sse42,
    /// CRC-32 or CRC-32C folding with PCLMULQDQ on 128-bit registers.
    x86_pclmul,
    /// CRC-32 or CRC-32C folding with VPCLMULQDQ on 256-bit registers.
    x86_vpclmul,
    /// Adler-32 on the target's vectors: NEON, SSE2, wasm SIMD, or scalar
    /// code where there are none.
    vector,
    /// Adler-32 with AArch64's UDOT.
    arm_dotprod,
    /// Adler-32 on 256-bit AVX2 registers.
    x86_avx2,
};
