//! The `greedy`, `lazy` and `lazy2` strategies (levels 5-12): at each
//! position the longest match among a bounded number of candidates, taken
//! at once (greedy) or held while the next one or two positions are tried
//! for a better one, with a gain rule weighing length against the offset's
//! cost. Candidates come from hash chains (small windows) or from rows of
//! a hash table, each entry tagged with 8 more bits of the hash so a vector
//! compare picks the candidates worth reading (larger windows). btlazy2
//! (levels 13-15) is lazy2 over a binary tree of the positions sharing a
//! hash, sorted lazily: positions are chained as they come and put in the
//! tree only when a search passes them.

const std = @import("std");
const builtin = @import("builtin");
const window = @import("window.zig");
const encode = @import("../sequences.zig");

const Window = window.Window;
const Bytes = window.Bytes;

pub const Search = enum { chain, row, tree };

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
    /// Trees: two entries per position, its smaller and larger subtrees
    /// (until sorted: the previous position and `unsorted`).
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
pub noinline fn compress(comptime search: Search, comptime depth: u2, comptime mls: u4, comptime rl: u3, st: *State, w: Window, store: *encode.SeqStore, reps: *[3]u32, start: usize, end: usize) usize {
    const b: Bytes = .of(w);
    const i_start: usize = w.index(start);
    const i_end: usize = w.index(end);
    const extra: usize = if (search == .row) cache_size else 0;
    if (end - start < 8 + extra + 1) return end - start;
    const limit = i_end - 8 - extra;
    // The start of the input: catching up stops above it.
    const prefix: usize = w.lowFor(start, st.window_log);
    var ip = i_start;
    var anchor = i_start;
    var rep1 = reps[0];
    var rep2 = reps[1];
    ip += @intFromBool(ip == prefix);
    const max_rep = ip - lowest(st, w, ip);
    const saved1 = window.disableRep(&rep1, max_rep);
    const saved2 = window.disableRep(&rep2, max_rep);
    st.skipping = false;
    if (search == .row) fillCache(mls, rl, st, b, st.next, limit);
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
            const found = find(search, mls, rl, st, w, b, ip, i_end);
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
                    if (off != 0 and rep1 > 0) {
                        if (betterRep(b, rep1, ip, i_end, len, off, 3)) |rep_len| {
                            len = rep_len;
                            off = 1;
                            match_at = ip;
                        }
                    }
                    {
                        const c = find(search, mls, rl, st, w, b, ip, i_end);
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
                        if (off != 0 and rep1 > 0) {
                            if (betterRep(b, rep1, ip, i_end, len, off, 4)) |rep_len| {
                                len = rep_len;
                                off = 1;
                                match_at = ip;
                            }
                        }
                        const c = find(search, mls, rl, st, w, b, ip, i_end);
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
            if (search == .row) fillCache(mls, rl, st, b, st.next, limit);
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
    window.restoreReps(reps, rep1, rep2, saved1, saved2);
    return i_end - anchor;
}

inline fn betterRep(b: Bytes, rep: u32, ip: usize, end: usize, len: usize, off: usize, weight: usize) ?usize {
    if (b.load32(ip) != b.load32(ip - rep)) return null;
    const n = b.count(ip + 4 - rep, ip + 4, end) + 4;
    if (@as(i64, @intCast(n * weight)) > @as(i64, @intCast(len * weight)) - log2(off) + 1) return n;
    return null;
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

inline fn find(comptime search: Search, comptime mls: u4, comptime rl: u3, st: *State, w: Window, b: Bytes, ip: usize, i_end: usize) Found {
    return switch (search) {
        .chain => findInChain(mls, st, w, b, ip, i_end),
        .row => findInRow(mls, rl, st, w, b, ip, i_end),
        .tree => findInTree(mls, st, w, b, ip, i_end),
    };
}

// ---- hash chains ----

/// Insert positions up to `ip` (excluded) and return the newest with
/// `ip`'s hash.
inline fn insertChain(comptime mls: u4, st: *State, b: Bytes, ip: usize) usize {
    const mask = (@as(usize, 1) << st.chain_log) - 1;
    var i = st.next;
    while (i < ip) {
        const h = b.hash(mls, i, st.hash_log);
        st.chain[i & mask] = st.hash[h];
        st.hash[h] = @intCast(i);
        i += 1;
        if (st.skipping) break;
    }
    st.next = ip;
    return st.hash[b.hash(mls, ip, st.hash_log)];
}

fn findInChain(comptime mls: u4, st: *State, w: Window, b: Bytes, ip: usize, i_end: usize) Found {
    const chain_size = @as(usize, 1) << st.chain_log;
    const mask = chain_size - 1;
    const low = lowest(st, w, ip);
    const min_chain = if (ip > chain_size) ip - chain_size else 0;
    var attempts = @as(usize, 1) << st.search_log;
    var best: Found = .{ .len = 3, .off = 0 };
    var m = insertChain(mls, st, b, ip);
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

inline fn rowHash(comptime mls: u4, st: *const State, b: Bytes, i: usize) u32 {
    return b.hash(mls, i, st.hash_log + tag_bits);
}

inline fn prefetchRow(comptime rl: u3, st: *const State, row: usize) void {
    @prefetch(st.hash.ptr + row, .{});
    if (rl >= 5) @prefetch(st.hash.ptr + row + 16, .{});
    @prefetch(st.tags.ptr + row, .{});
    if (rl == 6) @prefetch(st.tags.ptr + row + 32, .{});
}

/// The hashes of the next positions, rows fetched ahead.
fn fillCache(comptime mls: u4, comptime rl: u3, st: *State, b: Bytes, from: usize, limit: usize) void {
    const n = if (from > limit) 0 else @min(cache_size, limit - from + 1);
    for (from..from + n) |i| {
        const h = rowHash(mls, st, b, i);
        prefetchRow(rl, st, (h >> tag_bits) << rl);
        st.cache[i & (cache_size - 1)] = h;
    }
}

/// The hash of `i` from the cache, replaced by the hash `cache_size` on.
inline fn nextCachedHash(comptime mls: u4, comptime rl: u3, st: *State, b: Bytes, i: usize) u32 {
    const new = rowHash(mls, st, b, i + cache_size);
    prefetchRow(rl, st, (new >> tag_bits) << rl);
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

fn insertRows(comptime mls: u4, comptime rl: u3, st: *State, b: Bytes, from: usize, to: usize) void {
    const mask = (@as(u32, 1) << rl) - 1;
    for (from..to) |i| {
        const h = nextCachedHash(mls, rl, st, b, i);
        const row = (@as(usize, h) >> tag_bits) << rl;
        const n = nextEntry(st.tags[row..], mask);
        st.tags[row + n] = @truncate(h);
        st.hash[row + n] = @intCast(i);
    }
}

inline fn updateRows(comptime mls: u4, comptime rl: u3, st: *State, b: Bytes, ip: usize) void {
    var i = st.next;
    // After a long match only its first and last positions are inserted.
    if (ip - i > 384) {
        insertRows(mls, rl, st, b, i, i + 96);
        i = ip - 32;
        fillCache(mls, rl, st, b, i, ip + 1);
    }
    insertRows(mls, rl, st, b, i, ip);
    st.next = ip;
}

/// The entries of a row that carry `tag`: bit `k << group_log` for the
/// entry `k` places on from the head, newest first.
const Matches = struct {
    bits: u64,
    group_log: u3,

    inline fn next(m: Matches, head: u32) u32 {
        return head +% (@ctz(m.bits) >> m.group_log);
    }
};

/// Which entries of a row carry `tag`, newest first: bit k for the entry
/// k places on from the head.
inline fn matchMask(comptime entries: usize, tags: []const u8, tag: u8, head: u32) Matches {
    // A 16-entry row on a vector unit that cannot gather a compare into
    // bits cheaply gets a nibble for each entry: narrowing the compare by
    // four bits does it in one instruction.
    if (entries == 16 and builtin.cpu.arch == .aarch64) {
        const row: @Vector(16, u8) = tags[0..16].*;
        const eq: @Vector(16, u8) = @select(u8, row == @as(@Vector(16, u8), @splat(tag)), @as(@Vector(16, u8), @splat(0xff)), @as(@Vector(16, u8), @splat(0)));
        const narrowed: @Vector(8, u8) = @truncate(@as(@Vector(8, u16), @bitCast(eq)) >> @as(@Vector(8, u16), @splat(4)));
        const nibbles: u64 = @bitCast(narrowed);
        return .{ .bits = std.math.rotr(u64, nibbles & 0x1111_1111_1111_1111, 4 * head), .group_log = 2 };
    }
    const vector = @Vector(entries, u8);
    const row: vector = tags[0..entries].*;
    const eq = row == @as(vector, @splat(tag));
    const mask_type = @Int(.unsigned, entries);
    const mask: mask_type = @bitCast(eq);
    return .{ .bits = std.math.rotr(mask_type, mask, head), .group_log = 0 };
}

fn findInRow(comptime mls: u4, comptime rl: u3, st: *State, w: Window, b: Bytes, ip: usize, i_end: usize) Found {
    const low = lowest(st, w, ip);
    const entries = @as(u32, 1) << rl;
    const mask = entries - 1;
    var attempts: usize = @as(usize, 1) << @min(st.search_log, rl);
    var h: u32 = undefined;
    if (!st.skipping) {
        updateRows(mls, rl, st, b, ip);
        h = nextCachedHash(mls, rl, st, b, ip);
    } else {
        h = rowHash(mls, st, b, ip);
        st.next = ip;
    }
    const row = (@as(usize, h) >> tag_bits) << rl;
    const tag: u8 = @truncate(h);
    const tags = st.tags[row..][0..entries];
    const head = tags[0] & mask;
    var matches: Matches = matchMask(@as(usize, 1) << rl, tags, tag, head);
    var buffer: [64]u32 = undefined;
    var count: usize = 0;
    while (matches.bits != 0 and attempts > 0) : (matches.bits &= matches.bits - 1) {
        const pos = matches.next(head) & mask;
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

// ---- binary tree ----

/// A tree entry whose position is chained but not yet sorted. Indices
/// start above it.
const unsorted = 1;

/// Chain the positions up to `ip` (excluded) as unsorted.
fn updateTree(comptime mls: u4, st: *State, b: Bytes, ip: usize) void {
    const mask = (@as(usize, 1) << (st.chain_log - 1)) - 1;
    var i = st.next;
    while (i < ip) : (i += 1) {
        const h = b.hash(mls, i, st.hash_log);
        const e = 2 * (i & mask);
        st.chain[e] = st.hash[h];
        st.chain[e + 1] = unsorted;
        st.hash[h] = @intCast(i);
    }
    st.next = ip;
}

/// Sort the chained position `curr` into the tree below it.
fn insertTree(st: *State, w: Window, b: Bytes, curr: usize, i_end: usize, compares_: usize, bt_low: usize) void {
    const mask = (@as(usize, 1) << (st.chain_log - 1)) - 1;
    // A local copy: stores into the tree cannot change it.
    const bt = st.chain;
    var compares = compares_;
    var common_smaller: usize = 0;
    var common_larger: usize = 0;
    // The chain link to the next older position; it is overwritten.
    var m: usize = bt[2 * (curr & mask)];
    var dummy: u32 = 0;
    const low = lowest(st, w, curr);
    var smaller_ptr: *u32 = &bt[2 * (curr & mask)];
    var larger_ptr: *u32 = &bt[2 * (curr & mask) + 1];
    while (compares > 0 and m > low) : (compares -= 1) {
        const next = 2 * (m & mask);
        var len = @min(common_smaller, common_larger);
        len += b.count(m + len, curr + len, i_end);
        if (curr + len == i_end) break;
        if (b.byte(m + len) < b.byte(curr + len)) {
            smaller_ptr.* = @intCast(m);
            common_smaller = len;
            if (m <= bt_low) {
                smaller_ptr = &dummy;
                break;
            }
            smaller_ptr = &bt[next + 1];
            m = bt[next + 1];
        } else {
            larger_ptr.* = @intCast(m);
            common_larger = len;
            if (m <= bt_low) {
                larger_ptr = &dummy;
                break;
            }
            larger_ptr = &bt[next];
            m = bt[next];
        }
    }
    smaller_ptr.* = 0;
    larger_ptr.* = 0;
}

fn findInTree(comptime mls: u4, st: *State, w: Window, b: Bytes, ip: usize, i_end: usize) Found {
    // Inside a long match just taken: not searched.
    if (ip < st.next) return .{ .len = 0, .off = 0 };
    updateTree(mls, st, b, ip);
    const mask = (@as(usize, 1) << (st.chain_log - 1)) - 1;
    // A local copy: stores into the tree cannot change it.
    const bt = st.chain;
    const h = b.hash(mls, ip, st.hash_log);
    const low = lowest(st, w, ip);
    const bt_low = if (mask >= ip) 0 else ip - mask;
    const unsort_limit = @max(bt_low, low);
    var compares = @as(usize, 1) << st.search_log;
    var candidates = compares;
    var previous: usize = 0;
    // Walk the unsorted positions, linking them back in a reversed chain.
    var m: usize = st.hash[h];
    while (m > unsort_limit and bt[2 * (m & mask) + 1] == unsorted and candidates > 1) {
        const e = 2 * (m & mask);
        bt[e + 1] = @intCast(previous);
        previous = m;
        m = bt[e];
        candidates -= 1;
    }
    // The last one left unsorted is dropped: faster, a little worse.
    if (m > unsort_limit and bt[2 * (m & mask) + 1] == unsorted) {
        const e = 2 * (m & mask);
        bt[e] = 0;
        bt[e + 1] = 0;
    }
    // Sort them, oldest first.
    m = previous;
    while (m != 0) {
        const next = bt[2 * (m & mask) + 1];
        insertTree(st, w, b, m, i_end, candidates, unsort_limit);
        m = next;
        candidates += 1;
    }
    // Insert `ip`, finding the longest match on the way down.
    var common_smaller: usize = 0;
    var common_larger: usize = 0;
    var dummy: u32 = 0;
    var smaller_ptr: *u32 = &bt[2 * (ip & mask)];
    var larger_ptr: *u32 = &bt[2 * (ip & mask) + 1];
    var match_end = ip + 8 + 1;
    var best: usize = 0;
    var off: usize = 999999999;
    m = st.hash[h];
    st.hash[h] = @intCast(ip);
    while (compares > 0 and m > low) : (compares -= 1) {
        const next = 2 * (m & mask);
        var len = @min(common_smaller, common_larger);
        len += b.count(m + len, ip + len, i_end);
        if (len > best) {
            if (len > match_end - m) match_end = m + len;
            if (4 * @as(i64, @intCast(len - best)) > @as(i64, highbit(ip - m + 1)) - highbit(off)) {
                best = len;
                off = ip - m + 3;
            }
            if (ip + len == i_end) break;
        }
        if (b.byte(m + len) < b.byte(ip + len)) {
            smaller_ptr.* = @intCast(m);
            common_smaller = len;
            if (m <= bt_low) {
                smaller_ptr = &dummy;
                break;
            }
            smaller_ptr = &bt[next + 1];
            m = bt[next + 1];
        } else {
            larger_ptr.* = @intCast(m);
            common_larger = len;
            if (m <= bt_low) {
                larger_ptr = &dummy;
                break;
            }
            larger_ptr = &bt[next];
            m = bt[next];
        }
    }
    smaller_ptr.* = 0;
    larger_ptr.* = 0;
    // Positions inside a long match are not inserted.
    st.next = match_end - 8;
    return .{ .len = best, .off = off };
}

inline fn highbit(v: usize) i64 {
    return std.math.log2_int(u32, @intCast(v));
}

test "the entries that carry a tag come newest first from the head, however the mask is made" {
    var prng: std.Random.DefaultPrng = .init(3);
    const random = prng.random();
    inline for ([_]usize{ 16, 32, 64 }) |entries| {
        for (0..400) |_| {
            var tags: [64]u8 = undefined;
            // Few distinct tags, so that rows have several matches.
            for (tags[0..entries]) |*t| t.* = random.uintLessThan(u8, 4);
            const tag = random.uintLessThan(u8, 4);
            const head = random.uintLessThan(u32, entries);
            var matches = matchMask(entries, tags[0..entries], tag, head);
            var k: u32 = 0;
            while (k < entries) : (k += 1) {
                if (tags[(head + k) % entries] != tag) continue;
                try std.testing.expect(matches.bits != 0);
                try std.testing.expectEqual(k, @ctz(matches.bits) >> matches.group_log);
                matches.bits &= matches.bits - 1;
            }
            try std.testing.expectEqual(@as(u64, 0), matches.bits);
        }
    }
}
