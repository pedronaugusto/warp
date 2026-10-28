//! Quality 0: the reference's one-pass fragment coder. One hash table of
//! 5-byte matches, heuristic skipping over incompressible runs, literals
//! coded with a code built from a sample of the input before parsing, and
//! commands written as they are found with codes learnt from the previous
//! block (the first block uses the reference's default codes). A meta-block
//! grows by 64 KiB blocks while its literal code still fits them.

const std = @import("std");
const bits = @import("bits.zig");
const entropy = @import("entropy.zig");
const find = @import("find.zig");
const tables = @import("tables.zig");
const fastLog2 = @import("cost.zig").fastLog2;
const mulAdd = @import("cost.zig").mulAdd;

const Writer = bits.Writer;

/// The window distances reach: 2^18 less the format's gap.
const max_distance: isize = (1 << 18) - 16;
const first_block_size = 3 << 15;
const merge_block_size = 1 << 16;
const input_margin = 16;
const min_match = 5;
/// Acceptable loss for an incompressible meta-block stored raw: 2%.
const min_ratio = 980;

/// State kept across blocks: the command code learnt from the last one.
pub const Arena = struct {
    lit_depth: [256]u8 = undefined,
    lit_bits: [256]u16 = undefined,
    /// Command and distance codes, 64 symbols each, back to back. The
    /// command code is over a smaller alphabet: 0-15 insert 0 with copy
    /// codes 0-15 and the last distance, 16-39 insert 0 with copy codes
    /// 0-23, 40-63 insert codes 0-23 with copy code 0.
    cmd_depth: [128]u8 = tables.default_command_depths,
    cmd_bits: [128]u16 = tables.default_command_bits,
    cmd_histo: [128]u32 = undefined,
    /// The stored form of the command and distance codes for the next block.
    cmd_code: [512]u8 = tables.default_command_code ++ @as([512 - 57]u8, @splat(0)),
    cmd_code_numbits: usize = 448,
    tree: [2 * 256 + 1]entropy.Node = undefined,
    histogram: [256]u32 = undefined,
    tmp_depth: [704]u8 = undefined,
    tmp_bits: [64]u16 = undefined,
};

const cmd_histo_seed = [128]u32{
    0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0,
    0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1,
    1, 1, 1, 1, 0, 0, 0, 0,
};

/// The literal code from the input before parsing: all of it below 32 KiB,
/// every 29th byte above (every byte then gets a depth). Returns the
/// estimated ratio in millibytes per literal.
fn literalCode(s: *Arena, input: []const u8, w: *Writer) usize {
    const histogram = &s.histogram;
    @memset(histogram, 0);
    var total: usize = undefined;
    if (input.len < 1 << 15) {
        for (input) |b| histogram[b] += 1;
        total = input.len;
        for (histogram) |*h| {
            // The first 11 samples weigh 3: LZ77 evens the literals out.
            const adjust: u32 = 2 * @as(u32, @min(h.*, 11));
            h.* += adjust;
            total += adjust;
        }
    } else {
        const sample_rate = 29;
        var i: usize = 0;
        while (i < input.len) : (i += sample_rate) histogram[input[i]] += 1;
        total = (input.len + sample_rate - 1) / sample_rate;
        for (histogram) |*h| {
            const adjust: u32 = 1 + 2 * @as(u32, @min(h.*, 11));
            h.* += adjust;
            total += adjust;
        }
    }
    entropy.buildAndStoreFast(w, &s.tree, histogram, total, 8, &s.lit_depth, &s.lit_bits);
    var ratio: usize = 0;
    for (histogram, s.lit_depth) |h, d| {
        if (h != 0) ratio += h * d;
    }
    return ratio * 125 / total;
}

/// The command and distance codes from this block's histogram, stored.
fn commandCode(s: *Arena, w: *Writer) void {
    const depth = &s.cmd_depth;
    const tmp_depth = &s.tmp_depth;
    @memset(tmp_depth, 0);
    entropy.createTree(s.cmd_histo[0..64], 15, &s.tree, depth[0..64]);
    entropy.createTree(s.cmd_histo[64..128], 14, &s.tree, depth[64..128]);
    // The full alphabet's order of the small alphabet's symbols decides the
    // canonical codewords.
    @memcpy(tmp_depth[0..24], depth[0..24]);
    @memcpy(tmp_depth[24..32], depth[40..48]);
    @memcpy(tmp_depth[32..40], depth[24..32]);
    @memcpy(tmp_depth[40..48], depth[48..56]);
    @memcpy(tmp_depth[48..56], depth[32..40]);
    @memcpy(tmp_depth[56..64], depth[56..64]);
    entropy.codewords(tmp_depth[0..64], &s.tmp_bits);
    const b = &s.cmd_bits;
    @memcpy(b[0..24], s.tmp_bits[0..24]);
    @memcpy(b[24..32], s.tmp_bits[32..40]);
    @memcpy(b[32..40], s.tmp_bits[48..56]);
    @memcpy(b[40..48], s.tmp_bits[24..32]);
    @memcpy(b[48..56], s.tmp_bits[40..48]);
    @memcpy(b[56..64], s.tmp_bits[56..64]);
    entropy.codewords(depth[64..128], b[64..128]);
    @memset(tmp_depth[0..64], 0);
    @memcpy(tmp_depth[0..8], depth[0..8]);
    @memcpy(tmp_depth[64..72], depth[8..16]);
    @memcpy(tmp_depth[128..136], depth[16..24]);
    @memcpy(tmp_depth[192..200], depth[24..32]);
    @memcpy(tmp_depth[384..392], depth[32..40]);
    for (0..8) |i| {
        tmp_depth[128 + 8 * i] = depth[40 + i];
        tmp_depth[256 + 8 * i] = depth[48 + i];
        tmp_depth[448 + 8 * i] = depth[56 + i];
    }
    entropy.storeTree(w, tmp_depth, &s.tree);
    entropy.storeTree(w, depth[64..128], &s.tree);
}

const Emit = struct {
    w: *Writer,
    depth: *const [128]u8,
    code: *const [128]u16,
    histo: *[128]u32,

    inline fn symbol(e: Emit, c: usize) void {
        e.w.bits(e.depth[c], e.code[c]);
        e.histo[c] += 1;
    }

    /// `len < 6210`.
    inline fn insertLen(e: Emit, len: usize) void {
        if (len < 6) {
            e.symbol(len + 40);
        } else if (len < 130) {
            const tail = len - 2;
            const nbits = findLog2(tail) - 1;
            const prefix = tail >> @intCast(nbits);
            e.symbol((nbits << 1) + prefix + 42);
            e.w.bits(nbits, tail - (prefix << @intCast(nbits)));
        } else if (len < 2114) {
            const tail = len - 66;
            const nbits = findLog2(tail);
            e.symbol(nbits + 50);
            e.w.bits(nbits, tail - (@as(usize, 1) << @intCast(nbits)));
        } else {
            e.symbol(61);
            e.w.bits(12, len - 2114);
        }
    }

    inline fn longInsertLen(e: Emit, len: usize) void {
        if (len < 22594) {
            e.symbol(62);
            e.w.bits(14, len - 6210);
        } else {
            e.symbol(63);
            e.w.bits(24, len - 22594);
        }
    }

    inline fn copyLen(e: Emit, len: usize) void {
        if (len < 10) {
            e.symbol(len + 14);
        } else if (len < 134) {
            const tail = len - 6;
            const nbits = findLog2(tail) - 1;
            const prefix = tail >> @intCast(nbits);
            e.symbol((nbits << 1) + prefix + 20);
            e.w.bits(nbits, tail - (prefix << @intCast(nbits)));
        } else if (len < 2118) {
            const tail = len - 70;
            const nbits = findLog2(tail);
            e.symbol(nbits + 28);
            e.w.bits(nbits, tail - (@as(usize, 1) << @intCast(nbits)));
        } else {
            e.symbol(39);
            e.w.bits(24, len - 2118);
        }
    }

    inline fn copyLenLastDistance(e: Emit, len: usize) void {
        if (len < 12) {
            e.symbol(len - 4);
        } else if (len < 72) {
            const tail = len - 8;
            const nbits = findLog2(tail) - 1;
            const prefix = tail >> @intCast(nbits);
            e.symbol((nbits << 1) + prefix + 4);
            e.w.bits(nbits, tail - (prefix << @intCast(nbits)));
        } else if (len < 136) {
            const tail = len - 8;
            e.symbol((tail >> 5) + 30);
            e.w.bits(5, tail & 31);
            e.symbol(64);
        } else if (len < 2120) {
            const tail = len - 72;
            const nbits = findLog2(tail);
            e.symbol(nbits + 28);
            e.w.bits(nbits, tail - (@as(usize, 1) << @intCast(nbits)));
            e.symbol(64);
        } else {
            e.symbol(39);
            e.w.bits(24, len - 2120);
            e.symbol(64);
        }
    }

    inline fn distance(e: Emit, dist: usize) void {
        const d = dist + 3;
        const nbits = findLog2(d) - 1;
        const prefix = (d >> @intCast(nbits)) & 1;
        const offset = (2 + prefix) << @intCast(nbits);
        e.symbol(2 * (nbits - 1) + prefix + 80);
        e.w.bits(nbits, d - offset);
    }
};

inline fn findLog2(n: usize) u32 {
    return @intCast(std.math.log2_int(usize, n));
}

inline fn literals(w: *Writer, input: []const u8, depth: *const [256]u8, code: *const [256]u16) void {
    for (input) |lit| w.bits(depth[lit], code[lit]);
}

/// A compressed meta-block's header: not last, MLEN in 4-6 nibbles.
pub fn metaBlockHeader(w: *Writer, len: usize, uncompressed: bool) void {
    w.bits(1, 0);
    const nibbles: u32 = if (len <= 1 << 16) 4 else if (len <= 1 << 20) 5 else 6;
    w.bits(2, nibbles - 4);
    w.bits(nibbles * 4, len - 1);
    w.bits(1, @intFromBool(uncompressed));
}

/// Overwrite `n` bits at bit `pos`.
pub fn updateBits(n_bits: usize, value: u32, pos_in: usize, array: []u8) void {
    var n = n_bits;
    var v = value;
    var pos = pos_in;
    while (n > 0) {
        const byte = pos >> 3;
        const unchanged: u5 = @intCast(pos & 7);
        const changed: u5 = @intCast(@min(n, 8 - @as(usize, unchanged)));
        const total = unchanged + changed;
        const mask: u32 = ~((@as(u32, 1) << total) - 1) | ((@as(u32, 1) << unchanged) - 1);
        array[byte] = @truncate(((v & ((@as(u32, 1) << changed) - 1)) << unchanged) | (array[byte] & mask));
        n -= changed;
        v >>= changed;
        pos += changed;
    }
}

/// Drop the bits from `pos` on.
pub fn rewind(w: *Writer, pos: usize) void {
    w.buf[pos >> 3] &= @truncate((@as(u32, 1) << @intCast(pos & 7)) - 1);
    w.pos = pos;
}

fn shouldMerge(s: *Arena, data: []const u8, depths: *const [256]u8) bool {
    const sample_rate = 43;
    @memset(&s.histogram, 0);
    var i: usize = 0;
    while (i < data.len) : (i += sample_rate) s.histogram[data[i]] += 1;
    const total = (data.len + sample_rate - 1) / sample_rate;
    // Fused as clang fuses the reference's.
    var r: f64 = mulAdd(fastLog2(total) + 0.5, @floatFromInt(total), 200);
    for (s.histogram, depths) |h, d| r = mulAdd(-@as(f64, @floatFromInt(h)), @as(f64, @floatFromInt(d)) + fastLog2(h), r);
    return r >= 0;
}

fn shouldStoreRaw(metablock_start: usize, next_emit: usize, insert_len: usize, literal_ratio: usize) bool {
    const compressed = next_emit - metablock_start;
    if (compressed * 50 > insert_len) return false;
    return literal_ratio > min_ratio;
}

pub fn storeRaw(w: *Writer, data: []const u8, start_pos: usize) void {
    rewind(w, start_pos);
    metaBlockHeader(w, data.len, true);
    w.alignByte();
    w.bytes(data);
}

inline fn hashAt(data: []const u8, at: usize, comptime shift: u6) u32 {
    return @intCast(((find.load64(data, at) << 24) *% find.hash_mul32) >> shift);
}

inline fn hashBytes(v: u64, comptime offset: u6, comptime shift: u6) u32 {
    return @intCast((((v >> (8 * offset)) << 24) *% find.hash_mul32) >> shift);
}

inline fn isMatch(data: []const u8, a: usize, b: usize) bool {
    return find.load32(data, a) == find.load32(data, b) and data[a + 4] == data[b + 4];
}

/// Hash the three positions before `ip` and the one at it; the table's old
/// entry for `ip` is the next candidate.
inline fn rehash(table: []i32, data: []const u8, ip: usize, comptime shift: u6) usize {
    const v = find.load64(data, ip - 3);
    table[hashBytes(v, 0, shift)] = @intCast(ip - 3);
    table[hashBytes(v, 1, shift)] = @intCast(ip - 2);
    table[hashBytes(v, 2, shift)] = @intCast(ip - 1);
    const cur = hashBytes(v, 3, shift);
    const candidate: usize = @intCast(table[cur]);
    table[cur] = @intCast(ip);
    return candidate;
}

/// How a block's commands end: at its remainder, or with the meta-block
/// stored raw up to a match, the next block starting there.
const End = enum { remainder, raw };

/// Emit the commands of the block `all[input..ip_end]`; `next_emit` is the
/// first byte no command covers yet.
fn commands(s: *Arena, all: []const u8, table: []i32, comptime shift: u6, out: *Writer, input: usize, ip_end: usize, input_size: usize, next_emit: *usize, metablock_start: usize, mlen_pos: usize, literal_ratio: usize) End {
    @memcpy(&s.cmd_histo, &cmd_histo_seed);
    // A local writer: its position stays in a register past the stores.
    var lw = out.*;
    defer out.pos = lw.pos;
    const w = &lw;
    const e: Emit = .{ .w = w, .depth = &s.cmd_depth, .code = &s.cmd_bits, .histo = &s.cmd_histo };
    const block_size = ip_end - input;
    if (block_size < input_margin) return .remainder;
    // The last block keeps a 16-byte margin so distances stay below the
    // window less 16; others keep 5 so a copy stays inside the block.
    const ip_limit = input + @min(block_size - min_match, input_size - input_margin);
    var last_distance: isize = -1;
    var ip = input + 1;
    var next_hash = hashAt(all, ip, shift);
    while (true) {
        // Scan for a 5-byte match, skipping more the longer there is none.
        var skip: u32 = 32;
        var next_ip = ip;
        var candidate: usize = undefined;
        while (true) {
            while (true) {
                const hash = next_hash;
                const step = skip >> 5;
                skip += 1;
                ip = next_ip;
                next_ip = ip + step;
                if (next_ip > ip_limit) {
                    @branchHint(.unlikely);
                    return .remainder;
                }
                next_hash = hashAt(all, next_ip, shift);
                // The last distance first; before the first copy it is -1, a
                // candidate past ip, and never taken.
                const last: usize = @intCast(@as(isize, @intCast(ip)) - last_distance);
                if (isMatch(all, ip, last)) {
                    if (last < ip) {
                        @branchHint(.likely);
                        candidate = last;
                        table[hash] = @intCast(ip);
                        break;
                    }
                }
                candidate = @intCast(table[hash]);
                table[hash] = @intCast(ip);
                if (isMatch(all, ip, candidate)) {
                    @branchHint(.unlikely);
                    break;
                }
            }
            if (@as(isize, @intCast(ip - candidate)) <= max_distance) break;
        }
        // A match at ip: the literals before it, then the copy.
        {
            const base = ip;
            const matched = 5 + find.matchLength(all, candidate + 5, ip + 5, ip_end - ip - 5);
            const distance: isize = @intCast(base - candidate);
            const insert = base - next_emit.*;
            ip += matched;
            if (insert < 6210) {
                @branchHint(.likely);
                e.insertLen(insert);
            } else if (shouldStoreRaw(metablock_start, next_emit.*, insert, literal_ratio)) {
                storeRaw(w, all[metablock_start..base], mlen_pos - 3);
                next_emit.* = base;
                return .raw;
            } else e.longInsertLen(insert);
            literals(w, all[next_emit.*..base], &s.lit_depth, &s.lit_bits);
            if (distance == last_distance) {
                e.symbol(64);
            } else {
                e.distance(@intCast(distance));
                last_distance = distance;
            }
            e.copyLenLastDistance(matched);
            next_emit.* = ip;
            if (ip >= ip_limit) {
                @branchHint(.unlikely);
                return .remainder;
            }
            candidate = rehash(table, all, ip, shift);
        }
        // Copies that follow with no literals between.
        while (isMatch(all, ip, candidate)) {
            const base = ip;
            const matched = 5 + find.matchLength(all, candidate + 5, ip + 5, ip_end - ip - 5);
            if (@as(isize, @intCast(ip - candidate)) > max_distance) break;
            ip += matched;
            last_distance = @intCast(base - candidate);
            e.copyLen(matched);
            e.distance(@intCast(last_distance));
            next_emit.* = ip;
            if (ip >= ip_limit) {
                @branchHint(.unlikely);
                return .remainder;
            }
            candidate = rehash(table, all, ip, shift);
        }
        ip += 1;
        next_hash = hashAt(all, ip, shift);
    }
}

/// Compress `all` (`all.len > 0`) as meta-blocks, each after the first
/// with the command code learnt from the one before; table entries are
/// offsets into `all`. `table` is zeroed, 2^`table_bits` entries.
fn compressImpl(s: *Arena, all: []const u8, is_last: bool, table: []i32, comptime table_bits: u6, w: *Writer) void {
    const shift: u6 = 64 - @as(u7, table_bits);
    var input: usize = 0;
    var next_emit: usize = 0;
    var metablock_start: usize = 0;
    var block_size: usize = @min(all.len, first_block_size);
    var total_block_size = block_size;
    var mlen_pos = w.pos + 3;
    metaBlockHeader(w, block_size, false);
    w.bits(13, 0);
    var literal_ratio = literalCode(s, all[0..block_size], w);
    {
        var i: usize = 0;
        while (i + 7 < s.cmd_code_numbits) : (i += 8) w.bits(8, s.cmd_code[i >> 3]);
        w.bits(@intCast(s.cmd_code_numbits & 7), s.cmd_code[s.cmd_code_numbits >> 3]);
    }
    while (true) {
        const ip_end = input + block_size;
        const end = commands(s, all, table, shift, w, input, ip_end, all.len - input, &next_emit, metablock_start, mlen_pos, literal_ratio);
        if (end == .raw) {
            input = next_emit;
        } else {
            input += block_size;
            block_size = @min(all.len - input, merge_block_size);
            if (input < all.len and total_block_size + block_size <= 1 << 20 and shouldMerge(s, all[input..][0..block_size], &s.lit_depth)) {
                // Both sizes take 5 nibbles: the header's MLEN is rewritten.
                total_block_size += block_size;
                updateBits(20, @intCast(total_block_size - 1), mlen_pos, w.buf);
                continue;
            }
            if (next_emit < ip_end) {
                const insert = ip_end - next_emit;
                const e: Emit = .{ .w = w, .depth = &s.cmd_depth, .code = &s.cmd_bits, .histo = &s.cmd_histo };
                if (insert < 6210) {
                    e.insertLen(insert);
                    literals(w, all[next_emit..ip_end], &s.lit_depth, &s.lit_bits);
                } else if (shouldStoreRaw(metablock_start, next_emit, insert, literal_ratio)) {
                    storeRaw(w, all[metablock_start..ip_end], mlen_pos - 3);
                } else {
                    e.longInsertLen(insert);
                    literals(w, all[next_emit..ip_end], &s.lit_depth, &s.lit_bits);
                }
            }
            next_emit = ip_end;
        }
        if (input == all.len) break;
        metablock_start = input;
        block_size = @min(all.len - input, first_block_size);
        total_block_size = block_size;
        mlen_pos = w.pos + 3;
        metaBlockHeader(w, block_size, false);
        w.bits(13, 0);
        literal_ratio = literalCode(s, all[input..][0..block_size], w);
        commandCode(s, w);
    }
    if (!is_last) {
        // The next call starts with this block's command code.
        @memset(&s.cmd_code, 0);
        var cw: Writer = .{ .buf = &s.cmd_code };
        commandCode(s, &cw);
        s.cmd_code_numbits = cw.pos;
    }
}

/// Compress `input` as quality 0 does: `table` of a power of two entries
/// with an odd exponent 9-15, zeroed; `w` holds `2 * input.len + 503` bytes.
pub fn compress(s: *Arena, input: []const u8, is_last: bool, table: []i32, w: *Writer) void {
    const start = w.pos;
    if (input.len == 0) {
        std.debug.assert(is_last);
        w.bits(1, 1);
        w.bits(1, 1);
        w.alignByte();
        return;
    }
    const table_bits: u6 = @intCast(std.math.log2_int(usize, table.len));
    std.debug.assert(table_bits & 1 == 1);
    std.debug.assert(table_bits >= 9);
    std.debug.assert(table_bits <= 15);
    // The shift a constant, as the reference instantiates each size.
    switch (table_bits) {
        inline 9, 11, 13, 15 => |size| compressImpl(s, input, is_last, table, size, w),
        else => unreachable,
    }
    // Larger than one uncompressed meta-block: write that instead.
    if (w.pos - start > 31 + (input.len << 3)) storeRaw(w, input, start);
    if (is_last) {
        w.bits(1, 1);
        w.bits(1, 1);
        w.alignByte();
    }
}
