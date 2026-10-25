//! Prefix codes for the encoder, as the reference encoder (google/brotli
//! 1.2.1) builds and writes them: depths from counts by a two-queue
//! Huffman merge whose smallest counts are raised until the code fits its
//! depth limit, counts smoothed toward runs the code-length code stores
//! cheaply, the depths written as run-length-coded code lengths, and the
//! short codes (at most four symbols) in the format's simple form. Every
//! choice here is the reference's, ties included, so its sizes are kept.

const std = @import("std");
const bits = @import("bits.zig");
const tables = @import("tables.zig");

const Writer = bits.Writer;

/// The largest alphabet: insert-and-copy codes.
pub const max_symbols = 704;
pub const code_length_codes = 18;
const repeat_previous = 16;
const repeat_zero = 17;
const initial_repeated_length = 8;

pub const Node = struct {
    count: u32,
    left: i16,
    /// The right child, or the symbol of a leaf.
    right: i16,
};

/// Nodes the tree of `max_symbols` leaves needs.
pub const tree_size = 2 * max_symbols + 1;
pub const Tree = [tree_size]Node;

const sentinel: Node = .{ .count = std.math.maxInt(u32), .left = -1, .right = -1 };

/// The reference's sort: insertion below 13 items, Shell sort above; the
/// fast path's order is not total, so the algorithm decides its ties.
fn sortNodes(items: []Node, comptime less: fn (Node, Node) bool) void {
    const n = items.len;
    if (n < 13) {
        var i: usize = 1;
        while (i < n) : (i += 1) {
            const tmp = items[i];
            var k = i;
            var j = i - 1;
            while (less(tmp, items[j])) {
                items[k] = items[j];
                k = j;
                if (j == 0) break;
                j -= 1;
            }
            items[k] = tmp;
        }
        return;
    }
    const gaps = [_]usize{ 132, 57, 23, 10, 4, 1 };
    for (gaps[if (n < 57) 2 else 0..]) |gap| {
        var i: usize = gap;
        while (i < n) : (i += 1) {
            var j: usize = i;
            const tmp = items[i];
            while (j >= gap and less(tmp, items[j - gap])) : (j -= gap) items[j] = items[j - gap];
            items[j] = tmp;
        }
    }
}

fn lessFull(a: Node, b: Node) bool {
    if (a.count != b.count) return a.count < b.count;
    return a.right > b.right;
}

fn lessCount(a: Node, b: Node) bool {
    return a.count < b.count;
}

/// Depths of the leaves under `root`; false when one is deeper than
/// `max_depth`.
fn setDepth(root: usize, pool: []const Node, depth: []u8, max_depth: u32) bool {
    var stack: [16]i32 = undefined;
    var level: i32 = 0;
    var p = root;
    stack[0] = -1;
    while (true) {
        if (pool[p].left >= 0) {
            level += 1;
            if (level > max_depth) return false;
            stack[@intCast(level)] = pool[p].right;
            p = @intCast(pool[p].left);
            continue;
        }
        depth[@intCast(pool[p].right)] = @intCast(level);
        while (level >= 0 and stack[@intCast(level)] == -1) level -= 1;
        if (level < 0) return true;
        p = @intCast(stack[@intCast(level)]);
        stack[@intCast(level)] = -1;
    }
}

/// Merge the sorted leaves `tree[0..n]` into a tree whose root is
/// `tree[2n - 1]`.
fn merge(tree: []Node, n: usize) void {
    tree[n] = sentinel;
    tree[n + 1] = sentinel;
    var i: usize = 0;
    var j: usize = n + 1;
    var k = n - 1;
    while (k != 0) : (k -= 1) {
        var left: usize = undefined;
        if (tree[i].count <= tree[j].count) {
            left = i;
            i += 1;
        } else {
            left = j;
            j += 1;
        }
        var right: usize = undefined;
        if (tree[i].count <= tree[j].count) {
            right = i;
            i += 1;
        } else {
            right = j;
            j += 1;
        }
        const end = 2 * n - k;
        tree[end] = .{ .count = tree[left].count + tree[right].count, .left = @intCast(left), .right = @intCast(right) };
        tree[end + 1] = sentinel;
    }
}

/// Depths for `counts` (zero for an unused symbol), none deeper than
/// `limit`; `depth` is written only for used symbols.
pub fn createTree(counts: []const u32, limit: u32, tree: []Node, depth: []u8) void {
    var floor: u32 = 1;
    while (true) : (floor *= 2) {
        var n: usize = 0;
        var i = counts.len;
        while (i != 0) {
            i -= 1;
            if (counts[i] != 0) {
                tree[n] = .{ .count = @max(counts[i], floor), .left = -1, .right = @intCast(i) };
                n += 1;
            }
        }
        if (n == 1) {
            depth[@intCast(tree[0].right)] = 1;
            return;
        }
        sortNodes(tree[0..n], lessFull);
        merge(tree, n);
        if (setDepth(2 * n - 1, tree, depth, limit)) return;
    }
}

/// Smooth `counts` so the code's depths come in runs the code-length code
/// stores cheaply; `good` is scratch of `counts.len`.
pub fn optimizeForRle(counts_in: []u32, good: []u8) void {
    var nonzero_count: usize = 0;
    for (counts_in) |c| nonzero_count += @intFromBool(c != 0);
    if (nonzero_count < 16) return;
    var length = counts_in.len;
    while (length != 0 and counts_in[length - 1] == 0) length -= 1;
    if (length == 0) return;
    const counts = counts_in[0..length];
    {
        var nonzeros: usize = 0;
        var smallest: u32 = 1 << 30;
        for (counts) |c| {
            if (c != 0) {
                nonzeros += 1;
                smallest = @min(smallest, c);
            }
        }
        if (nonzeros < 5) return;
        if (smallest < 4 and length - nonzeros < 6) {
            for (1..length - 1) |i| {
                if (counts[i - 1] != 0 and counts[i] == 0 and counts[i + 1] != 0) counts[i] = 1;
            }
        }
        if (nonzeros < 28) return;
    }
    // Runs that already code well: zeros of 5 or more, others of 7.
    @memset(good[0..length], 0);
    {
        var symbol = counts[0];
        var step: usize = 0;
        for (0..length + 1) |i| {
            if (i == length or counts[i] != symbol) {
                if ((symbol == 0 and step >= 5) or (symbol != 0 and step >= 7)) {
                    for (0..step) |k| good[i - k - 1] = 1;
                }
                step = 1;
                if (i != length) symbol = counts[i];
            } else step += 1;
        }
    }
    // Strides of near-equal counts become equal; 24.8 fixed point.
    const streak_limit: usize = 1240;
    var stride: usize = 0;
    var limit: usize = 256 * (@as(usize, counts[0]) + counts[1] + counts[2]) / 3 + 420;
    var sum: usize = 0;
    for (0..length + 1) |i| {
        if (i == length or good[i] != 0 or (i != 0 and good[i - 1] != 0) or
            (256 * @as(usize, counts[i]) -% limit +% streak_limit) >= 2 * streak_limit)
        {
            if (stride >= 4 or (stride >= 3 and sum == 0)) {
                var count = (sum + stride / 2) / stride;
                if (count == 0) count = 1;
                if (sum == 0) count = 0;
                for (0..stride) |k| counts[i - k - 1] = @intCast(count);
            }
            stride = 0;
            sum = 0;
            if (i + 2 < length) {
                limit = 256 * (@as(usize, counts[i]) + counts[i + 1] + counts[i + 2]) / 3 + 420;
            } else if (i < length) {
                limit = 256 * @as(usize, counts[i]);
            } else limit = 0;
        }
        stride += 1;
        if (i != length) {
            sum += counts[i];
            if (stride >= 4) limit = (256 * sum + stride / 2) / stride;
            if (stride == 4) limit += 120;
        }
    }
}

/// Code lengths as code-length symbols with their extra bits.
pub const Lengths = struct {
    symbols: [max_symbols]u8 = undefined,
    extra: [max_symbols]u8 = undefined,
    len: usize = 0,

    fn put(l: *Lengths, symbol: u8, extra: u8) void {
        l.symbols[l.len] = symbol;
        l.extra[l.len] = extra;
        l.len += 1;
    }

    fn reverseFrom(l: *Lengths, start: usize) void {
        std.mem.reverse(u8, l.symbols[start..l.len]);
        std.mem.reverse(u8, l.extra[start..l.len]);
    }

    fn repeat(l: *Lengths, previous: u8, value: u8, count: usize) void {
        var reps = count;
        if (previous != value) {
            l.put(value, 0);
            reps -= 1;
        }
        if (reps == 7) {
            l.put(value, 0);
            reps -= 1;
        }
        if (reps < 3) {
            for (0..reps) |_| l.put(value, 0);
            return;
        }
        const start = l.len;
        reps -= 3;
        while (true) {
            l.put(repeat_previous, @intCast(reps & 3));
            reps >>= 2;
            if (reps == 0) break;
            reps -= 1;
        }
        l.reverseFrom(start);
    }

    fn zeros(l: *Lengths, count: usize) void {
        var reps = count;
        if (reps == 11) {
            l.put(0, 0);
            reps -= 1;
        }
        if (reps < 3) {
            for (0..reps) |_| l.put(0, 0);
            return;
        }
        const start = l.len;
        reps -= 3;
        while (true) {
            l.put(repeat_zero, @intCast(reps & 7));
            reps >>= 3;
            if (reps == 0) break;
            reps -= 1;
        }
        l.reverseFrom(start);
    }
};

/// Whether runs of non-zero and of zero lengths are worth run codes.
const RleUse = struct { nonzero: bool = false, zero: bool = false };

fn rleUse(depth: []const u8) RleUse {
    var reps_zero: usize = 0;
    var reps_nonzero: usize = 0;
    var runs_zero: usize = 1;
    var runs_nonzero: usize = 1;
    var i: usize = 0;
    while (i < depth.len) {
        const value = depth[i];
        var reps: usize = 1;
        while (i + reps < depth.len and depth[i + reps] == value) reps += 1;
        if (reps >= 3 and value == 0) {
            reps_zero += reps;
            runs_zero += 1;
        }
        if (reps >= 4 and value != 0) {
            reps_nonzero += reps;
            runs_nonzero += 1;
        }
        i += reps;
    }
    return .{ .nonzero = reps_nonzero > runs_nonzero * 2, .zero = reps_zero > runs_zero * 2 };
}

/// The depths as code-length symbols, trailing zeros dropped.
pub fn writeLengths(depth: []const u8, out: *Lengths) void {
    var length = depth.len;
    while (length != 0 and depth[length - 1] == 0) length -= 1;
    const use: RleUse = if (depth.len > 50) rleUse(depth[0..length]) else .{};
    var previous: u8 = initial_repeated_length;
    var i: usize = 0;
    while (i < length) {
        const value = depth[i];
        var reps: usize = 1;
        if ((value != 0 and use.nonzero) or (value == 0 and use.zero)) {
            while (i + reps < length and depth[i + reps] == value) reps += 1;
        }
        if (value == 0) {
            out.zeros(reps);
        } else {
            out.repeat(previous, value, reps);
            previous = value;
        }
        i += reps;
    }
}

fn reverseBits(n: u32, v: u16) u16 {
    const lut = [16]u16{ 0x0, 0x8, 0x4, 0xC, 0x2, 0xA, 0x6, 0xE, 0x1, 0x9, 0x5, 0xD, 0x3, 0xB, 0x7, 0xF };
    var r: usize = lut[v & 0xf];
    var b = v;
    var i: u32 = 4;
    while (i < n) : (i += 4) {
        r <<= 4;
        b >>= 4;
        r |= lut[b & 0xf];
    }
    r >>= @intCast((0 -% n) & 3);
    return @intCast(r);
}

/// Canonical codewords, bit-reversed for the writer, for `depth`.
pub fn codewords(depth: []const u8, out: []u16) void {
    var count: [16]u16 = @splat(0);
    for (depth) |d| count[d] += 1;
    count[0] = 0;
    var next: [16]u16 = undefined;
    next[0] = 0;
    var code: u32 = 0;
    for (1..16) |i| {
        code = (code + count[i - 1]) << 1;
        next[i] = @truncate(code);
    }
    for (depth, 0..) |d, i| {
        if (d != 0) {
            out[i] = reverseBits(d, next[d]);
            next[d] += 1;
        }
    }
}

/// The code-length code's own depths, with its static code.
fn storeCodeLengthDepths(w: *Writer, num_codes: u32, cl_depth: *const [code_length_codes]u8) void {
    const order = [code_length_codes]u8{ 1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
    const symbols = [6]u8{ 0, 7, 3, 2, 1, 15 };
    const lengths = [6]u8{ 2, 4, 3, 2, 2, 4 };
    var to_store: usize = code_length_codes;
    if (num_codes > 1) {
        while (to_store > 0) : (to_store -= 1) {
            if (cl_depth[order[to_store - 1]] != 0) break;
        }
    }
    var skip: usize = 0;
    if (cl_depth[order[0]] == 0 and cl_depth[order[1]] == 0) {
        skip = 2;
        if (cl_depth[order[2]] == 0) skip = 3;
    }
    w.bits(2, skip);
    for (skip..to_store) |i| {
        const l = cl_depth[order[i]];
        w.bits(lengths[l], symbols[l]);
    }
}

/// A complex prefix code: `depths` (an alphabet of at most `max_symbols`)
/// as code lengths under a code-length code of depth at most 5.
pub fn storeTree(w: *Writer, depths: []const u8, tree: []Node) void {
    var lengths: Lengths = .{};
    writeLengths(depths, &lengths);
    var histogram: [code_length_codes]u32 = @splat(0);
    for (lengths.symbols[0..lengths.len]) |s| histogram[s] += 1;
    var num_codes: u32 = 0;
    var code: usize = 0;
    for (histogram, 0..) |h, i| {
        if (h == 0) continue;
        if (num_codes == 0) {
            code = i;
            num_codes = 1;
        } else {
            num_codes = 2;
            break;
        }
    }
    var cl_depth: [code_length_codes]u8 = @splat(0);
    var cl_bits: [code_length_codes]u16 = undefined;
    createTree(&histogram, 5, tree, &cl_depth);
    codewords(&cl_depth, &cl_bits);
    storeCodeLengthDepths(w, num_codes, &cl_depth);
    if (num_codes == 1) cl_depth[code] = 0;
    for (lengths.symbols[0..lengths.len], lengths.extra[0..lengths.len]) |s, e| {
        w.bits(cl_depth[s], cl_bits[s]);
        switch (s) {
            repeat_previous => w.bits(2, e),
            repeat_zero => w.bits(3, e),
            else => {},
        }
    }
}

/// A simple prefix code of 2-4 symbols, ordered by depth.
fn storeSimple(w: *Writer, depths: []const u8, symbols_in: [4]usize, count: usize, max_bits: u32) void {
    var symbols = symbols_in;
    w.bits(2, 1);
    w.bits(2, count - 1);
    for (0..count) |i| {
        for (i + 1..count) |j| {
            if (depths[symbols[j]] < depths[symbols[i]]) std.mem.swap(usize, &symbols[j], &symbols[i]);
        }
    }
    for (symbols[0..count]) |s| w.bits(max_bits, s);
    if (count == 4) w.bits(1, @intFromBool(depths[symbols[0]] == 1));
}

/// Bits that name a symbol of an alphabet of `size`.
pub fn alphabetBits(size: usize) u32 {
    var n: u32 = 0;
    var c = size - 1;
    while (c != 0) : (c >>= 1) n += 1;
    return n;
}

/// Build the code of `histogram` into `depth` and `codes`, and store it.
pub fn buildAndStore(w: *Writer, histogram: []const u32, alphabet_size: usize, tree: []Node, depth: []u8, codes: []u16) void {
    var count: usize = 0;
    var s4: [4]usize = @splat(0);
    for (histogram, 0..) |h, i| {
        if (h == 0) continue;
        if (count < 4) {
            s4[count] = i;
        } else if (count > 4) break;
        count += 1;
    }
    const max_bits = alphabetBits(alphabet_size);
    if (count <= 1) {
        w.bits(4, 1);
        w.bits(max_bits, s4[0]);
        depth[s4[0]] = 0;
        codes[s4[0]] = 0;
        return;
    }
    @memset(depth[0..histogram.len], 0);
    createTree(histogram, 15, tree, depth);
    codewords(depth[0..histogram.len], codes);
    if (count <= 4) {
        storeSimple(w, depth, s4, count, max_bits);
    } else storeTree(w, depth[0..histogram.len], tree);
}

/// The fast qualities' build: depth at most 14, ties left to the sort,
/// complex codes written with the static code-length code.
pub fn buildAndStoreFast(w: *Writer, tree: []Node, histogram: []const u32, histogram_total: usize, max_bits: u32, depth: []u8, codes: []u16) void {
    var count: usize = 0;
    var symbols: [4]usize = @splat(0);
    var length: usize = 0;
    var total = histogram_total;
    while (total != 0) : (length += 1) {
        if (histogram[length] != 0) {
            if (count < 4) symbols[count] = length;
            count += 1;
            total -= histogram[length];
        }
    }
    if (count <= 1) {
        w.bits(4, 1);
        w.bits(max_bits, symbols[0]);
        depth[symbols[0]] = 0;
        codes[symbols[0]] = 0;
        return;
    }
    @memset(depth[0..length], 0);
    var floor: u32 = 1;
    while (true) : (floor *= 2) {
        var n: usize = 0;
        var l = length;
        while (l != 0) {
            l -= 1;
            if (histogram[l] != 0) {
                tree[n] = .{ .count = @max(histogram[l], floor), .left = -1, .right = @intCast(l) };
                n += 1;
            }
        }
        sortNodes(tree[0..n], lessCount);
        merge(tree, n);
        if (setDepth(2 * n - 1, tree, depth, 14)) break;
    }
    codewords(depth[0..length], codes);
    if (count <= 4) {
        storeSimple(w, depth, symbols, count, max_bits);
        return;
    }
    storeStaticCodeLengthCode(w);
    var previous: u8 = initial_repeated_length;
    var i: usize = 0;
    while (i < length) {
        const value = depth[i];
        var reps: usize = 1;
        while (i + reps < length and depth[i + reps] == value) reps += 1;
        i += reps;
        if (value == 0) {
            w.bits(tables.zero_reps_depth[reps], tables.zero_reps_bits[reps]);
            continue;
        }
        if (previous != value) {
            w.bits(tables.code_length_depth[value], tables.code_length_bits[value]);
            reps -= 1;
        }
        if (reps < 3) {
            for (0..reps) |_| w.bits(tables.code_length_depth[value], tables.code_length_bits[value]);
        } else {
            reps -= 3;
            w.bits(tables.nonzero_reps_depth[reps], tables.nonzero_reps_bits[reps]);
        }
        previous = value;
    }
}

pub fn storeStaticCodeLengthCode(w: *Writer) void {
    w.bits(40, 0x0000ff_55555554);
}

pub fn storeStaticCommandCode(w: *Writer) void {
    w.bits(56, 0x926244_16307003);
    w.bits(3, 0);
}

pub fn storeStaticDistanceCode(w: *Writer) void {
    w.bits(28, 0x0369dc03);
}

test "depths respect the limit and form a complete code" {
    var counts: [300]u32 = undefined;
    for (&counts, 0..) |*c, i| c.* = if (i % 7 == 3) 0 else @intCast(1 + (i * i * 2654435761 >> 7) % 100000);
    counts[5] = 1 << 28;
    var tree: Tree = undefined;
    var depth: [300]u8 = @splat(0);
    createTree(&counts, 15, &tree, &depth);
    var kraft: u64 = 0;
    for (counts, depth) |c, d| {
        if (c == 0) continue;
        try std.testing.expect(d >= 1 and d <= 15);
        kraft += @as(u64, 1) << @intCast(15 - d);
    }
    try std.testing.expectEqual(@as(u64, 1) << 15, kraft);
}
