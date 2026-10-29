//! The LZMA engine: literals, matches and repeated matches decoded through
//! the range decoder into a window, with liblzma 5.8.4's checks in its
//! order, so a stream is refused where and why liblzma refuses it.
//!
//! The window is generic: the whole-buffer decoders write straight into
//! the caller's output (`Linear`), the resumable ones into a ring of the
//! dictionary's size (`Ring`). A symbol runs unchecked while the input
//! holds `range.symbol_max` bytes and the window room for the longest
//! match; past either it runs careful: a symbol cut short by the input is
//! undone whole, and a match cut short by the output waits in `pending`.

const std = @import("std");
const aegis = @import("aegis");
const range = @import("range.zig");
const Diagnostic = @import("Diagnostic.zig");

const Prob = range.Prob;
const Log = range.Log;

pub const Error = error{
    /// The data breaks the format as liblzma reads it.
    InvalidStream,
};

/// lc, lp and pb: the literal context and position bits and the position
/// bits of everything else; liblzma takes lc + lp up to 4.
pub const Properties = struct {
    lc: u4 = 3,
    lp: u3 = 0,
    pb: u3 = 2,

    /// The properties byte, `(pb * 5 + lp) * 9 + lc`; null where it is
    /// past 224 or lc + lp past 4.
    pub fn parse(byte: u8) ?Properties {
        if (byte > (4 * 5 + 4) * 9 + 8) return null;
        const pb = byte / 45;
        const lp = (byte % 45) / 9;
        const lc = byte % 9;
        if (lc + lp > 4) return null;
        return .{ .lc = @intCast(lc), .lp = @intCast(lp), .pb = @intCast(pb) };
    }

    pub fn encode(p: Properties) u8 {
        return (@as(u8, p.pb) * 5 + p.lp) * 9 + p.lc;
    }
};

pub const states = 12;
pub const pos_states_max = 16;
pub const len_low = 8;
pub const len_mid = 8;
pub const len_high = 256;
pub const match_len_min = 2;
/// The longest match.
pub const match_len_max = match_len_min + len_low + len_mid + len_high - 1;
pub const dist_states = 4;
pub const dist_slots = 64;
pub const dist_model_end = 14;
pub const full_distances = 128;
pub const align_bits = 4;
/// A literal's 0x300 probabilities, at most 16 of them (lc + lp ≤ 4).
pub const literal_coders = 1 << 4;

pub const LenCoder = struct {
    choice: Prob = range.prob_init,
    choice2: Prob = range.prob_init,
    low: [pos_states_max][len_low]Prob = @splat(@splat(range.prob_init)),
    mid: [pos_states_max][len_mid]Prob = @splat(@splat(range.prob_init)),
    high: [len_high]Prob = @splat(range.prob_init),

    /// A match length less 2.
    inline fn decode(l: *LenCoder, d: *range.Decoder, pos_state: u4, comptime careful: bool, log: *Log) range.NeedInput!u32 {
        if (try d.bit(&l.choice, careful, log) == 0) return d.tree(&l.low[pos_state], 3, careful, log);
        if (try d.bit(&l.choice2, careful, log) == 0) return len_low + try d.tree(&l.mid[pos_state], 3, careful, log);
        return len_low + len_mid + try d.tree(&l.high, 8, careful, log);
    }
};

/// Every probability of a stream, reset together.
pub const Probs = struct {
    literal: [literal_coders][0x300]Prob = @splat(@splat(range.prob_init)),
    is_match: [states][pos_states_max]Prob = @splat(@splat(range.prob_init)),
    is_rep: [states]Prob = @splat(range.prob_init),
    is_rep0: [states]Prob = @splat(range.prob_init),
    is_rep1: [states]Prob = @splat(range.prob_init),
    is_rep2: [states]Prob = @splat(range.prob_init),
    is_rep0_long: [states][pos_states_max]Prob = @splat(@splat(range.prob_init)),
    dist_slot: [dist_states][dist_slots]Prob = @splat(@splat(range.prob_init)),
    /// The footers' probabilities from index 1, as the reverse trees read
    /// them (`dist - slot + m`, liblzma's `pos_special + dist - slot - 1`).
    dist_special: [full_distances - dist_model_end + 1]Prob = @splat(range.prob_init),
    dist_align: [1 << align_bits]Prob = @splat(range.prob_init),
    match_len: LenCoder = .{},
    rep_len: LenCoder = .{},
};

/// The window as the whole-buffer decoders keep it: the caller's output.
/// `start` is where the dictionary was last reset; distances reach back to
/// it, and to `dict_size` at most.
pub const Linear = struct {
    buf: []u8,
    pos: usize,
    start: usize,
    /// The dictionary as liblzma keeps it (`dictionary`).
    dict_size: u64,
    /// Where output stops: the known size's end or the buffer's.
    limit: usize,

    pub inline fn full(w: *const Linear) u64 {
        return @min(w.pos - w.start, w.dict_size);
    }
    /// Bytes since the dictionary's reset: the position the contexts see.
    pub inline fn at(w: *const Linear) usize {
        return w.pos - w.start;
    }
    pub inline fn room(w: *const Linear) usize {
        return w.limit - w.pos;
    }
    /// The byte `dist + 1` back.
    pub inline fn back(w: *const Linear, dist: u32) u8 {
        return w.buf[w.pos - dist - 1];
    }
    pub inline fn put(w: *Linear, b: u8) void {
        w.buf[w.pos] = b;
        w.pos += 1;
    }
    /// `len` bytes from `dist + 1` back; `len` ≤ `room()`.
    pub inline fn copy(w: *Linear, dist: u32, len: usize) void {
        const from = w.pos - dist - 1;
        const to = w.pos;
        if (dist + 1 >= len) {
            @memcpy(w.buf[to..][0..len], w.buf[from..][0..len]);
        } else for (0..len) |i| w.buf[to + i] = w.buf[from + i];
        w.pos += len;
    }
};

/// The window as the resumable decoders keep it: a ring of at least the
/// dictionary, the caller's memory. `total` counts the bytes since the
/// dictionary's reset; `limit` the bytes the current run may write.
pub const Ring = struct {
    buf: []u8,
    pos: usize = 0,
    total: u64 = 0,
    dict_size: u64,
    limit: usize = 0,

    pub inline fn full(w: *const Ring) u64 {
        return @min(w.total, w.dict_size);
    }
    pub inline fn at(w: *const Ring) usize {
        return @truncate(w.total);
    }
    pub inline fn room(w: *const Ring) usize {
        return w.limit;
    }
    pub inline fn back(w: *const Ring, dist: u32) u8 {
        const i = if (w.pos > dist) w.pos - dist - 1 else w.pos + w.buf.len - dist - 1;
        return w.buf[i];
    }
    pub inline fn put(w: *Ring, b: u8) void {
        w.buf[w.pos] = b;
        w.pos += 1;
        if (w.pos == w.buf.len) w.pos = 0;
        w.total += 1;
        w.limit -= 1;
    }
    /// `len` bytes from `dist + 1` back; `len` ≤ `room()`.
    pub inline fn copy(w: *Ring, dist: u32, len: usize) void {
        var from = if (w.pos > dist) w.pos - dist - 1 else w.pos + w.buf.len - dist - 1;
        if (dist + 1 >= len and from + len <= w.buf.len and w.pos + len <= w.buf.len) {
            @memcpy(w.buf[w.pos..][0..len], w.buf[from..][0..len]);
            w.pos += len;
            if (w.pos == w.buf.len) w.pos = 0;
        } else for (0..len) |_| {
            w.buf[w.pos] = w.buf[from];
            w.pos += 1;
            if (w.pos == w.buf.len) w.pos = 0;
            from += 1;
            if (from == w.buf.len) from = 0;
        }
        w.total += len;
        w.limit -= len;
    }
    /// A reset dictionary: nothing to reach back to.
    pub fn reset(w: *Ring) void {
        w.total = 0;
    }
    /// The last `n` bytes written, in up to two pieces.
    pub fn last(w: *const Ring, n: usize) [2][]const u8 {
        if (n <= w.pos) return .{ w.buf[w.pos - n .. w.pos], &.{} };
        return .{ w.buf[w.buf.len - (n - w.pos) ..], w.buf[0..w.pos] };
    }
};

/// The dictionary liblzma holds for a declared size: at least 4 KiB,
/// rounded up to 16 bytes. Distances reach back this far.
pub fn dictionary(declared: u64) u64 {
    return std.mem.alignForward(u64, @max(declared, 4096), 16);
}

/// The dictionary an LZMA2 property byte names (40 is 4 GiB less one);
/// null past 40.
pub fn lzma2Dictionary(byte: u8) ?u32 {
    if (byte > 40) return null;
    if (byte == 40) return 0xffff_ffff;
    return @as(u32, 2 | (byte & 1)) << @intCast(byte / 2 + 11);
}

/// Where a symbol leaves the stream. `literal`, `match`, `rep` and
/// `short_rep` are the state's transitions.
pub const State = u4;

pub inline fn afterLiteral(s: State) State {
    return if (s < 4) 0 else if (s < 10) s - 3 else s - 6;
}
pub inline fn afterMatch(s: State) State {
    return if (s < 7) 7 else 10;
}
pub inline fn afterRep(s: State) State {
    return if (s < 7) 8 else 11;
}
pub inline fn afterShortRep(s: State) State {
    return if (s < 7) 9 else 11;
}

/// Where a stream is between calls.
pub const Coder = struct {
    probs: Probs = .{},
    props: Properties = .{},
    state: State = 0,
    reps: [4]u32 = @splat(0),
    /// A match the output cut short: bytes left to copy from `reps[0]`.
    pending: u32 = 0,
    /// The size left where it is known (LZMA1 with a size, an LZMA2
    /// chunk); null where the end marker ends the stream.
    left: ?u64 = null,
    /// Whether an end marker may end a stream of known size.
    allow_marker: bool = false,
    /// The known size is reached and the marker must follow.
    marker_next: bool = false,
    /// Where the refused symbol starts, and why.
    fail_at: u64 = 0,
    reason: Diagnostic.Reason = .truncated,

    /// Probabilities and state reset, the properties set (a new stream, or
    /// an LZMA2 chunk's state reset).
    pub fn reset(c: *Coder, props: Properties) void {
        c.probs = .{};
        c.props = props;
        c.state = 0;
        c.reps = @splat(0);
        c.pending = 0;
        c.marker_next = false;
    }

    fn fail(c: *Coder, at: u64, reason: Diagnostic.Reason) Error {
        c.fail_at = at;
        c.reason = reason;
        return error.InvalidStream;
    }
};

pub const Status = enum {
    /// The stream ended: its known size with the coder finished, or the
    /// end marker.
    end,
    /// The window's limit is reached short of the stream's end.
    output_full,
};

/// Decode from `d` into `w` until the stream ends, the window's limit is
/// reached, or the input runs out (`NeedInput`, with `d` at the start of
/// the symbol it could not finish). `base` is the input's offset of
/// `d.in[0]`, for the diagnostic.
pub fn run(c: *Coder, d: *range.Decoder, w: anytype, base: u64) (Error || range.NeedInput)!Status {
    if (c.pending != 0) {
        const n: u32 = @intCast(@min(c.pending, w.room()));
        w.copy(c.reps[0], n);
        c.pending -= n;
        c.left = if (c.left) |l| taken(l, n) else null;
        if (c.pending != 0) return .output_full;
    }
    var log: Log = .{};
    while (true) {
        if (c.left) |l| if (l == 0 and !c.marker_next) {
            // The known size is reached: the stream ends where the coder
            // can, after the byte it may need; else only a marker may
            // follow.
            const m = d.mark();
            d.normalize(true) catch |err| {
                d.restore(m);
                return err;
            };
            if (d.finished()) return .end;
            if (!c.allow_marker) return c.fail(base + d.pos, .size_without_end);
            c.marker_next = true;
        };
        // The marker writes nothing: it needs no room.
        if (w.room() == 0 and !c.marker_next) return .output_full;
        const fast = d.roomy() and w.room() >= match_len_max;
        if (fast) {
            if (try symbol(c, d, w, base, false, &log)) return .end;
        } else {
            const m = d.mark();
            const saved = .{ c.state, c.reps };
            log.len = 0;
            const ended = symbol(c, d, w, base, true, &log) catch |err| switch (err) {
                error.NeedInput => {
                    log.undo();
                    d.restore(m);
                    c.state, c.reps = saved;
                    return error.NeedInput;
                },
                else => |e| return e,
            };
            if (ended) return .end;
            if (c.pending != 0) return .output_full;
        }
    }
}

/// One symbol: a literal, a match or a repeated match into `w`. True at
/// the end marker.
inline fn symbol(c: *Coder, d: *range.Decoder, w: anytype, base: u64, comptime careful: bool, log: *Log) (Error || range.NeedInput)!bool {
    const p = &c.probs;
    const at = w.at();
    // pb and lc + lp are at most 4: both are under 16.
    const pos_state: u4 = @truncate(at & ~(~@as(usize, 0) << c.props.pb));
    const sym_at = base + d.pos;
    if (try d.bit(&p.is_match[c.state][pos_state], careful, log) == 0) {
        if (c.marker_next) return c.fail(sym_at, .size_without_end);
        const prev: u32 = if (w.full() == 0) 0 else w.back(0);
        const lp_mask = ~(~@as(usize, 0) << c.props.lp);
        const coder: u4 = @intCast(((at & lp_mask) << c.props.lc) | ((prev << c.props.lc) >> 8));
        const probs = &p.literal[coder];
        var v: u32 = 1;
        if (c.state >= 7) {
            // After a match: the byte at rep0 steers the first bits while
            // they agree.
            var match_byte: u32 = w.back(c.reps[0]);
            var offset: u32 = 0x100;
            while (v < 0x100) {
                match_byte <<= 1;
                const match_bit = match_byte & offset;
                const b = try d.bit(&probs[offset + match_bit + v], careful, log);
                v = (v << 1) | b;
                offset &= if (b == 1) match_bit else ~match_bit;
            }
        } else {
            while (v < 0x100) v = (v << 1) | try d.bit(&probs[v], careful, log);
        }
        w.put(@truncate(v));
        c.state = afterLiteral(c.state);
        if (c.left) |l| c.left = taken(l, 1);
        return false;
    }
    var len: u32 = undefined;
    if (try d.bit(&p.is_rep[c.state], careful, log) == 0) {
        // A match: its length, then its distance.
        len = try p.match_len.decode(d, pos_state, careful, log);
        const dist_state = @min(len, dist_states - 1);
        const slot = try d.tree(&p.dist_slot[dist_state], 6, careful, log);
        var dist: u32 = slot;
        if (slot >= 4) {
            const footer: u5 = @intCast((slot >> 1) - 1);
            dist = (2 | (slot & 1)) << footer;
            // The footer's bits are below `dist`'s two, each field its own.
            if (slot < dist_model_end) {
                // A slot's probabilities start at its base less the slot.
                aegis.assert.invariant(slot <= dist and dist - slot < p.dist_special.len, "slot <= dist and dist - slot < p.dist_special.len");
                dist |= try d.reverse(p.dist_special[dist - slot ..], footer, careful, log);
            } else {
                dist |= try d.direct(footer - align_bits, careful) << align_bits;
                dist |= try d.reverse(&p.dist_align, align_bits, careful, log);
            }
        }
        if (dist == 0xffff_ffff) {
            // The end marker, where one may be: the coder must be done.
            if (c.left != null and !c.marker_next) return c.fail(sym_at, .marker_not_allowed);
            try d.normalize(careful);
            if (!d.finished()) return c.fail(base + d.pos, .end_not_finished);
            return true;
        }
        if (c.marker_next) return c.fail(sym_at, .size_without_end);
        if (dist >= w.full()) return c.fail(sym_at, .distance);
        // Copied first: an aggregate assigned in place reads what it writes.
        const reps = c.reps;
        c.reps = .{ dist, reps[0], reps[1], reps[2] };
        c.state = afterMatch(c.state);
    } else {
        if (c.marker_next) return c.fail(sym_at, .size_without_end);
        if (w.full() == 0) return c.fail(sym_at, .distance);
        if (try d.bit(&p.is_rep0[c.state], careful, log) == 0) {
            if (try d.bit(&p.is_rep0_long[c.state][pos_state], careful, log) == 0) {
                // A short rep: one byte from rep0.
                c.state = afterShortRep(c.state);
                w.put(w.back(c.reps[0]));
                if (c.left) |l| c.left = taken(l, 1);
                return false;
            }
        } else {
            var dist: u32 = undefined;
            if (try d.bit(&p.is_rep1[c.state], careful, log) == 0) {
                dist = c.reps[1];
            } else {
                if (try d.bit(&p.is_rep2[c.state], careful, log) == 0) {
                    dist = c.reps[2];
                } else {
                    dist = c.reps[3];
                    c.reps[3] = c.reps[2];
                }
                c.reps[2] = c.reps[1];
            }
            c.reps[1] = c.reps[0];
            c.reps[0] = dist;
        }
        len = try p.rep_len.decode(d, pos_state, careful, log);
        c.state = afterRep(c.state);
    }
    len += match_len_min;
    // The match, as far as the window's limit allows; where the limit is
    // the known size, a match past it is refused.
    const n: u32 = @intCast(@min(len, w.room()));
    if (c.left) |l| if (len > l) return c.fail(sym_at, .past_size);
    w.copy(c.reps[0], n);
    c.pending = len - n;
    if (c.left) |l| c.left = taken(l, n);
    return false;
}

/// The known size left after `n` more bytes, which it was checked to hold.
inline fn taken(left: u64, n: u32) u64 {
    aegis.assert.invariant(n <= left, "n <= left");
    return left - n;
}

test {
    _ = aegis;
}
