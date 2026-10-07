//! Where a full 128 KiB block should end, from byte statistics: the
//! reference encoder's pre-splitter. Compression of a block whose second
//! part differs from its first is better as two blocks, each with its own
//! tables. Level 0 compares the block's two ends (and its middle); levels
//! 1-4 grow a fingerprint chunk by chunk, sampled ever more densely, and
//! cut where a chunk departs from what came before.

const std = @import("std");

const chunk = 8 << 10;
const threshold_rate = 16;
const threshold_base = threshold_rate - 2;
const threshold_penalty = 3;

const Fingerprint = struct {
    events: [1 << 10]u32 = @splat(0),
    count: u64 = 0,
};

/// The size of the first block to cut from `block` (128 KiB).
pub fn split(block: []const u8, level: u3) usize {
    std.debug.assert(block.len == 128 << 10);
    if (level == 0) return fromBorders(block);
    return byChunks(block, level - 1);
}

fn byteHistogram(fp: *Fingerprint, bytes: []const u8) void {
    for (bytes) |b| fp.events[b] += 1;
}

fn distance(a: *const Fingerprint, b: *const Fingerprint, log: u4) u64 {
    var d: u64 = 0;
    for (a.events[0 .. @as(usize, 1) << log], b.events[0 .. @as(usize, 1) << log]) |x, y| {
        const l: i64 = @as(i64, x) * @as(i64, @intCast(b.count));
        const r: i64 = @as(i64, y) * @as(i64, @intCast(a.count));
        d += @abs(l - r);
    }
    return d;
}

fn differ(past: *const Fingerprint, new: *const Fingerprint, penalty: u32, log: u4) bool {
    const p50 = past.count * new.count;
    const deviation = distance(past, new, log);
    const threshold = p50 * (threshold_base + penalty) / threshold_rate;
    return deviation >= threshold;
}

fn fromBorders(block: []const u8) usize {
    const segment = 512;
    var begin: Fingerprint = .{};
    var end: Fingerprint = .{};
    byteHistogram(&begin, block[0..segment]);
    byteHistogram(&end, block[block.len - segment ..]);
    begin.count = segment;
    end.count = segment;
    if (!differ(&begin, &end, 0, 8)) return block.len;
    var middle: Fingerprint = .{};
    byteHistogram(&middle, block[block.len / 2 - segment / 2 ..][0..segment]);
    middle.count = segment;
    const from_begin = distance(&begin, &middle, 8);
    const from_end = distance(&end, &middle, 8);
    const min_distance = segment * segment / 3;
    if (@abs(@as(i64, @intCast(from_begin)) - @as(i64, @intCast(from_end))) < min_distance) return 64 << 10;
    return if (from_begin > from_end) 32 << 10 else 96 << 10;
}

fn record(fp: *Fingerprint, bytes: []const u8, rate: usize, log: u4) void {
    @memset(fp.events[0 .. @as(usize, 1) << log], 0);
    const limit = bytes.len - 2 + 1;
    var n: usize = 0;
    while (n < limit) : (n += rate) fp.events[hash2(bytes[n..], log)] += 1;
    fp.count = limit / rate;
}

inline fn hash2(p: []const u8, log: u4) u32 {
    if (log == 8) return p[0];
    return (@as(u32, std.mem.readInt(u16, p[0..2], .little)) *% 0x9e3779b9) >> @intCast(@as(u6, 32) - log);
}

fn byChunks(block: []const u8, level: u3) usize {
    const rates = [4]usize{ 43, 11, 5, 1 };
    const logs = [4]u4{ 8, 9, 10, 10 };
    const rate = rates[level];
    const log = logs[level];
    var past: Fingerprint = .{};
    var new: Fingerprint = .{};
    var penalty: u32 = threshold_penalty;
    record(&past, block[0..chunk], rate, log);
    var pos: usize = chunk;
    while (pos <= block.len - chunk) : (pos += chunk) {
        record(&new, block[pos..][0..chunk], rate, log);
        if (differ(&past, &new, penalty, log)) return pos;
        for (past.events[0 .. @as(usize, 1) << log], new.events[0 .. @as(usize, 1) << log]) |*a, b| a.* += b;
        past.count += new.count;
        if (penalty > 0) penalty -= 1;
    }
    return block.len;
}

test "a block of one kind is not cut; two halves of different bytes are" {
    var block: [128 << 10]u8 = undefined;
    for (&block, 0..) |*b, i| b.* = @truncate(i *% 7);
    try std.testing.expectEqual(@as(usize, 128 << 10), split(&block, 0));
    try std.testing.expectEqual(@as(usize, 128 << 10), split(&block, 3));
    for (block[64 << 10 ..], 0..) |*b, i| b.* = 'a' + @as(u8, @truncate(i % 3));
    try std.testing.expect(split(&block, 0) < 128 << 10);
    try std.testing.expectEqual(@as(usize, 64 << 10), split(&block, 4));
}
