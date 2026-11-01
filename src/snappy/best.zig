//! S2's best parser (`s2.EncodeBest`, and `EncodeSnappyBest` with no
//! repeats), as its Go runs on every target: a table of 8-byte hashes
//! (2^19 entries) and one of 4-byte hashes (2^16), each entry the latest
//! two positions. At each step every candidate of both tables, the last
//! offset, and the next two positions' candidates are scored by the bytes
//! they cover less what their copy costs (and the literal before it), and
//! the best is taken; a candidate that ends where the long table holds a
//! match is tried from that match's start too. Every position a copy
//! covers is indexed. Where the output would not stay 5 bytes shorter than
//! the input, the parser gives up and the block is one literal.
//!
//! The copies and repeats are written by S2's assembly emitters (as on
//! amd64 and arm64), and scored by its Go size functions.

const std = @import("std");
const emit = @import("emit.zig");

pub const long_bits = 19;
pub const short_bits = 16;
/// The tables' entries: the latest position in the low 32 bits, the one
/// before in the high.
pub const max_long = 1 << long_bits;
pub const max_short = 1 << short_bits;

/// The blocks the emitters size for: any.
const any_len = std.math.maxInt(u32);
const input_margin = 8 + 2;
const max_skip = 64;

inline fn load32(in: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, in[at..][0..4], .little);
}

inline fn load64(in: []const u8, at: usize) u64 {
    return std.mem.readInt(u64, in[at..][0..8], .little);
}

inline fn hash8(v: u64) usize {
    return @intCast((v *% 0xcf1bbcdcb7a56463) >> (64 - long_bits));
}

inline fn hash4(v: u64) usize {
    return (@as(u32, @truncate(v)) *% 2654435761) >> (32 - short_bits);
}

inline fn cur(e: u64) usize {
    return @intCast(e & 0xffff_ffff);
}

inline fn prev(e: u64) usize {
    return @intCast(e >> 32);
}

/// S2's `emitRepeatSize`.
fn repeatSize(offset: usize, len_in: usize) usize {
    var len = len_in;
    var size: usize = 0;
    while (true) {
        if (len <= 4 + 4 or (len < 8 + 4 and offset < 2048)) return size + 2;
        if (len < (1 << 8) + 4 + 4) return size + 3;
        if (len < (1 << 16) + (1 << 8) + 4) return size + 4;
        const max_repeat = (1 << 24) - 1;
        len -= (1 << 16) - 4;
        if (len <= max_repeat) return size + 5;
        size += 5;
        len = len - max_repeat + 4;
    }
}

/// S2's `emitCopySize`.
fn copySize(offset: usize, len_in: usize) usize {
    var len = len_in;
    if (offset >= 65536) {
        var i: usize = 0;
        if (len > 64) {
            len -= 64;
            if (len >= 4) return 5 + repeatSize(offset, len);
            i = 5;
        }
        if (len == 0) return i;
        return i + 5;
    }
    if (len > 64) {
        if (offset < 2048) return 2 + repeatSize(offset, len - 8);
        return 3 + repeatSize(offset, len - 60);
    }
    if (len >= 12 or offset >= 2048) return 3;
    return 2;
}

/// S2's `emitCopyNoRepeatSize`.
fn copyNoRepeatSize(offset: usize, len: usize) usize {
    if (offset >= 65536) return 5 + 5 * (len / 64);
    if (len > 64) return 3 + 3 * (len / 60);
    if (len >= 12 or offset >= 2048) return 3;
    return 2;
}

const Match = struct {
    /// Where the match starts: in the input, or (from the dictionary) that
    /// far before it, negative.
    offset: isize = 0,
    s: usize = 0,
    length: usize = 0,
    score: isize = 0,
    rep: bool = false,
    dict: bool = false,

    /// How far back it copies from.
    fn distance(m: Match) usize {
        return @intCast(@as(isize, @intCast(m.s)) - m.offset);
    }
};

/// The better of two candidates: by score, the earlier on a tie.
inline fn bestOf(a: Match, b: Match) Match {
    if (b.length == 0) return a;
    if (a.length == 0) return b;
    const as = a.score + @as(isize, @intCast(b.s));
    const bs = b.score + @as(isize, @intCast(a.s));
    return if (as >= bs) a else b;
}

/// S2's, Snappy's (no repeats), or S2's with a dictionary.
pub const Mode = enum { s2, snappy, dict };

/// A dictionary for the best parser: its content, its first repeat, and
/// its tables made by `indexDict`.
pub const DictTables = struct {
    content: []const u8,
    repeat: usize,
    long: []const u32,
    short: []const u32,
};

/// S2's index of a dictionary for the best parser (`Dict.initBest`):
/// every position's 8- and 4-byte hashes, each entry the latest two
/// positions (16 bits each).
pub fn indexDict(content: []const u8, long: []u32, short: []u32) void {
    @memset(long[0..max_long], 0);
    @memset(short[0..max_short], 0);
    var i: usize = 0;
    while (i + 8 < content.len) : (i += 1) {
        const cv = load64(content, i);
        const l = hash8(cv);
        const h = hash4(cv);
        long[l] = @as(u32, @intCast(i)) | (long[l] << 16);
        short[h] = @as(u32, @intCast(i)) | (short[h] << 16);
    }
}

/// The elements of `in` (at least 32 bytes) into `out[at..]`, or null
/// where S2 gives up. `long` and `short` hold `max_long` and `max_short`
/// entries; `dict` is given with `.dict`.
pub fn encode(comptime mode: Mode, in: []const u8, out: []u8, at: usize, long: []u64, short: []u64, dict: ?DictTables) ?usize {
    @memset(long, 0);
    @memset(short, 0);
    var p: Parser(mode) = .{ .in = in, .long = long, .short = short, .s_limit = in.len - input_margin };
    if (mode == .dict) {
        const d = dict.?;
        p.dict = d;
        p.repeat = @intCast(d.content.len - d.repeat);
        p.s_limit_dict = @min(in.len - input_margin, 65535 - input_margin);
    }
    return p.run(out, at);
}

fn Parser(comptime mode: Mode) type {
    const snappy = mode == .snappy;
    return struct {
        const P = @This();

        in: []const u8,
        long: []u64,
        short: []u64,
        s_limit: usize,
        next_emit: usize = 0,
        repeat: isize = 1,
        /// The best candidate of the step so far.
        best: Match = .{},
        /// The dictionary, while the output may reach it.
        dict: ?DictTables = null,
        s_limit_dict: usize = 0,

        fn run(p: *P, out: []u8, at: usize) ?usize {
            const in = p.in;
            const len = in.len;
            const dst_limit = at + len - 5;
            var o = at;
            var s: usize = if (mode == .dict) 0 else 1;
            var cv = load64(in, s);
            outer: while (true) {
                p.best = .{};
                // Steps until one finds a match.
                while (true) {
                    var next_s = ((s - p.next_emit) >> 8) + 1;
                    next_s = if (next_s > max_skip) s + max_skip else next_s + s;
                    if (next_s > p.s_limit) break :outer;
                    if (mode == .dict and p.dict != null and s >= 65535) {
                        p.dict = null;
                        if (p.repeat > @as(isize, @intCast(s))) p.repeat = std.math.minInt(i32);
                    }
                    p.step(s, cv);
                    if (p.best.length > 0) break;
                    cv = load64(in, next_s);
                    s = next_s;
                }
                var best = p.best;
                s = best.s;
                if (!best.rep and !best.dict) {
                    while (best.offset > 0 and s > p.next_emit and in[@intCast(best.offset - 1)] == in[s - 1]) {
                        best.offset -= 1;
                        best.length += 1;
                        s -= 1;
                    }
                }
                if (o + (s - p.next_emit) > dst_limit) return null;
                const base = s;
                const offset: usize = @intCast(@as(isize, @intCast(s)) - best.offset);
                s += best.length;
                if (offset > 65535 and s - base <= 5 and !best.rep) {
                    s = best.s + 1;
                    if (s >= p.s_limit) break :outer;
                    cv = load64(in, s);
                    continue :outer;
                }
                if (base != p.next_emit) o = emit.literal(out, o, in, p.next_emit, base - p.next_emit);
                if (snappy) {
                    o = emit.s2CopyNoRepeat(any_len, out, o, offset, best.length);
                } else if (best.rep and (p.next_emit > 0 or best.dict)) {
                    o = emit.s2Repeat(any_len, out, o, offset, best.length);
                } else {
                    o = emit.s2Copy(any_len, out, o, offset, best.length);
                }
                p.repeat = @intCast(offset);
                p.next_emit = s;
                if (s >= p.s_limit) break :outer;
                if (o > dst_limit) return null;
                var i = best.s + 1;
                while (i < s) : (i += 1) p.index(i);
                cv = load64(in, s);
            }
            if (p.next_emit < len) {
                if (o + len - p.next_emit > dst_limit) return null;
                o = emit.literal(out, o, in, p.next_emit, len - p.next_emit);
            }
            return o;
        }

        /// Position `i` into both tables, the latest before it kept.
        inline fn index(p: *P, i: usize) void {
            const v = load64(p.in, i);
            const l = hash8(v);
            const h = hash4(v);
            p.long[l] = @as(u64, i) | (p.long[l] << 32);
            p.short[h] = @as(u64, i) | (p.short[h] << 32);
        }

        /// Whether the repeat is an offset in the input at `s`.
        inline fn inputRepeat(p: *const P, s: usize) bool {
            return (p.dict == null or p.repeat <= @as(isize, @intCast(s))) and p.repeat > 0;
        }

        /// The candidates at `s`, the last offset one on, and (once one
        /// matches) the next two positions' and a match ending where the
        /// best does, into `best`; then `s` into the tables.
        fn step(p: *P, s: usize, cv: u64) void {
            const hl = hash8(cv);
            const hs = hash4(cv);
            const candidate_l = p.long[hl];
            const candidate_s = p.short[hs];
            const first: u32 = @truncate(cv);
            if (s > 0) {
                p.best = bestOf(p.candidate(cur(candidate_l), s, first, false), p.candidate(prev(candidate_l), s, first, false));
                p.take(p.candidate(cur(candidate_s), s, first, false));
                p.take(p.candidate(prev(candidate_s), s, first, false));
            }
            if (p.dict) |d| {
                const dl = d.long[hl];
                const ds = d.short[hs];
                p.take(p.fromDict(dl & 0xffff, s, first, false));
                p.take(p.fromDict(dl >> 16, s, first, false));
                p.take(p.fromDict(ds & 0xffff, s, first, false));
                p.take(p.fromDict(ds >> 16, s, first, false));
            }
            const si: isize = @intCast(s);
            if (snappy or p.inputRepeat(s)) {
                p.take(p.candidate(@intCast(si - p.repeat + 1), s + 1, @truncate(cv >> 8), !snappy));
            } else if (mode == .dict and si - p.repeat < -4 and p.dict != null) {
                const c: usize = @intCast(@as(isize, @intCast(p.dict.?.content.len)) - (p.repeat - si));
                p.take(p.fromDict(c, s, first, true));
                p.take(p.fromDict(c + 1, s + 1, @truncate(cv >> 8), true));
            }
            if (p.best.length > 0) p.ahead(s, cv);
            p.long[hl] = @as(u64, s) | (candidate_l << 32);
            p.short[hs] = @as(u64, s) | (candidate_s << 32);
        }

        /// The next two positions' candidates, then a match ending where
        /// the best does.
        fn ahead(p: *P, s: usize, cv: u64) void {
            const in = p.in;
            var ns = s + 1;
            var ncv = load64(in, ns);
            var hs = hash4(cv >> 8);
            var hl = hash8(ncv);
            p.around(p.short[hs], p.long[hl], ns, @truncate(ncv));
            if (p.dict) |d| {
                p.take(p.fromDict(d.long[hl] & 0xffff, ns, @truncate(ncv), false));
                p.take(p.fromDict(d.short[hs] & 0xffff, ns, @truncate(ncv), false));
            }
            if (snappy) p.take(p.candidate(@intCast(@as(isize, @intCast(ns)) - p.repeat + 1), ns + 1, @truncate(ncv >> 8), false));
            hs = hash4(ncv >> 8);
            const next_short = p.short[hs];
            ns += 1;
            ncv = load64(in, ns);
            hl = hash8(ncv);
            const next_long = p.long[hl];
            const nsi: isize = @intCast(ns);
            if (!snappy and p.inputRepeat(ns)) {
                p.take(p.candidate(@intCast(nsi - p.repeat), ns, @truncate(ncv), true));
            } else if (mode == .dict and p.repeat - nsi > 4 and p.dict != null) {
                const c: usize = @intCast(@as(isize, @intCast(p.dict.?.content.len)) - (p.repeat - nsi));
                p.take(p.fromDict(c, ns, @truncate(ncv), true));
            }
            p.around(next_short, next_long, ns, @truncate(ncv));
            if (p.dict) |d| {
                p.take(p.fromDict(d.long[hl] & 0xffff, ns, @truncate(ncv), false));
                p.take(p.fromDict(d.short[hs] & 0xffff, ns, @truncate(ncv), false));
            }
            // Where the best ends, a match in the long table: tried from
            // its start, as far back.
            const skip_begin: usize = if (snappy) 0 else 2;
            const skip_end: usize = if (snappy) 0 else 1;
            const b = p.best;
            const s_at = b.s + b.length - skip_end;
            if (s_at < p.s_limit) {
                const s_back = b.s + skip_begin - skip_end;
                const back_len = b.length - skip_begin;
                const bcv: u32 = @truncate(load64(in, s_back));
                const next = p.long[hash8(load64(in, s_at))];
                if (cur(next) > back_len) p.take(p.candidate(cur(next) - back_len, s_back, bcv, false));
                if (prev(next) > back_len) p.take(p.candidate(prev(next) - back_len, s_back, bcv, false));
            }
        }

        /// Both positions of a short and a long entry, for `s`.
        inline fn around(p: *P, short: u64, long: u64, s: usize, first: u32) void {
            p.take(p.candidate(cur(short), s, first, false));
            p.take(p.candidate(prev(short), s, first, false));
            p.take(p.candidate(cur(long), s, first, false));
            p.take(p.candidate(prev(long), s, first, false));
        }

        inline fn take(p: *P, m: Match) void {
            p.best = bestOf(p.best, m);
        }

        fn score(p: *const P, m: Match) isize {
            var sc = @as(isize, @intCast(m.length)) - @as(isize, @intCast(m.s));
            if (p.next_emit == m.s) sc += 1;
            const offset = m.distance();
            const size = if (snappy) copyNoRepeatSize(offset, m.length) else if (m.rep) repeatSize(offset, m.length) else copySize(offset, m.length);
            return sc - @as(isize, @intCast(size));
        }

        /// Whether the best already copies from where `offset` would for
        /// `s0`.
        inline fn sameAsBest(p: *const P, offset: isize, s0: usize) bool {
            const b = p.best;
            return b.length != 0 and @as(isize, @intCast(b.s)) - b.offset == @as(isize, @intCast(s0)) - offset;
        }

        /// The candidate from `offset` for position `s0`, its first four
        /// bytes `first`; length 0 for none (or for the best's offset
        /// again).
        fn candidate(p: *const P, offset: usize, s0: usize, first: u32, rep: bool) Match {
            const off: isize = @intCast(offset);
            if (p.sameAsBest(off, s0)) return .{ .offset = off, .s = s0 };
            const src = p.in;
            if (load32(src, offset) != first) return .{ .offset = off, .s = s0 };
            var m: Match = .{ .offset = off, .s = s0, .rep = rep };
            var at = offset + 4;
            var q = s0 + 4;
            // Snappy's stops at the input margin; S2's goes to the end.
            while (if (snappy) q <= p.s_limit else q < src.len) {
                if (!snappy and src.len - q < 8) {
                    if (src[q] != src[at]) break;
                    at += 1;
                    q += 1;
                    continue;
                }
                const diff = load64(src, q) ^ load64(src, at);
                if (diff != 0) {
                    at += @ctz(diff) >> 3;
                    break;
                }
                q += 8;
                at += 8;
            }
            m.length = at - offset;
            return p.scored(m);
        }

        /// The dictionary's candidate at content position `c` for `s0`.
        fn fromDict(p: *const P, c: usize, s0: usize, first: u32, rep: bool) Match {
            const content = p.dict.?.content;
            const off: isize = @as(isize, @intCast(c)) - @as(isize, @intCast(content.len));
            if (s0 >= 65535) return .{ .offset = off, .s = s0 };
            if (!rep and p.sameAsBest(off, s0)) return .{ .offset = off, .s = s0 };
            if (load32(content, c) != first) return .{ .offset = off, .s = s0 };
            const src = p.in;
            var m: Match = .{ .offset = off, .s = s0, .rep = rep, .dict = true };
            var at = c + 4;
            var q = s0 + 4;
            const end = if (rep) src.len else p.s_limit_dict;
            while (q < end and at < content.len) {
                if (src.len - q < 8 or content.len - at < 8) {
                    if (src[q] != content[at]) break;
                    at += 1;
                    q += 1;
                    continue;
                }
                const diff = load64(src, q) ^ load64(content, at);
                if (diff != 0) {
                    at += @ctz(diff) >> 3;
                    break;
                }
                q += 8;
                at += 8;
            }
            m.length = at - c;
            return p.scored(m);
        }

        inline fn scored(p: *const P, m_in: Match) Match {
            var m = m_in;
            m.score = p.score(m);
            if (m.score <= -@as(isize, @intCast(m.s))) m.length = 0;
            return m;
        }
    };
}
