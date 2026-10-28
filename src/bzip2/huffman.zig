//! A bzip2 code table: the format reference's (libbz2 1.0.8) limits, bases
//! and permutation, made as `BZ2_hbCreateDecodeTables` makes them, so a
//! code decodes, or is refused, exactly as there whatever its lengths
//! (1.0.8 checks no code for completeness); and a 10-bit root table that
//! replays its decode loop for every codeword of up to 10 bits, so most
//! symbols take one lookup.

const std = @import("std");
const bits_ = @import("bits.zig");

/// The longest codeword.
pub const max_len = 20;
/// Symbols: 256 byte values in use at most, RUNA, RUNB and the end.
pub const max_alpha = 258;
pub const root_bits = 10;

/// 1.0.8's `BZ_MAX_CODE_LEN`: the limits' and bases' length.
const code_lens = 23;

/// A root entry: the symbol above, the codeword's length below; a length
/// of 0 sends the decode to the bit-at-a-time loop, `refused` refuses it.
const Entry = u16;
const len_bits = 5;
const refused: Entry = 31;

pub const Table = struct {
    root: [1 << root_bits]Entry,
    limit: [code_lens]i32,
    base: [code_lens]i32,
    perm: [max_alpha]u16,
    min_len: u32,
    alpha: u32,

    /// The table for `lens` (each 1-20), one per symbol.
    pub fn build(t: *Table, lens: []const u8) void {
        const alpha = lens.len;
        var min: u32 = 32;
        var max: u32 = 0;
        for (lens) |l| {
            min = @min(min, l);
            max = @max(max, l);
        }
        t.min_len = min;
        t.alpha = @intCast(alpha);
        var pp: usize = 0;
        for (min..max + 1) |i| for (lens, 0..) |l, j| {
            if (l == i) {
                t.perm[pp] = @intCast(j);
                pp += 1;
            }
        };
        t.base = @splat(0);
        for (lens) |l| t.base[l + 1] += 1;
        for (1..code_lens) |i| t.base[i] += t.base[i - 1];
        t.limit = @splat(0);
        var vec: i32 = 0;
        for (min..max + 1) |i| {
            vec += t.base[i + 1] - t.base[i];
            t.limit[i] = vec - 1;
            vec <<= 1;
        }
        for (min + 1..max + 1) |i| t.base[i] = ((t.limit[i - 1] + 1) << 1) - t.base[i];
        for (&t.root, 0..) |*e, v| {
            e.* = 0;
            var zn = min;
            while (zn <= root_bits) : (zn += 1) {
                const zvec: i32 = @intCast(v >> @intCast(root_bits - zn));
                if (zvec <= t.limit[zn]) {
                    e.* = if (t.symbol(zn, zvec)) |s| (s << len_bits) | @as(Entry, @intCast(zn)) else refused;
                    break;
                }
            }
        }
    }

    /// The symbol of codeword `zvec` of `zn` bits; null where 1.0.8 refuses
    /// it, or where it names an entry past the alphabet, which 1.0.8 leaves
    /// to whatever its permutation held (warp refuses it).
    inline fn symbol(t: *const Table, zn: u32, zvec: i32) ?u16 {
        const index = zvec - t.base[zn];
        if (index < 0 or index >= t.alpha) return null;
        return t.perm[@intCast(index)];
    }

    /// The next symbol: `NeedInput` where the input ends first, null where
    /// the codeword is refused.
    pub inline fn decode(t: *const Table, r: *bits_.Reader) bits_.NeedInput!?u16 {
        if (r.n < root_bits) r.refill();
        const e = t.root[r.peek(root_bits)];
        const len = e & ((1 << len_bits) - 1);
        if (len != 0 and len <= r.n) {
            if (len == refused) return null;
            r.drop(len);
            return e >> len_bits;
        }
        if (len != 0 and len != refused) return error.NeedInput;
        return t.slow(r);
    }

    /// 1.0.8's loop, a bit at a time from the shortest length.
    fn slow(t: *const Table, r: *bits_.Reader) bits_.NeedInput!?u16 {
        var zn = t.min_len;
        try r.need(zn);
        var zvec: i32 = @intCast(r.peek(zn));
        while (true) {
            if (zn > max_len) return null;
            if (zvec <= t.limit[zn]) break;
            zn += 1;
            try r.need(zn);
            zvec = @intCast(r.peek(zn));
        }
        const s = t.symbol(zn, zvec) orelse return null;
        r.drop(zn);
        return s;
    }
};

test "codes decode as 1.0.8's loop reads them, through the root table and past it" {
    // A complete code with lengths 1 to 12 and two of 12.
    var lens: [13]u8 = undefined;
    for (0..12) |i| lens[i] = @intCast(i + 1);
    lens[12] = 12;
    var t: Table = undefined;
    t.build(&lens);
    // Symbol k < 12 has k ones and a zero; symbol 12, twelve ones.
    var buf: [4]u8 = undefined;
    for (0..13) |k| {
        const code: u32 = if (k < 12) ((@as(u32, 1) << @intCast(k)) - 1) << 1 else if (k == 12) 0xfff else 0;
        const len: u5 = @intCast(if (k < 12) k + 1 else 12);
        const word: u32 = if (k == 12) 0xfff else code;
        std.mem.writeInt(u32, &buf, word << @intCast(32 - @as(u6, len)), .big);
        var r: bits_.Reader = .{ .in = &buf };
        try std.testing.expectEqual(@as(?u16, @intCast(k)), try t.decode(&r));
        try std.testing.expectEqual(@as(u64, len), r.bitOffset());
    }
    // Twelve ones then a 0 is symbol 11; the input ending first needs more.
    var r: bits_.Reader = .{ .in = &.{0xff} };
    try std.testing.expectError(error.NeedInput, t.decode(&r));
}
