//! Splits a parsed block where separate entropy tables cost less. The
//! search is bounded by 300 sequences per partition and 196 cuts.
const encode = @import("encode.zig");

pub const Plan = struct {
    ends: [197]u32 = undefined,
    count: usize = 0,
};

/// Partition ends in sequence indices, including the whole block's end.
pub fn plan(store: *const encode.SeqStore, prev: *const encode.Entropy, scratch: *encode.Entropy, strategy: encode.Strategy) Plan {
    var p: Plan = .{};
    divide(&p, store, 0, store.count, prev, scratch, strategy);
    p.ends[p.count] = @intCast(store.count);
    p.count += 1;
    return p;
}

fn divide(p: *Plan, store: *const encode.SeqStore, from: usize, to: usize, prev: *const encode.Entropy, scratch: *encode.Entropy, strategy: encode.Strategy) void {
    if (to - from < 300 or p.count >= 196) return;
    const middle = (from + to) / 2;
    var whole = store.chunk(from, to);
    var left = store.chunk(from, middle);
    var right = store.chunk(middle, to);
    const size = encode.estimateBlock(&whole, prev, scratch, strategy);
    const first = encode.estimateBlock(&left, prev, scratch, strategy);
    const second = encode.estimateBlock(&right, prev, scratch, strategy);
    if (first + second >= size) return;
    divide(p, store, from, middle, prev, scratch, strategy);
    if (p.count >= 196) return;
    p.ends[p.count] = @intCast(middle);
    p.count += 1;
    divide(p, store, middle, to, prev, scratch, strategy);
}
