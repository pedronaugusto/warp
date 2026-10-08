//! Read-only dictionary candidates, indexed once. Their matches are merged
//! with a strategy's prefix parse before entropy coding.
const std = @import("std");
const window = @import("window.zig");
const sequences = @import("../sequences.zig");

pub const Index = struct {
    content: []const u8,
    heads: []u32,
    chain: []u32,
    log: u5,

    /// Earlier bytes cannot be named by an offBase (distance plus three).
    pub fn contentLen(len: usize) usize {
        return @min(len, std.math.maxInt(u32) - 3);
    }

    pub fn hashLog(len: usize) u5 {
        return @intCast(std.math.clamp(std.math.log2_int(usize, @max(len, 1)), 6, 17));
    }

    pub fn init(content: []const u8, heads: []u32, chain: []u32) Index {
        const index: Index = .{ .content = content, .heads = heads, .chain = chain, .log = hashLog(content.len) };
        @memset(heads, 0);
        @memset(chain, 0);
        if (content.len >= 4) for (0..content.len - 3) |p| {
            const h = window.hash(4, content, p, index.log);
            chain[p] = heads[h];
            heads[h] = @intCast(p + 1);
        };
        return index;
    }

    const Match = struct { distance: u32 = 0, len: usize = 0 };

    fn find(index: *const Index, in: []const u8, pos: usize, end: usize, frame_pos: u64, window_log: u5, attempts: usize) Match {
        if (pos + 4 > end or frame_pos > @as(u64, 1) << window_log) return .{};
        var entry = index.heads[window.hash(4, in, pos, index.log)];
        var left = attempts;
        var best: Match = .{};
        while (entry != 0 and left != 0) : (left -= 1) {
            const at: usize = entry - 1;
            const distance = frame_pos + index.content.len - at;
            if (distance <= std.math.maxInt(u32) - 3 and window.read32(in, pos) == window.read32(index.content, at)) {
                const len = index.count(in, pos, end, at);
                if (len > best.len) best = .{ .distance = @intCast(distance), .len = len };
                if (pos + len == end) break;
            }
            entry = index.chain[at];
        }
        return best;
    }

    fn count(index: *const Index, in: []const u8, pos: usize, end: usize, at: usize) usize {
        const limit = @min(index.content.len - at, end - pos);
        var len: usize = 4;
        while (len + 8 <= limit) {
            const a = std.mem.readInt(u64, index.content[at + len ..][0..8], .little);
            const b = std.mem.readInt(u64, in[pos + len ..][0..8], .little);
            const x = a ^ b;
            if (x != 0) return len + @ctz(x) / 8;
            len += 8;
        }
        while (len < limit and index.content[at + len] == in[pos + len]) len += 1;
        // A dictionary match may continue through the dictionary's end
        // into already decoded input. The caller supplies that prefix.
        if (len == index.content.len - at) {
            var source: usize = 0;
            while (pos + len < end and in[source] == in[pos + len]) {
                len += 1;
                source += 1;
            }
        }
        return len;
    }
};

/// Merge immutable dictionary candidates with prefix sequences. Prefix
/// distances are resolved before repeat history changes; entropy sees one
/// sequence stream and the resulting repeat offsets.
pub fn merge(index: *const Index, store: *sequences.SeqStore, scratch: []sequences.Sequence, in: []const u8, start: usize, end: usize, frame_start: u64, window_log: u5, search_log: u5, reps: *[3]u32) void {
    const count = store.count;
    const long = store.long;
    var parse_reps = reps.*;
    for (store.seqs[0..count], scratch[0..count], 0..) |q, *copy, i| {
        copy.* = q;
        const zero = store.litLen(i) == 0;
        copy.off = sequences.distance(parse_reps, q.off, zero) + 3;
        parse_reps = sequences.updateReps(parse_reps, q.off, zero);
    }
    store.reset();
    var pos = start;
    var anchor = start;
    var sequence: usize = 0;
    var prefix_start = start;
    var prefix_end = start;
    const attempts = @as(usize, 1) << @min(search_log, 12);
    while (pos < end) {
        while (pos >= prefix_end and sequence < count) {
            const q = scratch[sequence];
            prefix_start = prefix_end + q.lit;
            if (long) |l| if (!l.match and l.index == sequence) {
                prefix_start += 0x10000;
            };
            prefix_end = prefix_start + @as(usize, q.ml) + 3;
            if (long) |l| if (l.match and l.index == sequence) {
                prefix_end += 0x10000;
            };
            sequence += 1;
        }
        if (sequence != 0 and pos >= prefix_start and pos < prefix_end and prefix_end - pos >= 4) {
            const distance = scratch[sequence - 1].off - 3;
            emit(store, in, anchor, pos, end, distance, prefix_end - pos, reps);
            pos = prefix_end;
            anchor = pos;
            continue;
        }
        const m = index.find(in, pos, end, frame_start + pos - start, window_log, attempts);
        if (m.len >= 4) {
            emit(store, in, anchor, pos, end, m.distance, m.len, reps);
            pos += m.len;
            anchor = pos;
        } else pos += 1;
    }
    store.storeLast(in[anchor..end]);
}

fn emit(store: *sequences.SeqStore, in: []const u8, from: usize, to: usize, end: usize, distance: u32, len: usize, reps: *[3]u32) void {
    var off = distance + 3;
    for (1..4) |code| {
        if (to == from and code == 3 and reps[0] == 1) continue;
        if (sequences.distance(reps.*, @intCast(code), to == from) == distance) {
            off = @intCast(code);
            break;
        }
    }
    store.store(in, from, to, end, off, len);
    reps.* = sequences.updateReps(reps.*, off, to == from);
}
