//! GDeflate's writer: DEFLATE's blocks, as the engine chooses them, with
//! their bits dealt across 32 lanes the way the decoder reads them.
//!
//! The page is a sequence of 32-bit words, each a lane's. The writer plays
//! the decoder's reader to place them: it reserves a lane's next word in the
//! page when the lane's reader would hold fewer than 32 bits after the bits
//! written so far, and fills each reserved word as that lane's bits arrive.
//! The page opens with each lane's first word in lane order. Block headers
//! and a stored block's length go to lane 0; precode lengths and
//! code-length items round-robin from lane 0; data in rounds of one symbol
//! a lane, a match's distance on its lane's next turn (`writeData`).
const std = @import("std");
const block = @import("../deflate/block.zig");
const huffman = @import("../huffman.zig");

const decode = huffman.decode;

pub const lanes = 32;

/// Not a reserved word.
const none = std.math.maxInt(usize);

pub const Writer = struct {
    out: []u8,
    /// The next word of the page not yet reserved.
    next: usize,
    /// Each lane's bits not yet in its word, and how many.
    buf: [lanes]u64 = @splat(0),
    count: [lanes]u8 = @splat(0),
    /// Each lane's word being filled, and its next one once reserved.
    at: [lanes]usize = undefined,
    after: [lanes]usize = @splat(none),
    /// What the decoder's reader would hold in each lane.
    reader: [lanes]u8 = @splat(32),
    lane: u5 = 0,
    /// The page ran past `out`; what is written is not a page.
    overflow: bool = false,

    /// A writer of one page into `out`, its lanes' first words reserved.
    pub fn init(out: []u8) Writer {
        var w: Writer = .{ .out = out, .next = 0 };
        for (&w.at) |*a| a.* = w.reserve();
        return w;
    }

    /// The next word of the page, cleared; `none` past the output.
    fn reserve(w: *Writer) usize {
        const at = w.next;
        w.next += 4;
        if (w.next > w.out.len) {
            w.overflow = true;
            return none;
        }
        @memset(w.out[at..][0..4], 0);
        return at;
    }

    /// `n` bits to the current lane (`n <= 32`).
    pub fn add(w: *Writer, value: u32, n: u6) void {
        const lane = w.lane;
        w.buf[lane] |= @as(u64, value) << @intCast(w.count[lane]);
        w.count[lane] += n;
        w.reader[lane] -= n;
        if (w.count[lane] >= 32) w.flushWord(lane);
        if (w.reader[lane] < 32 and w.after[lane] == none) {
            w.after[lane] = w.reserve();
            w.reader[lane] += 32;
        }
    }

    /// The lane's 32 oldest bits into its word; its next word becomes the one
    /// being filled.
    fn flushWord(w: *Writer, lane: u5) void {
        if (w.at[lane] != none) std.mem.writeInt(u32, w.out[w.at[lane]..][0..4], @truncate(w.buf[lane]), .little);
        w.buf[lane] >>= 32;
        w.count[lane] -= 32;
        w.at[lane] = w.after[lane];
        w.after[lane] = none;
    }

    /// On to the next lane; whether that began a round (lane 0 again).
    inline fn advance(w: *Writer) u32 {
        w.lane +%= 1;
        return @intFromBool(w.lane == 0);
    }

    /// Each lane's last bits into its word: the page is whole. Its length.
    pub fn finish(w: *Writer) usize {
        for (0..lanes) |lane| {
            if (w.at[lane] != none) std.mem.writeInt(u32, w.out[w.at[lane]..][0..4], @truncate(w.buf[lane]), .little);
        }
        return w.next;
    }

    /// One block, as `deflate/block.zig`'s `write` takes it: the engine's
    /// choice of kind and code, with GDeflate's stored blocks weighed.
    pub fn writeBlock(w: *Writer, comptime interleaved: bool, data: block.Data, seqs: []const block.Sequence, tail: u32, counts_in: *const block.Counts, final: bool, kinds: block.Kinds) void {
        // Deflate64's alphabet writes a 258-byte match as 284 with 31 extra
        // bits: 285 is 3 with 16.
        var counts = counts_in.*;
        counts.litlen[284] += counts.litlen[285];
        counts.litlen[285] = 0;
        // Runs of matches merged into one long match: counted as written.
        var i: usize = 0;
        while (i < seqs.len) {
            const end = runEnd(seqs, i);
            if (end - i > 1) {
                var total: u32 = 0;
                for (seqs[i..end]) |s| {
                    counts.litlen[lengthSymbol(s.length)] -= 1;
                    total += s.length;
                }
                counts.litlen[lengthSymbol(total)] += 1;
                counts.dist[block.distSymbol(seqs[i].distance)] -= @intCast(end - i - 1);
            }
            i = end;
        }
        const stored_cost: ?u64 = if (kinds == .stored_only) null else if (data.raw) |raw| storedCost(raw.len) else null;
        var plan: block.Plan = undefined;
        switch (block.choose(&counts, seqs.len == 0 and tail == 0, kinds, stored_cost, &plan)) {
            .stored => w.writeStored(data.raw.?, final),
            .fixed => {
                w.blockHeader(final, 1);
                var tokens: Sequences(interleaved) = .{ .data = data.bytes, .seqs = seqs, .tail = tail };
                w.writeTokens(&tokens, &block.fixed);
            },
            .dynamic => {
                w.blockHeader(final, 2);
                w.writeHeader(&plan.header);
                var tokens: Sequences(interleaved) = .{ .data = data.bytes, .seqs = seqs, .tail = tail };
                w.writeTokens(&tokens, &plan.code);
            },
        }
    }

    /// A block's three bits, on lane 0.
    pub fn blockHeader(w: *Writer, final: bool, kind: u2) void {
        w.lane = 0;
        w.add(@intFromBool(final), 1);
        w.add(kind, 2);
    }

    /// A dynamic block's header after its three bits.
    pub fn writeHeader(w: *Writer, header: *const block.Header) void {
        w.lane = 0;
        w.add(header.hlit - 257, 5);
        w.add(header.hdist - 1, 5);
        w.add(header.hclen - 4, 4);
        for (block.precode_order[0..header.hclen]) |sym| {
            w.add(header.pre_lens[sym], 3);
            _ = w.advance();
        }
        w.lane = 0;
        for (header.items[0..header.n_items]) |item| {
            const sym = item & 0xff;
            w.add(header.pre_codes[sym], @intCast(header.pre_lens[sym]));
            switch (sym) {
                16 => w.add(item >> 8, 2),
                17 => w.add(item >> 8, 3),
                18 => w.add(item >> 8, 7),
                else => {},
            }
            _ = w.advance();
        }
    }

    /// The block's symbols in rounds, from `tokens` (`next() ?Token`): each
    /// lane a literal or a length a round, a lane that wrote a length its
    /// distance on its next turn instead. Then the end of the block, and
    /// the distances still waiting.
    pub fn writeTokens(w: *Writer, tokens: anytype, code: *const block.Code) void {
        var waiting: [lanes]Distance = @splat(.{});
        var round: u32 = 1;
        w.lane = 0;
        while (tokens.next()) |t| {
            round = w.distances(&waiting, round);
            switch (t) {
                .literal => |b| w.add(code.litlen_codes[b], @intCast(code.litlen_lens[b])),
                .match => |m| {
                    w.add(code.litlen_codes[m.length_symbol], @intCast(code.litlen_lens[m.length_symbol]));
                    w.add(m.length_extra, lengthExtraBits(m.length_symbol));
                    const dlen = code.dist_lens[m.distance_symbol];
                    waiting[w.lane] = .{
                        .round = round,
                        .bits = code.dist_codes[m.distance_symbol] | m.distance_extra << @intCast(dlen),
                        .len = @intCast(dlen + distExtraBits(m.distance_symbol)),
                    };
                },
            }
            round += w.advance();
        }
        round = w.distances(&waiting, round);
        w.add(code.litlen_codes[block.end_of_block], @intCast(code.litlen_lens[block.end_of_block]));
        round += w.advance();
        // The lanes after this one wait from the last round; those up to it,
        // from this one.
        const split = w.lane;
        for (split..lanes) |lane| {
            if (round > 1 and waiting[lane].round == round - 1) {
                w.lane = @intCast(lane);
                w.add(waiting[lane].bits, waiting[lane].len);
            }
        }
        for (0..split) |lane| {
            if (waiting[lane].round == round) {
                w.lane = @intCast(lane);
                w.add(waiting[lane].bits, waiting[lane].len);
            }
        }
    }

    /// The distances waiting from the last round, from the current lane on;
    /// the round it is after them.
    inline fn distances(w: *Writer, waiting: *[lanes]Distance, round_in: u32) u32 {
        var round = round_in;
        while (round > 1 and waiting[w.lane].round == round - 1) {
            waiting[w.lane].round = 0;
            w.add(waiting[w.lane].bits, waiting[w.lane].len);
            round += w.advance();
        }
        return round;
    }

    /// Stored blocks of at most 65,535 bytes: a 16-bit length on lane 0 (no
    /// alignment, no complement), then the bytes round-robin.
    pub fn writeStored(w: *Writer, data: []const u8, final: bool) void {
        var rest = data;
        while (true) {
            const chunk = rest[0..@min(rest.len, 65535)];
            rest = rest[chunk.len..];
            w.blockHeader(final and rest.len == 0, 0);
            w.add(@intCast(chunk.len), 16);
            for (chunk) |b| {
                w.add(b, 8);
                _ = w.advance();
            }
            if (rest.len == 0) return;
        }
    }
};

/// One symbol of a block's data: a literal, or a match as its length and
/// distance symbols and their extra bits.
pub const Token = union(enum) {
    literal: u8,
    match: struct { length_symbol: u16, length_extra: u32, distance_symbol: u8, distance_extra: u32 },
};

/// The tokens of the engine's sequences: each sequence's literals (the
/// block's bytes, which the matches skip over when `interleaved`), then
/// its match; then `tail` literals.
fn Sequences(comptime interleaved: bool) type {
    return struct {
        data: []const u8,
        seqs: []const block.Sequence,
        tail: u32,
        at: usize = 0,
        seq: usize = 0,
        /// Literals left before the next match.
        left: ?u32 = null,

        pub inline fn next(t: *@This()) ?Token {
            while (true) {
                const left = t.left orelse if (t.seq < t.seqs.len) t.seqs[t.seq].literals else t.tail;
                if (left > 0) {
                    t.left = left - 1;
                    t.at += 1;
                    return .{ .literal = t.data[t.at - 1] };
                }
                if (t.seq == t.seqs.len) return null;
                const s = t.seqs[t.seq];
                const end = runEnd(t.seqs, t.seq);
                var length: u32 = 0;
                for (t.seqs[t.seq..end]) |m| length += m.length;
                t.seq = end;
                t.left = null;
                if (interleaved) t.at += length;
                const sym = lengthSymbol(length);
                const ds = block.distSymbol(s.distance);
                return .{ .match = .{
                    .length_symbol = @intCast(sym),
                    .length_extra = length - lengthBase(sym),
                    .distance_symbol = @intCast(ds),
                    .distance_extra = s.distance - decode.dist_base64[ds],
                } };
            }
        }
    };
}

/// The extra bits of a Deflate64 length symbol: DEFLATE's, but 16 for 285.
fn lengthExtraBits(sym: u16) u6 {
    return if (sym == 285) 16 else @intCast(decode.length_extra[sym - 257]);
}

/// The extra bits of a Deflate64 distance symbol: DEFLATE's, and 14 for 30
/// and 31.
fn distExtraBits(sym: u8) u6 {
    return @intCast(decode.dist_extra64[sym]);
}

/// A match's distance waiting for its lane's next turn, from `round`
/// (0: none).
const Distance = struct { round: u32 = 0, bits: u32 = 0, len: u6 = 0 };

/// Deflate64's length symbol: DEFLATE's, but 284 for 258 and 285 (3 with
/// 16 extra bits) past it.
fn lengthSymbol(length: u32) u32 {
    return if (length > 258) 285 else if (length == 258) 284 else block.lengthSymbol(length);
}

fn lengthBase(sym: u32) u32 {
    return if (sym == 285) 3 else decode.length_base[sym - 257];
}

/// The matches the engine wrote at a run's distance, one after another
/// with no literals between: as many bytes as one Deflate64 match of
/// their total length, which is shorter written once from three on (three
/// 258-byte symbols with their distances against one symbol with 16 extra
/// bits). The end of the run starting at `i`: `i + 1` when shorter. A page
/// is at most 64 KiB, so a run's total fits one match (65,538).
fn runEnd(seqs: []const block.Sequence, i: usize) usize {
    var end = i + 1;
    while (end < seqs.len and seqs[end].literals == 0 and seqs[end].distance == seqs[i].distance) end += 1;
    return if (end - i >= 3) end else i + 1;
}

/// The bits of GDeflate's stored blocks for `len` bytes: 3 + 16 + 8 a byte
/// for each 65,535.
pub fn storedCost(len: usize) u64 {
    const chunks = @max(1, (len + 65534) / 65535);
    return 19 * @as(u64, chunks) + 8 * @as(u64, len);
}
