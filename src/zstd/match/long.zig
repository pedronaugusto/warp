//! Sparse long-distance matches over a rolling 64-byte content hash.
//! Sixteen candidates per bucket retain distant anchors without indexing
//! every byte. Matches feed the regular parser's gaps and block encoder.
const window = @import("window.zig");
const Params = @import("../params.zig").Params;

const min_match = 64;
const bucket_log = 4;
const bucket_size = 1 << bucket_log;

pub const Entry = struct { index: u32, tag: u32 };
// Positions fit the window's index space; lengths fit one block.
pub const Match = struct { at: u32, len: u32, distance: u32 };

pub const State = struct {
    entries: []Entry,
    heads: []u8,
    matches: []Match,
    hash: u64 = 0,
    bytes: usize = 0,
    count: usize = 0,

    pub fn hashLog(p: Params) u5 {
        return @max(6, p.window_log -| 7);
    }

    pub fn init(entries: []Entry, heads: []u8, matches: []Match) State {
        @memset(entries, .{ .index = 0, .tag = 0 });
        @memset(heads, 0);
        return .{ .entries = entries, .heads = heads, .matches = matches };
    }

    pub fn reset(s: *State) void {
        s.hash = 0;
        s.bytes = 0;
        s.count = 0;
    }

    pub fn reduceIndices(s: *State, amount: u32) void {
        for (s.entries) |*entry| entry.index -|= amount;
    }

    /// Produce non-overlapping long matches in this block. Rolling hash
    /// and sparse insertion continue across blocks and streaming compaction.
    pub fn generate(s: *State, w: window.Window, start: usize, end: usize) []const Match {
        s.count = 0;
        var covered = start;
        const mask = s.heads.len - 1;
        const warm: usize = @min(s.bytes, min_match);
        var at = start;
        const warm_end = @min(end, start + @max(min_match - warm -| 1, min_match -| (start + 1)));
        while (at < warm_end) : (at += 1) s.hash = (s.hash << 1) +% gear[w.in[at]];
        while (at < end) : (at += 1) {
            s.hash = (s.hash << 1) +% gear[w.in[at]];
            if (s.hash & 127 != 0) continue;
            const pos = at + 1 - min_match;
            const curr = w.index(pos);
            const bucket: usize = @intCast((s.hash >> 7) & mask);
            const tag: u32 = @truncate(s.hash >> 32);
            const entries = s.entries[bucket * bucket_size ..][0..bucket_size];
            var best: Match = .{ .at = @intCast(pos), .len = 0, .distance = 0 };
            if (pos >= covered) for (entries) |entry| {
                if (entry.tag != tag or entry.index < w.low or entry.index >= curr) continue;
                const candidate = w.at(entry.index);
                if (window.read32(w.in, candidate) != window.read32(w.in, pos)) continue;
                var len = window.count(w.in, candidate, pos, end);
                if (len < min_match) continue;
                var back: usize = 0;
                const low: usize = w.at(w.low);
                while (pos - back > covered and candidate - back > low and w.in[pos - back - 1] == w.in[candidate - back - 1]) back += 1;
                len += back;
                const distance = curr - entry.index;
                if (len > best.len or (len == best.len and distance < best.distance)) best = .{ .at = @intCast(pos - back), .len = @intCast(len), .distance = distance };
            };
            const head = s.heads[bucket];
            entries[head] = .{ .index = curr, .tag = tag };
            s.heads[bucket] = (head + 1) & (bucket_size - 1);
            if (best.len != 0) {
                s.matches[s.count] = best;
                s.count += 1;
                covered = best.at + best.len;
            }
        }
        s.bytes = warm + @min(min_match - warm, end - start);
        return s.matches[0..s.count];
    }
};

const gear = blk: {
    var values: [256]u64 = undefined;
    var state: u64 = 0x7f4a7c159e3779b9;
    for (&values) |*value| {
        state ^= state >> 12;
        state ^= state << 25;
        state ^= state >> 27;
        value.* = state *% 0x2545f4914f6cdd1d;
    }
    break :blk values;
};
