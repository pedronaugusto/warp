//! CRC-32 as zlib, gzip, PNG and zip compute it (IEEE 802.3, reflected,
//! polynomial 0xedb88320), with the fastest kernel this CPU has.
//!
//! Large inputs fold 16-byte lanes forward with carry-less multiplies
//! (PMULL on AArch64, PCLMULQDQ and VPCLMULQDQ on x86-64), many lanes at a
//! time, and reduce the last lane with a scalar kernel. Without those,
//! AArch64's CRC32 instructions take eight bytes a step, and anything else
//! eight bytes at a time from eight tables (slicing-by-8). Every kernel
//! gives the same value; tests hold each to a bitwise reference.

const std = @import("std");
const builtin = @import("builtin");
const cpu = @import("../cpu.zig");
const Kernel = @import("kernel.zig").Kernel;
const crc_ = @import("crc");

const arm_crc = @import("kernels_arm_crc");
const arm_pmull = @import("kernels_arm_pmull");
const arm_eor3 = @import("kernels_arm_eor3");
const x86_sse = @import("kernels_x86_sse");
const x86_avx2 = @import("kernels_x86_avx2");

/// The reflected polynomial.
pub const polynomial: u32 = 0xedb88320;

const math = crc_.Crc(polynomial);
pub const slicing8 = math.slicing8;
pub const bitwise = math.bitwise;

/// A running CRC-32, as `std.hash.Crc32` is used.
pub const Crc32 = struct {
    /// The CRC of what was given so far, as zlib's `crc32()` returns it.
    value: u32 = 0,

    pub const init: Crc32 = .{};

    pub fn update(c: *Crc32, bytes: []const u8) void {
        c.value = crc32(c.value, bytes);
    }

    pub fn final(c: Crc32) u32 {
        return c.value;
    }

    /// The CRC-32 of `bytes`.
    pub fn hash(bytes: []const u8) u32 {
        return crc32(0, bytes);
    }
};

/// zlib's `crc32(crc, buf, len)`: `crc` continued over `bytes`.
pub fn crc32(crc: u32, bytes: []const u8) u32 {
    return ~update(kernel(), ~crc, bytes);
}

/// The kernel this CPU runs.
pub fn kernel() Kernel {
    if (builtin.cpu.arch == .aarch64) {
        if (cpu.has(.arm_pmull) and cpu.has(.arm_sha3) and cpu.has(.arm_crc)) return .arm_pmull_eor3;
        if (cpu.has(.arm_pmull) and cpu.has(.arm_crc)) return .arm_pmull;
        if (cpu.has(.arm_crc)) return .arm_crc;
    }
    if (builtin.cpu.arch == .x86_64) {
        if (cpu.has(.x86_vpclmul)) return .x86_vpclmul;
        if (cpu.has(.x86_pclmul)) return .x86_pclmul;
    }
    return .slicing8;
}

/// Whether this CPU can run `k`.
pub fn runs(k: Kernel) bool {
    return switch (k) {
        .slicing8 => true,
        .arm_crc => builtin.cpu.arch == .aarch64 and cpu.has(.arm_crc),
        .arm_pmull => builtin.cpu.arch == .aarch64 and cpu.has(.arm_crc) and cpu.has(.arm_pmull),
        .arm_pmull_eor3 => builtin.cpu.arch == .aarch64 and cpu.has(.arm_crc) and cpu.has(.arm_pmull) and cpu.has(.arm_sha3),
        .x86_pclmul => builtin.cpu.arch == .x86_64 and cpu.has(.x86_pclmul),
        .x86_vpclmul => builtin.cpu.arch == .x86_64 and cpu.has(.x86_vpclmul),
        else => false,
    };
}

/// The register `reg` (as the algorithm keeps it, inverted) continued over
/// `bytes` by kernel `k`, which this CPU must run.
pub fn update(k: Kernel, reg: u32, bytes: []const u8) u32 {
    if (builtin.cpu.arch == .aarch64) switch (k) {
        .arm_pmull_eor3 => return crc_.folded(arm_eor3.min_len, arm_crc.crc32, arm_eor3.crc32Fold, reg, bytes),
        .arm_pmull => return crc_.folded(arm_pmull.min_len, arm_crc.crc32, arm_pmull.crc32Fold, reg, bytes),
        .arm_crc => return arm_crc.crc32(reg, bytes),
        else => {},
    };
    if (builtin.cpu.arch == .x86_64) switch (k) {
        .x86_vpclmul => return crc_.folded(x86_avx2.min_len, slicing8, x86_avx2.crc32Fold, reg, bytes),
        .x86_pclmul => return crc_.folded(x86_sse.min_len, slicing8, x86_sse.crc32Fold, reg, bytes),
        else => {},
    };
    return slicing8(reg, bytes);
}

/// zlib's `crc32_combine`: the CRC of A ++ B from the CRCs of A and B and
/// the length of B, in time logarithmic in it.
pub fn crc32Combine(crc_a: u32, crc_b: u32, len_b: u64) u32 {
    return math.combine(crc_a, crc_b, len_b);
}

const testing = std.testing;

test "CRC-32 is zlib's: the check value, the empty input, and std's at every length" {
    try testing.expectEqual(@as(u32, 0xcbf43926), Crc32.hash("123456789"));
    try testing.expectEqual(@as(u32, 0), Crc32.hash(""));
    var buf: [3000]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @truncate(i *% 2654435761 >> 7);
    for ([_]usize{ 0, 1, 7, 8, 9, 31, 64, 1000, 2999, 3000 }) |n| {
        try testing.expectEqual(std.hash.Crc32.hash(buf[0..n]), Crc32.hash(buf[0..n]));
    }
}

test "every kernel this CPU runs gives the bitwise CRC at lengths 0 to 4096 and alignments 0 to 63" {
    const buf = try testing.allocator.alloc(u8, 4096 + 64);
    defer testing.allocator.free(buf);
    for (buf, 0..) |*b, i| b.* = @truncate((i *% 0x9e3779b1) >> 11);
    for (std.enums.values(Kernel)) |k| {
        if (!runs(k)) continue;
        var n: usize = 0;
        while (n <= 4096) : (n += if (n < 300) 1 else 37) {
            for ([_]usize{ 0, 1, 3, 7, 8, 15, 16, 31, 63 }) |at| {
                const data = buf[at..][0..n];
                const want = bitwise(0xffff_ffff, data);
                testing.expectEqual(want, update(k, 0xffff_ffff, data)) catch |err| {
                    std.debug.print("kernel {s}, length {d}, alignment {d}\n", .{ @tagName(k), n, at });
                    return err;
                };
            }
        }
    }
}

test "a CRC continued over pieces equals the CRC of the whole, for every kernel" {
    var buf: [5000]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @truncate(i * 131 + 17);
    const whole = Crc32.hash(&buf);
    for ([_]usize{ 0, 1, 15, 16, 17, 255, 256, 257, 2048, 4999, 5000 }) |cut| {
        var c: Crc32 = .init;
        c.update(buf[0..cut]);
        c.update(buf[cut..]);
        try testing.expectEqual(whole, c.final());
    }
}

test "crc32Combine joins the CRCs of two pieces, at any length of the second" {
    var buf: [4096]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @truncate(i *% 7919 >> 3);
    for ([_]usize{ 0, 1, 2, 100, 1000, 2048, 4095, 4096 }) |cut| {
        const a = Crc32.hash(buf[0..cut]);
        const b = Crc32.hash(buf[cut..]);
        try testing.expectEqual(Crc32.hash(&buf), crc32Combine(a, b, buf.len - cut));
    }
    // Lengths past 4 GiB by the combine identities: the CRC of n zero bytes
    // is the combine of the empty CRC with them, and joining is associative.
    const zeros: [1024]u8 = @splat(0);
    const z1k = Crc32.hash(&zeros);
    try testing.expectEqual(crc32Combine(z1k, z1k, 1024), Crc32.hash(&(zeros ++ zeros)));
    var big = z1k;
    var len: u64 = 1024;
    while (len < (1 << 33)) : (len *= 2) big = crc32Combine(big, big, len);
    // 2^33 zero bytes: twice 2^32, and 2^32 is 2^22 KiB.
    var direct: u32 = z1k;
    for (0..23) |i| direct = crc32Combine(direct, direct, @as(u64, 1024) << @intCast(i));
    try testing.expectEqual(direct, big);
    try testing.expectEqual(crc32Combine(crc32Combine(1, 2, 5), 3, 7), crc32Combine(1, crc32Combine(2, 3, 7), 12));
}
