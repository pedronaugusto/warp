//! A GDeflate page decoded on the CPU: DEFLATE's blocks over Deflate64's
//! alphabet, their bits dealt across 32 lanes.
//!
//! Each lane reads through a 64-bit buffer that holds at least 32 bits
//! between symbols: the page opens with each lane's first 32-bit word in
//! lane order, and after each symbol a lane holding fewer than 32 bits takes
//! the next word of the page. A block's header is on lane 0; precode lengths
//! and code-length items go round-robin from lane 0. Data goes in rounds of
//! one symbol a lane: a lane that decodes a length decodes that match's
//! distance on its next turn, and the match's bytes are copied then, into
//! the place the length reserved. The end of the block ends the litlen
//! symbols; one more pass copies the matches still pending. A stored block
//! is a 16-bit length on lane 0, then its bytes round-robin.
//!
//! A pending match's bytes are always copied from output already written:
//! its source lies before its own place, and every other pending match's
//! place lies after it. So no input reads bytes the decoder has not written,
//! and the answer never depends on what the output held before.
const std = @import("std");
const huffman = @import("../huffman.zig");
const inflate = @import("../inflate.zig");
const Diagnostic = @import("Diagnostic.zig");

const decode = huffman.decode;

pub const lanes = 32;

pub const Error = error{
    /// The page breaks GDeflate's rules.
    InvalidStream,
    /// The page ended inside a block: a lane needed a word past its end.
    Truncated,
    /// The page decodes to more than the output holds.
    OutputTooSmall,
};

/// The tables a block's codes decode through, and its code lengths: the
/// DEFLATE engine's, at Deflate64's sizes.
pub const Tables = inflate.TablesFor(true);

/// The lanes' bits and the page.
const Reader = struct {
    in: []const u8,
    /// The next 32-bit word of the page.
    ip: usize = 0,
    buf: [lanes]u64 = @splat(0),
    left: [lanes]u8 = @splat(0),
    lane: u5 = 0,
    diagnostic: ?*Diagnostic,
    /// Where the page starts in the input a diagnostic counts from.
    base: u64,

    /// Give the lane 32 bits or more: the next word when it holds fewer.
    inline fn ensure(r: *Reader, lane: u5) Error!void {
        if (r.left[lane] >= 32) return;
        if (r.in.len - r.ip < 4) return r.fail(.truncated);
        r.buf[lane] |= @as(u64, std.mem.readInt(u32, r.in[r.ip..][0..4], .little)) << @intCast(r.left[lane]);
        r.left[lane] += 32;
        r.ip += 4;
    }

    /// The current lane's next `n` bits, consumed. Every caller takes at
    /// most 31 bits between `ensure`s, so they are there.
    inline fn pop(r: *Reader, n: u6) u32 {
        const lane = r.lane;
        // safe: n <= 31
        const v: u32 = @truncate(r.buf[lane] & ((@as(u64, 1) << n) - 1));
        r.buf[lane] >>= n;
        r.left[lane] -= n;
        return v;
    }

    /// The current lane's next symbol through `table`, consumed with its
    /// extra bits: the entry and the extra bits' value. A codeword with no
    /// symbol is refused.
    inline fn symbol(r: *Reader, table: []const u32, bits: u5) Error!struct { entry: u32, extra: u32 } {
        const lane = r.lane;
        const buf = r.buf[lane];
        var e = table[@as(usize, @truncate(buf & ((@as(u64, 1) << bits) - 1)))];
        var main: u6 = 0;
        if (e & decode.subtable_flag != 0) {
            main = bits;
            e = table[decode.value(e) + @as(usize, @truncate((buf >> bits) & ((@as(u64, 1) << decode.codeword(e)) - 1)))];
        }
        if (e & decode.exceptional != 0 and e & decode.end_flag == 0) return r.fail(.bad_symbol);
        const code = main + decode.codeword(e);
        const all = main + decode.consumed(e);
        // safe: all <= 31
        const extra: u32 = @truncate((buf & ((@as(u64, 1) << all) - 1)) >> code);
        r.buf[lane] = buf >> all;
        r.left[lane] -= all;
        return .{ .entry = e, .extra = extra };
    }

    /// Ensure the current lane, then go on to the next.
    inline fn advance(r: *Reader) Error!void {
        try r.ensure(r.lane);
        r.lane +%= 1;
    }

    fn fail(r: *Reader, reason: Diagnostic.Reason) Error {
        if (r.diagnostic) |d| d.* = .{ .tile = d.tile, .offset = .fromRaw(r.base + r.ip), .reason = reason };
        return if (reason == .truncated) error.Truncated else error.InvalidStream;
    }
};

/// A match whose distance its lane decodes on its next turn.
const Pending = struct { at: u32, len: u32 };

const precode_order = [19]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

/// Decode the page `in` into `out`; the bytes written. The page's blocks
/// must end with its final block within `out`. Bytes after the final block
/// are not read.
pub fn page(t: *Tables, in: []const u8, out: []u8, diagnostic: ?*Diagnostic, base: u64) Error!usize {
    var r: Reader = .{ .in = in, .diagnostic = diagnostic, .base = base };
    for (0..lanes) |lane| try r.ensure(@intCast(lane));
    var op: usize = 0;
    var pending: [lanes]Pending = undefined;
    // Bit `i`: lane `i` has a match waiting for its distance.
    var waiting: u32 = 0;
    while (true) {
        r.lane = 0;
        const final = r.pop(1) != 0;
        const kind = r.pop(2);
        try r.ensure(0);
        var litlen: []const u32 = &decode.Fixed(.litlen64).table;
        var lbits: u5 = decode.Fixed(.litlen64).bits;
        var dist: []const u32 = &decode.Fixed(.dist64).table;
        var dbits: u5 = decode.Fixed(.dist64).bits;
        switch (kind) {
            0 => {
                const len = r.pop(16);
                if (len > out.len - op) return error.OutputTooSmall;
                for (out[op..][0..len]) |*b| {
                    b.* = @intCast(r.pop(8));
                    try r.advance();
                }
                op += len;
            },
            1 => {},
            2 => {
                const bits = try header(&r, t);
                litlen = &t.litlen;
                lbits = bits[0];
                dist = &t.dist;
                dbits = bits[1];
            },
            else => return r.fail(.bad_block_type),
        }
        if (kind != 0) {
            r.lane = 0;
            while (true) {
                const bit = @as(u32, 1) << r.lane;
                if (waiting & bit != 0) {
                    try copy(&r, out, pending[r.lane], dist, dbits);
                    waiting &= ~bit;
                } else {
                    const s = try r.symbol(litlen, lbits);
                    if (s.entry & decode.literal_flag != 0) {
                        if (op == out.len) return error.OutputTooSmall;
                        out[op] = @truncate(decode.value(s.entry));
                        op += 1;
                    } else if (s.entry & decode.end_flag != 0) {
                        break;
                    } else {
                        const len = decode.value(s.entry) + s.extra;
                        if (len > out.len - op) return error.OutputTooSmall;
                        pending[r.lane] = .{ .at = @intCast(op), .len = len };
                        waiting |= bit;
                        op += len;
                    }
                }
                try r.advance();
            }
        }
        // One more pass: the matches still waiting, each on its lane's turn.
        for (0..lanes) |_| {
            const bit = @as(u32, 1) << r.lane;
            if (waiting & bit != 0) {
                try copy(&r, out, pending[r.lane], dist, dbits);
                waiting &= ~bit;
            }
            try r.advance();
        }
        if (final) return op;
    }
}

/// A dynamic block's header after its three bits: the counts on lane 0,
/// precode lengths and then code lengths round-robin, and the tables: their
/// main tables' bits.
fn header(r: *Reader, t: *Tables) Error![2]u5 {
    const hlit = r.pop(5) + 257;
    const hdist = r.pop(5) + 1;
    const hclen = r.pop(4) + 4;
    if (hlit > 286) return r.fail(.too_many_codes);
    try r.ensure(0);
    t.pre = @splat(0);
    for (precode_order[0..hclen]) |sym| {
        t.pre[sym] = @intCast(r.pop(3));
        try r.advance();
    }
    const pre_bits = decode.build(.precode, &t.precode, &t.pre, &decode.countLengths(&t.pre)) catch |err| return r.fail(codeReason(err));
    r.lane = 0;
    const total = hlit + hdist;
    const lens = &t.lens;
    var i: usize = 0;
    while (i < total) {
        const lane = r.lane;
        const e = t.precode[@as(usize, @truncate(r.buf[lane] & ((@as(u64, 1) << pre_bits) - 1)))];
        // An empty precode decodes every bit as symbol 0, one bit long, as
        // zlib's and the DEFLATE engine's do.
        const sym: u32 = if (e & decode.exceptional != 0) 0 else decode.value(e);
        _ = r.pop(decode.consumed(e));
        if (sym < 16) {
            lens[i] = @intCast(sym);
            i += 1;
        } else {
            const repeat: usize = switch (sym) {
                16 => 3 + r.pop(2),
                17 => 3 + r.pop(3),
                else => 11 + r.pop(7),
            };
            const fill: u8 = if (sym == 16) blk: {
                if (i == 0) return r.fail(.bad_code_lengths);
                break :blk lens[i - 1];
            } else 0;
            if (i + repeat > total) return r.fail(.bad_code_lengths);
            @memset(lens[i..][0..repeat], fill);
            i += repeat;
        }
        try r.advance();
    }
    if (lens[256] == 0) return r.fail(.no_end_code);
    const lbits = decode.build(.litlen64, &t.litlen, lens[0..hlit], &decode.countLengths(lens[0..hlit])) catch |err| return r.fail(codeReason(err));
    const dbits = decode.build(.dist64, &t.dist, lens[hlit..total], &decode.countLengths(lens[hlit..total])) catch |err| return r.fail(codeReason(err));
    return .{ lbits, dbits };
}

/// A waiting match: its distance from the current lane, then its bytes.
inline fn copy(r: *Reader, out: []u8, p: Pending, dist: []const u32, dbits: u5) Error!void {
    const s = try r.symbol(dist, dbits);
    const distance = decode.value(s.entry) + s.extra;
    if (distance > p.at) return r.fail(.distance_too_far);
    const dst = out[p.at..][0..p.len];
    const from = p.at - distance;
    if (distance >= p.len) {
        @memcpy(dst, out[from..][0..p.len]);
    } else {
        // The match overlaps its own bytes: a byte at a time, each read
        // after the one `distance` before it is written.
        for (dst, from..) |*b, k| b.* = out[k];
    }
}

fn codeReason(err: huffman.decode.BuildError) Diagnostic.Reason {
    return switch (err) {
        error.Oversubscribed => .oversubscribed_code,
        error.Incomplete => .incomplete_code,
    };
}
