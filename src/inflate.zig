//! The DEFLATE (RFC 1951) decode engine: block headers, code tables, and
//! the loops that turn symbols into bytes, on the caller's output buffer.
//!
//! Most of a stream decodes in the fast loop, which runs while sixteen
//! input bytes and `margin` output bytes remain: it refills its 64-bit bit
//! buffer with one unaligned load, decodes up to three symbols per refill,
//! consumes a length's or distance's codeword and extra bits with one
//! shift, and copies matches sixteen bytes at a time (overshooting by up to
//! fifteen bytes, inside the margin). Near either end a careful loop takes
//! one symbol at a time and checks every bound.
//!
//! Acceptance is zlib 1.3.1's, and so is the order in which bits are asked
//! for: past the end of the input the engine reads zero bits, and a stream
//! whose decoding consumed any of them is `Truncated`, never another error;
//! an error found in bits the input has is `InvalidStream`. So every prefix
//! of a valid stream is `Truncated`, and a stream zlib refuses is refused
//! for the same reason at the same point.

const std = @import("std");
const huffman = @import("huffman.zig").decode;
const Diagnostic = @import("Diagnostic.zig");

const literal_flag = huffman.literal_flag;
const exceptional = huffman.exceptional;
const subtable_flag = huffman.subtable_flag;
const end_flag = huffman.end_flag;

/// The longest match, plus the most a sixteen-byte copy writes past it.
pub const margin = 258 + 16;

/// The input a round of the fast loop may read: two refills (one before a
/// distance when the bits run short, or one for a subtable, and one at the
/// end), each eight bytes from at most seven past the last.
const fast_input = 7 + 8 + 1;

/// Decoding tables for one block at a time: about 11 KiB.
pub const Tables = struct {
    litlen: [huffman.Alphabet.litlen.enough()]u32 = undefined,
    dist: [huffman.Alphabet.dist.enough()]u32 = undefined,
    precode: [huffman.Alphabet.precode.enough()]u32 = undefined,
};

pub const Error = error{
    /// The stream breaks DEFLATE's rules (zlib's reading of them).
    InvalidStream,
    /// The input ended inside the stream.
    Truncated,
    /// The stream decodes to more than the output holds.
    OutputTooSmall,
};

/// How a call ended.
pub const Status = enum {
    /// The final block ended.
    done,
    /// The output is full and the stream goes on (partial decoding only).
    output_full,
};

/// Input that can grow: a reader's buffer, refilled as the engine asks.
/// A slice has no more.
pub const no_more: NoMore = .{};

pub const NoMore = struct {
    pub fn more(_: NoMore, _: *Stream) bool {
        return false;
    }
};

/// One raw DEFLATE stream being decoded: where it is in the input and the
/// output.
pub const Stream = struct {
    in: []const u8,
    /// The next input byte to load. Past `in.len` when zero bytes stand for
    /// input that does not exist.
    ip: usize,
    bitbuf: u64 = 0,
    /// How many of `bitbuf`'s low bits are loaded and not consumed.
    bitsleft: u32 = 0,
    /// Zero bytes loaded past the end of the input. They sit above every
    /// real bit, so consuming one of their bits leaves `bitsleft` below
    /// `8 * virtual`.
    virtual: u32 = 0,
    /// Input bytes before `in`: what a reader gave earlier.
    in_base: u64 = 0,
    out: []u8,
    op: usize,
    /// Where this stream's output starts in `out`: a distance may reach
    /// back to here, and then into `dictionary`.
    start: usize,
    /// Bytes that precede the output as history.
    dictionary: []const u8 = &.{},
    /// Stop without error when the output is full.
    partial: bool = false,
    diagnostic: ?*Diagnostic = null,

    /// Bits consumed since the start of the input.
    pub fn bitOffset(s: *const Stream) u64 {
        return (s.in_base + s.ip) * 8 - s.bitsleft;
    }

    /// Whether the bits consumed so far are all real.
    fn whole(s: *const Stream) bool {
        return s.bitsleft >= 8 * s.virtual;
    }

    /// Refuse the stream: `Truncated` if it consumed bits past the end of
    /// the input, else `InvalidStream` for `reason`.
    pub fn fail(s: *Stream, reason: Diagnostic.Reason) Error {
        const truncated = !s.whole();
        if (s.diagnostic) |d| d.* = .{
            .bit_offset = if (truncated) (s.in_base + s.ip - s.virtual) * 8 else s.bitOffset(),
            .reason = if (truncated) .truncated else reason,
        };
        return if (truncated) error.Truncated else error.InvalidStream;
    }

    /// `fail` from inside the fast loop, whose position lives in locals.
    fn failAt(s: *Stream, reason: Diagnostic.Reason, ip: usize, bitsleft: u32) Error {
        s.ip = ip;
        s.bitsleft = bitsleft;
        return s.fail(reason);
    }

    /// `Truncated` if the stream consumed bits past the end of the input.
    pub fn checkWhole(s: *Stream) Error!void {
        if (!s.whole()) return s.fail(.truncated);
    }

    pub inline fn consume(s: *Stream, n: u6) void {
        s.bitbuf >>= n;
        s.bitsleft -= n;
    }

    /// The low `n` bits.
    pub inline fn peek(s: *const Stream, n: u6) u32 {
        // safe: at most 32 bits asked for
        return @truncate(s.bitbuf & ((@as(u64, 1) << n) - 1));
    }

    /// At least `n` bits in hand (`n` <= 56): real ones while the input has
    /// them, zeros after.
    pub inline fn need(s: *Stream, source: anytype, n: u32) void {
        if (s.bitsleft >= n) return;
        if (s.ip + 8 <= s.in.len) {
            s.bitbuf |= std.mem.readInt(u64, s.in[s.ip..][0..8], .little) << @intCast(s.bitsleft);
            s.ip += (63 - s.bitsleft) >> 3;
            s.bitsleft |= 56;
            return;
        }
        s.needSlow(source, n);
    }

    /// `need` near the end of the input: a byte at a time, more from the
    /// source, then zeros.
    fn needSlow(s: *Stream, source: anytype, n: u32) void {
        while (s.bitsleft < n) {
            if (s.ip >= s.in.len and s.virtual == 0 and source.more(s)) continue;
            const byte: u64 = if (s.ip < s.in.len) s.in[s.ip] else blk: {
                s.virtual += 1;
                break :blk 0;
            };
            s.bitbuf |= byte << @intCast(s.bitsleft);
            s.ip += 1;
            s.bitsleft += 8;
        }
    }

    /// `n` bits, consumed; past the end of the input, `Truncated`.
    pub fn take(s: *Stream, source: anytype, n: u6) Error!u32 {
        s.need(source, n);
        const v = s.peek(n);
        s.consume(n);
        try s.checkWhole();
        return v;
    }

    /// Drop the bits to the next byte boundary, and hand back the whole
    /// bytes still in the bit buffer: `ip` is then the next byte.
    pub fn alignToByte(s: *Stream) void {
        s.consume(@intCast(s.bitsleft & 7));
        s.ip -= s.bitsleft / 8;
        s.bitbuf = 0;
        s.bitsleft = 0;
        // Zero bytes handed back were never consumed.
        s.virtual = @intCast(s.ip -| s.in.len);
    }
};

/// Decode blocks until the final one ends, or the output is full with
/// `partial`. `s.bitbuf` may hold bits of the stream already.
pub fn decode(t: *Tables, s: *Stream, source: anytype) Error!Status {
    while (true) {
        const header = try s.take(source, 3);
        const final = header & 1 != 0;
        const status: Status = switch (header >> 1) {
            0 => try stored(s, source),
            1 => try codes(s, source, &huffman.Fixed(.litlen).table, huffman.Fixed(.litlen).bits, &huffman.Fixed(.dist).table, huffman.Fixed(.dist).bits),
            2 => blk: {
                const bits = try dynamicHeader(t, s, source);
                break :blk try codes(s, source, &t.litlen, bits.litlen, &t.dist, bits.dist);
            },
            else => return s.fail(.bad_block_type),
        };
        if (status == .output_full) return .output_full;
        if (final) return .done;
    }
}

/// A stored block: its length and complement, then the bytes as they are.
fn stored(s: *Stream, source: anytype) Error!Status {
    s.consume(@intCast(s.bitsleft & 7));
    const lens = try s.take(source, 32);
    const len: u16 = @truncate(lens);
    if (len != ~@as(u16, @truncate(lens >> 16))) return s.fail(.stored_length);
    // The bit buffer holds whole bytes now; hand them back and copy from
    // the input itself.
    s.alignToByte();
    var left: usize = len;
    while (left > 0) {
        if (s.ip >= s.in.len and !source.more(s)) {
            s.virtual = 1;
            s.bitsleft = 0;
            s.ip += 1;
            return s.fail(.truncated);
        }
        const room = s.out.len - s.op;
        if (room == 0) return if (s.partial) .output_full else error.OutputTooSmall;
        const n = @min(left, s.in.len - s.ip, room);
        @memcpy(s.out[s.op..][0..n], s.in[s.ip..][0..n]);
        s.op += n;
        s.ip += n;
        left -= n;
    }
    return .done;
}

/// The main-table bits of a dynamic block's two tables.
const Bits = struct { litlen: u5, dist: u5 };

/// A dynamic block's header: the code-length code, then the litlen and
/// distance code lengths through it, then their tables.
fn dynamicHeader(t: *Tables, s: *Stream, source: anytype) Error!Bits {
    const counts = try s.take(source, 14);
    const hlit: usize = (counts & 31) + 257;
    const hdist: usize = ((counts >> 5) & 31) + 1;
    const hclen: usize = ((counts >> 10) & 15) + 4;
    if (hlit > 286 or hdist > 30) return s.fail(.too_many_codes);
    const order = [19]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };
    var pre: [19]u8 = @splat(0);
    for (order[0..hclen]) |sym| pre[sym] = @intCast(try s.take(source, 3));
    const pre_bits = huffman.build(.precode, &t.precode, &pre, &huffman.countLengths(&pre)) catch |err| return s.fail(switch (err) {
        error.Oversubscribed => .oversubscribed_code,
        error.Incomplete => .incomplete_code,
    });

    var lens: [286 + 30]u8 = undefined;
    const total = hlit + hdist;
    var i: usize = 0;
    while (i < total) {
        s.need(source, 7 + 7);
        const e = t.precode[s.peek(pre_bits)];
        const len = huffman.consumed(e);
        // An empty precode decodes every bit as symbol 0, one bit long, as
        // zlib's does: the lengths come out all zero and the block has no
        // end code.
        const sym: u32 = if (e & exceptional != 0) 0 else huffman.value(e);
        if (sym < 16) {
            s.consume(len);
            try s.checkWhole();
            lens[i] = @intCast(sym);
            i += 1;
            continue;
        }
        // The symbol and its repeat count together, as zlib asks for them.
        const repeat_bits: u6 = switch (sym) {
            16 => 2,
            17 => 3,
            else => 7,
        };
        const repeat_base: usize = switch (sym) {
            16 => 3,
            17 => 3,
            else => 11,
        };
        s.consume(len);
        const repeat = repeat_base + try s.take(source, repeat_bits);
        const fill: u8 = if (sym == 16) blk: {
            if (i == 0) return s.fail(.bad_code_lengths);
            break :blk lens[i - 1];
        } else 0;
        if (i + repeat > total) return s.fail(.bad_code_lengths);
        @memset(lens[i..][0..repeat], fill);
        i += repeat;
    }
    if (lens[256] == 0) return s.fail(.no_end_code);
    const lit_bits = huffman.build(.litlen, &t.litlen, lens[0..hlit], &huffman.countLengths(lens[0..hlit])) catch |err| return s.fail(codeReason(err));
    const dist_bits = huffman.build(.dist, &t.dist, lens[hlit..total], &huffman.countLengths(lens[hlit..total])) catch |err| return s.fail(codeReason(err));
    return .{ .litlen = lit_bits, .dist = dist_bits };
}

fn codeReason(err: huffman.BuildError) Diagnostic.Reason {
    return switch (err) {
        error.Oversubscribed => .oversubscribed_code,
        error.Incomplete => .incomplete_code,
    };
}

/// A Huffman-coded block: the fast loop while it can run, the careful loop
/// near either end.
inline fn codes(s: *Stream, source: anytype, litlen: []const u32, lbits: u5, dist: []const u32, dbits: u5) Error!Status {
    while (true) {
        if (fastReady(s) and try fast(s, litlen, lbits, dist, dbits)) return .done;
        // One symbol at a time until the fast loop can run again.
        while (!fastReady(s)) {
            switch (try careful(s, source, litlen, lbits, dist, dbits)) {
                .symbol => {},
                .end => return .done,
                .full => return .output_full,
            }
        }
    }
}

/// Whether the fast loop can run: sixteen real input bytes and `margin`
/// output bytes remain. It never runs on virtual input.
inline fn fastReady(s: *const Stream) bool {
    return s.virtual == 0 and s.ip + fast_input <= s.in.len and s.op + margin <= s.out.len;
}

/// Decode while `fastReady`; whether the block ended. Every bit this reads
/// is real.
fn fast(s: *Stream, litlen: []const u32, lbits: u5, dist: []const u32, dbits: u5) Error!bool {
    std.debug.assert(fastReady(s));
    var r: Fast = .{
        .in = s.in,
        .ip = s.ip,
        .bitbuf = s.bitbuf,
        .bitsleft = s.bitsleft,
        .lmask = (@as(u64, 1) << lbits) - 1,
        .dmask = (@as(u64, 1) << dbits) - 1,
    };
    const out = s.out;
    const start = s.start;
    const reach = s.dictionary.len;
    var op = s.op;
    defer {
        s.ip = r.ip;
        s.op = op;
        s.bitbuf = r.bitbuf;
        s.bitsleft = r.bitsleft & 63;
    }
    r.refill();
    var entry = litlen[r.low(r.lmask)];
    while (true) {
        // At the top: `entry` is the next litlen entry, at least 56 bits in
        // hand. Up to three literals a round: 45 bits.
        var saved = r.bitbuf;
        r.consume(entry);
        if (entry & literal_flag != 0) {
            const lit1 = entry;
            entry = litlen[r.low(r.lmask)];
            saved = r.bitbuf;
            r.consume(entry);
            out[op] = @truncate(lit1 >> 16);
            op += 1;
            if (entry & literal_flag != 0) {
                const lit2 = entry;
                entry = litlen[r.low(r.lmask)];
                saved = r.bitbuf;
                r.consume(entry);
                out[op] = @truncate(lit2 >> 16);
                op += 1;
                if (entry & literal_flag != 0) {
                    const lit3 = entry;
                    entry = litlen[r.low(r.lmask)];
                    out[op] = @truncate(lit3 >> 16);
                    op += 1;
                    if (!r.more(op, out.len)) return false;
                    continue;
                }
            }
        }
        if (entry & exceptional != 0) {
            @branchHint(.unlikely);
            if (entry & subtable_flag == 0) {
                if (entry & end_flag != 0) return true;
                return s.failAt(.bad_symbol, r.ip, r.bitsleft & 63);
            }
            // A long code: its first bits are consumed; the rest index the
            // subtable.
            r.refill();
            entry = litlen[huffman.value(entry) + r.low((@as(u64, 1) << huffman.codeword(entry)) - 1)];
            saved = r.bitbuf;
            r.consume(entry);
            if (entry & literal_flag != 0) {
                out[op] = @truncate(entry >> 16);
                op += 1;
                entry = litlen[r.low(r.lmask)];
                if (!r.more(op, out.len)) return false;
                continue;
            }
            if (entry & exceptional != 0) {
                if (entry & end_flag != 0) return true;
                return s.failAt(.bad_symbol, r.ip, r.bitsleft & 63);
            }
        }
        const length = huffman.value(entry) + huffman.extra(saved, entry);
        // The distance takes up to 28 bits, then 11 more must remain to
        // look the next symbol up before the refill.
        if (@as(u8, @truncate(r.bitsleft)) < 28 + 11) r.refill();
        entry = dist[r.low(r.dmask)];
        if (entry & exceptional != 0) {
            @branchHint(.unlikely);
            if (entry & subtable_flag == 0) return s.failAt(.bad_symbol, r.ip, r.bitsleft & 63);
            r.consume(entry);
            entry = dist[huffman.value(entry) + r.low((@as(u64, 1) << huffman.codeword(entry)) - 1)];
            if (entry & exceptional != 0) return s.failAt(.bad_symbol, r.ip, r.bitsleft & 63);
        }
        saved = r.bitbuf;
        r.consume(entry);
        const distance = huffman.value(entry) + huffman.extra(saved, entry);
        // The next symbol's entry and the refill go ahead of the copy.
        entry = litlen[r.low(r.lmask)];
        if (distance > op - start) {
            @branchHint(.cold);
            if (distance > op - start + reach) return s.failAt(.distance_too_far, r.ip, r.bitsleft & 63);
            copyFromDictionary(s, op, distance, length);
        } else copyMatch(out, op, distance, length);
        op += length;
        if (!r.more(op, out.len)) return false;
    }
}

/// The fast loop's input state, in registers.
const Fast = struct {
    in: []const u8,
    ip: usize,
    bitbuf: u64,
    /// The bits in hand in the low byte; the bits above are whatever full
    /// entries subtracted.
    bitsleft: u32,
    lmask: u64,
    dmask: u64,

    /// At least 56 bits in hand: one unaligned load, branchless.
    inline fn refill(r: *Fast) void {
        r.bitbuf |= std.mem.readInt(u64, r.in[r.ip..][0..8], .little) << @truncate(r.bitsleft);
        r.ip += (63 - (r.bitsleft & 63)) >> 3;
        r.bitsleft |= 56;
    }

    /// Consume an entry's bits: the shift takes the low six bits, and the
    /// subtraction the whole entry, whose low byte is the count.
    inline fn consume(r: *Fast, entry: u32) void {
        r.bitbuf >>= @truncate(entry);
        r.bitsleft -%= entry;
    }

    /// The bits under `mask` (a table index, under 2^15).
    inline fn low(r: *const Fast, mask: u64) usize {
        return @truncate(r.bitbuf & mask);
    }

    /// Refill for the next round, if one can run.
    inline fn more(r: *Fast, op: usize, out_len: usize) bool {
        if (r.ip + fast_input > r.in.len or op + margin > out_len) return false;
        r.refill();
        return true;
    }
};

/// One symbol with every bound checked.
const Careful = enum { symbol, end, full };

inline fn careful(s: *Stream, source: anytype, litlen: []const u32, lbits: u5, dist: []const u32, dbits: u5) Error!Careful {
    const lit = try symbol(s, source, litlen, lbits);
    if (lit.entry & end_flag != 0) {
        s.consume(lit.bits);
        return .end;
    }
    // Nothing is consumed before the output is known to have room: a
    // partial decode stops at the symbol, whole.
    if (s.op == s.out.len) {
        if (!s.partial) return error.OutputTooSmall;
        return .full;
    }
    s.consume(lit.bits);
    if (lit.entry & literal_flag != 0) {
        s.out[s.op] = @truncate(lit.entry >> 16);
        s.op += 1;
        return .symbol;
    }
    const length = huffman.value(lit.entry) + try s.take(source, lit.extra);
    const d = try symbol(s, source, dist, dbits);
    s.consume(d.bits);
    const distance = huffman.value(d.entry) + try s.take(source, d.extra);
    if (distance > s.op - s.start + s.dictionary.len) return s.fail(.distance_too_far);
    const room = s.out.len - s.op;
    if (length > room) {
        if (!s.partial) return error.OutputTooSmall;
        copyCareful(s, distance, room);
        return .full;
    }
    copyCareful(s, distance, length);
    return .symbol;
}

/// A decoded symbol: its entry, and the codeword's and extra bits' counts.
const Symbol = struct { entry: u32, bits: u6, extra: u6 };

/// The next symbol, not yet consumed. A code with no symbol is refused if
/// its bits are real; a symbol whose codeword reaches past the end of the
/// input is `Truncated`.
inline fn symbol(s: *Stream, source: anytype, table: []const u32, bits: u5) Error!Symbol {
    s.need(source, 15);
    var e = table[s.peek(bits)];
    var main: u6 = 0;
    if (e & subtable_flag != 0) {
        main = bits;
        e = table[huffman.value(e) + @as(usize, @truncate((s.bitbuf >> bits) & ((@as(u64, 1) << huffman.codeword(e)) - 1)))];
    }
    const code: u6 = main + huffman.codeword(e);
    if (code > s.bitsleft or s.bitsleft - code < 8 * s.virtual) {
        s.consume(@min(code, s.bitsleft));
        return s.fail(.truncated);
    }
    if (e & exceptional != 0 and e & end_flag == 0) {
        s.consume(code);
        return s.fail(.bad_symbol);
    }
    return .{ .entry = e, .bits = code, .extra = huffman.consumed(e) - huffman.codeword(e) };
}

/// A match where the output may end within sixteen bytes, or that reaches
/// into the dictionary: one byte at a time.
fn copyCareful(s: *Stream, distance: usize, length: usize) void {
    const back = s.op - s.start;
    for (0..length) |i| {
        const at = back + i;
        s.out[s.op + i] = if (distance <= at) s.out[s.op + i - distance] else s.dictionary[s.dictionary.len - (distance - at)];
    }
    s.op += length;
}

fn copyFromDictionary(s: *Stream, op: usize, distance: usize, length: usize) void {
    const back = op - s.start;
    for (0..length) |i| {
        const at = back + i;
        s.out[op + i] = if (distance <= at) s.out[op + i - distance] else s.dictionary[s.dictionary.len - (distance - at)];
    }
}

/// Copy `length` bytes from `distance` back to `op`, sixteen at a time; up
/// to fifteen bytes past the end are written, inside the margin.
inline fn copyMatch(out: []u8, op: usize, distance: usize, length: usize) void {
    const dst = out[op..].ptr;
    const src = dst - distance;
    if (distance >= 16) {
        // Most matches are at most 32 bytes: two copies, no branch.
        dst[0..16].* = src[0..16].*;
        dst[16..32].* = src[16..32].*;
        var i: usize = 32;
        while (i < length) : (i += 16) dst[i..][0..16].* = src[i..][0..16].*;
    } else if (distance >= 8) {
        // Eight bytes a step: no step reads what it writes.
        dst[0..8].* = src[0..8].*;
        var i: usize = 8;
        while (i < length) : (i += 8) dst[i..][0..8].* = src[i..][0..8].*;
    } else if (distance == 1) {
        // A run of one byte, sixteen at a time. The byte is read again each
        // step (from what the last wrote), which keeps the loop a loop
        // rather than a call to memset.
        var i: usize = 0;
        while (true) {
            dst[i..][0..16].* = @as(@Vector(16, u8), @splat(src[i]));
            i += 16;
            if (i >= length) break;
        }
    } else {
        // Distances 2-7: each eight-byte step writes the pattern and moves
        // on by the distance, so it reads only bytes already written.
        var i: usize = 0;
        while (i < length) : (i += distance) dst[i..][0..8].* = src[i..][0..8].*;
    }
}
