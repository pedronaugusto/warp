//! The LZMA encoder's engine: the model the decoder reads (`decode.Probs`),
//! symbols coded into the range encoder, and the price tables the
//! optimal parser reads, kept as liblzma 5.8.4 keeps them: length prices
//! per position state refreshed after so many uses, distance and align
//! prices after so many matches.
//!
//! The parsers (`optimum.zig`) choose the symbols and code them from a
//! finder (`Finder.zig`).

const std = @import("std");
const range = @import("range.zig");
const decode = @import("decode.zig");

const Prob = range.Prob;
const State = decode.State;
pub const Properties = decode.Properties;
const pos_states_max = decode.pos_states_max;
const len_low = decode.len_low;
const len_mid = decode.len_mid;
const dist_states = decode.dist_states;
const dist_slots = decode.dist_slots;
const dist_model_end = decode.dist_model_end;
const full_distances = decode.full_distances;
const align_bits = decode.align_bits;
pub const match_len_min = decode.match_len_min;
pub const match_len_max = decode.match_len_max;
const len_symbols = decode.len_low + decode.len_mid + decode.len_high;
const align_size = 1 << align_bits;
const dist_model_start = 4;

/// The parser's lookahead, in positions: a path is chosen over at most
/// this many.
pub const opts_len = 1 << 12;
/// The most input one parser call reads ahead (liblzma's `LOOP_INPUT_MAX`).
pub const loop_input_max = opts_len + 1;
/// `back` for a literal; 0-3 are the repeated distances, 4 on a match's
/// distance plus 4.
pub const literal_back = std.math.maxInt(u32);
pub const reps_len = 4;

pub const Mode = enum {
    /// liblzma's fast parser: the longest match, or a repeated one nearly
    /// as long, with a byte of lookahead.
    fast,
    /// The price-based optimal parser.
    normal,
};

/// A match the finder gives: its length and distance less one.
pub const Pair = struct { len: u32, dist: u32 };

/// A symbol a parser chose: `back` as `literal_back` above, its length.
pub const Symbol = struct { back: u32, len: u32 };

/// A length coder's prices per position state, for lengths up to the
/// table's size, refreshed after `table_size` uses.
pub const LenPrices = struct {
    prices: [pos_states_max][len_symbols]u32 = undefined,
    table_size: u32 = 0,
    counters: [pos_states_max]u32 = @splat(0),

    fn update(lp: *LenPrices, l: *const decode.LenCoder, pos_state: u32) void {
        const size = lp.table_size;
        lp.counters[pos_state] = size;
        const a0 = range.bit0Price(l.choice);
        const a1 = range.bit1Price(l.choice);
        const b0 = a1 + range.bit0Price(l.choice2);
        const b1 = a1 + range.bit1Price(l.choice2);
        const prices = &lp.prices[pos_state];
        var i: u32 = 0;
        while (i < size and i < len_low) : (i += 1) prices[i] = a0 + range.treePrice(&l.low[pos_state], 3, i);
        while (i < size and i < len_low + len_mid) : (i += 1) prices[i] = b0 + range.treePrice(&l.mid[pos_state], 3, i - len_low);
        while (i < size) : (i += 1) prices[i] = b1 + range.treePrice(&l.high, 8, i - len_low - len_mid);
    }

    pub inline fn price(lp: *const LenPrices, len: u32, pos_state: u32) u32 {
        return lp.prices[pos_state][len - match_len_min];
    }
};

/// A position of the optimal parser's path: how it is best reached, from
/// where, and the state and distances there.
pub const Optimal = struct {
    state: State = 0,
    prev_1_is_literal: bool = false,
    prev_2: bool = false,
    pos_prev_2: u32 = 0,
    back_prev_2: u32 = 0,
    price: u32 = 0,
    pos_prev: u32 = 0,
    back_prev: u32 = 0,
    backs: [reps_len]u32 = @splat(0),
};

/// The distance slot of `dist`: its top two bits and their place.
pub inline fn distSlot(dist: u32) u32 {
    if (dist < 2) return dist;
    const n: u5 = @intCast(31 - @clz(dist));
    return (@as(u32, n) << 1) | ((dist >> (n - 1)) & 1);
}

pub inline fn distState(len: u32) u32 {
    return @min(len - match_len_min, dist_states - 1);
}

/// The coder's options as the parsers and price tables need them.
pub const Tuning = struct {
    mode: Mode,
    /// The finder's nice length: the parsers take a match this long as is.
    nice_len: u32,
    dictionary: u32,
};

pub const Coder = struct {
    probs: decode.Probs = .{},
    props: Properties = .{},
    state: State = 0,
    reps: [reps_len]u32 = @splat(0),
    rc: range.Encoder = .init(&.{}),
    fast: bool = false,
    match_len: LenPrices = .{},
    rep_len: LenPrices = .{},
    dist_slot_prices: [dist_states][dist_slots]u32 = undefined,
    dist_prices: [dist_states][full_distances]u32 = undefined,
    dist_table_size: u32 = 0,
    match_price_count: u32 = 0,
    align_prices: [align_size]u32 = undefined,
    align_price_count: u32 = 0,
    /// The chosen path's symbols not yet coded: from `opts_current` to
    /// `opts_end`.
    opts_end: u32 = 0,
    opts_current: u32 = 0,
    opts: [opts_len]Optimal = undefined,
    matches: [match_len_max + 1]Pair = undefined,
    matches_count: u32 = 0,
    /// The longest match at the position the parser read ahead to.
    longest: u32 = 0,
    /// Bytes coded since the stream began: the position the contexts see.
    position: u64 = 0,
    /// Whether the stream's first byte, coded unsearched, is out.
    started: bool = false,

    /// A coder for a new stream: `tuning` fixed for its life.
    pub fn init(c: *Coder, props: Properties, tuning: Tuning) void {
        c.fast = tuning.mode == .fast;
        if (!c.fast) {
            c.dist_table_size = 2 * std.math.log2_int_ceil(u32, @max(tuning.dictionary, 1));
            c.match_len.table_size = tuning.nice_len + 1 - match_len_min;
            c.rep_len.table_size = tuning.nice_len + 1 - match_len_min;
        }
        c.position = 0;
        c.started = false;
        c.reset(props);
    }

    /// Probabilities, state and distances reset: a new stream, or an LZMA2
    /// chunk's state reset.
    pub fn reset(c: *Coder, props: Properties) void {
        c.props = props;
        c.probs = .{};
        c.state = 0;
        c.reps = @splat(0);
        if (!c.fast) {
            for (0..@as(u32, 1) << c.props.pb) |ps| {
                c.match_len.update(&c.probs.match_len, @intCast(ps));
                c.rep_len.update(&c.probs.rep_len, @intCast(ps));
            }
        }
        // Large enough that the tables are filled before their first use.
        c.match_price_count = std.math.maxInt(u32) / 2;
        c.align_price_count = std.math.maxInt(u32) / 2;
        c.opts_end = 0;
        c.opts_current = 0;
    }

    pub inline fn posState(c: *const Coder, position: u64) u32 {
        return @as(u32, @truncate(position)) & ((@as(u32, 1) << c.props.pb) - 1);
    }

    /// The literal coder for a byte at `position` after `prev`.
    pub inline fn literalProbs(c: anytype, position: u64, prev: u8) switch (@TypeOf(c)) {
        *Coder => *[0x300]Prob,
        else => *const [0x300]Prob,
    } {
        // lc + lp is at most 4: the index is under 16.
        const lp_mask = ~(~@as(u32, 0) << c.props.lp);
        const at: u32 = @truncate(position);
        const index: u4 = @intCast(((at & lp_mask) << c.props.lc) | ((@as(u32, prev) << c.props.lc) >> 8));
        return &c.probs.literal[index];
    }

    // Prices.

    pub fn literalPrice(c: *const Coder, position: u64, prev: u8, matched: bool, match_byte: u8, byte: u8) u32 {
        const probs = c.literalProbs(position, prev);
        if (!matched) return range.treePrice(probs, 8, byte);
        var price: u32 = 0;
        var offset: u32 = 0x100;
        var sym: u32 = @as(u32, byte) | 0x100;
        var mb: u32 = match_byte;
        while (sym < 1 << 16) {
            mb <<= 1;
            const match_bit = mb & offset;
            price += range.bitPrice(probs[offset + match_bit + (sym >> 8)], (sym >> 7) & 1);
            sym <<= 1;
            offset &= ~(mb ^ sym);
        }
        return price;
    }

    pub inline fn shortRepPrice(c: *const Coder, state: State, pos_state: u32) u32 {
        return range.bit0Price(c.probs.is_rep0[state]) + range.bit0Price(c.probs.is_rep0_long[state][pos_state]);
    }

    pub inline fn pureRepPrice(c: *const Coder, rep: u32, state: State, pos_state: u32) u32 {
        const p = &c.probs;
        if (rep == 0) return range.bit0Price(p.is_rep0[state]) + range.bit1Price(p.is_rep0_long[state][pos_state]);
        var price = range.bit1Price(p.is_rep0[state]);
        if (rep == 1) {
            price += range.bit0Price(p.is_rep1[state]);
        } else {
            price += range.bit1Price(p.is_rep1[state]);
            price += range.bitPrice(p.is_rep2[state], rep - 2);
        }
        return price;
    }

    pub inline fn repPrice(c: *const Coder, rep: u32, len: u32, state: State, pos_state: u32) u32 {
        return c.rep_len.price(len, pos_state) + c.pureRepPrice(rep, state, pos_state);
    }

    pub inline fn distLenPrice(c: *const Coder, dist: u32, len: u32, pos_state: u32) u32 {
        const ds = distState(len);
        const price = if (dist < full_distances)
            c.dist_prices[ds][dist]
        else
            c.dist_slot_prices[ds][distSlot(dist)] + c.align_prices[dist & (align_size - 1)];
        return price + c.match_len.price(len, pos_state);
    }

    pub fn fillDistPrices(c: *Coder) void {
        for (0..dist_states) |ds| {
            const slot_prices = &c.dist_slot_prices[ds];
            for (0..c.dist_table_size) |slot| slot_prices[slot] = range.treePrice(&c.probs.dist_slot[ds], 6, @intCast(slot));
            var slot: u32 = dist_model_end;
            while (slot < c.dist_table_size) : (slot += 1) slot_prices[slot] += range.directPrice((slot >> 1) - 1 - align_bits);
            for (0..dist_model_start) |i| c.dist_prices[ds][i] = slot_prices[i];
        }
        var i: u32 = dist_model_start;
        while (i < full_distances) : (i += 1) {
            const slot = distSlot(i);
            const footer: u5 = @intCast((slot >> 1) - 1);
            const base = (2 | (slot & 1)) << footer;
            const price = range.reversePrice(c.probs.dist_special[base - slot ..], footer, i - base);
            for (0..dist_states) |ds| c.dist_prices[ds][i] = price + c.dist_slot_prices[ds][slot];
        }
        c.match_price_count = 0;
    }

    pub fn fillAlignPrices(c: *Coder) void {
        for (0..align_size) |i| c.align_prices[i] = range.reversePrice(&c.probs.dist_align, align_bits, @intCast(i));
        c.align_price_count = 0;
    }

    // Symbols.

    /// The stream's first byte: a literal with nothing before it, the
    /// finder past it unsearched.
    pub fn start(c: *Coder, f: anytype) void {
        f.skip(1);
        f.read_ahead = 0;
        c.rc.bit(&c.probs.is_match[0][0], 0);
        c.rc.tree(&c.probs.literal[0], 8, f.buf[f.read_pos - 1]);
        c.position += 1;
        c.started = true;
    }

    /// The symbol the parser chose, at the finder's coding position.
    pub fn symbol(c: *Coder, f: anytype, s: Symbol) void {
        const pos_state = c.posState(c.position);
        const p = &c.probs;
        if (s.back == literal_back) {
            c.rc.bit(&p.is_match[c.state][pos_state], 0);
            c.literal(f.buf, f.read_pos - f.read_ahead);
        } else {
            c.rc.bit(&p.is_match[c.state][pos_state], 1);
            if (s.back < reps_len) {
                c.rc.bit(&p.is_rep[c.state], 1);
                c.repMatch(pos_state, s.back, s.len);
            } else {
                c.rc.bit(&p.is_rep[c.state], 0);
                c.match(pos_state, s.back - reps_len, s.len);
            }
        }
        f.read_ahead -= s.len;
        c.position += s.len;
    }

    /// The end marker: a match at the largest distance.
    pub fn marker(c: *Coder) void {
        const pos_state = c.posState(c.position);
        c.rc.bit(&c.probs.is_match[c.state][pos_state], 1);
        c.rc.bit(&c.probs.is_rep[c.state], 0);
        c.match(pos_state, std.math.maxInt(u32), match_len_min);
    }

    fn literal(c: *Coder, buf: []const u8, at: usize) void {
        const byte = buf[at];
        const probs = c.literalProbs(c.position, buf[at - 1]);
        if (c.state < 7) {
            c.rc.tree(probs, 8, byte);
        } else {
            // After a match: the byte at rep0 steers the bits while they
            // agree.
            var mb: u32 = buf[at - c.reps[0] - 1];
            var offset: u32 = 0x100;
            var sym: u32 = @as(u32, byte) | 0x100;
            while (sym < 1 << 16) {
                mb <<= 1;
                const match_bit = mb & offset;
                c.rc.bit(&probs[offset + match_bit + (sym >> 8)], (sym >> 7) & 1);
                sym <<= 1;
                offset &= ~(mb ^ sym);
            }
        }
        c.state = decode.afterLiteral(c.state);
    }

    fn length(c: *Coder, comptime which: enum { match, rep }, pos_state: u32, len: u32) void {
        const l = if (which == .match) &c.probs.match_len else &c.probs.rep_len;
        const lp = if (which == .match) &c.match_len else &c.rep_len;
        // Prices refreshed from the probabilities before this length's
        // bits: liblzma queues a symbol's bits and refreshes here, before
        // its coder applies them.
        if (!c.fast) {
            lp.counters[pos_state] -= 1;
            if (lp.counters[pos_state] == 0) lp.update(l, pos_state);
        }
        var v = len - match_len_min;
        if (v < len_low) {
            c.rc.bit(&l.choice, 0);
            c.rc.tree(&l.low[pos_state], 3, v);
        } else {
            c.rc.bit(&l.choice, 1);
            v -= len_low;
            if (v < len_mid) {
                c.rc.bit(&l.choice2, 0);
                c.rc.tree(&l.mid[pos_state], 3, v);
            } else {
                c.rc.bit(&l.choice2, 1);
                c.rc.tree(&l.high, 8, v - len_mid);
            }
        }
    }

    fn match(c: *Coder, pos_state: u32, dist: u32, len: u32) void {
        c.state = decode.afterMatch(c.state);
        c.length(.match, pos_state, len);
        const slot = distSlot(dist);
        c.rc.tree(&c.probs.dist_slot[distState(len)], 6, slot);
        if (slot >= dist_model_start) {
            const footer: u5 = @intCast((slot >> 1) - 1);
            const base = (2 | (slot & 1)) << footer;
            const reduced = dist - base;
            if (slot < dist_model_end) {
                c.rc.reverse(c.probs.dist_special[base - slot ..], footer, reduced);
            } else {
                c.rc.direct(reduced >> align_bits, footer - align_bits);
                c.rc.reverse(&c.probs.dist_align, align_bits, reduced & (align_size - 1));
                c.align_price_count += 1;
            }
        }
        const reps = c.reps;
        c.reps = .{ dist, reps[0], reps[1], reps[2] };
        c.match_price_count += 1;
    }

    fn repMatch(c: *Coder, pos_state: u32, rep: u32, len: u32) void {
        const p = &c.probs;
        if (rep == 0) {
            c.rc.bit(&p.is_rep0[c.state], 0);
            c.rc.bit(&p.is_rep0_long[c.state][pos_state], @intFromBool(len != 1));
        } else {
            const dist = c.reps[rep];
            c.rc.bit(&p.is_rep0[c.state], 1);
            if (rep == 1) {
                c.rc.bit(&p.is_rep1[c.state], 0);
            } else {
                c.rc.bit(&p.is_rep1[c.state], 1);
                c.rc.bit(&p.is_rep2[c.state], rep - 2);
                if (rep == 3) c.reps[3] = c.reps[2];
                c.reps[2] = c.reps[1];
            }
            c.reps[1] = c.reps[0];
            c.reps[0] = dist;
        }
        if (len == 1) {
            c.state = decode.afterShortRep(c.state);
        } else {
            c.length(.rep, pos_state, len);
            c.state = decode.afterRep(c.state);
        }
    }
};

test "distance slots, as liblzma's table gives them" {
    try std.testing.expectEqual(@as(u32, 0), distSlot(0));
    try std.testing.expectEqual(@as(u32, 3), distSlot(3));
    try std.testing.expectEqual(@as(u32, 4), distSlot(4));
    try std.testing.expectEqual(@as(u32, 5), distSlot(6));
    try std.testing.expectEqual(@as(u32, 13), distSlot(127));
    try std.testing.expectEqual(@as(u32, 14), distSlot(128));
    try std.testing.expectEqual(@as(u32, 63), distSlot(0xffff_ffff));
}
