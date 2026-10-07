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
        return f.sequences(in, lit_len, op, &lits);
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

    fn sequences(f: *Frame, in: []const u8, lit_len: usize, op_start: usize, lits: *const Literals) Error!usize {
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
        var op = op_start;
        var lp: usize = 0;
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
            if (f.out.len == op) return f.fail(error.OutputTooSmall, at, .bad_sequences_header);
            f.entropy.fse_ready = true;
            try f.execute(in[ip..], count, &op, &lp, lits, ip);
        }
        // The literals after the last sequence.
        const last = lits.len - lp;
        if (last > lits.limit - op) return f.fail(error.OutputTooSmall, at, .bad_length);
        @memmove(f.out[op..][0..last], lits.bytes[lp..][0..last]);
        op += last;
        return op - op_start;
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
    noinline fn execute(f: *Frame, stream: []const u8, count: usize, op: *usize, lp: *usize, lits: *const Literals, at: usize) Error!void {
        var r = bits.Reader.init(stream) catch return f.fail(error.InvalidStream, at, .bitstream_left);
        const ll_cells = &f.entropy.ll.cells;
        const of_cells = &f.entropy.of.cells;
        const ml_cells = &f.entropy.ml.cells;
        var ll_state: u32 = @intCast(r.read(f.entropy.ll.log));
        _ = r.reload();
        var of_state: u32 = @intCast(r.read(f.entropy.of.log));
        _ = r.reload();
        var ml_state: u32 = @intCast(r.read(f.entropy.ml.log));
        _ = r.reload();
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
            const o_lit = o + ll;
            const o_end = o_lit + ml;
            const l_end = l + ll;
            // Writes stop short of the next unread literal and of the end.
            const write_limit = if (lits.in_out) |base| @min(base + l_end, lits.limit) else lits.limit;
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
            try f.executeCarefully(o, lits.bytes[l..lits.len], ll, ml, offset, write_limit, at);
            l = l_end;
            o = o_end;
        }
        if (!r.finished()) return f.fail(error.InvalidStream, at, .bitstream_left);
        f.entropy.reps = .{ rep0, rep1, rep2 };
        op.* = o;
        lp.* = l;
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
