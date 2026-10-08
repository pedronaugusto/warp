//! COVER segment selection. Exact d-mers use an open-addressed dictionary;
//! fast selection counts hashed d-mers instead. Sliding windows count each
//! d-mer once, and selected d-mers leave the scoring distribution.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Model = struct {
    ids: []u32,
    frequencies: []u32,
    original: []u32,
    occurrences: []u32,
    keys: []u64,
    samples: []const []const u8,
    d: usize,
    mask: usize,

    pub fn init(gpa: Allocator, samples: []const []const u8, d: usize, exact: bool) Allocator.Error!Model {
        var total: usize = 0;
        for (samples) |sample| total += sample.len;
        const slots = if (exact) std.math.ceilPowerOfTwo(usize, @max(64, total * 2)) catch return error.OutOfMemory else 1 << 20;
        const ids = try gpa.alloc(u32, total);
        errdefer gpa.free(ids);
        const frequencies = try gpa.alloc(u32, slots);
        errdefer gpa.free(frequencies);
        const original = try gpa.alloc(u32, slots);
        errdefer gpa.free(original);
        const occurrences = try gpa.alloc(u32, slots);
        errdefer gpa.free(occurrences);
        const keys = try gpa.alloc(u64, if (exact) slots else 0);
        errdefer gpa.free(keys);
        @memset(frequencies, 0);
        @memset(ids, std.math.maxInt(u32));
        const m: Model = .{ .ids = ids, .frequencies = frequencies, .original = original, .occurrences = occurrences, .keys = keys, .samples = samples, .d = d, .mask = slots - 1 };
        var base: usize = 0;
        for (samples) |sample| {
            if (sample.len >= d) for (0..sample.len - d + 1) |at| {
                const key = dmer(sample[at..][0..d]);
                var slot = @as(usize, @intCast((key *% 0xcf1bbcdc_b7a56463) >> 32)) & m.mask;
                if (exact) {
                    while (frequencies[slot] != 0 and keys[slot] != key) slot = (slot + 1) & m.mask;
                    keys[slot] = key;
                }
                ids[base + at] = @intCast(slot);
                frequencies[slot] +|= 1;
            };
            base += sample.len;
        }
        @memcpy(original, frequencies);
        return m;
    }

    pub fn deinit(m: *Model, gpa: Allocator) void {
        gpa.free(m.keys);
        gpa.free(m.occurrences);
        gpa.free(m.original);
        gpa.free(m.frequencies);
        gpa.free(m.ids);
        m.* = undefined;
    }

    const Segment = struct { sample: usize = 0, at: usize = 0, len: usize = 0, score: u64 = 0 };

    fn best(m: *Model, k: usize) Segment {
        var best_segment: Segment = .{};
        var base: usize = 0;
        for (m.samples, 0..) |sample, s| {
            defer base += sample.len;
            if (sample.len < m.d) continue;
            const len = @min(sample.len, k);
            const dmers = len - m.d + 1;
            var score: u64 = 0;
            const ids = m.ids[base..][0 .. sample.len - m.d + 1];
            for (ids, 0..) |id, at| {
                if (m.occurrences[id] == 0) score += m.frequencies[id];
                m.occurrences[id] += 1;
                if (at >= dmers) {
                    const old = ids[at - dmers];
                    m.occurrences[old] -= 1;
                    if (m.occurrences[old] == 0) score -= m.frequencies[old];
                }
                if (at + 1 >= dmers and score > best_segment.score) best_segment = .{ .sample = s, .at = at + 1 - dmers, .len = len, .score = score };
            }
            for (ids[ids.len - dmers ..]) |id| m.occurrences[id] -= 1;
        }
        return best_segment;
    }

    /// Greedy coverage into `out`, strongest segments at the end, where
    /// dictionary matches find them first. Returns the selected byte count.
    pub fn select(m: *Model, out: []u8, k: usize) usize {
        @memcpy(m.frequencies, m.original);
        @memset(m.occurrences, 0);
        var cursor = out.len;
        while (cursor >= m.d) {
            const segment = m.best(@min(k, cursor));
            if (segment.score == 0) break;
            cursor -= segment.len;
            @memcpy(out[cursor..][0..segment.len], m.samples[segment.sample][segment.at..][0..segment.len]);
            var base: usize = segment.at;
            for (m.samples[0..segment.sample]) |sample| base += sample.len;
            for (m.ids[base..][0 .. segment.len - m.d + 1]) |id| m.frequencies[id] = 0;
        }
        const len = out.len - cursor;
        @memmove(out[0..len], out[cursor..]);
        return len;
    }
};

fn dmer(bytes: []const u8) u64 {
    var value: u64 = 0;
    for (bytes, 0..) |b, i| value |= @as(u64, b) << @intCast(8 * i);
    return value;
}
