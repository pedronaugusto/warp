//! The machine instructions warp's kernels need and Zig has no builtin for: each one instruction
//! on registers, touching no memory, so it reads and writes only its operands. glint's P007 seam
//! for the kernels (glint.json): nothing else lives here. Each needs the CPU feature named at it,
//! which only a kernel module built with that feature calls it under (build.zig's kernels); the
//! functions are inline, so they are assembled in their caller's module with its features.

/// AArch64 PMULL (AES): the carry-less product of the low 64-bit lanes of `x` and `k`.
pub inline fn pmull(x: @Vector(2, u64), k: @Vector(2, u64)) @Vector(2, u64) {
    return asm ("pmull %[r].1q, %[x].1d, %[k].1d"
        : [r] "=w" (-> @Vector(2, u64)),
        : [x] "w" (x),
          [k] "w" (k),
    );
}

/// AArch64 PMULL2 (AES): the carry-less product of the high 64-bit lanes of `x` and `k`.
pub inline fn pmull2(x: @Vector(2, u64), k: @Vector(2, u64)) @Vector(2, u64) {
    return asm ("pmull2 %[r].1q, %[x].2d, %[k].2d"
        : [r] "=w" (-> @Vector(2, u64)),
        : [x] "w" (x),
          [k] "w" (k),
    );
}

/// x86-64 PCLMULQDQ: the carry-less product of the 64-bit halves of `x` and `k` that `select`
/// names (0x00 low by low, 0x11 high by high).
pub inline fn pclmulqdq(comptime select: u8, x: @Vector(2, u64), k: @Vector(2, u64)) @Vector(2, u64) {
    return asm ("pclmulqdq $" ++ digits(select) ++ ", %[k], %[r]"
        : [r] "=x" (-> @Vector(2, u64)),
        : [x] "0" (x),
          [k] "x" (k),
    );
}

/// x86-64 VPCLMULQDQ (with AVX2): `pclmulqdq` in each 128-bit lane of `x` and `k`.
pub inline fn vpclmulqdq(comptime select: u8, x: anytype, k: @TypeOf(x)) @TypeOf(x) {
    return asm ("vpclmulqdq $" ++ digits(select) ++ ", %[k], %[x], %[r]"
        : [r] "=x" (-> @TypeOf(x)),
        : [x] "x" (x),
          [k] "x" (k),
    );
}

/// AArch64 CRC32B (CRC): the CRC-32 register `c` continued over one byte.
pub inline fn crc32b(c: u32, b: u8) u32 {
    return asm ("crc32b %[out:w], %[in:w], %[b:w]"
        : [out] "=r" (-> u32),
        : [in] "r" (c),
          [b] "r" (@as(u32, b)),
    );
}

/// AArch64 CRC32X (CRC): the CRC-32 register `c` continued over one little-endian word.
pub inline fn crc32x(c: u32, word: u64) u32 {
    return asm ("crc32x %[out:w], %[in:w], %[word:x]"
        : [out] "=r" (-> u32),
        : [in] "r" (c),
          [word] "r" (word),
    );
}

/// AArch64 CRC32CB (CRC): the CRC-32C register `c` continued over one byte.
pub inline fn crc32cb(c: u32, b: u8) u32 {
    return asm ("crc32cb %[out:w], %[in:w], %[b:w]"
        : [out] "=r" (-> u32),
        : [in] "r" (c),
          [b] "r" (@as(u32, b)),
    );
}

/// AArch64 CRC32CX (CRC): the CRC-32C register `c` continued over one little-endian word.
pub inline fn crc32cx(c: u32, word: u64) u32 {
    return asm ("crc32cx %[out:w], %[in:w], %[word:x]"
        : [out] "=r" (-> u32),
        : [in] "r" (c),
          [word] "r" (word),
    );
}

/// x86-64 CRC32 on a quadword (SSE4.2): the CRC-32C register `c` continued over one word.
pub inline fn crc32q(c: u64, word: u64) u64 {
    return asm ("crc32q %[word], %[c]"
        : [c] "=r" (-> u64),
        : [in] "0" (c),
          [word] "r" (word),
    );
}

/// x86-64 CRC32 on a byte (SSE4.2): the CRC-32C register `c` continued over one byte.
pub inline fn crc32cByte(c: u32, b: u8) u32 {
    return asm ("crc32b %[b], %[c]"
        : [c] "=r" (-> u32),
        : [in] "0" (c),
          [b] "r" (b),
    );
}

/// x86-64 VPSADBW (AVX2): each eight bytes of `v` summed, in four 64-bit lanes.
pub inline fn vpsadbw(v: @Vector(32, u8)) @Vector(4, u64) {
    return asm ("vpsadbw %[z], %[v], %[r]"
        : [r] "=x" (-> @Vector(4, u64)),
        : [v] "x" (v),
          [z] "x" (@as(@Vector(32, u8), @splat(0))),
    );
}

/// x86-64 VPMADDUBSW (AVX2): the unsigned bytes of `v` times the signed bytes of `w`, pairs added.
pub inline fn vpmaddubsw(v: @Vector(32, u8), w: @Vector(32, u8)) @Vector(16, u16) {
    return asm ("vpmaddubsw %[w], %[v], %[r]"
        : [r] "=x" (-> @Vector(16, u16)),
        : [v] "x" (v),
          [w] "x" (w),
    );
}

/// x86-64 VPMADDWD (AVX2): the 16-bit lanes of `v` times `m`, pairs added into 32-bit lanes.
pub inline fn vpmaddwd(v: @Vector(16, u16), m: @Vector(16, u16)) @Vector(8, u32) {
    return asm ("vpmaddwd %[m], %[v], %[r]"
        : [r] "=x" (-> @Vector(8, u32)),
        : [v] "x" (v),
          [m] "x" (m),
    );
}

/// AArch64 UDOT (DotProd): each four bytes of `a` and `b` multiplied and summed into a 32-bit
/// lane of `acc`.
pub inline fn udot(acc: @Vector(4, u32), a: @Vector(16, u8), b: @Vector(16, u8)) @Vector(4, u32) {
    return asm ("udot %[r].4s, %[a].16b, %[b].16b"
        : [r] "=w" (-> @Vector(4, u32)),
        : [acc] "0" (acc),
          [a] "w" (a),
          [b] "w" (b),
    );
}

/// `x`, as a value the optimizer cannot rewrite through: an empty template its register passes
/// through, so a sum built from it stays the sum written. On a target without the template, `x`.
pub inline fn barrier(x: usize) usize {
    return switch (@import("builtin").cpu.arch) {
        .aarch64, .aarch64_be, .x86_64, .x86, .arm, .armeb, .thumb, .thumbeb, .riscv32, .riscv64 => asm (""
            : [out] "=r" (-> usize),
            : [in] "0" (x),
        ),
        else => x,
    };
}

/// An instruction's immediate in decimal, for its template.
fn digits(comptime n: u8) []const u8 {
    return @import("std").fmt.comptimePrint("{d}", .{n});
}
