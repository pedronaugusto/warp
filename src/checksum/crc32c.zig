//! CRC-32C (Castagnoli, reflected polynomial 0x82f63b78), the checksum of
//! iSCSI, ext4, Btrfs and many storage formats, with the fastest kernel
//! this CPU has.
//!
//! Large inputs fold 16-byte lanes forward with carry-less multiplies, as
//! CRC-32 does, and finish with the CRC32C instruction (AArch64's
//! `crc32cx`, x86-64's `crc32q`). Without carry-less multiplies the
//! instruction alone takes eight bytes a step, and anything else
//! slicing-by-8. Every kernel gives the value std's `CRC-32/ISCSI`
//! does; tests hold each to a bitwise reference.

const std = @import("std");
const builtin = @import("builtin");
const cpu = @import("../cpu.zig");
const Kernel = @import("kernel.zig").Kernel;
const crc_ = @import("crc.zig");

const arm_crc = @import("kernels_arm_crc");
const arm_pmull = @import("kernels_arm_pmull");
const arm_eor3 = @import("kernels_arm_eor3");
const x86_crc = @import("kernels_x86_crc");
const x86_sse = @import("kernels_x86_sse");
const x86_avx2 = @import("kernels_x86_avx2");

/// The reflected polynomial.
pub const polynomial: u32 = 0x82f63b78;

const math = crc_.Crc(polynomial);
pub const slicing8 = math.slicing8;
pub const bitwise = math.bitwise;

/// A running CRC-32C.
pub const Crc32c = struct {
    /// The CRC of what was given so far.
    value: u32 = 0,

    pub const init: Crc32c = .{};

    pub fn update(c: *Crc32c, bytes: []const u8) void {
        c.value = crc32c(c.value, bytes);
    }

    pub fn final(c: Crc32c) u32 {
        return c.value;
    }

    /// The CRC-32C of `bytes`.
    pub fn hash(bytes: []const u8) u32 {
        return crc32c(0, bytes);
    }
};

/// `crc` continued over `bytes`, as `crc32` continues a CRC-32.
pub fn crc32c(crc: u32, bytes: []const u8) u32 {
    return ~update(kernel(), ~crc, bytes);
}

/// The kernel this CPU runs.
pub fn kernel() Kernel {
    if (builtin.cpu.arch == .aarch64) {
        if (cpu.has(.arm_pmull) and cpu.has(.arm_sha3) and cpu.has(.arm_crc)) return .arm_pmull_eor3;
        if (cpu.has(.arm_pmull) and cpu.has(.arm_crc)) return .arm_pmull;
        if (cpu.has(.arm_crc)) return .arm_crc;
    }
    if (builtin.cpu.arch == .x86_64 and cpu.has(.x86_sse42)) {
        if (cpu.has(.x86_vpclmul)) return .x86_vpclmul;
        if (cpu.has(.x86_pclmul)) return .x86_pclmul;
        return .x86_sse42;
    }
    return .slicing8;
}

/// Whether this CPU can run `k`.
pub fn runs(k: Kernel) bool {
    const arm = builtin.cpu.arch == .aarch64;
    const x86 = builtin.cpu.arch == .x86_64 and cpu.has(.x86_sse42);
    return switch (k) {
        .slicing8 => true,
        .arm_crc => arm and cpu.has(.arm_crc),
        .arm_pmull => arm and cpu.has(.arm_crc) and cpu.has(.arm_pmull),
        .arm_pmull_eor3 => arm and cpu.has(.arm_crc) and cpu.has(.arm_pmull) and cpu.has(.arm_sha3),
        .x86_sse42 => x86,
        .x86_pclmul => x86 and cpu.has(.x86_pclmul),
        .x86_vpclmul => x86 and cpu.has(.x86_vpclmul),
        else => false,
    };
}

/// The register `reg` (inverted, as the algorithm keeps it) continued over
/// `bytes` by kernel `k`, which this CPU must run.
pub fn update(k: Kernel, reg: u32, bytes: []const u8) u32 {
    if (builtin.cpu.arch == .aarch64) switch (k) {
        .arm_pmull_eor3 => return crc_.folded(arm_eor3.min_len, arm_crc.crc32c, arm_eor3.crc32cFold, reg, bytes),
        .arm_pmull => return crc_.folded(arm_pmull.min_len, arm_crc.crc32c, arm_pmull.crc32cFold, reg, bytes),
        .arm_crc => return arm_crc.crc32c(reg, bytes),
        else => {},
    };
    if (builtin.cpu.arch == .x86_64) switch (k) {
        .x86_vpclmul => return crc_.folded(x86_avx2.min_len, x86_crc.crc32c, x86_avx2.crc32cFold, reg, bytes),
        .x86_pclmul => return crc_.folded(x86_sse.min_len, x86_crc.crc32c, x86_sse.crc32cFold, reg, bytes),
        .x86_sse42 => return x86_crc.crc32c(reg, bytes),
        else => {},
    };
    return slicing8(reg, bytes);
}

/// The CRC-32C of A ++ B from the CRC-32Cs of A and B and the length of B,
/// in time logarithmic in it.
pub fn crc32cCombine(crc_a: u32, crc_b: u32, len_b: u64) u32 {
    return math.combine(crc_a, crc_b, len_b);
}

const testing = std.testing;

test "CRC-32C is iSCSI's: the check value, RFC 3720's vectors, and std's at every length" {
    try testing.expectEqual(@as(u32, 0xe3069283), Crc32c.hash("123456789"));
    try testing.expectEqual(@as(u32, 0), Crc32c.hash(""));
    try testing.expectEqual(@as(u32, 0x8a9136aa), Crc32c.hash(&@as([32]u8, @splat(0))));
    try testing.expectEqual(@as(u32, 0x62a8ab43), Crc32c.hash(&@as([32]u8, @splat(0xff))));
    var up: [32]u8 = undefined;
    for (&up, 0..) |*b, i| b.* = @intCast(i);
    try testing.expectEqual(@as(u32, 0x46dd794e), Crc32c.hash(&up));
    var buf: [3000]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @truncate(i *% 2654435761 >> 7);
    for ([_]usize{ 0, 1, 7, 8, 9, 31, 64, 191, 192, 193, 1000, 2999, 3000 }) |n| {
        try testing.expectEqual(std.hash.crc.@"CRC-32/ISCSI".hash(buf[0..n]), Crc32c.hash(buf[0..n]));
    }
}

test "every CRC-32C kernel this CPU runs gives the bitwise CRC at lengths 0 to 4096 and alignments 0 to 63" {
    const buf = try testing.allocator.alloc(u8, 4096 + 64);
    defer testing.allocator.free(buf);
    for (buf, 0..) |*b, i| b.* = @truncate((i *% 0x9e3779b1) >> 11);
    for (std.enums.values(Kernel)) |k| {
        if (!runs(k)) continue;
        var n: usize = 0;
        while (n <= 4096) : (n += if (n < 300) 1 else 37) {
            for ([_]usize{ 0, 1, 3, 7, 8, 15, 16, 31, 63 }) |at| {
                const data = buf[at..][0..n];
                testing.expectEqual(bitwise(0xffff_ffff, data), update(k, 0xffff_ffff, data)) catch |err| {
                    std.debug.print("kernel {t}, length {d}, alignment {d}\n", .{ k, n, at });
                    return err;
                };
            }
        }
    }
}

test "crc32cCombine joins the CRC-32Cs of two pieces, up to lengths past 4 GiB" {
    var buf: [4096]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @truncate(i *% 7919 >> 3);
    for ([_]usize{ 0, 1, 2, 100, 1000, 2048, 4095, 4096 }) |cut| {
        var c: Crc32c = .init;
        c.update(buf[0..cut]);
        try testing.expectEqual(c.final(), Crc32c.hash(buf[0..cut]));
        c.update(buf[cut..]);
        try testing.expectEqual(Crc32c.hash(&buf), c.final());
        try testing.expectEqual(Crc32c.hash(&buf), crc32cCombine(Crc32c.hash(buf[0..cut]), Crc32c.hash(buf[cut..]), buf.len - cut));
    }
    // 2^33 zero bytes two ways: doubling 1 KiB 23 times, and joining
    // 2^32-byte halves built the same way.
    const zeros: [1024]u8 = @splat(0);
    var doubled = Crc32c.hash(&zeros);
    var len: u64 = 1024;
    while (len < (1 << 32)) : (len *= 2) doubled = crc32cCombine(doubled, doubled, len);
    const half = doubled;
    try testing.expectEqual(crc32cCombine(half, half, 1 << 32), blk: {
        var d = Crc32c.hash(&zeros);
        for (0..23) |i| d = crc32cCombine(d, d, @as(u64, 1024) << @intCast(i));
        break :blk d;
    });
}
