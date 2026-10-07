//! Adler-32 (RFC 1950), the zlib container's checksum, with the fastest
//! kernel this CPU has.
//!
//! s1 is 1 plus the bytes' sum and s2 the sum of every s1 along the way,
//! both modulo 65521. A block of n bytes adds n·s1 plus each byte weighted
//! by how many s1 values it enters (n for the first, 1 for the last), so a
//! kernel keeps per-column byte sums and a running sum in vectors and
//! weights them once per run of blocks, reducing modulo 65521 only when the
//! 32-bit sums could otherwise overflow.

const std = @import("std");
const builtin = @import("builtin");
const cpu = @import("../cpu.zig");
const Kernel = @import("kernel.zig").Kernel;

const arm_dotprod = @import("kernels_arm_dotprod");
const x86_avx2 = @import("kernels_x86_avx2");

pub const base = 65521;
/// The most bytes s2 can take from s1 = s2 = base - 1 without passing 2^32.
pub const nmax = 5552;

/// A running Adler-32, as `std.hash.Adler32` is used.
pub const Adler32 = struct {
    /// The Adler-32 of what was given so far, as zlib's `adler32()` returns it.
    value: u32 = 1,

    pub const init: Adler32 = .{};

    pub fn update(a: *Adler32, bytes: []const u8) void {
        a.value = adler32(a.value, bytes);
    }

    pub fn final(a: Adler32) u32 {
        return a.value;
    }

    /// The Adler-32 of `bytes`.
    pub fn hash(bytes: []const u8) u32 {
        return adler32(1, bytes);
    }
};

/// zlib's `adler32(adler, buf, len)`: `adler` continued over `bytes`.
pub fn adler32(adler: u32, bytes: []const u8) u32 {
    return update(kernel(), adler, bytes);
}

/// The kernel this CPU runs.
pub fn kernel() Kernel {
    if (builtin.cpu.arch == .aarch64 and cpu.has(.arm_dotprod)) return .arm_dotprod;
    if (builtin.cpu.arch == .x86_64 and cpu.has(.x86_avx2)) return .x86_avx2;
    return .vector;
}

/// Whether this CPU can run `k`.
pub fn runs(k: Kernel) bool {
    return switch (k) {
        .vector => true,
        .arm_dotprod => builtin.cpu.arch == .aarch64 and cpu.has(.arm_dotprod),
        .x86_avx2 => builtin.cpu.arch == .x86_64 and cpu.has(.x86_avx2),
        else => false,
    };
}

/// `adler` continued over `bytes` by kernel `k`, which this CPU must run.
pub fn update(k: Kernel, adler: u32, bytes: []const u8) u32 {
    switch (k) {
        .arm_dotprod => if (builtin.cpu.arch == .aarch64) return arm_dotprod.adler32(adler, bytes),
        .x86_avx2 => if (builtin.cpu.arch == .x86_64) return x86_avx2.adler32(adler, bytes),
        else => {},
    }
    return vector(adler, bytes);
}

/// 32-byte blocks on the target's vectors: per-column sums in 16-bit
/// lanes, the running sum in 32-bit lanes.
pub fn vector(adler: u32, bytes: []const u8) u32 {
    const block = 32;
    // Column sums stay below 2^16: 255 · 256 blocks.
    const max_blocks = 256;
    var s1: u32 = adler & 0xffff;
    var s2: u32 = adler >> 16;
    var rest = bytes;
    const weights: @Vector(block, u32) = comptime blk: {
        var w: [block]u32 = undefined;
        for (&w, 0..) |*x, i| x.* = block - i;
        break :blk w;
    };
    while (rest.len >= block) {
        // A run whose s2 cannot pass 2^32 before it is reduced.
        const blocks: usize = @min(rest.len / block, max_blocks, nmax / block);
        var columns: @Vector(block, u16) = @splat(0);
        var running: @Vector(8, u32) = @splat(0);
        var prefix: @Vector(8, u32) = @splat(0);
        for (0..blocks) |i| {
            const v: @Vector(block, u8) = rest[i * block ..][0..block].*;
            prefix +%= running;
            const w: @Vector(block, u16) = v;
            columns +%= w;
            const quarters = @shuffle(u16, w, undefined, [8]i32{ 0, 1, 2, 3, 4, 5, 6, 7 }) +
                @shuffle(u16, w, undefined, [8]i32{ 8, 9, 10, 11, 12, 13, 14, 15 }) +
                @shuffle(u16, w, undefined, [8]i32{ 16, 17, 18, 19, 20, 21, 22, 23 }) +
                @shuffle(u16, w, undefined, [8]i32{ 24, 25, 26, 27, 28, 29, 30, 31 });
            running +%= @as(@Vector(8, u32), quarters);
        }
        // In 64 bits: 32 times the prefix sums alone can pass 2^32.
        const n: u64 = blocks * block;
        const c32: @Vector(block, u32) = columns;
        const prefix_sum: u64 = @reduce(.Add, @as(@Vector(8, u64), prefix));
        const weighted: u64 = @reduce(.Add, c32 * weights);
        s2 = @intCast((s2 + n * s1 + block * prefix_sum + weighted) % base);
        s1 = (s1 + @reduce(.Add, c32)) % base;
        rest = rest[blocks * block ..];
    }
    return tail(s1, s2, rest);
}

/// The last bytes, one at a time; `rest.len` < nmax.
pub fn tail(s1_in: u32, s2_in: u32, rest: []const u8) u32 {
    var s1 = s1_in;
    var s2 = s2_in;
    for (rest) |b| {
        s1 += b;
        s2 += s1;
    }
    return (s2 % base) << 16 | (s1 % base);
}

/// The Adler-32 of A ++ B from those of A and B and the length of B.
pub fn adler32Combine(adler_a: u32, adler_b: u32, len_b: u64) u32 {
    const rem: u32 = @intCast(len_b % base);
    var sum1: u32 = adler_a & 0xffff;
    var sum2: u32 = @intCast((@as(u64, rem) * sum1) % base);
    sum1 += (adler_b & 0xffff) + base - 1;
    sum2 += (adler_a >> 16) + (adler_b >> 16) + base - rem;
    if (sum1 >= base) sum1 -= base;
    if (sum1 >= base) sum1 -= base;
    if (sum2 >= base << 1) sum2 -= base << 1;
    if (sum2 >= base) sum2 -= base;
    return sum2 << 16 | sum1;
}

/// The definition, one byte at a time with a reduction after each: the
/// reference every kernel is tested against.
pub fn reference(adler: u32, bytes: []const u8) u32 {
    var s1 = adler & 0xffff;
    var s2 = adler >> 16;
    for (bytes) |b| {
        s1 = (s1 + b) % base;
        s2 = (s2 + s1) % base;
    }
    return s2 << 16 | s1;
}

const testing = std.testing;

test "Adler-32 is zlib's: known values, the empty input, and std's" {
    try testing.expectEqual(@as(u32, 1), Adler32.hash(""));
    try testing.expectEqual(@as(u32, 0x00620062), Adler32.hash("a"));
    try testing.expectEqual(@as(u32, 0x11e60398), Adler32.hash("Wikipedia"));
    var buf: [3000]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @truncate(i *% 31 + 7);
    for ([_]usize{ 0, 1, 31, 32, 33, 100, 2999, 3000 }) |n| {
        try testing.expectEqual(std.hash.Adler32.hash(buf[0..n]), Adler32.hash(buf[0..n]));
    }
}

test "every kernel this CPU runs gives the reference at lengths 0 to 4096, alignments 0 to 63, and on all-0xff runs past the reduction bound" {
    const buf = try testing.allocator.alloc(u8, 4096 + 64);
    defer testing.allocator.free(buf);
    for (buf, 0..) |*b, i| b.* = @truncate((i *% 0x9e3779b1) >> 11);
    const ones = try testing.allocator.alloc(u8, 3 * nmax + 77);
    defer testing.allocator.free(ones);
    @memset(ones, 0xff);
    for (std.enums.values(Kernel)) |k| {
        if (!runs(k)) continue;
        var n: usize = 0;
        while (n <= 4096) : (n += if (n < 300) 1 else 37) {
            for ([_]usize{ 0, 1, 3, 7, 8, 15, 16, 31, 63 }) |at| {
                const data = buf[at..][0..n];
                testing.expectEqual(reference(1, data), update(k, 1, data)) catch |err| {
                    std.debug.print("kernel {s}, length {d}, alignment {d}\n", .{ @tagName(k), n, at });
                    return err;
                };
            }
        }
        // The largest sums: every byte 0xff, starting from the largest state.
        const start: u32 = (base - 1) << 16 | (base - 1);
        try testing.expectEqual(reference(start, ones), update(k, start, ones));
    }
}

test "adler32Combine joins the checksums of two pieces" {
    var buf: [10_000]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = @truncate(i *% 7919 >> 3);
    for ([_]usize{ 0, 1, 2, 100, 5552, 9999, 10_000 }) |cut| {
        const a = Adler32.hash(buf[0..cut]);
        const b = Adler32.hash(buf[cut..]);
        try testing.expectEqual(Adler32.hash(&buf), adler32Combine(a, b, buf.len - cut));
    }
    // Past 4 GiB: length enters only modulo 65521.
    try testing.expectEqual(adler32Combine(0x1234_5678, 0x0abc_0def, 7), adler32Combine(0x1234_5678, 0x0abc_0def, 7 + 65521 * (1 << 20)));
}
