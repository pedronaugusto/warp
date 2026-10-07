//! The `dfast` strategy (levels 3-4): two hash tables, one keyed by eight
//! bytes and one by `mls`, the longer match preferred; a short match found
//! first is tried against a long one at the next position. The first
//! repeat offset is tried one position ahead.

const std = @import("std");
const builtin = @import("builtin");
const window = @import("window.zig");
const encode = @import("../encode.zig");

const Window = window.Window;

/// Search the block `w.in[start..end]`; sequences go to `store`, `reps`
/// are the repeat offsets before and after. Returns the trailing literals.
pub noinline fn compress(
    long_table: []u32,
    long_log: u5,
    short_table: []u32,
    short_log: u5,
    w: Window,
    store: *encode.SeqStore,
    reps: *[3]u32,
    start: usize,
    end: usize,
    comptime mls: u4,
) usize {
    if (end - start < 8) return end - start;
    const b: window.Bytes = .of(w);
    const step_increment = 1 << 8;
    const prefix: usize = w.low;
    const i_end: usize = w.index(end);
    const limit = i_end - 8;
    var anchor: usize = w.index(start);
    var ip = anchor;
    var rep1 = reps[0];
    var rep2 = reps[1];
    var saved1: u32 = 0;
    var saved2: u32 = 0;
    ip += @intFromBool(ip == prefix);
    {
        const max_rep: u32 = @intCast(ip - prefix);
        if (rep2 > max_rep) {
            saved2 = rep2;
            rep2 = 0;
        }
        if (rep1 > max_rep) {
            saved1 = rep1;
            rep1 = 0;
        }
    }
    while (true) {
        var step: usize = 1;
        var next_step = ip + step_increment;
        var ip1 = ip + step;
        if (ip1 > limit) break;
        var hl0 = b.hash(ip, long_log, 8);
        var idxl0: usize = long_table[hl0];
        var hl1: u32 = undefined;
        var curr: usize = undefined;
        var len: usize = undefined;
        var offset: usize = undefined;
        const Outcome = enum { none, repeat, match };
        const outcome: Outcome = search: while (true) {
            const hs0 = b.hash(ip, short_log, mls);
            const idxs0: usize = short_table[hs0];
            curr = ip;
            long_table[hl0] = @intCast(curr);
            short_table[hs0] = @intCast(curr);
            if (rep1 > 0 and b.load32(ip + 1 - rep1) == b.load32(ip + 1)) {
                len = b.count(ip + 1 + 4 - rep1, ip + 1 + 4, i_end) + 4;
                ip += 1;
                break :search .repeat;
            }
            hl1 = b.hash(ip1, long_log, 8);
            if (matches64(b, prefix, ip, idxl0)) {
                var m = idxl0;
                len = b.count(m + 8, ip + 8, i_end) + 8;
                offset = ip - m;
                while (ip > anchor and m > prefix and b.byte(ip - 1) == b.byte(m - 1)) {
                    ip -= 1;
                    m -= 1;
                    len += 1;
                }
                break :search .match;
            }
            const idxl1: usize = long_table[hl1];
            if (matches32(b, prefix, ip, idxs0)) {
                // A short match: perhaps a long one a position on.
                var m = idxs0;
                len = b.count(m + 4, ip + 4, i_end) + 4;
                offset = ip - m;
                if (idxl1 > prefix and b.load64(idxl1) == b.load64(ip1)) {
                    const l1 = b.count(idxl1 + 8, ip1 + 8, i_end) + 8;
                    if (l1 > len) {
                        ip = ip1;
                        len = l1;
                        offset = ip - idxl1;
                        m = idxl1;
                    }
                }
                while (ip > anchor and m > prefix and b.byte(ip - 1) == b.byte(m - 1)) {
                    ip -= 1;
                    m -= 1;
                    len += 1;
                }
                break :search .match;
            }
            if (ip1 >= next_step) {
                @prefetch(b.ptr(ip1 + 64), .{});
                @prefetch(b.ptr(ip1 + 128), .{});
                step += 1;
                next_step += step_increment;
            }
            ip = ip1;
            ip1 += step;
            hl0 = hl1;
            idxl0 = idxl1;
            // AArch64 cores keep ahead of the scan with this (as the
            // reference does there); x86 prefetchers need no help.
            if (builtin.cpu.arch == .aarch64) @prefetch(b.ptr(ip + 256), .{});
            if (ip1 > limit) break :search .none;
        };
        switch (outcome) {
            .none => break,
            .repeat => store.store(w.in, w.at(@intCast(anchor)), w.at(@intCast(ip)), end, 1, len),
            .match => {
                rep2 = rep1;
                rep1 = @intCast(offset);
                // Safe below 4: the match ends past `ip1`.
                if (step < 4) long_table[hl1] = @intCast(ip1);
                store.store(w.in, w.at(@intCast(anchor)), w.at(@intCast(ip)), end, rep1 + 3, len);
            },
        }
        ip += len;
        anchor = ip;
        if (ip <= limit) {
            const insert = curr + 2;
            long_table[b.hash(insert, long_log, 8)] = @intCast(insert);
            long_table[b.hash(ip - 2, long_log, 8)] = @intCast(ip - 2);
            short_table[b.hash(insert, short_log, mls)] = @intCast(insert);
            short_table[b.hash(ip - 1, short_log, mls)] = @intCast(ip - 1);
            while (ip <= limit and rep2 > 0 and b.load32(ip) == b.load32(ip - rep2)) {
                const rlen = b.count(ip + 4 - rep2, ip + 4, i_end) + 4;
                const t = rep1;
                rep1 = rep2;
                rep2 = t;
                short_table[b.hash(ip, short_log, mls)] = @intCast(ip);
                long_table[b.hash(ip, long_log, 8)] = @intCast(ip);
                store.store(w.in, w.at(@intCast(ip)), w.at(@intCast(ip)), end, 1, rlen);
                ip += rlen;
                anchor = ip;
            }
        }
    }
    if (saved1 != 0 and rep1 != 0) saved2 = saved1;
    reps[0] = if (rep1 != 0) rep1 else saved1;
    reps[1] = if (rep2 != 0) rep2 else saved2;
    return i_end - anchor;
}

/// Eight bytes equal at a valid candidate; both loads always made, so
/// the validity test does not branch.
inline fn matches64(b: window.Bytes, prefix: usize, p: usize, i: usize) bool {
    const valid = i >= prefix;
    const q = if (valid) i else p;
    return valid and b.load64(p) == b.load64(q);
}

inline fn matches32(b: window.Bytes, prefix: usize, p: usize, i: usize) bool {
    const valid = i >= prefix;
    const q = if (valid) i else p;
    return valid and b.load32(p) == b.load32(q);
}
