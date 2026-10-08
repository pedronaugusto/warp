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
                        const dst = f.out[f.out.len - len ..];
                        @memcpy(dst, in[header..][0..len]);
                        lits.* = f.inOut(len, op);
                    }
                    return header + len;
                }
                const dst = f.out[f.out.len - len ..];
                @memset(dst, in[header]);
                lits.* = f.inOut(len, op);
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
                const dst = f.out[f.out.len - len ..];
                if (kind == 2) {
                    try f.huffmanTable(src, header, !single and huffman.chooseDouble(len, csize));
                    const used = f.tables.weights.len;
                    if (used >= src.len) return f.fail(error.InvalidStream, header, .bad_huffman_weights);
                    try f.huffmanDecode(src[used..], dst, single, header);
                } else {
                    try f.huffmanDecode(src, dst, single, header);
                }
                lits.* = f.inOut(len, op);
                return header + csize;
            },
        }
    }

    fn inOut(f: *Frame, len: usize, op: usize) Literals {
        const room = f.out.len - op;
        const limit = if (room > f.block_max + margin + len + margin) op + f.block_max + margin else f.out.len;
        return .{ .bytes = f.out[f.out.len - len ..], .len = len, .in_out = f.out.len - len, .limit = limit };
    }

    fn huffmanTable(f: *Frame, src: []const u8, at: usize, double: bool) Error!void {
        huffman.readWeights(src, &f.tables.weights) catch return f.fail(error.InvalidStream, at, .bad_huffman_weights);
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

    const SequenceHeader = struct { count: usize, ip: usize };

    fn sequenceHeader(f: *Frame, in: []const u8, lit_len: usize) Error!SequenceHeader {
        var ip = lit_len;
        const at = ip;
        if (ip >= in.len) return f.fail(error.InvalidStream, at, .bad_sequences_header);
        var count: usize = in[ip];
        ip += 1;
        if (count > 0x7f) {
            if (count == 0xff) {
                if (ip + 2 > in.len) return f.fail(error.InvalidStream, at, .bad_sequences_header);
                count = @as(usize, std.mem.readInt(u16, in[ip..][0..2], .little)) + 0x7f00;
                ip += 2;
            } else {
                if (ip >= in.len) return f.fail(error.InvalidStream, at, .bad_sequences_header);
                count = ((count - 0x80) << 8) + in[ip];
                ip += 1;
            }
        }
        if (count == 0) {
            if (ip != in.len) return f.fail(error.InvalidStream, at, .bad_sequences_header);
        } else {
            if (ip >= in.len) return f.fail(error.InvalidStream, at, .bad_sequences_header);
            const modes = in[ip];
            if (modes & 3 != 0) return f.fail(error.InvalidStream, ip, .bad_sequences_header);
            ip += 1;
            ip += try f.codeTable(fse.LlTable, &f.tables.ll, &f.entropy.ll, @truncate(modes >> 6), codes.max_ll, codes.max_ll_log, &codes.ll_base, &codes.ll_bits, &fse.ll_default, in, ip);
            ip += try f.codeTable(fse.OfTable, &f.tables.of, &f.entropy.of, @truncate(modes >> 4), codes.max_of, codes.max_of_log, &codes.of_base, &codes.of_bits, &fse.of_default, in, ip);
            ip += try f.codeTable(fse.MlTable, &f.tables.ml, &f.entropy.ml, @truncate(modes >> 2), codes.max_ml, codes.max_ml_log, &codes.ml_base, &codes.ml_bits, &fse.ml_default, in, ip);
            f.entropy.fse_ready = true;
        }
        return .{ .count = count, .ip = ip };
    }

    fn sequences(f: *Frame, comptime partial: bool, in: []const u8, lit_len: usize, op_start: usize, lits: *Literals) Error!usize {
        const header = try f.sequenceHeader(in, lit_len);
        const ip = header.ip;
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
                try f.execute(true, false, in[ip..], count, &op, &lp, lits, ip);
                if (f.stopped) return op - op_start;
            } else if (lits.in_out != null and lits.limit == f.out.len) {
                try f.execute(false, true, in[ip..], count, &op, &lp, lits, ip);
            } else {
                try f.execute(false, false, in[ip..], count, &op, &lp, lits, ip);
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
            if (last > lits.limit - op) return f.fail(error.OutputTooSmall, at, .bad_length);
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
        const header = try f.sequenceHeader(in, section.bytes);
        prepared.count = header.count;
        prepared.stream = in[header.ip..];
        prepared.at = header.ip;
        prepared.tables.ll = f.entropy.ll.*;
        prepared.tables.ml = f.entropy.ml.*;
        prepared.tables.of = f.entropy.of.*;
        switch (prepared.cursor) {
            .huffman => |*symbols| {
                if (symbols.table == &f.tables.huffman and symbols.table.kind == .single and huffman.chooseDouble(section.len, symbols.source.len)) f.tables.huffman.buildDouble(&f.tables.weights);
                prepared.tables.huffman = symbols.table.*;
                symbols.table = &prepared.tables.huffman;
            },
            else => {},
        }
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
        const dict = f.dict;
        const literal_len = prepared.literal_len;
        const at = prepared.at;
        const lit = prepared.literals;
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
                    if (offset >= 16) wildCopy16(match, match - offset, ml) else overlapCopy(match, match - offset, offset, ml);
                } else {
                    const back = offset - (o_lit - prefix);
                    if (back > dict.len) return f.fail(error.InvalidStream, at, .bad_offset);
                    const first = @min(ml, back);
                    @memcpy(out[o_lit..][0..first], dict[dict.len - back ..][0..first]);
                    if (first < ml) repeat(out[o_lit + first ..].ptr, out[prefix..].ptr, ml - first);
                }
            } else {
                try f.executeCarefully(o, lit[l..literal_len], ll, ml, offset, out.len, at);
            }
            o = o_end;
            l = l_end;
        }
        if (!prepared.complete) return f.fail(error.InvalidStream, at, .bitstream_left);
        const last = literal_len - l;
        if (last > out.len - o) return f.fail(error.OutputTooSmall, at, .bad_length);
        @memcpy(out[o..][0..last], lit[l..][0..last]);
        f.entropy.reps = .{ rep0, rep1, rep2 };
        return o + last - op_start;
    }

    /// Set up one code's table from its mode; returns the bytes of its
    /// description.
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
        ip: usize,
    ) Error!usize {
        switch (mode) {
            0 => {
                current.* = default;
                return 0;
            },
            1 => {
                if (ip >= in.len) return f.fail(error.InvalidStream, ip, .bad_fse_table);
                if (in[ip] > max) return f.fail(error.InvalidStream, ip, .bad_fse_table);
                own.rle(in[ip], base, extra);
                current.* = own;
                return 1;
            },
            2 => {
                var counts: fse.Counts = undefined;
                fse.readCounts(in[ip..], max, &counts) catch return f.fail(error.InvalidStream, ip, .bad_fse_table);
                if (counts.log > max_log) return f.fail(error.InvalidStream, ip, .bad_fse_table);
                own.build(counts.norm[0 .. @as(usize, counts.max_symbol) + 1], counts.log, base, extra);
                current.* = own;
                return counts.len;
            },
            3 => {
                if (!f.entropy.fse_ready) return f.fail(error.InvalidStream, ip, .repeat_first);
                return 0;
            },
        }
    }

    /// Out of line: inlined into the frame loop, the sequence loop loses
    /// registers to it and runs 7-9% slower (measured on large frames).
    noinline fn execute(f: *Frame, comptime partial: bool, comptime behind_literals: bool, stream: []const u8, count: usize, op: *usize, lp: *usize, lits: *const Literals, at: usize) Error!void {
        var r = bits.Reader.init(stream) catch return f.fail(error.InvalidStream, at, .bitstream_left);
        const ll_cells = &f.entropy.ll.cells;
        const of_cells = &f.entropy.of.cells;
        const ml_cells = &f.entropy.ml.cells;
        var ll_state = readState(&r, f.entropy.ll.log);
        var of_state = readState(&r, f.entropy.of.log);
        var ml_state = readState(&r, f.entropy.ml.log);
        // The repeat offsets, most recent first, kept in registers.
        var rep0 = f.entropy.reps[0];
        var rep1 = f.entropy.reps[1];
        var rep2 = f.entropy.reps[2];
        const out = f.out;
        const prefix = f.start;
        const lit = lits.bytes.ptr;
        // The fast loop reads 16 bytes from the last literal it copies.
        const lit_fast_end = @min(lits.len, lits.bytes.len -| 16);
        var o = op.*;
        var l = lp.*;
        var n = count;
        while (n > 0) : (n -= 1) {
            // ---- decode ----
            const llc = ll_cells[ll_state];
            const mlc = ml_cells[ml_state];
            const ofc = of_cells[of_state];
            var offset: u32 = undefined;
            if (ofc.extra_bits > 1) {
                offset = ofc.base + @as(u32, @intCast(r.readFast(@intCast(ofc.extra_bits))));
                rep2 = rep1;
                rep1 = rep0;
                rep0 = offset;
            } else {
                const ll0 = llc.base == 0;
                if (ofc.extra_bits == 0) {
                    // Repeat 1, or repeat 2 after no literals.
                    offset = if (ll0) rep1 else rep0;
                    rep1 = if (ll0) rep0 else rep1;
                    rep0 = offset;
                } else {
                    // Repeat 2 or 3, or after no literals repeat 3 or
                    // repeat 1 less one.
                    const index = ofc.base + @intFromBool(ll0) + @as(u32, @intCast(r.readFast(1)));
                    var rep: u32 = switch (index) {
                        1 => rep1,
                        2 => rep2,
                        else => rep0 -% 1,
                    };
                    // A repeat offset of zero is broken: made impossible.
                    if (rep == 0) rep = std.math.maxInt(u32);
                    if (index != 1) rep2 = rep1;
                    rep1 = rep0;
                    rep0 = rep;
                    offset = rep;
                }
            }
            var ml: usize = mlc.base;
            if (mlc.extra_bits > 0) ml += @intCast(r.readFast(@intCast(mlc.extra_bits)));
            if (@as(u32, ofc.extra_bits) + mlc.extra_bits + llc.extra_bits >= 64 - 7 - (9 + 9 + 8)) _ = r.reload();
            var ll: usize = llc.base;
            if (llc.extra_bits > 0) ll += @intCast(r.readFast(@intCast(llc.extra_bits)));
            if (n > 1) {
                ll_state = llc.next_state + @as(u32, @intCast(r.read(@intCast(llc.nb_bits))));
                ml_state = mlc.next_state + @as(u32, @intCast(r.read(@intCast(mlc.nb_bits))));
                of_state = ofc.next_state + @as(u32, @intCast(r.read(@intCast(ofc.nb_bits))));
                _ = r.reload();
            }

            // ---- execute ----
            if (partial) {
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
            const write_limit = if (behind_literals) lits.in_out.? + l_end else lits.limit;
            if (l_end <= lit_fast_end and o_end + margin <= write_limit) {
                @branchHint(.likely);
                const dst = out.ptr + o;
                copy16(dst, lit + l);
                if (ll > 16) wildCopy16(dst + 16, lit + l + 16, ll - 16);
                l = l_end;
                const m = out.ptr + o_lit;
                if (offset <= o_lit - prefix) {
                    @branchHint(.likely);
                    const src = m - offset;
                    if (offset >= 16) {
                        wildCopy16(m, src, ml);
                    } else {
                        overlapCopy(m, src, offset, ml);
                    }
                } else {
                    // From the dictionary, maybe on into the frame.
                    const back = offset - (o_lit - prefix);
                    if (back > f.dict.len) return f.fail(error.InvalidStream, at, .bad_offset);
                    const first = @min(ml, back);
                    @memcpy(m[0..first], f.dict[f.dict.len - back ..][0..first]);
                    if (first < ml) repeat(m + first, out.ptr + prefix, ml - first);
                }
                o = o_end;
                continue;
            }
            // A literal length past the section puts the unread literal past
            // the output's end: the output's end comes first.
            try f.executeCarefully(o, lits.bytes[l..lits.len], ll, ml, offset, @min(write_limit, lits.limit), at);
            l = l_end;
            o = o_end;
        }
        if (!r.finished()) return f.fail(error.InvalidStream, at, .bitstream_left);
        f.entropy.reps = .{ rep0, rep1, rep2 };
        op.* = o;
        lp.* = l;
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
        const lit = @min(ll, f.out.len - o);
        try f.readLiterals(cursor, f.out[o..][0..lit], at);
        if (lit < ll) return lit;
        const start = o + lit;
        const match = @min(ml, f.out.len - start);
        if (offset > start - f.start) {
            const back = offset - (start - f.start);
            if (back > f.dict.len) return f.fail(error.InvalidStream, at, .bad_offset);
            const first = @min(match, back);
            @memcpy(f.out[start..][0..first], f.dict[f.dict.len - back ..][0..first]);
            if (first < match) repeat(f.out[start + first ..].ptr, f.out[f.start..].ptr, match - first);
        } else {
            if (offset == 0) return f.fail(error.InvalidStream, at, .bad_offset);
            repeat(f.out[start..].ptr, f.out[start - offset ..].ptr, match);
        }
        return lit + match;
    }

    /// One sequence with every bound checked and exact copies; `lits` are
    /// the literals not yet read, `limit` the end of what it may write.
    fn executeCarefully(f: *Frame, o: usize, lits: []const u8, ll: usize, ml: usize, offset: usize, limit: usize, at: usize) Error!void {
        const out = f.out;
        if (o > limit or ll + ml > limit - o) return f.fail(error.OutputTooSmall, at, .bad_length);
        if (ll > lits.len) return f.fail(error.InvalidStream, at, .bad_length);
        @memmove(out[o..][0..ll], lits[0..ll]);
        const o_lit = o + ll;
        if (offset > o_lit - f.start) {
            // Into the dictionary, maybe on into the frame.
            const back = offset - (o_lit - f.start);
            if (back > f.dict.len) return f.fail(error.InvalidStream, at, .bad_offset);
            const first = @min(ml, back);
            @memcpy(out[o_lit..][0..first], f.dict[f.dict.len - back ..][0..first]);
            if (first < ml) repeat(out[o_lit + first ..].ptr, out[f.start..].ptr, ml - first);
            return;
        }
        repeat(out[o_lit..].ptr, out[o_lit - offset ..].ptr, ml);
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

    pub fn decode(prepared: *Prepared) Error!void {
        prepared.failure = .literals_size;
        switch (prepared.cursor) {
            .raw => |bytes| @memcpy(prepared.literals[0..prepared.literal_len], bytes),
            .rle => |byte| @memset(prepared.literals[0..prepared.literal_len], byte),
            .huffman => |symbols| {
                if (symbols.ends[0] == symbols.ends[3]) {
                    try huffman.decode1(symbols.table, symbols.source, prepared.literals[0..prepared.literal_len]);
                } else try huffman.decode4(symbols.table, symbols.source, prepared.literals[0..prepared.literal_len]);
            },
        }
        prepared.failure = .bitstream_left;
        prepared.complete = true;
        if (prepared.count == 0) return;
        if (prepared.count > prepared.seqs.len) return error.InvalidStream;
        var r = try bits.Reader.init(prepared.stream);
        const ll_cells = &prepared.tables.ll.cells;
        const ml_cells = &prepared.tables.ml.cells;
        const of_cells = &prepared.tables.of.cells;
        var ll_state = readState(&r, prepared.tables.ll.log);
        var of_state = readState(&r, prepared.tables.of.log);
        var ml_state = readState(&r, prepared.tables.ml.log);
        for (prepared.seqs[0..prepared.count], 0..) |*sequence, i| {
            const llc = ll_cells[ll_state];
            const mlc = ml_cells[ml_state];
            const ofc = of_cells[of_state];
            const off = if (ofc.extra_bits > 1) ofc.base + @as(u32, @intCast(r.readFast(@intCast(ofc.extra_bits)))) + 3 else if (ofc.extra_bits == 1) 2 + @as(u32, @intCast(r.readFast(1))) else 1;
            var ml = mlc.base;
            if (mlc.extra_bits > 0) ml += @intCast(r.readFast(@intCast(mlc.extra_bits)));
            if (@as(u32, ofc.extra_bits) + mlc.extra_bits + llc.extra_bits >= 64 - 7 - (9 + 9 + 8)) _ = r.reload();
            var ll = llc.base;
            if (llc.extra_bits > 0) ll += @intCast(r.readFast(@intCast(llc.extra_bits)));
            sequence.* = .{ .ll = ll, .ml = ml, .off = off };
            if (i + 1 < prepared.count) {
                ll_state = llc.next_state + @as(u32, @intCast(r.read(@intCast(llc.nb_bits))));
                ml_state = mlc.next_state + @as(u32, @intCast(r.read(@intCast(mlc.nb_bits))));
                of_state = ofc.next_state + @as(u32, @intCast(r.read(@intCast(ofc.nb_bits))));
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

/// Copy `len` bytes 16 at a time, writing up to 15 past the end; source
/// and destination at least 16 apart, or the source after.
inline fn wildCopy16(dst: [*]u8, src: [*]const u8, len: usize) void {
    var i: usize = 0;
    while (true) {
        copy16(dst + i, src + i);
        i += 16;
        if (i >= len) break;
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

inline fn readState(r: *bits.Reader, log: u4) u32 {
    const state: u32 = @intCast(r.read(log));
    _ = r.reload();
    return state;
}
