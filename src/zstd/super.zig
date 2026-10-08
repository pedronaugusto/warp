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
    parse_reps: [3]u32,
    cut: ?usize = null,
    unchanged: bool = true,

    pub fn init(store: *encode.SeqStore, scratch: *const encode.Entropy, before: [3]u32, wanted: usize, literals: usize) Cursor {
        return .{ .store = store, .costs = .init(store, scratch, literals), .budget = (wanted - 256) * 2048, .parse_reps = before };
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
                    cursor.cut = to;
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

    /// Preserve the parser's repeat choices unless a raw partition or a
    /// literal cut changes what the same code means in the emitted stream.
    pub fn remap(cursor: *Cursor, part_: *encode.SeqStore, reps: *[3]u32) [3]u32 {
        const from = cursor.sequence - part_.count;
        if (cursor.unchanged) {
            if (cursor.cut == null or part_.count == 0) return reps.*;
            cursor.parse_reps = cursor.replay(cursor.parse_reps, 0, from);
            reps.* = cursor.parse_reps;
            cursor.unchanged = false;
        }
        var emitted = reps.*;
        for (part_.seqs[0..part_.count], 0..) |*q, i| {
            const old = q.off;
            const zero = part_.litLen(i) == 0;
            const cut = cursor.cut != null and cursor.cut.? == from + i;
            const original_zero = zero and !cut;
            if (old <= 3 and (zero != original_zero or sequences.distance(cursor.parse_reps, old, original_zero) != sequences.distance(emitted, old, zero))) {
                q.off = sequences.distance(cursor.parse_reps, old, original_zero) + 3;
                part_.of_codes[i] = codes.ofCode(q.off);
            }
            cursor.parse_reps = sequences.updateReps(cursor.parse_reps, old, original_zero);
            emitted = sequences.updateReps(emitted, q.off, zero);
            if (cut) cursor.cut = null;
        }
        return emitted;
    }

    /// A raw partition leaves repeat offsets unchanged. Until the first
    /// such partition, the original codes and final parser history suffice;
    /// replay the prefix only when it becomes necessary to remap later codes.
    pub fn rejected(cursor: *Cursor, count: usize, reps: *[3]u32) void {
        if (!cursor.unchanged or count == 0) return;
        const from = cursor.sequence - count;
        reps.* = cursor.replay(cursor.parse_reps, 0, from);
        cursor.parse_reps = cursor.replay(reps.*, from, cursor.sequence);
        cursor.unchanged = false;
    }

    fn replay(cursor: *const Cursor, initial: [3]u32, from: usize, to: usize) [3]u32 {
        var reps = initial;
        for (from..to) |i| reps = sequences.updateReps(reps, cursor.store.seqs[i].off, cursor.store.litLen(i) == 0);
        return reps;
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
    store.ll_codes[i] = if (len > 0xffff) codes.max_ll else codes.llCode(len);
}
