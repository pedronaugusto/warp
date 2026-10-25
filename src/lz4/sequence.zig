//! What every LZ4 parser writes: tokens, lengths, literals and offsets,
//! the format's end-of-block rules, and the match counter.

const std = @import("std");

pub const min_match = 4;
/// The last bytes of a block are literals.
pub const last_literals = 5;
/// The last match starts at least this far before a block's end.
pub const mf_limit = 12;
/// A shorter input is written as literals.
pub const min_length = mf_limit + 1;
pub const max_offset = 65535;
const run_mask = 15;

/// The longest block `len` bytes compress to: lz4's `LZ4_compressBound`.
pub fn bound(len: usize) usize {
    return len + len / 255 + 16;
}

/// How a parser treats the end of its output.
pub const Directive = enum {
    /// The output holds `bound(len)`.
    unlimited,
    /// A block that does not fit is refused.
    limited,
    /// As much of the input as fits is written (lz4's `destSize`).
    fill,
};

/// What a call wrote: input taken and output written.
pub const Written = struct { in_len: usize, out_len: usize };

/// The equal bytes at the start of `a` and `b`, at most `a.len`.
pub inline fn countMatch(a: []const u8, b: []const u8) usize {
    var n: usize = 0;
    // The first word apart, as lz4's `LZ4_count`: most candidates differ
    // inside it, and then no loop is entered.
    if (a.len >= 8) {
        const x = std.mem.readInt(u64, a[0..8], .little) ^ std.mem.readInt(u64, b[0..8], .little);
        if (x != 0) return @ctz(x) / 8;
        n = 8;
    }
    while (n + 8 <= a.len) : (n += 8) {
        const x = std.mem.readInt(u64, a[n..][0..8], .little) ^ std.mem.readInt(u64, b[n..][0..8], .little);
        if (x != 0) return n + @ctz(x) / 8;
    }
    while (n < a.len and a[n] == b[n]) n += 1;
    return n;
}

/// The output being written.
pub const Out = struct {
    buf: []u8,
    pos: usize = 0,

    pub inline fn left(o: *const Out) usize {
        return o.buf.len - o.pos;
    }

    /// A token holding the literal length, its extra bytes and the
    /// literals; returns the token's position.
    pub inline fn literals(o: *Out, lits: []const u8) usize {
        const token = o.pos;
        o.pos += 1;
        if (lits.len >= run_mask) {
            o.buf[token] = run_mask << 4;
            o.lengthBytes(lits.len - run_mask);
        } else o.buf[token] = @intCast(lits.len << 4);
        @memcpy(o.buf[o.pos..][0..lits.len], lits);
        o.pos += lits.len;
        return token;
    }

    /// As `literals` for `src[anchor..ip]`, copied in 8-byte steps that may
    /// read up to 7 bytes past `ip` and write as far past the literals:
    /// for a sequence with a match, after which the input holds the last
    /// literals and the output a match and the last sequence, 8 bytes and
    /// more, so both stay inside their buffers.
    pub inline fn literalsBefore(o: *Out, src: []const u8, anchor: usize, ip: usize) usize {
        std.debug.assert(ip + 7 < src.len);
        const len = ip - anchor;
        const token = o.pos;
        o.pos += 1;
        if (len >= run_mask) {
            o.buf[token] = run_mask << 4;
            o.lengthBytes(len - run_mask);
        } else o.buf[token] = @intCast(len << 4);
        std.debug.assert(o.pos + len + 8 <= o.buf.len);
        const to = o.buf[o.pos..].ptr;
        const from = src[anchor..].ptr;
        var i: usize = 0;
        while (i < len) : (i += 8) to[i..][0..8].* = from[i..][0..8].*;
        o.pos += len;
        return token;
    }

    pub inline fn offset(o: *Out, distance: u16) void {
        std.mem.writeInt(u16, o.buf[o.pos..][0..2], distance, .little);
        o.pos += 2;
    }

    /// The match length's token field and extra bytes: `code` is the
    /// length less `min_match`.
    pub inline fn matchLength(o: *Out, token: usize, code: usize) void {
        if (code >= run_mask) {
            o.buf[token] += run_mask;
            o.lengthBytes(code - run_mask);
        } else o.buf[token] += @intCast(code);
    }

    /// A length's bytes past its token field: `n / 255` bytes of 255, then
    /// the rest. The 255s go four at a step, as lz4 writes them, which may
    /// write three bytes past the last; a length is always followed by
    /// literals or by the last sequence, so they stay inside the output and
    /// are written over. Each step stores eight, so the loop is no `memset`
    /// call, whose saved registers would cost every sequence.
    inline fn lengthBytes(o: *Out, length: usize) void {
        var n = length;
        while (n >= 4 * 255) : (n -= 4 * 255) {
            o.buf[o.pos..][0..8].* = @splat(255);
            o.pos += 4;
        }
        o.buf[o.pos..][0..4].* = @splat(255);
        o.pos += n / 255;
        o.buf[o.pos] = @intCast(n % 255);
        o.pos += 1;
    }

    /// The bytes literals take with their token and length bytes.
    pub fn literalsCost(len: usize) usize {
        return 1 + len + (len + 255 - run_mask) / 255;
    }

    /// The last sequence: the literals from `anchor` to the end, or as many
    /// as fit for `.fill`; null for `.limited` when they do not fit. The
    /// input taken counts from `begin`, where the parse started.
    pub fn last(o: *Out, comptime directive: Directive, src: []const u8, anchor: usize, begin: usize) ?Written {
        var run = src.len - anchor;
        if (directive != .unlimited and o.pos + literalsCost(run) > o.buf.len) {
            if (directive == .limited) return null;
            run = o.buf.len - o.pos - 1;
            run -= (run + 256 - run_mask) / 256;
        }
        _ = o.literals(src[anchor..][0..run]);
        return .{ .in_len = anchor + run - begin, .out_len = o.pos };
    }
};

test "a bound holds the input as one literal run" {
    var buf: [600]u8 = undefined;
    var o: Out = .{ .buf = &buf };
    const src: [500]u8 = @splat(7);
    const w = o.last(.limited, &src, 0, 0).?;
    try std.testing.expectEqual(@as(usize, 500), w.in_len);
    try std.testing.expect(w.out_len <= bound(500));
    try std.testing.expectEqual(Out.literalsCost(500), w.out_len);
}
