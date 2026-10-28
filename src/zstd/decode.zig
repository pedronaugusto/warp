//! The block decoder: a compressed block's literals section, its
//! sequences section, and the sequences executed into the output.
//!
//! Output is written straight into the caller's buffer, which is the
//! frame's history; matches may reach back past the frame's start into a
//! dictionary's content. Literals are decoded into the end of the output
//! buffer and read from there as the output grows toward them (raw
//! literals are read in place from the input when 32 bytes follow them),
//! so decoding needs no literal buffer of its own: a block can only
//! regenerate as much as the output holds, and while it does, the output
//! never reaches a literal not yet read.
//!
//! The fast loop copies in 16-byte steps and may write up to 32 bytes past
//! a sequence's end; it runs while that room exists before the next unread
//! literal and the output's end. Everything else goes through a careful
//! path that copies exactly and checks every bound, in the order the
//! format's reference decoder checks them, so a broken block is refused
//! for the same reason.

const std = @import("std");
const aegis = @import("aegis");
const builtin = @import("builtin");
const bits = @import("bits.zig");
const fse = @import("fse.zig");
const huffman = @import("huffman.zig");
const codes = @import("codes.zig");
const Diagnostic = @import("Diagnostic.zig");

pub const block_max = 1 << 17;
/// Room the fast loop may write past a sequence's end.
pub const margin = 32;

pub const Error = error{ InvalidStream, OutputTooSmall };

/// The decoding tables a decoder owns: built per block when the block
/// sends its own.
pub const Tables = struct {
    huffman: huffman.Table,
    weights: huffman.Weights,
    ll: fse.LlTable,
    of: fse.OfTable,
    ml: fse.MlTable,
};

/// What a frame's blocks share: the tables used last (a block may say
/// "the same again") and the repeat offsets.
pub const Entropy = struct {
    huffman: ?*const huffman.Table = null,
    ll: *const fse.LlTable = &fse.ll_default,
    of: *const fse.OfTable = &fse.of_default,
    ml: *const fse.MlTable = &fse.ml_default,
    /// A block has decoded sequences with tables, so "repeat" is allowed.
    fse_ready: bool = false,
    reps: [3]u32 = .{ 1, 4, 8 },
};

/// One frame being decoded into a buffer.
pub const Frame = struct {
    tables: *Tables,
    /// Optional literal scratch for blocks decoded into an exact output buffer.
    literal_buffer: []u8 = &.{},
    entropy: Entropy,
    /// The whole output; this frame's content starts at `start`.
    out: []u8,
    start: usize,
    /// History before `start`: a dictionary's content.
    dict: []const u8,
    /// min(window, 128 KiB): the largest literals section and compressed
    /// block.
    block_max: usize,
    /// Where and why a block was refused, relative to the block.
    fault: Fault = .{},
    /// A partial block stopped at the output limit.
    stopped: bool = false,

    pub const Fault = struct { offset: usize = 0, reason: Diagnostic.Reason = .truncated };

    fn fail(f: *Frame, err: Error, offset: usize, reason: Diagnostic.Reason) Error {
        f.fault = .{ .offset = offset, .reason = reason };
        return err;
    }

    /// Decode a compressed block at `op`; returns the bytes written.
    pub fn block(f: *Frame, in: []const u8, op: usize) Error!usize {
        if (in.len > f.block_max) return f.fail(error.InvalidStream, 0, .block_too_large);
        var lits: Literals = undefined;
        const lit_len = try f.literals(in, op, &lits);
        return f.sequences(false, in, lit_len, op, &lits);
    }

    /// Decode a prefix through the same sequence decoder; literals are
    /// pulled into their final positions rather than decoded into a tail.
    pub fn blockPartial(f: *Frame, in: []const u8, op: usize) Error!usize {
        f.stopped = false;
        if (in.len > f.block_max) return f.fail(error.InvalidStream, 0, .block_too_large);
        var cursor: LiteralCursor = undefined;
        const section = try f.literalCursor(in, &cursor, null);
        var lits: Literals = .{ .bytes = &.{}, .len = section.len, .in_out = null, .limit = f.out.len, .cursor = &cursor };
        return f.sequences(true, in, section.bytes, op, &lits);
    }

    const LiteralSection = struct { bytes: usize, len: usize };

    fn literalCursor(f: *Frame, in: []const u8, cursor: *LiteralCursor, metadata: ?*LiteralSection) Error!LiteralSection {
        if (in.len < 2) return f.fail(error.InvalidStream, 0, .bad_literals_header);
        const kind: u2 = @truncate(in[0]);
        const size_format: u2 = @truncate(in[0] >> 2);
        if (kind < 2) {
            const header: usize = switch (size_format) {
                0, 2 => 1,
                1 => 2,
                3 => 3,
            };
            if (in.len < header + @as(usize, kind)) return f.fail(error.InvalidStream, 0, .bad_literals_header);
            const len: usize = switch (header) {
                1 => in[0] >> 3,
                2 => std.mem.readInt(u16, in[0..2], .little) >> 4,
                else => std.mem.readInt(u24, in[0..3], .little) >> 4,
            };
            if (len > f.block_max) return f.fail(error.InvalidStream, 0, .bad_literals_header);
            if (metadata) |m| m.* = .{ .bytes = header, .len = len };
            if (kind == 0) {
                if (in.len - header < len) return f.fail(error.InvalidStream, 0, .bad_literals_header);
                cursor.* = .{ .raw = in[header..][0..len] };
            } else cursor.* = .{ .rle = in[header] };
            return .{ .bytes = header + (if (kind == 0) len else 1), .len = len };
        }
        if (kind == 3 and f.entropy.huffman == null) return f.fail(error.InvalidStream, 0, .treeless_first);
        if (in.len < 5) return f.fail(error.InvalidStream, 0, .bad_literals_header);
        const h = std.mem.readInt(u32, in[0..4], .little);
        const header: usize = if (size_format < 2) 3 else if (size_format == 2) 4 else 5;
        const len: usize = switch (size_format) {
            0, 1 => (h >> 4) & 0x3ff,
            2 => (h >> 4) & 0x3fff,
            3 => (h >> 4) & 0x3ffff,
        };
        const csize: usize = switch (size_format) {
            0, 1 => (h >> 14) & 0x3ff,
            2 => h >> 18,
            3 => (h >> 22) + (@as(usize, in[4]) << 10),
        };
        const single = size_format == 0;
        if (len > f.block_max or (!single and len < 6) or header + csize > in.len) return f.fail(error.InvalidStream, 0, .bad_literals_header);
        if (metadata) |m| m.* = .{ .bytes = header, .len = len };
        var src = in[header..][0..csize];
        if (kind == 2) {
            try f.huffmanTable(src, header, false);
            if (f.tables.weights.len >= src.len) return f.fail(error.InvalidStream, header, .bad_huffman_weights);
            src = src[f.tables.weights.len..];
        }
        cursor.* = .{ .huffman = huffman.Symbols.init(f.entropy.huffman.?, src, len, single) catch return f.fail(error.InvalidStream, header, .literals_size) };
        return .{ .bytes = header + csize, .len = len };
    }

    // ---- literals ----

    /// Where a block's literals are and how far the fast loop may read.
    const Literals = struct {
        /// The literals and the readable bytes after them: in the input
        /// (32 or more follow), or the end of the output (none follow).
        bytes: []const u8,
        len: usize,
        /// Where the literals start in `out`, when they are there: the
        /// output may not overtake the next one unread.
        in_out: ?usize,
        cursor: ?*LiteralCursor = null,
        /// The end of the output this block may write. Where its literals
        /// are not in the input and the output has room for a whole block
        /// and its literals, the reference decoder puts them after the
        /// block and lets the block write no further than 32 bytes past
        /// the largest block; so does this decoder, refusing the same
        /// blocks as too large for the output.
        limit: usize,
    };

    fn literals(f: *Frame, in: []const u8, op: usize, lits: *Literals) Error!usize {
        if (in.len < 2) return f.fail(error.InvalidStream, 0, .bad_literals_header);
        const kind: u2 = @truncate(in[0]);
        const size_format: u2 = @truncate(in[0] >> 2);
        const room = f.out.len - op;
        const expected = @min(f.block_max, room);
        switch (kind) {
            0, 1 => {
                // Raw or RLE: one, two or three header bytes.
                var header: usize = undefined;
                var len: usize = undefined;
                switch (size_format) {
                    0, 2 => {
                        header = 1;
                        len = in[0] >> 3;
                    },
                    1 => {
                        header = 2;
                        if (kind == 1 and in.len < 3) return f.fail(error.InvalidStream, 0, .bad_literals_header);
                        len = std.mem.readInt(u16, in[0..2], .little) >> 4;
                    },
                    3 => {
                        header = 3;
                        if (in.len < 3 + @as(usize, kind)) return f.fail(error.InvalidStream, 0, .bad_literals_header);
                        len = std.mem.readInt(u24, in[0..3], .little) >> 4;
                    },
                }
                if (len > f.block_max) return f.fail(error.InvalidStream, 0, .bad_literals_header);
                if (expected < len) return f.fail(error.OutputTooSmall, 0, .bad_literals_header);
                if (kind == 0) {
                    if (header + len > in.len) return f.fail(error.InvalidStream, 0, .bad_literals_header);
                    if (header + len + margin <= in.len) {
                        // Read in place: the block's own bytes follow.
                        lits.* = .{ .bytes = in[header..], .len = len, .in_out = null, .limit = f.out.len };
                    } else {
                        lits.* = f.literalStorage(len, op);
                        @memcpy(@constCast(lits.bytes[0..len]), in[header..][0..len]); // aegis: no-danger: literalStorage returns this decoder's writable scratch or output.
                    }
                    return header + len;
                }
                lits.* = f.literalStorage(len, op);
                @memset(@constCast(lits.bytes[0..len]), in[header]); // aegis: no-danger: literalStorage returns this decoder's writable scratch or output.
                return header + 1;
            },
            2, 3 => {
                if (kind == 3 and f.entropy.huffman == null) return f.fail(error.InvalidStream, 0, .treeless_first);
                if (in.len < 5) return f.fail(error.InvalidStream, 0, .bad_literals_header);
                const h = std.mem.readInt(u32, in[0..4], .little);
                var header: usize = undefined;
                var len: usize = undefined;
                var csize: usize = undefined;
                switch (size_format) {
                    0, 1 => {
                        header = 3;
                        len = (h >> 4) & 0x3ff;
                        csize = (h >> 14) & 0x3ff;
                    },
                    2 => {
                        header = 4;
                        len = (h >> 4) & 0x3fff;
                        csize = h >> 18;
                    },
                    3 => {
                        header = 5;
                        len = (h >> 4) & 0x3ffff;
                        csize = (h >> 22) + (@as(usize, in[4]) << 10);
                    },
                }
                const single = size_format == 0;
                if (len > f.block_max) return f.fail(error.InvalidStream, 0, .bad_literals_header);
                if (!single and len < 6) return f.fail(error.InvalidStream, 0, .bad_literals_header);
                if (csize + header > in.len) return f.fail(error.InvalidStream, 0, .bad_literals_header);
                if (expected < len) return f.fail(error.OutputTooSmall, 0, .bad_literals_header);
                const src = in[header..][0..csize];
                lits.* = f.literalStorage(len, op);
                const dst = @constCast(lits.bytes[0..len]); // aegis: no-danger: literalStorage returns this decoder's writable scratch or output.
                if (kind == 2) {
                    try f.huffmanTable(src, header, !single and huffman.chooseDouble(@truncate(len), @truncate(csize)));
                    const used = f.tables.weights.len;
                    if (used >= src.len) return f.fail(error.InvalidStream, header, .bad_huffman_weights);
                    try f.huffmanDecode(src[used..], dst, single, header);
                } else {
                    try f.huffmanDecode(src, dst, single, header);
                }
                return header + csize;
            },
        }
    }

    fn literalStorage(f: *Frame, len: usize, op: usize) Literals {
        // The literals section's caller has checked a section no longer
        // than a block or than the room left.
        aegis.assert.invariant(f.block_max <= block_max, "f.block_max <= block_max");
        aegis.assert.invariant(len <= f.block_max, "len <= f.block_max");
        aegis.assert.invariant(op <= f.out.len, "op <= f.out.len");
        aegis.assert.invariant(len <= f.out.len - op, "len <= f.out.len - op");
        const room = f.out.len - op;
        if (room <= f.block_max + 2 * margin + len and len + margin <= f.literal_buffer.len) {
            @memset(f.literal_buffer[len..][0..margin], 0);
            return .{ .bytes = f.literal_buffer, .len = len, .in_out = null, .limit = f.out.len };
        }
        return f.inOut(len, op);
    }

    fn inOut(f: *Frame, len: usize, op: usize) Literals {
        // The literals section's caller has checked a section no longer
        // than a block or than the room left.
        aegis.assert.invariant(f.block_max <= block_max, "f.block_max <= block_max");
        aegis.assert.invariant(len <= f.block_max, "len <= f.block_max");
        aegis.assert.invariant(op <= f.out.len, "op <= f.out.len");
        aegis.assert.invariant(len <= f.out.len - op, "len <= f.out.len - op");
        aegis.assert.invariant(len <= f.out.len, "len <= f.out.len");
        const room = f.out.len - op;
        const limit = if (room > f.block_max + margin + len + margin) op + f.block_max + margin else f.out.len;
        return .{ .bytes = f.out[f.out.len - len ..], .len = len, .in_out = f.out.len - len, .limit = limit };
    }

    fn huffmanTable(f: *Frame, src: []const u8, at: usize, double: bool) Error!void {
        f.tables.weights = aegis.input.Untrusted([]const u8).init(src).parse({}, huffman.readWeights) catch return f.fail(error.InvalidStream, at, .bad_huffman_weights);
        if (double) f.tables.huffman.buildDouble(&f.tables.weights) else f.tables.huffman.buildSingle(&f.tables.weights);
        f.entropy.huffman = &f.tables.huffman;
    }

    fn huffmanDecode(f: *Frame, src: []const u8, dst: []u8, single: bool, at: usize) Error!void {
        const table = f.entropy.huffman.?;
        if (single) {
            huffman.decode1(table, src, dst) catch return f.fail(error.InvalidStream, at, .literals_size);
        } else {
            if (src.len == 0) return f.fail(error.InvalidStream, at, .literals_size);
            huffman.decode4(table, src, dst) catch return f.fail(error.InvalidStream, at, .literals_size);
        }
    }

    // ---- sequences ----

    const SequenceHeader = struct {
        count: usize,
        /// The sequences' bitstream: the rest of the block.
        stream: []const u8,
        /// Where it starts in the block.
        at: usize,
    };

    fn sequenceHeader(f: *Frame, in: []const u8, lit_len: usize) Error!SequenceHeader {
        const at = lit_len;
        if (at >= in.len) return f.fail(error.InvalidStream, at, .bad_sequences_header);
        const parsed = aegis.input.Untrusted([]const u8).init(in[at..]).parse({}, sequenceCount) catch
            return f.fail(error.InvalidStream, at, .bad_sequences_header);
        const count: usize = parsed.count;
        // What is left of the block, cut as the header is read.
        var rest = in[at..][parsed.bytes..];
        if (count == 0) {
            if (rest.len != 0) return f.fail(error.InvalidStream, at, .bad_sequences_header);
        } else {
            if (rest.len == 0) return f.fail(error.InvalidStream, at, .bad_sequences_header);
            const modes = rest[0];
            if (modes & 3 != 0) return f.fail(error.InvalidStream, in.len - rest.len, .bad_sequences_header);
            rest = rest[1..];
            rest = try f.codeTable(fse.LlTable, &f.tables.ll, &f.entropy.ll, @truncate(modes >> 6), codes.max_ll, codes.max_ll_log, &codes.ll_base, &codes.ll_bits, &fse.ll_default, in, rest);
            rest = try f.codeTable(fse.OfTable, &f.tables.of, &f.entropy.of, @truncate(modes >> 4), codes.max_of, codes.max_of_log, &codes.of_base, &codes.of_bits, &fse.of_default, in, rest);
            rest = try f.codeTable(fse.MlTable, &f.tables.ml, &f.entropy.ml, @truncate(modes >> 2), codes.max_ml, codes.max_ml_log, &codes.ml_base, &codes.ml_bits, &fse.ml_default, in, rest);
            f.entropy.fse_ready = true;
        }
        return .{ .count = count, .stream = rest, .at = in.len - rest.len };
    }

    /// A sequences header's count, at most the format's 0xFFFF + 0x7F00,
    /// and the bytes that give it.
    const SequenceCount = struct { count: u17, bytes: u2 };

    /// The count at the start of `in`: one byte below 0x80, two from
    /// 0x80, three after 0xFF.
    fn sequenceCount(_: void, in: []const u8) error{Truncated}!SequenceCount {
        if (in.len == 0) return error.Truncated;
        const first = in[0];
        if (first < 0x80) return .{ .count = first, .bytes = 1 };
        if (first == 0xff) {
            if (in.len < 3) return error.Truncated;
            return .{ .count = @as(u17, std.mem.readInt(u16, in[1..3], .little)) + 0x7f00, .bytes = 3 };
        }
        if (in.len < 2) return error.Truncated;
        return .{ .count = (@as(u17, first - 0x80) << 8) | in[1], .bytes = 2 };
    }

    fn sequences(f: *Frame, comptime partial: bool, in: []const u8, lit_len: usize, op_start: usize, lits: *Literals) Error!usize {
        const header = try f.sequenceHeader(in, lit_len);
        const ip = header.at;
        const count = header.count;
        const at = lit_len;
        var op = op_start;
        var lp: usize = 0;
        if (count != 0) {
            if (f.out.len == op) {
                if (partial) {
                    f.stopped = true;
                    return 0;
                }
                return f.fail(error.OutputTooSmall, at, .bad_sequences_header);
            }
            f.entropy.fse_ready = true;
            // Where literals sit in the output ahead of the block's end, the
            // output may not overtake the next unread one; elsewhere the
            // block's limit is fixed.
            if (partial) {
                try f.execute(true, false, header.stream, count, &op, &lp, lits, ip);
                if (f.stopped) return op - op_start;
            } else if (lits.in_out != null and lits.limit == f.out.len) {
                try f.execute(false, true, header.stream, count, &op, &lp, lits, ip);
            } else {
                try f.execute(false, false, header.stream, count, &op, &lp, lits, ip);
            }
        }
        // The literals after the last sequence.
        const last = lits.len - lp;
        if (partial) {
            const n = @min(last, lits.limit - op);
            try f.readLiterals(lits.cursor.?, f.out[op..][0..n], at);
            f.stopped = n < last;
            op += n;
        } else {
            if (last > lits.limit - op) return f.fail(error.OutputTooSmall, ip, .bad_length);
            @memmove(f.out[op..][0..last], lits.bytes[lp..][0..last]);
            op += last;
        }
        return op - op_start;
    }

    /// Parse a block's headers in order, snapshotting its entropy for a worker.
    pub fn prepareBlock(f: *Frame, in: []const u8, prepared: *Prepared) Error!void {
        if (in.len > f.block_max) return f.fail(error.InvalidStream, 0, .block_too_large);
        var metadata: LiteralSection = .{ .bytes = 0, .len = 0 };
        const section = f.literalCursor(in, &prepared.cursor, &metadata) catch |err| {
            prepared.literal_len = metadata.len;
            prepared.literal_at = metadata.bytes;
            return err;
        };
        prepared.literal_len = section.len;
        prepared.literal_at = metadata.bytes;
        prepared.sequence_at = section.bytes;
        // The literals' table, as the core decodes them with it.
        switch (prepared.cursor) {
            .huffman => |*symbols| {
                if (symbols.table == &f.tables.huffman and symbols.table.kind == .single and huffman.chooseDouble(@truncate(section.len), @truncate(symbols.source.len))) f.tables.huffman.buildDouble(&f.tables.weights);
                prepared.tables.huffman = symbols.table.*;
                symbols.table = &prepared.tables.huffman;
            },
            else => {},
        }
        const header = f.sequenceHeader(in, section.bytes) catch |err| {
            // The core decodes a block's literals before it reads its
            // sequences header: a block wrong in both is refused for its
            // literals, which come first.
            prepared.decodeLiterals() catch |literal_err| return f.fail(literal_err, metadata.bytes, .literals_size);
            return err;
        };
        prepared.count = header.count;
        prepared.stream = header.stream;
        prepared.at = header.at;
        prepared.tables.ll = f.entropy.ll.*;
        prepared.tables.ml = f.entropy.ml.*;
        prepared.tables.of = f.entropy.of.*;
    }

    /// Execute an entropy-decoded block in order against the frame's history.
    pub fn applyBlock(f: *Frame, prepared: *const Prepared, op_start: usize) Error!usize {
        var o = op_start;
        var l: usize = 0;
        var rep0 = f.entropy.reps[0];
        var rep1 = f.entropy.reps[1];
        var rep2 = f.entropy.reps[2];
        const out = f.out;
        const prefix = f.start;
        const literal_len = prepared.literal_len;
        const at = prepared.at;
        const lit = prepared.literals;
        // The worker decoded `count` sequences into `seqs`.
        aegis.assert.invariant(prepared.count <= prepared.seqs.len, "prepared.count <= prepared.seqs.len");
        for (prepared.seqs[0..prepared.count]) |q| {
            const ll: usize = q.ll;
            const ml: usize = q.ml;
            var offset: u32 = undefined;
            if (q.off > 3) {
                offset = q.off - 3;
                rep2 = rep1;
                rep1 = rep0;
                rep0 = offset;
            } else if (q.off == 1) {
                offset = if (ll == 0) rep1 else rep0;
                rep1 = if (ll == 0) rep0 else rep1;
                rep0 = offset;
            } else {
                const index = q.off - 1 + @intFromBool(ll == 0);
                var distance: u32 = switch (index) {
                    1 => rep1,
                    2 => rep2,
                    else => rep0 -% 1,
                };
                if (distance == 0) distance = std.math.maxInt(u32);
                if (index != 1) rep2 = rep1;
                rep1 = rep0;
                rep0 = distance;
                offset = distance;
            }
            const o_lit = o + ll;
            const o_end = o_lit + ml;
            const l_end = l + ll;
            if (l_end <= literal_len and o_end <= out.len -| margin) {
                const dst = out.ptr + o;
                copy16(dst, lit.ptr + l);
                if (ll > 16) wildCopy16(dst + 16, lit.ptr + l + 16, ll - 16);
                if (offset <= o_lit - prefix) {
                    const match = out.ptr + o_lit;
                    aegis.assert.invariant(offset <= o_lit, "offset <= o_lit");
                    if (offset >= 16) wildCopy16(match, match - offset, ml) else overlapCopy(match, match - offset, offset, ml);
                } else try f.fromDictionary(o_lit, ml, offset - (o_lit - prefix), at);
            } else {
                try f.executeCarefully(o, lit, literal_len, l, ll, ml, offset, out.len, at);
            }
            o = o_end;
            l = l_end;
        }
        if (!prepared.complete) return f.fail(error.InvalidStream, at, .bitstream_left);
        // Each sequence read its literals from the section and wrote
        // inside the output.
        aegis.assert.invariant(literal_len <= lit.len, "literal_len <= lit.len");
        aegis.assert.invariant(l <= literal_len, "l <= literal_len");
        aegis.assert.invariant(o <= out.len, "o <= out.len");
        const rest = lit[l..literal_len];
        if (rest.len > out.len - o) return f.fail(error.OutputTooSmall, at, .bad_length);
        @memcpy(out[o..][0..rest.len], rest);
        const last = rest.len;
        f.entropy.reps = .{ rep0, rep1, rep2 };
        return o + last - op_start;
    }

    /// Set up one code's table from its mode, described at the start of
    /// `rest` (the end of the block `in`); returns what follows it.
    fn codeTable(
        f: *Frame,
        comptime T: type,
        own: *T,
        current: **const T,
        mode: u2,
        max: u8,
        max_log: u4,
        base: []const u32,
        extra: []const u8,
        default: *const T,
        in: []const u8,
        rest: []const u8,
    ) Error![]const u8 {
        const ip = in.len - rest.len;
        switch (mode) {
            0 => {
                current.* = default;
                return rest;
            },
            1 => {
                if (rest.len == 0) return f.fail(error.InvalidStream, ip, .bad_fse_table);
                if (rest[0] > max) return f.fail(error.InvalidStream, ip, .bad_fse_table);
                own.rle(rest[0], base, extra);
                current.* = own;
                return rest[1..];
            },
            2 => {
                const counts = aegis.input.Untrusted([]const u8).init(rest).parse(max, fse.readCounts) catch return f.fail(error.InvalidStream, ip, .bad_fse_table);
                if (counts.log > max_log) return f.fail(error.InvalidStream, ip, .bad_fse_table);
                own.build(counts.norm[0 .. @as(usize, counts.max_symbol) + 1], counts.log, base, extra);
                current.* = own;
                return rest[@min(rest.len, counts.len)..];
            },
            3 => {
                if (!f.entropy.fse_ready) return f.fail(error.InvalidStream, ip, .repeat_first);
                return rest;
            },
        }
    }

    /// Out of line: inlined into the frame loop, the sequence loop loses
    /// registers to it and runs 7-9% slower (measured on large frames).
    noinline fn execute(f: *Frame, comptime partial: bool, comptime behind_literals: bool, stream: []const u8, count: usize, op: *usize, lp: *usize, lits: *const Literals, at: usize) Error!void {
        var r = bits.Reader.init(stream) catch return f.fail(error.InvalidStream, at, .bitstream_left);
        var ll_state = readState(LlState, &r, f.entropy.ll.log);
        var of_state = readState(OfState, &r, f.entropy.of.log);
        var ml_state = readState(MlState, &r, f.entropy.ml.log);
        // The repeat offsets, most recent first, kept in registers.
        var rep = f.entropy.reps;
        const out = f.out;
        const prefix = f.start;
        const lit = lits.bytes.ptr;
        // Long literal runs can read up to 31 bytes past their end.
        const lit_fast_end = @min(lits.len, lits.bytes.len -| margin);
        var o = op.*;
        var l = lp.*;
        var n = count;
        // Fetch the next sequence's cells before copying this one's output.
        // The copies can cover the dependent table loads' latency; the final
        // sequence never reads an unused state or fetches another cell.
        // Each cell stays whole in one register and gives up its fields by
        // shifts: split into fields, three cells outgrow the registers.
        const tables: SequenceCells.Lookup = .init(&f.entropy);
        const lits_limit = lits.limit;
        const in_out = lits.in_out orelse 0;
        var next = SequenceCells.read(tables, ll_state, ml_state, of_state);
        while (n > 0) : (n -= 1) {
            // ---- decode ----
            const cell = next;
            const offset = SequenceCells.offset(cell, &r, &rep);
            const of_extra = SequenceCells.extra(cell.of);
            prefetchMatch(out, o, prefix, offset);
            const ml_extra = SequenceCells.extra(cell.ml);
            const ll_extra = SequenceCells.extra(cell.ll);
            // Lengths: a base below 2^17 and at most 16 extra bits.
            const ml_base: u17 = @truncate(SequenceCells.base(cell.ml));
            const ml_bits: u16 = if (ml_extra > 0) @truncate(r.readFast(ml_extra)) else 0;
            const ml: usize = @as(u32, ml_base) + ml_bits;
            if (@as(u32, of_extra) + ml_extra + ll_extra >= 64 - 7 - (9 + 9 + 8)) _ = r.reload();
            const ll_base: u17 = @truncate(SequenceCells.base(cell.ll));
            const ll_bits: u16 = if (ll_extra > 0) @truncate(r.readFast(ll_extra)) else 0;
            const ll: usize = @as(u32, ll_base) + ll_bits;
            if (n > 1) {
                ll_state = SequenceCells.nextState(LlState, cell.ll, &r);
                ml_state = SequenceCells.nextState(MlState, cell.ml, &r);
                of_state = SequenceCells.nextState(OfState, cell.of, &r);
                _ = r.reload();
                next = SequenceCells.read(tables, ll_state, ml_state, of_state);
            }

            // ---- execute ----
            if (partial) {
                aegis.assert.invariant(l <= lits.len, "l <= lits.len");
                try f.executePrefix(&o, lits.cursor.?, lits.len - l, ll, ml, offset, at);
                if (f.stopped) {
                    op.* = o;
                    return;
                }
                l += ll;
                continue;
            }
            const o_lit = o + ll;
            const o_end = o_lit + ml;
            const l_end = l + ll;
            // Writes stop short of the next unread literal and of the end.
            const write_limit = if (behind_literals) in_out + l_end else lits_limit;
            if (l_end <= lit_fast_end and o_end + margin <= write_limit) {
                @branchHint(.likely);
                const dst = out.ptr + o;
                wildCopy32(dst, lit + l, ll);
                l = l_end;
                const m = out.ptr + o_lit;
                if (offset <= o_lit - prefix) {
                    @branchHint(.likely);
                    aegis.assert.invariant(offset <= o_lit, "offset <= o_lit");
                    const src = m - offset;
                    if (offset >= 16) {
                        wildCopy32(m, src, ml);
                    } else {
                        overlapCopy(m, src, offset, ml);
                    }
                } else try f.fromDictionary(o_lit, ml, offset - (o_lit - prefix), at);
                o = o_end;
                continue;
            }
            // A literal length past the section puts the unread literal past
            // the output's end: the output's end comes first.
            try f.executeCarefully(o, lits.bytes, lits.len, l, ll, ml, offset, @min(write_limit, lits_limit), at);
            l = l_end;
            o = o_end;
        }
        if (!r.finished()) return f.fail(error.InvalidStream, at, .bitstream_left);
        f.entropy.reps = rep;
        op.* = o;
        lp.* = l;
    }

    /// A match from `back` bytes before the frame, in the dictionary, maybe
    /// running on into the frame: out of line, as the frame's history
    /// usually holds a match.
    noinline fn fromDictionary(f: *Frame, o_lit: usize, ml: usize, back: usize, at: usize) Error!void {
        if (back > f.dict.len) return f.fail(error.InvalidStream, at, .bad_offset);
        // The caller has room for the match, after the frame's start.
        aegis.assert.invariant(f.start <= o_lit, "f.start <= o_lit");
        aegis.assert.invariant(o_lit <= f.out.len, "o_lit <= f.out.len");
        aegis.assert.invariant(ml <= f.out.len - o_lit, "ml <= f.out.len - o_lit");
        const target = f.out[o_lit..][0..ml];
        const from = f.dict[f.dict.len - back ..];
        const first = @min(target.len, from.len);
        @memcpy(target[0..first], from[0..first]);
        if (first < target.len) repeat(target[first..].ptr, f.out[f.start..o_lit].ptr, target.len - first);
    }

    fn readLiterals(f: *Frame, cursor: *LiteralCursor, out: []u8, at: usize) Error!void {
        cursor.read(out) catch return f.fail(error.InvalidStream, at, .literals_size);
    }

    fn executePrefix(f: *Frame, op: *usize, cursor: *LiteralCursor, remaining: usize, ll: usize, ml: usize, offset: usize, at: usize) Error!void {
        const used = try f.executePartial(op.*, cursor, remaining, ll, ml, offset, at);
        op.* += used;
        f.stopped = used < ll + ml;
    }

    fn executePartial(f: *Frame, o: usize, cursor: *LiteralCursor, remaining: usize, ll: usize, ml: usize, offset: usize, at: usize) Error!usize {
        if (ll > remaining) return f.fail(error.InvalidStream, at, .bad_length);
        // The output so far is inside the output.
        aegis.assert.invariant(o <= f.out.len, "o <= f.out.len");
        const lit = @min(ll, f.out.len - o);
        try f.readLiterals(cursor, f.out[o..][0..lit], at);
        if (lit < ll) return lit;
        const start = o + lit;
        const match = @min(ml, f.out.len - start);
        if (offset > start - f.start) {
            try f.fromDictionary(start, match, offset - (start - f.start), at);
        } else {
            if (offset == 0) return f.fail(error.InvalidStream, at, .bad_offset);
            aegis.assert.invariant(start <= f.out.len, "start <= f.out.len");
            const written = f.out[0..start];
            aegis.assert.invariant(offset <= written.len, "offset <= written.len");
            repeat(f.out[start..].ptr, written[written.len - offset ..].ptr, match);
        }
        return lit + match;
    }

    /// One sequence with every bound checked and exact copies; the
    /// section's literals are `section[0..len]`, those from `l` not yet
    /// read, and `limit` the end of what it may write.
    fn executeCarefully(f: *Frame, o: usize, section: []const u8, len: usize, l: usize, ll: usize, ml: usize, offset: usize, limit: usize, at: usize) Error!void {
        // The literals read so far are a prefix of the section's.
        aegis.assert.invariant(len <= section.len, "len <= section.len");
        aegis.assert.invariant(l <= len, "l <= len");
        const lits = section[l..len];
        // The callers' limits are inside the output.
        aegis.assert.invariant(limit <= f.out.len, "limit <= f.out.len");
        const room = f.out[0..limit];
        if (o > room.len or ll + ml > room.len - o) return f.fail(error.OutputTooSmall, at, .bad_length);
        if (ll > lits.len) return f.fail(error.InvalidStream, at, .bad_length);
        aegis.assert.invariant(ll <= room.len - o, "ll <= room.len - o");
        @memmove(room[o..][0..ll], lits[0..ll]);
        const o_lit = o + ll;
        if (offset > o_lit - f.start) return f.fromDictionary(o_lit, ml, offset - (o_lit - f.start), at);
        // Behind the match, which the guard above keeps inside the room.
        aegis.assert.invariant(o_lit <= room.len, "o_lit <= room.len");
        const written = room[0..o_lit];
        aegis.assert.invariant(offset <= written.len, "offset <= written.len");
        repeat(room[o_lit..].ptr, written[written.len - offset ..].ptr, ml);
    }
};

/// The three independent lookups for one sequence, each cell whole.
/// A state of a sequence-code table: an index sized to the largest table
/// of its code (literal and match lengths 2^9 cells, offsets 2^8), so a
/// cell's next state plus the bits read after it, always below the table's
/// size, is an index into it by its type.
const LlState = u9;
const MlState = u9;
const OfState = u8;
comptime {
    std.debug.assert(codes.max_ll_log == @bitSizeOf(LlState));
    std.debug.assert(codes.max_ml_log == @bitSizeOf(MlState));
    std.debug.assert(codes.max_of_log == @bitSizeOf(OfState));
}

const SequenceCells = struct {
    ll: u64,
    ml: u64,
    of: u64,

    /// The three code tables of a block, held beside the loop that reads
    /// them: through the frame, a store to the output could change them, and
    /// the loop would load their addresses again for every sequence.
    const Lookup = struct {
        ll: *const [1 << codes.max_ll_log]fse.SeqCell,
        ml: *const [1 << codes.max_ml_log]fse.SeqCell,
        of: *const [1 << codes.max_of_log]fse.SeqCell,

        fn init(entropy: *const Entropy) Lookup {
            return .{ .ll = &entropy.ll.cells, .ml = &entropy.ml.cells, .of = &entropy.of.cells };
        }
    };

    inline fn read(tables: Lookup, ll: LlState, ml: MlState, of: OfState) SequenceCells {
        return .{
            .ll = @bitCast(tables.ll[ll]),
            .ml = @bitCast(tables.ml[ml]),
            .of = @bitCast(tables.of[of]),
        };
    }

    /// The offset of the sequence the cells describe, reading its bits and
    /// moving the repeat offsets: a code of more than one bit is an offset
    /// itself, and a shorter one a repeat of one of the three.
    inline fn offset(cells: SequenceCells, r: *bits.Reader, rep: *[3]u32) u32 {
        const of_extra = extra(cells.of);
        if (of_extra > 1) {
            // A base below 2^31 and fewer than 31 extra bits: the sum fits.
            const of_base: u31 = @truncate(base(cells.of));
            const of_bits: u31 = @truncate(r.readFast(of_extra));
            const value = @as(u32, of_base) + of_bits;
            rep[2] = rep[1];
            rep[1] = rep[0];
            rep[0] = value;
            return value;
        }
        const ll0 = base(cells.ll) == 0;
        if (of_extra == 0) {
            // Repeat 1, or repeat 2 after no literals.
            const value = if (ll0) rep[1] else rep[0];
            rep[1] = if (ll0) rep[0] else rep[1];
            rep[0] = value;
            return value;
        }
        // Repeat 2 or 3, or after no literals repeat 3 or repeat 1 less one.
        // A repeat code's base is 0 or 1: the index is 0 to 3.
        const rep_base: u1 = @truncate(base(cells.of));
        const rep_bit: u1 = @truncate(r.readFast(1));
        const index = @as(u32, rep_base) + @intFromBool(ll0) + rep_bit;
        var value: u32 = switch (index) {
            1 => rep[1],
            2 => rep[2],
            else => rep[0] -% 1,
        };
        // A repeat offset of zero is broken: made impossible.
        if (value == 0) value = std.math.maxInt(u32);
        if (index != 1) rep[2] = rep[1];
        rep[1] = rep[0];
        rep[0] = value;
        return value;
    }

    /// The cell's next state after its `stateBits` bits: below the
    /// table's size, so it fits the table's state type.
    inline fn nextState(comptime State: type, cell: u64, r: *bits.Reader) State {
        const base_state: State = @truncate(cell);
        const bits_read: State = @truncate(r.read(stateBits(cell)));
        return base_state +% bits_read;
    }

    inline fn extra(cell: u64) u6 {
        // safe: the extra bit counts of every code table are at most 31.
        return @truncate(cell >> 16);
    }

    inline fn stateBits(cell: u64) u6 {
        // safe: a state's bit count is at most the table's log, 9 or less.
        return @truncate(cell >> 24);
    }

    inline fn base(cell: u64) u32 {
        return @truncate(cell >> 32);
    }
};

/// Entropy-decoded sequences, with repeat codes still resolved in output order.
pub const PreparedSequence = struct { ll: u32, ml: u32, off: u32 };

/// A block's entropy snapshot and caller-provided literal and sequence storage.
pub const Prepared = struct {
    tables: Tables,
    cursor: LiteralCursor,
    literal_len: usize = 0,
    count: usize = 0,
    stream: []const u8 = &.{},
    at: usize = 0,
    literal_at: usize = 0,
    sequence_at: usize = 0,
    complete: bool = true,
    failure: Diagnostic.Reason = .bitstream_left,
    literals: []u8,
    seqs: []PreparedSequence,

    /// The block's literals, decoded into `literals`.
    pub fn decodeLiterals(prepared: *const Prepared) Error!void {
        switch (prepared.cursor) {
            .raw => |bytes| @memcpy(prepared.literals[0..prepared.literal_len], bytes),
            .rle => |byte| @memset(prepared.literals[0..prepared.literal_len], byte),
            .huffman => |symbols| {
                if (symbols.ends[0] == symbols.ends[3]) {
                    try huffman.decode1(symbols.table, symbols.source, prepared.literals[0..prepared.literal_len]);
                } else try huffman.decode4(symbols.table, symbols.source, prepared.literals[0..prepared.literal_len]);
            },
        }
    }

    pub fn decode(prepared: *Prepared) Error!void {
        prepared.failure = .literals_size;
        try prepared.decodeLiterals();
        prepared.failure = .bitstream_left;
        prepared.complete = true;
        if (prepared.count == 0) return;
        if (prepared.count > prepared.seqs.len) return error.InvalidStream;
        var r = try bits.Reader.init(prepared.stream);
        const ll_cells = &prepared.tables.ll.cells;
        const ml_cells = &prepared.tables.ml.cells;
        const of_cells = &prepared.tables.of.cells;
        var ll_state = readState(LlState, &r, prepared.tables.ll.log);
        var of_state = readState(OfState, &r, prepared.tables.of.log);
        var ml_state = readState(MlState, &r, prepared.tables.ml.log);
        for (prepared.seqs[0..prepared.count], 0..) |*sequence, i| {
            const llc = ll_cells[ll_state];
            const mlc = ml_cells[ml_state];
            const ofc = of_cells[of_state];
            // An offset code's base below 2^31 and fewer than 31 extra bits;
            // a length code's base below 2^17 and at most 16.
            const off = if (ofc.extra_bits > 1) blk: {
                const of_base: u31 = @truncate(ofc.base);
                const of_bits: u31 = @truncate(r.readFast(@truncate(ofc.extra_bits)));
                break :blk @as(u32, of_base) + of_bits + 3;
            } else if (ofc.extra_bits == 1) 2 + @as(u32, @as(u1, @truncate(r.readFast(1)))) else 1;
            const ml_base: u17 = @truncate(mlc.base);
            const ml_bits: u16 = if (mlc.extra_bits > 0) @truncate(r.readFast(@truncate(mlc.extra_bits))) else 0;
            const ml = @as(u32, ml_base) + ml_bits;
            if (@as(u32, ofc.extra_bits) + mlc.extra_bits + llc.extra_bits >= 64 - 7 - (9 + 9 + 8)) _ = r.reload();
            const ll_base: u17 = @truncate(llc.base);
            const ll_bits: u16 = if (llc.extra_bits > 0) @truncate(r.readFast(@truncate(llc.extra_bits))) else 0;
            const ll = @as(u32, ll_base) + ll_bits;
            sequence.* = .{ .ll = ll, .ml = ml, .off = off };
            if (i + 1 < prepared.count) {
                ll_state = SequenceCells.nextState(LlState, @bitCast(llc), &r);
                ml_state = SequenceCells.nextState(MlState, @bitCast(mlc), &r);
                of_state = SequenceCells.nextState(OfState, @bitCast(ofc), &r);
                _ = r.reload();
            }
        }
        prepared.complete = r.finished();
    }
};

pub const LiteralCursor = union(enum) {
    raw: []const u8,
    rle: u8,
    huffman: huffman.Symbols,

    fn read(c: *LiteralCursor, out: []u8) huffman.Error!void {
        switch (c.*) {
            .raw => |bytes| {
                if (out.len > bytes.len) return error.InvalidStream;
                @memcpy(out, bytes[0..out.len]);
                c.raw = bytes[out.len..];
            },
            .rle => |byte| @memset(out, byte),
            .huffman => |*symbols| try symbols.read(out),
        }
    }
};

inline fn copy16(dst: [*]u8, src: [*]const u8) void {
    const v: @Vector(16, u8) = src[0..16].*;
    dst[0..16].* = v;
}

inline fn copy8(dst: [*]u8, src: [*]const u8) void {
    const v: @Vector(8, u8) = src[0..8].*;
    dst[0..8].* = v;
}

/// Copy `len` bytes 16 at a time, writing up to 31 past the end; source
/// and destination at least 16 apart, or the source after.
inline fn wildCopy16(dst: [*]u8, src: [*]const u8, len: usize) void {
    copy16(dst, src);
    var i: usize = 16;
    while (i < len) : (i += 32) {
        copy16(dst + i, src + i);
        copy16(dst + i + 16, src + i + 16);
    }
}

/// Copy `len` bytes, the first 32 whatever `len` is (a short copy is the
/// common one, and a branch on its length mispredicts), 32 at a time after,
/// writing up to 31 past the end; source and destination at least 16 apart,
/// or the source after.
inline fn wildCopy32(dst: [*]u8, src: [*]const u8, len: usize) void {
    copy16(dst, src);
    copy16(dst + 16, src + 16);
    var i: usize = 32;
    while (i < len) : (i += 32) {
        copy16(dst + i, src + i);
        copy16(dst + i + 16, src + i + 16);
    }
}

/// A match closer than 16 bytes: its first 8 bytes laid down so that the
/// distance from source to destination becomes 8 or more (a multiple of
/// the offset), then 8 at a time. Writes up to 7 bytes past the end.
inline fn overlapCopy(dst_: [*]u8, src_: [*]const u8, offset: usize, len: usize) void {
    var dst = dst_;
    var src = src_;
    if (offset < 8) {
        // Bytes 4-7 repeat the pattern from `add` on; after the 8 bytes
        // the source has moved on by `advance`.
        const add = [8]u8{ 0, 1, 2, 1, 4, 4, 4, 4 };
        const advance = [8]u8{ 0, 1, 2, 2, 4, 3, 2, 1 };
        dst[0] = src[0];
        dst[1] = src[1];
        dst[2] = src[2];
        dst[3] = src[3];
        const v: @Vector(4, u8) = (src + add[offset])[0..4].*;
        dst[4..8].* = v;
        src += advance[offset];
    } else {
        copy8(dst, src);
        src += 8;
    }
    dst += 8;
    var i: usize = 8;
    while (i < len) : (i += 8) {
        copy8(dst, src);
        dst += 8;
        src += 8;
    }
}

/// Copy forward a byte at a time: where the source runs into the bytes
/// being written, they repeat, as a match does.
fn repeat(dst: [*]u8, src: [*]const u8, len: usize) void {
    for (0..len) |i| dst[i] = src[i];
}

/// A first state: `log` bits, the table's log, which its state type holds.
inline fn readState(comptime State: type, r: *bits.Reader, log: u4) State {
    const state: State = @truncate(r.read(log));
    _ = r.reload();
    return state;
}

/// Fetch a decoded prefix while its remaining sequence bits are read.
inline fn prefetchMatch(out: []u8, o: usize, prefix: usize, offset: usize) void {
    if (builtin.cpu.arch == .aarch64 and offset <= o - prefix) {
        aegis.assert.invariant(offset <= o, "offset <= o");
        @prefetch(out.ptr + o - offset, .{});
    }
}
