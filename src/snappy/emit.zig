//! Writing a block's elements: literals, copies and (S2) repeats, each
//! reference's way. google's and S2's encoders split long copies and
//! choose between copy forms differently, so each has its own emitters,
//! line for line; a byte-for-byte parse needs the same.
//!
//! Every emitter writes to `out[at..]` and returns where it ended; the
//! caller has kept `bound` room.

const std = @import("std");

const tag_literal = 0;
const tag_copy1 = 1;
const tag_copy2 = 2;
const tag_copy4 = 3;

/// The varint of a block's decoded length; where it ended.
pub fn length(out: []u8, at: usize, len: u32) usize {
    var o = at;
    var v = len;
    while (v >= 0x80) : (v >>= 7) {
        out[o] = @as(u8, @truncate(v)) | 0x80;
        o += 1;
    }
    out[o] = @intCast(v);
    return o + 1;
}

/// A literal of `in[start..][0..len]` (`len` 1 or more): its length in the
/// tag up to 60, else in the 1-4 bytes after it, as both references write
/// it. Short ones are stored 16 bytes at once where both buffers have room.
pub inline fn literal(out: []u8, at: usize, in: []const u8, start: usize, len: usize) usize {
    const n = len - 1;
    var o = at;
    if (n < 60) {
        out[o] = tag_literal | @as(u8, @intCast(n)) << 2;
        o += 1;
    } else {
        const count: usize = (std.math.log2_int(usize, n) >> 3) + 1;
        out[o] = tag_literal | @as(u8, @intCast(59 + count)) << 2;
        for (0..count) |i| out[o + 1 + i] = @truncate(n >> @intCast(8 * i));
        o += 1 + count;
    }
    if (len <= 16 and out.len - o >= 16 and in.len - start >= 16) {
        out[o..][0..16].* = in[start..][0..16].*;
    } else @memcpy(out[o..][0..len], in[start..][0..len]);
    return o + len;
}

/// google's copy of 4 to 64 bytes from `offset` (below 64 KiB) back: a
/// 1-byte-offset copy when it is shorter than 12 and the offset below
/// 2048, else a 2-byte-offset one.
inline fn googleCopyAtMost64(out: []u8, at: usize, offset: usize, len: usize) usize {
    if (len < 12 and offset < 2048) {
        out[at] = @intCast(tag_copy1 | (len - 4) << 2 | (offset >> 8) << 5);
        out[at + 1] = @truncate(offset);
        return at + 2;
    }
    out[at] = @intCast(tag_copy2 | (len - 1) << 2);
    std.mem.writeInt(u16, out[at + 1 ..][0..2], @intCast(offset), .little);
    return at + 3;
}

/// google's `EmitCopy`: copies of 64 while 68 or more remain, one of 60
/// where more than 64 remain, then the rest.
pub inline fn googleCopy(out: []u8, at: usize, offset: usize, len_in: usize) usize {
    var len = len_in;
    var o = at;
    while (len >= 68) : (len -= 64) o = googleCopyAtMost64(out, o, offset, 64);
    if (len > 64) {
        o = googleCopyAtMost64(out, o, offset, 60);
        len -= 60;
    }
    return googleCopyAtMost64(out, o, offset, len);
}

/// The longest repeat one element holds in S2's assembly encoders: a
/// 24-bit length past 65540.
const max_repeat = ((1 << 24) - 1) + 65536;

/// S2's repeat of `len_in` (4 or more) from `offset` back, as its
/// assembly encoders write it for blocks of at most `max_len` bytes:
/// lengths 4-8 in two bytes; 9-11 from an offset below 2048 as a 1-byte-
/// offset copy (where the class reaches such offsets); then 1, 2 or 3
/// length bytes; past `max_repeat`, repeats of that length first.
pub fn s2Repeat(comptime max_len: u64, out: []u8, at: usize, offset: usize, len_in: usize) usize {
    var o = at;
    var len = len_in;
    while (true) {
        const l = len - 4;
        if (len <= 8) {
            out[o] = @intCast(tag_copy1 | l << 2);
            out[o + 1] = 0;
            return o + 2;
        }
        if (max_len >= 2048 and len < 12 and offset < 2048) {
            out[o] = @intCast(tag_copy1 | l << 2 | (offset >> 8) << 5);
            out[o + 1] = @truncate(offset);
            return o + 2;
        }
        if (l < 260) {
            out[o..][0..3].* = .{ 5 << 2 | tag_copy1, 0, @intCast(l - 4) };
            return o + 3;
        }
        if (max_len < (1 << 16) + (1 << 8) or l < (1 << 16) + (1 << 8)) {
            out[o..][0..2].* = .{ 6 << 2 | tag_copy1, 0 };
            std.mem.writeInt(u16, out[o + 2 ..][0..2], @intCast(l - 256), .little);
            return o + 4;
        }
        if (max_len >= max_repeat and l >= max_repeat) {
            out[o..][0..5].* = .{ 7 << 2 | tag_copy1, 0, 0xfb, 0xff, 0xff };
            o += 5;
            len = l - (max_repeat - 4);
            continue;
        }
        const v = l - 65536;
        out[o..][0..5].* = .{ 7 << 2 | tag_copy1, 0, @truncate(v), @truncate(v >> 8), @truncate(v >> 16) };
        return o + 5;
    }
}

inline fn copy4(out: []u8, at: usize, offset: usize, len: usize) usize {
    out[at] = @intCast(tag_copy4 | (len - 1) << 2);
    std.mem.writeInt(u32, out[at + 1 ..][0..4], @intCast(offset), .little);
    return at + 5;
}

inline fn copy2(out: []u8, at: usize, offset: usize, len: usize) usize {
    out[at] = @intCast(tag_copy2 | (len - 1) << 2);
    std.mem.writeInt(u16, out[at + 1 ..][0..2], @intCast(offset), .little);
    return at + 3;
}

/// A copy of at most 64 bytes, by S2's choice: 1-byte offset below 12
/// bytes and 2048 back, else 2-byte.
inline fn s2CopyShort(comptime max_len: u64, out: []u8, at: usize, offset: usize, len: usize) usize {
    if (len >= 12 or (max_len - 1 >= 2048 and offset >= 2048)) return copy2(out, at, offset, len);
    out[at] = @intCast(tag_copy1 | (len - 4) << 2 | (offset >> 8) << 5);
    out[at + 1] = @truncate(offset);
    return at + 2;
}

/// S2's copy of `len` (4 or more) from `offset` back, as its assembly
/// encoders write it for blocks of at most `max_len` bytes: past 64 bytes,
/// a first copy (64 at a 4-byte offset, 8 at a 1-byte one, or 60) and the
/// rest as a repeat.
pub fn s2Copy(comptime max_len: u64, out: []u8, at: usize, offset: usize, len_in: usize) usize {
    var o = at;
    var len = len_in;
    if (max_len - 1 >= 65536 and offset >= 65536) {
        if (len > 64) {
            o = copy4(out, o, offset, 64);
            len -= 64;
            if (len >= 4) return s2Repeat(max_len, out, o, offset, len);
        }
        if (len == 0) return o;
        return copy4(out, o, offset, len);
    }
    if (len > 64) {
        if (offset < 2048) {
            out[o] = @intCast(tag_copy1 | (8 - 4) << 2 | (offset >> 8) << 5);
            out[o + 1] = @truncate(offset);
            return s2Repeat(max_len, out, o + 2, offset, len - 8);
        }
        o = copy2(out, o, offset, 60);
        return s2Repeat(max_len, out, o, offset, len - 60);
    }
    return s2CopyShort(max_len, out, o, offset, len);
}

/// S2's copy for the Snappy format, no repeats: copies of 64 at a 4-byte
/// offset, or of 60 at a 2-byte one, while more than 64 remain.
pub fn s2CopyNoRepeat(comptime max_len: u64, out: []u8, at: usize, offset: usize, len_in: usize) usize {
    var o = at;
    var len = len_in;
    if (max_len - 1 >= 65536 and offset >= 65536) {
        while (len > 64) {
            o = copy4(out, o, offset, 64);
            len -= 64;
            if (len < 4) break;
        }
        if (len == 0) return o;
        return copy4(out, o, offset, len);
    }
    while (len > 64) : (len -= 60) o = copy2(out, o, offset, 60);
    return s2CopyShort(max_len, out, o, offset, len);
}

/// The most bytes a literal's length takes in a block of at most `n`
/// bytes, as S2's assembly reserves it.
pub fn literalOverhead(n: u64) usize {
    if (n == 0) return 0;
    if (n < 60) return 1;
    if (n < 1 << 8) return 2;
    if (n < 1 << 16) return 3;
    if (n < 1 << 24) return 4;
    return 5;
}

test "google's copies: a long one split as EmitCopy splits it" {
    var out: [16]u8 = undefined;
    // 131 = 64 + 60 + 7: two 2-byte-offset copies, then a 1-byte one.
    const n = googleCopy(&out, 0, 10, 131);
    try std.testing.expectEqualSlices(u8, &.{ 0xfe, 10, 0, 0xee, 10, 0, 0x0d, 10 }, out[0..n]);
}

test "S2's repeats: the lengths of one to three bytes, and the split past 24 bits" {
    var out: [16]u8 = undefined;
    const max = std.math.maxInt(u32);
    try std.testing.expectEqualSlices(u8, &.{ 0x11, 0 }, out[0..s2Repeat(max, &out, 0, 5000, 8)]);
    // 10 from 300 back: a 1-byte-offset copy; in the 511-byte class, a repeat.
    try std.testing.expectEqualSlices(u8, &.{ 0x39, 44 }, out[0..s2Repeat(max, &out, 0, 300, 10)]);
    try std.testing.expectEqualSlices(u8, &.{ 0x15, 0, 2 }, out[0..s2Repeat(511, &out, 0, 300, 10)]);
    try std.testing.expectEqualSlices(u8, &.{ 0x15, 0, 252 }, out[0..s2Repeat(max, &out, 0, 5000, 260)]);
    try std.testing.expectEqualSlices(u8, &.{ 0x19, 0, 4, 0 }, out[0..s2Repeat(max, &out, 0, 5000, 264)]);
    try std.testing.expectEqualSlices(u8, &.{ 0x1d, 0, 0xfe, 0xff, 0xff }, out[0..s2Repeat(max, &out, 0, 5000, max_repeat + 3)]);
    // One past: a full repeat of `max_repeat`, then one of 4.
    try std.testing.expectEqualSlices(u8, &.{ 0x1d, 0, 0xfb, 0xff, 0xff, 0x01, 0 }, out[0..s2Repeat(max, &out, 0, 5000, max_repeat + 4)]);
}
