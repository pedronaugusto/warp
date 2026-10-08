//! When to end a block: when the symbols coming in stop resembling the
//! block's so far, a new Huffman code pays for its header.
//!
//! Symbols are observed coarsely, ten kinds: literals by two of their
//! high bits and their low bit, matches as short or long. Every 512 new
//! observations the new kinds' mix is compared with the block's, scaled to
//! the same total; a difference above a fixed share ends the block, the
//! share lowering as the block grows (a long block has amortized its
//! header).

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
