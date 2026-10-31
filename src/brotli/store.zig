//! Writing meta-blocks, as the reference encoder writes them: headers,
//! uncompressed meta-blocks, block-switch codes, context maps (move to
//! front and zero runs), and the commands with their literals and distances
//! under the codes of their block types and contexts. The fast and trivial
//! forms are the lower qualities': one code per alphabet, no splits, no
//! contexts, built from the meta-block's histograms (or the static codes).

const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const bits = @import("bits.zig");
const codes = @import("codes.zig");
const command = @import("command.zig");
const context = @import("context.zig");
const entropy = @import("entropy.zig");
const tables = @import("tables.zig");
const blocks = @import("blocks.zig");
const settings = @import("settings.zig");

const Writer = bits.Writer;
const Command = command.Command;

/// Distance symbols at NPOSTFIX 0, NDIRECT 0 with the large window's bits.
const max_simple_distance_alphabet = 140;

pub fn blockLengthPrefixCode(len: u32) u32 {
    var code: u32 = if (len >= 177) (if (len >= 753) 20 else 14) else (if (len >= 41) 7 else 0);
    while (code < command.block_length_symbols - 1 and len >= codes.block_counts[code + 1].offset) code += 1;
    return code;
}

pub const BlockTypeCodes = struct {
    last_type: usize = 1,
    second_last_type: usize = 0,

    pub fn next(c: *BlockTypeCodes, t: u8) usize {
        const code: usize = if (t == c.last_type + 1) 1 else if (t == c.second_last_type) 0 else @as(usize, t) + 2;
        c.second_last_type = c.last_type;
        c.last_type = t;
        return code;
    }
};

/// MLEN's nibbles (as MNIBBLES - 4), bit count and value.
fn encodeMlen(length: usize) struct { nibbles: u64, numbits: u32, value: u64 } {
    aegis.assert.pre(length > 0, "length > 0");
    aegis.assert.pre(length <= 1 << 24, "length <= 1 << 24");
    const lg: u32 = if (length == 1) 1 else command.log2Floor(length - 1) + 1;
    const mnibbles: u32 = (if (lg < 16) 16 else lg + 3) / 4;
    return .{ .nibbles = mnibbles - 4, .numbits = mnibbles * 4, .value = length - 1 };
}

fn storeCommandExtra(cmd: Command, w: *Writer) void {
    const copylen_code = cmd.copyLenCode();
    const inscode = command.insertCode(cmd.insert_len);
    const copycode = command.copyCode(copylen_code);
    const insnumextra = command.insert_extra[inscode];
    const insextraval: u64 = cmd.insert_len - command.insert_base[inscode];
    const copyextraval: u64 = copylen_code - command.copy_base[copycode];
    w.bits(insnumextra + command.copy_extra[copycode], (copyextraval << @intCast(insnumextra)) | insextraval);
}

/// A number 0-255.
pub fn storeVarLenUint8(n: usize, w: *Writer) void {
    if (n == 0) {
        w.bits(1, 0);
        return;
    }
    const nbits = command.log2Floor(n);
    w.bits(1, 1);
    w.bits(3, nbits);
    w.bits(nbits, n - (@as(usize, 1) << @intCast(nbits)));
}

pub fn storeCompressedMetaBlockHeader(is_final: bool, length: usize, w: *Writer) void {
    w.bits(1, @intFromBool(is_final));
    if (is_final) w.bits(1, 0);
    const m = encodeMlen(length);
    w.bits(2, m.nibbles);
    w.bits(m.numbits, m.value);
    if (!is_final) w.bits(1, 0);
}

fn storeUncompressedMetaBlockHeader(length: usize, w: *Writer) void {
    // ISLAST is 0: an uncompressed meta-block cannot be the last.
    w.bits(1, 0);
    const m = encodeMlen(length);
    w.bits(2, m.nibbles);
    w.bits(m.numbits, m.value);
    w.bits(1, 1);
}

/// `input[position..][0..len]` in the ring (`mask`) stored raw; an empty
/// last meta-block follows when `is_final`.
pub fn storeUncompressedMetaBlock(is_final: bool, input: []const u8, position: usize, mask: usize, length: usize, w: *Writer) void {
    var masked = position & mask;
    var len = length;
    storeUncompressedMetaBlockHeader(len, w);
    w.alignByte();
    if (masked + len > mask + 1) {
        const len1 = mask + 1 - masked;
        w.bytes(input[masked..][0..len1]);
        len -= len1;
        masked = 0;
    }
    w.bytes(input[masked..][0..len]);
    if (is_final) {
        w.bits(1, 1);
        w.bits(1, 1);
        w.alignByte();
    }
}

fn moveToFrontTransform(v_in: []const u32, v_out: []u32) void {
    if (v_in.len == 0) return;
    var max_value = v_in[0];
    for (v_in[1..]) |v| max_value = @max(max_value, v);
    std.debug.assert(max_value < 256);
    var mtf: [256]u8 = undefined;
    for (0..max_value + 1) |i| mtf[i] = @intCast(i);
    const size = max_value + 1;
    for (v_in, v_out) |v, *o| {
        const index = std.mem.findScalar(u8, mtf[0..size], @intCast(v)).?;
        o.* = @intCast(index);
        const value = mtf[index];
        var k = index;
        while (k != 0) : (k -= 1) mtf[k] = mtf[k - 1];
        mtf[0] = value;
    }
}

/// Zero runs in `v` as prefix codes of their lengths (low 9 bits) with
/// extra bits above; other values shifted by the largest prefix used,
/// at most `max_prefix_in`. Returns the count and that prefix.
fn runLengthCodeZeros(v: []u32, max_prefix_in: u32) struct { len: usize, max_prefix: u32 } {
    var max_reps: u32 = 0;
    var i: usize = 0;
    while (i < v.len) {
        while (i < v.len and v[i] != 0) i += 1;
        var reps: u32 = 0;
        while (i < v.len and v[i] == 0) : (i += 1) reps += 1;
        max_reps = @max(max_reps, reps);
    }
    var max_prefix: u32 = if (max_reps > 0) command.log2Floor(max_reps) else 0;
    max_prefix = @min(max_prefix, max_prefix_in);
    var out: usize = 0;
    i = 0;
    while (i < v.len) {
        if (v[i] != 0) {
            v[out] = v[i] + max_prefix;
            i += 1;
            out += 1;
            continue;
        }
        var reps: u32 = 1;
        while (i + reps < v.len and v[i + reps] == 0) reps += 1;
        i += reps;
        while (reps != 0) {
            if (reps < @as(u32, 2) << @intCast(max_prefix)) {
                const prefix = command.log2Floor(reps);
                const extra = reps - (@as(u32, 1) << @intCast(prefix));
                v[out] = prefix + (extra << 9);
                out += 1;
                break;
            }
            const extra = (@as(u32, 1) << @intCast(max_prefix)) - 1;
            v[out] = max_prefix + (extra << 9);
            reps -= (@as(u32, 2) << @intCast(max_prefix)) - 1;
            out += 1;
        }
    }
    return .{ .len = out, .max_prefix = max_prefix };
}

const max_context_map_symbols = command.max_block_types + 16;

pub const ContextMapArena = struct {
    histogram: [max_context_map_symbols]u32 = undefined,
    depths: [max_context_map_symbols]u8 = undefined,
    codes: [max_context_map_symbols]u16 = undefined,
};

fn encodeContextMap(gpa: Allocator, arena: *ContextMapArena, map: []const u32, num_clusters: usize, tree: []entropy.Node, w: *Writer) Allocator.Error!void {
    storeVarLenUint8(num_clusters - 1, w);
    if (num_clusters == 1) return;
    const rle = try gpa.alloc(u32, map.len);
    defer gpa.free(rle);
    moveToFrontTransform(map, rle);
    const r = runLengthCodeZeros(rle, 6);
    const histogram = &arena.histogram;
    @memset(histogram, 0);
    for (rle[0..r.len]) |s| histogram[s & 0x1ff] += 1;
    const use_rle = r.max_prefix > 0;
    w.bits(1, @intFromBool(use_rle));
    if (use_rle) w.bits(4, r.max_prefix - 1);
    const size = num_clusters + r.max_prefix;
    entropy.buildAndStore(w, histogram[0..size], size, tree, &arena.depths, &arena.codes);
    for (rle[0..r.len]) |s| {
        const symbol = s & 0x1ff;
        const extra = s >> 9;
        w.bits(arena.depths[symbol], arena.codes[symbol]);
        if (symbol > 0 and symbol <= r.max_prefix) w.bits(symbol, extra);
    }
    // Move-to-front was used.
    w.bits(1, 1);
}

/// What a block switch is written with.
pub const BlockSplitCode = struct {
    type_codes: BlockTypeCodes = .{},
    type_depths: [command.block_type_symbols]u8 = undefined,
    type_bits: [command.block_type_symbols]u16 = undefined,
    length_depths: [command.block_length_symbols]u8 = undefined,
    length_bits: [command.block_length_symbols]u16 = undefined,
};

fn storeBlockSwitch(code: *BlockSplitCode, block_len: u32, block_type: u8, is_first: bool, w: *Writer) void {
    const typecode = code.type_codes.next(block_type);
    if (!is_first) w.bits(code.type_depths[typecode], code.type_bits[typecode]);
    const lencode = blockLengthPrefixCode(block_len);
    const r = codes.block_counts[lencode];
    w.bits(code.length_depths[lencode], code.length_bits[lencode]);
    w.bits(r.extra, block_len - r.offset);
}

fn buildAndStoreBlockSplitCode(types: []const u8, lengths: []const u32, num_types: usize, tree: []entropy.Node, code: *BlockSplitCode, w: *Writer) void {
    var type_histo: [command.block_type_symbols]u32 = @splat(0);
    var length_histo: [command.block_length_symbols]u32 = @splat(0);
    var calc: BlockTypeCodes = .{};
    for (types, lengths, 0..) |t, l, i| {
        const tc = calc.next(t);
        if (i != 0) type_histo[tc] += 1;
        length_histo[blockLengthPrefixCode(l)] += 1;
    }
    storeVarLenUint8(num_types - 1, w);
    if (num_types > 1) {
        entropy.buildAndStore(w, type_histo[0 .. num_types + 2], num_types + 2, tree, &code.type_depths, &code.type_bits);
        entropy.buildAndStore(w, &length_histo, command.block_length_symbols, tree, &code.length_depths, &code.length_bits);
        storeBlockSwitch(code, lengths[0], types[0], true, w);
    }
}

/// A context map where each block type has its own histogram.
fn storeTrivialContextMap(arena: *ContextMapArena, num_types: usize, context_bits: u32, tree: []entropy.Node, w: *Writer) void {
    storeVarLenUint8(num_types - 1, w);
    if (num_types <= 1) return;
    const repeat_code = context_bits - 1;
    const repeat_bits = (@as(u64, 1) << @intCast(repeat_code)) - 1;
    const alphabet_size = num_types + repeat_code;
    const histogram = &arena.histogram;
    @memset(histogram[0..alphabet_size], 0);
    // RLEMAX.
    w.bits(1, 1);
    w.bits(4, repeat_code - 1);
    histogram[repeat_code] = @intCast(num_types);
    histogram[0] = 1;
    for (context_bits..alphabet_size) |i| histogram[i] = 1;
    entropy.buildAndStore(w, histogram[0..alphabet_size], alphabet_size, tree, &arena.depths, &arena.codes);
    for (0..num_types) |i| {
        const code = if (i == 0) 0 else i + context_bits - 1;
        w.bits(arena.depths[code], arena.codes[code]);
        w.bits(arena.depths[repeat_code], arena.codes[repeat_code]);
        w.bits(repeat_code, repeat_bits);
    }
    // Inverse move-to-front.
    w.bits(1, 1);
}

/// One category's (literal, command or distance) block switches and codes.
const BlockEncoder = struct {
    histogram_length: usize,
    num_block_types: usize,
    block_types: []const u8,
    block_lengths: []const u32,
    split_code: BlockSplitCode = .{},
    block_ix: usize = 0,
    block_len: usize,
    entropy_ix: usize = 0,
    depths: []u8 = &.{},
    codes: []u16 = &.{},

    fn init(histogram_length: usize, split: *const blocks.BlockSplit) BlockEncoder {
        return .{
            .histogram_length = histogram_length,
            .num_block_types = split.num_types,
            .block_types = split.types[0..split.num_blocks],
            .block_lengths = split.lengths[0..split.num_blocks],
            .block_len = if (split.num_blocks == 0) 0 else split.lengths[0],
        };
    }

    fn deinit(e: *BlockEncoder, gpa: Allocator) void {
        if (e.depths.len != 0) gpa.free(e.depths);
        if (e.codes.len != 0) gpa.free(e.codes);
    }

    fn storeSwitchCodes(e: *BlockEncoder, tree: []entropy.Node, w: *Writer) void {
        buildAndStoreBlockSplitCode(e.block_types, e.block_lengths, e.num_block_types, tree, &e.split_code, w);
    }

    fn storeCodes(e: *BlockEncoder, gpa: Allocator, comptime H: type, histograms: []const H, alphabet_size: usize, tree: []entropy.Node, w: *Writer) Allocator.Error!void {
        const size = histograms.len * e.histogram_length;
        e.depths = try gpa.alloc(u8, size);
        e.codes = try gpa.alloc(u16, size);
        for (histograms, 0..) |*h, i| {
            const ix = i * e.histogram_length;
            entropy.buildAndStore(w, h.data[0..e.histogram_length], alphabet_size, tree, e.depths[ix..][0..e.histogram_length], e.codes[ix..][0..e.histogram_length]);
        }
    }

    inline fn advance(e: *BlockEncoder, w: *Writer) ?u8 {
        if (e.block_len != 0) {
            e.block_len -= 1;
            return null;
        }
        e.block_ix += 1;
        const block_len = e.block_lengths[e.block_ix];
        const block_type = e.block_types[e.block_ix];
        e.block_len = block_len - 1;
        storeBlockSwitch(&e.split_code, block_len, block_type, false, w);
        return block_type;
    }

    inline fn symbol(e: *BlockEncoder, s: usize, w: *Writer) void {
        if (e.advance(w)) |t| e.entropy_ix = t * e.histogram_length;
        const ix = e.entropy_ix + s;
        w.bits(e.depths[ix], e.codes[ix]);
    }

    inline fn symbolWithContext(e: *BlockEncoder, s: usize, ctx: usize, map: []const u32, w: *Writer, comptime context_bits: u5) void {
        if (e.advance(w)) |t| e.entropy_ix = @as(usize, t) << context_bits;
        const histo_ix = map[e.entropy_ix + ctx];
        const ix = histo_ix * e.histogram_length + s;
        w.bits(e.depths[ix], e.codes[ix]);
    }
};

pub const StoreArena = struct {
    tree: entropy.Tree = undefined,
    context_map: ContextMapArena = .{},
};

/// A meta-block with its block splits, context maps and histograms.
pub fn storeMetaBlock(gpa: Allocator, arena: *StoreArena, input: []const u8, start_pos: usize, length: usize, mask: usize, prev_byte_in: u8, prev_byte2_in: u8, is_last: bool, params: *const settings.Resolved, mode: context.Mode, cmds: []const Command, mb: *const blocks.MetaBlockSplit, w: *Writer) Allocator.Error!void {
    var pos = start_pos;
    var prev_byte = prev_byte_in;
    var prev_byte2 = prev_byte2_in;
    const dist = &params.dist;
    const num_distance_symbols = dist.alphabet_size_max;
    const num_effective_distance_symbols = dist.alphabet_size_limit;
    const lut = &context.lookup[@backingInt(mode)];
    storeCompressedMetaBlockHeader(is_last, length, w);
    const tree = &arena.tree;
    var literal_enc: BlockEncoder = .init(command.literal_symbols, &mb.literal_split);
    defer literal_enc.deinit(gpa);
    var command_enc: BlockEncoder = .init(command.command_symbols, &mb.command_split);
    defer command_enc.deinit(gpa);
    var distance_enc: BlockEncoder = .init(num_effective_distance_symbols, &mb.distance_split);
    defer distance_enc.deinit(gpa);
    literal_enc.storeSwitchCodes(tree, w);
    command_enc.storeSwitchCodes(tree, w);
    distance_enc.storeSwitchCodes(tree, w);
    w.bits(2, dist.postfix_bits);
    w.bits(4, dist.direct_codes >> @intCast(dist.postfix_bits));
    for (0..mb.literal_split.num_types) |_| w.bits(2, @backingInt(mode));
    if (mb.literal_context_map.len == 0) {
        storeTrivialContextMap(&arena.context_map, mb.literal_histograms.len, command.literal_context_bits, tree, w);
    } else try encodeContextMap(gpa, &arena.context_map, mb.literal_context_map, mb.literal_histograms.len, tree, w);
    if (mb.distance_context_map.len == 0) {
        storeTrivialContextMap(&arena.context_map, mb.distance_histograms.len, command.distance_context_bits, tree, w);
    } else try encodeContextMap(gpa, &arena.context_map, mb.distance_context_map, mb.distance_histograms.len, tree, w);
    try literal_enc.storeCodes(gpa, command.LiteralHistogram, mb.literal_histograms, command.literal_symbols, tree, w);
    try command_enc.storeCodes(gpa, command.CommandHistogram, mb.command_histograms, command.command_symbols, tree, w);
    try distance_enc.storeCodes(gpa, command.DistanceHistogram, mb.distance_histograms, num_distance_symbols, tree, w);
    for (cmds) |cmd| {
        command_enc.symbol(cmd.cmd_prefix, w);
        storeCommandExtra(cmd, w);
        if (mb.literal_context_map.len == 0) {
            for (0..cmd.insert_len) |_| {
                literal_enc.symbol(input[pos & mask], w);
                pos += 1;
            }
        } else {
            for (0..cmd.insert_len) |_| {
                const ctx = lut[prev_byte] | lut[256 + @as(usize, prev_byte2)];
                const literal = input[pos & mask];
                literal_enc.symbolWithContext(literal, ctx, mb.literal_context_map, w, command.literal_context_bits);
                prev_byte2 = prev_byte;
                prev_byte = literal;
                pos += 1;
            }
        }
        pos += cmd.copyLen();
        if (cmd.copyLen() != 0) {
            prev_byte2 = input[(pos - 2) & mask];
            prev_byte = input[(pos - 1) & mask];
            if (cmd.cmd_prefix >= 128) {
                const dist_code = cmd.dist_prefix & 0x3ff;
                const distnumextra = cmd.dist_prefix >> 10;
                if (mb.distance_context_map.len == 0) {
                    distance_enc.symbol(dist_code, w);
                } else {
                    distance_enc.symbolWithContext(dist_code, cmd.distanceContext(), mb.distance_context_map, w, command.distance_context_bits);
                }
                w.bits(distnumextra, cmd.dist_extra);
            }
        }
    }
    if (is_last) w.alignByte();
}

fn buildHistograms(input: []const u8, start_pos: usize, mask: usize, cmds: []const Command, lit: *command.LiteralHistogram, cmd_h: *command.CommandHistogram, dist_h: *command.DistanceHistogram) void {
    var pos = start_pos;
    for (cmds) |cmd| {
        cmd_h.add(cmd.cmd_prefix);
        for (0..cmd.insert_len) |_| {
            lit.add(input[pos & mask]);
            pos += 1;
        }
        pos += cmd.copyLen();
        if (cmd.copyLen() != 0 and cmd.cmd_prefix >= 128) dist_h.add(cmd.dist_prefix & 0x3ff);
    }
}

fn storeDataWithCodes(input: []const u8, start_pos: usize, mask: usize, cmds: []const Command, lit_depth: []const u8, lit_bits: []const u16, cmd_depth: []const u8, cmd_bits: []const u16, dist_depth: []const u8, dist_bits: []const u16, w: *Writer) void {
    var pos = start_pos;
    for (cmds) |cmd| {
        const cmd_code = cmd.cmd_prefix;
        w.bits(cmd_depth[cmd_code], cmd_bits[cmd_code]);
        storeCommandExtra(cmd, w);
        for (0..cmd.insert_len) |_| {
            const literal = input[pos & mask];
            w.bits(lit_depth[literal], lit_bits[literal]);
            pos += 1;
        }
        pos += cmd.copyLen();
        if (cmd.copyLen() != 0 and cmd.cmd_prefix >= 128) {
            const dist_code = cmd.dist_prefix & 0x3ff;
            w.bits(dist_depth[dist_code], dist_bits[dist_code]);
            w.bits(cmd.dist_prefix >> 10, cmd.dist_extra);
        }
    }
}

pub const SimpleArena = struct {
    lit_histo: command.LiteralHistogram = undefined,
    cmd_histo: command.CommandHistogram = undefined,
    dist_histo: command.DistanceHistogram = undefined,
    lit_depth: [command.literal_symbols]u8 = undefined,
    lit_bits: [command.literal_symbols]u16 = undefined,
    cmd_depth: [command.command_symbols]u8 = undefined,
    cmd_bits: [command.command_symbols]u16 = undefined,
    dist_depth: [max_simple_distance_alphabet]u8 = undefined,
    dist_bits: [max_simple_distance_alphabet]u16 = undefined,
    tree: entropy.Tree = undefined,
};

/// Quality 3: one code per alphabet from the meta-block's histograms.
pub fn storeMetaBlockTrivial(a: *SimpleArena, input: []const u8, start_pos: usize, length: usize, mask: usize, is_last: bool, params: *const settings.Resolved, cmds: []const Command, w: *Writer) void {
    const num_distance_symbols = params.dist.alphabet_size_max;
    storeCompressedMetaBlockHeader(is_last, length, w);
    a.lit_histo = .empty;
    a.cmd_histo = .empty;
    a.dist_histo = .empty;
    buildHistograms(input, start_pos, mask, cmds, &a.lit_histo, &a.cmd_histo, &a.dist_histo);
    w.bits(13, 0);
    entropy.buildAndStore(w, &a.lit_histo.data, command.literal_symbols, &a.tree, &a.lit_depth, &a.lit_bits);
    entropy.buildAndStore(w, &a.cmd_histo.data, command.command_symbols, &a.tree, &a.cmd_depth, &a.cmd_bits);
    entropy.buildAndStore(w, a.dist_histo.data[0..max_simple_distance_alphabet], num_distance_symbols, &a.tree, &a.dist_depth, &a.dist_bits);
    storeDataWithCodes(input, start_pos, mask, cmds, &a.lit_depth, &a.lit_bits, &a.cmd_depth, &a.cmd_bits, &a.dist_depth, &a.dist_bits, w);
    if (is_last) w.alignByte();
}

/// Quality 2: the fast code builder, and the static command and distance
/// codes when there are few commands.
pub fn storeMetaBlockFast(a: *SimpleArena, input: []const u8, start_pos: usize, length: usize, mask: usize, is_last: bool, params: *const settings.Resolved, cmds: []const Command, w: *Writer) void {
    const num_distance_symbols = params.dist.alphabet_size_max;
    const distance_alphabet_bits = command.log2Floor(num_distance_symbols - 1) + 1;
    storeCompressedMetaBlockHeader(is_last, length, w);
    w.bits(13, 0);
    if (cmds.len <= 128) {
        var histogram: [command.literal_symbols]u32 = @splat(0);
        var pos = start_pos;
        var num_literals: usize = 0;
        for (cmds) |cmd| {
            for (0..cmd.insert_len) |_| {
                histogram[input[pos & mask]] += 1;
                pos += 1;
            }
            num_literals += cmd.insert_len;
            pos += cmd.copyLen();
        }
        entropy.buildAndStoreFast(w, &a.tree, &histogram, num_literals, 8, &a.lit_depth, &a.lit_bits);
        entropy.storeStaticCommandCode(w);
        entropy.storeStaticDistanceCode(w);
        storeDataWithCodes(input, start_pos, mask, cmds, &a.lit_depth, &a.lit_bits, &tables.static_command_depth, &tables.static_command_bits, &tables.static_distance_depth, &tables.static_distance_bits, w);
    } else {
        a.lit_histo = .empty;
        a.cmd_histo = .empty;
        a.dist_histo = .empty;
        buildHistograms(input, start_pos, mask, cmds, &a.lit_histo, &a.cmd_histo, &a.dist_histo);
        entropy.buildAndStoreFast(w, &a.tree, &a.lit_histo.data, a.lit_histo.total, 8, &a.lit_depth, &a.lit_bits);
        entropy.buildAndStoreFast(w, &a.tree, &a.cmd_histo.data, a.cmd_histo.total, 10, &a.cmd_depth, &a.cmd_bits);
        entropy.buildAndStoreFast(w, &a.tree, &a.dist_histo.data, a.dist_histo.total, distance_alphabet_bits, &a.dist_depth, &a.dist_bits);
        storeDataWithCodes(input, start_pos, mask, cmds, &a.lit_depth, &a.lit_bits, &a.cmd_depth, &a.cmd_bits, &a.dist_depth, &a.dist_bits, w);
    }
    if (is_last) w.alignByte();
}
