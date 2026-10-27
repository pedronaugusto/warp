//! The bzip2 engine: a stream's header, each block's header, selectors and
//! code tables, its symbols through move-to-front into the BWT vector, the
//! inverse BWT with the run-length stage and the block's CRC, and the
//! stream's end. Every check is the format reference's (libbz2 1.0.8), made
//! in its order, so a stream is refused for the reason 1.0.8 gives.
//!
//! The engine reads in units: a header field, one selector, one step of a
//! code length, one symbol. A unit that runs out of input rolls back to its
//! start and the engine returns `NeedInput`, so the same engine decodes a
//! whole buffer (where that is truncation) and input given in pieces.

const std = @import("std");
const aegis = @import("aegis");
const bits_ = @import("bits.zig");
const huffman = @import("huffman.zig");
const crc_ = @import("../checksum/crc32bzip2.zig");
const Diagnostic = @import("Diagnostic.zig");

const Reader = bits_.Reader;

/// The largest block: level 9's.
pub const block_max = 900_000;
/// Selectors kept; 1.0.8 reads more and ignores them (CVE-2019-12900).
pub const max_selectors = 2 + block_max / group_size;
const group_size = 50;
const max_groups = 6;
/// The longest run RUNA and RUNB may spell: their weight stops doubling here.
const max_run_weight = 2 * 1024 * 1024;

pub const Error = error{
    /// Not a bzip2 stream, or one that breaks the format as 1.0.8 reads it.
    InvalidStream,
    /// A block's or the stream's CRC does not match.
    ChecksumMismatch,
};

pub const Status = enum {
    /// The output is full; the next call goes on.
    output_full,
    /// The stream ended, at a byte boundary.
    stream_end,
};

const Phase = enum { stream_magic, block_magic, block_header, used16, used, groups, selectors, code_start, code_lengths, symbols, output, stream_crc, done };

/// `read`: a part is read and the next in order follows. `end`: the end
/// magic where a block's would be. `more`: another table's code lengths.
const Event = enum { read, end, more };

const Machine = aegis.state.Machine(Phase, Event, .{ .initial = .stream_magic, .terminal = &.{.done}, .edges = &.{
    .{ .from = .stream_magic, .on = .read, .to = .block_magic },
    .{ .from = .block_magic, .on = .read, .to = .block_header },
    .{ .from = .block_magic, .on = .end, .to = .stream_crc },
    .{ .from = .block_header, .on = .read, .to = .used16 },
    .{ .from = .used16, .on = .read, .to = .used },
    .{ .from = .used, .on = .read, .to = .groups },
    .{ .from = .groups, .on = .read, .to = .selectors },
    .{ .from = .selectors, .on = .read, .to = .code_start },
    .{ .from = .code_start, .on = .read, .to = .code_lengths },
    .{ .from = .code_lengths, .on = .more, .to = .code_start },
    .{ .from = .code_lengths, .on = .read, .to = .symbols },
    .{ .from = .symbols, .on = .read, .to = .output },
    .{ .from = .output, .on = .read, .to = .block_magic },
    .{ .from = .stream_crc, .on = .read, .to = .done },
} });

/// 1.0.8's `BZ2_rNums`: where a randomised block's bytes were flipped.
const random_numbers = [512]u16{
    619, 720, 127, 481, 931, 816, 813, 233, 566, 247, 985, 724, 205, 454, 863, 491,
    741, 242, 949, 214, 733, 859, 335, 708, 621, 574, 73,  654, 730, 472, 419, 436,
    278, 496, 867, 210, 399, 680, 480, 51,  878, 465, 811, 169, 869, 675, 611, 697,
    867, 561, 862, 687, 507, 283, 482, 129, 807, 591, 733, 623, 150, 238, 59,  379,
    684, 877, 625, 169, 643, 105, 170, 607, 520, 932, 727, 476, 693, 425, 174, 647,
    73,  122, 335, 530, 442, 853, 695, 249, 445, 515, 909, 545, 703, 919, 874, 474,
    882, 500, 594, 612, 641, 801, 220, 162, 819, 984, 589, 513, 495, 799, 161, 604,
    958, 533, 221, 400, 386, 867, 600, 782, 382, 596, 414, 171, 516, 375, 682, 485,
    911, 276, 98,  553, 163, 354, 666, 933, 424, 341, 533, 870, 227, 730, 475, 186,
    263, 647, 537, 686, 600, 224, 469, 68,  770, 919, 190, 373, 294, 822, 808, 206,
    184, 943, 795, 384, 383, 461, 404, 758, 839, 887, 715, 67,  618, 276, 204, 918,
    873, 777, 604, 560, 951, 160, 578, 722, 79,  804, 96,  409, 713, 940, 652, 934,
    970, 447, 318, 353, 859, 672, 112, 785, 645, 863, 803, 350, 139, 93,  354, 99,
    820, 908, 609, 772, 154, 274, 580, 184, 79,  626, 630, 742, 653, 282, 762, 623,
    680, 81,  927, 626, 789, 125, 411, 521, 938, 300, 821, 78,  343, 175, 128, 250,
    170, 774, 972, 275, 999, 639, 495, 78,  352, 126, 857, 956, 358, 619, 580, 124,
    737, 594, 701, 612, 669, 112, 134, 694, 363, 992, 809, 743, 168, 974, 944, 375,
    748, 52,  600, 747, 642, 182, 862, 81,  344, 805, 988, 739, 511, 655, 814, 334,
    249, 515, 897, 955, 664, 981, 649, 113, 974, 459, 893, 228, 433, 837, 553, 268,
    926, 240, 102, 654, 459, 51,  686, 754, 806, 760, 493, 403, 415, 394, 687, 700,
    946, 670, 656, 610, 738, 392, 760, 799, 887, 653, 978, 321, 576, 617, 626, 502,
    894, 679, 243, 440, 680, 879, 194, 572, 640, 724, 926, 56,  204, 700, 707, 151,
    457, 449, 797, 195, 791, 558, 945, 679, 297, 59,  87,  824, 713, 663, 412, 693,
    342, 606, 134, 108, 571, 364, 631, 212, 174, 643, 304, 329, 343, 97,  430, 751,
    497, 314, 983, 374, 822, 928, 140, 206, 73,  263, 980, 736, 876, 478, 430, 305,
    170, 514, 364, 692, 829, 82,  855, 953, 676, 246, 369, 970, 294, 750, 807, 827,
    150, 790, 288, 923, 804, 378, 215, 828, 592, 281, 565, 555, 710, 82,  896, 831,
    547, 261, 524, 462, 293, 465, 502, 56,  661, 821, 976, 991, 658, 869, 905, 758,
    745, 193, 768, 550, 608, 933, 378, 286, 215, 979, 792, 961, 61,  688, 793, 644,
    986, 403, 106, 366, 905, 644, 372, 567, 466, 434, 645, 210, 389, 550, 919, 135,
    780, 773, 635, 389, 707, 100, 626, 958, 165, 504, 920, 176, 193, 713, 857, 265,
    203, 50,  668, 108, 645, 990, 626, 197, 510, 357, 358, 850, 858, 364, 936, 638,
};

/// The code tables of a block.
pub const Tables = [max_groups]huffman.Table;

/// Where a stream is: everything the engine keeps between units, beside
/// the BWT vector and code tables its owner holds.
pub const State = struct {
    phase: Phase = .stream_magic,
    /// The block size in 100 kB units, 1-9.
    level: u32 = 0,
    /// The stream's CRC so far, from its blocks'.
    combined: u32 = 0,

    // The block's header.
    block_crc: u32 = 0,
    randomised: bool = false,
    orig_ptr: u32 = 0,
    used16: u16 = 0,
    /// The next row of the in-use map, then the next selector, code-length
    /// table or symbol: the index of the part being read.
    at: u32 = 0,
    seq_to_unseq: [256]u8 = undefined,
    in_use: u32 = 0,
    groups: u32 = 0,
    selector_count: u32 = 0,
    /// The selectors' move-to-front list.
    selector_mtf: [max_groups]u8 = undefined,
    selectors: [max_selectors]u8 = undefined,
    /// The code table being read, its length so far.
    table: u32 = 0,
    curr: u32 = 0,
    lens: [max_alpha_size]u8 = undefined,

    // The symbols.
    mtf: [256]u8 = undefined,
    counts: [256]u32 = undefined,
    nblock: u32 = 0,
    /// Symbols left of the current group; the next selector.
    group_left: u32 = 0,
    group: u32 = 0,
    /// A run of RUNA and RUNB: its length so far, and the next symbol's
    /// weight.
    run: u32 = 0,
    run_weight: u32 = 0,

    // The output.
    pos: u32 = 0,
    reads: u32 = 0,
    last: u8 = 0,
    same: u8 = 0,
    repeat: u32 = 0,
    rand_to_go: u32 = 0,
    rand_at: u32 = 0,
    crc: u32 = 0,

    /// Where the refused unit starts, and why.
    fail_bit: u64 = 0,
    reason: Diagnostic.Reason = .truncated,

    /// The one place the phase changes: along a declared edge.
    fn go(s: *State, comptime from: Phase, comptime on: Event) void {
        s.phase = comptime Machine.after(from, on);
    }

    /// A stream of `level` at a block's magic, as if its header were read:
    /// where a block found by its magic is decoded on its own.
    pub fn atBlock(level: u32) State {
        var s: State = .{ .level = level };
        s.go(.stream_magic, .read);
        return s;
    }

    /// A block's CRC into the stream's, as the block ends.
    pub fn join(s: *State, block_crc: u32) void {
        s.combined = std.math.rotl(u32, s.combined, 1) ^ block_crc;
    }

    /// Whether the stream has ended.
    pub fn done(s: *const State) bool {
        return s.phase == .done;
    }

    fn fail(s: *State, at: u64, reason: Diagnostic.Reason) Error {
        s.fail_bit = at;
        s.reason = reason;
        return if (reason == .block_crc or reason == .stream_crc) error.ChecksumMismatch else error.InvalidStream;
    }
};

const max_alpha_size = huffman.max_alpha;

/// What the engine works in: the BWT vector (`block_max` entries) and the
/// code tables.
pub const Work = struct {
    tt: []u32,
    tables: *Tables,
};

/// Run the stream from `s` over `r` until it ends or `out` is full;
/// `out[op.*..]` takes the output. `NeedInput` leaves `r` at the start of
/// the unit it could not finish.
pub fn run(s: *State, w: Work, r: *Reader, out: []u8, op: *usize) (Error || bits_.NeedInput)!Status {
    while (true) switch (try runBlock(s, w, r, out, op)) {
        .output_full => return .output_full,
        .stream_end => return .stream_end,
        .boundary => {},
    };
}

pub const BlockStatus = enum {
    /// The output is full; the next call goes on.
    output_full,
    /// At a block's magic: the stream's header or a block is read.
    boundary,
    /// The stream ended, at a byte boundary.
    stream_end,
};

/// `run`, stopping at the next block boundary: what a block decoded on its
/// own, and a decoder joining such blocks, run to.
pub fn runBlock(s: *State, w: Work, r: *Reader, out: []u8, op: *usize) (Error || bits_.NeedInput)!BlockStatus {
    while (true) {
        const m = r.mark();
        const at = r.bitOffset();
        unit(s, w, r, out, op, at) catch |err| switch (err) {
            error.NeedInput => {
                // The symbols roll back one symbol, not the run of them.
                if (s.phase != .symbols) r.restore(m);
                return error.NeedInput;
            },
            error.OutputFull => return .output_full,
            else => |e| return e,
        };
        switch (s.phase) {
            .done => return .stream_end,
            .block_magic => return .boundary,
            else => {},
        }
    }
}

const UnitError = Error || bits_.NeedInput || error{OutputFull};

/// One unit of the current phase (a field, a row of the in-use map, a
/// selector, a step of a code length), its state committed only when it is
/// read whole; the symbols and the output run as long as they can.
fn unit(s: *State, w: Work, r: *Reader, out: []u8, op: *usize, at: u64) UnitError!void {
    switch (s.phase) {
        .stream_magic => {
            if (try r.bits(8) != 'B') return s.fail(at, .bad_magic);
            if (try r.bits(8) != 'Z') return s.fail(at, .bad_magic);
            if (try r.bits(8) != 'h') return s.fail(at, .bad_magic);
            const level = try r.bits(8);
            if (level < '1' or level > '9') return s.fail(at, .bad_level);
            s.level = level - '0';
            s.combined = 0;
            s.go(.stream_magic, .read);
        },
        .block_magic => {
            const first = try r.bits(8);
            const magic: []const u8 = switch (first) {
                0x31 => &.{ 0x41, 0x59, 0x26, 0x53, 0x59 },
                0x17 => &.{ 0x72, 0x45, 0x38, 0x50, 0x90 },
                else => return s.fail(at, .bad_block_magic),
            };
            for (magic) |byte| if (try r.bits(8) != byte) return s.fail(at, .bad_block_magic);
            if (first == 0x17) s.go(.block_magic, .end) else s.go(.block_magic, .read);
        },
        .block_header => {
            const crc = try r.bits(32);
            const randomised = try r.bits(1) == 1;
            const orig_ptr = try r.bits(24);
            if (orig_ptr > 10 + 100_000 * s.level) return s.fail(at, .orig_ptr);
            s.block_crc = crc;
            s.randomised = randomised;
            s.orig_ptr = orig_ptr;
            s.go(.block_header, .read);
        },
        .used16 => {
            s.used16 = @intCast(try r.bits(16));
            s.at = 0;
            s.in_use = 0;
            s.go(.used16, .read);
        },
        .used => {
            while (s.at < 16 and s.used16 & (@as(u16, 0x8000) >> @intCast(s.at)) == 0) s.at += 1;
            if (s.at < 16) {
                const row = try r.bits(16);
                for (0..16) |j| if (row & (@as(u32, 0x8000) >> @intCast(j)) != 0) {
                    s.seq_to_unseq[s.in_use] = @intCast(s.at * 16 + j);
                    s.in_use += 1;
                };
                s.at += 1;
                return;
            }
            if (s.in_use == 0) return s.fail(at, .no_symbols);
            s.go(.used, .read);
        },
        .groups => {
            const groups = try r.bits(3);
            if (groups < 2 or groups > max_groups) return s.fail(at, .groups);
            const count = try r.bits(15);
            if (count < 1) return s.fail(at, .no_selectors);
            s.groups = groups;
            s.selector_count = count;
            for (&s.selector_mtf, 0..) |*v, i| v.* = @intCast(i);
            s.at = 0;
            s.go(.groups, .read);
        },
        .selectors => {
            if (s.at < s.selector_count) {
                var j: u32 = 0;
                while (try r.bits(1) == 1) {
                    j += 1;
                    if (j >= s.groups) return s.fail(at, .selector);
                }
                // The move-to-front undone as each is read; 1.0.8 keeps
                // the first `max_selectors`.
                const v = s.selector_mtf[j];
                @memmove(s.selector_mtf[1 .. j + 1], s.selector_mtf[0..j]);
                s.selector_mtf[0] = v;
                if (s.at < max_selectors) s.selectors[s.at] = v;
                s.at += 1;
                return;
            }
            s.selector_count = @min(s.selector_count, max_selectors);
            s.table = 0;
            s.go(.selectors, .read);
        },
        .code_start => {
            s.curr = try r.bits(5);
            s.at = 0;
            s.go(.code_start, .read);
        },
        .code_lengths => try codeLength(s, w, r, at),
        .symbols => {
            try symbols(s, w, r);
            if (s.orig_ptr >= s.nblock) return s.fail(r.bitOffset(), .orig_ptr);
            link(s, w.tt);
            s.go(.symbols, .read);
        },
        .output => {
            const start = op.*;
            const finished = if (s.randomised) output(true, s, w.tt, out, op) else output(false, s, w.tt, out, op);
            s.crc = crc_.slicing8(s.crc, out[start..op.*]);
            if (!(finished catch return s.fail(at, .corrupt))) return error.OutputFull;
            if (~s.crc != s.block_crc) return s.fail(r.bitOffset(), .block_crc);
            s.join(s.block_crc);
            s.go(.output, .read);
        },
        .stream_crc => {
            const crc = try r.bits(32);
            if (crc != s.combined) return s.fail(at, .stream_crc);
            r.alignByte();
            s.go(.stream_crc, .read);
        },
        .done => {},
    }
}

/// The block's symbols into the BWT vector, one symbol a unit, to the
/// end-of-block symbol. `NeedInput` leaves `r` at the symbol it could not
/// read.
fn symbols(s: *State, w: Work, r: *Reader) UnitError!void {
    const tt = w.tt;
    const limit = 100_000 * s.level;
    const eob = s.in_use + 1;
    var nblock = s.nblock;
    var left = s.group_left;
    var group = s.group;
    var run_len = s.run;
    var weight = s.run_weight;
    var table: *const huffman.Table = if (group != 0) &w.tables[s.selectors[group - 1]] else &w.tables[0];
    defer {
        s.nblock = nblock;
        s.group_left = left;
        s.group = group;
        s.run = run_len;
        s.run_weight = weight;
    }
    while (true) {
        const m = r.mark();
        const at = r.bitOffset();
        var next_left = left;
        var next_group = group;
        var next_table = table;
        if (next_left == 0) {
            if (next_group >= s.selector_count) return s.fail(at, .selectors_exhausted);
            next_table = &w.tables[s.selectors[next_group]];
            next_group += 1;
            next_left = group_size;
        }
        const sym = (next_table.decode(r) catch {
            r.restore(m);
            return error.NeedInput;
        }) orelse return s.fail(at, .bad_code);
        left = next_left - 1;
        group = next_group;
        table = next_table;
        if (sym <= 1) {
            // RUNA and RUNB: a run's length in bijective base 2.
            if (weight >= max_run_weight) return s.fail(at, .run_too_long);
            run_len += (@as(u32, sym) + 1) * weight;
            weight *= 2;
            continue;
        }
        if (run_len != 0) {
            if (run_len > limit - nblock) return s.fail(at, .block_too_large);
            const uc = s.seq_to_unseq[s.mtf[0]];
            s.counts[uc] += run_len;
            @memset(tt[nblock..][0..run_len], uc);
            nblock += run_len;
            run_len = 0;
            weight = 1;
        }
        if (sym == eob) return;
        if (nblock >= limit) return s.fail(at, .block_too_large);
        const nn = sym - 1;
        const v = s.mtf[nn];
        @memmove(s.mtf[1 .. nn + 1], s.mtf[0..nn]);
        s.mtf[0] = v;
        const uc = s.seq_to_unseq[v];
        s.counts[uc] += 1;
        tt[nblock] = uc;
        nblock += 1;
    }
}

/// The inverse BWT's links: each entry's position above its byte (1.0.8's
/// fast form), and the output started at the block's first byte.
fn link(s: *State, tt: []u32) void {
    var next: [256]u32 = undefined;
    var sum: u32 = 0;
    for (&next, s.counts) |*n, c| {
        n.* = sum;
        sum += c;
    }
    for (0..s.nblock) |i| {
        const uc: u8 = @truncate(tt[i]);
        tt[next[uc]] |= @as(u32, @intCast(i)) << 8;
        next[uc] += 1;
    }
    s.pos = tt[s.orig_ptr] >> 8;
    s.reads = 0;
    s.same = 0;
    s.repeat = 0;
    s.rand_to_go = 0;
    s.rand_at = 0;
    s.crc = 0xffff_ffff;
}

/// The block's bytes through the run-length stage into `out[op.*..]`: four
/// equal bytes are followed by a count of more. True when the block is
/// out; `Corrupt` where it ends where a count should be (1.0.8 reads past
/// the block there and refuses it).
fn output(comptime randomised: bool, s: *State, tt: []const u32, out: []u8, op: *usize) error{Corrupt}!bool {
    const n = s.nblock;
    var o = op.*;
    var pos = s.pos;
    var reads = s.reads;
    var last = s.last;
    var same = s.same;
    var repeat = s.repeat;
    defer {
        op.* = o;
        s.pos = pos;
        s.reads = reads;
        s.last = last;
        s.same = same;
        s.repeat = repeat;
    }
    while (true) {
        if (repeat != 0) {
            const k = @min(repeat, out.len - o);
            @memset(out[o..][0..k], last);
            o += k;
            repeat -= @intCast(k);
            if (repeat != 0) return false;
        }
        if (reads == n) {
            if (same == 4) return error.Corrupt;
            return true;
        }
        // A run's count takes no room, so a stream that fits its output
        // ends there.
        if (o == out.len and same != 4) return false;
        const e = tt[pos];
        var b: u8 = @truncate(e);
        pos = e >> 8;
        reads += 1;
        if (randomised) b ^= randomMask(s);
        if (same == 4) {
            repeat = b;
            same = 0;
            continue;
        }
        out[o] = b;
        o += 1;
        same = if (same != 0 and b == last) same + 1 else 1;
        last = b;
    }
}

/// A randomised block's next mask: 1 where 1.0.8's table flipped the byte.
fn randomMask(s: *State) u8 {
    if (s.rand_to_go == 0) {
        s.rand_to_go = random_numbers[s.rand_at];
        s.rand_at = (s.rand_at + 1) % @as(u32, random_numbers.len);
    }
    s.rand_to_go -= 1;
    return @intFromBool(s.rand_to_go == 1);
}

/// One step of a code length (1.0.8's loop: the length checked, then a
/// bit to keep it, or two to change it), or the table built once every
/// symbol has one.
fn codeLength(s: *State, w: Work, r: *Reader, at: u64) UnitError!void {
    const alpha = s.in_use + 2;
    if (s.at < alpha) {
        if (s.curr < 1 or s.curr > huffman.max_len) return s.fail(at, .code_length);
        if (try r.bits(1) == 0) {
            s.lens[s.at] = @intCast(s.curr);
            s.at += 1;
        } else {
            if (try r.bits(1) == 0) s.curr += 1 else s.curr -= 1;
        }
        return;
    }
    w.tables[s.table].build(s.lens[0..alpha]);
    s.table += 1;
    if (s.table < s.groups) return s.go(.code_lengths, .more);
    for (&s.mtf, 0..) |*v, i| v.* = @intCast(i);
    s.counts = @splat(0);
    s.nblock = 0;
    s.group_left = 0;
    s.group = 0;
    s.run = 0;
    s.run_weight = 1;
    s.go(.code_lengths, .read);
}
