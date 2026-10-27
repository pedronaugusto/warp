//! S2's better parser (`s2.EncodeBetter`, and `EncodeSnappyBetter` with no
//! repeats), as its generated assembly runs it on amd64 and arm64: a table
//! of long hashes (5 to 7 bytes) and one of 4-byte hashes, by the input's
//! size class. Each step takes an 8-byte match from either table first,
//! then a 4-byte one, trying the long table one byte on against a short
//! match. A match at the last offset is a repeat; a match of 5 bytes or
//! less more than 64 KiB back is not taken. After each copy the positions
//! it covered are indexed: its second and its last two in both tables,
//! then every other one from both ends into the long table. Steps grow
//! with the bytes since the last literal, capped at 100 in the largest
//! classes. Where the output would not stay `len / 32` plus a margin
//! shorter than the input, the parser gives up and the block is one
//! literal.

const std = @import("std");
const emit = @import("emit.zig");
const fast = @import("fast.zig");

/// A size class: the assembly's parameters for inputs of at most
/// `max_len` bytes.
pub const Class = struct {
    long_bits: u6,
    short_bits: u6,
    skip_log: u5,
    long_bytes: u4,
    max_len: u64,
    /// The largest step; 0 for none.
    max_skip: u32,
    /// Snappy's elements: no repeats.
    snappy: bool,
};

/// The most table entries any class takes: long, then short.
pub const max_long = 1 << 17;
pub const max_short = 1 << 14;

pub fn class(len: usize, comptime snappy: bool) Class {
    const max = std.math.maxInt(u32);
    if (snappy) {
        if (len > 65536) return .{ .long_bits = 17, .short_bits = 14, .skip_log = 7, .long_bytes = 7, .max_len = max, .max_skip = 100, .snappy = true };
        if (len >= 16 << 10) return .{ .long_bits = 16, .short_bits = 13, .skip_log = 7, .long_bytes = 7, .max_len = 65535, .max_skip = 0, .snappy = true };
    } else {
        if (len > 4 << 20) return .{ .long_bits = 17, .short_bits = 14, .skip_log = 7, .long_bytes = 7, .max_len = max, .max_skip = 100, .snappy = false };
        if (len >= 16 << 10) return .{ .long_bits = 17, .short_bits = 14, .skip_log = 7, .long_bytes = 7, .max_len = 4 << 20, .max_skip = 100, .snappy = false };
    }
    if (len >= 4 << 10) return .{ .long_bits = 14, .short_bits = 12, .skip_log = 6, .long_bytes = 6, .max_len = (16 << 10) - 1, .max_skip = 0, .snappy = snappy };
    if (len >= 512) return .{ .long_bits = 12, .short_bits = 10, .skip_log = 5, .long_bytes = 6, .max_len = (4 << 10) - 1, .max_skip = 0, .snappy = snappy };
    return .{ .long_bits = 10, .short_bits = 8, .skip_log = 4, .long_bytes = 6, .max_len = 511, .max_skip = 0, .snappy = snappy };
}

/// The elements of `in` (at least `fast.min_len` bytes) into `out[at..]`,
/// or null where S2 gives up. `long` and `short` hold `max_long` and
/// `max_short` entries.
pub fn encode(comptime snappy: bool, in: []const u8, out: []u8, at: usize, long: []u32, short: []u32) ?usize {
    const len = in.len;
    if (snappy) {
        if (len > 65536) return run(class(65537, true), in, out, at, long, short);
        if (len >= 16 << 10) return run(class(16 << 10, true), in, out, at, long, short);
    } else {
        if (len > 4 << 20) return run(class((4 << 20) + 1, false), in, out, at, long, short);
        if (len >= 16 << 10) return run(class(16 << 10, false), in, out, at, long, short);
    }
    if (len >= 4 << 10) return run(class(4 << 10, snappy), in, out, at, long, short);
    if (len >= 512) return run(class(512, snappy), in, out, at, long, short);
    return run(class(fast.min_len, snappy), in, out, at, long, short);
}

inline fn load32(in: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, in[at..][0..4], .little);
}

inline fn load64(in: []const u8, at: usize) u64 {
    return std.mem.readInt(u64, in[at..][0..8], .little);
}

fn run(comptime c: Class, in: []const u8, out: []u8, at: usize, long_all: []u32, short_all: []u32) ?usize {
    const long = long_all[0 .. @as(usize, 1) << c.long_bits];
    const short = short_all[0 .. @as(usize, 1) << c.short_bits];
    @memset(long, 0);
    @memset(short, 0);
    const overhead = comptime emit.literalOverhead(c.max_len);
    const margin: usize = if (c.snappy) 9 else 6;
    const len = in.len;
    const s_limit = len - 8;
    const dst_limit = at + (len - margin - (len >> 5));
    const hashL = struct {
        inline fn f(v: u64) usize {
            return fast.hash(c.long_bytes, c.long_bits, v);
        }
    }.f;
    const hashS = struct {
        inline fn f(v: u64) usize {
            return fast.hash(4, c.short_bits, v);
        }
    }.f;
    var o = at;
    var next_emit: usize = 0;
    var s: usize = 1;
    var repeat: usize = 0;
    search: while (true) {
        const gap = (s - next_emit) >> c.skip_log;
        const next_s = if (c.max_skip != 0 and gap > c.max_skip - 1) s + c.max_skip else s + gap + 1;
        if (next_s >= s_limit) break :search;
        var cv = load64(in, s);
        const hl = hashL(cv);
        const hs = hashS(cv);
        var candidate: usize = long[hl];
        const candidate_s: usize = short[hs];
        long[hl] = @intCast(s);
        short[hs] = @intCast(s);
        const long_val = load64(in, candidate);
        const short_val = load64(in, candidate_s);
        // Eight bytes from either table first, then four.
        if (long_val != cv) {
            if (short_val == cv) {
                candidate = candidate_s;
            } else if (@as(u32, @truncate(long_val)) != @as(u32, @truncate(cv))) {
                if (@as(u32, @truncate(short_val)) != @as(u32, @truncate(cv))) {
                    s = next_s;
                    continue :search;
                }
                // A short match: the long table one byte on, else it.
                cv >>= 8;
                const h = hashL(cv);
                candidate = long[h];
                s += 1;
                long[h] = @intCast(s);
                if (load32(in, candidate) != @as(u32, @truncate(cv))) {
                    s -= 1;
                    candidate = candidate_s;
                }
            }
        }
        while (candidate != 0 and s > next_emit and in[candidate - 1] == in[s - 1]) {
            s -= 1;
            candidate -= 1;
        }
        if (o + (s - next_emit) + overhead >= dst_limit) return null;
        const base = s;
        s += 4;
        candidate += 4;
        const extra = fast.matchLen(in, candidate, s);
        const offset = s - candidate;
        if (!c.snappy and repeat == offset) {
            if (base != next_emit) o = emit.literal(out, o, in, next_emit, base - next_emit);
            s += extra;
            next_emit = s;
            o = emit.s2Repeat(c.max_len, out, o, offset, extra + 4);
        } else {
            // Five bytes or fewer from more than 64 KiB back cost what
            // they save: not taken.
            if (c.max_len - 1 > 65535 and extra <= 1 and offset > 65535) {
                s = next_s + 1;
                continue :search;
            }
            repeat = offset;
            if (base != next_emit) o = emit.literal(out, o, in, next_emit, base - next_emit);
            s += extra;
            next_emit = s;
            o = if (c.snappy)
                emit.s2CopyNoRepeat(c.max_len, out, o, offset, extra + 4)
            else
                emit.s2Copy(c.max_len, out, o, offset, extra + 4);
        }
        if (s >= s_limit) break :search;
        if (o >= dst_limit) return null;
        // The copy's positions into the tables.
        var index0 = base + 1;
        var index1 = s - 2;
        const h0l = hashL(load64(in, index0));
        const h0s = hashS(load64(in, index0 + 1));
        const h1l = hashL(load64(in, index1));
        const h1s = hashS(load64(in, index1 + 1));
        long[h0l] = @intCast(index0);
        long[h1l] = @intCast(index1);
        short[h0s] = @intCast(index0 + 1);
        short[h1s] = @intCast(index1 + 1);
        var index2 = (index0 + index1 + 1) >> 1;
        index0 += 1;
        index1 -= 1;
        while (index2 < index1) {
            const a = hashL(load64(in, index0));
            const b = hashL(load64(in, index2));
            long[a] = @intCast(index0);
            long[b] = @intCast(index2);
            index0 += 2;
            index2 += 2;
        }
    }
    if (o + (len - next_emit) + overhead >= dst_limit) return null;
    if (next_emit != len) o = emit.literal(out, o, in, next_emit, len - next_emit);
    return o;
}

/// S2's index of a dictionary for the better parser (`Dict.initBetter`):
/// every position's 7-byte hash into 2^17 entries and 4-byte hash into
/// 2^14.
pub const dict_long = 1 << 17;
pub const dict_short = 1 << 14;

pub fn indexDict(content: []const u8, long: []u16, short: []u16) void {
    @memset(long[0..dict_long], 0);
    @memset(short[0..dict_short], 0);
    var i: usize = 0;
    while (i + 8 < content.len) : (i += 1) {
        const cv = load64(content, i);
        long[fast.hash(7, 17, cv)] = @intCast(i);
        short[fast.hash(4, 14, cv)] = @intCast(i);
    }
}

const any_len = std.math.maxInt(u32);

/// S2's better parser with a dictionary (`Dict.EncodeBetter`, its Go on
/// every target): while the output may reach the dictionary, its tables
/// (made by `indexDict`) are searched beside the input's; then the input
/// alone, as `encodeBlockBetterGo`. Null where S2 gives up.
pub fn encodeDict(content: []const u8, repeat_at: usize, dlong: []const u16, dshort: []const u16, in: []const u8, out: []u8, at: usize, long: []u32, short: []u32) ?usize {
    @memset(long[0..dict_long], 0);
    @memset(short[0..dict_short], 0);
    var p: DictParser = .{
        .content = content,
        .dlong = dlong,
        .dshort = dshort,
        .in = in,
        .out = out,
        .long = long[0..dict_long],
        .short = short[0..dict_short],
        .o = at,
        .repeat = content.len - repeat_at,
        .s_limit = @min(in.len - 8, 65535 - 8),
        .dst_limit = at + in.len - (in.len >> 5) - 6,
        .cv = load64(in, 0),
    };
    return p.run();
}

/// What a step leaves: the next search, the end of a phase, the end of
/// the parse (the rest one literal), or giving up.
const Next = enum { more, end, finish, give_up };

const DictParser = struct {
    content: []const u8,
    dlong: []const u16,
    dshort: []const u16,
    in: []const u8,
    out: []u8,
    long: []u32,
    short: []u32,
    o: usize,
    next_emit: usize = 0,
    s: usize = 0,
    next_s: usize = 0,
    repeat: usize,
    cv: u64,
    s_limit: usize,
    dst_limit: usize,

    fn run(p: *DictParser) ?usize {
        second: {
            while (true) switch (p.step(true)) {
                .more => {},
                .end => break,
                .finish => break :second,
                .give_up => return null,
            };
            if (p.repeat > p.s) p.repeat = 0;
            p.s_limit = p.in.len - 8;
            if (p.s < p.s_limit) {
                p.cv = load64(p.in, p.s);
                while (true) switch (p.step(false)) {
                    .more => {},
                    .end, .finish => break,
                    .give_up => return null,
                };
            }
        }
        if (p.next_emit >= p.in.len) return p.o;
        if (p.o + p.in.len - p.next_emit > p.dst_limit) return null;
        return emit.literal(p.out, p.o, p.in, p.next_emit, p.in.len - p.next_emit);
    }

    fn literalTo(p: *DictParser, end: usize) void {
        if (end != p.next_emit) p.o = emit.literal(p.out, p.o, p.in, p.next_emit, end - p.next_emit);
    }

    inline fn hl(v: u64) usize {
        return fast.hash(7, 17, v);
    }

    inline fn hs(v: u64) usize {
        return fast.hash(4, 14, v);
    }

    /// One search: with the dictionary while `dict`, else the input alone.
    fn step(p: *DictParser, comptime dict: bool) Next {
        const in = p.in;
        const s = p.s;
        const cv = p.cv;
        p.next_s = s + ((s - p.next_emit) >> 7) + 1;
        if (p.next_s > p.s_limit) return .end;
        const h_long = hl(cv);
        const h_short = hs(cv);
        const candidate_l: usize = p.long[h_long];
        const candidate_s: usize = p.short[h_short];
        const dict_l: usize = if (dict) p.dlong[h_long] else 0;
        const dict_s: usize = if (dict) p.dshort[h_short] else 0;
        p.long[h_long] = @intCast(s);
        p.short[h_short] = @intCast(s);
        const val_long = load64(in, candidate_l);
        const val_short = load64(in, candidate_s);
        if (!dict or s != 0) {
            if (cv == val_long) return p.inputMatch(candidate_l);
            if (cv == val_short) return p.inputMatch(candidate_s);
        }
        if (dict and p.repeat >= s + 4) {
            const c = p.content.len - (p.repeat - s);
            if (c > 0 and @as(u32, @truncate(cv)) == load32(p.content, c)) return p.dictRepeat(c);
        }
        if (dict and s == 0) {
            p.cv = load64(in, p.next_s);
            p.s = p.next_s;
            return .more;
        }
        if (@as(u32, @truncate(cv)) == @as(u32, @truncate(val_long))) return p.inputMatch(candidate_l);
        if (dict and @as(u32, @truncate(cv)) == load32(p.content, dict_l)) return p.dictMatch(dict_l);
        if (@as(u32, @truncate(cv)) == @as(u32, @truncate(val_short))) {
            const h = hl(cv >> 8);
            const c: usize = p.long[h];
            p.long[h] = @intCast(s + 1);
            if (@as(u32, @truncate(cv >> 8)) == load32(in, c)) {
                p.s += 1;
                return p.inputMatch(c);
            }
            return p.inputMatch(candidate_s);
        }
        if (dict and @as(u32, @truncate(cv)) == load32(p.content, dict_s)) {
            const h = hl(cv >> 8);
            const c: usize = p.long[h];
            p.long[h] = @intCast(s + 1);
            if (@as(u32, @truncate(cv >> 8)) == load32(in, c)) {
                p.s += 1;
                return p.inputMatch(c);
            }
            return p.dictMatch(dict_s);
        }
        p.cv = load64(in, p.next_s);
        p.s = p.next_s;
        return .more;
    }

    /// The repeat value reaching into the dictionary at `s`, from `c`.
    fn dictRepeat(p: *DictParser, c_in: usize) Next {
        const in = p.in;
        const content = p.content;
        var c = c_in;
        var base = p.s;
        var i = c;
        while (base > p.next_emit and i > 0 and content[i - 1] == in[base - 1]) {
            i -= 1;
            base -= 1;
        }
        p.literalTo(base);
        var s = p.s + 4;
        c += 4;
        while (c + 8 < content.len and s + 8 <= in.len) {
            const diff = load64(in, s) ^ load64(content, c);
            if (diff != 0) {
                s += @ctz(diff) / 8;
                break;
            }
            s += 8;
            c += 8;
        }
        p.o = emit.s2Repeat(any_len, p.out, p.o, p.repeat, s - base);
        p.next_emit = s;
        p.s = s;
        if (s >= p.s_limit) return .end;
        var index0 = base + 1;
        var index1 = s - 2;
        p.cv = load64(in, s);
        while (index0 < index1) {
            const cv0 = load64(in, index0);
            const cv1 = load64(in, index1);
            p.long[hl(cv0)] = @intCast(index0);
            p.short[hs(cv0 >> 8)] = @intCast(index0 + 1);
            p.long[hl(cv1)] = @intCast(index1);
            p.short[hs(cv1 >> 8)] = @intCast(index1 + 1);
            index0 += 2;
            index1 -= 2;
        }
        return .more;
    }

    /// The copy's two ends into both tables.
    fn indexEnds(p: *DictParser, index0: usize, index1: usize) void {
        const cv0 = load64(p.in, index0);
        const cv1 = load64(p.in, index1);
        p.long[hl(cv0)] = @intCast(index0);
        p.short[hs(cv0 >> 8)] = @intCast(index0 + 1);
        p.long[hl(cv1)] = @intCast(index1);
        p.short[hs(cv1 >> 8)] = @intCast(index1 + 1);
    }

    /// A match from the dictionary at `s`.
    fn dictMatch(p: *DictParser, cand_in: usize) Next {
        const in = p.in;
        const content = p.content;
        var cand = cand_in;
        var s = p.s;
        while (cand > 0 and s > p.next_emit and content[cand - 1] == in[s - 1]) {
            cand -= 1;
            s -= 1;
        }
        if (p.o + (s - p.next_emit) > p.dst_limit) return .give_up;
        p.literalTo(s);
        const base = s;
        const offset = s + content.len - cand;
        s += 4;
        cand += 4;
        while (s + 8 <= in.len and content.len - cand >= 8) {
            const diff = load64(in, s) ^ load64(content, cand);
            if (diff != 0) {
                s += @ctz(diff) / 8;
                break;
            }
            s += 8;
            cand += 8;
        }
        if (p.repeat == offset) {
            p.o = emit.s2Repeat(any_len, p.out, p.o, offset, s - base);
        } else {
            if (s <= p.s_limit or s - base < 8) {
                p.o = emit.s2Copy(any_len, p.out, p.o, offset, s - base);
            } else {
                p.o = emit.s2Copy(any_len, p.out, p.o, offset, 4);
                p.o = emit.s2Repeat(any_len, p.out, p.o, offset, s - base - 4);
            }
            p.repeat = offset;
        }
        p.next_emit = s;
        p.s = s;
        if (s >= p.s_limit) return .end;
        if (p.o > p.dst_limit) return .give_up;
        var index0 = base + 1;
        var index1 = s - 2;
        p.indexEnds(index0, index1);
        index0 += 1;
        index1 -= 1;
        p.cv = load64(in, s);
        while (index0 < index1) {
            p.long[hl(load64(in, index0))] = @intCast(index0);
            p.long[hl(load64(in, index1))] = @intCast(index1);
            index0 += 2;
            index1 -= 2;
        }
        return .more;
    }

    /// A match from the input at `s`.
    fn inputMatch(p: *DictParser, cand_in: usize) Next {
        const in = p.in;
        var cand = cand_in;
        var s = p.s;
        while (cand > 0 and s > p.next_emit and in[cand - 1] == in[s - 1]) {
            cand -= 1;
            s -= 1;
        }
        if (p.o + (s - p.next_emit) > p.dst_limit) return .give_up;
        const base = s;
        const offset = base - cand;
        s = base + 4 + fast.matchLen(in, cand + 4, base + 4);
        if (offset > 65535 and s - base <= 5 and p.repeat != offset) {
            p.s = p.next_s + 1;
            if (p.s >= p.s_limit) return .finish;
            p.cv = load64(in, p.s);
            return .more;
        }
        p.literalTo(base);
        if (p.repeat == offset) {
            p.o = emit.s2Repeat(any_len, p.out, p.o, offset, s - base);
        } else {
            p.o = emit.s2Copy(any_len, p.out, p.o, offset, s - base);
            p.repeat = offset;
        }
        p.next_emit = s;
        p.s = s;
        // An input match past the limit ends the parse, in either phase.
        if (s >= p.s_limit) return .finish;
        if (p.o > p.dst_limit) return .give_up;
        var index0 = base + 1;
        var index1 = s - 2;
        p.indexEnds(index0, index1);
        index0 += 1;
        index1 -= 1;
        p.cv = load64(in, s);
        var index2 = (index0 + index1 + 1) >> 1;
        while (index2 < index1) {
            p.long[hl(load64(in, index0))] = @intCast(index0);
            p.long[hl(load64(in, index2))] = @intCast(index2);
            index0 += 2;
            index2 += 2;
        }
        return .more;
    }
};
