//! The near-optimal parser (levels 10-12), the reference's algorithm: every
//! match the binary trees find at each position of a block is kept until
//! the block ends; then the cheapest path through the block's literals and
//! matches is found backwards under a cost model, the model is set from
//! that path's Huffman code, and the path is found again, a few times. A
//! block of literals only, and for short blocks the cheapest path under the
//! fixed code, are weighed too; the block writer then picks stored, fixed
//! or dynamic by exact cost as for every level.
//!
//! The parse stops and resumes at any position, as the other parsers do:
//! the matches found so far, the block's statistics and a long match still
//! being skipped are its state.

const std = @import("std");
const match = @import("../match.zig");
const block = @import("block.zig");
const split = @import("split.zig");
const huffman = @import("../huffman.zig");

const decode = huffman.decode;
const BinaryTrees = match.BinaryTrees;
pub const Match = BinaryTrees.Match;

/// How a level searches and optimizes.
pub const Params = struct {
    /// Tree nodes visited per search.
    depth: u32,
    /// A match this long ends a search, and the positions inside it are
    /// not searched.
    nice: u32,
    /// Most paths found per block.
    passes: u32,
    /// A pass that saves fewer bits than this is the last.
    min_improvement: u32,
    /// An earlier pass's path is used again if it saves at least this many
    /// bits over the last pass's.
    min_bits_earlier: u32,
    /// Blocks up to this long also get a path for the fixed code.
    fixed_max: u32,
};

/// Costs are in sixteenths of a bit: the model's estimates are fractional.
const bit_cost = 16;
/// What a symbol the last pass did not use costs in the next.
const literal_unused_bits = 13;
const length_unused_bits = 13;
const offset_unused_bits = 10;

/// The shortest block the splitter makes, as the other parsers.
const min_block = 5000;

/// A node of a block's graph, one per position and one for its end: the
/// least cost from here to the end of the block, and the item that starts
/// that path (`length` 1: a literal, its byte above; else a match, its
/// distance above).
pub const Node = struct { cost: u32, item: u32 };
const item_shift = 9;
const item_mask = (1 << item_shift) - 1;

const Costs = struct {
    literal: [256]u32,
    length: [match.max_match + 1]u32,
    offset: [30]u32,
};

/// Each distance's symbol, all of them: the path search asks for many.
const offset_slot: [match.window + 1]u8 = blk: {
    @setEvalBranchQuota(200_000);
    var t: [match.window + 1]u8 = undefined;
    t[0] = 0;
    for (0..30) |s| {
        const first = decode.dist_base[s];
        for (first..first + (1 << decode.dist_extra[s])) |d| t[d] = s;
    }
    break :blk t;
};

/// The cost of a literal for the first pass, by how likely matches are
/// (few, some, many) and how many distinct literals the block has:
/// -log2((1 - p) / literals), and of a length symbol, -log2(p / 29), in
/// sixteenths of a bit, as the reference's table (its formula; it generates
/// the table with a script).
const default_literal: [3][257]u8 = blk: {
    @setEvalBranchQuota(20_000);
    const probabilities = [3]f64{ 0.25, 0.5, 0.75 };
    var t: [3][257]u8 = undefined;
    for (probabilities, 0..) |prob, i| {
        for (1..257) |used| t[i][used] = @intFromFloat(-std.math.log2((1 - prob) / @as(f64, used)) * bit_cost);
        t[i][0] = t[i][1];
    }
    break :blk t;
};
const default_length_symbol: [3]u8 = blk: {
    const probabilities = [3]f64{ 0.25, 0.5, 0.75 };
    var t: [3]u8 = undefined;
    for (probabilities, 0..) |prob, i| t[i] = @intFromFloat(-std.math.log2(prob / 29) * bit_cost);
    break :blk t;
};

/// Each length's slot.
inline fn lengthSlot(len: u32) u32 {
    return block.lengthSymbol(len) - 257;
}

/// The parse's state between positions and calls.
pub const State = struct {
    /// Each position's matches, by increasing length, then a header: their
    /// count, and the position's byte.
    cache: []Match,
    /// Matches kept: past this the block ends (one more position's worth of
    /// room follows it).
    cache_limit: usize,
    len: usize = 0,
    /// The block's graph; long enough for the longest block and the
    /// longest match past its end.
    nodes: []Node,
    /// A block ends this many bytes after it starts (or at the input's end,
    /// when that comes within `min_block` more).
    block_max: usize,
    /// The bytes that tell a block's shortest worthwhile match, for the
    /// statistics: what the whole input has, or a stream's look-ahead.
    scan: usize,
    costs: Costs = undefined,
    saved: Costs = undefined,
    /// The last block's observations, to compare the next with.
    prev_seen: [split.kinds]u32 = @splat(0),
    prev_n: u32 = 0,
    /// Match lengths a greedy parse would take, since the last check and
    /// before it: the first pass's estimate of how likely matches are.
    lens_new: [match.max_match + 1]u32 = @splat(0),
    lens: [match.max_match + 1]u32 = @splat(0),
    /// The next position the statistics observe.
    next_observation: usize = 0,
    /// Where the block could have ended at the last check that kept it.
    prev_check: ?usize = null,
    /// The shortest match the statistics count, for this block.
    min_len: u32 = 3,
    /// Positions inside a long match still to insert unsearched.
    skip_left: u32 = 0,
    first_block: bool = true,
    /// The last block was literals only: count no matches in the next's
    /// statistics.
    literals_only: bool = false,
    /// The shortest match a path takes: 3, or 6 under `filtered`.
    min_take: u32 = match.min_match,
    /// Blocks take the fixed code only (`fixed`): one path, under its
    /// costs.
    fixed_only: bool = false,

    /// Start a stream at `p`.
    pub fn restart(o: *State, p: usize) void {
        o.len = 0;
        o.prev_seen = @splat(0);
        o.prev_n = 0;
        o.lens_new = @splat(0);
        o.lens = @splat(0);
        o.next_observation = p;
        o.prev_check = null;
        o.min_len = 3;
        o.skip_left = 0;
        o.first_block = true;
        o.literals_only = false;
    }

    /// The positions moved back `n`.
    pub fn slide(o: *State, n: usize) void {
        o.next_observation -|= n;
        if (o.prev_check) |*c| c.* -= n;
    }
};

/// Parse from the builder's position: find and keep matches, and write each
/// block when it ends. Returns after a block, or where the bytes at hand
/// end.
pub fn parse(comptime dictionary: bool, comptime full_window: bool, c: anytype, o: *State, bt: *BinaryTrees, h: match.History, params: Params) void {
    const n = h.in.len;
    const stop = c.stop();
    var p = c.b.p;
    defer c.b.p = p;
    const b = c.b;
    if (o.len == 0 and o.skip_left == 0 and p < stop) {
        // A block starts here: the statistics' shortest match, from its first
        // bytes.
        if (!c.final and p + o.scan > n) return;
        o.min_len = if (o.literals_only) match.max_match + 1 else minMatchLen(h.in[p..@min(n, p + o.scan)], params.depth);
    }
    while (true) {
        if (o.skip_left > 0) {
            // Inside a long match: insert, keep no matches.
            if (p >= stop) return;
            const max = maxLen(n, p);
            // As libdeflate: the tree compares as far as a nice match.
            if (max >= BinaryTrees.required) bt.skip(dictionary, full_window, h, @intCast(p), @min(params.nice, max), params.depth);
            o.cache[o.len] = .{ .length = 0, .offset = h.in[p] };
            o.len += 1;
            p += 1;
            o.skip_left -= 1;
            if (o.skip_left > 0) continue;
        } else {
            if (p >= stop) return;
            const max = maxLen(n, p);
            var found: usize = 0;
            if (max >= BinaryTrees.required) found = bt.matches(dictionary, full_window, h, @intCast(p), max, params.nice, params.depth, o.cache[o.len..].ptr);
            const best: u32 = if (found > 0) o.cache[o.len + found - 1].length else 0;
            o.len += found;
            if (p >= o.next_observation) {
                if (best >= o.min_len) {
                    b.split.match(best);
                    o.next_observation = p + best;
                    o.lens_new[best] += 1;
                } else {
                    b.split.literal(h.in[p]);
                    o.next_observation = p + 1;
                }
            }
            o.cache[o.len] = .{ .length = @intCast(found), .offset = h.in[p] };
            o.len += 1;
            p += 1;
            if (best >= match.min_match and best >= @min(params.nice, max)) {
                o.skip_left = best - 1;
                continue;
            }
        }
        // At the end of the bytes, the caller ends the block: final or not,
        // as it knows.
        if (c.final and p == n) return;
        // Where the block may end.
        const start: usize = @intCast(b.start);
        const block_len = p - start;
        const max_end = if (c.final and n - start < o.block_max + min_block) n else start + o.block_max;
        if (p >= max_end or o.len >= o.cache_limit) {
            close(c, o, h, p, p, false, params);
            return;
        }
        if (b.split.n_new < split.check_every or block_len < min_block or (c.final and n - p < min_block)) continue;
        if (b.split.differsAt(block_len)) {
            // The data changed: end the block before the part that differs.
            const end = o.prev_check orelse p;
            close(c, o, h, end, p, false, params);
            return;
        }
        mergeLens(o);
        o.prev_check = p;
    }
}

/// Write the block the parse holds, to its position: at a flush or the
/// end of the input.
pub fn finish(c: anytype, o: *State, h: match.History, final: bool, params: Params) void {
    const p = c.b.p;
    if (!final and @as(isize, @intCast(p)) == c.b.start) return;
    mergeLens(o);
    close(c, o, h, p, p, final, params);
}

fn mergeLens(o: *State) void {
    for (&o.lens, &o.lens_new) |*l, *new| {
        l.* += new.*;
        new.* = 0;
    }
}

/// End the block at `end` (the parse is at `p`, past it when the block
/// ends before a part that differs): find its path, write it, and keep
/// what was found past it for the next block.
fn close(c: anytype, o: *State, h: match.History, end: usize, p: usize, final: bool, params: Params) void {
    const b = c.b;
    const start: usize = @intCast(b.start);
    const length = end - start;
    // The cache's end for the block: back from the parse's, a header and
    // its matches per position.
    var cache_end = o.len;
    for (end..p) |_| {
        cache_end -= 1;
        cache_end -= o.cache[cache_end].length;
    }
    const rewound = end != p;
    if (!rewound) {
        b.split.merge();
        mergeLens(o);
    }
    const used_only_literals = choosePath(o, &b.split, h, start, length, o.cache[0..cache_end], params);
    o.literals_only = used_only_literals;
    emitPath(c, o, h, start, length, used_only_literals);
    c.emit(end, final);
    // The matches found past the block start the next.
    @memmove(o.cache[0 .. o.len - cache_end], o.cache[cache_end..o.len]);
    o.len -= cache_end;
    o.prev_seen = b.split.seen;
    o.prev_n = b.split.n_seen;
    if (rewound) {
        // The observations past the block are the next one's start.
        b.split.seen = @splat(0);
        b.split.n_seen = 0;
        o.lens = @splat(0);
    } else {
        b.split.startBlock();
        o.lens = @splat(0);
        o.lens_new = @splat(0);
    }
    o.prev_check = null;
    o.first_block = false;
    // The next block observes from where the parse is.
    o.next_observation = p;
    b.ended = true;
    // The next block's statistics' shortest match, from its first bytes
    // as far as they are here.
    o.min_len = if (o.literals_only) match.max_match + 1 else minMatchLen(h.in[end..@min(h.in.len, end + o.scan)], params.depth);
}

/// Find the block's path: several passes under costs from the last
/// pass's code, literals only, the fixed code's path. Leaves the path in
/// the nodes, and costs for the next block; whether it is literals only.
fn choosePath(o: *State, stats: *const split.Splitter, h: match.History, start: usize, length: usize, cache: []const Match, params: Params) bool {
    const bytes = h.in[start..][0..length];
    // Paths may not run past the block's end.
    for (o.nodes[length + 1 .. @min(o.nodes.len, length + match.max_match)]) |*node| node.cost = 0x8000_0000;
    if (o.fixed_only) {
        setCostsFromLengths(&o.costs, &block.fixed_lengths);
        findPath(o, length, cache);
        return false;
    }
    // Literals only.
    var literal_counts: block.Counts = .{};
    for (bytes) |byte| literal_counts.literal(byte);
    const literal_lengths = block.dynamicLengths(&literal_counts);
    var fixed_cost: u64 = std.math.maxInt(u64);
    if (length <= params.fixed_max) {
        const kept = o.costs;
        setCostsFromLengths(&o.costs, &block.fixed_lengths);
        findPath(o, length, cache);
        fixed_cost = o.nodes[0].cost / bit_cost + 7;
        o.costs = kept;
    }
    setInitialCosts(o, stats, bytes, params);
    var best: u64 = std.math.maxInt(u64);
    var last: u64 = 0;
    var passes = params.passes;
    while (true) {
        findPath(o, length, cache);
        const lengths = block.dynamicLengths(&tally(o, length));
        last = lengths.cost;
        if (last + params.min_improvement > best) break;
        best = last;
        o.saved = o.costs;
        setCostsFromLengths(&o.costs, &lengths);
        passes -= 1;
        if (passes == 0) break;
    }
    if (@min(literal_lengths.cost, fixed_cost) < best) {
        if (literal_lengths.cost < fixed_cost) {
            setCostsFromLengths(&o.costs, &literal_lengths);
            return true;
        }
        setCostsFromLengths(&o.costs, &block.fixed_lengths);
        findPath(o, length, cache);
    } else if (last >= best + params.min_bits_earlier) {
        // An earlier pass's path was cheaper: find it again.
        o.costs = o.saved;
        findPath(o, length, cache);
        setCostsFromLengths(&o.costs, &block.dynamicLengths(&tally(o, length)));
    }
    return false;
}

/// The cheapest path from each position to the block's end, backwards:
/// a literal, or for each match each length from three to its own with the
/// nearest distance that has it.
fn findPath(o: *State, length: usize, cache: []const Match) void {
    const nodes = o.nodes;
    const costs = &o.costs;
    nodes[length].cost = 0;
    var k = cache.len;
    var i = length;
    while (i > 0) {
        i -= 1;
        k -= 1;
        const header = cache[k];
        const count = header.length;
        const literal = header.offset;
        var best = costs.literal[literal] + nodes[i + 1].cost;
        var item: u32 = @as(u32, literal) << item_shift | 1;
        if (count != 0) {
            var len: u32 = o.min_take;
            for (cache[k - count .. k]) |m| {
                const offset_cost = costs.offset[offset_slot[m.offset]];
                while (len <= m.length) : (len += 1) {
                    const cost = offset_cost + costs.length[len] + nodes[i + len].cost;
                    if (cost < best) {
                        best = cost;
                        item = len | @as(u32, m.offset) << item_shift;
                    }
                }
            }
            k -= count;
        }
        nodes[i] = .{ .cost = best, .item = item };
    }
}

/// The symbol counts of the path in the nodes.
fn tally(o: *const State, length: usize) block.Counts {
    var counts: block.Counts = .{};
    var i: usize = 0;
    while (i < length) {
        const item = o.nodes[i].item;
        const len = item & item_mask;
        if (len == 1) counts.literal(@intCast(item >> item_shift)) else counts.match(len, item >> item_shift);
        i += len;
    }
    return counts;
}

/// Costs from a code's lengths; a symbol with none gets a high cost, so
/// the next pass can still take it.
fn setCostsFromLengths(costs: *Costs, lengths: *const block.Lengths) void {
    for (&costs.literal, lengths.litlen[0..256]) |*cost, len| cost.* = @as(u32, if (len != 0) len else literal_unused_bits) * bit_cost;
    for (match.min_match..match.max_match + 1) |len| {
        const slot = lengthSlot(@intCast(len));
        const code_len: u32 = lengths.litlen[257 + slot];
        costs.length[len] = ((if (code_len != 0) code_len else length_unused_bits) + decode.length_extra[slot]) * bit_cost;
    }
    for (&costs.offset, lengths.dist[0..30], decode.dist_extra) |*cost, len, extra| cost.* = (@as(u32, if (len != 0) len else offset_unused_bits) + extra) * bit_cost;
}

/// The first pass's costs: defaults from the block's literals and the
/// greedy parse's match lengths, mixed with the last block's costs as far
/// as the blocks look alike.
fn setInitialCosts(o: *State, stats: *const split.Splitter, bytes: []const u8, params: Params) void {
    // Distinct literals, ignoring the rarest.
    var counts: [256]u32 = @splat(0);
    for (bytes) |byte| counts[byte] += 1;
    const cutoff = bytes.len >> 11;
    var used: u32 = 0;
    for (counts) |count| used += @intFromBool(count > cutoff);
    used = @max(used, 1);
    // How likely matches are, from a greedy parse's lengths.
    var literal_freq: i64 = @intCast(bytes.len);
    var match_freq: i64 = 0;
    var len = chooseMinLen(used, params.depth);
    while (len <= match.max_match) : (len += 1) {
        match_freq += o.lens[len];
        literal_freq -= @as(i64, len) * o.lens[len];
    }
    literal_freq = @max(literal_freq, 0);
    const which: usize = if (match_freq > literal_freq) 2 else if (match_freq * 4 > literal_freq) 1 else 0;
    const literal_cost: u32 = default_literal[which][used];
    const length_cost: u32 = default_length_symbol[which];
    if (o.first_block) return setDefaultCosts(&o.costs, literal_cost, length_cost);
    // How far this block's observations differ from the last block's.
    var delta: u64 = 0;
    for (o.prev_seen, stats.seen) |prev, now| {
        const a = @as(u64, prev) * stats.n_seen;
        const b = @as(u64, now) * o.prev_n;
        delta += if (a > b) a - b else b - a;
    }
    const limit = @as(u64, o.prev_n) * stats.n_seen * 200 / 512;
    if (delta > 3 * limit) return setDefaultCosts(&o.costs, literal_cost, length_cost);
    const change: u2 = if (4 * delta > 9 * limit) 3 else if (2 * delta > 3 * limit) 2 else if (2 * delta > limit) 1 else 0;
    for (&o.costs.literal) |*cost| adjust(cost, literal_cost, change);
    for (match.min_match..match.max_match + 1) |l| adjust(&o.costs.length[l], defaultLengthCost(@intCast(l), length_cost), change);
    for (&o.costs.offset, 0..) |*cost, slot| adjust(cost, defaultOffsetCost(slot), change);
}

/// Mix a cost with its default: the more the blocks differ, the more of
/// the default.
inline fn adjust(cost: *u32, default: u32, change: u2) void {
    cost.* = switch (change) {
        0 => (default + 3 * cost.*) / 4,
        1 => (default + cost.*) / 2,
        2 => (5 * default + 3 * cost.*) / 8,
        3 => (3 * default + cost.*) / 4,
    };
}

fn setDefaultCosts(costs: *Costs, literal_cost: u32, length_cost: u32) void {
    @memset(&costs.literal, literal_cost);
    for (match.min_match..match.max_match + 1) |len| costs.length[len] = defaultLengthCost(@intCast(len), length_cost);
    for (&costs.offset, 0..) |*cost, slot| cost.* = defaultOffsetCost(slot);
}

inline fn defaultLengthCost(len: u32, length_cost: u32) u32 {
    return length_cost + @as(u32, decode.length_extra[lengthSlot(len)]) * bit_cost;
}

/// Every offset symbol equally likely: -log2(1/30) bits, and its extra
/// bits.
inline fn defaultOffsetCost(slot: usize) u32 {
    return 4 * bit_cost + (907 * bit_cost) / 1000 + @as(u32, decode.dist_extra[slot]) * bit_cost;
}

/// Turn the path into the builder's sequences, counts and kept literals.
/// The sequences lie over the nodes' memory: the walk writes sequence `j`
/// only after reading every node up to the `j`-th match's, at least `3j`.
fn emitPath(c: anytype, o: *State, h: match.History, start: usize, length: usize, literals_only: bool) void {
    const b = c.b;
    const keep = @TypeOf(c.*).keeps_literals;
    b.n = 0;
    b.n_lits = 0;
    b.counts = .{};
    if (literals_only) {
        for (h.in[start..][0..length]) |byte| {
            b.counts.literal(byte);
            if (keep) {
                b.lits[b.n_lits] = byte;
                b.n_lits += 1;
            }
        }
        c.run = @intCast(length);
        return;
    }
    var run: u32 = 0;
    var i: usize = 0;
    while (i < length) {
        const item = o.nodes[i].item;
        const len = item & item_mask;
        if (len == 1) {
            const byte: u8 = @intCast(item >> item_shift);
            b.counts.literal(byte);
            if (keep) {
                b.lits[b.n_lits] = byte;
                b.n_lits += 1;
            }
            run += 1;
        } else {
            const distance = item >> item_shift;
            b.counts.match(len, distance);
            b.seqs[b.n] = .{ .literals = run, .length = @intCast(len), .distance = @intCast(distance) };
            b.n += 1;
            run = 0;
        }
        i += len;
    }
    c.run = run;
}

/// The longest match a position can have: 258, or what is left.
inline fn maxLen(n: usize, p: usize) u32 {
    return @intCast(@min(match.max_match, n - p));
}

/// The shortest match worth counting in the statistics, from how many
/// distinct literals the data has: few literals make short matches poor
/// (the reference's table).
fn minMatchLen(bytes: []const u8, depth: u32) u32 {
    // Very short blocks often suit the fixed code, which takes any match.
    if (bytes.len < 512) return match.min_match;
    var used: [256]bool = @splat(false);
    for (bytes[0..@min(bytes.len, 4096)]) |byte| used[byte] = true;
    var count: u32 = 0;
    for (used) |u| count += @intFromBool(u);
    return chooseMinLen(count, depth);
}

fn chooseMinLen(used: u32, depth: u32) u32 {
    const by_used = [_]u8{
        9, 9, 9, 9, 9, 9, 8, 8, 7, 7, 6, 6, 6, 6, 6, 6,
        5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
        5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 4, 4, 4,
        4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
        4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4, 4,
    };
    if (used >= by_used.len) return match.min_match;
    var min_len: u32 = by_used[used];
    // A shallow search finds few long matches.
    if (depth < 16) min_len = @min(min_len, if (depth < 5) @as(u32, 4) else if (depth < 10) @as(u32, 5) else 7);
    return min_len;
}
