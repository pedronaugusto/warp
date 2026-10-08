//! The `fast` strategy (levels 1-2 and every negative level): one hash
//! table of the latest position per hash, searched two positions at a
//! time, with the first repeat offset tried two positions ahead. Positions
//! are skipped faster the longer no match turns up, and faster still by
//! the level's acceleration (negative levels).
//!
//! Positions here are indices (see `window.Bytes`): the table stores them
//! as they are.

const window = @import("window.zig");
const encode = @import("../sequences.zig");

const Window = window.Window;

/// Search the block `w.in[start..end]`; sequences go to `store`, `reps`
/// are the repeat offsets before and after. Returns the trailing literals.
pub noinline fn compress(comptime mls: u4, comptime cmov: bool, table: []u32, hash_log: u5, w: Window, store: *encode.SeqStore, reps: *[3]u32, start: usize, end: usize, acceleration: u32) usize {
    if (end - start < 8) return end - start;
    const b: window.Bytes = .of(w);
    const step_size: usize = acceleration + @intFromBool(acceleration == 0) + 1;
    const step_increment = 1 << 7;
    const prefix: usize = w.low;
    const i_end: usize = w.index(end);
    const limit = i_end - 8;
    var anchor: usize = w.index(start);
    var ip0 = anchor;
    var rep1 = reps[0];
    var rep2 = reps[1];
    ip0 += @intFromBool(ip0 == prefix);
    const max_rep = ip0 - prefix;
    const saved1 = window.disableRep(&rep1, max_rep);
    const saved2 = window.disableRep(&rep2, max_rep);
    outer: while (true) {
        var step = step_size;
        var next_step = ip0 + step_increment;
        var ip1 = ip0 + 1;
        var ip2 = ip0 + step;
        var ip3 = ip2 + 1;
        if (ip3 >= limit) break :outer;
        var hash0 = b.hash(mls, ip0, hash_log);
        var hash1 = b.hash(mls, ip1, hash_log);
        var match_idx: usize = table[hash0];
        var current0: usize = undefined;
        var match0: usize = undefined;
        var len: usize = undefined;
        var off: u32 = undefined;
        found: {
            while (true) {
                const rval = b.load32(ip2 - rep1);
                current0 = ip0;
                table[hash0] = @intCast(ip0);
                if (b.load32(ip2) == rval and rep1 > 0) {
                    ip0 = ip2;
                    match0 = ip0 - rep1;
                    len = @intFromBool(b.byte(ip0 - 1) == b.byte(match0 - 1));
                    ip0 -= len;
                    match0 -= len;
                    off = 1;
                    len += 4;
                    table[hash1] = @intCast(ip1);
                    break :found;
                }
                if (matches(cmov, b, prefix, ip0, match_idx)) {
                    table[hash1] = @intCast(ip1);
                    break;
                }
                match_idx = table[hash1];
                hash0 = hash1;
                hash1 = b.hash(mls, ip2, hash_log);
                ip0 = ip1;
                ip1 = ip2;
                ip2 = ip3;
                current0 = ip0;
                table[hash0] = @intCast(ip0);
                if (matches(cmov, b, prefix, ip0, match_idx)) {
                    // Searching resumes 4 or more ahead: an entry there
                    // would be one it passes.
                    if (step <= 4) table[hash1] = @intCast(ip1);
                    break;
                }
                match_idx = table[hash1];
                hash0 = hash1;
                hash1 = b.hash(mls, ip2, hash_log);
                ip0 = ip1;
                ip1 = ip2;
                ip2 = ip0 + step;
                ip3 = ip1 + step;
                if (ip2 >= next_step) {
                    step += 1;
                    @prefetch(b.ptr(ip1 + 64), .{});
                    @prefetch(b.ptr(ip1 + 128), .{});
                    next_step += step_increment;
                }
                if (ip3 >= limit) break :outer;
            }
            // A match found by hash: a new offset.
            match0 = match_idx;
            rep2 = rep1;
            rep1 = @intCast(ip0 - match0);
            off = rep1 + 3;
            len = 4;
            while (ip0 > anchor and match0 > prefix and b.byte(ip0 - 1) == b.byte(match0 - 1)) {
                ip0 -= 1;
                match0 -= 1;
                len += 1;
            }
        }
        len += b.count(match0 + len, ip0 + len, i_end);
        store.store(w.in, w.at(@intCast(anchor)), w.at(@intCast(ip0)), end, off, len);
        ip0 += len;
        anchor = ip0;
        if (ip0 <= limit) {
            table[b.hash(mls, current0 + 2, hash_log)] = @intCast(current0 + 2);
            table[b.hash(mls, ip0 - 2, hash_log)] = @intCast(ip0 - 2);
            if (rep2 > 0) {
                while (ip0 <= limit and b.load32(ip0) == b.load32(ip0 - rep2)) {
                    const rlen = b.count(ip0 + 4 - rep2, ip0 + 4, i_end) + 4;
                    const t = rep1;
                    rep1 = rep2;
                    rep2 = t;
                    table[b.hash(mls, ip0, hash_log)] = @intCast(ip0);
                    ip0 += rlen;
                    const p = w.at(@intCast(ip0 - rlen));
                    store.store(w.in, p, p, end, 1, rlen);
                    anchor = ip0;
                }
            }
        }
    }
    // Repeat offsets left invalid at the start come back, in order.
    window.restoreReps(reps, rep1, rep2, saved1, saved2);
    return i_end - anchor;
}

inline fn matches(comptime cmov: bool, b: window.Bytes, prefix: usize, p: usize, i: usize) bool {
    if (cmov) {
        const valid = i >= prefix;
        const q = if (valid) i else p;
        return valid and b.load32(p) == b.load32(q);
    }
    if (i < prefix) return false;
    return b.load32(p) == b.load32(i);
}
