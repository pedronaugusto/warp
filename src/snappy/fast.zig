//! S2's default parser (`s2.Encode`, and `EncodeSnappy` with no repeats),
//! as its generated assembly runs it on amd64 and arm64: one table of
//! 32-bit positions, hashed over 4 to 6 bytes into 2^8 to 2^14 entries by
//! the input's size class. Each step checks the last offset one byte on,
//! then three positions' candidates (two from one load); a match is
//! extended backwards and forwards, and after a copy the position two
//! before its end is indexed and the end tried at once. Steps grow with
//! the bytes since the last literal (`>> skip_log`, plus 4). Where the
//! output would not stay `len / 32 + 9` shorter than the input, the
//! parser gives up and the block is one literal.

const std = @import("std");
const emit = @import("emit.zig");

/// A size class: the assembly's parameters for inputs of at most
/// `max_len` bytes.
pub const Class = struct {
    table_bits: u6,
    skip_log: u5,
    hash_bytes: u4,
    max_len: u64,
    /// Snappy's elements: no repeats.
    snappy: bool,
};

/// Inputs shorter than this are one literal.
pub const min_len = 32;
/// The most table entries any class takes.
pub const max_table = 1 << 14;

/// The class S2 picks for an input of `len` (at least `min_len`) bytes.
pub fn class(len: usize, comptime snappy: bool) Class {
    const max = std.math.maxInt(u32);
    if (snappy) {
        if (len > 65536) return .{ .table_bits = 14, .skip_log = 6, .hash_bytes = 6, .max_len = max, .snappy = true };
        if (len >= 16 << 10) return .{ .table_bits = 14, .skip_log = 6, .hash_bytes = 6, .max_len = 65535, .snappy = true };
    } else {
        if (len >= 4 << 20) return .{ .table_bits = 14, .skip_log = 6, .hash_bytes = 6, .max_len = max, .snappy = false };
        if (len >= 16 << 10) return .{ .table_bits = 14, .skip_log = 6, .hash_bytes = 6, .max_len = 4 << 20, .snappy = false };
    }
    if (len >= 4 << 10) return .{ .table_bits = 12, .skip_log = 5, .hash_bytes = 5, .max_len = (16 << 10) - 1, .snappy = snappy };
    if (len >= 512) return .{ .table_bits = 10, .skip_log = 5, .hash_bytes = 4, .max_len = (4 << 10) - 1, .snappy = snappy };
    return .{ .table_bits = 8, .skip_log = 4, .hash_bytes = 4, .max_len = 511, .snappy = snappy };
}

/// The elements of `in` into `out[at..]`, or null where S2 gives up and
/// writes one literal. `table` holds `max_table` entries.
pub fn encode(comptime snappy: bool, in: []const u8, out: []u8, at: usize, table: []u32) ?usize {
    const len = in.len;
    if (snappy) {
        if (len > 65536) return run(class(65537, true), in, out, at, table);
        if (len >= 16 << 10) return run(class(16 << 10, true), in, out, at, table);
    } else {
        if (len >= 4 << 20) return run(class(4 << 20, false), in, out, at, table);
        if (len >= 16 << 10) return run(class(16 << 10, false), in, out, at, table);
    }
    if (len >= 4 << 10) return run(class(4 << 10, snappy), in, out, at, table);
    if (len >= 512) return run(class(512, snappy), in, out, at, table);
    return run(class(min_len, snappy), in, out, at, table);
}

inline fn load32(in: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, in[at..][0..4], .little);
}

inline fn load64(in: []const u8, at: usize) u64 {
    return std.mem.readInt(u64, in[at..][0..8], .little);
}

/// S2's hash of the low `bytes` bytes of `v` into `bits` bits.
pub inline fn hash(comptime bytes: u4, comptime bits: u6, v: u64) usize {
    const prime: u64 = switch (bytes) {
        4 => 2654435761,
        5 => 889523592379,
        6 => 227718039650203,
        7 => 58295818150454627,
        8 => 0xcf1bbcdcb7a56463,
        else => @compileError("no S2 hash of that many bytes"),
    };
    const x = if (bytes < 8) v << (64 - 8 * @as(u7, bytes)) else v;
    return @intCast((x *% prime) >> (64 - @as(u7, bits)));
}

/// How many bytes from `a` match those from `b` (`a < b`), to the end.
pub inline fn matchLen(in: []const u8, a: usize, b: usize) usize {
    var n: usize = 0;
    while (b + n + 8 <= in.len) {
        const x = load64(in, a + n) ^ load64(in, b + n);
        if (x != 0) return n + @ctz(x) / 8;
        n += 8;
    }
    while (b + n < in.len and in[a + n] == in[b + n]) n += 1;
    return n;
}

inline fn copy(comptime c: Class, out: []u8, at: usize, offset: usize, len: usize) usize {
    return if (c.snappy) emit.s2CopyNoRepeat(c.max_len, out, at, offset, len) else emit.s2Copy(c.max_len, out, at, offset, len);
}

fn run(comptime c: Class, in: []const u8, out: []u8, at: usize, table_all: []u32) ?usize {
    const table = table_all[0 .. @as(usize, 1) << c.table_bits];
    @memset(table, 0);
    const overhead = comptime emit.literalOverhead(c.max_len);
    const len = in.len;
    const s_limit = len - 8;
    const dst_limit = at + (len - 9 - (len >> 5));
    var o = at;
    var next_emit: usize = 0;
    var s: usize = 1;
    var repeat: usize = 1;
    search: while (true) {
        const next_s = s + ((s - next_emit) >> c.skip_log) + 4;
        if (next_s >= s_limit) break :search;
        var cv = load64(in, s);
        const h0 = hash(c.hash_bytes, c.table_bits, cv);
        const h1 = hash(c.hash_bytes, c.table_bits, cv >> 8);
        var candidate: usize = table[h0];
        const candidate2: usize = table[h1];
        table[h0] = @intCast(s);
        table[h1] = @intCast(s + 1);
        const h2 = hash(c.hash_bytes, c.table_bits, cv >> 16);
        // The last offset, one byte on.
        if (@as(u32, @truncate(cv >> 8)) == load32(in, s - repeat + 1)) {
            var base = s + 1;
            const emitted = next_emit;
            var i = base - repeat;
            while (i != 0 and base > next_emit and in[i - 1] == in[base - 1]) {
                base -= 1;
                i -= 1;
            }
            if (o + (base - next_emit) + overhead >= dst_limit) return null;
            if (base != next_emit) o = emit.literal(out, o, in, next_emit, base - next_emit);
            next_emit = base;
            s += 5;
            s += matchLen(in, s - repeat, s);
            // A repeat once a literal has been written; a copy before.
            o = if (!c.snappy and emitted != 0)
                emit.s2Repeat(c.max_len, out, o, repeat, s - base)
            else
                copy(c, out, o, repeat, s - base);
            next_emit = s;
            continue :search;
        }
        if (load32(in, candidate) != @as(u32, @truncate(cv))) {
            cv >>= 8;
            candidate = table[h2];
            if (load32(in, candidate2) == @as(u32, @truncate(cv))) {
                table[h2] = @intCast(s + 2);
                s += 1;
                candidate = candidate2;
            } else {
                table[h2] = @intCast(s + 2);
                cv >>= 8;
                if (load32(in, candidate) != @as(u32, @truncate(cv))) {
                    s = next_s;
                    continue :search;
                }
                s += 2;
            }
        }
        // A match at `s` from `candidate`: backwards, then forwards.
        while (candidate != 0 and s > next_emit and in[candidate - 1] == in[s - 1]) {
            s -= 1;
            candidate -= 1;
        }
        if (o + (s - next_emit) + overhead >= dst_limit) return null;
        if (s != next_emit) o = emit.literal(out, o, in, next_emit, s - next_emit);
        next_emit = s;
        while (true) {
            repeat = s - candidate;
            s += 4;
            s += matchLen(in, candidate + 4, s);
            const length = s - (candidate + repeat);
            next_emit = s;
            o = copy(c, out, o, repeat, length);
            if (s >= s_limit) break :search;
            const cv2 = load64(in, s - 2);
            if (o >= dst_limit) return null;
            const e0 = hash(c.hash_bytes, c.table_bits, cv2);
            const e1 = hash(c.hash_bytes, c.table_bits, cv2 >> 16);
            candidate = table[e1];
            table[e0] = @intCast(s - 2);
            table[e1] = @intCast(s);
            if (load32(in, candidate) != @as(u32, @truncate(cv2 >> 16))) {
                s += 1;
                continue :search;
            }
        }
    }
    if (o + (len - next_emit) + overhead >= dst_limit) return null;
    if (next_emit != len) o = emit.literal(out, o, in, next_emit, len - next_emit);
    return o;
}

/// S2's index of a dictionary for the default parser (`Dict.initFast`):
/// every third position's three hashes over 6 bytes, 2^14 entries.
pub const dict_table = 1 << 14;

pub fn indexDict(content: []const u8, table: []u16) void {
    @memset(table[0..dict_table], 0);
    var i: usize = 0;
    while (i + 8 + 2 < content.len) : (i += 3) {
        const x = load64(content, i);
        table[hash(6, 14, x)] = @intCast(i);
        table[hash(6, 14, x >> 8)] = @intCast(i + 1);
        table[hash(6, 14, x >> 16)] = @intCast(i + 2);
    }
}

/// How many bytes of `a` from `ai` match `b` from `bi`, eight at a time
/// while `ai <= a_end` and `bi + 8 <= b_end`; Go's loops in S2's
/// dictionary parsers, which stop short of the ends.
inline fn extend8(a: []const u8, ai_in: usize, a_end: usize, b: []const u8, bi_in: usize, b_end: usize) usize {
    var ai = ai_in;
    var bi = bi_in;
    while (ai <= a_end and bi + 8 <= b_end) {
        const diff = load64(a, ai) ^ load64(b, bi);
        if (diff != 0) return ai + @ctz(diff) / 8;
        ai += 8;
        bi += 8;
    }
    return ai;
}

/// S2's default parser with a dictionary (`Dict.Encode`, its Go on every
/// target): while the output may reach the dictionary, its table (made by
/// `indexDict`) is searched beside the input's, and its repeat value is
/// the first repeat; then the input alone, as `encodeBlockGo`. Null where
/// S2 gives up.
pub fn encodeDict(content: []const u8, repeat_at: usize, dtable: []const u16, in: []const u8, out: []u8, at: usize, table: []u32) ?usize {
    @memset(table[0..dict_table], 0);
    var p: DictParser = .{
        .content = content,
        .dtable = dtable,
        .in = in,
        .out = out,
        .table = table[0..dict_table],
        .o = at,
        .repeat = content.len - repeat_at,
        .s_limit = @min(in.len - 8, 65535 - 8),
        .dst_limit = at + in.len - (in.len >> 5) - 5,
        .cv = load64(in, 0),
    };
    return p.run();
}

const any_len = std.math.maxInt(u32);

/// What a step leaves: the next search, the end of a phase, or giving up.
const Next = enum { more, end, give_up };

const DictParser = struct {
    content: []const u8,
    dtable: []const u16,
    in: []const u8,
    out: []u8,
    table: []u32,
    o: usize,
    next_emit: usize = 0,
    s: usize = 0,
    repeat: usize,
    cv: u64,
    s_limit: usize,
    dst_limit: usize,

    fn run(p: *DictParser) ?usize {
        while (true) switch (p.dictStep()) {
            .more => {},
            .end => break,
            .give_up => return null,
        };
        // The dictionary out of reach: the input alone.
        if (p.repeat > p.s) p.repeat = 0;
        p.s_limit = p.in.len - 8;
        if (p.s < p.s_limit) {
            p.cv = load64(p.in, p.s);
            while (true) switch (p.inputStep()) {
                .more => {},
                .end => break,
                .give_up => return null,
            };
        }
        if (p.next_emit >= p.in.len) return p.o;
        if (p.o + p.in.len - p.next_emit > p.dst_limit) return null;
        return emit.literal(p.out, p.o, p.in, p.next_emit, p.in.len - p.next_emit);
    }

    fn literalTo(p: *DictParser, end: usize) void {
        if (end != p.next_emit) p.o = emit.literal(p.out, p.o, p.in, p.next_emit, end - p.next_emit);
    }

    /// One search while the dictionary is in reach.
    fn dictStep(p: *DictParser) Next {
        const in = p.in;
        const content = p.content;
        const table = p.table;
        const s = p.s;
        const cv = p.cv;
        const next_s = s + ((s - p.next_emit) >> 6) + 4;
        const h0 = hash(6, 14, cv);
        const h1 = hash(6, 14, cv >> 8);
        if (next_s > p.s_limit) return .end;
        var cand_dict: usize = p.dtable[h0];
        const cand_dict2: usize = p.dtable[h1];
        const candidate2: usize = table[h1];
        var candidate: usize = table[h0];
        table[h0] = @intCast(s);
        table[h1] = @intCast(s + 1);
        const h2 = hash(6, 14, cv >> 16);
        if (p.repeat > s) {
            if (p.repeat - s >= 4 and @as(u32, @truncate(cv)) == load32(content, content.len - (p.repeat - s))) return p.dictRepeat();
        } else if (p.repeat > 0 and @as(u32, @truncate(cv >> 8)) == load32(in, s - p.repeat + 1)) {
            return p.inputRepeat(false);
        }
        if (s == 0) return p.skipTo(next_s);
        if (@as(u32, @truncate(cv)) == load32(in, candidate)) return p.inputMatch(candidate);
        candidate = table[h2];
        if (@as(u32, @truncate(cv >> 8)) == load32(in, candidate2)) {
            table[h2] = @intCast(s + 2);
            p.s += 1;
            return p.inputMatch(candidate2);
        }
        if (cv == load64(content, cand_dict)) {
            table[h2] = @intCast(s + 2);
            return p.dictMatch(cand_dict);
        }
        cand_dict = p.dtable[h2];
        if (cand_dict2 >= 1 and cv ^ load64(content, cand_dict2 - 1) < 1 << 8) {
            table[h2] = @intCast(s + 2);
            p.s += 1;
            return p.dictMatch(cand_dict2);
        }
        table[h2] = @intCast(s + 2);
        if (@as(u32, @truncate(cv >> 16)) == load32(in, candidate)) {
            p.s += 2;
            return p.inputMatch(candidate);
        }
        if (cand_dict >= 2 and cv ^ load64(content, cand_dict - 2) < 1 << 16) {
            p.s += 2;
            return p.dictMatch(cand_dict);
        }
        return p.skipTo(next_s);
    }

    fn skipTo(p: *DictParser, next_s: usize) Next {
        p.cv = load64(p.in, next_s);
        p.s = next_s;
        return .more;
    }

    /// The repeat value reaching into the dictionary, at `s`.
    fn dictRepeat(p: *DictParser) Next {
        const in = p.in;
        const content = p.content;
        var c = content.len - (p.repeat - p.s);
        var base = p.s;
        var i = c;
        while (base > p.next_emit and i > 0 and content[i - 1] == in[base - 1]) {
            i -= 1;
            base -= 1;
        }
        if (p.o + (base - p.next_emit) > p.dst_limit) return .give_up;
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
        return p.after(s);
    }

    /// The last offset in the input, one byte on (`checked`: the output
    /// limit checked first, as the second phase does).
    fn inputRepeat(p: *DictParser, checked: bool) Next {
        const in = p.in;
        var base = p.s + 1;
        var i = base - p.repeat;
        while (base > p.next_emit and i > 0 and in[i - 1] == in[base - 1]) {
            i -= 1;
            base -= 1;
        }
        if (checked and p.o + (base - p.next_emit) > p.dst_limit) return .give_up;
        p.literalTo(base);
        const s = extend8(in, p.s + 5, p.s_limit, in, p.s - p.repeat + 5, in.len);
        p.o = if (p.next_emit > 0) emit.s2Repeat(any_len, p.out, p.o, p.repeat, s - base) else emit.s2Copy(any_len, p.out, p.o, p.repeat, s - base);
        return p.after(s);
    }

    /// After a repeat: on from `s`, or the phase's end.
    fn after(p: *DictParser, s: usize) Next {
        p.next_emit = s;
        p.s = s;
        if (s >= p.s_limit) return .end;
        p.cv = load64(p.in, s);
        return .more;
    }

    /// A match from the dictionary at `s`: backwards, then forwards.
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
        p.repeat = s + content.len - cand;
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
        if (s <= p.s_limit or s - base < 8) {
            p.o = emit.s2Copy(any_len, p.out, p.o, p.repeat, s - base);
        } else {
            p.o = emit.s2Copy(any_len, p.out, p.o, p.repeat, 4);
            p.o = emit.s2Repeat(any_len, p.out, p.o, p.repeat, s - base - 4);
        }
        p.next_emit = s;
        p.s = s;
        if (s >= p.s_limit) return .end;
        if (p.o > p.dst_limit) return .give_up;
        const x = load64(in, s - 2);
        p.table[hash(6, 14, x)] = @intCast(s - 2);
        p.table[hash(6, 14, x >> 8)] = @intCast(s - 1);
        p.cv = load64(in, s);
        return .more;
    }

    /// A match from the input at `s`: backwards, then copies while the
    /// position after each starts another.
    fn inputMatch(p: *DictParser, cand_in: usize) Next {
        const in = p.in;
        var cand = cand_in;
        var s = p.s;
        while (cand > 0 and s > p.next_emit and in[cand - 1] == in[s - 1]) {
            cand -= 1;
            s -= 1;
        }
        if (p.o + (s - p.next_emit) > p.dst_limit) return .give_up;
        p.literalTo(s);
        while (true) {
            const base = s;
            p.repeat = base - cand;
            s = extend8(in, s + 4, in.len - 8, in, cand + 4, in.len);
            p.o = emit.s2Copy(any_len, p.out, p.o, p.repeat, s - base);
            p.next_emit = s;
            p.s = s;
            if (s >= p.s_limit) return .end;
            if (p.o > p.dst_limit) return .give_up;
            const x = load64(in, s - 2);
            const e0 = hash(6, 14, x);
            const e1 = hash(6, 14, x >> 16);
            cand = p.table[e1];
            p.table[e0] = @intCast(s - 2);
            p.table[e1] = @intCast(s);
            if (@as(u32, @truncate(x >> 16)) != load32(in, cand)) {
                p.cv = load64(in, s + 1);
                p.s = s + 1;
                return .more;
            }
        }
    }

    /// One search with the dictionary out of reach (`encodeBlockGo`).
    fn inputStep(p: *DictParser) Next {
        const in = p.in;
        const table = p.table;
        const s = p.s;
        const cv = p.cv;
        const next_s = s + ((s - p.next_emit) >> 6) + 4;
        if (next_s > p.s_limit) return .end;
        const h0 = hash(6, 14, cv);
        const h1 = hash(6, 14, cv >> 8);
        var candidate: usize = table[h0];
        const candidate2: usize = table[h1];
        table[h0] = @intCast(s);
        table[h1] = @intCast(s + 1);
        const h2 = hash(6, 14, cv >> 16);
        if (p.repeat > 0 and @as(u32, @truncate(cv >> 8)) == load32(in, s - p.repeat + 1)) return p.inputRepeat(true);
        if (@as(u32, @truncate(cv)) == load32(in, candidate)) return p.inputMatch(candidate);
        candidate = table[h2];
        if (@as(u32, @truncate(cv >> 8)) == load32(in, candidate2)) {
            table[h2] = @intCast(s + 2);
            p.s += 1;
            return p.inputMatch(candidate2);
        }
        table[h2] = @intCast(s + 2);
        if (@as(u32, @truncate(cv >> 16)) == load32(in, candidate)) {
            p.s += 2;
            return p.inputMatch(candidate);
        }
        return p.skipTo(next_s);
    }
};
