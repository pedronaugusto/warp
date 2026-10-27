//! LZMA's parsers, as liblzma 5.8.4 chooses symbols. `normal` prices
//! every path through the next positions (literals, short reps, repeated
//! and new matches, and a match or repeat followed by a literal and a
//! rep0) and takes the cheapest; `fast` takes the longest match, or a
//! repeated one nearly as long, looking one byte ahead.
//!
//! Both read the finder at the coding position and ahead of it: `read_pos`
//! is past the last position searched, `read_ahead` how far that is past
//! the next symbol's start. `run` codes their choices.

const std = @import("std");
const range = @import("range.zig");
const decode = @import("decode.zig");
const encode = @import("encode.zig");
const lengthIn = @import("../match.zig").matchLengthIn;

const Coder = encode.Coder;
const Symbol = encode.Symbol;
const Optimal = encode.Optimal;
const State = decode.State;
const literal_back = encode.literal_back;
const reps_len = encode.reps_len;
const opts_len = encode.opts_len;
const match_len_max = encode.match_len_max;
const infinity = range.infinity;

/// Where a run stops short of the input's end: an LZMA2 chunk's limits.
pub const Chunk = struct {
    /// The input position (`read_pos - read_ahead`) the run stops at.
    limit: usize,
    /// The output, with the coder's pending bytes, the run stops at.
    budget: u64,
};

pub const Status = enum {
    /// The input is coded up to the finder's limit and more may come.
    need_input,
    /// The input is coded to its end, or the chunk's limits are reached.
    done,
};

/// Code symbols from the finder until its input ends or `chunk`'s limits
/// are reached. The range coder is not flushed.
pub fn run(c: *Coder, f: anytype, chunk: ?Chunk) Status {
    if (!c.started) {
        if (f.read_pos == f.read_limit) {
            if (!f.finishing) return .need_input;
        } else c.start(f);
    }
    while (true) {
        if (chunk) |k| if (f.read_pos - f.read_ahead >= k.limit or c.rc.pos + c.rc.pending() >= k.budget) return .done;
        if (f.read_pos >= f.read_limit) {
            if (!f.finishing) return .need_input;
            if (f.read_ahead == 0) return .done;
        }
        const s = if (c.fast) fast(c, f) else normal(c, f);
        c.symbol(f, s);
    }
}

inline fn literal1() Symbol {
    return .{ .back = literal_back, .len = 1 };
}

inline fn makeLiteral(o: *Optimal) void {
    o.back_prev = literal_back;
    o.prev_1_is_literal = false;
}

inline fn makeShortRep(o: *Optimal) void {
    o.back_prev = 0;
    o.prev_1_is_literal = false;
}

/// Whether two bytes from `at` repeat the two from `back`.
inline fn pair(b: []const u8, back: usize, at: usize) bool {
    return b[at] == b[back] and b[at + 1] == b[back + 1];
}

/// The optimal parser's next symbol.
pub fn normal(c: *Coder, f: anytype) Symbol {
    if (c.opts_end != c.opts_current) {
        // The rest of the path chosen last time.
        const o = c.opts[c.opts_current];
        const s: Symbol = .{ .len = o.pos_prev - c.opts_current, .back = o.back_prev };
        c.opts_current = o.pos_prev;
        return s;
    }
    if (f.read_ahead == 0) {
        if (c.match_price_count >= 1 << 7) c.fillDistPrices();
        if (c.align_price_count >= 1 << decode.align_bits) c.fillAlignPrices();
    }
    const position = c.position;
    var len_end = switch (begin(c, f, position)) {
        .symbol => |s| return s,
        .len_end => |l| l,
    };
    var reps = c.reps;
    var cur: u32 = 1;
    while (cur < len_end) : (cur += 1) {
        c.longest = f.find(&c.matches, &c.matches_count);
        if (c.longest >= f.nice_len) break;
        const avail_full: u32 = @intCast(@min(f.avail() + 1, opts_len - 1 - cur));
        len_end = step(c, f.buf, f.read_pos - 1, &reps, len_end, position + cur, cur, f.nice_len, avail_full);
    }
    return backward(c, cur);
}

const Begin = union(enum) { symbol: Symbol, len_end: u32 };

/// The first position: a symbol where the choice is plain (a match as
/// long as `nice_len`, or nothing to match), else the prices of reaching
/// each length from it; the path's end so far.
fn begin(c: *Coder, f: anytype, position: u64) Begin {
    const nice_len = f.nice_len;
    var len_main: u32 = undefined;
    var count: u32 = undefined;
    if (f.read_ahead == 0) {
        len_main = f.find(&c.matches, &count);
    } else {
        len_main = c.longest;
        count = c.matches_count;
    }
    const buf_avail: u32 = @intCast(@min(f.avail() + 1, match_len_max));
    if (buf_avail < 2) return .{ .symbol = literal1() };
    const b = f.buf;
    const at = f.read_pos - 1;
    var rep_lens: [reps_len]u32 = undefined;
    var rep_max: u32 = 0;
    for (0..reps_len) |i| {
        const back = at - c.reps[i] - 1;
        if (!pair(b, back, at)) {
            rep_lens[i] = 0;
            continue;
        }
        rep_lens[i] = lengthIn(b, back, at, 2, buf_avail);
        if (rep_lens[i] > rep_lens[rep_max]) rep_max = @intCast(i);
    }
    if (rep_lens[rep_max] >= nice_len) {
        f.skip(rep_lens[rep_max] - 1);
        return .{ .symbol = .{ .back = rep_max, .len = rep_lens[rep_max] } };
    }
    if (len_main >= nice_len) {
        f.skip(len_main - 1);
        return .{ .symbol = .{ .back = c.matches[count - 1].dist + reps_len, .len = len_main } };
    }
    const current_byte = b[at];
    const match_byte = b[at - c.reps[0] - 1];
    if (len_main < 2 and current_byte != match_byte and rep_lens[rep_max] < 2) return .{ .symbol = literal1() };
    const p = &c.probs;
    const state = c.state;
    c.opts[0].state = state;
    const pos_state = c.posState(position);
    c.opts[1].price = range.bit0Price(p.is_match[state][pos_state]) + c.literalPrice(position, b[at - 1], state >= 7, match_byte, current_byte);
    makeLiteral(&c.opts[1]);
    const match_price = range.bit1Price(p.is_match[state][pos_state]);
    const rep_match_price = match_price + range.bit1Price(p.is_rep[state]);
    if (match_byte == current_byte) {
        const short_rep_price = rep_match_price + c.shortRepPrice(state, pos_state);
        if (short_rep_price < c.opts[1].price) {
            c.opts[1].price = short_rep_price;
            makeShortRep(&c.opts[1]);
        }
    }
    const len_end = @max(len_main, rep_lens[rep_max]);
    if (len_end < 2) return .{ .symbol = .{ .back = c.opts[1].back_prev, .len = 1 } };
    c.opts[1].pos_prev = 0;
    c.opts[0].backs = c.reps;
    var len = len_end;
    while (len >= 2) : (len -= 1) unreached(&c.opts[len]);
    for (0..reps_len) |i| {
        var rep_len = rep_lens[i];
        if (rep_len < 2) continue;
        const price = rep_match_price + c.pureRepPrice(@intCast(i), state, pos_state);
        while (rep_len >= 2) : (rep_len -= 1) {
            const total = price + c.rep_len.price(rep_len, pos_state);
            if (total < c.opts[rep_len].price) c.opts[rep_len] = reached(c.opts[rep_len], total, 0, @intCast(i));
        }
    }
    const normal_match_price = match_price + range.bit0Price(p.is_rep[state]);
    len = if (rep_lens[0] >= 2) rep_lens[0] + 1 else 2;
    if (len <= len_main) {
        var i: u32 = 0;
        while (len > c.matches[i].len) i += 1;
        while (true) : (len += 1) {
            const dist = c.matches[i].dist;
            const total = normal_match_price + c.distLenPrice(dist, len, pos_state);
            if (total < c.opts[len].price) c.opts[len] = reached(c.opts[len], total, 0, dist + reps_len);
            if (len == c.matches[i].len) {
                i += 1;
                if (i == count) break;
            }
        }
    }
    return .{ .len_end = len_end };
}

/// `o` reached at `price` by one symbol from `pos_prev`.
inline fn reached(o: Optimal, price: u32, pos_prev: u32, back_prev: u32) Optimal {
    var r = o;
    r.price = price;
    r.pos_prev = pos_prev;
    r.back_prev = back_prev;
    r.prev_1_is_literal = false;
    return r;
}

/// `opts[offset]` reached at `price` by a match or repeat from `cur`, a
/// literal, then a rep0 from `offset - len`.
inline fn reachedTwice(c: *Coder, offset: u32, price: u32, pos_prev: u32, cur: u32, back_prev_2: u32) void {
    const o = &c.opts[offset];
    if (price >= o.price) return;
    o.price = price;
    o.pos_prev = pos_prev;
    o.back_prev = 0;
    o.prev_1_is_literal = true;
    o.prev_2 = true;
    o.pos_prev_2 = cur;
    o.back_prev_2 = back_prev_2;
}

/// The path reaches `end`: unreached positions up to it cost infinity.
inline fn extend(c: *Coder, len_end: *u32, end: u32) void {
    while (len_end.* < end) {
        len_end.* += 1;
        unreached(&c.opts[len_end.*]);
    }
}

/// A position no path reaches yet. Its link is read before a path does
/// (to skip a short rep after one), so it is set: as liblzma's first
/// stream finds it, and the same whatever an earlier stream left.
inline fn unreached(o: *Optimal) void {
    o.price = infinity;
    o.pos_prev = 0;
    o.back_prev = 0;
}

/// The state and distances where the cheapest path reaches `cur`, kept
/// in `opts[cur]`. `reps` holds those at `cur - 1`.
fn arrive(c: *Coder, reps: *[reps_len]u32, cur: u32) State {
    const o = &c.opts[cur];
    var pos_prev = o.pos_prev;
    var state: State = undefined;
    if (o.prev_1_is_literal) {
        pos_prev -= 1;
        if (o.prev_2) {
            state = c.opts[o.pos_prev_2].state;
            state = if (o.back_prev_2 < reps_len) decode.afterRep(state) else decode.afterMatch(state);
        } else state = c.opts[pos_prev].state;
        state = decode.afterLiteral(state);
    } else state = c.opts[pos_prev].state;
    if (pos_prev == cur - 1) {
        state = if (o.back_prev == 0) decode.afterShortRep(state) else decode.afterLiteral(state);
    } else {
        var back: u32 = undefined;
        if (o.prev_1_is_literal and o.prev_2) {
            pos_prev = o.pos_prev_2;
            back = o.back_prev_2;
            state = decode.afterRep(state);
        } else {
            back = o.back_prev;
            state = if (back < reps_len) decode.afterRep(state) else decode.afterMatch(state);
        }
        const backs = c.opts[pos_prev].backs;
        if (back < reps_len) {
            reps[0] = backs[back];
            var i: u32 = 1;
            while (i <= back) : (i += 1) reps[i] = backs[i - 1];
            while (i < reps_len) : (i += 1) reps[i] = backs[i];
        } else {
            reps.* = .{ back - reps_len, backs[0], backs[1], backs[2] };
        }
    }
    o.state = state;
    o.backs = reps.*;
    return state;
}

/// What the path at `cur` (input at `at`) reaches: a literal or short rep,
/// a literal then a rep0, repeated matches, new matches. The path's end.
fn step(c: *Coder, b: []const u8, at: usize, reps: *[reps_len]u32, len_end_in: u32, position: u64, cur: u32, nice_len: u32, avail_full: u32) u32 {
    var len_end = len_end_in;
    const p = &c.probs;
    const state = arrive(c, reps, cur);
    const cur_price = c.opts[cur].price;
    const current_byte = b[at];
    const match_byte = b[at - reps[0] - 1];
    const pos_state = c.posState(position);
    const cur_and_1_price = cur_price + range.bit0Price(p.is_match[state][pos_state]) + c.literalPrice(position, b[at - 1], state >= 7, match_byte, current_byte);
    var next_is_literal = false;
    const next = &c.opts[cur + 1];
    if (cur_and_1_price < next.price) {
        next.price = cur_and_1_price;
        next.pos_prev = cur;
        makeLiteral(next);
        next_is_literal = true;
    }
    const match_price = cur_price + range.bit1Price(p.is_match[state][pos_state]);
    const rep_match_price = match_price + range.bit1Price(p.is_rep[state]);
    if (match_byte == current_byte and !(next.pos_prev < cur and next.back_prev == 0)) {
        const short_rep_price = rep_match_price + c.shortRepPrice(state, pos_state);
        if (short_rep_price <= next.price) {
            next.price = short_rep_price;
            next.pos_prev = cur;
            makeShortRep(next);
            next_is_literal = true;
        }
    }
    if (avail_full < 2) return len_end;
    const avail = @min(avail_full, nice_len);
    if (!next_is_literal and match_byte != current_byte) {
        // A literal, then a rep0.
        const back = at - reps[0] - 1;
        const limit = @min(avail_full, nice_len + 1);
        const len_test = lengthIn(b, back, at, 1, limit) - 1;
        if (len_test >= 2) {
            const state_2 = decode.afterLiteral(state);
            const pos_state_next = c.posState(position + 1);
            const next_rep_match_price = cur_and_1_price + range.bit1Price(p.is_match[state_2][pos_state_next]) + range.bit1Price(p.is_rep[state_2]);
            const offset = cur + 1 + len_test;
            extend(c, &len_end, offset);
            const total = next_rep_match_price + c.repPrice(0, len_test, state_2, pos_state_next);
            if (total < c.opts[offset].price) {
                c.opts[offset] = reached(c.opts[offset], total, cur + 1, 0);
                c.opts[offset].prev_1_is_literal = true;
                c.opts[offset].prev_2 = false;
            }
        }
    }
    const start_len = repeats(c, b, at, reps, state, rep_match_price, position, cur, &len_end, nice_len, avail, avail_full);
    matches(c, b, at, state, match_price, position, cur, &len_end, start_len, nice_len, avail, avail_full);
    return len_end;
}

/// The repeated matches from `cur`, each also followed by a literal and a
/// rep0. The shortest new match worth pricing after them.
fn repeats(c: *Coder, b: []const u8, at: usize, reps: *const [reps_len]u32, state: State, rep_match_price: u32, position: u64, cur: u32, len_end: *u32, nice_len: u32, avail: u32, avail_full: u32) u32 {
    const p = &c.probs;
    const pos_state = c.posState(position);
    var start_len: u32 = 2;
    for (0..reps_len) |ri| {
        const back = at - reps[ri] - 1;
        if (!pair(b, back, at)) continue;
        const len_test = lengthIn(b, back, at, 2, avail);
        extend(c, len_end, cur + len_test);
        const price = rep_match_price + c.pureRepPrice(@intCast(ri), state, pos_state);
        var len = len_test;
        while (len >= 2) : (len -= 1) {
            const total = price + c.rep_len.price(len, pos_state);
            if (total < c.opts[cur + len].price) c.opts[cur + len] = reached(c.opts[cur + len], total, cur, @intCast(ri));
        }
        if (ri == 0) start_len = len_test + 1;
        // The repeat, a literal, then a rep0.
        var len_test_2 = len_test + 1;
        const limit = @min(avail_full, len_test_2 + nice_len);
        if (len_test_2 < limit) len_test_2 = lengthIn(b, back, at, len_test_2, limit);
        len_test_2 -= len_test + 1;
        if (len_test_2 >= 2) {
            var state_2 = decode.afterRep(state);
            var pos_state_next = c.posState(position + len_test);
            const cur_and_len_literal_price = price + c.rep_len.price(len_test, pos_state) + range.bit0Price(p.is_match[state_2][pos_state_next]) + c.literalPrice(position + len_test, b[at + len_test - 1], true, b[back + len_test], b[at + len_test]);
            state_2 = decode.afterLiteral(state_2);
            pos_state_next = c.posState(position + len_test + 1);
            const next_rep_match_price = cur_and_len_literal_price + range.bit1Price(p.is_match[state_2][pos_state_next]) + range.bit1Price(p.is_rep[state_2]);
            const offset = cur + len_test + 1 + len_test_2;
            extend(c, len_end, offset);
            const total = next_rep_match_price + c.repPrice(0, len_test_2, state_2, pos_state_next);
            reachedTwice(c, offset, total, cur + len_test + 1, cur, @intCast(ri));
        }
    }
    return start_len;
}

/// The new matches from `cur` from `start_len` on, the longest of each
/// distance also followed by a literal and a rep0.
fn matches(c: *Coder, b: []const u8, at: usize, state: State, match_price: u32, position: u64, cur: u32, len_end: *u32, start_len: u32, nice_len: u32, avail: u32, avail_full: u32) void {
    const p = &c.probs;
    const pos_state = c.posState(position);
    var new_len = c.longest;
    var count = c.matches_count;
    if (new_len > avail) {
        new_len = avail;
        count = 0;
        while (new_len > c.matches[count].len) count += 1;
        c.matches[count].len = new_len;
        count += 1;
    }
    if (new_len < start_len) return;
    const normal_match_price = match_price + range.bit0Price(p.is_rep[state]);
    extend(c, len_end, cur + new_len);
    var i: u32 = 0;
    while (start_len > c.matches[i].len) i += 1;
    var len_test = start_len;
    while (true) : (len_test += 1) {
        const cur_back = c.matches[i].dist;
        const total = normal_match_price + c.distLenPrice(cur_back, len_test, pos_state);
        if (total < c.opts[cur + len_test].price) c.opts[cur + len_test] = reached(c.opts[cur + len_test], total, cur, cur_back + reps_len);
        if (len_test != c.matches[i].len) continue;
        // The match, a literal, then a rep0.
        const back = at - cur_back - 1;
        var len_test_2 = len_test + 1;
        const limit = @min(avail_full, len_test_2 + nice_len);
        if (len_test_2 < limit) len_test_2 = lengthIn(b, back, at, len_test_2, limit);
        len_test_2 -= len_test + 1;
        if (len_test_2 >= 2) {
            var state_2 = decode.afterMatch(state);
            var pos_state_next = c.posState(position + len_test);
            const cur_and_len_literal_price = total + range.bit0Price(p.is_match[state_2][pos_state_next]) + c.literalPrice(position + len_test, b[at + len_test - 1], true, b[back + len_test], b[at + len_test]);
            state_2 = decode.afterLiteral(state_2);
            pos_state_next = c.posState(position + len_test + 1);
            const next_rep_match_price = cur_and_len_literal_price + range.bit1Price(p.is_match[state_2][pos_state_next]) + range.bit1Price(p.is_rep[state_2]);
            const offset = cur + len_test + 1 + len_test_2;
            extend(c, len_end, offset);
            const total_2 = next_rep_match_price + c.repPrice(0, len_test_2, state_2, pos_state_next);
            reachedTwice(c, offset, total_2, cur + len_test + 1, cur, cur_back + reps_len);
        }
        i += 1;
        if (i == count) break;
    }
}

/// The cheapest path to `cur`, linked forward from 0; its first symbol.
fn backward(c: *Coder, cur_in: u32) Symbol {
    var cur = cur_in;
    c.opts_end = cur;
    var pos_mem = c.opts[cur].pos_prev;
    var back_mem = c.opts[cur].back_prev;
    while (true) {
        if (c.opts[cur].prev_1_is_literal) {
            makeLiteral(&c.opts[pos_mem]);
            c.opts[pos_mem].pos_prev = pos_mem - 1;
            if (c.opts[cur].prev_2) {
                c.opts[pos_mem - 1].prev_1_is_literal = false;
                c.opts[pos_mem - 1].pos_prev = c.opts[cur].pos_prev_2;
                c.opts[pos_mem - 1].back_prev = c.opts[cur].back_prev_2;
            }
        }
        const pos_prev = pos_mem;
        const back_cur = back_mem;
        back_mem = c.opts[pos_prev].back_prev;
        pos_mem = c.opts[pos_prev].pos_prev;
        c.opts[pos_prev].back_prev = back_cur;
        c.opts[pos_prev].pos_prev = cur;
        cur = pos_prev;
        if (cur == 0) break;
    }
    c.opts_current = c.opts[0].pos_prev;
    return .{ .len = c.opts[0].pos_prev, .back = c.opts[0].back_prev };
}

/// Whether a match one shorter at `small` beats one at `big`: far nearer.
inline fn changePair(small: u32, big: u32) bool {
    return big >> 7 > small;
}

/// The fast parser's next symbol.
pub fn fast(c: *Coder, f: anytype) Symbol {
    const nice_len = f.nice_len;
    var len_main: u32 = undefined;
    var count: u32 = undefined;
    if (f.read_ahead == 0) {
        len_main = f.find(&c.matches, &count);
    } else {
        len_main = c.longest;
        count = c.matches_count;
    }
    const b = f.buf;
    const at = f.read_pos - 1;
    const buf_avail: u32 = @intCast(@min(f.avail() + 1, match_len_max));
    if (buf_avail < 2) return literal1();
    var rep_len: u32 = 0;
    var rep_index: u32 = 0;
    for (0..reps_len) |i| {
        const back = at - c.reps[i] - 1;
        if (!pair(b, back, at)) continue;
        const len = lengthIn(b, back, at, 2, buf_avail);
        if (len >= nice_len) {
            f.skip(len - 1);
            return .{ .back = @intCast(i), .len = len };
        }
        if (len > rep_len) {
            rep_index = @intCast(i);
            rep_len = len;
        }
    }
    if (len_main >= nice_len) {
        f.skip(len_main - 1);
        return .{ .back = c.matches[count - 1].dist + reps_len, .len = len_main };
    }
    var back_main: u32 = 0;
    if (len_main >= 2) {
        back_main = c.matches[count - 1].dist;
        while (count > 1 and len_main == c.matches[count - 2].len + 1) {
            if (!changePair(c.matches[count - 2].dist, back_main)) break;
            count -= 1;
            len_main = c.matches[count - 1].len;
            back_main = c.matches[count - 1].dist;
        }
        if (len_main == 2 and back_main >= 0x80) len_main = 1;
    }
    if (rep_len >= 2) {
        if (rep_len + 1 >= len_main or (rep_len + 2 >= len_main and back_main > 1 << 9) or (rep_len + 3 >= len_main and back_main > 1 << 15)) {
            f.skip(rep_len - 1);
            return .{ .back = rep_index, .len = rep_len };
        }
    }
    if (len_main < 2 or buf_avail <= 2) return literal1();
    // A byte ahead: a longer or nearer match there makes this a literal.
    c.longest = f.find(&c.matches, &c.matches_count);
    if (c.longest >= 2) {
        const new_dist = c.matches[c.matches_count - 1].dist;
        if ((c.longest >= len_main and new_dist < back_main) or
            (c.longest == len_main + 1 and !changePair(back_main, new_dist)) or
            c.longest > len_main + 1 or
            (c.longest + 1 >= len_main and len_main >= 3 and changePair(new_dist, back_main)))
            return literal1();
    }
    const limit = @max(2, len_main - 1);
    for (0..reps_len) |i| {
        const back = at + 1 - c.reps[i] - 1;
        if (std.mem.eql(u8, b[at + 1 ..][0..limit], b[back..][0..limit])) return literal1();
    }
    f.skip(len_main - 2);
    return .{ .back = back_main + reps_len, .len = len_main };
}
