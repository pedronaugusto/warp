//! Decoding tables for DEFLATE's Huffman codes, built from code lengths as
//! zlib 1.3.1's `inflate_table` accepts them.
//!
//! A table is indexed by the next `bits` bits of the stream (least
//! significant first). Codes no longer than that fill every entry whose low
//! bits are their codeword; longer codes go through a subtable that the
//! main entry points to. `bits` is the longest code length, capped per
//! alphabet, so a block whose codes are short builds a small table.
//!
//! An entry is a u32:
//!
//!   bit  31     literal (litlen tables only)
//!   bit  15     exceptional: a subtable pointer, the end of block, or an
//!               invalid code
//!   bit  14     subtable pointer
//!   bit  13     end of block
//!   bits 16-31  the value: a literal byte, a length or distance base, a
//!               precode symbol, or the subtable's start
//!   bits 8-11   the codeword's length (a pointer: the subtable's bits)
//!   bits 0-4    the bits to consume: codeword plus extra bits (a pointer:
//!               the main table's bits)
//!
//! so one shift by the low byte consumes a length's or distance's codeword
//! and extra bits together, and the extra bits are what was consumed above
//! the codeword.

const std = @import("std");

pub const literal_flag: u32 = 1 << 31;
pub const exceptional: u32 = 1 << 15;
pub const subtable_flag: u32 = 1 << 14;
pub const end_flag: u32 = 1 << 13;

/// The bits an entry consumes.
pub inline fn consumed(e: u32) u6 {
    // Bits 5-7 are zero: the low six bits are the field, and a shift by them
    // needs no mask.
    return @truncate(e);
}

/// The codeword's length within an entry's consumed bits.
pub inline fn codeword(e: u32) u6 {
    // safe: the field is four bits
    return @truncate((e >> 8) & 15);
}

/// The extra bits' value: what `saved` held above the codeword.
pub inline fn extra(saved: u64, e: u32) u32 {
    // safe: at most 13 extra bits
    return @truncate((saved & ((@as(u64, 1) << consumed(e)) - 1)) >> codeword(e));
}

/// The entry's value.
pub inline fn value(e: u32) u32 {
    return e >> 16;
}

/// Which code a table decodes.
pub const Alphabet = enum {
    /// The code-length code: symbols 0-18.
    precode,
    /// Literals 0-255, end of block 256, lengths 257-285; 286 and 287 are
    /// invalid in data.
    litlen,
    /// Distances 0-29; 30 and 31 are invalid in data.
    dist,

    pub fn size(a: Alphabet) usize {
        return switch (a) {
            .precode => 19,
            .litlen => 288,
            .dist => 32,
        };
    }

    /// The most main-table bits.
    pub fn maxBits(a: Alphabet) u5 {
        return switch (a) {
            .precode => 7,
            .litlen => 11,
            .dist => 8,
        };
    }

    /// The entries a table can need: the main table and every subtable
    /// (zlib's `enough` for these sizes).
    pub fn enough(a: Alphabet) usize {
        return switch (a) {
            .precode => 128,
            .litlen => 2342,
            .dist => 402,
        };
    }
};

pub const length_base = [29]u16{ 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 15, 17, 19, 23, 27, 31, 35, 43, 51, 59, 67, 83, 99, 115, 131, 163, 195, 227, 258 };
pub const length_extra = [29]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 0 };
pub const dist_base = [30]u16{ 1, 2, 3, 4, 5, 7, 9, 13, 17, 25, 33, 49, 65, 97, 129, 193, 257, 385, 513, 769, 1025, 1537, 2049, 3073, 4097, 6145, 8193, 12289, 16385, 24577 };
pub const dist_extra = [30]u8{ 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 6, 7, 7, 8, 8, 9, 9, 10, 10, 11, 11, 12, 12, 13, 13 };

/// The entry for an invalid code of `len` bits.
pub fn invalid(len: u32) u32 {
    return exceptional | (len << 8) | len;
}

/// `sym`'s entry for a codeword of `len` bits.
fn symbolEntry(comptime alphabet: Alphabet, sym: usize, len: u32) u32 {
    switch (alphabet) {
        .precode => return (@as(u32, @intCast(sym)) << 16) | (len << 8) | len,
        .litlen => {
            if (sym < 256) return literal_flag | (@as(u32, @intCast(sym)) << 16) | (len << 8) | len;
            if (sym == 256) return exceptional | end_flag | (len << 8) | len;
            if (sym < 286) {
                const i = sym - 257;
                return (@as(u32, length_base[i]) << 16) | (len << 8) | (len + length_extra[i]);
            }
            return invalid(len);
        },
        .dist => {
            if (sym < 30) return (@as(u32, dist_base[sym]) << 16) | (len << 8) | (len + dist_extra[sym]);
            return invalid(len);
        },
    }
}

/// Why lengths were refused, by zlib's rules.
pub const BuildError = error{
    /// More codes than the lengths allow.
    Oversubscribed,
    /// Fewer, other than a single one-bit code (or none) for literals and
    /// distances; any for the precode.
    Incomplete,
};

/// How many lengths of each value 0-15.
pub fn countLengths(lens: []const u8) [16]u16 {
    var count: [16]u16 = @splat(0);
    for (lens) |l| count[l] += 1;
    return count;
}

/// Build `table` for the code with lengths `lens` (`count` is
/// `countLengths(lens)`); returns the main table's bits.
///
/// A code with no symbols at all decodes every bit pattern as invalid,
/// one bit long, as zlib's does; a single one-bit litlen or distance code
/// is accepted and its other bit pattern is invalid.
pub fn build(comptime alphabet: Alphabet, table: []u32, lens: []const u8, count_in: *const [16]u16) BuildError!u5 {
    var count = count_in.*;
    count[0] = 0;
    var max: u5 = 0;
    for (1..16) |l| {
        if (count[l] != 0) max = @intCast(l);
    }
    if (max == 0) {
        table[0] = invalid(1);
        table[1] = invalid(1);
        return 1;
    }
    var left: i32 = 1;
    for (1..16) |l| {
        left <<= 1;
        left -= count[l];
        if (left < 0) return error.Oversubscribed;
    }
    const bits: u5 = @min(max, alphabet.maxBits());
    if (left > 0) {
        if (alphabet == .precode or max != 1) return error.Incomplete;
        // A single one-bit code: its codeword is 0.
        const sym = std.mem.findScalar(u8, lens, 1).?;
        table[0] = symbolEntry(alphabet, sym, 1);
        table[1] = invalid(1);
        return 1;
    }
    buildComplete(alphabet, table, lens, &count, bits);
    return bits;
}

/// The symbols in canonical order, shortest code first, then by value.
fn canonicalOrder(lens: []const u8, count: *const [16]u16, sorted: []u16) void {
    var offset: [16]u16 = undefined;
    offset[1] = 0;
    for (2..16) |l| offset[l] = offset[l - 1] + count[l - 1];
    for (lens, 0..) |l, sym| {
        if (l == 0) continue;
        sorted[offset[l]] = @intCast(sym);
        offset[l] += 1;
    }
}

/// A complete code. Codewords are taken in canonical order, held
/// bit-reversed as the decoder reads them; the next is the reversed
/// increment of the last. A code of `len` bits is written once into a
/// table `1 << len` long, which is doubled with a copy of itself on the way
/// to the next length, so each code fills every entry whose low `len` bits
/// are its codeword. Codes longer than `bits` go into subtables after the
/// main table, each as small as the codes behind its prefix allow (zlib's
/// rule): those codes come next in canonical order and fill it exactly.
fn buildComplete(comptime alphabet: Alphabet, table: []u32, lens: []const u8, count: *const [16]u16, bits: u5) void {
    var sorted_buf: [288]u16 = undefined;
    const sorted = sorted_buf[0..lens.len];
    canonicalOrder(lens, count, sorted);
    const main_len = @as(usize, 1) << bits;
    var next: usize = 0;
    var codeword_rev: usize = 0;
    var len: usize = 1;
    var remaining: u16 = count[1];
    while (remaining == 0) {
        len += 1;
        remaining = count[len];
    }
    var table_end: usize = @as(usize, 1) << @intCast(@min(len, bits));
    while (len <= bits) {
        while (remaining != 0) : (remaining -= 1) {
            table[codeword_rev] = symbolEntry(alphabet, sorted[next], @intCast(len));
            next += 1;
            if (codeword_rev == table_end - 1) {
                // The last code, all ones: the rest is copies.
                while (table_end < main_len) : (table_end <<= 1) {
                    @memcpy(table[table_end..][0..table_end], table[0..table_end]);
                }
                return;
            }
            const bit = @as(usize, 1) << std.math.log2_int(usize, codeword_rev ^ (table_end - 1));
            codeword_rev = (codeword_rev & (bit - 1)) | bit;
        }
        while (true) {
            len += 1;
            if (len <= bits) {
                @memcpy(table[table_end..][0..table_end], table[0..table_end]);
                table_end <<= 1;
            }
            remaining = count[len];
            if (remaining != 0) break;
        }
    }
    table_end = main_len;
    var sub_prefix: usize = std.math.maxInt(usize);
    var sub_start: usize = 0;
    while (true) {
        const prefix = codeword_rev & (main_len - 1);
        if (prefix != sub_prefix) {
            sub_prefix = prefix;
            sub_start = table_end;
            var sub_bits: usize = len - bits;
            var used: usize = remaining;
            while (used < (@as(usize, 1) << @intCast(sub_bits))) {
                sub_bits += 1;
                used = (used << 1) + count[bits + sub_bits];
            }
            table_end = sub_start + (@as(usize, 1) << @intCast(sub_bits));
            table[prefix] = exceptional | subtable_flag | (@as(u32, @intCast(sub_start)) << 16) | (@as(u32, @intCast(sub_bits)) << 8) | bits;
        }
        const e = symbolEntry(alphabet, sorted[next], @intCast(len - bits));
        next += 1;
        var i = sub_start + (codeword_rev >> bits);
        while (i < table_end) : (i += @as(usize, 1) << @intCast(len - bits)) table[i] = e;
        const all_ones = (@as(usize, 1) << @intCast(len)) - 1;
        if (codeword_rev == all_ones) return;
        const bit = @as(usize, 1) << std.math.log2_int(usize, codeword_rev ^ all_ones);
        codeword_rev = (codeword_rev & (bit - 1)) | bit;
        remaining -= 1;
        while (remaining == 0) {
            len += 1;
            remaining = count[len];
        }
    }
}

/// A table for the fixed codes, built at compile time.
pub fn Fixed(comptime alphabet: Alphabet) type {
    return struct {
        pub const bits: u5 = if (alphabet == .litlen) 9 else 5;
        pub const table: [1 << bits]u32 = blk: {
            @setEvalBranchQuota(100_000);
            var lens: [alphabet.size()]u8 = undefined;
            if (alphabet == .litlen) {
                @memset(lens[0..144], 8);
                @memset(lens[144..256], 9);
                @memset(lens[256..280], 7);
                @memset(lens[280..288], 8);
            } else @memset(&lens, 5);
            var t: [1 << bits]u32 = undefined;
            // unreachable: the fixed lengths are complete codes
            const got = build(alphabet, &t, &lens, &countLengths(&lens)) catch unreachable;
            std.debug.assert(got == bits);
            break :blk t;
        };
    };
}

const testing = std.testing;

/// The symbol at `codeword` (most significant bit first) of `len` bits, by
/// walking the table as the decoder does.
fn lookup(table: []const u32, bits: u5, code: usize, len: usize) u32 {
    var rev: u64 = 0;
    for (0..len) |i| rev |= @as(u64, (code >> @intCast(len - 1 - i)) & 1) << @intCast(i);
    var e = table[@as(usize, @truncate(rev & ((@as(u64, 1) << bits) - 1)))];
    if (e & subtable_flag != 0) {
        const sub_bits = codeword(e);
        e = table[value(e) + @as(usize, @truncate((rev >> bits) & ((@as(u64, 1) << sub_bits) - 1)))];
    }
    return e;
}

test "the fixed tables decode every fixed code to its symbol" {
    const lit = Fixed(.litlen);
    // 'A' is 0x30 + 65 in eight bits; 256 is seven zero bits; 285 is 0xc5.
    try testing.expectEqual(@as(u32, 'A'), value(lookup(&lit.table, lit.bits, 0x30 + 'A', 8)) & 0xff);
    try testing.expect(lookup(&lit.table, lit.bits, 0x30 + 'A', 8) & literal_flag != 0);
    try testing.expect(lookup(&lit.table, lit.bits, 0, 7) & end_flag != 0);
    try testing.expectEqual(@as(u32, 258), value(lookup(&lit.table, lit.bits, 0xc5, 8)));
    try testing.expectEqual(@as(u32, 255), value(lookup(&lit.table, lit.bits, 0x190 + 111, 9)) & 0xff);
    // 286 and 287 are codes, but invalid ones.
    try testing.expect(lookup(&lit.table, lit.bits, 0xc6, 8) & (exceptional | end_flag | subtable_flag) == exceptional);
    const dist = Fixed(.dist);
    try testing.expectEqual(@as(u32, 24577), value(lookup(&dist.table, dist.bits, 29, 5)));
    try testing.expect(lookup(&dist.table, dist.bits, 30, 5) & exceptional != 0);
}

test "a code with subtables decodes every symbol, and lengths are refused as zlib refuses them" {
    // 256 is one bit, symbol i is i + 2 bits for i < 14, and 14 is 15 bits:
    // a complete code that needs subtables past 11 bits.
    var lens: [288]u8 = @splat(0);
    lens[256] = 1;
    for (0..14) |i| lens[i] = @intCast(i + 2);
    lens[14] = 15;
    var table: [Alphabet.litlen.enough()]u32 = undefined;
    const bits = try build(.litlen, &table, &lens, &countLengths(&lens));
    try testing.expectEqual(@as(u5, 11), bits);
    // Canonical codes: 256 is "0", symbol i (i + 2 bits) is i + 1 ones and a
    // zero, and symbol 14 is fifteen ones.
    try testing.expect(lookup(&table, bits, 0, 1) & end_flag != 0);
    for (0..14) |i| {
        const len = i + 2;
        const code = ((@as(usize, 1) << @intCast(len)) - 1) - 1;
        try testing.expectEqual(@as(u32, @intCast(i)), value(lookup(&table, bits, code, len)) & 0xff);
    }
    try testing.expectEqual(@as(u32, 14), value(lookup(&table, bits, (1 << 15) - 1, 15)) & 0xff);

    var over: [288]u8 = @splat(0);
    over[0] = 1;
    over[1] = 1;
    over[256] = 1;
    try testing.expectError(error.Oversubscribed, build(.litlen, &table, &over, &countLengths(&over)));
    var two: [288]u8 = @splat(0);
    two[0] = 2;
    two[256] = 2;
    try testing.expectError(error.Incomplete, build(.litlen, &table, &two, &countLengths(&two)));
    var one: [32]u8 = @splat(0);
    one[3] = 1;
    try testing.expectEqual(@as(u5, 1), try build(.dist, &table, &one, &countLengths(&one)));
    var pre: [19]u8 = @splat(0);
    pre[18] = 1;
    try testing.expectError(error.Incomplete, build(.precode, &table, &pre, &countLengths(&pre)));
}
