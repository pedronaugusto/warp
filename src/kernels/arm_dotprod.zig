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
        s2 = (s2 + n * s1 + 64 * total_prefix + total_weighted) % base;
        s1 = (s1 + total_sum) % base;
        rest = rest[chunks * 64 ..];
    }
    for (rest) |b| {
        s1 += b;
        s2 += s1;
    }
    return @intCast((s2 % base) << 16 | (s1 % base));
}

inline fn udot(acc: u32x4, a: u8x16, b: u8x16) u32x4 {
    return asm ("udot %[r].4s, %[a].16b, %[b].16b"
        : [r] "=w" (-> u32x4),
        : [acc] "0" (acc),
          [a] "w" (a),
          [b] "w" (b),
    );
}
