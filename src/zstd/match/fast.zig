//! The `fast` strategy (levels 1-2 and every negative level): one hash
//! table of the latest position per hash, searched two positions at a
//! time, with the first repeat offset tried two positions ahead. Positions
//! are skipped faster the longer no match turns up, and faster still by
//! the level's acceleration (negative levels).

const std = @import("std");
const window = @import("window.zig");
const encode = @import("../encode.zig");

const Window = window.Window;

/// Search the block `in[start..end]`; sequences go to `store`, `reps` are
/// the repeat offsets before and after. Returns the trailing literals.
pub fn compress(
    table: []u32,
    hash_log: u5,
    w: Window,
    store: *encode.SeqStore,
    reps: *[3]u32,
    start: usize,
    end: usize,
    acceleration: u32,
    comptime mls: u4,
    comptime cmov: bool,
) usize {
    const in = w.in;
    const step_size: usize = acceleration + @intFromBool(acceleration == 0) + 1;
    const step_increment = 1 << 7;
    const prefix: usize = w.at(w.low);
    if (end < 8 or end - start < 8) return end - start;
    const limit = end - 8;
    var anchor = start;
    var ip0 = start;
    var rep1 = reps[0];
    var rep2 = reps[1];
    var saved1: u32 = 0;
    var saved2: u32 = 0;
    ip0 += @intFromBool(ip0 == prefix);
    {
        const max_rep: u32 = @intCast(ip0 - prefix);
        if (rep2 > max_rep) {
            saved2 = rep2;
            rep2 = 0;
        }
        if (rep1 > max_rep) {
            saved1 = rep1;
            rep1 = 0;
        }
    }
    outer: while (true) {
        var step = step_size;
        var next_step = ip0 + step_increment;
        var ip1 = ip0 + 1;
        var ip2 = ip0 + step;
        var ip3 = ip2 + 1;
        if (ip3 >= limit) break :outer;
        var hash0 = window.hash(in, ip0, hash_log, mls);
        var hash1 = window.hash(in, ip1, hash_log, mls);
        var match_idx = table[hash0];
        var current0: u32 = undefined;
        var match0: usize = undefined;
        var len: usize = undefined;
        var off: u32 = undefined;
        found: {
            while (true) {
                const rval = window.read32(in, ip2 - rep1);
                current0 = w.index(ip0);
                table[hash0] = current0;
                if (window.read32(in, ip2) == rval and rep1 > 0) {
                    ip0 = ip2;
                    match0 = ip0 - rep1;
                    len = @intFromBool(in[ip0 - 1] == in[match0 - 1]);
                    ip0 -= len;
                    match0 -= len;
                    off = 1;
                    len += 4;
                    table[hash1] = w.index(ip1);
                    break :found;
                }
                if (matches(in, w, ip0, match_idx, cmov)) {
                    table[hash1] = w.index(ip1);
                    break;
                }
                match_idx = table[hash1];
                hash0 = hash1;
                hash1 = window.hash(in, ip2, hash_log, mls);
                ip0 = ip1;
                ip1 = ip2;
                ip2 = ip3;
                current0 = w.index(ip0);
                table[hash0] = current0;
                if (matches(in, w, ip0, match_idx, cmov)) {
                    // Searching resumes 4 or more ahead: an entry there
                    // would be one it passes.
                    if (step <= 4) table[hash1] = w.index(ip1);
                    break;
                }
                match_idx = table[hash1];
                hash0 = hash1;
                hash1 = window.hash(in, ip2, hash_log, mls);
                ip0 = ip1;
                ip1 = ip2;
                ip2 = ip0 + step;
                ip3 = ip1 + step;
                if (ip2 >= next_step) {
                    step += 1;
                    @prefetch(in.ptr + ip1 + 64, .{});
                    @prefetch(in.ptr + ip1 + 128, .{});
                    next_step += step_increment;
                }
                if (ip3 >= limit) break :outer;
            }
            // A match found by hash: a new offset.
            match0 = w.at(match_idx);
            rep2 = rep1;
            rep1 = @intCast(ip0 - match0);
            off = rep1 + 3;
            len = 4;
            while (ip0 > anchor and match0 > prefix and in[ip0 - 1] == in[match0 - 1]) {
                ip0 -= 1;
                match0 -= 1;
                len += 1;
            }
        }
        len += window.count(in, match0 + len, ip0 + len, end);
        store.store(in[anchor..ip0], off, len);
        ip0 += len;
        anchor = ip0;
        if (ip0 <= limit) {
            table[window.hash(in, w.at(current0 + 2), hash_log, mls)] = current0 + 2;
            table[window.hash(in, ip0 - 2, hash_log, mls)] = w.index(ip0 - 2);
            if (rep2 > 0) {
                while (ip0 <= limit and window.read32(in, ip0) == window.read32(in, ip0 - rep2)) {
                    const rlen = window.count(in, ip0 + 4 - rep2, ip0 + 4, end) + 4;
                    std.mem.swap(u32, &rep1, &rep2);
                    table[window.hash(in, ip0, hash_log, mls)] = w.index(ip0);
                    ip0 += rlen;
                    store.store(&.{}, 1, rlen);
                    anchor = ip0;
                }
            }
        }
    }
    // Repeat offsets left invalid at the start come back, in order.
    if (saved1 != 0 and rep1 != 0) saved2 = saved1;
    reps[0] = if (rep1 != 0) rep1 else saved1;
    reps[1] = if (rep2 != 0) rep2 else saved2;
    return end - anchor;
}

inline fn matches(in: []const u8, w: Window, p: usize, idx: u32, comptime cmov: bool) bool {
    if (cmov) {
        const valid = idx >= w.low;
        const at = if (valid) w.at(idx) else p;
        return valid and window.read32(in, p) == window.read32(in, at);
    }
    if (idx < w.low) return false;
    return window.read32(in, p) == window.read32(in, w.at(idx));
}
