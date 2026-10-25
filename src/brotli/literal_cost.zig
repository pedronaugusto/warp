//! Estimated bits of each literal for the Zopfli parsers' first pass, the
//! reference encoder's `BrotliEstimateBitCostsForLiterals`: entropy over a
//! sliding window of about 1 KiB, by UTF-8 position for mostly UTF-8
//! input, of 4 KiB otherwise.

const cost = @import("cost.zig");
const blocks = @import("blocks.zig");

fn utf8Position(last: usize, c: usize, clamp: usize) usize {
    if (c < 128) return 0;
    if (c >= 192) return @min(1, clamp);
    // A continuation: does the byte before end the sequence?
    if (last < 0xE0) return 0;
    return @min(2, clamp);
}

fn multiByteStatsLevel(pos: usize, len: usize, mask: usize, data: []const u8) usize {
    var counts: [3]usize = @splat(0);
    // 2 would be right, but 1 compresses better.
    var max_utf8: usize = 1;
    var last_c: usize = 0;
    for (0..len) |i| {
        const c: usize = data[(pos + i) & mask];
        counts[utf8Position(last_c, c, 2)] += 1;
        last_c = c;
    }
    if (counts[2] < 500) max_utf8 = 1;
    if (counts[1] + counts[2] < 25) max_utf8 = 0;
    return max_utf8;
}

fn estimateUtf8(pos: usize, len: usize, mask: usize, data: []const u8, histogram: *[3 * 256]usize, out: []f32) void {
    const max_utf8 = multiByteStatsLevel(pos, len, mask, data);
    const window_half = 495;
    const in_window = @min(window_half, len);
    var in_window_utf8: [3]usize = @splat(0);
    @memset(histogram, 0);
    {
        var last_c: usize = 0;
        var utf8_pos: usize = 0;
        for (0..in_window) |i| {
            const c: usize = data[(pos + i) & mask];
            histogram[256 * utf8_pos + c] += 1;
            in_window_utf8[utf8_pos] += 1;
            utf8_pos = utf8Position(last_c, c, max_utf8);
            last_c = c;
        }
    }
    for (0..len) |i| {
        if (i >= window_half) {
            // A byte leaves the window.
            const c: usize = if (i < window_half + 1) 0 else data[(pos + i - window_half - 1) & mask];
            const last_c: usize = if (i < window_half + 2) 0 else data[(pos + i - window_half - 2) & mask];
            const p2 = utf8Position(last_c, c, max_utf8);
            histogram[256 * p2 + data[(pos + i - window_half) & mask]] -= 1;
            in_window_utf8[p2] -= 1;
        }
        if (i + window_half < len) {
            // A byte enters it.
            const c: usize = data[(pos + i + window_half - 1) & mask];
            const last_c: usize = data[(pos + i + window_half - 2) & mask];
            const p2 = utf8Position(last_c, c, max_utf8);
            histogram[256 * p2 + data[(pos + i + window_half) & mask]] += 1;
            in_window_utf8[p2] += 1;
        }
        const c: usize = if (i < 1) 0 else data[(pos + i - 1) & mask];
        const last_c: usize = if (i < 2) 0 else data[(pos + i - 2) & mask];
        const utf8_pos = utf8Position(last_c, c, max_utf8);
        var histo = histogram[256 * utf8_pos + data[(pos + i) & mask]];
        if (histo == 0) histo = 1;
        const prologue_length = 2000;
        const multiplier = 0.35 / 2000.0;
        var lit_cost = cost.fastLog2(in_window_utf8[utf8_pos]) - cost.fastLog2(histo);
        lit_cost += 0.02905;
        if (lit_cost < 1.0) {
            lit_cost *= 0.5;
            lit_cost += 0.5;
        }
        // The first bytes cost more: the start of the data is unlike the
        // rest.
        if (i < prologue_length) lit_cost += cost.mulAdd(multiplier, @floatFromInt(i), 0.35);
        out[i] = @floatCast(lit_cost);
    }
}

pub fn estimate(pos: usize, len: usize, mask: usize, data: []const u8, histogram: *[3 * 256]usize, out: []f32) void {
    if (blocks.isMostlyUtf8(data, pos, mask, len, 0.75)) return estimateUtf8(pos, len, mask, data, histogram, out);
    const window_half = 2000;
    var in_window: usize = @min(window_half, len);
    const h = histogram[0..256];
    @memset(h, 0);
    for (0..in_window) |i| h[data[(pos + i) & mask]] += 1;
    for (0..len) |i| {
        if (i >= window_half) {
            h[data[(pos + i - window_half) & mask]] -= 1;
            in_window -= 1;
        }
        if (i + window_half < len) {
            h[data[(pos + i + window_half) & mask]] += 1;
            in_window += 1;
        }
        var histo = h[data[(pos + i) & mask]];
        if (histo == 0) histo = 1;
        var lit_cost = cost.fastLog2(in_window) - cost.fastLog2(histo);
        lit_cost += 0.029;
        if (lit_cost < 1.0) {
            lit_cost *= 0.5;
            lit_cost += 0.5;
        }
        out[i] = @floatCast(lit_cost);
    }
}
