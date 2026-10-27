//! google/snappy 1.3.1's two parsers, line for line: the input cut into
//! fragments of 64 KiB, each with its own table of 16-bit positions
//! cleared to the fragment's size (256 to 32 Ki entries).
//!
//! Level 1 (`CompressFragment`) probes one table per position, the first
//! 16 positions after a literal's start one by one, then further apart the
//! longer nothing matches (every `skip >> 5` bytes, `skip` growing by that
//! step). Its hash is the portable build's, `0x1e35a7bd * bytes`: builds
//! for SSE4.2 or ARM's CRC instructions hash with CRC-32C instead and
//! write other blocks, so warp writes this one on every target.
//!
//! Level 2 (`CompressFragmentDoubleHash`) keeps a table of 8-byte hashes
//! and one of 4-byte hashes (half the entries each), prefers the 8-byte
//! candidate, tries the next position's 8-byte one against a 4-byte match,
//! extends a match backwards, and indexes more positions after each copy.

const std = @import("std");
const emit = @import("emit.zig");

/// The input is compressed in fragments of this many bytes.
pub const fragment_len = 1 << 16;
/// The most table entries a fragment takes (both levels together).
pub const max_table = 1 << 15;
const min_table = 1 << 8;

/// The input margin the parsers keep: no match starts in a fragment's
/// last 15 bytes.
const margin = 15;

pub const Level = enum { one, two };

/// The table entries a fragment of `len` bytes takes: a power of two from
/// 256 to 32 Ki at least `len`.
pub fn tableSize(len: usize) usize {
    if (len > max_table) return max_table;
    if (len < min_table) return min_table;
    return @as(usize, 2) << std.math.log2_int(usize, len - 1);
}

/// The elements of `in`, fragment by fragment, into `out[at..]` (room for
/// `bound`); where they end. `table` holds `max_table` entries.
pub fn compress(level: Level, in: []const u8, out: []u8, at: usize, table: []u16) usize {
    var o = at;
    var pos: usize = 0;
    while (pos < in.len) {
        const n = @min(in.len - pos, fragment_len);
        const size = tableSize(n);
        @memset(table[0..size], 0);
        const fragment = in[pos..][0..n];
        o = switch (level) {
            .one => one(fragment, out, o, table[0..size]),
            .two => two(fragment, out, o, table[0 .. size / 2], table[size / 2 .. size]),
        };
        pos += n;
    }
    return o;
}

inline fn load32(in: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, in[at..][0..4], .little);
}

inline fn load64(in: []const u8, at: usize) u64 {
    return std.mem.readInt(u64, in[at..][0..8], .little);
}

/// Level 1's table entry for four bytes.
inline fn hash1(bytes: u32, size: usize) usize {
    return ((bytes *% 0x1e35a7bd) >> 17) & (size - 1);
}

/// Level 2's entries: for four bytes, and for eight.
inline fn hash4(bytes: u32, size: usize) usize {
    return ((bytes *% 2654435761) >> 18) & (size - 1);
}

inline fn hash8(bytes: u64, size: usize) usize {
    return @intCast(((bytes *% 58295818150454627) >> 50) & (size - 1));
}

/// How many bytes from `a` match those from `b` (`a < b`), to the end.
inline fn matchLen(in: []const u8, a: usize, b: usize) usize {
    var n: usize = 0;
    while (b + n + 8 <= in.len) {
        const x = load64(in, a + n) ^ load64(in, b + n);
        if (x != 0) return n + @ctz(x) / 8;
        n += 8;
    }
    while (b + n < in.len and in[a + n] == in[b + n]) n += 1;
    return n;
}

/// `CompressFragment`.
fn one(in: []const u8, out: []u8, at: usize, table: []u16) usize {
    const size = table.len;
    var o = at;
    var ip: usize = 0;
    if (in.len >= margin) outer: {
        const limit = in.len - margin;
        var preload = load32(in, 1);
        while (true) {
            const next_emit = ip;
            ip += 1;
            var data = load64(in, ip);
            var skip: u32 = 32;
            var candidate: usize = undefined;
            found: {
                if (ip + 16 <= limit) {
                    // The first 16 positions one by one, from loads already
                    // made.
                    for (0..4) |j| {
                        for (0..4) |k| {
                            const i = 4 * j + k;
                            const dword: u32 = if (i == 0) preload else @truncate(data);
                            const e = hash1(dword, size);
                            candidate = table[e];
                            table[e] = @intCast(ip + i);
                            if (load32(in, candidate) == dword) {
                                o = emit.literal(out, o, in, next_emit, i + 1);
                                ip += i;
                                break :found;
                            }
                            data >>= 8;
                        }
                        data = load64(in, ip + 4 * j + 4);
                    }
                    ip += 16;
                    skip += 16;
                }
                while (true) {
                    const dword: u32 = @truncate(data);
                    const e = hash1(dword, size);
                    const step = skip >> 5;
                    skip += step;
                    const next_ip = ip + step;
                    if (next_ip > limit) {
                        ip = next_emit;
                        break :outer;
                    }
                    candidate = table[e];
                    table[e] = @intCast(ip);
                    if (dword == load32(in, candidate)) break;
                    data = load32(in, next_ip);
                    ip = next_ip;
                }
                o = emit.literal(out, o, in, next_emit, ip - next_emit);
            }
            // Copies while the position after each starts another match.
            while (true) {
                const base = ip;
                const matched = 4 + matchLen(in, candidate + 4, ip + 4);
                ip += matched;
                o = emit.googleCopy(out, o, base - candidate, matched);
                if (ip >= limit) break :outer;
                table[hash1(load32(in, ip - 1), size)] = @intCast(ip - 1);
                const cur = load32(in, ip);
                const e = hash1(cur, size);
                candidate = table[e];
                table[e] = @intCast(ip);
                if (cur != load32(in, candidate)) break;
            }
            preload = load32(in, ip + 1);
        }
    }
    if (ip < in.len) o = emit.literal(out, o, in, ip, in.len - ip);
    return o;
}

/// `CompressFragmentDoubleHash`: `table` of 4-byte hashes, `table2` of
/// 8-byte ones.
fn two(in: []const u8, out: []u8, at: usize, table: []u16, table2: []u16) usize {
    const size = table.len;
    var o = at;
    var ip: usize = 0;
    if (in.len >= margin) outer: {
        const limit = in.len - margin;
        while (true) {
            const next_emit = ip;
            ip += 1;
            var data = load64(in, ip);
            var skip: u32 = 512;
            var candidate: usize = undefined;
            var candidate_len: usize = undefined;
            while (true) {
                const e2 = hash8(data, size);
                const step = skip >> 9;
                skip += 1;
                const next_ip = ip + step;
                if (next_ip > limit) {
                    ip = next_emit;
                    break :outer;
                }
                candidate = table2[e2];
                table2[e2] = @intCast(ip);
                if (@as(u32, @truncate(data)) == load32(in, candidate)) {
                    candidate_len = matchLen(in, candidate + 4, ip + 4) + 4;
                    break;
                }
                const e = hash4(@truncate(data), size);
                candidate = table[e];
                table[e] = @intCast(ip);
                if (@as(u32, @truncate(data)) == load32(in, candidate)) {
                    candidate_len = matchLen(in, candidate + 4, ip + 4) + 4;
                    const next2 = hash8(load64(in, ip + 1), size);
                    const candidate2: usize = table2[next2];
                    const len2 = matchLen(in, candidate2, ip + 1);
                    if (len2 > candidate_len) {
                        table2[next2] = @intCast(ip);
                        candidate = candidate2;
                        candidate_len = len2;
                        ip += 1;
                    }
                    break;
                }
                data = load64(in, next_ip);
                ip = next_ip;
            }
            // Backwards while the bytes before both agree.
            while (ip > next_emit and candidate > 0 and in[ip - 1] == in[candidate - 1]) {
                ip -= 1;
                candidate -= 1;
                candidate_len += 1;
            }
            table2[hash8(load64(in, ip + 1), size)] = @intCast(ip + 1);
            table2[hash8(load64(in, ip + 2), size)] = @intCast(ip + 2);
            table[hash4(load32(in, ip + 1), size)] = @intCast(ip + 1);
            if (ip > next_emit) o = emit.literal(out, o, in, next_emit, ip - next_emit);
            while (true) {
                const base = ip;
                ip += candidate_len;
                o = emit.googleCopy(out, o, base - candidate, candidate_len);
                if (ip >= limit) break :outer;
                if (ip > 7) {
                    table2[hash8(load64(in, ip - 7), size)] = @intCast(ip - 7);
                    table2[hash8(load64(in, ip - 4), size)] = @intCast(ip - 4);
                }
                table2[hash8(load64(in, ip - 3), size)] = @intCast(ip - 3);
                table2[hash8(load64(in, ip - 2), size)] = @intCast(ip - 2);
                table[hash4(load32(in, ip - 2), size)] = @intCast(ip - 2);
                table[hash4(load32(in, ip - 1), size)] = @intCast(ip - 1);
                const cur = load32(in, ip);
                const e2 = hash8(load64(in, ip), size);
                candidate = table2[e2];
                table2[e2] = @intCast(ip);
                if (cur == load32(in, candidate)) {
                    candidate_len = matchLen(in, candidate + 4, ip + 4) + 4;
                    continue;
                }
                const e = hash4(cur, size);
                candidate = table[e];
                table[e] = @intCast(ip);
                if (cur == load32(in, candidate)) {
                    candidate_len = matchLen(in, candidate + 4, ip + 4) + 4;
                    continue;
                }
                break;
            }
        }
    }
    if (ip < in.len) o = emit.literal(out, o, in, ip, in.len - ip);
    return o;
}

test "table sizes: a power of two from 256 to 32 Ki covering the fragment" {
    try std.testing.expectEqual(@as(usize, 256), tableSize(1));
    try std.testing.expectEqual(@as(usize, 1024), tableSize(1000));
    try std.testing.expectEqual(@as(usize, 1024), tableSize(1024));
    try std.testing.expectEqual(@as(usize, 2048), tableSize(1025));
    try std.testing.expectEqual(@as(usize, 32768), tableSize(65536));
}
