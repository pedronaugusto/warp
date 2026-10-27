//! LZMA's range decoder over the input in place: a 32-bit range and code,
//! a byte read whenever the range falls below 2^24, and 11-bit adaptive
//! probabilities. A symbol reads at most `symbol_max` bytes, so the
//! decoder runs unchecked while that many remain; past them it is careful:
//! a byte it lacks is `NeedInput`, and the probabilities it changed are
//! logged so the symbol can be undone.

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
            d.code = d.code << 8 | d.in[d.pos];
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
        inline for (0..n) |_| m = m << 1 | try d.bit(&probs[m], careful, log);
        return m - (1 << n);
    }

    /// `n` bits, least significant first, through a tree.
    pub inline fn reverse(d: *Decoder, probs: []Prob, n: u5, comptime careful: bool, log: *Log) NeedInput!u32 {
        var m: u32 = 1;
        var v: u32 = 0;
        for (0..n) |i| {
            const b = try d.bit(&probs[m], careful, log);
            m = m << 1 | b;
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
            const mask = 0 -% (d.code -% d.range >> 31 ^ 1);
            d.code -%= d.range & mask;
            v = v << 1 | (mask & 1);
        }
        return v;
    }
};

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
