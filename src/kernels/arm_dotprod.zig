//! Adler-32 on AArch64 with UDOT: 64 bytes a step in four independent
//! chains, the byte sums and the weighted sums both by dot products. Built
//! with the DotProd extension; run only where the CPU has it.

const base = 65521;
const u32x4 = @Vector(4, u32);
const u8x16 = @Vector(16, u8);

/// `adler` continued over `bytes`.
pub fn adler32(adler: u32, bytes: []const u8) u32 {
    var s1: u64 = adler & 0xffff;
    var s2: u64 = adler >> 16;
    var rest = bytes;
    const ones: u8x16 = @splat(1);
    const weights = comptime blk: {
        var w: [4]u8x16 = undefined;
        for (0..4) |v| for (0..16) |i| {
            w[v][i] = 64 - 16 * v - i;
        };
        break :blk w;
    };
    while (rest.len >= 64) {
        // Lanes hold at most 1020 a chunk in s1 and 1020·n²/2 in s2: 1024
        // chunks stay under 2^32.
        const chunks: usize = @min(rest.len / 64, 1024);
        var sum: [4]u32x4 = @splat(@splat(0));
        var prefix: [4]u32x4 = @splat(@splat(0));
        var weighted: [4]u32x4 = @splat(@splat(0));
        for (0..chunks) |c| {
            inline for (0..4) |v| {
                const data: u8x16 = rest[c * 64 + v * 16 ..][0..16].*;
                prefix[v] +%= sum[v];
                sum[v] = udot(sum[v], data, ones);
                weighted[v] = udot(weighted[v], data, weights[v]);
            }
        }
        const n: u64 = chunks * 64;
        const total_sum: u64 = @reduce(.Add, @as(@Vector(4, u64), sum[0] +% sum[1] +% sum[2] +% sum[3]));
        var total_prefix: u64 = 0;
        var total_weighted: u64 = 0;
        inline for (0..4) |v| {
            total_prefix += @reduce(.Add, @as(@Vector(4, u64), prefix[v]));
            total_weighted += @reduce(.Add, @as(@Vector(4, u64), weighted[v]));
        }
        // Each sum reduced before it is weighted: every term within base and n times it.
        s2 = (s2 + n * s1 + 64 * (total_prefix % base) + total_weighted % base) % base;
        s1 = (s1 + total_sum) % base;
        rest = rest[chunks * 64 ..];
    }
    // The last bytes as one chunk, zero-padded in front: zeros add nothing to s1 and s1 to s2
    // once each, so k bytes add k·s1 and their sums weighted k down to 1.
    if (rest.len != 0) {
        const k = @min(rest.len, 64);
        var padded: [64]u8 = @splat(0);
        @memcpy(padded[64 - k ..], rest[0..k]);
        var sum: u32x4 = @splat(0);
        var weighted: u32x4 = @splat(0);
        inline for (0..4) |v| {
            const data: u8x16 = padded[v * 16 ..][0..16].*;
            sum = udot(sum, data, ones);
            weighted = udot(weighted, data, weights[v]);
        }
        const total: u64 = @reduce(.Add, @as(@Vector(4, u64), sum));
        const total_weighted: u64 = @reduce(.Add, @as(@Vector(4, u64), weighted));
        s2 = (s2 + k * s1 + total_weighted % base) % base;
        s1 = (s1 + total % base) % base;
    }
    return @intCast(((s2 % base) << 16) | (s1 % base));
}

inline fn udot(acc: u32x4, a: u8x16, b: u8x16) u32x4 {
    return asm ("udot %[r].4s, %[a].16b, %[b].16b" // aegis: boundary: one instruction on vector registers, no memory
        : [r] "=w" (-> u32x4),
        : [acc] "0" (acc),
          [a] "w" (a),
          [b] "w" (b),
    );
}
