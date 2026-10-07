//! The instruction-set extensions warp's checksum kernels use, as this CPU
//! has them. A feature the target guarantees is known at compile time and
//! costs nothing; any other is detected on first use and kept: one atomic
//! word, written by whichever thread asks first (every writer writes the
//! same value).
//!
//! Detection is the only contact with the operating system in warp: CPUID
//! and XGETBV on x86-64, `sysctlbyname` on Darwin, the auxiliary vector on
//! Linux, `IsProcessorFeaturePresent` on Windows. Elsewhere only what the
//! target guarantees is used.

const std = @import("std");
const builtin = @import("builtin");

/// One extension or a group the kernels need together.
pub const Feature = enum(u5) {
    /// AArch64 CRC32 instructions (FEAT_CRC32).
    arm_crc,
    /// AArch64 polynomial multiply, PMULL and PMULL2 (FEAT_PMULL).
    arm_pmull,
    /// AArch64 three-way exclusive or, EOR3 (FEAT_SHA3).
    arm_sha3,
    /// AArch64 UDOT (FEAT_DotProd).
    arm_dotprod,
    /// x86 CRC32 (SSE4.2).
    x86_sse42,
    /// x86 PCLMULQDQ with SSE4.1.
    x86_pclmul,
    /// x86 AVX2 with the operating system saving YMM state.
    x86_avx2,
    /// x86 VPCLMULQDQ on 256-bit registers (with AVX2).
    x86_vpclmul,
};

pub const Set = std.EnumSet(Feature);

/// The features the target guarantees at compile time.
pub const guaranteed: Set = blk: {
    var set: Set = .empty;
    const cpu = builtin.cpu;
    switch (cpu.arch) {
        .aarch64 => {
            if (cpu.has(.aarch64, .crc)) set.insert(.arm_crc);
            if (cpu.has(.aarch64, .aes)) set.insert(.arm_pmull);
            if (cpu.has(.aarch64, .sha3)) set.insert(.arm_sha3);
            if (cpu.has(.aarch64, .dotprod)) set.insert(.arm_dotprod);
        },
        .x86_64 => {
            if (cpu.has(.x86, .sse4_2)) set.insert(.x86_sse42);
            if (cpu.has(.x86, .pclmul) and cpu.has(.x86, .sse4_1)) set.insert(.x86_pclmul);
            if (cpu.has(.x86, .avx2)) set.insert(.x86_avx2);
            if (cpu.has(.x86, .avx2) and cpu.has(.x86, .vpclmulqdq)) set.insert(.x86_vpclmul);
        },
        else => {},
    }
    break :blk set;
};

/// Bit 31 says the word below it has been detected.
var detected: std.atomic.Value(u32) = .init(0);
const done: u32 = 1 << 31;

/// Whether this CPU has `feature`.
pub fn has(comptime feature: Feature) bool {
    if (comptime guaranteed.contains(feature)) return true;
    if (comptime !detectable(feature)) return false;
    return features().contains(feature);
}

/// Every feature this CPU has.
pub fn features() Set {
    var word = detected.load(.monotonic);
    if (word & done == 0) {
        word = @as(u32, detect().bits.mask) | done;
        detected.store(word, .monotonic);
    }
    var set: Set = .empty;
    // safe: the mask's bits are the set's, below the done bit
    set.bits.mask = @truncate(word);
    return set;
}

/// Whether `feature` can be found at run time on this target.
fn detectable(feature: Feature) bool {
    return switch (builtin.cpu.arch) {
        .aarch64 => switch (feature) {
            .arm_crc, .arm_pmull, .arm_sha3, .arm_dotprod => switch (builtin.os.tag) {
                .macos, .ios, .tvos, .watchos, .visionos, .linux, .windows => true,
                else => false,
            },
            else => false,
        },
        .x86_64 => switch (feature) {
            .x86_sse42, .x86_pclmul, .x86_avx2, .x86_vpclmul => true,
            else => false,
        },
        else => false,
    };
}

fn detect() Set {
    var set = guaranteed;
    switch (builtin.cpu.arch) {
        .aarch64 => detectArm(&set),
        .x86_64 => detectX86(&set),
        else => {},
    }
    return set;
}

fn detectArm(set: *Set) void {
    switch (builtin.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => {
            const names = [_]struct { [:0]const u8, Feature }{
                .{ "hw.optional.armv8_crc32", .arm_crc },
                .{ "hw.optional.arm.FEAT_PMULL", .arm_pmull },
                .{ "hw.optional.arm.FEAT_SHA3", .arm_sha3 },
                .{ "hw.optional.arm.FEAT_DotProd", .arm_dotprod },
            };
            for (names) |n| {
                var value: u32 = 0;
                var len: usize = @sizeOf(u32);
                if (std.c.sysctlbyname(n[0], &value, &len, null, 0) == 0 and value != 0) set.insert(n[1]);
            }
        },
        .linux => {
            const hwcap = std.os.linux.getauxval(std.elf.AT.HWCAP);
            // asm/hwcap.h for arm64.
            if (hwcap & (1 << 7) != 0) set.insert(.arm_crc);
            if (hwcap & (1 << 4) != 0) set.insert(.arm_pmull);
            if (hwcap & (1 << 17) != 0) set.insert(.arm_sha3);
            if (hwcap & (1 << 20) != 0) set.insert(.arm_dotprod);
        },
        .windows => {
            const w = std.os.windows;
            if (w.IsProcessorFeaturePresent(.ARM_V8_CRC32_INSTRUCTIONS_AVAILABLE)) set.insert(.arm_crc);
            if (w.IsProcessorFeaturePresent(.ARM_V8_CRYPTO_INSTRUCTIONS_AVAILABLE)) set.insert(.arm_pmull);
            if (w.IsProcessorFeaturePresent(.ARM_SHA3_INSTRUCTIONS_AVAILABLE)) set.insert(.arm_sha3);
            if (w.IsProcessorFeaturePresent(.ARM_V82_DP_INSTRUCTIONS_AVAILABLE)) set.insert(.arm_dotprod);
        },
        else => {},
    }
}

fn detectX86(set: *Set) void {
    if (builtin.cpu.arch != .x86_64) return;
    const leaf1 = cpuid(1, 0);
    const sse41 = leaf1[2] & (1 << 19) != 0;
    const pclmul = leaf1[2] & (1 << 1) != 0;
    if (leaf1[2] & (1 << 20) != 0) set.insert(.x86_sse42);
    if (sse41 and pclmul) set.insert(.x86_pclmul);
    // AVX state saved by the operating system: OSXSAVE, then XCR0's SSE
    // and AVX bits.
    const osxsave = leaf1[2] & (1 << 27) != 0;
    if (!osxsave or xgetbv() & 0b110 != 0b110) return;
    if (cpuid(0, 0)[0] < 7) return;
    const leaf7 = cpuid(7, 0);
    const avx2 = leaf7[1] & (1 << 5) != 0;
    if (avx2) set.insert(.x86_avx2);
    if (avx2 and pclmul and leaf7[2] & (1 << 10) != 0) set.insert(.x86_vpclmul);
}

fn cpuid(leaf: u32, subleaf: u32) [4]u32 {
    var eax: u32 = undefined;
    var ebx: u32 = undefined;
    var ecx: u32 = undefined;
    var edx: u32 = undefined;
    asm volatile ("cpuid"
        : [eax] "={eax}" (eax),
          [ebx] "={ebx}" (ebx),
          [ecx] "={ecx}" (ecx),
          [edx] "={edx}" (edx),
        : [leaf] "{eax}" (leaf),
          [subleaf] "{ecx}" (subleaf),
    );
    return .{ eax, ebx, ecx, edx };
}

fn xgetbv() u32 {
    return asm volatile ("xgetbv"
        : [eax] "={eax}" (-> u32),
        : [ecx] "{ecx}" (@as(u32, 0)),
        : .{ .edx = true });
}

test "the detected features include the guaranteed ones, and asking twice gives the same set" {
    const first = features();
    try std.testing.expect(first.supersetOf(guaranteed));
    try std.testing.expectEqual(first.bits.mask, features().bits.mask);
    inline for (comptime std.enums.values(Feature)) |f| try std.testing.expectEqual(first.contains(f), has(f));
}
