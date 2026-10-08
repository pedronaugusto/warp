//! Binary-tree matches and adaptive shortest-path parsing. btopt uses
//! integer bit prices and skips unpromising positions; btultra considers
//! every reachable position with fractional prices. btultra2 primes those
//! prices with a first pass over the first block.
const std = @import("std");
const window = @import("window.zig");
const sequences = @import("../sequences.zig");
const price = @import("price.zig");
const Window = window.Window;
const Bytes = window.Bytes;

const horizon = 4096;
const infinity = 1 << 30;

const Match = struct { off: u32, len: u32 };
const Node = struct {
    cost: i32 = infinity,
    off: u32 = 0,
    ml: u32 = 0,
    lit: u32 = 0,
    reps: [3]u32 = .{ 1, 4, 8 },
};

/// Scratch used only by optimal strategies, in the compressor's memory.
pub const Workspace = struct {
    nodes: [horizon + 3]Node,
    matches: [horizon + 3]Match,
    model: price.Model,
};

/// Match tables and insertion positions for an optimal parse.
pub const State = struct {
    hash: []u32,
    tree: []u32,
    hash3: []u32,
    hash_log: u5,
    hash3_log: u5,
    window_log: u5,
    search_log: u5,
    target: u32,
    next: usize,
    next3: usize,
    workspace: *Workspace,
};

/// Parse one block; returns its trailing literals.
pub noinline fn compress(comptime accurate: bool, comptime mls: u4, st: *State, w: Window, store: *sequences.SeqStore, reps: *[3]u32, start: usize, end: usize) usize {
    if (end - start < 9) return end - start;
    const b = Bytes.of(w);
    const limit = w.index(end) - 8;
    const iend = w.index(end);
    var ip: usize = w.index(start);
    var anchor = ip;
    ip += @intFromBool(ip == w.start);
    const model = &st.workspace.model;
    model.begin(accurate, w.in[start..end]);
    const nodes = &st.workspace.nodes;
    const min_match: u32 = if (mls == 3) 3 else 4;
    while (ip < limit) {
        const lit: u32 = @intCast(ip - anchor);
        const matches = findAll(mls, st, w, b, ip, iend, reps.*, lit == 0);
        if (matches.len == 0) {
            ip += 1;
            continue;
        }
        nodes[0] = .{ .lit = lit, .cost = model.literalLength(accurate, lit), .reps = reps.* };
        const longest = matches[matches.len - 1];
        var terminal: Node = undefined;
        var current: u32 = 0;
        var last: u32 = longest.len;
        if (longest.len > @min(st.target, horizon - 1)) {
            terminal = .{ .ml = longest.len, .off = longest.off };
        } else {
            seed(accurate, min_match, st, matches, lit);
            const path = extend(accurate, mls, st, w, b, ip, iend, last);
            terminal = path.terminal;
            current = path.current;
            last = path.last;
        }
        if (terminal.ml == 0) {
            ip += last;
            continue;
        }
        if (terminal.lit == 0) {
            reps.* = newReps(nodes[current].reps, terminal.off, nodes[current].lit == 0);
        } else {
            reps.* = terminal.reps;
            current -= terminal.lit;
        }
        const first = reverse(nodes, current, terminal);
        const finish = current + 2;
        for (nodes[first .. finish + 1]) |q| {
            if (q.ml == 0) {
                ip = anchor + q.lit;
                continue;
            }
            const from = anchor - w.start;
            model.update(w.in[from..][0..q.lit], q.off, q.ml);
            store.store(w.in, from, from + q.lit, end, q.off, q.ml);
            anchor += q.lit + q.ml;
            ip = anchor;
        }
        model.updateBases(accurate);
    }
    return iend - anchor;
}

fn seed(comptime accurate: bool, min_match: u32, st: *State, matches: []const Match, lit: u32) void {
    const nodes = &st.workspace.nodes;
    const model = &st.workspace.model;
    var pos: u32 = 1;
    while (pos < min_match) : (pos += 1) nodes[pos] = .{ .lit = lit + pos };
    for (matches) |m| {
        while (pos <= m.len) : (pos += 1) {
            nodes[pos] = .{ .ml = pos, .off = m.off, .cost = nodes[0].cost + model.match(accurate, m.off, pos) + model.literalLength(accurate, 0) };
        }
    }
    nodes[pos] = .{};
}

const Path = struct { terminal: Node, current: u32, last: u32 };

fn extend(comptime accurate: bool, comptime mls: u4, st: *State, w: Window, b: Bytes, ip: usize, end: usize, initial: u32) Path {
    const nodes = &st.workspace.nodes;
    const model = &st.workspace.model;
    var last = initial;
    var cur: u32 = 1;
    while (cur <= last) : (cur += 1) {
        advanceLiteral(accurate, st, b, ip, end, cur, &last);
        if (nodes[cur].lit == 0) {
            const prev = cur - nodes[cur].ml;
            nodes[cur].reps = newReps(nodes[prev].reps, nodes[cur].off, nodes[prev].lit == 0);
        }
        if (ip + cur > end - 8) continue;
        if (cur == last) break;
        if (!accurate and nodes[cur + 1].cost <= nodes[cur].cost + 128) continue;
        const matches = findAll(mls, st, w, b, ip + cur, end, nodes[cur].reps, nodes[cur].lit == 0);
        if (matches.len == 0) continue;
        const longest = matches[matches.len - 1];
        if (longest.len > @min(st.target, horizon - 1) or cur + longest.len >= horizon or ip + cur + longest.len >= end) {
            return .{ .terminal = .{ .ml = longest.len, .off = longest.off }, .current = cur, .last = cur + longest.len };
        }
        const base = nodes[cur].cost + model.literalLength(accurate, 0);
        var start: u32 = if (mls == 3) 3 else 4;
        for (matches) |m| {
            var ml = m.len;
            while (ml >= start) : (ml -= 1) {
                const pos = cur + ml;
                const cost = base + model.match(accurate, m.off, ml);
                if (pos > last or cost < nodes[pos].cost) {
                    while (last < pos) {
                        last += 1;
                        nodes[last] = .{ .lit = 1 };
                    }
                    nodes[pos] = .{ .ml = ml, .off = m.off, .cost = cost };
                } else if (!accurate) break;
            }
            start = m.len + 1;
        }
        nodes[last + 1] = .{};
    }
    return .{ .terminal = nodes[last], .current = last - nodes[last].ml, .last = last };
}

fn advanceLiteral(comptime accurate: bool, st: *State, b: Bytes, ip: usize, end: usize, cur: u32, last: *u32) void {
    const nodes = &st.workspace.nodes;
    const model = &st.workspace.model;
    const lit = nodes[cur - 1].lit + 1;
    const cost = nodes[cur - 1].cost + model.literal(accurate, b.byte(ip + cur - 1)) + model.increment(accurate, lit);
    if (cost > nodes[cur].cost) return;
    const prev_match = nodes[cur];
    nodes[cur] = nodes[cur - 1];
    nodes[cur].lit = lit;
    nodes[cur].cost = cost;
    if (accurate and prev_match.lit == 0 and model.increment(accurate, 1) < 0 and ip + cur < end) {
        const with_one = prev_match.cost + model.literal(accurate, b.byte(ip + cur)) + model.increment(accurate, 1);
        const with_more = cost + model.literal(accurate, b.byte(ip + cur)) + model.increment(accurate, lit + 1);
        if (with_one < with_more and with_one < nodes[cur + 1].cost) {
            const prev = cur - prev_match.ml;
            nodes[cur + 1] = prev_match;
            nodes[cur + 1].reps = newReps(nodes[prev].reps, prev_match.off, nodes[prev].lit == 0);
            nodes[cur + 1].lit = 1;
            nodes[cur + 1].cost = with_one;
            last.* = @max(last.*, cur + 1);
        }
    }
}

fn reverse(nodes: *[horizon + 3]Node, current: u32, terminal: Node) u32 {
    var at = current;
    var first = current + 2;
    nodes[first] = terminal;
    while (true) {
        const previous = nodes[at];
        nodes[first].lit = previous.lit;
        if (previous.ml == 0) return first;
        first -= 1;
        nodes[first] = previous;
        at -= previous.lit + previous.ml;
    }
}

/// Offset histories use offBase values 1-3 for repeats and offset+3 otherwise.
const newReps = sequences.updateReps;

fn findAll(comptime mls: u4, st: *State, w: Window, b: Bytes, curr: usize, end: usize, reps: [3]u32, zero_literals: bool) []const Match {
    if (curr < st.next) return &.{};
    while (st.next < curr) st.next += insert(mls, st, w, b, st.next, end, curr);
    st.next = curr;
    const matches = &st.workspace.matches;
    var n: usize = 0;
    var best: usize = if (mls == 3) 2 else 3;
    const sufficient = @min(st.target, horizon - 1);
    const low = lowest(st, w, curr);
    const min_match: usize = if (mls == 3) 3 else 4;
    const first: usize = @intFromBool(zero_literals);
    for (first..3 + first) |code| {
        const distance = if (code == 3) reps[0] -| 1 else reps[code];
        if (distance == 0 or distance > curr - low) continue;
        const at = curr - distance;
        if (!equal(min_match, b, at, curr)) continue;
        const len = min_match + b.count(at + min_match, curr + min_match, end);
        if (len <= best) continue;
        best = len;
        matches[n] = .{ .off = @intCast(code - first + 1), .len = @intCast(len) };
        n += 1;
        if (len > sufficient or curr + len == end) return matches[0..n];
    }
    if (mls == 3 and best < 3) {
        while (st.next3 < curr) : (st.next3 += 1) st.hash3[b.hash(3, st.next3, st.hash3_log)] = @intCast(st.next3);
        const at = st.hash3[b.hash(3, curr, st.hash3_log)];
        if (at >= low and curr - at < 1 << 18) {
            const len = b.count(at, curr, end);
            if (len >= 3) {
                best = len;
                matches[n] = .{ .off = @intCast(curr - at + 3), .len = @intCast(len) };
                n += 1;
                if (len > sufficient or curr + len == end) {
                    st.next = curr + 1;
                    return matches[0..n];
                }
            }
        }
    }
    const result = walk(mls, st, w, b, curr, end, curr, best, matches[n..]);
    st.next = result.forward + curr;
    return matches[0 .. n + result.count];
}

inline fn equal(min_match: usize, b: Bytes, a: usize, c: usize) bool {
    const x = b.load32(a) ^ b.load32(c);
    return if (min_match == 3) x & 0xffffff == 0 else x == 0;
}

inline fn lowest(st: *const State, w: Window, curr: usize) usize {
    return @max(w.start, curr -| (@as(usize, 1) << st.window_log));
}

const Walk = struct { count: usize, forward: usize, best: usize };

fn insert(comptime mls: u4, st: *State, w: Window, b: Bytes, curr: usize, end: usize, target: usize) usize {
    const found = walk(mls, st, w, b, curr, end, target, 8, &.{});
    const skip = if (found.best > 384) @min(192, found.best - 384) else 0;
    return @max(skip, found.forward);
}

fn walk(comptime mls: u4, st: *State, w: Window, b: Bytes, curr: usize, end: usize, target: usize, initial: usize, matches: []Match) Walk {
    const hash = b.hash(if (mls == 3) 4 else mls, curr, st.hash_log);
    var at: usize = st.hash[hash];
    st.hash[hash] = @intCast(curr);
    const tree = st.tree;
    const mask = tree.len / 2 - 1;
    const tree_low = curr -| mask;
    const low = lowest(st, w, target);
    var dummy: u32 = 0;
    var smaller: *u32 = &tree[2 * (curr & mask)];
    var larger: *u32 = &tree[2 * (curr & mask) + 1];
    var small_len: usize = 0;
    var large_len: usize = 0;
    var best = initial;
    var farthest = curr + 9;
    var n: usize = 0;
    var tries = @as(u32, 1) << st.search_log;
    while (tries > 0 and at >= low) : (tries -= 1) {
        const next = 2 * (at & mask);
        var len = @min(small_len, large_len);
        len += b.count(at + len, curr + len, end);
        if (len > best) {
            best = len;
            farthest = @max(farthest, at + len);
            if (matches.len != 0) {
                matches[n] = .{ .off = @intCast(curr - at + 3), .len = @intCast(len) };
                n += 1;
            }
            if (curr + len == end or (matches.len != 0 and len > horizon)) break;
        }
        if (b.byte(at + len) < b.byte(curr + len)) {
            smaller.* = @intCast(at);
            small_len = len;
            if (at <= tree_low) {
                smaller = &dummy;
                break;
            }
            smaller = &tree[next + 1];
            at = tree[next + 1];
        } else {
            larger.* = @intCast(at);
            large_len = len;
            if (at <= tree_low) {
                larger = &dummy;
                break;
            }
            larger = &tree[next];
            at = tree[next];
        }
    }
    smaller.* = 0;
    larger.* = 0;
    return .{ .count = n, .forward = farthest - curr - 8, .best = best };
}

test "optimal repeat histories include the zero-literal shift" {
    try std.testing.expectEqual([3]u32{ 4, 8, 16 }, newReps(.{ 8, 16, 32 }, 7, false));
    try std.testing.expectEqual([3]u32{ 16, 8, 32 }, newReps(.{ 8, 16, 32 }, 1, true));
    try std.testing.expectEqual([3]u32{ 7, 8, 16 }, newReps(.{ 8, 16, 32 }, 3, true));
}
