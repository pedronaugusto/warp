//! CRC-32 and CRC-32C by folding: the bulk of an input becomes one
//! 16-byte lane whose CRC (from a zero register) is the input's, which the
//! caller finishes with a scalar kernel together with the bytes left over.
//!
//! A 16-byte lane, loaded little-endian as [lo, hi], is the polynomial
//! lo·x^64 + hi in the reflected bit order. Moving it D bytes forward
//! is multiplying by x^(8D) modulo P, which two carry-less 64×32-bit
//! products do: lo times x^(8D+31) mod P and hi times x^(8D-33) mod P (in
//! the reflected order, where a 64×32 product lands one bit short of the
//! 128-bit lane). Many lanes fold at once, D = the bytes a step takes;
//! then they fold into one.
//!
//! Every function here is `inline`: a kernel module built with the CPU
//! features its instructions need instantiates it, and the code is
//! generated there with those features. This module is never compiled for
//! itself.

const std = @import("std");

/// x^n mod P, reflected (bit 31 is x^0).
pub fn xPowModP(comptime polynomial: u32, comptime n: u32) u32 {
    @setEvalBranchQuota(100_000);
    var r: u32 = 1 << 31;
    for (0..n) |_| r = if (r & 1 != 0) (r >> 1) ^ polynomial else r >> 1;
    return r;
}

/// The constants that fold a 16-byte lane `distance` bytes forward, as the
/// [lo, hi] pair a 128-bit carry-less multiply takes.
pub fn foldConstants(comptime polynomial: u32, comptime distance: u32) [2]u64 {
    return .{ xPowModP(polynomial, 8 * distance + 31), xPowModP(polynomial, 8 * distance - 33) };
}

/// The bulk of `bytes` folded into one lane, and how many bytes that took
/// (a multiple of 16, at least `Ops.lanes * Ops.width`).
pub const Folded = struct { lane: u128, used: usize };

/// The reflected polynomials.
pub const crc32_polynomial: u32 = 0xedb88320;
pub const crc32c_polynomial: u32 = 0x82f63b78;

/// What a kernel module supplies.
///
///   width: bytes per register (16 or 32)
///   lanes: registers folded per step
///   vector: the register type, @Vector(width / 8, u64)
///   clmulLo(x, k), clmulHi(x, k): x.lo·k.lo and x.hi·k.hi in each 128-bit
///     lane, for x and k of type vector and of type @Vector(2, u64)
///
/// Lanes join with plain exclusive ors, which a module built with SHA3 on
/// AArch64 compiles to EOR3.
pub inline fn fold(comptime Ops: type, comptime polynomial: u32, reg: u32, bytes: []const u8) Folded {
    const width = Ops.width;
    const lanes = Ops.lanes;
    const step = width * lanes;
    const vector = Ops.vector;
    const u64x2 = @Vector(2, u64);
    std.debug.assert(bytes.len >= step);

    var acc: [lanes]vector = undefined;
    inline for (&acc, 0..) |*a, i| a.* = load(vector, bytes[i * width ..][0..width]);
    // The register enters as the first four bytes' complement: the folded
    // CRC then starts from zero.
    var first: [width / 8]u64 = @splat(0);
    first[0] = reg;
    acc[0] ^= @as(vector, first);

    const k_step = splat(vector, comptime foldConstants(polynomial, step));
    var at: usize = step;
    while (bytes.len - at >= step) : (at += step) {
        inline for (&acc, 0..) |*a, i| a.* = Ops.clmulLo(a.*, k_step) ^ Ops.clmulHi(a.*, k_step) ^ load(vector, bytes[at + i * width ..][0..width]);
    }

    // The registers into one, then a register's 128-bit lanes into one.
    const k_width = splat(vector, comptime foldConstants(polynomial, width));
    var r = acc[0];
    inline for (acc[1..]) |a| r = Ops.clmulLo(r, k_width) ^ Ops.clmulHi(r, k_width) ^ a;
    var x: u64x2 = .{ r[0], r[1] };
    const k16: u64x2 = comptime foldConstants(polynomial, 16);
    if (width == 32) x = Ops.clmulLo(x, k16) ^ Ops.clmulHi(x, k16) ^ u64x2{ r[2], r[3] };

    // What is left, sixteen bytes at a time.
    while (bytes.len - at >= 16) : (at += 16) {
        x = Ops.clmulLo(x, k16) ^ Ops.clmulHi(x, k16) ^ load(u64x2, bytes[at..][0..16]);
    }
    return .{ .lane = @as(u128, x[1]) << 64 | x[0], .used = at };
}

inline fn load(comptime R: type, bytes: *const [@sizeOf(R)]u8) R {
    const n = @typeInfo(R).vector.len;
    var out: R = undefined;
    inline for (0..n) |i| out[i] = std.mem.readInt(u64, bytes[i * 8 ..][0..8], .little);
    return out;
}

inline fn splat(comptime R: type, k: [2]u64) R {
    const n = @typeInfo(R).vector.len;
    var out: R = undefined;
    inline for (0..n) |i| out[i] = k[i % 2];
    return out;
}

/// AArch64: PMULL and PMULL2 on 128-bit registers, twelve lanes (192
/// bytes) a step, enough to keep four vector pipes busy through PMULL's
/// latency.
pub const Arm = struct {
    pub const width = 16;
    pub const lanes = 12;
    pub const vector = @Vector(2, u64);

    pub inline fn clmulLo(x: vector, k: vector) vector {
        return asm ("pmull %[r].1q, %[x].1d, %[k].1d"
            : [r] "=w" (-> vector),
            : [x] "w" (x),
              [k] "w" (k),
        );
    }

    pub inline fn clmulHi(x: vector, k: vector) vector {
        return asm ("pmull2 %[r].1q, %[x].2d, %[k].2d"
            : [r] "=w" (-> vector),
            : [x] "w" (x),
              [k] "w" (k),
        );
    }
};

/// x86-64 with SSE4.1: PCLMULQDQ on 128-bit registers, eight lanes (128
/// bytes) a step, as many as its latency needs.
pub const X86Sse = struct {
    pub const width = 16;
    pub const lanes = 8;
    pub const vector = @Vector(2, u64);

    pub inline fn clmulLo(x: vector, k: vector) vector {
        return clmul(0x00, x, k);
    }

    pub inline fn clmulHi(x: vector, k: vector) vector {
        return clmul(0x11, x, k);
    }

    inline fn clmul(comptime select: u8, x: vector, k: vector) vector {
        return asm ("pclmulqdq $" ++ std.fmt.comptimePrint("{d}", .{select}) ++ ", %[k], %[r]"
            : [r] "=x" (-> vector),
            : [x] "0" (x),
              [k] "x" (k),
        );
    }
};

/// x86-64 with AVX2 and VPCLMULQDQ: 256-bit registers, two 128-bit lanes
/// each, eight registers (256 bytes) a step.
pub const X86Avx2 = struct {
    pub const width = 32;
    pub const lanes = 8;
    pub const vector = @Vector(4, u64);

    pub inline fn clmulLo(x: anytype, k: @TypeOf(x)) @TypeOf(x) {
        return clmul(0x00, x, k);
    }

    pub inline fn clmulHi(x: anytype, k: @TypeOf(x)) @TypeOf(x) {
        return clmul(0x11, x, k);
    }

    inline fn clmul(comptime select: u8, x: anytype, k: @TypeOf(x)) @TypeOf(x) {
        const R = @TypeOf(x);
        const imm = std.fmt.comptimePrint("{d}", .{select});
        return asm ("vpclmulqdq $" ++ imm ++ ", %[k], %[x], %[r]"
            : [r] "=x" (-> R),
            : [x] "x" (x),
              [k] "x" (k),
        );
    }
};
