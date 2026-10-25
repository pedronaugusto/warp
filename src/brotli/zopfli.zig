//! Qualities 10-11: the reference encoder's Zopfli-class parsing. Every
//! position's matches (H10's tree, nearby short matches, the static
//! dictionary) feed a shortest-path search over the block, costs in
//! single precision from a model of the literals (and, at quality 11, a
//! second pass with the first pass's commands), the last distances of each
//! path start tracked through shortcuts. Quality 11 finds all matches
//! first and searches twice; quality 10 searches once as it goes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const command = @import("command.zig");
const cost = @import("cost.zig");
const settings = @import("settings.zig");
const hash = @import("hash.zig");
const tree = @import("tree.zig");
const backward = @import("backward.zig");
const blocks = @import("blocks.zig");
const find = @import("find.zig");
const literal_cost = @import("literal_cost.zig");

const Command = command.Command;
const BackwardMatch = find.BackwardMatch;
const H10 = tree.H10;

const max_effective_distance_alphabet = 544;
const infinity: f32 = 1.7e38;
const long_copy_quick_step = 16384;
const max_zopfli_len_10 = 150;
const max_zopfli_len_11 = 325;

const distance_cache_index = [16]u32{ 0, 1, 2, 3, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1 };
const distance_cache_offset = [16]i32{ 0, 0, 0, 0, -1, 1, -2, 2, -3, 3, -1, 1, -2, 2, -3, 3 };

fn maxZopfliLen(p: *const settings.Resolved) usize {
    return if (p.quality <= 10) max_zopfli_len_10 else max_zopfli_len_11;
}

fn maxZopfliCandidates(p: *const settings.Resolved) usize {
    return if (p.quality <= 10) 1 else 5;
}

pub const Node = struct {
    /// Copy length in the low 25 bits, `length + 9 - length code` above.
    length: u32,
    distance: u32,
    /// Insert length in the low 27 bits, the short distance code + 1 above.
    dcode_insert_length: u32,
    /// The cost to reach this position, then the next command's length
    /// along the path, or the shortcut to the last distance update.
    u: u32,

    const stub: Node = .{ .length = 1, .distance = 0, .dcode_insert_length = 0, .u = @bitCast(infinity) };

    inline fn cost(n: Node) f32 {
        return @bitCast(n.u);
    }

    inline fn copyLength(n: Node) u32 {
        return n.length & 0x1ffffff;
    }

    inline fn lengthCode(n: Node) u32 {
        return n.copyLength() + 9 - (n.length >> 25);
    }

    inline fn distanceCode(n: Node) u32 {
        const short_code = n.dcode_insert_length >> 27;
        return if (short_code == 0) n.distance + command.short_distance_codes - 1 else short_code - 1;
    }

    inline fn commandLength(n: Node) u32 {
        return n.copyLength() + (n.dcode_insert_length & 0x7ffffff);
    }
};

/// Memory the parsers keep between meta-blocks.
pub const Scratch = struct {
    nodes: []Node = &.{},
    matches: []BackwardMatch = &.{},
    num_matches: []u32 = &.{},
    literal_costs: []f32 = &.{},
    cost_dist: []f32 = &.{},
    model: ?*Model = null,

    pub fn deinit(s: *Scratch, gpa: Allocator) void {
        gpa.free(s.nodes);
        gpa.free(s.matches);
        gpa.free(s.num_matches);
        gpa.free(s.literal_costs);
        gpa.free(s.cost_dist);
        if (s.model) |m| gpa.destroy(m);
        s.* = .{};
    }
};

fn ensure(comptime T: type, gpa: Allocator, slot: *[]T, n: usize) Allocator.Error![]T {
    if (slot.len < n) {
        gpa.free(slot.*);
        slot.* = &.{};
        slot.* = try gpa.alloc(T, n);
    }
    return slot.*[0..n];
}

/// The histogram-based cost model.
pub const Model = struct {
    cost_cmd: [command.command_symbols]f32 = undefined,
    cost_dist: []f32 = &.{},
    distance_histogram_size: u32 = 0,
    /// Cumulative literal costs by position.
    literal_costs: []f32 = &.{},
    min_cost_cmd: f32 = 0,
    num_bytes: usize = 0,
    literal_histograms: [3 * 256]usize = undefined,
    histogram_literal: [command.literal_symbols]u32 = undefined,
    histogram_cmd: [command.command_symbols]u32 = undefined,
    histogram_dist: [max_effective_distance_alphabet]u32 = undefined,
    cost_literal: [command.literal_symbols]f32 = undefined,

    fn init(m: *Model, gpa: Allocator, scratch: *Scratch, dist: *const command.DistanceParams, num_bytes: usize) Allocator.Error!void {
        m.num_bytes = num_bytes;
        m.literal_costs = try ensure(f32, gpa, &scratch.literal_costs, num_bytes + 2);
        m.cost_dist = try ensure(f32, gpa, &scratch.cost_dist, dist.alphabet_size_limit);
        m.distance_histogram_size = dist.alphabet_size_limit;
    }

    inline fn commandCost(m: *const Model, code: u16) f32 {
        return m.cost_cmd[code];
    }

    inline fn distanceCost(m: *const Model, code: usize) f32 {
        return m.cost_dist[code];
    }

    inline fn literalCosts(m: *const Model, from: usize, to: usize) f32 {
        return m.literal_costs[to] - m.literal_costs[from];
    }

    /// Cumulative sums kept exact by carrying their rounding forward.
    fn accumulate(m: *Model, comptime from_symbols: bool, ring: []const u8, mask: usize, position: usize) void {
        const lc = m.literal_costs;
        var carry: f32 = 0;
        lc[0] = 0;
        for (0..m.num_bytes) |i| {
            if (from_symbols) {
                carry += m.cost_literal[ring[(position + i) & mask]];
            } else carry += lc[i + 1];
            lc[i + 1] = lc[i] + carry;
            carry -= lc[i + 1] - lc[i];
        }
    }

    fn setFromCommands(m: *Model, position: usize, ring: []const u8, mask: usize, cmds: []const Command, last_insert_len: usize) void {
        var pos = position - last_insert_len;
        @memset(&m.histogram_literal, 0);
        @memset(&m.histogram_cmd, 0);
        @memset(&m.histogram_dist, 0);
        for (cmds) |c| {
            const inslength = c.insert_len;
            const copylength = c.copyLen();
            const distcode = c.dist_prefix & 0x3ff;
            const cmdcode = c.cmd_prefix;
            m.histogram_cmd[cmdcode] += 1;
            if (cmdcode >= 128) m.histogram_dist[distcode] += 1;
            for (0..inslength) |j| m.histogram_literal[ring[(pos + j) & mask]] += 1;
            pos += inslength + copylength;
        }
        setCost(&m.histogram_literal, true, &m.cost_literal);
        setCost(&m.histogram_cmd, false, &m.cost_cmd);
        setCost(m.histogram_dist[0..m.distance_histogram_size], false, m.cost_dist);
        var min_cost_cmd = infinity;
        for (m.cost_cmd) |c| min_cost_cmd = @min(min_cost_cmd, c);
        m.min_cost_cmd = min_cost_cmd;
        m.accumulate(true, ring, mask, position);
    }

    fn setFromLiteralCosts(m: *Model, position: usize, ring: []const u8, mask: usize) void {
        literal_cost.estimate(position, m.num_bytes, mask, ring, &m.literal_histograms, m.literal_costs[1..]);
        m.accumulate(false, ring, mask, position);
        for (&m.cost_cmd, 0..) |*c, i| c.* = @floatCast(cost.fastLog2(11 + i));
        for (m.cost_dist[0..m.distance_histogram_size], 0..) |*c, i| c.* = @floatCast(cost.fastLog2(20 + i));
        m.min_cost_cmd = @floatCast(cost.fastLog2(11));
    }
};

fn setCost(histogram: []const u32, literal_histogram: bool, out: []f32) void {
    var sum: usize = 0;
    for (histogram) |h| sum += h;
    const log2sum: f32 = @floatCast(cost.fastLog2(sum));
    var missing_symbol_sum = sum;
    if (!literal_histogram) {
        for (histogram) |h| missing_symbol_sum += @intFromBool(h == 0);
    }
    const missing_symbol_cost: f32 = @as(f32, @floatCast(cost.fastLog2(missing_symbol_sum))) + 2;
    for (histogram, out[0..histogram.len]) |h, *c| {
        if (h == 0) {
            c.* = missing_symbol_cost;
            continue;
        }
        // Shannon bits, at least one.
        c.* = log2sum - @as(f32, @floatCast(cost.fastLog2(h)));
        if (c.* < 1) c.* = 1;
    }
}

inline fn updateNode(nodes: []Node, pos: usize, start_pos: usize, len: usize, len_code: usize, dist: usize, short_code: usize, c: f32) void {
    nodes[pos + len] = .{
        .length = @intCast(len | ((len + 9 - len_code) << 25)),
        .distance = @intCast(dist),
        .dcode_insert_length = @intCast((short_code << 27) | (pos - start_pos)),
        .u = @bitCast(c),
    };
}

const PosData = struct {
    pos: usize,
    distance_cache: [4]i32,
    costdiff: f32,
    cost: f32,
};

/// The 8 smallest cost differences with their positions, sorted.
const StartPosQueue = struct {
    q: [8]PosData = undefined,
    idx: usize = 0,

    fn size(s: *const StartPosQueue) usize {
        return @min(s.idx, 8);
    }

    fn push(s: *StartPosQueue, posdata: *const PosData) void {
        var offset = ~s.idx & 7;
        s.idx += 1;
        const len = s.size();
        s.q[offset] = posdata.*;
        // At most len - 1 adjacent swaps restore the order.
        for (1..len) |_| {
            if (s.q[offset & 7].costdiff > s.q[(offset + 1) & 7].costdiff) std.mem.swap(PosData, &s.q[offset & 7], &s.q[(offset + 1) & 7]);
            offset += 1;
        }
    }

    fn at(s: *const StartPosQueue, k: usize) *const PosData {
        return &s.q[(k -% s.idx) & 7];
    }
};

/// The shortest copy that can still lower some later position's cost.
fn minimumCopyLength(start_cost: f32, nodes: []const Node, num_bytes: usize, pos: usize) usize {
    var min_cost = start_cost;
    var len: usize = 2;
    var next_len_bucket: usize = 4;
    var next_len_offset: usize = 10;
    while (pos + len <= num_bytes and nodes[pos + len].cost() <= min_cost) {
        len += 1;
        if (len == next_len_offset) {
            // The next copy length code: one more extra bit.
            min_cost += 1.0;
            next_len_offset += next_len_bucket;
            next_len_bucket *= 2;
        }
    }
    return len;
}

/// The position whose command last updated the distances on the path to
/// `pos` (dictionary references and distance code 0 do not).
fn distanceShortcut(block_start: usize, pos: usize, max_backward_limit: usize, gap: usize, nodes: []const Node) u32 {
    const c_len = nodes[pos].copyLength();
    const i_len = nodes[pos].dcode_insert_length & 0x7ffffff;
    const dist = nodes[pos].distance;
    if (pos == 0) return 0;
    if (dist + c_len <= block_start + pos + gap and dist <= max_backward_limit + gap and nodes[pos].distanceCode() > 0) return @intCast(pos);
    return nodes[pos - c_len - i_len].u;
}

/// The last four distances at `pos` along the shortest path.
fn distanceCacheAt(pos: usize, starting: *const [16]i32, nodes: []const Node, out: *[4]i32) void {
    var idx: usize = 0;
    var p: usize = nodes[pos].u;
    while (idx < 4 and p > 0) {
        const i_len = nodes[p].dcode_insert_length & 0x7ffffff;
        const c_len = nodes[p].copyLength();
        out[idx] = @intCast(nodes[p].distance);
        idx += 1;
        p = nodes[p - c_len - i_len].u;
    }
    var s: usize = 0;
    while (idx < 4) : (idx += 1) {
        out[idx] = starting[s];
        s += 1;
    }
}

fn evaluateNode(block_start: usize, pos: usize, max_backward_limit: usize, gap: usize, starting: *const [16]i32, model: *const Model, queue: *StartPosQueue, nodes: []Node) void {
    // The shortcut overwrites the cost.
    const node_cost = nodes[pos].cost();
    nodes[pos].u = distanceShortcut(block_start, pos, max_backward_limit, gap, nodes);
    if (node_cost <= model.literalCosts(0, pos)) {
        var posdata: PosData = .{ .pos = pos, .cost = node_cost, .costdiff = node_cost - model.literalCosts(0, pos), .distance_cache = undefined };
        distanceCacheAt(pos, starting, nodes, &posdata.distance_cache);
        queue.push(&posdata);
    }
}

/// Relax the nodes reachable from `pos`; returns the longest copy.
fn updateNodes(num_bytes: usize, block_start: usize, pos: usize, ring: []const u8, mask: usize, params: *const settings.Resolved, max_backward_limit: usize, starting: *const [16]i32, matches: []const BackwardMatch, model: *const Model, queue: *StartPosQueue, nodes: []Node) usize {
    const stream_offset = params.stream_offset;
    const cur_ix = block_start + pos;
    const cur = cur_ix & mask;
    const max_distance = @min(cur_ix, max_backward_limit);
    const dictionary_start = @min(cur_ix + stream_offset, max_backward_limit);
    const max_len = num_bytes - pos;
    const max_zopfli_len = maxZopfliLen(params);
    const max_iters = maxZopfliCandidates(params);
    const gap: usize = if (params.dictionary) |d| d.total_size else 0;
    var result: usize = 0;
    evaluateNode(block_start + stream_offset, pos, max_backward_limit, gap, starting, model, queue, nodes);
    const min_len = blk: {
        const posdata = queue.at(0);
        const min_cost = posdata.cost + model.min_cost_cmd + model.literalCosts(posdata.pos, pos);
        break :blk minimumCopyLength(min_cost, nodes, num_bytes, pos);
    };
    // Command starts in order of increasing cost difference.
    var k: usize = 0;
    while (k < max_iters and k < queue.size()) : (k += 1) {
        const posdata = queue.at(k);
        const start = posdata.pos;
        const inscode = command.insertCode(pos - start);
        const start_costdiff = posdata.costdiff;
        const base_cost = start_costdiff + @as(f32, @floatFromInt(command.insert_extra[inscode])) + model.literalCosts(0, pos);
        // Last-distance matches with this start's distances.
        var best_len = min_len - 1;
        var j: usize = 0;
        while (j < command.short_distance_codes and best_len < max_len) : (j += 1) {
            const idx = distance_cache_index[j];
            const bk: usize = @bitCast(@as(isize, posdata.distance_cache[idx] + distance_cache_offset[j]));
            var prev_ix = cur_ix -% bk;
            var len: usize = 0;
            const continuation = ring[cur + best_len];
            if (cur + best_len > mask) break;
            // Word dictionary: not here.
            if (bk > dictionary_start + gap) continue;
            if (bk <= max_distance) {
                if (prev_ix >= cur_ix) continue;
                prev_ix &= mask;
                if (prev_ix + best_len > mask or continuation != ring[prev_ix + best_len]) continue;
                len = find.matchLength(ring, prev_ix, cur, max_len);
            } else if (bk > dictionary_start) {
                const d = params.dictionary.?;
                len = d.matchAt(ring[cur..], dictionary_start, bk, best_len, max_len, continuation) orelse continue;
            } else {
                // Addressable by a decoder, but not held here.
                continue;
            }
            const dist_cost = base_cost + model.distanceCost(j);
            var l = best_len + 1;
            while (l <= len) : (l += 1) {
                const copycode = command.copyCode(l);
                const cmdcode = command.combineCodes(inscode, copycode, j == 0);
                const c = (if (cmdcode < 128) base_cost else dist_cost) + @as(f32, @floatFromInt(command.copy_extra[copycode])) + model.commandCost(cmdcode);
                if (c < nodes[pos + l].cost()) {
                    updateNode(nodes, pos, start, l, l, bk, j + 1, c);
                    result = @max(result, l);
                }
                best_len = l;
            }
        }
        // Past the first two starts, only new last-distance matches help.
        if (k >= 2) continue;
        var len = min_len;
        for (matches) |match| {
            const dist: usize = match.distance;
            const is_dictionary_match = dist > dictionary_start + gap;
            // The last distances were all tried: a plain distance code.
            const dist_code = dist + command.short_distance_codes - 1;
            const dp = command.prefixEncodeDistance(dist_code, params.dist.direct_codes, @intCast(params.dist.postfix_bits));
            const distnumextra = dp.prefix >> 10;
            const dist_cost = base_cost + @as(f32, @floatFromInt(distnumextra)) + model.distanceCost(dp.prefix & 0x3ff);
            // Every length up to the match's, or only it for a dictionary
            // word or a long match.
            const max_match_len = match.length();
            if (len < max_match_len and (is_dictionary_match or max_match_len > max_zopfli_len)) len = max_match_len;
            while (len <= max_match_len) : (len += 1) {
                const len_code = if (is_dictionary_match) match.lengthCode() else len;
                const copycode = command.copyCode(len_code);
                const cmdcode = command.combineCodes(inscode, copycode, false);
                const c = dist_cost + @as(f32, @floatFromInt(command.copy_extra[copycode])) + model.commandCost(cmdcode);
                if (c < nodes[pos + len].cost()) {
                    updateNode(nodes, pos, start, len, len_code, dist, 0, c);
                    result = @max(result, len);
                }
            }
        }
    }
    return result;
}

fn shortestPathFromNodes(num_bytes: usize, nodes: []Node) usize {
    var index = num_bytes;
    var num_commands: usize = 0;
    while (nodes[index].dcode_insert_length & 0x7ffffff == 0 and nodes[index].length == 1) index -= 1;
    nodes[index].u = std.math.maxInt(u32);
    while (index != 0) {
        const len = nodes[index].commandLength();
        index -= len;
        nodes[index].u = len;
        num_commands += 1;
    }
    return num_commands;
}

fn createCommands(num_bytes: usize, block_start: usize, nodes: []const Node, dist_cache: *[16]i32, last_insert_len: *usize, params: *const settings.Resolved, commands: []Command, num_literals: *usize) void {
    const stream_offset = params.stream_offset;
    const max_backward_limit = (@as(usize, 1) << params.lgwin) - 16;
    const gap: usize = if (params.dictionary) |d| d.total_size else 0;
    var pos: usize = 0;
    var offset: u32 = nodes[0].u;
    var i: usize = 0;
    while (offset != std.math.maxInt(u32)) : (i += 1) {
        const next = &nodes[pos + offset];
        const copy_length = next.copyLength();
        var insert_length: usize = next.dcode_insert_length & 0x7ffffff;
        pos += insert_length;
        offset = next.u;
        if (i == 0) {
            insert_length += last_insert_len.*;
            last_insert_len.* = 0;
        }
        const distance = next.distance;
        const len_code = next.lengthCode();
        const dictionary_start = @min(block_start + pos + stream_offset, max_backward_limit);
        const is_dictionary = distance > dictionary_start + gap;
        const dist_code = next.distanceCode();
        commands[i] = .init(&params.dist, insert_length, copy_length, @as(i32, @intCast(len_code)) - @as(i32, @intCast(copy_length)), dist_code);
        if (!is_dictionary and dist_code > 0) {
            dist_cache[3] = dist_cache[2];
            dist_cache[2] = dist_cache[1];
            dist_cache[1] = dist_cache[0];
            dist_cache[0] = @intCast(distance);
        }
        num_literals.* += insert_length;
        pos += copy_length;
    }
    last_insert_len.* += num_bytes - pos;
}

fn initNodes(nodes: []Node) void {
    @memset(nodes, Node.stub);
}

fn h10Of(hasher: *hash.Hasher) *H10 {
    return &hasher.impl.h10;
}

fn modelOf(gpa: Allocator, scratch: *Scratch) Allocator.Error!*Model {
    if (scratch.model == null) {
        const m = try gpa.create(Model);
        m.* = .{};
        scratch.model = m;
    }
    return scratch.model.?;
}

/// Quality 10: matches found as the search goes, one pass.
pub fn create(gpa: Allocator, scratch: *Scratch, num_bytes_in: u32, position_in: u32, ring: []const u8, mask_in: u32, mode: anytype, params: *const settings.Resolved, hasher: *hash.Hasher, dist_cache: *[16]i32, out: *backward.Out) Allocator.Error!void {
    _ = mode;
    const num_bytes: usize = num_bytes_in;
    const position: usize = position_in;
    const mask: usize = mask_in;
    const nodes = try ensure(Node, gpa, &scratch.nodes, num_bytes + 1);
    initNodes(nodes);
    const h = h10Of(hasher);
    const stream_offset = params.stream_offset;
    const max_backward_limit = (@as(usize, 1) << params.lgwin) - 16;
    const max_zopfli_len = maxZopfliLen(params);
    const matches_all = try ensure(BackwardMatch, gpa, &scratch.matches, 2 * (tree.max_num_matches + 64));
    const store_end = if (num_bytes >= H10.store_lookahead) position + num_bytes - H10.store_lookahead + 1 else position;
    const gap: usize = if (params.dictionary) |d| d.total_size else 0;
    const lz_matches_offset: usize = if (params.dictionary != null) tree.max_num_matches + 128 else 0;
    const model = try modelOf(gpa, scratch);
    nodes[0].length = 0;
    nodes[0].u = @bitCast(@as(f32, 0));
    try model.init(gpa, scratch, &params.dist, num_bytes);
    model.setFromLiteralCosts(position, ring, mask);
    var queue: StartPosQueue = .{};
    var i: usize = 0;
    while (i + H10.hash_type_length - 1 < num_bytes) : (i += 1) {
        const pos = position + i;
        const max_distance = @min(pos, max_backward_limit);
        const dictionary_start = @min(pos + stream_offset, max_backward_limit);
        var num_matches = h.findAllMatches(ring, mask, pos, num_bytes - i, max_distance, dictionary_start + gap, params, matches_all[lz_matches_offset..].ptr);
        if (params.dictionary) |d| {
            const cd = d.findAll(ring, mask, pos, 3, num_bytes - i, dictionary_start, params.dist.max_distance, matches_all[lz_matches_offset - 64 ..][0..64]);
            mergeMatches(matches_all, matches_all[lz_matches_offset - 64 ..][0..cd], matches_all[lz_matches_offset..][0..num_matches]);
            num_matches += cd;
        }
        const matches = matches_all[0..num_matches];
        var n = num_matches;
        if (n > 0 and matches[n - 1].length() > max_zopfli_len) {
            matches[0] = matches[n - 1];
            n = 1;
        }
        var skip = updateNodes(num_bytes, position, i, ring, mask, params, max_backward_limit, dist_cache, matches[0..n], model, &queue, nodes);
        if (skip < long_copy_quick_step) skip = 0;
        if (n == 1 and matches[0].length() > max_zopfli_len) skip = @max(matches[0].length(), skip);
        if (skip > 1) {
            // The copy's tail into the hasher.
            h.storeRange(ring, mask, pos + 1, @min(pos + skip, store_end));
            skip -= 1;
            while (skip != 0) : (skip -= 1) {
                i += 1;
                if (i + H10.hash_type_length - 1 >= num_bytes) break;
                evaluateNode(position + stream_offset, i, max_backward_limit, gap, dist_cache, model, &queue, nodes);
            }
        }
    }
    out.num_commands = shortestPathFromNodes(num_bytes, nodes);
    createCommands(num_bytes, position, nodes, dist_cache, out.last_insert_len, params, out.commands, out.num_literals);
}

fn mergeMatches(dst: []BackwardMatch, src1: []const BackwardMatch, src2: []const BackwardMatch) void {
    var a: usize = 0;
    var b: usize = 0;
    var o: usize = 0;
    while (a < src1.len and b < src2.len) : (o += 1) {
        const l1 = src1[a].length();
        const l2 = src2[b].length();
        if (l1 < l2 or (l1 == l2 and src1[a].distance < src2[b].distance)) {
            dst[o] = src1[a];
            a += 1;
        } else {
            dst[o] = src2[b];
            b += 1;
        }
    }
    while (a < src1.len) : (a += 1) {
        dst[o] = src1[a];
        o += 1;
    }
    while (b < src2.len) : (b += 1) {
        dst[o] = src2[b];
        o += 1;
    }
}

fn iterate(num_bytes: usize, position: usize, ring: []const u8, mask: usize, params: *const settings.Resolved, gap: usize, dist_cache: *const [16]i32, model: *const Model, num_matches: []const u32, matches: []const BackwardMatch, nodes: []Node) usize {
    const stream_offset = params.stream_offset;
    const max_backward_limit = (@as(usize, 1) << params.lgwin) - 16;
    const max_zopfli_len = maxZopfliLen(params);
    var queue: StartPosQueue = .{};
    var cur_match_pos: usize = 0;
    nodes[0].length = 0;
    nodes[0].u = @bitCast(@as(f32, 0));
    var i: usize = 0;
    while (i + 3 < num_bytes) : (i += 1) {
        var skip = updateNodes(num_bytes, position, i, ring, mask, params, max_backward_limit, dist_cache, matches[cur_match_pos..][0..num_matches[i]], model, &queue, nodes);
        if (skip < long_copy_quick_step) skip = 0;
        cur_match_pos += num_matches[i];
        if (num_matches[i] == 1 and matches[cur_match_pos - 1].length() > max_zopfli_len) skip = @max(matches[cur_match_pos - 1].length(), skip);
        if (skip > 1) {
            skip -= 1;
            while (skip != 0) : (skip -= 1) {
                i += 1;
                if (i + 3 >= num_bytes) break;
                evaluateNode(position + stream_offset, i, max_backward_limit, gap, dist_cache, model, &queue, nodes);
                cur_match_pos += num_matches[i];
            }
        }
    }
    return shortestPathFromNodes(num_bytes, nodes);
}

/// Quality 11: all matches first, then two searches, the second with the
/// first's commands as its cost model.
pub fn createHq(gpa: Allocator, scratch: *Scratch, num_bytes_in: u32, position_in: u32, ring: []const u8, mask_in: u32, mode: anytype, params: *const settings.Resolved, hasher: *hash.Hasher, dist_cache: *[16]i32, out: *backward.Out) Allocator.Error!void {
    _ = mode;
    const num_bytes: usize = num_bytes_in;
    const position: usize = position_in;
    const mask: usize = mask_in;
    const h = h10Of(hasher);
    const stream_offset = params.stream_offset;
    const max_backward_limit = (@as(usize, 1) << params.lgwin) - 16;
    const num_matches = try ensure(u32, gpa, &scratch.num_matches, num_bytes);
    var matches = try ensure(BackwardMatch, gpa, &scratch.matches, 4 * num_bytes);
    const store_end = if (num_bytes >= H10.store_lookahead) position + num_bytes - H10.store_lookahead + 1 else position;
    const gap: usize = if (params.dictionary) |d| d.total_size else 0;
    const shadow_matches: usize = if (params.dictionary != null) tree.max_num_matches + 128 else 0;
    var cur_match_pos: usize = 0;
    var i: usize = 0;
    while (i + H10.hash_type_length - 1 < num_bytes) : (i += 1) {
        const pos = position + i;
        const max_distance = @min(pos, max_backward_limit);
        const dictionary_start = @min(pos + stream_offset, max_backward_limit);
        const max_length = num_bytes - i;
        // Room for this position's matches.
        const room = cur_match_pos + tree.max_num_matches + shadow_matches;
        if (room > matches.len) {
            var size = matches.len;
            while (size < room) size *= 2;
            scratch.matches = try blocks.grow(BackwardMatch, gpa, scratch.matches, size, cur_match_pos);
            matches = scratch.matches;
        }
        var found = h.findAllMatches(ring, mask, pos, max_length, max_distance, dictionary_start + gap, params, matches[cur_match_pos + shadow_matches ..].ptr);
        if (params.dictionary) |d| {
            const cd = d.findAll(ring, mask, pos, 3, max_length, dictionary_start, params.dist.max_distance, matches[cur_match_pos + shadow_matches - 64 ..][0..64]);
            mergeMatches(matches[cur_match_pos..], matches[cur_match_pos + shadow_matches - 64 ..][0..cd], matches[cur_match_pos + shadow_matches ..][0..found]);
            found += cd;
        }
        const cur_match_end = cur_match_pos + found;
        num_matches[i] = @intCast(found);
        if (found > 0) {
            const match_len = matches[cur_match_end - 1].length();
            if (match_len > max_zopfli_len_11) {
                const skip = match_len - 1;
                matches[cur_match_pos] = matches[cur_match_end - 1];
                cur_match_pos += 1;
                num_matches[i] = 1;
                // The copy's tail into the hasher.
                h.storeRange(ring, mask, pos + 1, @min(pos + match_len, store_end));
                @memset(num_matches[i + 1 ..][0..skip], 0);
                i += skip;
            } else cur_match_pos = cur_match_end;
        }
    }
    const orig_num_literals = out.num_literals.*;
    const orig_last_insert_len = out.last_insert_len.*;
    const orig_dist_cache = dist_cache[0..4].*;
    const nodes = try ensure(Node, gpa, &scratch.nodes, num_bytes + 1);
    const model = try modelOf(gpa, scratch);
    try model.init(gpa, scratch, &params.dist, num_bytes);
    for (0..2) |pass| {
        initNodes(nodes);
        if (pass == 0) {
            model.setFromLiteralCosts(position, ring, mask);
        } else {
            model.setFromCommands(position, ring, mask, out.commands[0..out.num_commands], orig_last_insert_len);
        }
        out.num_literals.* = orig_num_literals;
        out.last_insert_len.* = orig_last_insert_len;
        dist_cache[0..4].* = orig_dist_cache;
        out.num_commands = iterate(num_bytes, position, ring, mask, params, gap, dist_cache, model, num_matches, matches, nodes);
        createCommands(num_bytes, position, nodes, dist_cache, out.last_insert_len, params, out.commands, out.num_literals);
    }
}
