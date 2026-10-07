//! Finite State Entropy (tANS) for the decoder: the normalized counts a
//! table is described by, read from a forward bitstream exactly as the
//! format's reference decoder reads them, and the decoding tables built
//! from them: one kind for sequence codes (each state carries its code's
//! base value and extra bits) and one for plain symbols (Huffman weights).
//!
//! The default tables for literal lengths, match lengths and offsets are
//! built at compile time.

const std = @import("std");
const codes = @import("codes.zig");

/// The largest table log a description may state before its use's limit
/// is applied.
pub const absolute_max_log = 15;
pub const min_log = 5;

pub const ReadError = error{InvalidStream};

/// Counts read from a table description.
pub const Counts = struct {
    /// Indexed by symbol; -1 is the "less than one" probability.
    norm: [256]i16,
    max_symbol: u8,
    log: u4,
    /// Bytes of the description.
    len: usize,
};

/// Read a table description from the start of `in`: at most
/// `max_symbol + 1` symbols, a log of at most `absolute_max_log` (the
/// caller applies its own limit).
pub fn readCounts(in: []const u8, max_symbol: u8, counts: *Counts) ReadError!void {
    if (in.len < 8) {
        // The reader below needs eight bytes: the description is read from
        // a zero-padded copy, and may not reach into the padding.
        var buffer: [8]u8 = @splat(0);
        @memcpy(buffer[0..in.len], in);
        try readCounts(&buffer, max_symbol, counts);
        if (counts.len > in.len) return error.InvalidStream;
        return;
    }
    const symbols: u32 = @as(u32, max_symbol) + 1;
    @memset(counts.norm[0..symbols], 0);
    var ip: usize = 0;
    const iend = in.len;
    var bit_stream: u32 = std.mem.readInt(u32, in[0..4], .little);
    var nb_bits: u5 = @intCast((bit_stream & 0xf) + min_log);
    if (nb_bits > absolute_max_log) return error.InvalidStream;
    bit_stream >>= 4;
    var bit_count: u32 = 4;
    counts.log = @intCast(nb_bits);
    var remaining: i32 = (@as(i32, 1) << nb_bits) + 1;
    var threshold: i32 = @as(i32, 1) << nb_bits;
    nb_bits += 1;
    var charnum: u32 = 0;
    var previous0 = false;
    while (true) {
        if (previous0) {
            // Two-bit repeat codes, each 0b11 adding three zero counts.
            var repeats: u32 = @ctz(~bit_stream | 0x8000_0000) >> 1;
            while (repeats >= 12) {
                charnum += 3 * 12;
                if (ip + 7 <= iend) {
                    ip += 3;
                } else {
                    bit_count -%= @intCast(8 * (iend - 7 - ip));
                    bit_count &= 31;
                    ip = iend - 4;
                }
                bit_stream = std.mem.readInt(u32, in[ip..][0..4], .little) >> @intCast(bit_count);
                repeats = @ctz(~bit_stream | 0x8000_0000) >> 1;
            }
            charnum += 3 * repeats;
            bit_stream >>= @intCast(2 * repeats);
            bit_count += 2 * repeats;
            charnum += bit_stream & 3;
            bit_count += 2;
            if (charnum >= symbols) break;
            if (ip + 7 <= iend or ip + (bit_count >> 3) + 4 <= iend) {
                ip += bit_count >> 3;
                bit_count &= 7;
            } else {
                bit_count -%= @intCast(8 * (iend - 4 - ip));
                bit_count &= 31;
                ip = iend - 4;
            }
            bit_stream = std.mem.readInt(u32, in[ip..][0..4], .little) >> @intCast(bit_count);
        }
        const max: i32 = (2 * threshold - 1) - remaining;
        var count: i32 = undefined;
        const low_mask: u32 = @intCast(threshold - 1);
        if (@as(i64, bit_stream & low_mask) < max) {
            count = @intCast(bit_stream & low_mask);
            bit_count += nb_bits - 1;
        } else {
            count = @intCast(bit_stream & @as(u32, @intCast(2 * threshold - 1)));
            if (count >= threshold) count -= max;
            bit_count += nb_bits;
        }
        count -= 1;
        if (count >= 0) remaining -= count else remaining += count;
        counts.norm[charnum] = @intCast(count);
        charnum += 1;
        previous0 = count == 0;
        if (remaining < threshold) {
            if (remaining <= 1) break;
            nb_bits = @intCast(std.math.log2_int(u32, @intCast(remaining)) + 1);
            threshold = @as(i32, 1) << (nb_bits - 1);
        }
        if (charnum >= symbols) break;
        if (ip + 7 <= iend or ip + (bit_count >> 3) + 4 <= iend) {
            ip += bit_count >> 3;
            bit_count &= 7;
        } else {
            bit_count -%= @intCast(8 * (iend - 4 - ip));
            bit_count &= 31;
            ip = iend - 4;
        }
        bit_stream = std.mem.readInt(u32, in[ip..][0..4], .little) >> @intCast(bit_count);
    }
    if (remaining != 1) return error.InvalidStream;
    if (charnum > symbols) return error.InvalidStream;
    if (bit_count > 32) return error.InvalidStream;
    counts.max_symbol = @intCast(charnum - 1);
    counts.len = ip + ((bit_count + 7) >> 3);
}

/// The table's step between the positions of one symbol.
pub inline fn step(size: u32) u32 {
    return (size >> 1) + (size >> 3) + 3;
}

/// Lay the symbols of `norm` over a table of `2^log` cells as the format
/// spreads them; `symbols[cell]` receives each cell's symbol. Symbols of
/// count -1 take the last cells, highest first.
fn spread(norm: []const i16, log: u4, symbols: []u8) void {
    const size: u32 = @as(u32, 1) << log;
    const mask = size - 1;
    var high: u32 = size - 1;
    for (norm, 0..) |n, s| if (n == -1) {
        symbols[high] = @intCast(s);
        high -%= 1;
    };
    var position: u32 = 0;
    const st = step(size);
    for (norm, 0..) |n, s| {
        var i: i32 = 0;
        while (i < n) : (i += 1) {
            symbols[position] = @intCast(s);
            position = (position + st) & mask;
            while (position > high) position = (position + st) & mask;
        }
    }
}

/// One decoded cell: its symbol, the bits to read for the next state, and
/// the next state's base.
const Decoded = struct { symbol: u8, nb_bits: u8, next_state: u16 };

/// Spread the symbols, then give each cell the state that follows it, from
/// the order in which each symbol's cells occur.
fn decodeCells(norm: []const i16, log: u4, cells: []Decoded) void {
    const size: u32 = @as(u32, 1) << log;
    var symbols: [512]u8 = undefined;
    spread(norm, log, symbols[0..size]);
    var next: [256]u32 = undefined;
    for (norm, 0..) |n, s| next[s] = if (n == -1) 1 else @intCast(n);
    for (cells[0..size], symbols[0..size]) |*c, s| {
        const n = next[s];
        next[s] += 1;
        const nb: u32 = log - std.math.log2_int(u32, n);
        c.* = .{ .symbol = s, .nb_bits = @intCast(nb), .next_state = @intCast((n << @intCast(nb)) - size) };
    }
}

/// A cell of a sequence-code table: the code's base value and extra bits
/// in place of the symbol, all of it in one 8-byte load.
pub const SeqCell = extern struct {
    next_state: u16,
    extra_bits: u8,
    nb_bits: u8,
    base: u32,
};

/// A decoding table for one of the three sequence codes.
pub fn SeqTable(comptime max_log: u4) type {
    return struct {
        const Self = @This();
        cells: [1 << max_log]SeqCell,
        log: u4,

        /// Build from counts; `base` and `extra` describe the code.
        pub fn build(t: *Self, norm: []const i16, log: u4, base: []const u32, extra: []const u8) void {
            std.debug.assert(log <= max_log);
            var decoded: [1 << max_log]Decoded = undefined;
            decodeCells(norm, log, &decoded);
            t.log = log;
            for (t.cells[0 .. @as(usize, 1) << log], decoded[0 .. @as(usize, 1) << log]) |*c, d| {
                c.* = .{ .next_state = d.next_state, .extra_bits = extra[d.symbol], .nb_bits = d.nb_bits, .base = base[d.symbol] };
            }
        }

        /// A table of one state: every sequence has code `symbol`.
        pub fn rle(t: *Self, symbol: u8, base: []const u32, extra: []const u8) void {
            t.log = 0;
            t.cells[0] = .{ .next_state = 0, .extra_bits = extra[symbol], .nb_bits = 0, .base = base[symbol] };
        }
    };
}

pub const LlTable = SeqTable(codes.max_ll_log);
pub const MlTable = SeqTable(codes.max_ml_log);
pub const OfTable = SeqTable(codes.max_of_log);

fn defaultTable(comptime T: type, comptime norm: []const i16, comptime log: u4, comptime base: []const u32, comptime extra: []const u8) T {
    @setEvalBranchQuota(100_000);
    var t: T = undefined;
    t.build(norm, log, base, extra);
    return t;
}

pub const ll_default: LlTable = defaultTable(LlTable, &codes.ll_default, codes.ll_default_log, &codes.ll_base, &codes.ll_bits);
pub const ml_default: MlTable = defaultTable(MlTable, &codes.ml_default, codes.ml_default_log, &codes.ml_base, &codes.ml_bits);
pub const of_default: OfTable = defaultTable(OfTable, &codes.of_default, codes.of_default_log, &codes.of_base, &codes.of_bits);

/// A cell of a plain symbol table.
pub const Cell = extern struct {
    next_state: u16,
    symbol: u8,
    nb_bits: u8,
};

/// A decoding table of plain symbols, at most `2^max_log` cells.
pub fn Table(comptime max_log: u4) type {
    return struct {
        const Self = @This();
        cells: [1 << max_log]Cell,
        log: u4,

        pub fn build(t: *Self, norm: []const i16, log: u4) void {
            std.debug.assert(log <= max_log);
            var decoded: [1 << max_log]Decoded = undefined;
            decodeCells(norm, log, &decoded);
            t.log = log;
            for (t.cells[0 .. @as(usize, 1) << log], decoded[0 .. @as(usize, 1) << log]) |*c, d| {
                c.* = .{ .next_state = d.next_state, .symbol = d.symbol, .nb_bits = d.nb_bits };
            }
        }
    };
}

test "the default tables are the format's: cells from its published tables" {
    // The reference decoder's static default tables: literal-length state
    // 0 is code 0 with 4 bits and next base 0, state 1 the same with next
    // base 16, state 63 code 32 (base 8192, 13 extra bits) with 6 bits.
    try std.testing.expectEqual(@as(u4, 6), ll_default.log);
    try std.testing.expectEqual(SeqCell{ .next_state = 0, .extra_bits = 0, .nb_bits = 4, .base = 0 }, ll_default.cells[0]);
    try std.testing.expectEqual(SeqCell{ .next_state = 16, .extra_bits = 0, .nb_bits = 4, .base = 0 }, ll_default.cells[1]);
    try std.testing.expectEqual(SeqCell{ .next_state = 32, .extra_bits = 0, .nb_bits = 5, .base = 1 }, ll_default.cells[2]);
    try std.testing.expectEqual(SeqCell{ .next_state = 0, .extra_bits = 13, .nb_bits = 6, .base = 8192 }, ll_default.cells[63]);
    // Offsets: state 1 is code 6 (offset base 61), state 31 code 24.
    try std.testing.expectEqual(SeqCell{ .next_state = 0, .extra_bits = 6, .nb_bits = 4, .base = 61 }, of_default.cells[1]);
    try std.testing.expectEqual(SeqCell{ .next_state = 16, .extra_bits = 7, .nb_bits = 4, .base = 125 }, of_default.cells[15]);
    try std.testing.expectEqual(SeqCell{ .next_state = 0, .extra_bits = 24, .nb_bits = 5, .base = 16777213 }, of_default.cells[31]);
    try std.testing.expectEqual(@as(u32, 3), ml_default.cells[0].base);
}

test "descriptions that break the rules are refused" {
    var counts: Counts = undefined;
    // A log above 15.
    try std.testing.expectError(error.InvalidStream, readCounts(&.{ 0x0f, 0, 0, 0 }, 255, &counts));
    // Counts that do not add up before the input ends.
    try std.testing.expectError(error.InvalidStream, readCounts(&.{0x00}, 255, &counts));
}
