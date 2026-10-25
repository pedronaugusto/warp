//! Brotli's prefix codes as decoding tables: a root of 2^8 entries indexed
//! by the next 8 bits, and a second-level table for each root entry whose
//! codes are longer. Each entry is 16 bits: its length in the low 4 and its
//! symbol (or, for a root entry that points to a second-level table, that
//! table's offset) in the high 12. Every alphabet has at most 1,128 symbols
//! and every table at most 1,504 entries, so both fit.
//!
//! The tables are built the way the format's reference builds them, so a
//! table for an alphabet of `n` symbols never takes more than `n + 376`
//! entries (`maxEntries`).

const std = @import("std");
const bits_ = @import("bits.zig");
const Reader = bits_.Reader;
const NeedInput = bits_.NeedInput;

pub const Entry = u16;

pub const root_bits = 8;
pub const max_length = 15;

/// The most entries a table for `alphabet` symbols takes.
pub fn maxEntries(alphabet: usize) usize {
    return alphabet + 376;
}

inline fn entry(len: u32, value: u32) Entry {
    std.debug.assert(len <= max_length);
    std.debug.assert(value < 1 << 12);
    return @intCast(len | value << 4);
}

/// Decode one symbol from the table at `table[0..]`. Fast mode reads with
/// 15 bits loaded; careful mode reads what the input has and fails only if
/// the symbol's code is longer.
pub inline fn decode(r: *Reader, comptime careful: bool, table: [*]const Entry) NeedInput!u32 {
    if (careful) r.fillAvailable(max_length) else try r.fill(false, max_length);
    const b = r.buf;
    var e = table[@as(u8, @truncate(b))];
    var len: u32 = e & 15;
    if (len > root_bits) {
        if (careful and r.count <= root_bits) return error.NeedInput;
        const sub: u32 = @intCast((b >> root_bits) & ((@as(u64, 1) << @intCast(len - root_bits)) - 1));
        e = table[(e >> 4) + sub];
        len = root_bits + (e & 15);
    }
    if (careful and len > r.count) return error.NeedInput;
    r.drop(len);
    return e >> 4;
}

/// The table width of the next second-level table, the reference's rule:
/// as wide as the codes still to place that share its prefix need.
fn nextTableBits(count: *const [max_length + 1]u16, first_len: u32) u32 {
    var len = first_len;
    var left: i32 = @as(i32, 1) << @intCast(len - root_bits);
    while (len < max_length) {
        left -= count[len];
        if (left <= 0) break;
        len += 1;
        left <<= 1;
    }
    return len - root_bits;
}

inline fn reverse(key: u32) u32 {
    return @bitReverse(@as(u8, @intCast(key)));
}

fn replicate(table: []Entry, step: usize, end: usize, e: Entry) void {
    var at = end;
    while (true) {
        at -= step;
        table[at] = e;
        if (at == 0) break;
    }
}

/// The longest alphabet: a large-window stream's distances.
pub const max_alphabet = 1128;

/// The symbols of a code by length: `links[l]` (1 to 15) is the first
/// symbol of length `l`, `links[16 + s]` the next of `s`'s length, in
/// symbol order, `count[l]` of each.
pub const Links = [max_length + 1 + max_alphabet]u16;

/// Build the table of a complete code whose symbols `links` lists by
/// length into `table`, which holds `maxEntries` of its alphabet's
/// entries; `count` is cleared. Returns the entries used.
pub fn build(table: []Entry, links: *const Links, count: *[max_length + 1]u16) usize {
    var longest: u32 = max_length;
    while (count[longest] == 0) longest -= 1;

    var table_bits: u32 = @min(root_bits, longest);
    var table_size: usize = @as(usize, 1) << @intCast(table_bits);
    var total: usize = 1 << root_bits;
    var key: u32 = 0;
    var key_step: u32 = 1 << (root_bits - 1);
    var step: usize = 2;
    var len: u32 = 1;
    while (len <= table_bits) : (len += 1) {
        var at: usize = len;
        for (0..count[len]) |_| {
            const symbol = links[at];
            at = max_length + 1 + @as(usize, symbol);
            replicate(table[reverse(key)..], step, table_size, entry(len, symbol));
            key += key_step;
        }
        step <<= 1;
        key_step >>= 1;
    }
    // A root narrower than 8 bits is repeated to fill 2^8 entries.
    while (table_size != total) {
        @memcpy(table[table_size..][0..table_size], table[0..table_size]);
        table_size <<= 1;
    }
    // The second-level tables, each pointed to from one root entry.
    key_step = 1;
    var sub_key: u32 = 1 << root_bits;
    var sub_key_step: u32 = 1 << (root_bits - 1);
    var used: usize = 0;
    len = root_bits + 1;
    step = 2;
    while (len <= longest) : (len += 1) {
        var at: usize = len;
        while (count[len] != 0) : (count[len] -= 1) {
            if (sub_key == 1 << root_bits) {
                used += table_size;
                table_bits = nextTableBits(count, len);
                table_size = @as(usize, 1) << @intCast(table_bits);
                total += table_size;
                const root = reverse(key);
                key += key_step;
                table[root] = entry(table_bits + root_bits, @intCast(used));
                sub_key = 0;
            }
            const symbol = links[at];
            at = max_length + 1 + @as(usize, symbol);
            replicate(table[used + reverse(sub_key) ..], step, table_size, entry(len - root_bits, symbol));
            sub_key += sub_key_step;
        }
        step <<= 1;
        sub_key_step >>= 1;
    }
    @memset(count, 0);
    return total;
}

/// `links` and `count` for code lengths in symbol order (tests).
pub fn linksOf(lengths: []const u8, links: *Links, count: *[max_length + 1]u16) void {
    var tails: [max_length + 1]usize = undefined;
    for (&tails, 0..) |*tail, l| tail.* = l;
    @memset(count, 0);
    for (lengths, 0..) |l, symbol| if (l != 0) {
        links[tails[l]] = @intCast(symbol);
        tails[l] = max_length + 1 + symbol;
        count[l] += 1;
    };
}

/// Build the table of a simple prefix code: `symbols[0..n]` (distinct; n
/// 1-4) with the format's fixed lengths; `four_lengths` picks lengths
/// 1, 2, 3, 3 over 2, 2, 2, 2 for four symbols. Returns the entries used.
pub fn buildSimple(table: []Entry, symbols: []const u16, four_lengths: bool) usize {
    var s: [4]u16 = undefined;
    @memcpy(s[0..symbols.len], symbols);
    var size: usize = 1;
    switch (symbols.len) {
        1 => table[0] = entry(0, s[0]),
        2 => {
            table[0] = entry(1, @min(s[0], s[1]));
            table[1] = entry(1, @max(s[0], s[1]));
            size = 2;
        },
        3 => {
            table[0] = entry(1, s[0]);
            table[2] = entry(1, s[0]);
            table[1] = entry(2, @min(s[1], s[2]));
            table[3] = entry(2, @max(s[1], s[2]));
            size = 4;
        },
        4 => if (!four_lengths) {
            std.mem.sort(u16, &s, {}, std.sort.asc(u16));
            table[0] = entry(2, s[0]);
            table[2] = entry(2, s[1]);
            table[1] = entry(2, s[2]);
            table[3] = entry(2, s[3]);
            size = 4;
        } else {
            const lo = @min(s[2], s[3]);
            const hi = @max(s[2], s[3]);
            for ([_]Entry{ entry(1, s[0]), entry(2, s[1]), entry(1, s[0]), entry(3, lo), entry(1, s[0]), entry(2, s[1]), entry(1, s[0]), entry(3, hi) }, 0..) |e, i| table[i] = e;
            size = 8;
        },
        else => unreachable,
    }
    while (size != 1 << root_bits) : (size <<= 1) @memcpy(table[size..][0..size], table[0..size]);
    return 1 << root_bits;
}

/// The code length code's table: 32 entries indexed by the next 5 bits,
/// from the 18 lengths (0-5) the header gave in symbol order. One symbol
/// with a length makes a code of no bits.
pub fn buildCodeLengths(table: *[32]Entry, lengths: *const [18]u8, count: *const [6]u16) void {
    var sorted: [18]u16 = undefined;
    var offset: [7]u16 = undefined;
    offset[1] = 0;
    for (1..6) |len| offset[len + 1] = offset[len] + count[len];
    var used: usize = 0;
    for (lengths, 0..) |len, symbol| if (len != 0) {
        sorted[offset[len]] = @intCast(symbol);
        offset[len] += 1;
        used += 1;
    };
    if (used == 1) {
        @memset(table, entry(0, sorted[0]));
        return;
    }
    var key: u32 = 0;
    var key_step: u32 = 1 << 7;
    var symbol: usize = 0;
    var step: usize = 2;
    for (1..6) |len| {
        for (0..count[len]) |_| {
            replicate(table[reverse(key)..], step, 32, entry(@intCast(len), sorted[symbol]));
            symbol += 1;
            key += key_step;
        }
        step <<= 1;
        key_step >>= 1;
    }
}

test "a complete code decodes each symbol by its canonical code" {
    // Lengths 1, 2, 3, 3: codes 0, 10, 110, 111 (read least significant bit
    // first: 0b0, 0b01, 0b011, 0b111).
    const lengths = [_]u8{ 1, 2, 3, 3 };
    var count: [max_length + 1]u16 = undefined;
    var links: Links = undefined;
    linksOf(&lengths, &links, &count);
    var table: [maxEntries(4)]Entry = undefined;
    try std.testing.expectEqual(256, build(&table, &links, &count));
    const in = [_]u8{ 0b1101_1010, 0b0000_0001 } ++ @as([32]u8, @splat(0));
    var r: Reader = .{ .in = &in };
    for ([_]u32{ 0, 1, 2, 3, 0 }) |want| try std.testing.expectEqual(want, try decode(&r, false, &table));
}

test "codes longer than the root use second-level tables" {
    // One symbol of each length 1..14 and two of length 15.
    var lengths: [16]u8 = undefined;
    for (0..14) |i| lengths[i] = @intCast(i + 1);
    lengths[14] = 15;
    lengths[15] = 15;
    var count: [max_length + 1]u16 = undefined;
    var links: Links = undefined;
    linksOf(&lengths, &links, &count);
    var table: [maxEntries(16)]Entry = undefined;
    const used = build(&table, &links, &count);
    try std.testing.expect(used <= maxEntries(16));
    // Symbol 13's code is thirteen ones then a zero; read LSB first.
    const code: u64 = (1 << 13) - 1;
    var in: [40]u8 = @splat(0);
    std.mem.writeInt(u64, in[0..8], code, .little);
    var r: Reader = .{ .in = &in };
    try std.testing.expectEqual(13, try decode(&r, false, &table));
    try std.testing.expectEqual(14, r.bitOffset());
}
