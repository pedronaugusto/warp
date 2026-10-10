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

/// Build the decoding cells of a table over `2^log` states: each cell, in
/// state order, is made by `make` from its symbol, the bits to read for the
/// next state and that state's base. The symbols are spread first; the cell
/// loop is the only other pass.
fn decodeCells(comptime T: type, comptime Context: type, comptime make: fn (Context, symbol: u8, nb_bits: u8, next_state: u16) T, norm: []const i16, log: u4, cells: []T, context: Context) void {
    const size: u32 = @as(u32, 1) << log;
    var symbols: [512]u8 = undefined;
    spread(norm, log, symbols[0..size]);
    var next: [256]u32 = undefined;
    for (norm, 0..) |n, s| next[s] = if (n == -1) 1 else @intCast(n);
    for (cells[0..size], symbols[0..size]) |*c, s| {
        const n = next[s];
        next[s] = n + 1;
        const nb: u32 = log - std.math.log2_int(u32, n);
        c.* = make(context, s, @intCast(nb), @intCast((n << @intCast(nb)) - size));
    }
}

/// A cell of a sequence-code table: the code's base value and extra bits
/// in place of the symbol, all of it in one 8-byte load.
pub const SeqCell = packed struct(u64) {
    next_state: u16,
    extra_bits: u8,
    nb_bits: u8,
    base: u32,
};

/// What a sequence code adds to a state's symbol: its base value and its
/// extra bits.
const Code = struct {
    base: []const u32,
    extra: []const u8,

    fn cell(code: Code, symbol: u8, nb_bits: u8, next_state: u16) SeqCell {
        return .{ .next_state = next_state, .extra_bits = code.extra[symbol], .nb_bits = nb_bits, .base = code.base[symbol] };
    }
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
            t.log = log;
            decodeCells(SeqCell, Code, Code.cell, norm, log, &t.cells, .{ .base = base, .extra = extra });
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
            t.log = log;
            const Plain = struct {
                fn cell(_: void, symbol: u8, nb_bits: u8, next_state: u16) Cell {
                    return .{ .next_state = next_state, .symbol = symbol, .nb_bits = nb_bits };
                }
            };
            decodeCells(Cell, void, Plain.cell, norm, log, &t.cells, {});
        }
    };
}

// ---- encoding ----

pub const max_table_log = 12;

/// The table log for `total` symbols of values up to `max_symbol`, at most
/// `max`: small inputs get small tables, never too small to hold every
/// symbol.
pub fn optimalLog(max: u4, total: usize, max_symbol: u8, minus: u4) u4 {
    std.debug.assert(total > 1);
    const max_bits_src: i32 = @as(i32, std.math.log2_int(usize, total - 1)) - minus;
    var log: i32 = max;
    const min_bits = minLog(total, max_symbol);
    if (max_bits_src < log) log = max_bits_src;
    if (min_bits > log) log = min_bits;
    if (log < min_log) log = min_log;
    if (log > max_table_log) log = max_table_log;
    return @intCast(log);
}

fn minLog(total: usize, max_symbol: u8) i32 {
    const from_total: i32 = @as(i32, std.math.log2_int(usize, total)) + 1;
    const from_symbols: i32 = @as(i32, std.math.log2_int(u32, @max(max_symbol, 1))) + 2;
    return @min(from_total, from_symbols);
}

pub const NormalizeError = error{Unnormalizable};

/// Counts scaled to sum to `2^log`, each present symbol at least 1 (or
/// -1, "less than one", when `low_probability`), the rounding biased the
/// way the format's reference encoder biases it. `total` is the sum of
/// `counts`; no single symbol may hold all of it.
pub fn normalize(norm: []i16, log: u4, counts: []const u32, total: usize, low_probability: bool) NormalizeError!void {
    const rest_to_beat = [_]u64{ 0, 473195, 504333, 520860, 550000, 700000, 750000, 830000 };
    const low: i16 = if (low_probability) -1 else 1;
    const scale: u6 = 62 - @as(u6, log);
    const unit: u64 = (@as(u64, 1) << 62) / total;
    const v_step: u64 = @as(u64, 1) << (scale - 20);
    var still: i32 = @as(i32, 1) << log;
    var largest: usize = 0;
    var largest_p: i16 = 0;
    const low_threshold: u64 = total >> log;
    for (counts, norm[0..counts.len], 0..) |c, *n, s| {
        std.debug.assert(c != total);
        if (c == 0) {
            n.* = 0;
            continue;
        }
        if (c <= low_threshold) {
            n.* = low;
            still -= 1;
        } else {
            var p: i16 = @intCast((@as(u64, c) * unit) >> scale);
            if (p < 8) {
                const beat = v_step * rest_to_beat[@intCast(p)];
                if (@as(u64, c) * unit - (@as(u64, @intCast(p)) << scale) > beat) p += 1;
            }
            if (p > largest_p) {
                largest_p = p;
                largest = s;
            }
            n.* = p;
            still -= p;
        }
    }
    if (-still >= (norm[largest] >> 1)) {
        try normalizeSlowly(norm, log, counts, total, low);
    } else {
        norm[largest] += @intCast(still);
    }
}

/// The second method, for distributions the first rounds badly.
fn normalizeSlowly(norm: []i16, log: u4, counts: []const u32, total_: usize, low: i16) NormalizeError!void {
    const unassigned: i16 = -2;
    var total = total_;
    var distributed: u32 = 0;
    const low_threshold: u64 = total >> log;
    var low_one: u64 = (@as(u64, total) * 3) >> (@as(u6, log) + 1);
    for (counts, norm[0..counts.len]) |c, *n| {
        if (c == 0) {
            n.* = 0;
        } else if (c <= low_threshold) {
            n.* = low;
            distributed += 1;
            total -= c;
        } else if (c <= low_one) {
            n.* = 1;
            distributed += 1;
            total -= c;
        } else n.* = unassigned;
    }
    var to_distribute: u32 = (@as(u32, 1) << log) - distributed;
    if (to_distribute == 0) return;
    if (total / to_distribute > low_one) {
        low_one = (total * 3) / (to_distribute * 2);
        for (counts, norm[0..counts.len]) |c, *n| {
            if (n.* == unassigned and c <= low_one) {
                n.* = 1;
                distributed += 1;
                total -= c;
            }
        }
        to_distribute = (@as(u32, 1) << log) - distributed;
    }
    if (distributed == counts.len) {
        // Every symbol is rare: the rest goes to the most frequent.
        var max_s: usize = 0;
        var max_c: u32 = 0;
        for (counts, 0..) |c, s| if (c > max_c) {
            max_s = s;
            max_c = c;
        };
        norm[max_s] += @intCast(to_distribute);
        return;
    }
    if (total == 0) {
        var s: usize = 0;
        while (to_distribute > 0) : (s = (s + 1) % counts.len) {
            if (norm[s] > 0) {
                to_distribute -= 1;
                norm[s] += 1;
            }
        }
        return;
    }
    const v_step_log: u6 = 62 - @as(u6, log);
    const mid: u64 = (@as(u64, 1) << (v_step_log - 1)) - 1;
    const r_step: u64 = ((@as(u64, 1) << v_step_log) * to_distribute + mid) / total;
    var tmp_total: u64 = mid;
    for (counts, norm[0..counts.len]) |c, *n| {
        if (n.* != unassigned) continue;
        const end = tmp_total + c * r_step;
        const weight: u32 = @intCast((end >> v_step_log) - (tmp_total >> v_step_log));
        if (weight < 1) return error.Unnormalizable;
        n.* = @intCast(weight);
        tmp_total = end;
    }
}

/// Write a table description: the inverse of `readCounts`. `out` holds at
/// least `countsBound(max_symbol, log)` bytes; returns the bytes written.
pub fn writeCounts(out: []u8, norm: []const i16, log: u4) usize {
    var o: usize = 0;
    const size: i32 = @as(i32, 1) << log;
    var bit_stream: u32 = @as(u32, log) - min_log;
    // Up to 32 bits gather before a flush (16 held, 7 repeat codes, one more).
    var bit_count: u6 = 4;
    var remaining: i32 = size + 1;
    var threshold: i32 = size;
    var nb_bits: u6 = @as(u6, log) + 1;
    var symbol: usize = 0;
    var previous0 = false;
    while (symbol < norm.len and remaining > 1) {
        if (previous0) {
            var start = symbol;
            while (symbol < norm.len and norm[symbol] == 0) symbol += 1;
            std.debug.assert(symbol != norm.len);
            while (symbol >= start + 24) {
                start += 24;
                bit_stream += @as(u32, 0xffff) << @intCast(bit_count);
                out[o] = @truncate(bit_stream);
                out[o + 1] = @truncate(bit_stream >> 8);
                o += 2;
                bit_stream >>= 16;
            }
            while (symbol >= start + 3) {
                start += 3;
                bit_stream += @as(u32, 3) << @intCast(bit_count);
                bit_count += 2;
            }
            bit_stream += @as(u32, @intCast(symbol - start)) << @intCast(bit_count);
            bit_count += 2;
            if (bit_count > 16) {
                out[o] = @truncate(bit_stream);
                out[o + 1] = @truncate(bit_stream >> 8);
                o += 2;
                bit_stream >>= 16;
                bit_count -= 16;
            }
        }
        var count: i32 = norm[symbol];
        symbol += 1;
        const max = (2 * threshold - 1) - remaining;
        remaining -= if (count < 0) -count else count;
        count += 1;
        if (count >= threshold) count += max;
        bit_stream += @as(u32, @intCast(count)) << @intCast(bit_count);
        bit_count += nb_bits;
        if (count < max) bit_count -= 1;
        previous0 = count == 1;
        std.debug.assert(remaining >= 1);
        while (remaining < threshold) {
            nb_bits -= 1;
            threshold >>= 1;
        }
        if (bit_count > 16) {
            out[o] = @truncate(bit_stream);
            out[o + 1] = @truncate(bit_stream >> 8);
            o += 2;
            bit_stream >>= 16;
            bit_count -= 16;
        }
    }
    std.debug.assert(remaining == 1);
    out[o] = @truncate(bit_stream);
    out[o + 1] = @truncate(bit_stream >> 8);
    o += (@as(usize, bit_count) + 7) / 8;
    return o;
}

/// The most bytes `writeCounts` writes.
pub fn countsBound(max_symbol: u8, log: u4) usize {
    return ((@as(usize, max_symbol) + 1) * @as(usize, log) + 4 + 2) / 8 + 1 + 2;
}

/// How a symbol moves the encoder's state.
pub const Transform = struct {
    delta_find_state: i32,
    delta_nb_bits: u32,
};

/// An encoding table: the states in symbol order and each symbol's
/// transform.
pub fn EncodeTable(comptime table_log: u4, comptime max_symbol: u8) type {
    return struct {
        const Self = @This();
        log: u4,
        /// The largest symbol it can encode.
        symbols: u8,
        states: [1 << table_log]u16,
        transforms: [@as(usize, max_symbol) + 1]Transform,

        pub fn build(t: *Self, norm: []const i16, log: u4) void {
            std.debug.assert(log <= table_log);
            std.debug.assert(norm.len <= @as(usize, max_symbol) + 1);
            const size: u32 = @as(u32, 1) << log;
            t.log = log;
            t.symbols = @intCast(norm.len - 1);
            var cumul: [@as(usize, max_symbol) + 2]u32 = undefined;
            cumul[0] = 0;
            for (norm, 1..) |n, u| cumul[u] = cumul[u - 1] + (if (n == -1) 1 else @as(u32, @intCast(n)));
            var symbol_of: [1 << table_log]u8 = undefined;
            spread(norm, log, symbol_of[0..size]);
            for (symbol_of[0..size], 0..) |sym, u| {
                t.states[cumul[sym]] = @intCast(size + u);
                cumul[sym] += 1;
            }
            var total: i32 = 0;
            for (norm, t.transforms[0..norm.len]) |n, *tt| switch (n) {
                0 => tt.* = .{ .delta_find_state = 0, .delta_nb_bits = ((@as(u32, log) + 1) << 16) - size },
                -1, 1 => {
                    tt.* = .{ .delta_find_state = total - 1, .delta_nb_bits = (@as(u32, log) << 16) - size };
                    total += 1;
                },
                else => {
                    const c: u32 = @intCast(n);
                    const max_bits_out: u32 = log - std.math.log2_int(u32, c - 1);
                    const min_state_plus = c << @intCast(max_bits_out);
                    tt.* = .{ .delta_find_state = total - @as(i32, n), .delta_nb_bits = (max_bits_out << 16) - min_state_plus };
                    total += n;
                },
            };
        }

        /// One state, every symbol `symbol`: the table of an RLE mode.
        pub fn rle(t: *Self, symbol: u8) void {
            t.log = 0;
            t.symbols = symbol;
            t.states[0] = 0;
            t.states[1] = 0;
            for (&t.transforms) |*tt| tt.* = .{ .delta_find_state = 0, .delta_nb_bits = 0 };
        }

        /// The cost of `symbol` in 1/256 bits, approximately; `null` for a
        /// symbol the table cannot encode.
        pub fn bitCost(t: *const Self, symbol: u8) ?u32 {
            if (symbol > t.symbols) return null;
            const accuracy = 8;
            const tt = t.transforms[symbol];
            const min_bits: i64 = tt.delta_nb_bits >> 16;
            const threshold: i64 = (min_bits + 1) << 16;
            const size: i64 = @as(i64, 1) << t.log;
            const delta = threshold - (@as(i64, tt.delta_nb_bits) + size);
            const normalized = (delta << accuracy) >> t.log;
            const cost = (min_bits + 1) * (1 << accuracy) - normalized;
            // A symbol of probability 0 (or any of an RLE table) costs at
            // least a table log and a bit: it cannot be coded at all.
            const bad = (@as(i64, t.log) + 1) << accuracy;
            if (cost >= bad or cost < 0) return null;
            return @intCast(cost);
        }

        /// The state of a stream that ends with `symbol`.
        pub fn initState(t: *const Self, symbol: u8) u32 {
            const tt = t.transforms[symbol];
            const nb_bits_out = (tt.delta_nb_bits + (1 << 15)) >> 16;
            const value = (nb_bits_out << 16) -% tt.delta_nb_bits;
            return t.states[@intCast(@as(i32, @intCast(value >> @intCast(nb_bits_out))) + tt.delta_find_state)];
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

test "a table cannot price a symbol it has no state for, nor any symbol of an RLE table" {
    // Counts over symbols 0-3 with symbol 2 absent: a block that needs
    // symbol 2 cannot repeat this table (it once could, and decoded wrong).
    var t: EncodeTable(9, 52) = undefined;
    const norm = [_]i16{ 20, 10, 0, 2 };
    t.build(&norm, 5);
    try std.testing.expect(t.bitCost(0) != null);
    try std.testing.expect(t.bitCost(3) != null);
    try std.testing.expectEqual(@as(?u32, null), t.bitCost(2));
    try std.testing.expectEqual(@as(?u32, null), t.bitCost(4));
    // The cost of a frequent symbol is below one of a rare one.
    try std.testing.expect(t.bitCost(0).? < t.bitCost(3).?);
    t.rle(1);
    try std.testing.expectEqual(@as(?u32, null), t.bitCost(1));
}

test "descriptions that break the rules are refused" {
    var counts: Counts = undefined;
    // A log above 15.
    try std.testing.expectError(error.InvalidStream, readCounts(&.{ 0x0f, 0, 0, 0 }, 255, &counts));
    // Counts that do not add up before the input ends.
    try std.testing.expectError(error.InvalidStream, readCounts(&.{0x00}, 255, &counts));
}
