//! Costed partitions of a parsed superblock. Matches are parsed once;
//! literal runs can be cut without discarding the matches after them.
const std = @import("std");
const encode = @import("encode.zig");
const codes = @import("codes.zig");
const sequences = @import("sequences.zig");

/// The reference's supported target range, applied to best-effort targets.
pub fn target(value: u32) usize {
    return std.math.clamp(value, 1340, encode.block_max);
}

const Costs = struct {
    literal: u32,
    ll: [64]u32 = @splat(0),
    ml: [64]u32 = @splat(0),
    of: [64]u32 = @splat(0),

    fn init(store: *encode.SeqStore, next: *const encode.Entropy, literal_size: usize) Costs {
        var costs: Costs = .{ .literal = @intCast(@max(256, @min(2048, literal_size * 2048 / @max(1, store.lit_len)))) };
        if (store.count != 0) {
            for (0..64) |i| {
                costs.ll[i] = if (next.ll.log == 0) 0 else next.ll.bitCost(@intCast(i)) orelse 2048;
                costs.ml[i] = if (next.ml.log == 0) 0 else next.ml.bitCost(@intCast(i)) orelse 2048;
                costs.of[i] = if (next.of.log == 0) 0 else next.of.bitCost(@intCast(i)) orelse 2048;
            }
        }
        return costs;
    }

    fn sequence(costs: *const Costs, store: *const encode.SeqStore, i: usize) u32 {
        const ll = store.ll_codes[i];
        const ml = store.ml_codes[i];
        const of = store.of_codes[i];
        return costs.ll[ll] + costs.ml[ml] + costs.of[of] + 256 * (@as(u32, codes.ll_bits[ll]) + codes.ml_bits[ml] + of);
    }
};

/// Cursor over one block's borrowed sequence and literal storage.
pub const Cursor = struct {
    store: *encode.SeqStore,
    costs: Costs,
    budget: usize,
    sequence: usize = 0,
    literal: usize = 0,
    parts: usize = 0,

    pub fn init(store: *encode.SeqStore, scratch: *const encode.Entropy, before: [3]u32, wanted: usize, literals: usize) Cursor {
        const cursor: Cursor = .{ .store = store, .costs = .init(store, scratch, literals), .budget = (wanted - 256) * 2048 };
        var reps = before;
        for (store.seqs[0..store.count], 0..) |*q, i| {
            const old = q.off;
            const zero = store.litLen(i) == 0;
            q.off = sequences.distance(reps, old, zero) + 3;
            reps = sequences.updateReps(reps, old, zero);
        }
        return cursor;
    }

    pub fn done(cursor: *const Cursor) bool {
        return cursor.sequence == cursor.store.count and cursor.literal == cursor.store.lit_len;
    }

    /// The next borrowed piece, retaining full matches and splitting literals.
    pub fn next(cursor: *Cursor) encode.SeqStore {
        cursor.parts += 1;
        if (cursor.parts == 197) cursor.budget = std.math.maxInt(usize);
        const store = cursor.store;
        const from = cursor.sequence;
        const first_literal = cursor.literal;
        var cost: usize = 0;
        var to = from;
        while (to < store.count) {
            const ll = store.litLen(to);
            const literal_cost = @as(usize, ll) * cursor.costs.literal;
            const sequence_cost = cursor.costs.sequence(store, to);
            if (cost + literal_cost + sequence_cost > cursor.budget) {
                if (to != from) break;
                if (literal_cost > cursor.budget) {
                    const take = @min(ll, @max(1, cursor.budget / cursor.costs.literal));
                    cursor.literal += take;
                    setLiterals(store, to, ll - @as(u32, @intCast(take)));
                    return cursor.part(from, from, first_literal, cursor.literal);
                }
            }
            cost += literal_cost + sequence_cost;
            cursor.literal += ll;
            to += 1;
            if (cost >= cursor.budget) break;
        }
        cursor.sequence = to;
        if (to == store.count) {
            const remaining = store.lit_len - cursor.literal;
            const take = @min(remaining, (cursor.budget -| cost) / cursor.costs.literal);
            cursor.literal += if (to == from and take == 0) @min(1, remaining) else take;
        }
        return cursor.part(from, to, first_literal, cursor.literal);
    }

    fn part(cursor: *const Cursor, from: usize, to: usize, first: usize, end: usize) encode.SeqStore {
        const store = cursor.store;
        var part_ = store.*;
        part_.seqs = store.seqs[from..to];
        part_.count = to - from;
        part_.lits = store.lits[first..end];
        part_.lit_len = end - first;
        part_.ll_codes = store.ll_codes[from..to];
        part_.ml_codes = store.ml_codes[from..to];
        part_.of_codes = store.of_codes[from..to];
        part_.long = if (store.long) |long| if (long.index >= from and long.index < to) .{ .index = @intCast(long.index - from), .match = long.match } else null else null;
        return part_;
    }
};

fn setLiterals(store: *encode.SeqStore, i: usize, len: u32) void {
    store.seqs[i].lit = @truncate(len);
    if (store.long) |long| if (long.index == i and !long.match) {
        store.long = null;
    };
    if (len > 0xffff) store.long = .{ .index = @intCast(i), .match = false };
}

/// Choose a valid repeat code in the history of the emitted partitions.
pub fn offset(reps: [3]u32, distance: u32, zero: bool) u32 {
    for (1..4) |code| {
        if (zero and code == 3 and reps[0] <= 1) continue;
        if (sequences.distance(reps, @intCast(code), zero) == distance) return @intCast(code);
    }
    return distance + 3;
}
