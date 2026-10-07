//! x86-64 kernels on 256-bit registers: CRC-32 and CRC-32C folding with
//! VPCLMULQDQ, and Adler-32 with VPSADBW and VPMADDUBSW. Built with AVX2,
//! PCLMUL and VPCLMULQDQ; the folds run only where the CPU has
//! VPCLMULQDQ, Adler-32 wherever it has AVX2.

const fold = @import("kernels_fold");

/// The fewest bytes the folds take.
pub const min_len = fold.X86Avx2.width * fold.X86Avx2.lanes;

/// The bulk of `bytes` as one CRC-32 lane; `bytes.len >= min_len`.
pub fn crc32Fold(reg: u32, bytes: []const u8) fold.Folded {
    return fold.fold(fold.X86Avx2, fold.crc32_polynomial, reg, bytes);
}

/// The bulk of `bytes` as one CRC-32C lane; `bytes.len >= min_len`.
pub fn crc32cFold(reg: u32, bytes: []const u8) fold.Folded {
    return fold.fold(fold.X86Avx2, fold.crc32c_polynomial, reg, bytes);
}

const base = 65521;
const u8x32 = @Vector(32, u8);
const u64x4 = @Vector(4, u64);
const u32x8 = @Vector(8, u32);

/// `adler` continued over `bytes`.
pub fn adler32(adler: u32, bytes: []const u8) u32 {
    var s1: u64 = adler & 0xffff;
    var s2: u64 = adler >> 16;
    var rest = bytes;
    const weights: u8x32 = comptime blk: {
        var w: [32]u8 = undefined;
        for (&w, 0..) |*x, i| x.* = 32 - i;
        break :blk w;
    };
    const ones16: @Vector(16, u16) = @splat(1);
    while (rest.len >= 32) {
        // Lanes of `sum` gain at most 2040 a block, `prefix` 2040·n²/2:
        // 1024 blocks keep both far from 2^64, and `weighted` (32130 a
        // block) under 2^32.
        const blocks: usize = @min(rest.len / 32, 1024);
        var sum: u64x4 = @splat(0);
        var prefix: u64x4 = @splat(0);
        var weighted: u32x8 = @splat(0);
        for (0..blocks) |b| {
            const v: u8x32 = rest[b * 32 ..][0..32].*;
            prefix +%= sum;
            sum +%= sad(v);
            weighted +%= maddwd(maddubs(v, weights), ones16);
        }
        const n: u64 = blocks * 32;
        s2 = (s2 + n * s1 + 32 * @reduce(.Add, prefix) + @reduce(.Add, @as(@Vector(8, u64), weighted))) % base;
        s1 = (s1 + @reduce(.Add, sum)) % base;
        rest = rest[blocks * 32 ..];
    }
    for (rest) |b| {
        s1 += b;
        s2 += s1;
    }
    return @intCast((s2 % base) << 16 | (s1 % base));
}

/// Sums of each eight bytes, in four 64-bit lanes.
inline fn sad(v: u8x32) u64x4 {
    return asm ("vpsadbw %[z], %[v], %[r]"
        : [r] "=x" (-> u64x4),
        : [v] "x" (v),
          [z] "x" (@as(u8x32, @splat(0))),
    );
}

/// Unsigned bytes of `v` times the signed bytes of `w`, pairs added.
inline fn maddubs(v: u8x32, w: u8x32) @Vector(16, u16) {
    return asm ("vpmaddubsw %[w], %[v], %[r]"
        : [r] "=x" (-> @Vector(16, u16)),
        : [v] "x" (v),
          [w] "x" (w),
    );
}

/// 16-bit lanes times `m`, pairs added into 32-bit lanes.
inline fn maddwd(v: @Vector(16, u16), m: @Vector(16, u16)) u32x8 {
    return asm ("vpmaddwd %[m], %[v], %[r]"
        : [r] "=x" (-> u32x8),
        : [v] "x" (v),
          [m] "x" (m),
    );
}
