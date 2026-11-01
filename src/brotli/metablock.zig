//! Building and writing a meta-block from its commands, as the reference
//! encoder does: raw when it would not compress, the fast form at quality
//! 2, the trivial form at 3, and from 4 block splits with histograms per
//! block type: greedy (merging a block with the last or the one before when
//! that costs less, qualities 4-9, literal contexts from a static map at 5
//! and up) or the high-quality builder (qualities 10-11).

const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const bits = @import("bits.zig");
const command = @import("command.zig");
const context = @import("context.zig");
const cost = @import("cost.zig");
const entropy = @import("entropy.zig");
const tables = @import("tables.zig");
const store = @import("store.zig");
const settings = @import("settings.zig");
const zopfli = @import("zopfli.zig");
const split_hq = @import("split.zig");
const blocks = @import("blocks.zig");

const Writer = bits.Writer;
const BlockSplit = blocks.BlockSplit;
const MetaBlockSplit = blocks.MetaBlockSplit;
const shrink = blocks.shrink;
const isMostlyUtf8 = blocks.isMostlyUtf8;
const Command = command.Command;
const LiteralHistogram = command.LiteralHistogram;
const CommandHistogram = command.CommandHistogram;
const DistanceHistogram = command.DistanceHistogram;

pub const max_static_contexts = 13;
const min_utf8_ratio = 0.75;

/// Memory the meta-block writers keep between meta-blocks.
pub const Scratch = struct {
    zopfli: zopfli.Scratch = .{},
    simple: ?*store.SimpleArena = null,
    store: ?*store.StoreArena = null,

    pub fn deinit(s: *Scratch, gpa: Allocator) void {
        s.zopfli.deinit(gpa);
        if (s.simple) |a| gpa.destroy(a);
        if (s.store) |a| gpa.destroy(a);
    }
};

/// The literal context mode: signed for mostly non-UTF-8 input at
/// qualities 10-11, UTF-8 otherwise.
pub fn chooseContextMode(params: *const settings.Resolved, data: []const u8, pos: u32, mask: u32, length: usize) context.Mode {
    if (params.quality >= 10 and !isMostlyUtf8(data, pos, mask, length, min_utf8_ratio)) return .signed;
    return .utf8;
}

fn estimateEntropy(population: []const u32) f64 {
    var total: usize = 0;
    var r: f64 = 0;
    for (population) |p| {
        total += p;
        r = cost.mulAdd(@floatFromInt(p), cost.fastLog2(p), r);
    }
    return cost.mulAdd(@floatFromInt(total), cost.fastLog2(total), -r);
}

const StaticContexts = struct { num: usize = 1, map: ?*const [64]u32 = null };

/// One, two or three literal contexts by how well the previous byte's
/// UTF-8 class predicts the next's.
fn chooseContextMap(quality: u4, bigram: *const [9]u32) StaticContexts {
    var monogram: [3]u32 = @splat(0);
    var two_prefix: [6]u32 = @splat(0);
    for (0..9) |i| {
        monogram[i % 3] += bigram[i];
        two_prefix[i % 6] += bigram[i];
    }
    var e: [4]f64 = undefined;
    e[1] = estimateEntropy(&monogram);
    e[2] = estimateEntropy(two_prefix[0..3]) + estimateEntropy(two_prefix[3..6]);
    e[3] = 0;
    for (0..3) |i| e[3] += estimateEntropy(bigram[3 * i ..][0..3]);
    const total = monogram[0] + monogram[1] + monogram[2];
    std.debug.assert(total != 0);
    e[0] = 1.0 / @as(f64, @floatFromInt(total));
    e[1] *= e[0];
    e[2] *= e[0];
    e[3] *= e[0];
    // Three contexts decode more slowly: not below quality 7.
    if (quality < 7) e[3] = e[1] * 10;
    // Under 0.2 bits a symbol saved: no context modelling.
    if (e[1] - e[2] < 0.2 and e[1] - e[3] < 0.2) return .{};
    if (e[2] - e[3] < 0.02) return .{ .num = 2, .map = &tables.context_map_simple_utf8 };
    return .{ .num = 3, .map = &tables.context_map_continuation };
}

/// The 13-context map, for long inputs where it lowers the entropy of the
/// literals' top five bits enough.
fn complexStaticContextMap(input: []const u8, start_in: usize, length: usize, mask: usize, size_hint: usize) ?StaticContexts {
    if (size_hint < 1 << 20) return null;
    const end_pos = start_in + length;
    var combined: [32]u32 = @splat(0);
    var ctx_histo: [max_static_contexts * 32]u32 = @splat(0);
    var total: u32 = 0;
    const lut = &context.lookup[@backingInt(context.Mode.utf8)];
    var start = start_in;
    // 64-byte strides every 4 KiB.
    while (start + 64 <= end_pos) : (start += 4096) {
        var prev2 = input[start & mask];
        var prev1 = input[(start + 1) & mask];
        for (start + 2..start + 64) |pos| {
            const literal = input[pos & mask];
            const ctx = tables.context_map_complex_utf8[lut[prev1] | lut[256 + @as(usize, prev2)]];
            total += 1;
            combined[literal >> 3] += 1;
            ctx_histo[(ctx << 5) + (literal >> 3)] += 1;
            prev2 = prev1;
            prev1 = literal;
        }
    }
    var e: [3]f64 = undefined;
    e[1] = estimateEntropy(&combined);
    e[2] = 0;
    for (0..max_static_contexts) |i| e[2] += estimateEntropy(ctx_histo[i << 5 ..][0..32]);
    e[0] = 1.0 / @as(f64, @floatFromInt(total));
    e[1] *= e[0];
    e[2] *= e[0];
    // Tuned on silesia's files: skip input that compresses poorly with it
    // too (entropy above 3 bits) or saves under 0.2 bits a symbol.
    if (e[2] > 3.0 or e[1] - e[2] < 0.2) return null;
    return .{ .num = max_static_contexts, .map = &tables.context_map_complex_utf8 };
}

fn decideLiteralContextModeling(input: []const u8, start_in: usize, length: usize, mask: usize, quality: u4, size_hint: usize) StaticContexts {
    if (quality < 5 or length < 64) return .{};
    if (complexStaticContextMap(input, start_in, length, mask, size_hint)) |c| return c;
    // UTF-8 class bigrams in 64-byte strides every 4 KiB.
    const end_pos = start_in + length;
    var bigram: [9]u32 = @splat(0);
    const lut = [4]usize{ 0, 0, 1, 2 };
    var start = start_in;
    while (start + 64 <= end_pos) : (start += 4096) {
        var prev = lut[input[start & mask] >> 6] * 3;
        for (start + 1..start + 64) |pos| {
            const literal = input[pos & mask];
            bigram[prev + lut[literal >> 6]] += 1;
            prev = lut[literal >> 6] * 3;
        }
    }
    return chooseContextMap(quality, &bigram);
}

fn shouldCompress(data: []const u8, mask: usize, last_flush_pos: u64, bytes: usize, num_literals: usize, num_commands: usize) bool {
    if (bytes <= 2) return false;
    if (num_commands < (bytes >> 8) + 2 and @as(f64, @floatFromInt(num_literals)) > 0.99 * @as(f64, @floatFromInt(bytes))) {
        var literal_histo: [256]u32 = @splat(0);
        const sample_rate = 13;
        const min_entropy = 7.92;
        const threshold = @as(f64, @floatFromInt(bytes)) * min_entropy / sample_rate;
        const t = (bytes + sample_rate - 1) / sample_rate;
        var pos: u32 = @truncate(last_flush_pos);
        for (0..t) |_| {
            literal_histo[data[pos & mask]] += 1;
            pos +%= sample_rate;
        }
        if (cost.bitsEntropy(&literal_histo) > threshold) return false;
    }
    return true;
}

/// A plain block splitter (one histogram a block type) over an alphabet.
fn BlockSplitter(comptime H: type) type {
    return struct {
        const Self = @This();
        alphabet_size: usize,
        min_block_size: usize,
        split_threshold: f64,
        num_blocks: usize = 0,
        split: *BlockSplit,
        histograms: []H,
        combined: [2]H = undefined,
        target_block_size: usize,
        block_size: usize = 0,
        curr: usize = 0,
        last: [2]usize = .{ 0, 0 },
        last_entropy: [2]f64 = undefined,
        merge_last_count: usize = 0,

        fn init(gpa: Allocator, alphabet_size: usize, min_block_size: usize, split_threshold: f64, num_symbols: usize, split: *BlockSplit, histograms: *[]H) Allocator.Error!Self {
            const max_num_blocks = num_symbols / min_block_size + 1;
            // One more than the block types: the current one.
            const max_num_types = @min(max_num_blocks, command.max_block_types + 1);
            try split.ensure(gpa, max_num_blocks);
            split.num_blocks = max_num_blocks;
            histograms.* = try gpa.alloc(H, max_num_types);
            histograms.*[0] = .empty;
            return .{ .alphabet_size = alphabet_size, .min_block_size = min_block_size, .split_threshold = split_threshold, .split = split, .histograms = histograms.*, .target_block_size = min_block_size };
        }

        fn entropyOf(s: *const Self, h: *const H) f64 {
            return cost.bitsEntropy(h.data[0..s.alphabet_size]);
        }

        fn finishBlock(s: *Self, is_final: bool, histograms_size: *usize) void {
            const split = s.split;
            const hs = s.histograms;
            s.block_size = @max(s.block_size, s.min_block_size);
            if (s.num_blocks == 0) {
                split.lengths[0] = @intCast(s.block_size);
                split.types[0] = 0;
                s.last_entropy[0] = s.entropyOf(&hs[0]);
                s.last_entropy[1] = s.last_entropy[0];
                s.num_blocks += 1;
                split.num_types += 1;
                s.curr += 1;
                if (s.curr < hs.len) hs[s.curr] = .empty;
                s.block_size = 0;
            } else if (s.block_size > 0) {
                const e = s.entropyOf(&hs[s.curr]);
                var combined_entropy: [2]f64 = undefined;
                var diff: [2]f64 = undefined;
                for (0..2) |j| {
                    s.combined[j] = hs[s.curr];
                    s.combined[j].addHistogram(&hs[s.last[j]]);
                    combined_entropy[j] = s.entropyOf(&s.combined[j]);
                    diff[j] = combined_entropy[j] - e - s.last_entropy[j];
                }
                if (split.num_types < command.max_block_types and diff[0] > s.split_threshold and diff[1] > s.split_threshold) {
                    // A new block type.
                    split.lengths[s.num_blocks] = @intCast(s.block_size);
                    split.types[s.num_blocks] = @intCast(split.num_types);
                    s.last[1] = s.last[0];
                    s.last[0] = @as(u8, @intCast(split.num_types));
                    s.last_entropy[1] = s.last_entropy[0];
                    s.last_entropy[0] = e;
                    s.num_blocks += 1;
                    split.num_types += 1;
                    s.curr += 1;
                    if (s.curr < hs.len) hs[s.curr] = .empty;
                    s.block_size = 0;
                    s.merge_last_count = 0;
                    s.target_block_size = s.min_block_size;
                } else if (diff[1] < diff[0] - 20.0) {
                    // The second last block's type.
                    split.lengths[s.num_blocks] = @intCast(s.block_size);
                    split.types[s.num_blocks] = split.types[s.num_blocks - 2];
                    std.mem.swap(usize, &s.last[0], &s.last[1]);
                    hs[s.last[0]] = s.combined[1];
                    s.last_entropy[1] = s.last_entropy[0];
                    s.last_entropy[0] = combined_entropy[1];
                    s.num_blocks += 1;
                    s.block_size = 0;
                    hs[s.curr] = .empty;
                    s.merge_last_count = 0;
                    s.target_block_size = s.min_block_size;
                } else {
                    // Merged into the last block.
                    split.lengths[s.num_blocks - 1] += @intCast(s.block_size);
                    hs[s.last[0]] = s.combined[0];
                    s.last_entropy[0] = combined_entropy[0];
                    if (split.num_types == 1) s.last_entropy[1] = s.last_entropy[0];
                    s.block_size = 0;
                    hs[s.curr] = .empty;
                    s.merge_last_count += 1;
                    if (s.merge_last_count > 1) s.target_block_size += s.min_block_size;
                }
            }
            if (is_final) {
                histograms_size.* = split.num_types;
                split.num_blocks = s.num_blocks;
            }
        }

        inline fn addSymbol(s: *Self, symbol: usize) void {
            s.histograms[s.curr].add(symbol);
            s.block_size += 1;
            if (s.block_size == s.target_block_size) s.finishBlock(false, undefined);
        }
    };
}

/// A literal block splitter over the static map's contexts.
const ContextBlockSplitter = struct {
    alphabet_size: usize,
    num_contexts: usize,
    max_block_types: usize,
    min_block_size: usize,
    split_threshold: f64,
    num_blocks: usize = 0,
    split: *BlockSplit,
    histograms: []LiteralHistogram,
    target_block_size: usize,
    block_size: usize = 0,
    curr: usize = 0,
    last: [2]usize = .{ 0, 0 },
    last_entropy: [2 * max_static_contexts]f64 = undefined,
    merge_last_count: usize = 0,
    combined: [2 * max_static_contexts]LiteralHistogram = undefined,

    fn init(gpa: Allocator, alphabet_size: usize, num_contexts: usize, min_block_size: usize, split_threshold: f64, num_symbols: usize, split: *BlockSplit, histograms: *[]LiteralHistogram) Allocator.Error!ContextBlockSplitter {
        const max_num_blocks = num_symbols / min_block_size + 1;
        const max_block_types = command.max_block_types / num_contexts;
        const max_num_types = @min(max_num_blocks, max_block_types + 1);
        try split.ensure(gpa, max_num_blocks);
        split.num_blocks = max_num_blocks;
        histograms.* = try gpa.alloc(LiteralHistogram, max_num_types * num_contexts);
        for (histograms.*[0..num_contexts]) |*h| h.* = .empty;
        return .{ .alphabet_size = alphabet_size, .num_contexts = num_contexts, .max_block_types = max_block_types, .min_block_size = min_block_size, .split_threshold = split_threshold, .split = split, .histograms = histograms.*, .target_block_size = min_block_size };
    }

    fn clear(s: *ContextBlockSplitter, at: usize) void {
        for (s.histograms[at..][0..s.num_contexts]) |*h| h.* = .empty;
    }

    fn finishBlock(s: *ContextBlockSplitter, is_final: bool, histograms_size: *usize) void {
        const split = s.split;
        const n = s.num_contexts;
        const hs = s.histograms;
        const le = &s.last_entropy;
        if (s.block_size < s.min_block_size) s.block_size = s.min_block_size;
        if (s.num_blocks == 0) {
            split.lengths[0] = @intCast(s.block_size);
            split.types[0] = 0;
            for (0..n) |i| {
                le[i] = cost.bitsEntropy(hs[i].data[0..s.alphabet_size]);
                le[n + i] = le[i];
            }
            s.num_blocks += 1;
            split.num_types += 1;
            s.curr += n;
            if (s.curr < hs.len) s.clear(s.curr);
            s.block_size = 0;
        } else if (s.block_size > 0) {
            var e: [max_static_contexts]f64 = undefined;
            var combined_entropy: [2 * max_static_contexts]f64 = undefined;
            var diff: [2]f64 = .{ 0, 0 };
            for (0..n) |i| {
                const curr = s.curr + i;
                e[i] = cost.bitsEntropy(hs[curr].data[0..s.alphabet_size]);
                for (0..2) |j| {
                    const jx = j * n + i;
                    s.combined[jx] = hs[curr];
                    s.combined[jx].addHistogram(&hs[s.last[j] + i]);
                    combined_entropy[jx] = cost.bitsEntropy(s.combined[jx].data[0..s.alphabet_size]);
                    diff[j] += combined_entropy[jx] - e[i] - le[jx];
                }
            }
            if (split.num_types < s.max_block_types and diff[0] > s.split_threshold and diff[1] > s.split_threshold) {
                split.lengths[s.num_blocks] = @intCast(s.block_size);
                split.types[s.num_blocks] = @intCast(split.num_types);
                s.last[1] = s.last[0];
                s.last[0] = split.num_types * n;
                for (0..n) |i| {
                    le[n + i] = le[i];
                    le[i] = e[i];
                }
                s.num_blocks += 1;
                split.num_types += 1;
                s.curr += n;
                if (s.curr < hs.len) s.clear(s.curr);
                s.block_size = 0;
                s.merge_last_count = 0;
                s.target_block_size = s.min_block_size;
            } else if (diff[1] < diff[0] - 20.0) {
                split.lengths[s.num_blocks] = @intCast(s.block_size);
                split.types[s.num_blocks] = split.types[s.num_blocks - 2];
                std.mem.swap(usize, &s.last[0], &s.last[1]);
                for (0..n) |i| {
                    hs[s.last[0] + i] = s.combined[n + i];
                    le[n + i] = le[i];
                    le[i] = combined_entropy[n + i];
                    hs[s.curr + i] = .empty;
                }
                s.num_blocks += 1;
                s.block_size = 0;
                s.merge_last_count = 0;
                s.target_block_size = s.min_block_size;
            } else {
                split.lengths[s.num_blocks - 1] += @intCast(s.block_size);
                for (0..n) |i| {
                    hs[s.last[0] + i] = s.combined[i];
                    le[i] = combined_entropy[i];
                    if (split.num_types == 1) le[n + i] = le[i];
                    hs[s.curr + i] = .empty;
                }
                s.block_size = 0;
                s.merge_last_count += 1;
                if (s.merge_last_count > 1) s.target_block_size += s.min_block_size;
            }
        }
        if (is_final) {
            histograms_size.* = split.num_types * n;
            split.num_blocks = s.num_blocks;
        }
    }

    inline fn addSymbol(s: *ContextBlockSplitter, symbol: usize, ctx: usize) void {
        s.histograms[s.curr + ctx].add(symbol);
        s.block_size += 1;
        if (s.block_size == s.target_block_size) s.finishBlock(false, undefined);
    }
};

/// Qualities 4-9: greedy block splits for each category, and the static
/// context map's histograms for literals.
fn buildGreedy(gpa: Allocator, ring: []const u8, pos_in: usize, mask: usize, prev_byte_in: u8, prev_byte2_in: u8, mode: context.Mode, sc: StaticContexts, cmds: []const Command, mb: *MetaBlockSplit) Allocator.Error!void {
    var num_literals: usize = 0;
    for (cmds) |c| num_literals += c.insert_len;
    const lut = &context.lookup[@backingInt(mode)];
    var pos = pos_in;
    var prev_byte = prev_byte_in;
    var prev_byte2 = prev_byte2_in;
    var plain: BlockSplitter(LiteralHistogram) = undefined;
    var ctx: ContextBlockSplitter = undefined;
    const ctx_splitter = sc.num > 1;
    if (ctx_splitter) {
        ctx = try .init(gpa, 256, sc.num, 512, 400.0, num_literals, &mb.literal_split, &mb.literal_histograms);
    } else {
        plain = try .init(gpa, 256, 512, 400.0, num_literals, &mb.literal_split, &mb.literal_histograms);
    }
    var cmd_blocks: BlockSplitter(CommandHistogram) = try .init(gpa, command.command_symbols, 1024, 500.0, cmds.len, &mb.command_split, &mb.command_histograms);
    var dist_blocks: BlockSplitter(DistanceHistogram) = try .init(gpa, 64, 512, 100.0, cmds.len, &mb.distance_split, &mb.distance_histograms);
    for (cmds) |c| {
        cmd_blocks.addSymbol(c.cmd_prefix);
        for (0..c.insert_len) |_| {
            const literal = ring[pos & mask];
            if (ctx_splitter) {
                ctx.addSymbol(literal, sc.map.?[lut[prev_byte] | lut[256 + @as(usize, prev_byte2)]]);
            } else plain.addSymbol(literal);
            prev_byte2 = prev_byte;
            prev_byte = literal;
            pos += 1;
        }
        pos += c.copyLen();
        if (c.copyLen() != 0) {
            prev_byte2 = ring[(pos - 2) & mask];
            prev_byte = ring[(pos - 1) & mask];
            if (c.cmd_prefix >= 128) dist_blocks.addSymbol(c.dist_prefix & 0x3ff);
        }
    }
    var literal_size: usize = undefined;
    if (ctx_splitter) ctx.finishBlock(true, &literal_size) else plain.finishBlock(true, &literal_size);
    mb.literal_histograms = try shrink(LiteralHistogram, gpa, mb.literal_histograms, literal_size);
    var command_size: usize = undefined;
    cmd_blocks.finishBlock(true, &command_size);
    mb.command_histograms = try shrink(CommandHistogram, gpa, mb.command_histograms, command_size);
    var distance_size: usize = undefined;
    dist_blocks.finishBlock(true, &distance_size);
    mb.distance_histograms = try shrink(DistanceHistogram, gpa, mb.distance_histograms, distance_size);
    if (ctx_splitter) {
        // The static map's contexts, per block type.
        const size = mb.literal_split.num_types << command.literal_context_bits;
        mb.literal_context_map = try gpa.alloc(u32, size);
        for (0..mb.literal_split.num_types) |i| {
            const offset: u32 = @intCast(i * sc.num);
            for (0..64) |j| mb.literal_context_map[(i << command.literal_context_bits) + j] = offset + sc.map.?[j];
        }
    }
}

fn optimizeHistograms(num_distance_codes: usize, mb: *MetaBlockSplit) void {
    var good: [command.command_symbols]u8 = undefined;
    for (mb.literal_histograms) |*h| entropy.optimizeForRle(&h.data, &good);
    for (mb.command_histograms) |*h| entropy.optimizeForRle(&h.data, &good);
    for (mb.distance_histograms) |*h| entropy.optimizeForRle(h.data[0..num_distance_codes], &good);
}

/// Write the meta-block of `bytes` bytes at `last_flush_pos` from its
/// commands (the reference's `WriteMetaBlockInternal`).
pub fn write(gpa: Allocator, scratch: *Scratch, data: []const u8, mask: u32, last_flush_pos: u64, bytes: u32, is_last: bool, mode: context.Mode, params: *const settings.Resolved, prev_byte: u8, prev_byte2: u8, num_literals: usize, cmds: []Command, saved_dist_cache: *const [4]i32, dist_cache: *[16]i32, w: *Writer) Allocator.Error!void {
    const wrapped_last_flush_pos = settings.wrapPosition(last_flush_pos);
    if (bytes == 0) {
        // ISLAST and ISEMPTY.
        w.bits(2, 3);
        w.pos = (w.pos + 7) & ~@as(usize, 7);
        return;
    }
    if (!shouldCompress(data, mask, last_flush_pos, bytes, num_literals, cmds.len)) {
        // The cache's last update is undone with the copies.
        dist_cache[0..4].* = saved_dist_cache.*;
        store.storeUncompressedMetaBlock(is_last, data, wrapped_last_flush_pos, mask, bytes, w);
        return;
    }
    aegis.assert.invariant(w.pos <= 14, "w.pos <= 14");
    const last_bytes: u16 = (@as(u16, w.buf[1]) << 8) | w.buf[0];
    const last_bytes_bits = w.pos;
    var block_params = params.*;
    if (params.quality <= 2) {
        const a = try simpleArena(gpa, scratch);
        store.storeMetaBlockFast(a, data, wrapped_last_flush_pos, bytes, mask, is_last, params, cmds, w);
    } else if (params.quality < 4) {
        const a = try simpleArena(gpa, scratch);
        store.storeMetaBlockTrivial(a, data, wrapped_last_flush_pos, bytes, mask, is_last, params, cmds, w);
    } else {
        var mb: MetaBlockSplit = .{};
        defer mb.deinit(gpa);
        if (params.quality < 10) {
            var sc: StaticContexts = .{};
            if (!params.disable_literal_context_modeling) sc = decideLiteralContextModeling(data, wrapped_last_flush_pos, bytes, mask, params.quality, params.size_hint);
            try buildGreedy(gpa, data, wrapped_last_flush_pos, mask, prev_byte, prev_byte2, mode, sc, cmds, &mb);
        } else {
            try split_hq.buildMetaBlock(gpa, data, wrapped_last_flush_pos, mask, &block_params, prev_byte, prev_byte2, cmds, mode, &mb);
        }
        optimizeHistograms(block_params.dist.alphabet_size_limit, &mb);
        if (scratch.store == null) scratch.store = try gpa.create(store.StoreArena);
        try store.storeMetaBlock(gpa, scratch.store.?, data, wrapped_last_flush_pos, bytes, mask, prev_byte, prev_byte2, is_last, &block_params, mode, cmds, &mb, w);
    }
    if (bytes + 4 < w.pos >> 3) {
        // Larger than raw: the cache and the pending bits restored, stored.
        dist_cache[0..4].* = saved_dist_cache.*;
        w.buf[0] = @truncate(last_bytes);
        w.buf[1] = @truncate(last_bytes >> 8);
        w.pos = last_bytes_bits;
        store.storeUncompressedMetaBlock(is_last, data, wrapped_last_flush_pos, mask, bytes, w);
    }
}

fn simpleArena(gpa: Allocator, scratch: *Scratch) Allocator.Error!*store.SimpleArena {
    if (scratch.simple == null) scratch.simple = try gpa.create(store.SimpleArena);
    return scratch.simple.?;
}
