//! Bit-cost estimates as the reference encoder makes them: log2 from a
//! single-precision table below 256, the entropy of a population, and the
//! cost of storing a histogram's prefix code with its symbols. Sums run in
//! the reference's order, and a product added to a sum is fused where clang
//! fuses it in the reference's build (`-ffp-contract=on`), so its doubles,
//! and its choices, come out equal.

const std = @import("std");
const builtin = @import("builtin");
const tables = @import("tables.zig");

const code_length_codes = 18;
const repeat_zero = 17;

/// `a * b + c`, fused where the target has fused multiply-add, as clang
/// fuses the reference's expressions there (and cannot elsewhere).
pub inline fn mulAdd(a: f64, b: f64, c: f64) f64 {
    if (comptime has_fma) return @mulAdd(f64, a, b, c);
    return a * b + c;
}

const has_fma = switch (builtin.cpu.arch) {
    .aarch64, .aarch64_be => true,
    .x86, .x86_64 => std.Target.x86.featureSetHas(builtin.cpu.features, .fma),
    else => false,
};

/// log2(v), log2(0) = 0.
pub inline fn fastLog2(v: usize) f64 {
    if (v < 256) return tables.log2[v];
    return @log2(@as(f64, @floatFromInt(v)));
}

/// Bits to code the population with its own entropy, at least one a symbol.
pub fn bitsEntropy(population: []const u32) f64 {
    var sum: usize = 0;
    var r: f64 = 0;
    for (population) |p| {
        sum += p;
        r = mulAdd(-@as(f64, @floatFromInt(p)), fastLog2(p), r);
    }
    if (sum != 0) r = mulAdd(@floatFromInt(sum), fastLog2(sum), r);
    return @max(r, @as(f64, @floatFromInt(sum)));
}

/// The estimated bits of `h`'s symbols and of storing its code.
pub fn populationCost(comptime H: type, h: *const H) f64 {
    const one = 12;
    const two = 20;
    const three = 28;
    const four = 37;
    if (h.total == 0) return one;
    var count: usize = 0;
    var s: [5]usize = undefined;
    for (h.data, 0..) |d, i| {
        if (d == 0) continue;
        s[count] = i;
        count += 1;
        if (count > 4) break;
    }
    switch (count) {
        1 => return one,
        2 => return two + @as(f64, @floatFromInt(h.total)),
        3 => {
            const a = h.data[s[0]];
            const b = h.data[s[1]];
            const c = h.data[s[2]];
            return three + @as(f64, @floatFromInt(2 * (a + b + c) - @max(a, b, c)));
        },
        4 => {
            var histo: [4]u32 = undefined;
            for (&histo, s[0..4]) |*v, i| v.* = h.data[i];
            for (0..4) |i| {
                for (i + 1..4) |j| {
                    if (histo[j] > histo[i]) std.mem.swap(u32, &histo[j], &histo[i]);
                }
            }
            const h23 = histo[2] + histo[3];
            return four + @as(f64, @floatFromInt(3 * h23 + 2 * (histo[0] + histo[1]) - @max(h23, histo[0])));
        },
        else => {},
    }
    // The entropy of the symbols, and a code-length histogram that uses the
    // zero-run code 17 but not the repeat code 16.
    var bits: f64 = 0;
    var max_depth: usize = 1;
    var depth_histo: [code_length_codes]u32 = @splat(0);
    const log2total = fastLog2(h.total);
    var i: usize = 0;
    while (i < H.symbols) {
        if (h.data[i] > 0) {
            const log2p = log2total - fastLog2(h.data[i]);
            var depth: usize = @intFromFloat(log2p + 0.5);
            bits = mulAdd(@floatFromInt(h.data[i]), log2p, bits);
            depth = @min(depth, 15);
            max_depth = @max(max_depth, depth);
            depth_histo[depth] += 1;
            i += 1;
            continue;
        }
        var reps: u32 = 1;
        while (i + reps < H.symbols and h.data[i + reps] == 0) reps += 1;
        i += reps;
        // The last zero run costs nothing: it is implicit.
        if (i == H.symbols) break;
        if (reps < 3) {
            depth_histo[0] += reps;
        } else {
            reps -= 2;
            while (reps > 0) : (reps >>= 3) {
                depth_histo[repeat_zero] += 1;
                bits += 3;
            }
        }
    }
    bits += @floatFromInt(18 + 2 * max_depth);
    bits += bitsEntropy(&depth_histo);
    return bits;
}
