//! Huffman codes for the encoder: lengths from symbol frequencies, limited
//! to DEFLATE's maximum (15 for litlen and distance codes, 7 for the
//! code-length code), and canonical codewords from lengths.
//!
//! The tree is built by merging two queues (leaves sorted by frequency,
//! internal nodes in the order they are made), which needs no heap. The
//! lengths come from the internal nodes taken top-down: each turns one
//! free slot at its depth into two one level deeper; a node that would go
//! deeper than the limit splits the deepest free slot above the limit
//! instead. The slots always fill a complete code, so the result is never
//! incomplete and never longer than the limit.

const std = @import("std");

/// Most symbols of any DEFLATE alphabet (litlen: 288).
pub const max_symbols = 288;

/// Code lengths for `freqs` (one per symbol, `lens.len` of them), none
/// longer than `max_len`; a symbol with no frequency gets 0. With one
/// symbol used, it gets one bit; with none, all are 0.
pub fn buildLengths(freqs: []const u32, max_len: u4, lens: []u8) void {
    std.debug.assert(freqs.len == lens.len);
    std.debug.assert(freqs.len <= max_symbols);
    @memset(lens, 0);
    // Leaves sorted by frequency, then symbol: deterministic.
    var keys: [max_symbols]u64 = undefined;
    var n: usize = 0;
    for (freqs, 0..) |f, sym| {
        if (f == 0) continue;
        keys[n] = @as(u64, f) << 16 | sym;
        n += 1;
    }
    if (n == 0) return;
    if (n == 1) {
        lens[@as(u16, @truncate(keys[0]))] = 1;
        return;
    }
    std.sort.pdq(u64, keys[0..n], {}, std.sort.asc(u64));

    // Two-queue merge: nodes 0..n-1 are the leaves, n.. the internal nodes.
    var weight: [2 * max_symbols]u64 = undefined;
    var parent: [2 * max_symbols]u16 = undefined;
    for (keys[0..n], 0..) |k, i| weight[i] = k >> 16;
    var leaf: usize = 0;
    var internal: usize = n;
    var made: usize = n;
    while (made < 2 * n - 1) : (made += 1) {
        var sum: u64 = 0;
        for (0..2) |_| {
            const take_leaf = leaf < n and (internal == made or weight[leaf] <= weight[internal]);
            const node = if (take_leaf) blk: {
                leaf += 1;
                break :blk leaf - 1;
            } else blk: {
                internal += 1;
                break :blk internal - 1;
            };
            sum += weight[node];
            parent[node] = @intCast(made);
        }
        weight[made] = sum;
    }

    // Lengths per depth, internal nodes top-down (a parent was made after
    // its children). `weight` now holds each internal node's depth.
    var counts: [16]u16 = @splat(0);
    counts[0] = 1;
    const root = 2 * n - 2;
    var node = root + 1;
    while (node > n) {
        node -= 1;
        const depth: usize = if (node == root) 0 else @as(usize, @intCast(weight[parent[node]])) + 1;
        weight[node] = depth;
        var slot = depth;
        if (slot >= max_len) {
            slot = max_len;
            while (true) {
                slot -= 1;
                if (counts[slot] != 0) break;
            }
        }
        counts[slot] -= 1;
        counts[slot + 1] += 2;
    }

    // The most frequent symbols (last in `keys`) get the shortest codes.
    var i: usize = n;
    for (1..@as(usize, max_len) + 1) |len| {
        for (0..counts[len]) |_| {
            i -= 1;
            lens[@as(u16, @truncate(keys[i]))] = @intCast(len);
        }
    }
    std.debug.assert(i == 0);
}

/// The canonical codeword of each symbol (RFC 1951 3.2.2), bit-reversed:
/// written least significant bit first, as DEFLATE packs Huffman codes.
pub fn canonicalCodes(lens: []const u8, codes: []u16) void {
    var count: [16]u16 = @splat(0);
    for (lens) |l| count[l] += 1;
    count[0] = 0;
    var next: [16]u16 = undefined;
    var code: u16 = 0;
    for (1..16) |l| {
        code = (code + count[l - 1]) << 1;
        next[l] = code;
    }
    for (lens, codes) |l, *c| {
        if (l == 0) {
            c.* = 0;
            continue;
        }
        c.* = @bitReverse(next[l]) >> @intCast(16 - @as(u5, @intCast(l)));
        next[l] += 1;
    }
}

const testing = std.testing;

fn kraft(lens: []const u8, max: u4) u64 {
    var sum: u64 = 0;
    for (lens) |l| if (l != 0) {
        sum += @as(u64, 1) << @intCast(max - l);
    };
    return sum;
}

test "lengths form a complete code within the limit, shorter for more frequent symbols" {
    var prng: std.Random.DefaultPrng = .init(5);
    const random = prng.random();
    var freqs: [288]u32 = undefined;
    var lens: [288]u8 = undefined;
    for (0..300) |round| {
        const n = 2 + random.uintLessThan(usize, 287);
        for (freqs[0..n]) |*f| f.* = if (random.boolean()) 0 else switch (round % 3) {
            0 => random.uintLessThan(u32, 100),
            1 => @as(u32, 1) << random.uintLessThan(u5, 24),
            else => random.uintLessThan(u32, 3),
        };
        freqs[0] = 1;
        freqs[1] = 1;
        for ([_]u4{ 7, 15 }) |max| {
            if (max == 7 and n > 128) continue;
            buildLengths(freqs[0..n], max, lens[0..n]);
            try testing.expectEqual(@as(u64, 1) << max, kraft(lens[0..n], max));
            for (freqs[0..n], lens[0..n]) |f, l| {
                try testing.expectEqual(f == 0, l == 0);
                try testing.expect(l <= max);
            }
            for (0..n) |a| for (0..n) |b| {
                if (freqs[a] > freqs[b] and freqs[b] != 0) try testing.expect(lens[a] <= lens[b]);
            };
        }
    }
}

test "a Fibonacci distribution is cut to fifteen bits and stays complete" {
    var freqs: [30]u32 = undefined;
    var a: u32 = 1;
    var b: u32 = 1;
    for (&freqs) |*f| {
        f.* = a;
        const c = a + b;
        a = b;
        b = c;
    }
    var lens: [30]u8 = undefined;
    buildLengths(&freqs, 15, &lens);
    try testing.expectEqual(@as(u64, 1) << 15, kraft(&lens, 15));
    try testing.expectEqual(@as(u8, 15), std.mem.max(u8, &lens));
}

test "canonical codes are RFC 1951's example, reversed" {
    // RFC 1951 3.2.2: lengths (3, 3, 3, 3, 3, 2, 4, 4) give F=00, A=010,
    // B=011, ..., G=1110, H=1111.
    const lens = [_]u8{ 3, 3, 3, 3, 3, 2, 4, 4 };
    var codes: [8]u16 = undefined;
    canonicalCodes(&lens, &codes);
    const want = [_]u16{ 0b010, 0b011, 0b100, 0b101, 0b110, 0b00, 0b1110, 0b1111 };
    for (lens, codes, want) |l, c, w| try testing.expectEqual(@bitReverse(w) >> @intCast(16 - @as(u5, @intCast(l))), c);
}
