//! The `greedy`, `lazy` and `lazy2` strategies (levels 5-12): at each
//! position the longest match among a bounded number of candidates, taken
//! at once (greedy) or held while the next one or two positions are tried
//! for a better one, with a gain rule weighing length against the offset's
//! cost. Candidates come from hash chains (small windows) or from rows of
//! a hash table, each entry tagged with 8 more bits of the hash so a vector
//! compare picks the candidates worth reading (larger windows).

const std = @import("std");
const window = @import("window.zig");
const encode = @import("../encode.zig");

const Window = window.Window;
const Bytes = window.Bytes;

pub const Search = enum { chain, row };

const tag_bits = 8;
const cache_size = 8;
/// Past this many positions skipped a step, only searched positions are
/// inserted.
const skipping_step = 8;

/// The tables of one strategy, and where insertion has got to.
pub const State = struct {
    /// Chains: the newest position per hash. Rows: 2^row_log entries per
    /// row, entry 0 unused.
    hash: []u32,
    /// Chains: the previous position with the same hash, per position.
    chain: []u32 = &.{},
    /// Rows: each entry's tag; a row's byte 0 holds its head.
    tags: []u8 = &.{},
    hash_log: u5,
    chain_log: u5 = 0,
    row_log: u3 = 4,
    search_log: u5,
    window_log: u5,
    /// The next index to insert.
    next: usize = 0,
    cache: [cache_size]u32 = undefined,
    skipping: bool = false,
};

/// Search the block `w.in[start..end]`; sequences go to `store`, `reps`
/// are the repeat offsets before and after. Returns the trailing literals.
pub noinline fn compress(
    st: *State,
    w: Window,
    store: *encode.SeqStore,
    reps: *[3]u32,
    start: usize,
    end: usize,
    comptime search: Search,
    comptime depth: u2,
    comptime mls: u4,
) usize {
    const b: Bytes = .of(w);
    const i_start: usize = w.index(start);
    const i_end: usize = w.index(end);
    const extra: usize = if (search == .row) cache_size else 0;
    if (end - start < 8 + extra + 1) return end - start;
    const limit = i_end - 8 - extra;
    // The start of the input: catching up stops above it.
    const prefix: usize = w.start;
    var ip = i_start;
    var anchor = i_start;
    var rep1 = reps[0];
    var rep2 = reps[1];
    var saved1: u32 = 0;
    var saved2: u32 = 0;
    ip += @intFromBool(ip == prefix);
    {
        const max_rep: u32 = @intCast(ip - lowest(st, w, ip));
        if (rep2 > max_rep) {
            saved2 = rep2;
            rep2 = 0;
        }
        if (rep1 > max_rep) {
            saved1 = rep1;
            rep1 = 0;
        }
    }
    st.skipping = false;
    if (search == .row) fillCache(st, b, st.next, limit, mls);
    while (ip < limit) {
        var len: usize = 0;
        var off: usize = 1;
        var match_at = ip + 1;
        // A repeat one position on.
        if (rep1 > 0 and b.load32(ip + 1 - rep1) == b.load32(ip + 1)) {
            len = b.count(ip + 1 + 4 - rep1, ip + 1 + 4, i_end) + 4;
        }
        if (depth == 0 and len > 0) {
            // Taken at once.
        } else {
            const found = find(st, w, b, ip, i_end, search, mls);
            if (found.len > len) {
                len = found.len;
                match_at = ip;
                off = found.off;
            }
            if (len < 4) {
                const step = ((ip - anchor) >> 8) + 1;
                ip += step;
                st.skipping = step > skipping_step;
                continue;
            }
            if (depth >= 1) {
                while (ip < limit) {
                    ip += 1;
                    if (off != 0 and rep1 > 0 and b.load32(ip) == b.load32(ip - rep1)) {
                        const rep_len = b.count(ip + 4 - rep1, ip + 4, i_end) + 4;
                        const gain2: i64 = @intCast(rep_len * 3);
                        const gain1: i64 = @as(i64, @intCast(len * 3)) - log2(off) + 1;
                        if (rep_len >= 4 and gain2 > gain1) {
                            len = rep_len;
                            off = 1;
                            match_at = ip;
                        }
                    }
                    {
                        const c = find(st, w, b, ip, i_end, search, mls);
                        if (c.len >= 4) {
                            const gain2: i64 = @as(i64, @intCast(c.len * 4)) - log2(c.off);
                            const gain1: i64 = @as(i64, @intCast(len * 4)) - log2(off) + 4;
                            if (gain2 > gain1) {
                                len = c.len;
                                off = c.off;
                                match_at = ip;
                                continue;
                            }
                        }
                    }
                    if (depth == 2 and ip < limit) {
                        ip += 1;
                        if (off != 0 and rep1 > 0 and b.load32(ip) == b.load32(ip - rep1)) {
                            const rep_len = b.count(ip + 4 - rep1, ip + 4, i_end) + 4;
                            const gain2: i64 = @intCast(rep_len * 4);
                            const gain1: i64 = @as(i64, @intCast(len * 4)) - log2(off) + 1;
                            if (rep_len >= 4 and gain2 > gain1) {
                                len = rep_len;
                                off = 1;
                                match_at = ip;
                            }
                        }
                        const c = find(st, w, b, ip, i_end, search, mls);
                        if (c.len >= 4) {
                            const gain2: i64 = @as(i64, @intCast(c.len * 4)) - log2(c.off);
                            const gain1: i64 = @as(i64, @intCast(len * 4)) - log2(off) + 7;
                            if (gain2 > gain1) {
                                len = c.len;
                                off = c.off;
                                match_at = ip;
                                continue;
                            }
                        }
                    }
                    break;
                }
            }
            if (off > 3) {
                // Catch up: the match may start earlier.
                const distance = off - 3;
                while (match_at > anchor and match_at - distance > prefix and b.byte(match_at - 1) == b.byte(match_at - distance - 1)) {
                    match_at -= 1;
                    len += 1;
                }
                rep2 = rep1;
                rep1 = @intCast(distance);
            }
        }
        store.store(w.in, w.at(@intCast(anchor)), w.at(@intCast(match_at)), end, @intCast(off), len);
        ip = match_at + len;
        anchor = ip;
        if (st.skipping) {
            if (search == .row) fillCache(st, b, st.next, limit, mls);
            st.skipping = false;
        }
        while (ip <= limit and rep2 > 0 and b.load32(ip) == b.load32(ip - rep2)) {
            const rlen = b.count(ip + 4 - rep2, ip + 4, i_end) + 4;
            const t = rep2;
            rep2 = rep1;
            rep1 = t;
            store.store(w.in, w.at(@intCast(ip)), w.at(@intCast(ip)), end, 1, rlen);
            ip += rlen;
            anchor = ip;
        }
    }
    if (saved1 != 0 and rep1 != 0) saved2 = saved1;
    reps[0] = if (rep1 != 0) rep1 else saved1;
    reps[1] = if (rep2 != 0) rep2 else saved2;
    return i_end - anchor;
}

inline fn log2(off: usize) i64 {
    return std.math.log2_int(u64, off);
}

/// The lowest index a match from `curr` may reach: the window back from
/// it, not before the input.
inline fn lowest(st: *const State, w: Window, curr: usize) usize {
    const max = @as(usize, 1) << st.window_log;
    return if (curr - w.start > max) curr - max else w.start;
}

const Found = struct { len: usize, off: usize };

inline fn find(st: *State, w: Window, b: Bytes, ip: usize, i_end: usize, comptime search: Search, comptime mls: u4) Found {
    return switch (search) {
        .chain => findInChain(st, w, b, ip, i_end, mls),
        .row => findInRow(st, w, b, ip, i_end, mls),
    };
}

// ---- hash chains ----

/// Insert positions up to `ip` (excluded) and return the newest with
/// `ip`'s hash.
inline fn insertChain(st: *State, b: Bytes, ip: usize, comptime mls: u4) usize {
    const mask = (@as(usize, 1) << st.chain_log) - 1;
    var i = st.next;
    while (i < ip) {
        const h = b.hash(i, st.hash_log, mls);
        st.chain[i & mask] = st.hash[h];
        st.hash[h] = @intCast(i);
        i += 1;
        if (st.skipping) break;
    }
    st.next = ip;
    return st.hash[b.hash(ip, st.hash_log, mls)];
}

fn findInChain(st: *State, w: Window, b: Bytes, ip: usize, i_end: usize, comptime mls: u4) Found {
    const chain_size = @as(usize, 1) << st.chain_log;
    const mask = chain_size - 1;
    const low = lowest(st, w, ip);
    const min_chain = if (ip > chain_size) ip - chain_size else 0;
    var attempts = @as(usize, 1) << st.search_log;
    var best: Found = .{ .len = 3, .off = 0 };
    var m = insertChain(st, b, ip, mls);
    while (m >= low and attempts > 0) : (attempts -= 1) {
        if (b.load32(m + best.len - 3) == b.load32(ip + best.len - 3)) {
            const len = b.count(m, ip, i_end);
            if (len > best.len) {
                best = .{ .len = len, .off = ip - m + 3 };
                if (ip + len == i_end) break;
            }
        }
        if (m <= min_chain) break;
        m = st.chain[m & mask];
    }
    return best;
}

// ---- rows ----

inline fn rowHash(st: *const State, b: Bytes, i: usize, comptime mls: u4) u32 {
    return b.hash(i, st.hash_log + tag_bits, mls);
}

inline fn prefetchRow(st: *const State, row: usize) void {
    @prefetch(st.hash.ptr + row, .{});
    if (st.row_log >= 5) @prefetch(st.hash.ptr + row + 16, .{});
    @prefetch(st.tags.ptr + row, .{});
    if (st.row_log == 6) @prefetch(st.tags.ptr + row + 32, .{});
}

/// The hashes of the next positions, rows fetched ahead.
fn fillCache(st: *State, b: Bytes, from: usize, limit: usize, comptime mls: u4) void {
    const n = if (from > limit) 0 else @min(cache_size, limit - from + 1);
    for (from..from + n) |i| {
        const h = rowHash(st, b, i, mls);
        prefetchRow(st, (h >> tag_bits) << st.row_log);
        st.cache[i & (cache_size - 1)] = h;
    }
}

/// The hash of `i` from the cache, replaced by the hash `cache_size` on.
inline fn nextCachedHash(st: *State, b: Bytes, i: usize, comptime mls: u4) u32 {
    const new = rowHash(st, b, i + cache_size, mls);
    prefetchRow(st, (new >> tag_bits) << st.row_log);
    const h = st.cache[i & (cache_size - 1)];
    st.cache[i & (cache_size - 1)] = new;
    return h;
}

/// The next entry of a row to write: entries cycle down from the last,
/// skipping 0, which holds the head.
inline fn nextEntry(tags: []u8, mask: u32) u32 {
    var n = (@as(u32, tags[0]) -% 1) & mask;
    if (n == 0) n = mask;
    tags[0] = @intCast(n);
    return n;
}

fn insertRows(st: *State, b: Bytes, from: usize, to: usize, comptime mls: u4) void {
    const mask = (@as(u32, 1) << st.row_log) - 1;
    for (from..to) |i| {
        const h = nextCachedHash(st, b, i, mls);
        const row = (@as(usize, h) >> tag_bits) << st.row_log;
        const n = nextEntry(st.tags[row..], mask);
        st.tags[row + n] = @truncate(h);
        st.hash[row + n] = @intCast(i);
    }
}

inline fn updateRows(st: *State, b: Bytes, ip: usize, comptime mls: u4) void {
    var i = st.next;
    // After a long match only its first and last positions are inserted.
    if (ip - i > 384) {
        insertRows(st, b, i, i + 96, mls);
        i = ip - 32;
        fillCache(st, b, i, ip + 1, mls);
    }
    insertRows(st, b, i, ip, mls);
    st.next = ip;
}

/// Which entries of a row carry `tag`, newest first: bit k for the entry
/// k places on from the head.
inline fn matchMask(tags: []const u8, tag: u8, head: u32, comptime entries: usize) u64 {
    const V = @Vector(entries, u8);
    const row: V = tags[0..entries].*;
    const eq = row == @as(V, @splat(tag));
    const Mask = @Int(.unsigned, entries);
    const mask: Mask = @bitCast(eq);
    return std.math.rotr(Mask, mask, head);
}

fn findInRow(st: *State, w: Window, b: Bytes, ip: usize, i_end: usize, comptime mls: u4) Found {
    const low = lowest(st, w, ip);
    const entries = @as(u32, 1) << st.row_log;
    const mask = entries - 1;
    var attempts: usize = @as(usize, 1) << @min(st.search_log, st.row_log);
    var h: u32 = undefined;
    if (!st.skipping) {
        updateRows(st, b, ip, mls);
        h = nextCachedHash(st, b, ip, mls);
    } else {
        h = rowHash(st, b, ip, mls);
        st.next = ip;
    }
    const row = (@as(usize, h) >> tag_bits) << st.row_log;
    const tag: u8 = @truncate(h);
    const tags = st.tags[row..][0..entries];
    const head = tags[0] & mask;
    var matches: u64 = switch (st.row_log) {
        4 => matchMask(tags, tag, head, 16),
        5 => matchMask(tags, tag, head, 32),
        else => matchMask(tags, tag, head, 64),
    };
    var buffer: [64]u32 = undefined;
    var count: usize = 0;
    while (matches != 0 and attempts > 0) : (matches &= matches - 1) {
        const pos = (head + @ctz(matches)) & mask;
        if (pos == 0) continue;
        const m = st.hash[row + pos];
        if (m < low) break;
        @prefetch(b.ptr(m), .{});
        buffer[count] = m;
        count += 1;
        attempts -= 1;
    }
    // The current position goes in too: one less to insert next time.
    {
        const n = nextEntry(st.tags[row..], mask);
        st.tags[row + n] = tag;
        st.hash[row + n] = @intCast(st.next);
        st.next += 1;
    }
    var best: Found = .{ .len = 3, .off = 0 };
    for (buffer[0..count]) |m| {
        if (b.load32(m + best.len - 3) == b.load32(ip + best.len - 3)) {
            const len = b.count(m, ip, i_end);
            if (len > best.len) {
                best = .{ .len = len, .off = ip - m + 3 };
                if (ip + len == i_end) break;
            }
        }
    }
    return best;
}
