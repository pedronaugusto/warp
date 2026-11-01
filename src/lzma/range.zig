//! LZMA's range coder: a 32-bit range, a byte moved whenever the range
//! falls below 2^24, and 11-bit adaptive probabilities.
//!
//! The decoder reads the input in place. A symbol reads at most
//! `symbol_max` bytes, so the decoder runs unchecked while that many
//! remain; past them it is careful: a byte it lacks is `NeedInput`, and
//! the probabilities it changed are logged so the symbol can be undone.
//!
//! The encoder writes the caller's output in place, as liblzma's writes
//! its bytes (a carry held back over a run of 0xff), and counts what does
//! not fit, so a caller learns the size a stream needs. Prices are
//! liblzma's: a bit's cost in sixteenths of a bit, from a table of 128.

const std = @import("std");

pub const NeedInput = error{NeedInput};

/// The most input one symbol reads (LZMA SDK's `LZMA_REQUIRED_INPUT_MAX`).
pub const symbol_max = 20;

pub const Prob = u16;
/// A new probability: one half.
pub const prob_init: Prob = 1 << (prob_bits - 1);
const prob_bits = 11;
const move_bits = 5;
const top: u32 = 1 << 24;

/// The probabilities a careful symbol changed, to undo it. A symbol
/// changes fewer than 48: the match bits, a length (up to 10), a
/// distance slot (6), its footer (up to 26, of which 4 adaptive) and a
/// literal (up to 16).
pub const Log = struct {
    entries: [48]struct { p: *Prob, old: Prob } = undefined,
    len: u32 = 0,

    fn note(l: *Log, p: *Prob) void {
        l.entries[l.len] = .{ .p = p, .old = p.* };
        l.len += 1;
    }

    /// Every logged probability back, latest first.
    pub fn undo(l: *Log) void {
        while (l.len > 0) {
            l.len -= 1;
            l.entries[l.len].p.* = l.entries[l.len].old;
        }
    }
};

pub const Decoder = struct {
    in: []const u8,
    pos: usize,
    range: u32 = 0xffff_ffff,
    code: u32 = 0,

    pub const Mark = struct { pos: usize, range: u32, code: u32 };

    /// The coder's first five bytes: a zero, then the code. False where
    /// the first is not zero; `NeedInput` where fewer than five remain.
    pub fn start(d: *Decoder) NeedInput!bool {
        if (d.in.len - d.pos < 5) return error.NeedInput;
        if (d.in[d.pos] != 0) return false;
        d.code = std.mem.readInt(u32, d.in[d.pos + 1 ..][0..4], .big);
        d.range = 0xffff_ffff;
        d.pos += 5;
        return true;
    }

    pub fn mark(d: *const Decoder) Mark {
        return .{ .pos = d.pos, .range = d.range, .code = d.code };
    }

    pub fn restore(d: *Decoder, m: Mark) void {
        d.pos = m.pos;
        d.range = m.range;
        d.code = m.code;
    }

    /// Whether a symbol can run unchecked.
    pub inline fn roomy(d: *const Decoder) bool {
        return d.in.len - d.pos >= symbol_max;
    }

    /// Where the stream may end: the code at zero.
    pub inline fn finished(d: *const Decoder) bool {
        return d.code == 0;
    }

    pub inline fn normalize(d: *Decoder, comptime careful: bool) NeedInput!void {
        if (d.range < top) {
            if (careful and d.pos == d.in.len) return error.NeedInput;
            d.range <<= 8;
            d.code = (d.code << 8) | d.in[d.pos];
            d.pos += 1;
        }
    }

    /// One bit under probability `p`, `p` moved toward it.
    pub inline fn bit(d: *Decoder, p: *Prob, comptime careful: bool, log: *Log) NeedInput!u1 {
        try d.normalize(careful);
        if (careful) log.note(p);
        const bound = (d.range >> prob_bits) * p.*;
        if (d.code < bound) {
            d.range = bound;
            p.* += ((1 << prob_bits) - p.*) >> move_bits;
            return 0;
        }
        d.range -= bound;
        d.code -= bound;
        p.* -= p.* >> move_bits;
        return 1;
    }

    /// `n` bits, most significant first, through a tree of `2^n` probabilities.
    pub inline fn tree(d: *Decoder, probs: []Prob, comptime n: u5, comptime careful: bool, log: *Log) NeedInput!u32 {
        var m: u32 = 1;
        inline for (0..n) |_| m = (m << 1) | try d.bit(&probs[m], careful, log);
        return m - (1 << n);
    }

    /// `n` bits, least significant first, through a tree.
    pub inline fn reverse(d: *Decoder, probs: []Prob, n: u5, comptime careful: bool, log: *Log) NeedInput!u32 {
        var m: u32 = 1;
        var v: u32 = 0;
        for (0..n) |i| {
            const b = try d.bit(&probs[m], careful, log);
            m = (m << 1) | b;
            v |= @as(u32, b) << @intCast(i);
        }
        return v;
    }

    /// `n` bits of probability one half.
    pub inline fn direct(d: *Decoder, n: u5, comptime careful: bool) NeedInput!u32 {
        var v: u32 = 0;
        for (0..n) |_| {
            try d.normalize(careful);
            d.range >>= 1;
            // All ones where the code was at or above the range.
            const mask = 0 -% (((d.code -% d.range) >> 31) ^ 1);
            d.code -%= d.range & mask;
            v = (v << 1) | (mask & 1);
        }
        return v;
    }
};

pub const Encoder = struct {
    low: u64 = 0,
    range: u32 = 0xffff_ffff,
    /// The byte held back for a carry, and how many (it, then 0xff ones)
    /// wait.
    cache: u8 = 0,
    cache_size: u64 = 1,
    out: []u8,
    /// The bytes written, including those past `out` (not stored).
    pos: usize = 0,

    pub fn init(out: []u8) Encoder {
        return .{ .out = out };
    }

    /// The bytes written taken away: the coder goes on into `out` from
    /// its start.
    pub fn restart(e: *Encoder, out: []u8) void {
        e.out = out;
        e.pos = 0;
    }

    /// Whether every byte written fit in `out`.
    pub fn fits(e: *const Encoder) bool {
        return e.pos <= e.out.len;
    }

    /// The bytes still to come once flushed: the held ones and the flush's.
    pub inline fn pending(e: *const Encoder) u64 {
        return e.cache_size + 5 - 1;
    }

    inline fn put(e: *Encoder, b: u8) void {
        if (e.pos < e.out.len) e.out[e.pos] = b;
        e.pos += 1;
    }

    inline fn shiftLow(e: *Encoder) void {
        if (@as(u32, @truncate(e.low)) < 0xff00_0000 or e.low >> 32 != 0) {
            const carry: u8 = @truncate(e.low >> 32);
            var b = e.cache;
            while (true) {
                e.put(b +% carry);
                b = 0xff;
                e.cache_size -= 1;
                if (e.cache_size == 0) break;
            }
            e.cache = @truncate(e.low >> 24);
        }
        e.cache_size += 1;
        e.low = (e.low & 0x00ff_ffff) << 8;
    }

    inline fn normalize(e: *Encoder) void {
        if (e.range < top) {
            e.range <<= 8;
            e.shiftLow();
        }
    }

    /// One bit under probability `p`, `p` moved toward it.
    pub inline fn bit(e: *Encoder, p: *Prob, b: u32) void {
        e.normalize();
        const bound = (e.range >> prob_bits) * p.*;
        if (b == 0) {
            e.range = bound;
            p.* += ((1 << prob_bits) - p.*) >> move_bits;
        } else {
            e.low += bound;
            e.range -= bound;
            p.* -= p.* >> move_bits;
        }
    }

    /// The low `n` bits of `v`, most significant first, through a tree.
    pub inline fn tree(e: *Encoder, probs: []Prob, comptime n: u5, v: u32) void {
        var m: u32 = 1;
        inline for (0..n) |i| {
            const b = (v >> (n - 1 - i)) & 1;
            e.bit(&probs[m], b);
            m = (m << 1) | b;
        }
    }

    /// The low `n` bits of `v`, least significant first, through a tree.
    pub inline fn reverse(e: *Encoder, probs: []Prob, n: u5, v: u32) void {
        var m: u32 = 1;
        var rest = v;
        for (0..n) |_| {
            const b = rest & 1;
            rest >>= 1;
            e.bit(&probs[m], b);
            m = (m << 1) | b;
        }
    }

    /// The low `n` bits of `v` at one half each, most significant first.
    pub inline fn direct(e: *Encoder, v: u32, n: u5) void {
        var i = n;
        while (i > 0) {
            i -= 1;
            e.normalize();
            e.range >>= 1;
            if ((v >> i) & 1 != 0) e.low += e.range;
        }
    }

    /// The coder's last bytes: a stream can end here.
    pub fn flush(e: *Encoder) void {
        e.normalize();
        for (0..5) |_| e.shiftLow();
    }
};

/// The price of a bit, in sixteenths of a bit, by probability.
const prices: [(1 << prob_bits) >> reducing_bits]u8 = blk: {
    @setEvalBranchQuota(20000);
    var t: [(1 << prob_bits) >> reducing_bits]u8 = undefined;
    var i: u32 = (1 << reducing_bits) / 2;
    while (i < 1 << prob_bits) : (i += 1 << reducing_bits) {
        var w: u32 = i;
        var count: u32 = 0;
        for (0..price_shift) |_| {
            w *= w;
            count <<= 1;
            while (w >= 1 << 16) {
                w >>= 1;
                count += 1;
            }
        }
        t[i >> reducing_bits] = @intCast((prob_bits << price_shift) - 15 - count);
    }
    break :blk t;
};
const reducing_bits = 4;
const price_shift = 4;
/// A price no path reaches.
pub const infinity: u32 = 1 << 30;

pub inline fn bitPrice(p: Prob, b: u32) u32 {
    return prices[(p ^ ((0 -% b) & ((1 << prob_bits) - 1))) >> reducing_bits];
}
pub inline fn bit0Price(p: Prob) u32 {
    return prices[p >> reducing_bits];
}
pub inline fn bit1Price(p: Prob) u32 {
    return prices[(p ^ ((1 << prob_bits) - 1)) >> reducing_bits];
}

/// The price of `v`'s low `n` bits through a tree.
pub inline fn treePrice(probs: []const Prob, comptime n: u5, v: u32) u32 {
    var price: u32 = 0;
    var m = v + (1 << n);
    while (m != 1) {
        const b = m & 1;
        m >>= 1;
        price += bitPrice(probs[m], b);
    }
    return price;
}

pub inline fn reversePrice(probs: []const Prob, n: u5, v: u32) u32 {
    var price: u32 = 0;
    var m: u32 = 1;
    var rest = v;
    for (0..n) |_| {
        const b = rest & 1;
        rest >>= 1;
        price += bitPrice(probs[m], b);
        m = (m << 1) | b;
    }
    return price;
}

pub inline fn directPrice(n: u32) u32 {
    return n << price_shift;
}

test "bits decode as the reference's coder writes them" {
    // The stream LZMA writes for a single literal 'a' at lc=3 lp=0 pb=2
    // starts 00 30 ...; here the coder alone: five bytes, a bit at one
    // half reads the code's top bit.
    var d: Decoder = .{ .in = &.{ 0, 0x80, 0, 0, 0, 0 }, .pos = 0 };
    try std.testing.expect(try d.start());
    try std.testing.expectEqual(@as(u32, 1), try d.direct(1, false));
    var e: Decoder = .{ .in = &.{ 1, 0, 0, 0, 0 }, .pos = 0 };
    try std.testing.expect(!try e.start());
    var f: Decoder = .{ .in = &.{ 0, 0 }, .pos = 0 };
    try std.testing.expectError(error.NeedInput, f.start());
}

test "what the encoder writes, the decoder reads" {
    var buf: [64]u8 = undefined;
    var e: Encoder = .init(&buf);
    var pe: [8]Prob = @splat(prob_init);
    const bits = [_]u32{ 1, 0, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0, 1 };
    for (bits, 0..) |b, i| e.bit(&pe[i % 8], b);
    e.direct(0x2d5, 10);
    e.tree(&pe, 3, 5);
    e.flush();
    try std.testing.expect(e.fits());
    try std.testing.expectEqual(@as(u8, 0), buf[0]);
    var d: Decoder = .{ .in = buf[0..e.pos], .pos = 0 };
    try std.testing.expect(try d.start());
    var pd: [8]Prob = @splat(prob_init);
    var log: Log = .{};
    for (bits, 0..) |b, i| try std.testing.expectEqual(b, try d.bit(&pd[i % 8], false, &log));
    try std.testing.expectEqual(@as(u32, 0x2d5), try d.direct(10, false));
    try std.testing.expectEqual(@as(u32, 5), try d.tree(&pd, 3, false, &log));
    try d.normalize(false);
    try std.testing.expect(d.finished());
    try std.testing.expectEqual(e.pos, d.pos);
}

test "prices: a bit at one half costs one bit" {
    try std.testing.expectEqual(@as(u32, 16), bit0Price(prob_init));
    try std.testing.expect(bit0Price(2000) < bit1Price(2000));
}
