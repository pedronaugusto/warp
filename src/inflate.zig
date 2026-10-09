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
//!
//! The engine is resumable at any input byte: its place in a stream is a
//! `State` and the bits in hand. It reads in units of at most 48 bits (a
//! block header, a stored block's lengths, one code length, one symbol
//! with its extra bits) and tells its source after each unit it finishes
//! (`commit`). A streaming caller that runs out of input inside a unit
//! takes the `Truncated` as "more input", goes back to the last commit, and
//! keeps the unit's bits for the next call.

const std = @import("std");
const huffman = @import("huffman.zig").decode;
const Diagnostic = @import("Diagnostic.zig");

const literal_flag = huffman.literal_flag;
const exceptional = huffman.exceptional;
const subtable_flag = huffman.subtable_flag;
const end_flag = huffman.end_flag;

/// The longest match, plus the most a sixteen-byte copy writes past it.
pub const margin = 258 + 16;

/// The farthest a DEFLATE distance reaches.
pub const max_distance = 32768;

/// The input a round of the fast loop may read: two refills (one before a
/// distance when the bits run short, or one for a subtable, and one at the
/// end), each eight bytes from at most seven past the last.
const fast_input = 7 + 8 + 1;

/// Decoding tables for one block at a time, and the code lengths a dynamic
/// block's header gives for them: about 11 KiB.
pub const Tables = TablesFor(false);

/// The extended alphabet changes table capacity only for a Deflate64
/// decoder; ordinary DEFLATE keeps its original state footprint.
pub fn TablesFor(comptime extended: bool) type {
    return struct {
        pub const wide = extended;
        litlen: [huffman.Alphabet.litlen.enough()]u32 = undefined,
        dist: [if (extended) huffman.Alphabet.dist64.enough() else huffman.Alphabet.dist.enough()]u32 = undefined,
        precode: [huffman.Alphabet.precode.enough()]u32 = undefined,
        pre: [19]u8 = undefined,
        lens: [286 + if (extended) @as(usize, 32) else 30]u8 = undefined,
    };
}

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
    /// A block other than the final one ended.
    block_end,
    /// The output is full and the stream goes on (partial decoding only).
    output_full,
};

/// Input that can grow: a reader's buffer, refilled as the engine asks.
/// A slice has no more, and nothing is told of the engine's progress.
pub const no_more: NoMore = .{};

pub const NoMore = struct {
    pub fn more(_: NoMore, _: *Stream) bool {
        return false;
    }

    pub fn commit(_: NoMore, _: *Stream) void {}
};

/// The bytes before the output that a distance may reach: a dictionary,
/// or a streaming decoder's window, in two pieces (a ring's older and newer
/// halves) that read as one.
pub const History = struct {
    older: []const u8 = &.{},
    newer: []const u8 = &.{},

    pub fn len(h: History) usize {
        return h.older.len + h.newer.len;
    }

    /// Copy `dst.len` bytes into `dst`, starting `back` bytes before the
    /// end (`dst.len <= back <= len()`).
    pub fn copyOut(h: History, back: usize, dst: []u8) void {
        var from = h.len() - back;
        var to: usize = 0;
        if (from < h.older.len) {
            const n = @min(dst.len, h.older.len - from);
            @memcpy(dst[0..n], h.older[from..][0..n]);
            to = n;
            from = h.older.len;
        }
        const rest = dst.len - to;
        @memcpy(dst[to..], h.newer[from - h.older.len ..][0..rest]);
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
    /// back to here, and then into `history`.
    start: usize,
    /// Bytes that precede the output.
    history: History = .{},
    /// The farthest distance accepted: a streaming decoder's window. Past
    /// it a stream is refused (`window_exceeded`).
    window: u32 = max_distance,
    /// Stop without error when the output is full.
    partial: bool = false,
    /// The stream ABI's tree flush stops after the next block header.
    stop_header: bool = false,
    /// Private: the C ABI stops at a final block before its trailer.
    stop_final: bool = false,
    diagnostic: ?*Diagnostic = null,
    deflate64: bool = false,

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

    /// `Truncated` at the end of the input, which a byte-wise reader (a
    /// stored block, a gzip header) has reached.
    pub fn failEnd(s: *Stream) Error {
        s.bitbuf = 0;
        s.bitsleft = 0;
        s.virtual = 1;
        s.ip = s.in.len + 1;
        return s.fail(.truncated);
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
    /// bytes still in the bit buffer: `ip` is then the next byte. Those
    /// bytes were loaded from `in` (a unit finished in this input).
    pub fn alignToByte(s: *Stream) void {
        s.consume(@intCast(s.bitsleft & 7));
        std.debug.assert(s.bitsleft / 8 <= s.ip);
        s.ip -= s.bitsleft / 8;
        s.bitbuf = 0;
        s.bitsleft = 0;
        // Zero bytes handed back were never consumed.
        s.virtual = @intCast(s.ip -| s.in.len);
    }
};

/// Where a stream is between blocks and inside one: everything a resumed
/// decode needs besides the bits in hand and the tables.
pub const State = struct {
    phase: Phase = .header,
    /// The current block is the last.
    final: bool = false,
    /// A stored block's bytes still to copy.
    stored_left: u16 = 0,
    /// The current Huffman block's code: the fixed one, or the tables'
    /// with these main-table bits.
    fixed: bool = false,
    lbits: u5 = 0,
    dbits: u5 = 0,
    /// A match the output had no room for: its bytes still to copy and
    /// its distance.
    copy_left: u32 = 0,
    copy_distance: u32 = 0,
    /// Introspection of a match suspended by a full output buffer.
    copy_length: u32 = 0,
    copy_bits: u16 = 0,
    /// A dynamic block's header so far: its counts, and how many code
    /// lengths are read (they are in the tables').
    hlit: u16 = 0,
    hdist: u16 = 0,
    hclen: u16 = 0,
    read: u16 = 0,
    pre_bits: u5 = 0,

    pub const Phase = enum { header, stored_lengths, stored, precode, lengths, codes, done };
};

/// Decode until a block ends, the final one ends, or the output is full
/// (partial decoding). `s.bitbuf` may hold bits of the stream already.
pub noinline fn decode(t: anytype, s: *Stream, source: anytype, state: *State) Error!Status {
    s.deflate64 = @TypeOf(t.*).wide;
    // Each part goes on to the next by a direct jump.
    phase: switch (state.phase) {
        .header => {
            const next = try blockHeader(s, source, state);
            if (s.stop_header and next != .precode and next != .stored_lengths) return .block_end;
            switch (next) {
                .stored_lengths => continue :phase .stored_lengths,
                .precode => continue :phase .precode,
                else => continue :phase .codes,
            }
        },
        .stored_lengths => {
            const lens = try s.take(source, 32);
            const len: u16 = @truncate(lens);
            if (len != ~@as(u16, @truncate(lens >> 16))) return s.fail(.stored_length);
            s.alignToByte();
            state.stored_left = len;
            state.phase = .stored;
            source.commit(s);
            if (s.stop_header) return .block_end;
            continue :phase .stored;
        },
        .stored => {
            if (!try stored(s, source, state)) return .output_full;
            return blockEnd(s, source, state);
        },
        .precode => {
            try precode(t, s, source, state);
            continue :phase .lengths;
        },
        .lengths => {
            try lengths(t, s, source, state);
            if (s.stop_header) return .block_end;
            continue :phase .codes;
        },
        .codes => {
            if (state.copy_left != 0) {
                if (!resumeCopy(s, state)) return .output_full;
                source.commit(s);
            }
            const ended = if (state.fixed)
                try codes(s, source, state, &huffman.Fixed(if (@TypeOf(t.*).wide) .litlen64 else .litlen).table, huffman.Fixed(.litlen).bits, &huffman.Fixed(if (@TypeOf(t.*).wide) .dist64 else .dist).table, huffman.Fixed(.dist).bits)
            else
                try codes(s, source, state, &t.litlen, state.lbits, &t.dist, state.dbits);
            if (!ended) return .output_full;
            return blockEnd(s, source, state);
        },
        .done => return .done,
    }
}

inline fn blockEnd(s: *Stream, source: anytype, state: *State) Status {
    state.phase = if (state.final) .done else .header;
    source.commit(s);
    if (state.final and s.stop_final) return .block_end;
    return if (state.final) .done else .block_end;
}

/// A block's three header bits and a dynamic block's counts. Stored
/// lengths are a separate unit, so byte-aligned sync points are observable.
inline fn blockHeader(s: *Stream, source: anytype, state: *State) Error!State.Phase {
    const header = try s.take(source, 3);
    const final = header & 1 != 0;
    switch (header >> 1) {
        0 => {
            s.consume(@intCast(s.bitsleft & 7));
            state.phase = .stored_lengths;
        },
        1 => {
            state.fixed = true;
            state.phase = .codes;
        },
        2 => {
            const counts = try s.take(source, 14);
            const hlit: u16 = @intCast((counts & 31) + 257);
            const hdist: u16 = @intCast(((counts >> 5) & 31) + 1);
            if (hlit > 286 or hdist > (if (s.deflate64) @as(u16, 32) else 30)) return s.fail(.too_many_codes);
            state.hlit = hlit;
            state.hdist = hdist;
            state.hclen = @intCast(((counts >> 10) & 15) + 4);
            state.read = 0;
            state.phase = .precode;
        },
        else => return s.fail(.bad_block_type),
    }
    state.final = final;
    source.commit(s);
    return state.phase;
}

/// A stored block's bytes, as they are; false when the output filled first.
fn stored(s: *Stream, source: anytype, state: *State) Error!bool {
    while (state.stored_left > 0) {
        if (s.ip >= s.in.len and !source.more(s)) return s.failEnd();
        const room = s.out.len - s.op;
        if (room == 0) {
            if (!s.partial) return error.OutputTooSmall;
            return false;
        }
        const n = @min(state.stored_left, s.in.len - s.ip, room);
        @memcpy(s.out[s.op..][0..n], s.in[s.ip..][0..n]);
        s.op += n;
        s.ip += n;
        state.stored_left -= @intCast(n);
        source.commit(s);
    }
    return true;
}

const precode_order = [19]u8{ 16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15 };

/// A dynamic block's code-length code: three bits per length, then its
/// table.
fn precode(t: anytype, s: *Stream, source: anytype, state: *State) Error!void {
    var read = state.read;
    defer state.read = read;
    if (read == 0) t.pre = @splat(0);
    while (read < state.hclen) {
        const len: u8 = @intCast(try s.take(source, 3));
        t.pre[precode_order[read]] = len;
        read += 1;
        source.commit(s);
    }
    state.pre_bits = huffman.build(.precode, &t.precode, &t.pre, &huffman.countLengths(&t.pre)) catch |err| return s.fail(codeReason(err));
    read = 0;
    state.phase = .lengths;
}

/// A dynamic block's litlen and distance code lengths through the
/// code-length code, one length or repeat at a time, then their tables.
fn lengths(t: anytype, s: *Stream, source: anytype, state: *State) Error!void {
    const hlit = state.hlit;
    const total = hlit + state.hdist;
    const pre_bits = state.pre_bits;
    const lens = &t.lens;
    // Keep progress in a register, then save it even on a truncated unit.
    // Source commits snapshot bits and output, independently of this index.
    var read = state.read;
    defer state.read = read;
    while (read < total) {
        const i = read;
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
            read = i + 1;
            source.commit(s);
            continue;
        }
        // The symbol and its repeat count together, as zlib asks for them.
        const repeat_bits: u6 = switch (sym) {
            16 => 2,
            17 => 3,
            else => 7,
        };
        const repeat_base: u16 = switch (sym) {
            16 => 3,
            17 => 3,
            else => 11,
        };
        s.consume(len);
        const repeat = repeat_base + @as(u16, @intCast(try s.take(source, repeat_bits)));
        const fill: u8 = if (sym == 16) blk: {
            if (i == 0) return s.fail(.bad_code_lengths);
            break :blk lens[i - 1];
        } else 0;
        if (i + repeat > total) return s.fail(.bad_code_lengths);
        @memset(lens[i..][0..repeat], fill);
        read = i + repeat;
        source.commit(s);
    }
    if (lens[256] == 0) return s.fail(.no_end_code);
    state.lbits = huffman.build(if (@TypeOf(t.*).wide) .litlen64 else .litlen, &t.litlen, lens[0..hlit], &huffman.countLengths(lens[0..hlit])) catch |err| return s.fail(codeReason(err));
    state.dbits = huffman.build(if (@TypeOf(t.*).wide) .dist64 else .dist, &t.dist, lens[hlit..total], &huffman.countLengths(lens[hlit..total])) catch |err| return s.fail(codeReason(err));
    state.fixed = false;
    state.phase = .codes;
}

fn codeReason(err: huffman.BuildError) Diagnostic.Reason {
    return switch (err) {
        error.Oversubscribed => .oversubscribed_code,
        error.Incomplete => .incomplete_code,
    };
}

/// A Huffman-coded block: the fast loop while it can run, the careful loop
/// near either end. Whether the block ended (else the output is full).
inline fn codes(s: *Stream, source: anytype, state: *State, litlen: []const u32, lbits: u5, dist: []const u32, dbits: u5) Error!bool {
    while (true) {
        if (fastReady(s)) {
            // Ordinary DEFLATE cannot encode a distance beyond 32 KiB.
            // Select the bound once per fast-loop entry, not per match.
            // Keep the register-heavy loop out of the resumable phase caller.
            const ended = if (s.window >= max_distance)
                try @call(.never_inline, fast, .{ std.math.maxInt(usize), s, Bytes(true){ .stream = s, .out = s.out, .start = s.start, .window = s.window }, litlen, lbits, dist, dbits })
            else
                try @call(.never_inline, fast, .{ std.math.maxInt(usize), s, Bytes(false){ .stream = s, .out = s.out, .start = s.start, .window = s.window }, litlen, lbits, dist, dbits });
            if (ended) return true;
            source.commit(s);
        }
        // One symbol at a time until the fast loop can run again.
        while (!fastReady(s)) {
            switch (try careful(s, source, state, litlen, lbits, dist, dbits)) {
                .symbol => source.commit(s),
                .end => return true,
                .full => {
                    source.commit(s);
                    return false;
                },
            }
        }
    }
}

/// Whether the fast loop can run: sixteen real input bytes and `margin`
/// output bytes remain. It never runs on virtual input.
inline fn fastReady(s: *const Stream) bool {
    return !s.deflate64 and s.virtual == 0 and s.ip + fast_input <= s.in.len and s.op + margin <= s.out.len;
}

/// Decode while `fastReady`; whether the block ended. Every bit this reads
/// is real.
pub fn fast(comptime rounds: usize, s: *Stream, output: anytype, litlen: []const u32, lbits: u5, dist: []const u32, dbits: u5) Error!bool {
    std.debug.assert(s.virtual == 0);
    std.debug.assert(s.ip + fast_input <= s.in.len);
    std.debug.assert(output.position() + margin <= output.capacity());
    var r: Fast = .{
        .in = s.in,
        .ip = s.ip,
        .bitbuf = s.bitbuf,
        .bitsleft = s.bitsleft,
        .lmask = (@as(u64, 1) << lbits) - 1,
        .dmask = (@as(u64, 1) << dbits) - 1,
    };
    const out = output.buffer();
    const capacity = out.len;
    var op = output.position();
    var left = rounds;
    defer {
        s.ip = r.ip;
        output.finish(op);
        s.bitbuf = r.bitbuf;
        s.bitsleft = r.bitsleft & 63;
    }
    r.refill();
    var entry = litlen[r.low(r.lmask)];
    while (true) {
        if (comptime rounds != std.math.maxInt(usize)) {
            if (left == 0) return false;
            left -= 1;
        }
        // At the top: `entry` is the next litlen entry, at least 56 bits in
        // hand. Up to three literals a round: 45 bits.
        var saved = r.bitbuf;
        r.consume(entry);
        if (entry & literal_flag != 0) {
            const lit1 = entry;
            entry = litlen[r.low(r.lmask)];
            saved = r.bitbuf;
            r.consume(entry);
            out[op] = @as(u8, @truncate(lit1 >> 16)); // safe: the payload low byte is a literal
            op += 1;
            if (entry & literal_flag != 0) {
                const lit2 = entry;
                entry = litlen[r.low(r.lmask)];
                saved = r.bitbuf;
                r.consume(entry);
                out[op] = @as(u8, @truncate(lit2 >> 16)); // safe: the payload low byte is a literal
                op += 1;
                if (entry & literal_flag != 0) {
                    const lit3 = entry;
                    entry = litlen[r.low(r.lmask)];
                    out[op] = @as(u8, @truncate(lit3 >> 16)); // safe: the payload low byte is a literal
                    op += 1;
                    if (!r.more(op, capacity)) return false;
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
                out[op] = @as(u8, @truncate(entry >> 16)); // safe: the payload low byte is a literal
                op += 1;
                entry = litlen[r.low(r.lmask)];
                if (!r.more(op, capacity)) return false;
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
            // A code with no symbol is refused after its bits, as the
            // careful loop refuses it.
            r.consume(entry);
            if (entry & subtable_flag == 0) return s.failAt(.bad_symbol, r.ip, r.bitsleft & 63);
            entry = dist[huffman.value(entry) + r.low((@as(u64, 1) << huffman.codeword(entry)) - 1)];
            if (entry & exceptional != 0) {
                r.consume(entry);
                return s.failAt(.bad_symbol, r.ip, r.bitsleft & 63);
            }
        }
        saved = r.bitbuf;
        r.consume(entry);
        const distance = huffman.value(entry) + huffman.extra(saved, entry);
        // The next symbol's entry and the refill go ahead of the copy.
        entry = litlen[r.low(r.lmask)];
        try output.match(op, distance, length, r.ip, r.bitsleft & 63);
        op += length;
        if (!r.more(op, capacity)) return false;
    }
}

/// Ordinary output: the stream owns the history and output position.
fn Bytes(comptime full_window: bool) type {
    return struct {
        stream: *Stream,
        out: []u8,
        start: usize,
        window: usize,

        const Self = @This();

        inline fn position(b: Self) usize {
            return b.stream.op;
        }

        inline fn capacity(b: Self) usize {
            return b.out.len;
        }

        inline fn buffer(b: Self) []u8 {
            return b.out;
        }

        inline fn match(b: Self, op: usize, distance: usize, length: usize, ip: usize, bits: u32) Error!void {
            const s = b.stream;
            if (distance > op - b.start or (!full_window and distance > b.window)) {
                @branchHint(.cold);
                if (!full_window and distance > b.window) return s.failAt(.window_exceeded, ip, bits);
                if (distance > op - b.start + s.history.len()) return s.failAt(.distance_too_far, ip, bits);
                copyFromHistory(s, op, distance, length);
            } else copyMatch(u8, b.out, op, distance, length);
        }

        inline fn finish(b: Self, op: usize) void {
            b.stream.op = op;
        }
    };
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

inline fn careful(s: *Stream, source: anytype, state: *State, litlen: []const u32, lbits: u5, dist: []const u32, dbits: u5) Error!Careful {
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
    if (distance > s.window) return s.fail(.window_exceeded);
    if (distance > s.op - s.start + s.history.len()) return s.fail(.distance_too_far);
    const room = s.out.len - s.op;
    if (length > room) {
        if (!s.partial) return error.OutputTooSmall;
        copyCareful(s, distance, room);
        state.copy_left = @intCast(length - room);
        state.copy_distance = @intCast(distance);
        state.copy_length = length;
        state.copy_bits = @as(u16, lit.bits) + lit.extra + d.bits + d.extra;
        return .full;
    }
    copyCareful(s, distance, length);
    return .symbol;
}

/// A decoded symbol: its entry, and the codeword's and extra bits' counts.
pub const Symbol = struct { entry: u32, bits: u6, extra: u6 };

/// The next symbol, not yet consumed. A code with no symbol is refused if
/// its bits are real; a symbol whose codeword reaches past the end of the
/// input is `Truncated`.
pub inline fn symbol(s: *Stream, source: anytype, table: []const u32, bits: u5) Error!Symbol {
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

/// The rest of a match the output had no room for, as far as it has room
/// now; whether it is all copied.
fn resumeCopy(s: *Stream, state: *State) bool {
    const n = @min(state.copy_left, s.out.len - s.op);
    copyCareful(s, state.copy_distance, n);
    state.copy_left -= @intCast(n);
    return state.copy_left == 0;
}

/// A match where the output may end within sixteen bytes: the part in the
/// history, then a byte at a time.
fn copyCareful(s: *Stream, distance: usize, length: usize) void {
    const back = s.op - s.start;
    var done: usize = 0;
    if (distance > back) {
        done = @min(length, distance - back);
        s.history.copyOut(distance - back, s.out[s.op..][0..done]);
    }
    for (done..length) |i| s.out[s.op + i] = s.out[s.op + i - distance];
    s.op += length;
}

/// A match that starts in the history, from the fast loop (the output has
/// `margin` bytes of room): the part in the history sixteen bytes at a
/// time where one piece of it holds them, then the rest from the output,
/// which it may overlap.
fn copyFromHistory(s: *Stream, op: usize, distance: usize, length: usize) void {
    const back = op - s.start;
    const k = distance - back;
    const from_history = @min(length, k);
    const h = s.history;
    const at = h.len() - k;
    const piece = if (at >= h.older.len) h.newer[at - h.older.len ..] else h.older[at..];
    if (from_history + 15 <= piece.len) {
        // Up to fifteen bytes past the part are written, inside the margin.
        const dst = s.out[op..].ptr;
        var i: usize = 0;
        while (i < from_history) : (i += 16) dst[i..][0..16].* = piece[i..][0..16].*;
    } else h.copyOut(k, s.out[op..][0..from_history]);
    if (from_history < length) copyMatch(u8, s.out, op + from_history, distance, length - from_history);
}

/// Copy `length` elements from `distance` back to `op`, sixteen at a time;
/// up to thirty-one elements past the end fit within the fast-loop margin.
pub inline fn copyMatch(comptime T: type, out: []T, op: usize, distance: usize, length: usize) void {
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
            dst[i..][0..16].* = @as(@Vector(16, T), @splat(src[i]));
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

test "history reads as one across a ring's two pieces" {
    const h: History = .{ .older = "abcd", .newer = "efg" };
    var out: [5]u8 = undefined;
    h.copyOut(7, &out);
    try std.testing.expectEqualStrings("abcde", &out);
    h.copyOut(3, out[0..3]);
    try std.testing.expectEqualStrings("efg", out[0..3]);
    h.copyOut(5, out[0..4]);
    try std.testing.expectEqualStrings("cdef", out[0..4]);
}
