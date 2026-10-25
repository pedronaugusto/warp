//! Qualities 10-11's meta-block builder, the reference encoder's: the
//! distance parameters (NPOSTFIX, NDIRECT) that code the distances in the
//! fewest bits, block splits per category from entropy codes refined on
//! samples and a shortest path through them, block clustering, histograms
//! per block type and context, and the histograms clustered into at most
//! 256 for the context maps.

const std = @import("std");
const Allocator = std.mem.Allocator;
const command = @import("command.zig");
const context = @import("context.zig");
const cost = @import("cost.zig");
const settings = @import("settings.zig");
const blocks = @import("blocks.zig");

const Command = command.Command;
const BlockSplit = blocks.BlockSplit;
const MetaBlockSplit = blocks.MetaBlockSplit;
const LiteralHistogram = command.LiteralHistogram;
const CommandHistogram = command.CommandHistogram;
const DistanceHistogram = command.DistanceHistogram;

const max_literal_histograms = 100;
const max_command_histograms = 50;
const literal_block_switch_cost = 28.1;
const command_block_switch_cost = 13.5;
const distance_block_switch_cost = 14.6;
const literal_stride_length = 70;
const command_stride_length = 40;
const distance_stride_length = 40;
const symbols_per_literal_histogram = 544;
const symbols_per_command_histogram = 530;
const symbols_per_distance_histogram = 544;
const min_length_for_block_splitting = 128;
const iter_mul_for_refining = 2;
const min_iters_for_refining = 100;
const histograms_per_batch = 64;
const clusters_per_batch = 16;
const invalid_index = std.math.maxInt(u32);

/// The reference's generator: from 7, a loop of 2^29.
inline fn myRand(seed: *u32) u32 {
    seed.* *%= 16807;
    return seed.*;
}

inline fn bitCost(count: usize) f64 {
    return if (count == 0) -2.0 else cost.fastLog2(count);
}

const HistogramPair = struct { idx1: u32, idx2: u32, cost_combo: f64, cost_diff: f64 };

fn pairIsLess(p1: *const HistogramPair, p2: *const HistogramPair) bool {
    if (p1.cost_diff != p2.cost_diff) return p1.cost_diff > p2.cost_diff;
    return (p1.idx2 -% p1.idx1) > (p2.idx2 -% p2.idx1);
}

/// The context map's entropy saved by merging clusters of these sizes.
fn clusterCostDiff(size_a: usize, size_b: usize) f64 {
    const size_c = size_a + size_b;
    const fa: f64 = @floatFromInt(size_a);
    const fb: f64 = @floatFromInt(size_b);
    const fc: f64 = @floatFromInt(size_c);
    // Fused as clang fuses the reference's.
    const t = cost.mulAdd(fa, cost.fastLog2(size_a), fb * cost.fastLog2(size_b));
    return cost.mulAdd(-fc, cost.fastLog2(size_c), t);
}

fn Clustering(comptime H: type) type {
    return struct {
        fn compareAndPushToQueue(out: []H, tmp: *H, cluster_size: []const u32, idx1_in: u32, idx2_in: u32, max_num_pairs: usize, pairs: []HistogramPair, num_pairs: *usize) void {
            if (idx1_in == idx2_in) return;
            const idx1 = @min(idx1_in, idx2_in);
            const idx2 = @max(idx1_in, idx2_in);
            var p: HistogramPair = .{ .idx1 = idx1, .idx2 = idx2, .cost_diff = 0, .cost_combo = 0 };
            p.cost_diff = 0.5 * clusterCostDiff(cluster_size[idx1], cluster_size[idx2]);
            p.cost_diff -= out[idx1].bit_cost;
            p.cost_diff -= out[idx2].bit_cost;
            var good = false;
            if (out[idx1].total == 0) {
                p.cost_combo = out[idx2].bit_cost;
                good = true;
            } else if (out[idx2].total == 0) {
                p.cost_combo = out[idx1].bit_cost;
                good = true;
            } else {
                const threshold: f64 = if (num_pairs.* == 0) 1e99 else @max(0.0, pairs[0].cost_diff);
                tmp.* = out[idx1];
                tmp.addHistogram(&out[idx2]);
                const cost_combo = cost.populationCost(H, tmp);
                if (cost_combo < threshold - p.cost_diff) {
                    p.cost_combo = cost_combo;
                    good = true;
                }
            }
            if (!good) return;
            p.cost_diff += p.cost_combo;
            if (num_pairs.* > 0 and pairIsLess(&pairs[0], &p)) {
                // The new best on top.
                if (num_pairs.* < max_num_pairs) {
                    pairs[num_pairs.*] = pairs[0];
                    num_pairs.* += 1;
                }
                pairs[0] = p;
            } else if (num_pairs.* < max_num_pairs) {
                pairs[num_pairs.*] = p;
                num_pairs.* += 1;
            }
        }

        fn combine(out: []H, tmp: *H, cluster_size: []u32, symbols: []u32, clusters: []u32, pairs: []HistogramPair, num_clusters_in: usize, symbols_size: usize, max_clusters: usize, max_num_pairs: usize) usize {
            var num_clusters = num_clusters_in;
            var cost_diff_threshold: f64 = 0;
            var min_cluster_size: usize = 1;
            var num_pairs: usize = 0;
            // The pair saving the most stays first.
            for (0..num_clusters) |idx1| {
                for (idx1 + 1..num_clusters) |idx2| compareAndPushToQueue(out, tmp, cluster_size, clusters[idx1], clusters[idx2], max_num_pairs, pairs, &num_pairs);
            }
            while (num_clusters > min_cluster_size) {
                if (pairs[0].cost_diff >= cost_diff_threshold) {
                    cost_diff_threshold = 1e99;
                    min_cluster_size = max_clusters;
                    continue;
                }
                const best_idx1 = pairs[0].idx1;
                const best_idx2 = pairs[0].idx2;
                out[best_idx1].addHistogram(&out[best_idx2]);
                out[best_idx1].bit_cost = pairs[0].cost_combo;
                cluster_size[best_idx1] += cluster_size[best_idx2];
                for (symbols[0..symbols_size]) |*s| {
                    if (s.* == best_idx2) s.* = best_idx1;
                }
                for (0..num_clusters) |i| {
                    if (clusters[i] == best_idx2) {
                        @memmove(clusters[i .. num_clusters - 1], clusters[i + 1 .. num_clusters]);
                        break;
                    }
                }
                num_clusters -= 1;
                // Pairs with either of the merged clusters go.
                var copy_to: usize = 0;
                for (0..num_pairs) |i| {
                    const p = pairs[i];
                    if (p.idx1 == best_idx1 or p.idx2 == best_idx1 or p.idx1 == best_idx2 or p.idx2 == best_idx2) continue;
                    if (pairIsLess(&pairs[0], &p)) {
                        const front = pairs[0];
                        pairs[0] = p;
                        pairs[copy_to] = front;
                    } else pairs[copy_to] = p;
                    copy_to += 1;
                }
                num_pairs = copy_to;
                for (clusters[0..num_clusters]) |c| compareAndPushToQueue(out, tmp, cluster_size, best_idx1, c, max_num_pairs, pairs, &num_pairs);
            }
            return num_clusters;
        }

        fn bitCostDistance(histogram: *const H, candidate: *const H, tmp: *H) f64 {
            if (histogram.total == 0) return 0.0;
            tmp.* = histogram.*;
            tmp.addHistogram(candidate);
            return cost.populationCost(H, tmp) - candidate.bit_cost;
        }

        fn remap(in: []const H, clusters: []const u32, out: []H, tmp: *H, symbols: []u32) void {
            for (in, 0..) |*h, i| {
                var best_out = if (i == 0) symbols[0] else symbols[i - 1];
                var best_bits = bitCostDistance(h, &out[best_out], tmp);
                for (clusters) |c| {
                    const cur = bitCostDistance(h, &out[c], tmp);
                    if (cur < best_bits) {
                        best_bits = cur;
                        best_out = c;
                    }
                }
                symbols[i] = best_out;
            }
            for (clusters) |c| out[c] = .empty;
            for (in, 0..) |*h, i| out[symbols[i]].addHistogram(h);
        }

        /// Renumber `symbols` in order of first use and move their
        /// histograms there; returns how many there are.
        fn reindex(gpa: Allocator, out: []H, symbols: []u32) Allocator.Error!usize {
            const new_index = try gpa.alloc(u32, symbols.len);
            defer gpa.free(new_index);
            @memset(new_index, invalid_index);
            var next: u32 = 0;
            for (symbols) |s| {
                if (new_index[s] == invalid_index) {
                    new_index[s] = next;
                    next += 1;
                }
            }
            const tmp = try gpa.alloc(H, next);
            defer gpa.free(tmp);
            next = 0;
            for (symbols) |*s| {
                if (new_index[s.*] == next) {
                    tmp[next] = out[s.*];
                    next += 1;
                }
                s.* = new_index[s.*];
            }
            @memcpy(out[0..next], tmp);
            return next;
        }

        /// Cluster `in` into at most `max_histograms` in `out`, the map from
        /// each to its cluster in `symbols`; returns the clusters' count.
        fn cluster(gpa: Allocator, in: []const H, max_histograms: usize, out: []H, symbols: []u32) Allocator.Error!usize {
            const in_size = in.len;
            const cluster_size = try gpa.alloc(u32, in_size);
            defer gpa.free(cluster_size);
            const clusters = try gpa.alloc(u32, in_size);
            defer gpa.free(clusters);
            const max_input_histograms = 64;
            var pairs_capacity: usize = max_input_histograms * max_input_histograms / 2;
            var pairs = try gpa.alloc(HistogramPair, pairs_capacity + 1);
            defer gpa.free(pairs);
            var tmp: H = undefined;
            @memset(cluster_size, 1);
            for (in, 0..) |*h, i| {
                out[i] = h.*;
                out[i].bit_cost = cost.populationCost(H, h);
                symbols[i] = @intCast(i);
            }
            var num_clusters: usize = 0;
            var i: usize = 0;
            while (i < in_size) : (i += max_input_histograms) {
                const n = @min(in_size - i, max_input_histograms);
                for (0..n) |j| clusters[num_clusters + j] = @intCast(i + j);
                num_clusters += combine(out, &tmp, cluster_size, symbols[i..], clusters[num_clusters..], pairs, n, n, max_histograms, pairs_capacity);
            }
            // The second pass limits the pairs kept; past that only the best
            // is looked for.
            const max_num_pairs = @min(64 * num_clusters, (num_clusters / 2) * num_clusters);
            if (pairs_capacity < max_num_pairs + 1) {
                var size = pairs_capacity;
                while (size < max_num_pairs + 1) size *= 2;
                pairs = try gpa.realloc(pairs, size);
                pairs_capacity = size;
            }
            num_clusters = combine(out, &tmp, cluster_size, symbols, clusters, pairs, num_clusters, in_size, max_histograms, max_num_pairs);
            remap(in, clusters[0..num_clusters], out, &tmp, symbols);
            return reindex(gpa, out, symbols);
        }
    };
}

/// The block splitter over one category's symbols.
fn Splitter(comptime T: type, comptime H: type) type {
    return struct {
        const C = Clustering(H);

        fn initialEntropyCodes(data: []const T, stride: usize, histograms: []H) void {
            var seed: u32 = 7;
            const n = histograms.len;
            const block_length = data.len / n;
            for (histograms) |*h| h.* = .empty;
            for (histograms, 0..) |*h, i| {
                var pos = data.len * i / n;
                if (i != 0) pos += myRand(&seed) % block_length;
                if (pos + stride >= data.len) pos = data.len - stride - 1;
                h.addVector(T, data[pos..][0..stride]);
            }
        }

        fn randomSample(seed: *u32, data: []const T, stride_in: usize, sample: *H) void {
            var stride = stride_in;
            var pos: usize = 0;
            if (stride >= data.len) {
                stride = data.len;
            } else pos = myRand(seed) % (data.len - stride + 1);
            sample.addVector(T, data[pos..][0..stride]);
        }

        fn refineEntropyCodes(data: []const T, stride: usize, histograms: []H, tmp: *H) void {
            const n = histograms.len;
            var iters = iter_mul_for_refining * data.len / stride + min_iters_for_refining;
            var seed: u32 = 7;
            iters = ((iters + n - 1) / n) * n;
            for (0..iters) |iter| {
                tmp.* = .empty;
                randomSample(&seed, data, stride, tmp);
                histograms[iter % n].addHistogram(tmp);
            }
        }

        /// A block id per symbol along the cheapest path with switches;
        /// returns the number of blocks.
        fn findBlocks(data: []const T, block_switch_bitcost: f64, histograms: []const H, insert_cost: []f64, costs: []f64, switch_signal: []u8, block_id: []u8) usize {
            const alphabet_size = H.symbols;
            const n = histograms.len;
            const bitmap_len = (n + 7) >> 3;
            var num_blocks: usize = 1;
            if (n <= 1) {
                @memset(block_id[0..data.len], 0);
                return 1;
            }
            // A missing symbol costs 2 + log2(total), others -log2(p).
            @memset(insert_cost[0 .. alphabet_size * n], 0);
            for (histograms, 0..) |*h, i| insert_cost[i] = cost.fastLog2(@as(u32, @truncate(h.total)));
            var i: usize = alphabet_size;
            while (i != 0) {
                // Backwards: row 0 holds the totals until last.
                i -= 1;
                for (0..n) |j| insert_cost[i * n + j] = insert_cost[j] - bitCost(histograms[j].data[i]);
            }
            // costs[k]: the cost of reaching here with code k less the least,
            // capped at the switch cost, where a switch is marked.
            @memset(costs[0..n], 0);
            @memset(switch_signal[0 .. data.len * bitmap_len], 0);
            for (data, 0..) |symbol, byte_ix| {
                const ix = byte_ix * bitmap_len;
                const insert_cost_ix = @as(usize, symbol) * n;
                var min_cost: f64 = 1e99;
                var block_switch_cost = block_switch_bitcost;
                const prologue_length = 2000;
                const multiplier = 0.07 / 2000.0;
                for (0..n) |k| {
                    costs[k] += insert_cost[insert_cost_ix + k];
                    if (costs[k] < min_cost) {
                        min_cost = costs[k];
                        block_id[byte_ix] = @intCast(k);
                    }
                }
                // More blocks at the start.
                if (byte_ix < prologue_length) block_switch_cost *= cost.mulAdd(multiplier, @floatFromInt(byte_ix), 0.77);
                for (0..n) |k| {
                    costs[k] -= min_cost;
                    if (costs[k] >= block_switch_cost) {
                        costs[k] = block_switch_cost;
                        switch_signal[ix + (k >> 3)] |= @as(u8, 1) << @intCast(k & 7);
                    }
                }
            }
            // Back from the end, switching where marked.
            var byte_ix = data.len - 1;
            var ix = byte_ix * bitmap_len;
            var cur_id = block_id[byte_ix];
            while (byte_ix > 0) {
                const mask = @as(u8, 1) << @intCast(cur_id & 7);
                byte_ix -= 1;
                ix -= bitmap_len;
                if (switch_signal[ix + (cur_id >> 3)] & mask != 0) {
                    if (cur_id != block_id[byte_ix]) {
                        cur_id = block_id[byte_ix];
                        num_blocks += 1;
                    }
                }
                block_id[byte_ix] = cur_id;
            }
            return num_blocks;
        }

        fn remapBlockIds(block_ids: []u8, new_id: []u16) usize {
            const invalid = 256;
            @memset(new_id, invalid);
            var next: u16 = 0;
            for (block_ids) |b| {
                if (new_id[b] == invalid) {
                    new_id[b] = next;
                    next += 1;
                }
            }
            for (block_ids) |*b| b.* = @intCast(new_id[b.*]);
            return next;
        }

        fn buildBlockHistograms(data: []const T, block_ids: []const u8, histograms: []H) void {
            for (histograms) |*h| h.* = .empty;
            for (data, block_ids) |d, b| histograms[b].add(d);
        }

        fn clusterBlocks(gpa: Allocator, data: []const T, num_blocks: usize, block_ids: []const u8, split: *BlockSplit) Allocator.Error!void {
            const length = data.len;
            const histogram_symbols = try gpa.alloc(u32, num_blocks);
            defer gpa.free(histogram_symbols);
            const block_lengths = try gpa.alloc(u32, num_blocks);
            defer gpa.free(block_lengths);
            @memset(block_lengths, 0);
            const expected = clusters_per_batch * (num_blocks + histograms_per_batch - 1) / histograms_per_batch;
            var all_histograms = try gpa.alloc(H, expected);
            defer gpa.free(all_histograms);
            var all_size: usize = 0;
            var cluster_size = try gpa.alloc(u32, expected);
            defer gpa.free(cluster_size);
            const histograms = try gpa.alloc(H, @min(num_blocks, histograms_per_batch));
            defer gpa.free(histograms);
            var max_num_pairs: usize = histograms_per_batch * histograms_per_batch / 2;
            var pairs = try gpa.alloc(HistogramPair, max_num_pairs + 1);
            defer gpa.free(pairs);
            var sizes: [histograms_per_batch]u32 = undefined;
            var new_clusters: [histograms_per_batch]u32 = undefined;
            var symbols: [histograms_per_batch]u32 = undefined;
            var remap: [histograms_per_batch]u32 = @splat(0);
            var tmp: [2]H = undefined;
            {
                var block_idx: usize = 0;
                for (0..length) |i| {
                    block_lengths[block_idx] += 1;
                    if (i + 1 == length or block_ids[i] != block_ids[i + 1]) block_idx += 1;
                }
                std.debug.assert(block_idx == num_blocks);
            }
            // Clusters within batches first.
            var num_clusters: usize = 0;
            var pos: usize = 0;
            var i: usize = 0;
            while (i < num_blocks) : (i += histograms_per_batch) {
                const n = @min(num_blocks - i, histograms_per_batch);
                for (0..n) |j| {
                    histograms[j] = .empty;
                    for (0..block_lengths[i + j]) |_| {
                        histograms[j].add(data[pos]);
                        pos += 1;
                    }
                    histograms[j].bit_cost = cost.populationCost(H, &histograms[j]);
                    new_clusters[j] = @intCast(j);
                    symbols[j] = @intCast(j);
                    sizes[j] = 1;
                }
                const num_new = C.combine(histograms, &tmp[0], &sizes, &symbols, &new_clusters, pairs, n, n, histograms_per_batch, max_num_pairs);
                if (all_size + num_new > all_histograms.len) {
                    var size = @max(all_histograms.len, 1);
                    while (size < all_size + num_new) size *= 2;
                    all_histograms = try blocks.grow(H, gpa, all_histograms, size, all_size);
                    cluster_size = try blocks.grow(u32, gpa, cluster_size, size, all_size);
                }
                for (0..num_new) |j| {
                    all_histograms[all_size] = histograms[new_clusters[j]];
                    cluster_size[all_size] = sizes[new_clusters[j]];
                    all_size += 1;
                    remap[new_clusters[j]] = @intCast(j);
                }
                for (0..n) |j| histogram_symbols[i + j] = @as(u32, @intCast(num_clusters)) + remap[symbols[j]];
                num_clusters += num_new;
            }
            // Then all together.
            max_num_pairs = @min(64 * num_clusters, (num_clusters / 2) * num_clusters);
            if (pairs.len < max_num_pairs + 1) {
                gpa.free(pairs);
                pairs = &.{};
                pairs = try gpa.alloc(HistogramPair, max_num_pairs + 1);
            }
            const clusters = try gpa.alloc(u32, num_clusters);
            defer gpa.free(clusters);
            for (clusters, 0..) |*c, k| c.* = @intCast(k);
            const num_final = C.combine(all_histograms, &tmp[0], cluster_size, histogram_symbols, clusters, pairs, num_clusters, num_blocks, command.max_block_types, max_num_pairs);
            // Each block to its best final histogram, the last used among
            // equals.
            const new_index = try gpa.alloc(u32, num_clusters);
            defer gpa.free(new_index);
            @memset(new_index, invalid_index);
            pos = 0;
            var next_index: u32 = 0;
            for (0..num_blocks) |b| {
                tmp[0] = .empty;
                for (0..block_lengths[b]) |_| {
                    tmp[0].add(data[pos]);
                    pos += 1;
                }
                var best_out = if (b == 0) histogram_symbols[0] else histogram_symbols[b - 1];
                var best_bits = C.bitCostDistance(&tmp[0], &all_histograms[best_out], &tmp[1]);
                for (clusters[0..num_final]) |c| {
                    const cur = C.bitCostDistance(&tmp[0], &all_histograms[c], &tmp[1]);
                    if (cur < best_bits) {
                        best_bits = cur;
                        best_out = c;
                    }
                }
                histogram_symbols[b] = best_out;
                if (new_index[best_out] == invalid_index) {
                    new_index[best_out] = next_index;
                    next_index += 1;
                }
            }
            try writeClusters(gpa, block_lengths, histogram_symbols, new_index, split);
        }

        /// The blocks with their final types: neighbours clustering gave
        /// one type are one block.
        fn writeClusters(gpa: Allocator, block_lengths: []const u32, histogram_symbols: []const u32, new_index: []const u32, split: *BlockSplit) Allocator.Error!void {
            const num_blocks = block_lengths.len;
            try split.ensure(gpa, num_blocks);
            var cur_length: u32 = 0;
            var block_idx: usize = 0;
            var max_type: u8 = 0;
            for (0..num_blocks) |b| {
                cur_length += block_lengths[b];
                if (b + 1 == num_blocks or histogram_symbols[b] != histogram_symbols[b + 1]) {
                    const id: u8 = @intCast(new_index[histogram_symbols[b]]);
                    split.types[block_idx] = id;
                    split.lengths[block_idx] = cur_length;
                    max_type = @max(max_type, id);
                    cur_length = 0;
                    block_idx += 1;
                }
            }
            split.num_blocks = block_idx;
            split.num_types = @as(usize, max_type) + 1;
        }

        fn splitByteVector(gpa: Allocator, data: []const T, symbols_per_histogram: usize, max_histograms: usize, stride: usize, block_switch_cost: f64, params: *const settings.Resolved, split: *BlockSplit) Allocator.Error!void {
            const length = data.len;
            var num_histograms = @min(length / symbols_per_histogram + 1, max_histograms);
            if (length == 0) {
                split.num_types = 1;
                return;
            }
            if (length < min_length_for_block_splitting) {
                try split.ensure(gpa, split.num_blocks + 1);
                split.num_types = 1;
                split.types[split.num_blocks] = 0;
                split.lengths[split.num_blocks] = @intCast(length);
                split.num_blocks += 1;
                return;
            }
            const histograms = try gpa.alloc(H, num_histograms + 1);
            defer gpa.free(histograms);
            const tmp = &histograms[num_histograms];
            initialEntropyCodes(data, stride, histograms[0..num_histograms]);
            refineEntropyCodes(data, stride, histograms[0..num_histograms], tmp);
            const block_ids = try gpa.alloc(u8, length);
            defer gpa.free(block_ids);
            const bitmap_len = (num_histograms + 7) >> 3;
            const insert_cost = try gpa.alloc(f64, H.symbols * num_histograms);
            defer gpa.free(insert_cost);
            const costs = try gpa.alloc(f64, num_histograms);
            defer gpa.free(costs);
            const switch_signal = try gpa.alloc(u8, length * bitmap_len);
            defer gpa.free(switch_signal);
            const new_id = try gpa.alloc(u16, num_histograms);
            defer gpa.free(new_id);
            const iters: usize = if (params.quality < 11) 3 else 10;
            var num_blocks: usize = 0;
            for (0..iters) |_| {
                num_blocks = findBlocks(data, block_switch_cost, histograms[0..num_histograms], insert_cost, costs, switch_signal, block_ids);
                num_histograms = remapBlockIds(block_ids, new_id[0..num_histograms]);
                buildBlockHistograms(data, block_ids, histograms[0..num_histograms]);
            }
            try clusterBlocks(gpa, data, num_blocks, block_ids, split);
        }
    };
}

fn splitBlock(gpa: Allocator, cmds: []const Command, data: []const u8, pos: usize, mask: usize, params: *const settings.Resolved, mb: *MetaBlockSplit) Allocator.Error!void {
    {
        var count: usize = 0;
        for (cmds) |c| count += c.insert_len;
        const literals = try gpa.alloc(u8, count);
        defer gpa.free(literals);
        // The literals in one run.
        var at: usize = 0;
        var from = pos & mask;
        for (cmds) |c| {
            var insert_len: usize = c.insert_len;
            if (from + insert_len > mask) {
                const head = mask + 1 - from;
                @memcpy(literals[at..][0..head], data[from..][0..head]);
                from = 0;
                at += head;
                insert_len -= head;
            }
            if (insert_len > 0) {
                @memcpy(literals[at..][0..insert_len], data[from..][0..insert_len]);
                at += insert_len;
            }
            from = (from + insert_len + c.copyLen()) & mask;
        }
        // At most 100 literal histograms: room for context modelling.
        try Splitter(u8, LiteralHistogram).splitByteVector(gpa, literals, symbols_per_literal_histogram, max_literal_histograms, literal_stride_length, literal_block_switch_cost, params, &mb.literal_split);
    }
    {
        const codes = try gpa.alloc(u16, cmds.len);
        defer gpa.free(codes);
        for (cmds, codes) |c, *o| o.* = c.cmd_prefix;
        try Splitter(u16, CommandHistogram).splitByteVector(gpa, codes, symbols_per_command_histogram, max_command_histograms, command_stride_length, command_block_switch_cost, params, &mb.command_split);
    }
    {
        const prefixes = try gpa.alloc(u16, cmds.len);
        defer gpa.free(prefixes);
        var j: usize = 0;
        for (cmds) |c| {
            if (c.copyLen() != 0 and c.cmd_prefix >= 128) {
                prefixes[j] = c.dist_prefix & 0x3ff;
                j += 1;
            }
        }
        try Splitter(u16, DistanceHistogram).splitByteVector(gpa, prefixes[0..j], symbols_per_distance_histogram, max_command_histograms, distance_stride_length, distance_block_switch_cost, params, &mb.distance_split);
    }
}

/// The distances' bits under `new` (the commands' codes are under `orig`);
/// null when one is past `new`'s reach.
fn distanceCost(cmds: []const Command, orig: *const command.DistanceParams, new: *const command.DistanceParams, tmp: *DistanceHistogram) ?f64 {
    const equal = orig.postfix_bits == new.postfix_bits and orig.direct_codes == new.direct_codes;
    var extra_bits: f64 = 0;
    tmp.* = .empty;
    for (cmds) |c| {
        if (c.copyLen() == 0 or c.cmd_prefix < 128) continue;
        var prefix: u16 = c.dist_prefix;
        if (!equal) {
            const distance = c.restoreDistanceCode(orig);
            if (distance > new.max_distance) return null;
            prefix = command.prefixEncodeDistance(distance, new.direct_codes, @intCast(new.postfix_bits)).prefix;
        }
        tmp.add(prefix & 0x3ff);
        extra_bits += @floatFromInt(prefix >> 10);
    }
    return cost.populationCost(DistanceHistogram, tmp) + extra_bits;
}

fn recomputeDistancePrefixes(cmds: []Command, orig: *const command.DistanceParams, new: *const command.DistanceParams) void {
    if (orig.postfix_bits == new.postfix_bits and orig.direct_codes == new.direct_codes) return;
    for (cmds) |*c| {
        if (c.copyLen() != 0 and c.cmd_prefix >= 128) {
            const d = command.prefixEncodeDistance(c.restoreDistanceCode(orig), new.direct_codes, @intCast(new.postfix_bits));
            c.dist_prefix = d.prefix;
            c.dist_extra = d.extra;
        }
    }
}

/// Literal and distance histograms per block type and context, commands
/// per block type, as the splits run.
fn buildHistogramsWithContext(cmds: []const Command, mb: *const MetaBlockSplit, ring: []const u8, start_pos: usize, mask: usize, prev_byte_in: u8, prev_byte2_in: u8, mode: ?context.Mode, literal: []LiteralHistogram, commands: []CommandHistogram, distance: []DistanceHistogram) void {
    const Iterator = struct {
        split: *const BlockSplit,
        idx: usize = 0,
        t: usize = 0,
        length: usize,

        fn init(s: *const BlockSplit) @This() {
            return .{ .split = s, .length = if (s.num_blocks != 0) s.lengths[0] else 0 };
        }

        fn next(it: *@This()) void {
            if (it.length == 0) {
                it.idx += 1;
                it.t = it.split.types[it.idx];
                it.length = it.split.lengths[it.idx];
            }
            it.length -= 1;
        }
    };
    var lit_it: Iterator = .init(&mb.literal_split);
    var cmd_it: Iterator = .init(&mb.command_split);
    var dist_it: Iterator = .init(&mb.distance_split);
    var pos = start_pos;
    var prev_byte = prev_byte_in;
    var prev_byte2 = prev_byte2_in;
    for (cmds) |c| {
        cmd_it.next();
        commands[cmd_it.t].add(c.cmd_prefix);
        for (0..c.insert_len) |_| {
            lit_it.next();
            var ctx = lit_it.t;
            if (mode) |m| {
                const lut = &context.lookup[@backingInt(m)];
                ctx = (ctx << command.literal_context_bits) + (lut[prev_byte] | lut[256 + @as(usize, prev_byte2)]);
            }
            const b = ring[pos & mask];
            literal[ctx].add(b);
            prev_byte2 = prev_byte;
            prev_byte = b;
            pos += 1;
        }
        pos += c.copyLen();
        if (c.copyLen() != 0) {
            prev_byte2 = ring[(pos - 2) & mask];
            prev_byte = ring[(pos - 1) & mask];
            if (c.cmd_prefix >= 128) {
                dist_it.next();
                distance[(dist_it.t << command.distance_context_bits) + c.distanceContext()].add(c.dist_prefix & 0x3ff);
            }
        }
    }
}

pub fn buildMetaBlock(gpa: Allocator, ring: []const u8, pos: usize, mask: usize, params: *settings.Resolved, prev_byte: u8, prev_byte2: u8, cmds: []Command, mode: context.Mode, mb: *MetaBlockSplit) Allocator.Error!void {
    // Histogram ids fit in a byte.
    const max_number_of_histograms = 256;
    const orig = params.dist;
    var best_dist_cost: f64 = 1e99;
    var check_orig = true;
    var tmp: DistanceHistogram = undefined;
    var ndirect_msb: u32 = 0;
    var npostfix: u32 = 0;
    while (npostfix <= 3) : (npostfix += 1) {
        while (ndirect_msb < 16) : (ndirect_msb += 1) {
            const ndirect = ndirect_msb << @intCast(npostfix);
            const new = command.initDistanceParams(npostfix, ndirect, params.large_window);
            if (npostfix == orig.postfix_bits and ndirect == orig.direct_codes) check_orig = false;
            const dc = distanceCost(cmds, &orig, &new, &tmp) orelse break;
            if (dc > best_dist_cost) break;
            best_dist_cost = dc;
            params.dist = new;
        }
        if (ndirect_msb > 0) ndirect_msb -= 1;
        ndirect_msb /= 2;
    }
    if (check_orig) {
        const dc = distanceCost(cmds, &orig, &orig, &tmp).?;
        if (dc < best_dist_cost) params.dist = orig;
    }
    recomputeDistancePrefixes(cmds, &orig, &params.dist);
    try splitBlock(gpa, cmds, ring, pos, mask, params, mb);
    const multiplier: usize = if (params.disable_literal_context_modeling) 1 else 1 << command.literal_context_bits;
    const literal_size = mb.literal_split.num_types * multiplier;
    const literal = try gpa.alloc(LiteralHistogram, literal_size);
    defer gpa.free(literal);
    @memset(literal, .empty);
    const distance_size = mb.distance_split.num_types << command.distance_context_bits;
    const distance = try gpa.alloc(DistanceHistogram, distance_size);
    defer gpa.free(distance);
    @memset(distance, .empty);
    mb.command_histograms = try gpa.alloc(CommandHistogram, mb.command_split.num_types);
    @memset(mb.command_histograms, .empty);
    buildHistogramsWithContext(cmds, mb, ring, pos, mask, prev_byte, prev_byte2, if (params.disable_literal_context_modeling) null else mode, literal, mb.command_histograms, distance);
    mb.literal_context_map = try gpa.alloc(u32, mb.literal_split.num_types << command.literal_context_bits);
    const lh = try gpa.alloc(LiteralHistogram, mb.literal_context_map.len);
    mb.literal_histograms = lh;
    // Without context modelling, the first entry of each block type's
    // contexts is clustered, then copied to the rest.
    const n_lit = try Clustering(LiteralHistogram).cluster(gpa, literal, max_number_of_histograms, lh, mb.literal_context_map[0..literal.len]);
    mb.literal_histograms = try blocks.shrink(LiteralHistogram, gpa, lh, n_lit);
    if (params.disable_literal_context_modeling) {
        // Each block type's histogram for all its contexts.
        var i = mb.literal_split.num_types;
        while (i != 0) {
            i -= 1;
            for (0..64) |j| mb.literal_context_map[(i << command.literal_context_bits) + j] = mb.literal_context_map[i];
        }
    }
    mb.distance_context_map = try gpa.alloc(u32, distance_size);
    const dh = try gpa.alloc(DistanceHistogram, distance_size);
    mb.distance_histograms = dh;
    const n_dist = try Clustering(DistanceHistogram).cluster(gpa, distance, max_number_of_histograms, dh, mb.distance_context_map);
    mb.distance_histograms = try blocks.shrink(DistanceHistogram, gpa, dh, n_dist);
}
