//! When to end a block: when the symbols coming in stop resembling the
//! block's so far, a new Huffman code pays for its header.
//!
//! Symbols are observed coarsely, ten kinds: literals by two of their
//! high bits and their low bit, matches as short or long. Every 512 new
//! observations the new kinds' mix is compared with the block's, scaled to
//! the same total; a difference above a fixed share ends the block, the
//! share lowering as the block grows (a long block has amortized its
//! header).

const std = @import("std");

pub const kinds = 10;
pub const check_every = 512;

pub const Splitter = struct {
    new: [kinds]u32 = @splat(0),
    seen: [kinds]u32 = @splat(0),
    n_new: u32 = 0,
    n_seen: u32 = 0,

    pub inline fn literal(s: *Splitter, byte: u8) void {
        s.new[((byte >> 5) & 6) | (byte & 1)] += 1;
        s.n_new += 1;
    }

    pub inline fn match(s: *Splitter, length: u32) void {
        s.new[8 + @as(usize, @intFromBool(length >= 9))] += 1;
        s.n_new += 1;
    }

    /// The observations since the last comparison, read from the block's
    /// symbol counts rather than made one symbol at a time: the counts hold
    /// every literal and every length, so what is new is what they hold
    /// beyond what `seen` has taken in. A parser that keeps the counts
    /// compares with this and observes nothing per symbol.
    pub fn observeCounts(s: *Splitter, litlen: []const u32) void {
        var kinds_now: [kinds]u32 = @splat(0);
        for (litlen[0..256], 0..) |n, byte| kinds_now[((byte >> 5) & 6) | (byte & 1)] += n;
        // Lengths 3 to 8 are symbols 257 to 262; 9 and longer, 263 on.
        for (litlen[257..263]) |n| kinds_now[8] += n;
        for (litlen[263..286]) |n| kinds_now[9] += n;
        s.n_new = 0;
        for (&s.new, kinds_now, s.seen) |*new, now, seen| {
            new.* = now - seen;
            s.n_new += new.*;
        }
    }

    /// Enough new observations to compare.
    pub inline fn ready(s: *const Splitter) bool {
        return s.n_new >= check_every;
    }

    /// Whether the new observations differ enough from the block's to end
    /// it before them; else they join the block's.
    pub fn differs(s: *Splitter) bool {
        if (s.n_seen != 0) {
            var delta: u64 = 0;
            for (s.new, s.seen) |n, seen| {
                const a = @as(u64, n) * s.n_seen;
                const b = @as(u64, seen) * s.n_new;
                delta += if (a > b) a - b else b - a;
            }
            const cutoff = @as(u64, s.n_new) * 200 / 512 * s.n_seen;
            if (delta >= cutoff) return true;
        }
        for (&s.seen, &s.new) |*seen, *n| {
            seen.* += n.*;
            n.* = 0;
        }
        s.n_seen += s.n_new;
        s.n_new = 0;
        return false;
    }

    /// The near-optimal parser's check (the reference's): as `differs`, with a
    /// stricter cutoff while the block is short, and a term that grows with
    /// the block's length.
    pub fn differsAt(s: *Splitter, block_length: usize) bool {
        if (s.n_seen != 0) {
            var delta: u64 = 0;
            for (s.new, s.seen) |n, seen| {
                const a = @as(u64, n) * s.n_seen;
                const b = @as(u64, seen) * s.n_new;
                delta += if (a > b) a - b else b - a;
            }
            const items: u64 = s.n_seen + s.n_new;
            var cutoff = @as(u64, s.n_new) * 200 / 512 * s.n_seen;
            // A short block costs its code's header: end one only when the
            // change is clear.
            if (block_length < 10000 and items < 8192) cutoff += cutoff * (8192 - items) / 8192;
            if (delta + (block_length / 4096) * s.n_seen >= cutoff) return true;
        }
        s.merge();
        return false;
    }

    /// The new observations join the block's.
    pub fn merge(s: *Splitter) void {
        for (&s.seen, &s.new) |*seen, *n| {
            seen.* += n.*;
            n.* = 0;
        }
        s.n_seen += s.n_new;
        s.n_new = 0;
    }

    /// A new block starts with nothing observed: the observations that
    /// ended the last were of its own symbols.
    pub fn startBlock(s: *Splitter) void {
        s.* = .{};
    }
};

test "observations read from the symbol counts are those made symbol by symbol" {
    const block = @import("block.zig");
    var counts: block.Counts = .{};
    var made: Splitter = .{};
    var prng = std.Random.DefaultPrng.init(0x5eed);
    const random = prng.random();
    for (0..4000) |_| {
        if (random.boolean()) {
            const byte = random.int(u8);
            counts.literal(byte);
            made.literal(byte);
        } else {
            const length = random.intRangeAtMost(u32, 3, 258);
            counts.match(length, random.intRangeAtMost(u32, 1, 32768));
            made.match(length);
        }
    }
    var read: Splitter = .{};
    read.observeCounts(&counts.litlen);
    try std.testing.expectEqual(made.new, read.new);
    try std.testing.expectEqual(made.n_new, read.n_new);
    // After a comparison that takes the observations in, the next ones are
    // those the counts hold beyond them.
    try std.testing.expect(!read.differs());
    made = .{};
    for (0..700) |_| {
        if (random.boolean()) {
            const byte = random.int(u8);
            counts.literal(byte);
            made.literal(byte);
        } else {
            const length = random.intRangeAtMost(u32, 3, 258);
            counts.match(length, 1);
            made.match(length);
        }
    }
    read.observeCounts(&counts.litlen);
    try std.testing.expectEqual(made.new, read.new);
    try std.testing.expectEqual(made.n_new, read.n_new);
}
