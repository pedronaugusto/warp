//! Quality 1: the reference's two-pass fragment coder. Blocks of 128 KiB
//! are parsed with one hash table (4-byte matches below 2^16 entries, 6
//! above) into a command buffer first, then coded with codes built from
//! what was parsed, or stored raw when the literals would not compress.

const std = @import("std");
const bits = @import("bits.zig");
const entropy = @import("entropy.zig");
const find = @import("find.zig");
const cost = @import("cost.zig");
const fragment = @import("fragment.zig");

const Writer = bits.Writer;

const max_distance: isize = (1 << 18) - 16;
const block_size_max = 1 << 17;
const input_margin = 16;
const min_ratio = 0.98;
const sample_rate = 43;

pub const Arena = struct {
    lit_histo: [256]u32 = undefined,
    lit_depth: [256]u8 = undefined,
    lit_bits: [256]u16 = undefined,
    cmd_histo: [128]u32 = undefined,
    cmd_depth: [128]u8 = undefined,
    cmd_bits: [128]u16 = undefined,
    tree: [2 * 256 + 1]entropy.Node = undefined,
    tmp_depth: [704]u8 = undefined,
    tmp_bits: [64]u16 = undefined,
};

inline fn hashAt(data: []const u8, at: usize, shift: u6, comptime len: u6) u32 {
    return @intCast(((find.load64(data, at) << ((8 - len) * 8)) *% find.hash_mul32) >> shift);
}

inline fn hashBytes(v: u64, offset: u6, shift: u6, comptime len: u6) u32 {
    return @intCast((((v >> (8 * offset)) << ((8 - len) * 8)) *% find.hash_mul32) >> shift);
}

inline fn isMatch(data: []const u8, a: usize, b: usize, comptime len: usize) bool {
    if (find.load32(data, a) != find.load32(data, b)) return false;
    if (len == 4) return true;
    return data[a + 4] == data[b + 4] and data[a + 5] == data[b + 5];
}

/// The command and distance codes over this block's commands, stored.
fn commandCode(s: *Arena, w: *Writer) void {
    const depth = &s.cmd_depth;
    const tmp_depth = &s.tmp_depth;
    @memset(tmp_depth, 0);
    entropy.createTree(s.cmd_histo[0..64], 15, &s.tree, depth[0..64]);
    entropy.createTree(s.cmd_histo[64..128], 14, &s.tree, depth[64..128]);
    @memcpy(tmp_depth[0..24], depth[24..48]);
    @memcpy(tmp_depth[24..32], depth[0..8]);
    @memcpy(tmp_depth[32..40], depth[48..56]);
    @memcpy(tmp_depth[40..48], depth[8..16]);
    @memcpy(tmp_depth[48..56], depth[56..64]);
    @memcpy(tmp_depth[56..64], depth[16..24]);
    entropy.codewords(tmp_depth[0..64], &s.tmp_bits);
    const b = &s.cmd_bits;
    @memcpy(b[0..8], s.tmp_bits[24..32]);
    @memcpy(b[8..16], s.tmp_bits[40..48]);
    @memcpy(b[16..24], s.tmp_bits[56..64]);
    @memcpy(b[24..48], s.tmp_bits[0..24]);
    @memcpy(b[48..56], s.tmp_bits[32..40]);
    @memcpy(b[56..64], s.tmp_bits[48..56]);
    entropy.codewords(depth[64..128], b[64..128]);
    @memset(tmp_depth[0..64], 0);
    @memcpy(tmp_depth[0..8], depth[24..32]);
    @memcpy(tmp_depth[64..72], depth[32..40]);
    @memcpy(tmp_depth[128..136], depth[40..48]);
    @memcpy(tmp_depth[192..200], depth[48..56]);
    @memcpy(tmp_depth[384..392], depth[56..64]);
    for (0..8) |i| {
        tmp_depth[128 + 8 * i] = depth[i];
        tmp_depth[256 + 8 * i] = depth[8 + i];
        tmp_depth[448 + 8 * i] = depth[16 + i];
    }
    entropy.storeTree(w, tmp_depth, &s.tree);
    entropy.storeTree(w, depth[64..128], &s.tree);
}

inline fn log2(n: usize) u32 {
    return @intCast(std.math.log2_int(usize, n));
}

/// Commands are a symbol in the low byte and its extra bits above.
const Out = struct {
    commands: []u32,
    n: usize = 0,
    literals: []u8,
    nl: usize = 0,

    inline fn put(o: *Out, v: usize) void {
        o.commands[o.n] = @intCast(v);
        o.n += 1;
    }

    fn insertLen(o: *Out, len: usize) void {
        if (len < 6) {
            o.put(len);
        } else if (len < 130) {
            const tail = len - 2;
            const nbits = log2(tail) - 1;
            const prefix = tail >> @intCast(nbits);
            o.put(((nbits << 1) + prefix + 2) | ((tail - (prefix << @intCast(nbits))) << 8));
        } else if (len < 2114) {
            const tail = len - 66;
            const nbits = log2(tail);
            o.put((nbits + 10) | ((tail - (@as(usize, 1) << @intCast(nbits))) << 8));
        } else if (len < 6210) {
            o.put(21 | ((len - 2114) << 8));
        } else if (len < 22594) {
            o.put(22 | ((len - 6210) << 8));
        } else o.put(23 | ((len - 22594) << 8));
    }

    fn copyLen(o: *Out, len: usize) void {
        if (len < 10) {
            o.put(len + 38);
        } else if (len < 134) {
            const tail = len - 6;
            const nbits = log2(tail) - 1;
            const prefix = tail >> @intCast(nbits);
            o.put(((nbits << 1) + prefix + 44) | ((tail - (prefix << @intCast(nbits))) << 8));
        } else if (len < 2118) {
            const tail = len - 70;
            const nbits = log2(tail);
            o.put((nbits + 52) | ((tail - (@as(usize, 1) << @intCast(nbits))) << 8));
        } else o.put(63 | ((len - 2118) << 8));
    }

    fn copyLenLastDistance(o: *Out, len: usize) void {
        if (len < 12) {
            o.put(len + 20);
        } else if (len < 72) {
            const tail = len - 8;
            const nbits = log2(tail) - 1;
            const prefix = tail >> @intCast(nbits);
            o.put(((nbits << 1) + prefix + 28) | ((tail - (prefix << @intCast(nbits))) << 8));
        } else if (len < 136) {
            const tail = len - 8;
            o.put(((tail >> 5) + 54) | ((tail & 31) << 8));
            o.put(64);
        } else if (len < 2120) {
            const tail = len - 72;
            const nbits = log2(tail);
            o.put((nbits + 52) | ((tail - (@as(usize, 1) << @intCast(nbits))) << 8));
            o.put(64);
        } else {
            o.put(63 | ((len - 2120) << 8));
            o.put(64);
        }
    }

    fn distance(o: *Out, dist: usize) void {
        const d = dist + 3;
        const nbits = log2(d) - 1;
        const prefix = (d >> @intCast(nbits)) & 1;
        const offset = (2 + prefix) << @intCast(nbits);
        o.put((2 * (nbits - 1) + prefix + 80) | ((d - offset) << 8));
    }

    fn literalsFrom(o: *Out, src: []const u8) void {
        @memcpy(o.literals[o.nl..][0..src.len], src);
        o.nl += src.len;
    }
};

/// Hash positions in the last copy and take the table's old entry for `ip`
/// as the next candidate. With 4-byte hashes the reference hashes `ip - 1`
/// at offset 0 after a copy with literals before it, and at offset 2 after
/// one without; both are kept.
inline fn rehash(table: []i32, data: []const u8, ip: usize, shift: u6, comptime min_match: u6, comptime after_literals: bool) usize {
    var cur: u32 = undefined;
    if (min_match == 4) {
        const v = find.load64(data, ip - 3);
        cur = hashBytes(v, 3, shift, 4);
        table[hashBytes(v, 0, shift, 4)] = @intCast(ip - 3);
        table[hashBytes(v, 1, shift, 4)] = @intCast(ip - 2);
        table[hashBytes(v, if (after_literals) 0 else 2, shift, 4)] = @intCast(ip - 1);
    } else {
        var v = find.load64(data, ip - 5);
        table[hashBytes(v, 0, shift, 6)] = @intCast(ip - 5);
        table[hashBytes(v, 1, shift, 6)] = @intCast(ip - 4);
        table[hashBytes(v, 2, shift, 6)] = @intCast(ip - 3);
        v = find.load64(data, ip - 2);
        cur = hashBytes(v, 2, shift, 6);
        table[hashBytes(v, 0, shift, 6)] = @intCast(ip - 2);
        table[hashBytes(v, 1, shift, 6)] = @intCast(ip - 1);
    }
    const candidate: usize = @intCast(table[cur]);
    table[cur] = @intCast(ip);
    return candidate;
}

/// Parse `all[input..][0..block_size]`; positions are offsets into `all`.
fn createCommands(all: []const u8, input: usize, block_size: usize, table: []i32, shift: u6, comptime min_match: u6, o: *Out) void {
    const ip_end = input + block_size;
    var next_emit = input;
    var last_distance: isize = -1;
    remainder: {
        if (block_size < input_margin) break :remainder;
        const ip_limit = input + @min(block_size - min_match, all.len - input - input_margin);
        var ip = input + 1;
        var next_hash = hashAt(all, ip, shift, min_match);
        while (true) {
            var skip: u32 = 32;
            var next_ip = ip;
            var candidate: usize = undefined;
            while (true) {
                while (true) {
                    const h = next_hash;
                    const step = skip >> 5;
                    skip += 1;
                    ip = next_ip;
                    next_ip = ip + step;
                    if (next_ip > ip_limit) break :remainder;
                    next_hash = hashAt(all, next_ip, shift, min_match);
                    const last: isize = @as(isize, @intCast(ip)) - last_distance;
                    if (isMatch(all, ip, @intCast(last), min_match) and last < @as(isize, @intCast(ip))) {
                        candidate = @intCast(last);
                        table[h] = @intCast(ip);
                        break;
                    }
                    candidate = @intCast(table[h]);
                    table[h] = @intCast(ip);
                    if (isMatch(all, ip, candidate, min_match)) break;
                }
                if (@as(isize, @intCast(ip - candidate)) <= max_distance) break;
            }
            {
                const base = ip;
                const matched = min_match + find.matchLength(all, candidate + min_match, ip + min_match, ip_end - ip - min_match);
                const distance: isize = @intCast(base - candidate);
                ip += matched;
                o.insertLen(base - next_emit);
                o.literalsFrom(all[next_emit..base]);
                if (distance == last_distance) {
                    o.put(64);
                } else {
                    o.distance(@intCast(distance));
                    last_distance = distance;
                }
                o.copyLenLastDistance(matched);
                next_emit = ip;
                if (ip >= ip_limit) break :remainder;
                candidate = rehash(table, all, ip, shift, min_match, true);
            }
            while (@as(isize, @intCast(ip)) - @as(isize, @intCast(candidate)) <= max_distance and isMatch(all, ip, candidate, min_match)) {
                const base = ip;
                const matched = min_match + find.matchLength(all, candidate + min_match, ip + min_match, ip_end - ip - min_match);
                ip += matched;
                last_distance = @intCast(base - candidate);
                o.copyLen(matched);
                o.distance(@intCast(last_distance));
                next_emit = ip;
                if (ip >= ip_limit) break :remainder;
                candidate = rehash(table, all, ip, shift, min_match, false);
            }
            ip += 1;
            next_hash = hashAt(all, ip, shift, min_match);
        }
    }
    if (next_emit < ip_end) {
        o.insertLen(ip_end - next_emit);
        o.literalsFrom(all[next_emit..ip_end]);
    }
}

const num_extra_bits = [128]u32{
    0,  0,  0,  0,  0,  0,  1,  1,  2,  2,  3,  3,  4,  4,  5,  5,
    6,  7,  8,  9,  10, 12, 14, 24, 0,  0,  0,  0,  0,  0,  0,  0,
    1,  1,  2,  2,  3,  3,  4,  4,  0,  0,  0,  0,  0,  0,  0,  0,
    1,  1,  2,  2,  3,  3,  4,  4,  5,  5,  6,  7,  8,  9,  10, 24,
    0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,  0,
    1,  1,  2,  2,  3,  3,  4,  4,  5,  5,  6,  6,  7,  7,  8,  8,
    9,  9,  10, 10, 11, 11, 12, 12, 13, 13, 14, 14, 15, 15, 16, 16,
    17, 17, 18, 18, 19, 19, 20, 20, 21, 21, 22, 22, 23, 23, 24, 24,
};

const insert_offset = [24]u32{ 0, 1, 2, 3, 4, 5, 6, 8, 10, 14, 18, 26, 34, 50, 66, 98, 130, 194, 322, 578, 1090, 2114, 6210, 22594 };

fn storeCommands(s: *Arena, literals: []const u8, commands: []const u32, w: *Writer) void {
    @memset(&s.lit_histo, 0);
    @memset(&s.cmd_depth, 0);
    @memset(&s.cmd_bits, 0);
    @memset(&s.cmd_histo, 0);
    for (literals) |l| s.lit_histo[l] += 1;
    entropy.buildAndStoreFast(w, &s.tree, &s.lit_histo, literals.len, 8, &s.lit_depth, &s.lit_bits);
    for (commands) |c| s.cmd_histo[c & 0xff] += 1;
    s.cmd_histo[1] += 1;
    s.cmd_histo[2] += 1;
    s.cmd_histo[64] += 1;
    s.cmd_histo[84] += 1;
    commandCode(s, w);
    var lit: usize = 0;
    for (commands) |c| {
        const code = c & 0xff;
        const extra = c >> 8;
        w.bits(s.cmd_depth[code], s.cmd_bits[code]);
        w.bits(num_extra_bits[code], extra);
        if (code < 24) {
            const insert = insert_offset[code] + extra;
            for (literals[lit..][0..insert]) |l| w.bits(s.lit_depth[l], s.lit_bits[l]);
            lit += insert;
        }
    }
}

fn shouldCompress(s: *Arena, input: []const u8, num_literals: usize) bool {
    const corpus_size: f64 = @floatFromInt(input.len);
    if (@as(f64, @floatFromInt(num_literals)) < min_ratio * corpus_size) return true;
    const max_total_bit_cost = corpus_size * 8 * min_ratio / sample_rate;
    @memset(&s.lit_histo, 0);
    var i: usize = 0;
    while (i < input.len) : (i += sample_rate) s.lit_histo[input[i]] += 1;
    return cost.bitsEntropy(&s.lit_histo) < max_total_bit_cost;
}

fn compressImpl(s: *Arena, all: []const u8, command_buf: []u32, literal_buf: []u8, table: []i32, table_bits: u6, comptime min_match: u6, w: *Writer) void {
    const shift: u6 = @intCast(64 - @as(u7, table_bits));
    var input: usize = 0;
    while (input < all.len) {
        const block_size = @min(all.len - input, block_size_max);
        var o: Out = .{ .commands = command_buf, .literals = literal_buf };
        createCommands(all, input, block_size, table, shift, min_match, &o);
        const block = all[input..][0..block_size];
        if (shouldCompress(s, block, o.nl)) {
            fragment.metaBlockHeader(w, block_size, false);
            w.bits(13, 0);
            storeCommands(s, literal_buf[0..o.nl], command_buf[0..o.n], w);
        } else {
            // Few copies and literals near 8 bits each: stored raw.
            fragment.metaBlockHeader(w, block_size, true);
            w.alignByte();
            w.bytes(block);
        }
        input += block_size;
    }
}

/// Compress `input` as quality 1 does: `table` of 2^8-2^17 entries, zeroed;
/// the buffers hold `min(input.len, 128 KiB)` entries.
pub fn compress(s: *Arena, input: []const u8, is_last: bool, command_buf: []u32, literal_buf: []u8, table: []i32, w: *Writer) void {
    const start = w.pos;
    const table_bits: u6 = @intCast(std.math.log2_int(usize, table.len));
    std.debug.assert(table_bits >= 8);
    std.debug.assert(table_bits <= 17);
    if (table_bits <= 15) {
        compressImpl(s, input, command_buf, literal_buf, table, table_bits, 4, w);
    } else compressImpl(s, input, command_buf, literal_buf, table, table_bits, 6, w);
    // Larger than one uncompressed meta-block: write that instead.
    if (w.pos - start > 31 + (input.len << 3)) {
        fragment.rewind(w, start);
        fragment.metaBlockHeader(w, input.len, true);
        w.alignByte();
        w.bytes(input);
    }
    if (is_last) {
        w.bits(1, 1);
        w.bits(1, 1);
        w.alignByte();
    }
}
