//! The Brotli decoding engine: stream and meta-block headers, prefix codes,
//! context maps and the command loop, run against any input split and any
//! output history.
//!
//! The engine is resumable at every unit: a stream header, a meta-block
//! header, one symbol of a prefix code's description, one context map
//! entry, a command, a literal, a distance (each with the block switch
//! before it). A unit reads its bits, then commits what it read to the
//! `State`; a unit that runs out of input commits nothing, and the reader is
//! put back where it started (`Reader.Mark`), so the caller can give more
//! input and run it again. While `bits.margin` bytes of input remain a unit
//! reads unchecked; past that, careful reads check each byte.
//!
//! What it decodes into is the caller's `History` (comptime): the output
//! itself, or a window.

const std = @import("std");
const aegis = @import("aegis");
const bits_ = @import("bits.zig");
const Reader = bits_.Reader;
const huffman = @import("huffman.zig");
const Entry = huffman.Entry;
const codes = @import("codes.zig");
const context = @import("context.zig");
const dictionary = @import("dictionary.zig");
const Diagnostic = @import("Diagnostic.zig");

/// Every prefix code and context map a meta-block can need, at the
/// format's worst case; a meta-block touches the part it uses.
pub const Tables = struct {
    literal: [256 * huffman.maxEntries(256)]Entry,
    command: [256 * huffman.maxEntries(704)]Entry,
    distance: [256 * huffman.maxEntries(codes.max_distance_limit)]Entry,
    /// Where each tree of a group starts in its group's entries.
    literal_trees: [256]u32,
    command_trees: [256]u32,
    distance_trees: [256]u32,
    block_types: [3][huffman.maxEntries(258)]Entry,
    block_counts: [3][huffman.maxEntries(26)]Entry,
    context_map: [256 * 64]u8,
    distance_map: [256 * 4]u8,
    modes: [256]context.Mode,
    /// What each distance symbol past the short codes stands for, under
    /// the meta-block's NPOSTFIX and NDIRECT.
    distance_ranges: [codes.max_distance_limit]codes.Range,
    /// Literal block types whose contexts all map to one tree.
    trivial: [256]bool,
    /// The current literal block type's tree for each of its 64 contexts:
    /// the context map and the tree starts in one lookup.
    literal_contexts: [64]u32,
    /// The same trees by the bytes themselves: entry `p1 << 3 | c`, `c`
    /// the context mode's part from the byte before `p1` (at most 3 bits),
    /// so a literal's tree is one load from the literal before it. Built
    /// for a block long enough to repay it.
    literal_bytes: [256 * 8]u32,
    /// The current distance block type's tree for each of its 4 contexts.
    distance_contexts: [4]u32,
    /// The symbols of the code being read, one list per length:
    /// `links[l]` is the first of length `l`, `links[16 + s]` the one after
    /// `s` (`huffman.build`).
    links: huffman.Links,
    /// The code length code of the description being read.
    code_lengths: [32]Entry,
    /// The prefix code of the context map being read.
    map_code: [huffman.maxEntries(256 + 16)]Entry,
};

pub const Fail = error{InvalidStream};
pub const Error = Fail || error{ OutputTooSmall, WindowTooLarge };

/// What a run stopped for.
pub const Status = enum {
    /// The input ended inside a unit; nothing of the unit was taken.
    need_input,
    /// The history has no room for the next byte (a window to drain).
    output_full,
    /// The stream ended; the reader is at the byte after it.
    done,
};

const Phase = enum {
    stream_header,
    metablock_header,
    metadata,
    uncompressed,
    block_types,
    block_count_code,
    block_count,
    distance_params,
    modes,
    context_map_trees,
    context_map_rle,
    context_map_entries,
    context_map_mtf,
    tree_groups,
    prefix_code,
    command,
    literals,
    distance,
    copy,
    word,
    end,
    done,
};

/// What moves the stream on. `read`: a unit is done and the next in order
/// follows. `last` and `more`: a meta-block ends, the stream's last or one
/// before another. A meta-block's kind. `code`: a prefix code's
/// description starts, and it ends with what it was read for (a `Target`).
/// `distance_map` and `trees`: the literal context map is done and the
/// distance map follows, or both are and the trees follow. `insert` and
/// `copy`: a command's literals follow, or its copy's distance. `history`
/// and `word`: the distance copies from the output or the prefix, or a
/// dictionary word.
const Event = enum { read, last, more, metadata, uncompressed, compressed, code, block_type, block_count, map_code, tree, distance_map, trees, insert, copy, history, word };

const Machine = aegis.state.Machine(Phase, Event, .{ .initial = .stream_header, .terminal = &.{.done}, .edges = &.{
    .{ .from = .stream_header, .on = .read, .to = .metablock_header },
    .{ .from = .metablock_header, .on = .last, .to = .end },
    .{ .from = .metablock_header, .on = .metadata, .to = .metadata },
    .{ .from = .metablock_header, .on = .uncompressed, .to = .uncompressed },
    .{ .from = .metablock_header, .on = .compressed, .to = .block_types },
    .{ .from = .metadata, .on = .last, .to = .end },
    .{ .from = .metadata, .on = .more, .to = .metablock_header },
    .{ .from = .uncompressed, .on = .last, .to = .end },
    .{ .from = .uncompressed, .on = .more, .to = .metablock_header },
    .{ .from = .block_types, .on = .read, .to = .distance_params },
    .{ .from = .block_types, .on = .code, .to = .prefix_code },
    .{ .from = .block_count_code, .on = .code, .to = .prefix_code },
    .{ .from = .block_count, .on = .read, .to = .block_types },
    .{ .from = .distance_params, .on = .read, .to = .modes },
    .{ .from = .modes, .on = .read, .to = .context_map_trees },
    .{ .from = .context_map_trees, .on = .read, .to = .context_map_rle },
    .{ .from = .context_map_trees, .on = .distance_map, .to = .context_map_trees },
    .{ .from = .context_map_trees, .on = .trees, .to = .tree_groups },
    .{ .from = .context_map_rle, .on = .code, .to = .prefix_code },
    .{ .from = .context_map_entries, .on = .read, .to = .context_map_mtf },
    .{ .from = .context_map_mtf, .on = .distance_map, .to = .context_map_trees },
    .{ .from = .context_map_mtf, .on = .trees, .to = .tree_groups },
    .{ .from = .tree_groups, .on = .code, .to = .prefix_code },
    .{ .from = .tree_groups, .on = .read, .to = .command },
    .{ .from = .prefix_code, .on = .block_type, .to = .block_count_code },
    .{ .from = .prefix_code, .on = .block_count, .to = .block_count },
    .{ .from = .prefix_code, .on = .map_code, .to = .context_map_entries },
    .{ .from = .prefix_code, .on = .tree, .to = .tree_groups },
    .{ .from = .command, .on = .insert, .to = .literals },
    .{ .from = .command, .on = .copy, .to = .distance },
    .{ .from = .command, .on = .last, .to = .end },
    .{ .from = .command, .on = .more, .to = .metablock_header },
    .{ .from = .literals, .on = .copy, .to = .distance },
    .{ .from = .literals, .on = .last, .to = .end },
    .{ .from = .literals, .on = .more, .to = .metablock_header },
    .{ .from = .distance, .on = .history, .to = .copy },
    .{ .from = .distance, .on = .word, .to = .word },
    .{ .from = .copy, .on = .read, .to = .command },
    .{ .from = .copy, .on = .last, .to = .end },
    .{ .from = .copy, .on = .more, .to = .metablock_header },
    .{ .from = .word, .on = .read, .to = .command },
    .{ .from = .word, .on = .last, .to = .end },
    .{ .from = .word, .on = .more, .to = .metablock_header },
    .{ .from = .end, .on = .read, .to = .done },
} });

/// What a prefix code's description is being read for; its event when it
/// is read.
const Target = enum { block_type, block_count, map_code, tree };

/// The block types in force and the counts left of each: what a block
/// switch changes, kept apart so a careful unit can put it back.
pub const Blocks = struct {
    /// Each category's last two block types, the last at 1.
    types: [3][2]u32 = @splat(.{ 1, 0 }),
    counts: [3]u32 = @splat(1 << 24),
    literal_map: u32 = 0,
    literal_lookup: *const [512]u8 = &context.lookup[0],
    /// The literal tree of a block type whose 64 contexts all use one.
    literal_tree: ?u32 = null,
    /// Whether `Tables.literal_bytes` holds the current block type's trees.
    literal_bytes: bool = false,
    command_tree: u32 = 0,
    distance_map: u32 = 0,
};

/// A prefix code's description as it is read.
pub const Code = struct {
    target: Target = .tree,
    max: u32 = 0,
    limit: u32 = 0,
    symbol: u32 = 0,
    repeat: u32 = 0,
    repeat_len: u8 = 0,
    prev_len: u8 = 8,
    space: i64 = 0,
    count: [huffman.max_length + 1]u16 = @splat(0),
    /// Where each length's list of symbols ends in `Tables.links`.
    tails: [huffman.max_length + 1]u16 = undefined,
};

/// Where a stream is: everything the engine keeps between units.
pub const State = struct {
    phase: Phase = .stream_header,
    /// Accept the large-window extension (not RFC 7932; the reference's
    /// parameter).
    large_window: bool = false,
    window_bits: u5 = 0,
    large: bool = false,
    max_backward: u32 = 0,

    last: bool = false,
    /// Bytes of the meta-block not yet produced; negative after a command
    /// overran it.
    remaining: i64 = 0,

    // The meta-block header as it is read.
    category: u2 = 0,
    num_types: [3]u32 = .{ 1, 1, 1 },
    /// NPOSTFIX, 2 bits; NDIRECT, 4 bits shifted by NPOSTFIX: at most 120.
    npostfix: u2 = 0,
    ndirect: u7 = 0,
    distance_max: u32 = 0,
    distance_limit: u32 = 0,
    mode_index: u32 = 0,
    num_literal_trees: u32 = 1,
    num_distance_trees: u32 = 1,
    map: struct { distance: bool = false, size: u32 = 0, trees: u32 = 0, rlemax: u32 = 0, index: u32 = 0 } = .{},
    group: u2 = 0,
    tree: u32 = 0,
    group_used: u32 = 0,
    code: Code = .{},

    // The meta-block body.
    blocks: Blocks = .{},
    /// The last four distances, `distances[0]` the last.
    distances: [4]u32 = .{ 4, 11, 15, 16 },
    insert: u32 = 0,
    copy: u32 = 0,
    distance: u32 = 0,
    distance_context: u2 = 0,
    implicit: bool = false,
    /// A static dictionary word decoded and not yet written (streaming).
    word: [dictionary.transform_room]u8 = undefined,
    word_len: u8 = 0,
    word_at: u8 = 0,
    /// Bytes of the prefix dictionary still to copy, from `prefix_at`.
    prefix_at: usize = 0,
    from_prefix: bool = false,

    reason: Diagnostic.Reason = .truncated,
    /// The refused unit's first bit, counted from the reader's input.
    fail_bit: u64 = 0,

    /// The one place the phase changes: along a declared edge.
    fn go(s: *State, comptime from: Phase, comptime on: Event) void {
        s.phase = comptime Machine.after(from, on);
    }

    /// The meta-block read in `from` has ended.
    fn endPart(s: *State, comptime from: Phase) void {
        if (s.last) s.go(from, .last) else s.go(from, .more);
    }

    fn fail(s: *State, reason: Diagnostic.Reason, at: u64) Fail {
        s.reason = reason;
        s.fail_bit = at;
        return error.InvalidStream;
    }
};

/// Run the stream from `s` over `r` into `h` until it ends, the input runs
/// out inside a unit, or `h` is full (for a history that drains).
pub fn run(s: *State, t: *Tables, r: *Reader, h: anytype) Error!Status {
    while (true) {
        const m = r.mark();
        const careful = !r.roomy();
        // A careful unit's block switch is undone with the unit.
        const blocks = if (careful) s.blocks else undefined;
        const result = if (careful) step(true, s, t, r, h) else step(false, s, t, r, h);
        if (result) |status| {
            if (status) |stop| {
                if (stop != .done) try overrun(s, r);
                return stop;
            }
        } else |err| switch (err) {
            error.NeedInput => {
                r.restore(m);
                const literal_switched = s.blocks.types[0][1] != blocks.types[0][1];
                const distance_switched = s.blocks.types[2][1] != blocks.types[2][1];
                s.blocks = blocks;
                // The context tables of the types switched away from.
                if (literal_switched) selectLiteral(s, t);
                if (distance_switched) selectDistance(s, t, s.blocks.types[2][1]);
                try overrun(s, r);
                return .need_input;
            },
            error.InvalidStream => return error.InvalidStream,
            error.OutputTooSmall => {
                try overrun(s, r);
                return error.OutputTooSmall;
            },
            error.WindowTooLarge => return error.WindowTooLarge,
        }
    }
}

/// A command whose insert ran past its meta-block is refused when the
/// engine stops for input or output, as the reference refuses it at its
/// next output, rather than at the end of the literals.
fn overrun(s: *State, r: *const Reader) Fail!void {
    if (s.remaining < 0) return s.fail(.block_length, r.bitOffset());
}

const StepError = Error || bits_.NeedInput;

/// One unit of the current phase. Returns a status to stop with, or null
/// to go on.
fn step(comptime careful: bool, s: *State, t: *Tables, r: *Reader, h: anytype) StepError!?Status {
    const at = r.bitOffset();
    switch (s.phase) {
        .stream_header => {
            try streamHeader(careful, s, r, at);
            try h.begin(s.window_bits);
        },
        .metablock_header => try metablockHeader(careful, s, r, at),
        .metadata, .uncompressed => return bytesStep(s, r, h),
        .block_types, .block_count_code, .block_count, .distance_params, .modes, .context_map_trees, .context_map_rle, .context_map_entries, .context_map_mtf, .tree_groups, .prefix_code => return headerStep(careful, s, t, r, at),
        .command, .literals, .distance, .copy, .word => return bodyStep(careful, s, t, r, h, at),
        .end => {
            if (!r.alignByte()) return s.fail(.padding, at);
            r.unload();
            s.go(.end, .read);
            return .done;
        },
        .done => return .done,
    }
    return null;
}

/// The phases that take whole bytes: metadata skipped, uncompressed data
/// copied, each from a byte boundary.
fn bytesStep(s: *State, r: *Reader, h: anytype) StepError!?Status {
    switch (s.phase) {
        .metadata => {
            // Metadata is skipped byte by byte from a byte boundary.
            r.unload();
            const n: usize = @intCast(@min(@as(i64, @intCast(r.in.len - r.pos)), s.remaining));
            r.pos += n;
            s.remaining -= @intCast(n);
            if (s.remaining != 0) return .need_input;
            s.endPart(.metadata);
        },
        .uncompressed => {
            r.unload();
            while (s.remaining > 0) {
                const room = h.room();
                if (room == 0) return h.full();
                const n: usize = @intCast(@min(@min(@as(i64, @intCast(r.in.len - r.pos)), s.remaining), @as(i64, @intCast(room))));
                if (n == 0) return .need_input;
                h.write(r.in[r.pos..][0..n]);
                r.pos += n;
                s.remaining -= @intCast(n);
            }
            s.endPart(.uncompressed);
        },
        else => unreachable,
    }
    return null;
}

/// One unit of a compressed meta-block's header.
noinline fn headerStep(comptime careful: bool, s: *State, t: *Tables, r: *Reader, at: u64) StepError!?Status {
    switch (s.phase) {
        .block_types => {
            if (s.category == 3) {
                s.go(.block_types, .read);
                return null;
            }
            const n = try varLenUint8(careful, r) + 1;
            s.num_types[s.category] = n;
            if (n < 2) {
                s.category +%= 1;
                return null;
            }
            startCode(s, .block_types, .block_type, n + 2, n + 2);
        },
        .block_count_code => startCode(s, .block_count_code, .block_count, 26, 26),
        .block_count => {
            s.blocks.counts[s.category] = try blockCount(careful, r, &t.block_counts[s.category]);
            s.category +%= 1;
            s.go(.block_count, .read);
        },
        .distance_params => {
            const v = try r.bits(careful, 6);
            s.npostfix = @truncate(v);
            s.ndirect = @as(u7, @as(u4, @truncate(v >> 2))) << s.npostfix;
            const a = codes.distanceAlphabet(s.npostfix, s.ndirect, s.large);
            s.distance_max = a.max;
            s.distance_limit = a.limit;
            s.mode_index = 0;
            s.go(.distance_params, .read);
        },
        .modes => {
            if (s.mode_index == s.num_types[0]) {
                s.map = .{ .distance = false, .size = s.num_types[0] << 6 };
                s.go(.modes, .read);
                return null;
            }
            t.modes[s.mode_index] = @fromBackingInt(@intCast(try r.bits(careful, 2)));
            s.mode_index += 1;
        },
        .context_map_trees => {
            const n = try varLenUint8(careful, r) + 1;
            s.map.trees = n;
            s.map.index = 0;
            if (s.map.distance) s.num_distance_trees = n else s.num_literal_trees = n;
            const map = mapSlice(s, t);
            if (n == 1) {
                @memset(map, 0);
                return mapDone(s, .context_map_trees);
            }
            s.go(.context_map_trees, .read);
        },
        .context_map_rle => {
            s.map.rlemax = if (try r.bits(careful, 1) == 1) try r.bits(careful, 4) + 1 else 0;
            const alphabet = s.map.trees + s.map.rlemax;
            startCode(s, .context_map_rle, .map_code, alphabet, alphabet);
        },
        .context_map_entries => {
            const map = mapSlice(s, t);
            // One entry a unit; fast, as many as the margin allows.
            while (s.map.index != map.len) {
                const code = try huffman.decode(r, careful, &t.map_code);
                if (code == 0) {
                    map[s.map.index] = 0;
                    s.map.index += 1;
                } else if (code > s.map.rlemax) {
                    map[s.map.index] = @intCast(code - s.map.rlemax);
                    s.map.index += 1;
                } else {
                    // `code` is at most `rlemax`, 16 or less.
                    const bits: u5 = @intCast(code);
                    const reps = (@as(u32, 1) << bits) + try r.bits(careful, bits);
                    if (s.map.index + reps > map.len) return s.fail(.context_map_repeat, r.bitOffset());
                    @memset(map[s.map.index..][0..reps], 0);
                    s.map.index += reps;
                }
                if (careful or !r.roomy()) return null;
            }
            s.go(.context_map_entries, .read);
        },
        .context_map_mtf => {
            if (try r.bits(careful, 1) == 1) inverseMoveToFront(mapSlice(s, t));
            return mapDone(s, .context_map_mtf);
        },
        .tree_groups => {
            const n = switch (s.group) {
                0 => s.num_literal_trees,
                1 => s.num_types[1],
                2 => s.num_distance_trees,
                3 => unreachable,
            };
            if (s.tree == n) {
                s.group +%= 1;
                s.tree = 0;
                s.group_used = 0;
                if (s.group == 3) {
                    startBody(s, t);
                    s.go(.tree_groups, .read);
                }
                return null;
            }
            const groups = groupTrees(t, s.group);
            groups[s.tree] = s.group_used;
            switch (s.group) {
                0 => startCode(s, .tree_groups, .tree, 256, 256),
                1 => startCode(s, .tree_groups, .tree, 704, 704),
                2 => startCode(s, .tree_groups, .tree, s.distance_max, s.distance_limit),
                3 => unreachable,
            }
        },
        .prefix_code => try prefixCode(careful, s, t, r, at),
        else => unreachable,
    }
    return null;
}

/// One unit of a compressed meta-block's commands.
noinline fn bodyStep(comptime careful: bool, s: *State, t: *Tables, r: *Reader, h: anytype, at: u64) StepError!?Status {
    switch (s.phase) {
        .command => {
            if (!careful) return fastCommands(s, t, r, h);
            try readCommand(careful, s, t, r, at);
            if (s.insert == 0) s.go(.command, .copy) else s.go(.command, .insert);
        },
        .literals => {
            if (s.insert == 0) {
                if (s.remaining <= 0) return endMetablock(s, .literals, at);
                s.go(.literals, .copy);
                return null;
            }
            if (h.room() == 0) return h.full();
            if (s.blocks.counts[0] == 0) try blockSwitch(careful, s, t, r, 0, at);
            const tree = s.blocks.literal_tree orelse t.literal_contexts[s.blocks.literal_lookup[h.back(1)] | s.blocks.literal_lookup[256 + @as(usize, h.back(2))]];
            const literal = try huffman.decode(r, careful, t.literal[tree..].ptr);
            s.blocks.counts[0] -= 1;
            h.put(@intCast(literal));
            s.insert -= 1;
        },
        .distance => {
            const d = try readDistance(careful, s, t, r, at);
            switch (try resolve(s, h, d.distance, d.push, at, &s.word)) {
                .history, .prefix => s.go(.distance, .history),
                .word => s.go(.distance, .word),
            }
        },
        .copy => {
            if (s.copy != 0) {
                const n: u32 = if (s.from_prefix) @intCast(h.writeSome(h.prefix()[s.prefix_at..][0..s.copy])) else h.copy(s.distance, s.copy);
                if (s.from_prefix) s.prefix_at += n;
                s.copy -= n;
                if (s.copy != 0) return h.full();
            }
            s.from_prefix = false;
            if (s.remaining <= 0) return endMetablock(s, .copy, at);
            s.go(.copy, .read);
        },
        .word => {
            const n = h.writeSome(s.word[s.word_at..s.word_len]);
            s.word_at += @intCast(n);
            if (s.word_at != s.word_len) return h.full();
            if (s.remaining <= 0) return endMetablock(s, .word, at);
            s.go(.word, .read);
        },
        else => unreachable,
    }
    return null;
}

noinline fn streamHeader(comptime careful: bool, s: *State, r: *Reader, at: u64) StepError!void {
    s.large = false;
    if (try r.bits(careful, 1) == 0) {
        s.window_bits = 16;
    } else {
        const n = try r.bits(careful, 3);
        if (n != 0) {
            s.window_bits = @intCast(17 + n);
        } else {
            const m = try r.bits(careful, 3);
            if (m == 1) {
                if (!s.large_window) return s.fail(.window_bits, at);
                if (try r.bits(careful, 1) == 1) return s.fail(.window_bits, at);
                const w = try r.bits(careful, 6);
                if (w < 10 or w > 30) return s.fail(.window_bits, at);
                s.window_bits = @intCast(w);
                s.large = true;
            } else if (m != 0) {
                s.window_bits = @intCast(8 + m);
            } else s.window_bits = 17;
        }
    }
    s.max_backward = (@as(u32, 1) << s.window_bits) - 16;
    s.go(.stream_header, .read);
}

noinline fn metablockHeader(comptime careful: bool, s: *State, r: *Reader, at: u64) StepError!void {
    const last = try r.bits(careful, 1) == 1;
    if (last and try r.bits(careful, 1) == 1) {
        s.last = true;
        s.remaining = 0;
        s.go(.metablock_header, .last);
        return;
    }
    const nibbles = try r.bits(careful, 2);
    if (nibbles == 3) {
        if (try r.bits(careful, 1) != 0) return s.fail(.reserved, at);
        const nbytes = try r.bits(careful, 2);
        var len: u32 = 0;
        for (0..nbytes) |i| {
            const b = try r.bits(careful, 8);
            if (i + 1 == nbytes and nbytes > 1 and b == 0) return s.fail(.exuberant_metadata, at);
            len |= b << @intCast(8 * i);
        }
        if (!r.alignByte()) return s.fail(.padding, at);
        s.last = last;
        s.remaining = if (nbytes == 0) 0 else @as(i64, len) + 1;
        s.go(.metablock_header, .metadata);
        return;
    }
    const n = nibbles + 4;
    var len: u32 = 0;
    for (0..n) |i| {
        const nib = try r.bits(careful, 4);
        if (i + 1 == n and n > 4 and nib == 0) return s.fail(.exuberant_nibble, at);
        len |= nib << @intCast(4 * i);
    }
    const uncompressed = !last and try r.bits(careful, 1) == 1;
    if (uncompressed and !r.alignByte()) return s.fail(.padding, at);
    s.last = last;
    s.remaining = @as(i64, len) + 1;
    if (uncompressed) {
        s.go(.metablock_header, .uncompressed);
        return;
    }
    s.category = 0;
    s.num_types = .{ 1, 1, 1 };
    s.blocks.counts = @splat(1 << 24);
    s.group = 0;
    s.tree = 0;
    s.group_used = 0;
    s.go(.metablock_header, .compressed);
}

/// A number 0-255 in 1 to 11 bits.
fn varLenUint8(comptime careful: bool, r: *Reader) bits_.NeedInput!u32 {
    if (try r.bits(careful, 1) == 0) return 0;
    const n: u3 = @truncate(try r.bits(careful, 3));
    if (n == 0) return 1;
    return (@as(u32, 1) << n) + try r.bits(careful, n);
}

fn blockCount(comptime careful: bool, r: *Reader, table: []const Entry) bits_.NeedInput!u32 {
    const range = codes.block_counts[try huffman.decode(r, careful, table.ptr)];
    return range.offset + try r.bits(careful, range.extra);
}

fn blockSwitch(comptime careful: bool, s: *State, t: *Tables, r: *Reader, comptime category: u2, at: u64) StepError!void {
    const n = s.num_types[category];
    if (n <= 1) return s.fail(.block_switch, at);
    const code = try huffman.decode(r, careful, &t.block_types[category]);
    const count = try blockCount(careful, r, &t.block_counts[category]);
    const ring = &s.blocks.types[category];
    var next: u32 = switch (code) {
        0 => ring[0],
        1 => ring[1] + 1,
        else => code - 2,
    };
    if (next >= n) next -= n;
    ring[0] = ring[1];
    ring[1] = next;
    s.blocks.counts[category] = count;
    switch (category) {
        0 => selectLiteral(s, t),
        1 => s.blocks.command_tree = t.command_trees[next],
        2 => selectDistance(s, t, next),
        3 => unreachable,
    }
}

fn selectDistance(s: *State, t: *Tables, ty: u32) void {
    s.blocks.distance_map = ty << 2;
    for (&t.distance_contexts, t.distance_map[ty << 2 ..][0..4]) |*x, tree| x.* = t.distance_trees[tree];
}

fn selectLiteral(s: *State, t: *Tables) void {
    const ty = s.blocks.types[0][1];
    s.blocks.literal_map = ty << 6;
    s.blocks.literal_lookup = &context.lookup[@backingInt(t.modes[ty])];
    s.blocks.literal_tree = if (t.trivial[ty]) t.literal_trees[t.context_map[ty << 6]] else null;
    if (!t.trivial[ty]) for (&t.literal_contexts, t.context_map[ty << 6 ..][0..64]) |*x, tree| {
        x.* = t.literal_trees[tree];
    };
    // 2,048 stores repay themselves over a block of a few thousand literals.
    s.blocks.literal_bytes = !t.trivial[ty] and s.blocks.counts[0] >= 2048;
    if (s.blocks.literal_bytes) {
        const lookup = s.blocks.literal_lookup;
        const parts: usize = switch (t.modes[ty]) {
            .lsb6, .msb6 => 1,
            .utf8 => 4,
            .signed => 8,
        };
        for (0..256) |p1| for (0..parts) |c| {
            t.literal_bytes[p1 << 3 | c] = t.literal_contexts[lookup[p1] | @as(u8, @intCast(c))];
        };
    }
}

fn startBody(s: *State, t: *Tables) void {
    for (0..s.num_types[0]) |ty| {
        const map = t.context_map[ty << 6 ..][0..64];
        t.trivial[ty] = std.mem.allEqual(u8, map, map[0]);
    }
    for (t.distance_ranges[codes.short_distance_codes..s.distance_limit], codes.short_distance_codes..) |*x, symbol| x.* = codes.distanceRange(@intCast(symbol), s.npostfix, s.ndirect);
    s.blocks.types = @splat(.{ 1, 0 });
    selectLiteral(s, t);
    s.blocks.command_tree = t.command_trees[0];
    selectDistance(s, t, 0);
}

fn mapSlice(s: *const State, t: *Tables) []u8 {
    return if (s.map.distance) t.distance_map[0..s.map.size] else t.context_map[0..s.map.size];
}

/// The context map read in `from` is done: the distance map follows the
/// literal map, and the trees follow both.
fn mapDone(s: *State, comptime from: Phase) ?Status {
    if (!s.map.distance) {
        s.map = .{ .distance = true, .size = s.num_types[2] << 2 };
        s.go(from, .distance_map);
    } else {
        s.go(from, .trees);
    }
    return null;
}

/// RFC 7932 §7.3's inverse move-to-front transform.
fn inverseMoveToFront(v: []u8) void {
    var mtf: [256]u8 = undefined;
    for (&mtf, 0..) |*x, i| x.* = @intCast(i);
    for (v) |*x| {
        const index = x.*;
        const value = mtf[index];
        x.* = value;
        var i: usize = index;
        while (i > 0) : (i -= 1) mtf[i] = mtf[i - 1];
        mtf[0] = value;
    }
}

/// Leave `from` to read a prefix code for `target`; reading it ends in
/// the phase its target's edge leads to.
fn startCode(s: *State, comptime from: Phase, target: Target, max: u32, limit: u32) void {
    s.code = .{ .target = target, .max = max, .limit = limit };
    s.go(from, .code);
}

/// Where the table of the code being read goes.
fn codeTable(s: *const State, t: *Tables) []Entry {
    return switch (s.code.target) {
        .block_type => &t.block_types[s.category],
        .block_count => &t.block_counts[s.category],
        .map_code => &t.map_code,
        .tree => switch (s.group) {
            0 => t.literal[s.group_used..],
            1 => t.command[s.group_used..],
            2 => t.distance[s.group_used..],
            3 => unreachable,
        },
    };
}

fn codeDone(s: *State, used: usize) void {
    if (s.code.target == .tree) {
        s.group_used += @intCast(used);
        s.tree += 1;
    }
    switch (s.code.target) {
        inline else => |target| s.go(.prefix_code, @field(Event, @tagName(target))),
    }
}

/// One unit of a prefix code's description: its header (a simple code
/// whole, or a complex code's code length code), or one code length symbol.
noinline fn prefixCode(comptime careful: bool, s: *State, t: *Tables, r: *Reader, at: u64) StepError!void {
    const c = &s.code;
    if (c.space == 0) {
        // The header: HSKIP, then a simple code or the code length code.
        const hskip = try r.bits(careful, 2);
        if (hskip == 1) {
            const nsym = try r.bits(careful, 2) + 1;
            const width = std.math.log2_int(u32, c.max - 1) + 1;
            var symbols: [4]u16 = undefined;
            for (symbols[0..nsym]) |*sym| {
                const v = try r.bits(careful, width);
                if (v >= c.limit) return s.fail(.simple_code_symbol, at);
                sym.* = @intCast(v);
            }
            const four_lengths = nsym == 4 and try r.bits(careful, 1) == 1;
            for (0..nsym) |i| for (i + 1..nsym) |k| {
                if (symbols[i] == symbols[k]) return s.fail(.simple_code_repeat, at);
            };
            codeDone(s, huffman.buildSimple(codeTable(s, t), symbols[0..nsym], four_lengths));
            return;
        }
        const order = [18]u8{ 1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
        // The code length code lengths' own fixed code, by the next 4 bits.
        const prefix_len = [16]u3{ 2, 2, 2, 3, 2, 2, 2, 4, 2, 2, 2, 3, 2, 2, 2, 4 };
        const prefix_value = [16]u8{ 0, 4, 3, 2, 0, 4, 3, 1, 0, 4, 3, 2, 0, 4, 3, 5 };
        var lengths: [18]u8 = @splat(0);
        var count: [6]u16 = @splat(0);
        var space: i32 = 32;
        var used: u32 = 0;
        for (order[hskip..]) |symbol| {
            if (careful) {
                r.fillAvailable(4);
                const ix = r.peek(@min(4, r.count));
                if (prefix_len[ix] > r.count) return error.NeedInput;
            } else try r.fill(false, 4);
            const ix: u4 = @truncate(r.peek(4));
            const v = prefix_value[ix];
            r.drop(prefix_len[ix]);
            lengths[symbol] = v;
            if (v != 0) {
                space -= @as(i32, 32) >> @intCast(v);
                used += 1;
                count[v] += 1;
                if (space <= 0) break;
            }
        }
        if (!(used == 1 or space == 0)) return s.fail(.code_length_space, at);
        huffman.buildCodeLengths(&t.code_lengths, &lengths, &count);
        for (&c.tails, 0..) |*tail, len| tail.* = @intCast(len);
        c.symbol = 0;
        c.repeat = 0;
        c.repeat_len = 0;
        c.prev_len = 8;
        c.space = 32768;
        c.count = @splat(0);
        return;
    }
    // One code length symbol a unit; fast, as many as the margin allows.
    while (c.symbol < c.limit and c.space != 0) {
        try codeLengthSymbol(careful, c, t, r);
        // An oversubscribed code reads on to the end of its alphabet, as
        // the reference's does, and is refused there.
        if (careful or !r.roomy()) break;
    }
    if (c.symbol < c.limit and c.space != 0) return;
    if (c.space != 0) return s.fail(.code_space, at);
    codeDone(s, huffman.build(codeTable(s, t), &t.links, &c.count));
}

/// One symbol of the code length code: a length, or a repeat of the last
/// nonzero one or of zeros; each symbol given a length joins its length's
/// list.
inline fn codeLengthSymbol(comptime careful: bool, c: *Code, t: *Tables, r: *Reader) StepError!void {
    if (careful) r.fillAvailable(8) else try r.fill(false, 8);
    const e = t.code_lengths[@as(u5, @truncate(r.buf))];
    // A length of 4 bits, a code-length symbol of the rest.
    const len: u4 = @truncate(e & 15);
    if (careful and len > r.count) return error.NeedInput;
    const code: u8 = @intCast(e >> 4);
    if (code < 16) {
        r.drop(len);
        c.repeat = 0;
        if (code != 0) {
            t.links[c.tails[code]] = @intCast(c.symbol);
            c.tails[code] = @intCast(huffman.max_length + 1 + c.symbol);
            c.prev_len = code;
            c.space -= @as(i64, 32768) >> @intCast(code);
            c.count[code] += 1;
        }
        c.symbol += 1;
        return;
    }
    const extra: u2 = if (code == 16) 2 else 3;
    if (careful and @as(u6, len) + extra > r.count) return error.NeedInput;
    r.drop(len);
    const delta: u32 = @as(u3, @truncate(r.peek(extra)));
    r.drop(extra);
    const new_len: u8 = if (code == 16) c.prev_len else 0;
    if (c.repeat_len != new_len) {
        c.repeat = 0;
        c.repeat_len = new_len;
    }
    const old = c.repeat;
    if (c.repeat > 0) c.repeat = (c.repeat - 2) << @intCast(extra);
    c.repeat += delta + 3;
    const d = c.repeat - old;
    if (c.symbol + d > c.limit) {
        c.symbol = c.limit;
        c.space = 0xfffff;
        return;
    }
    if (c.repeat_len != 0) {
        const l = c.repeat_len;
        var tail = c.tails[l];
        for (c.symbol..c.symbol + d) |symbol| {
            t.links[tail] = @intCast(symbol);
            tail = @intCast(huffman.max_length + 1 + symbol);
        }
        c.tails[l] = tail;
        c.space -= @as(i64, d) << @intCast(15 - l);
        c.count[l] += @intCast(d);
    }
    c.symbol += d;
}

/// Distance codes 0-15: the last distances, as they are or nudged.
inline fn shortDistance(d: *const [4]u32, symbol: u32) u32 {
    const which = [16]u2{ 0, 1, 2, 3, 0, 0, 0, 0, 0, 0, 1, 1, 1, 1, 1, 1 };
    const delta = [16]i8{ 0, 0, 0, 0, -1, 1, -2, 2, -3, 3, -1, 1, -2, 2, -3, 3 };
    const v = @as(i64, d[which[symbol]]) + delta[symbol];
    // Not positive: past every distance, and refused as one.
    return if (v <= 0) 0x7fffffff else @intCast(v);
}

/// Act on the command's distance: a copy from the history, from the prefix
/// dictionary, or a static dictionary word.
/// The command unit: the insert-and-copy symbol and its extra bits, after
/// the block switch the command category's count asks for.
inline fn readCommand(comptime careful: bool, s: *State, t: *Tables, r: *Reader, at: u64) StepError!void {
    if (s.blocks.counts[1] == 0) try blockSwitch(careful, s, t, r, 1, at);
    const symbol = try huffman.decode(r, careful, t.command[s.blocks.command_tree..].ptr);
    const c = codes.commands[symbol];
    try r.fill(careful, @as(u6, c.insert_extra) + c.copy_extra);
    const insert = c.insert_offset + @as(u32, @intCast(r.peek(c.insert_extra)));
    r.drop(c.insert_extra);
    const copy = c.copy_offset + @as(u32, @intCast(r.peek(c.copy_extra)));
    r.drop(c.copy_extra);
    s.blocks.counts[1] -= 1;
    s.insert = insert;
    s.copy = copy;
    s.implicit = c.implicit_distance;
    s.distance_context = c.distance_context;
    s.remaining -= insert;
}

/// The distance unit: the command's distance, read (after the distance
/// category's block switch) or implied, and whether it joins the last ones.
inline fn readDistance(comptime careful: bool, s: *State, t: *Tables, r: *Reader, at: u64) StepError!struct { distance: u32, push: bool } {
    if (s.implicit) return .{ .distance = s.distances[0], .push = false };
    if (s.blocks.counts[2] == 0) try blockSwitch(careful, s, t, r, 2, at);
    const symbol = try huffman.decode(r, careful, t.distance[t.distance_contexts[s.distance_context]..].ptr);
    s.blocks.counts[2] -= 1;
    if (symbol < codes.short_distance_codes) return .{ .distance = shortDistance(&s.distances, symbol), .push = symbol != 0 };
    const range = t.distance_ranges[symbol];
    const extra = try r.bits(careful, range.extra);
    return .{ .distance = range.offset +% (extra << s.npostfix), .push = true };
}

/// Output room the fast loop keeps past a command: a 16-byte wild copy's
/// overrun, or a transformed word longer than its copy length.
const fast_room = 48;

/// Whole commands while the input has `bits.margin` bytes for each unit and
/// the history room for each command; the units are the careful path's,
/// read unchecked, the bytes written in place. Stops at a phase the unit
/// path takes up.
noinline fn fastCommands(s: *State, t: *Tables, r: *Reader, h: anytype) StepError!?Status {
    const H = @typeInfo(@TypeOf(h)).pointer.child;
    const end = r.in.len - bits_.margin;
    var f: Fast = .load(s, r, h);
    const buf = h.buf.ptr;
    const limit = h.limit;
    // The stream's output so far is `base +% f.pos`.
    const base = h.total() -% @as(u64, f.pos);
    const npostfix = s.npostfix;
    const max_backward = s.max_backward;
    var command_table = t.command[s.blocks.command_tree..].ptr;
    while (true) {
        if (f.br.pos > end) return f.stop(s, r, h, null);
        const at = f.br.bitOffset();
        // The command.
        if (f.counts[1] == 0) {
            f.save(s, r, h);
            try blockSwitch(false, s, t, r, 1, at);
            f = .load(s, r, h);
            command_table = t.command[s.blocks.command_tree..].ptr;
        }
        const c = codes.commands[decodeOk(&f.br, command_table)];
        f.br.fill(false, @as(u6, c.insert_extra) + c.copy_extra) catch unreachable; // unreachable: fast reads never fail
        const insert = c.insert_offset + @as(u32, @intCast(f.br.peek(c.insert_extra)));
        f.br.drop(c.insert_extra);
        const copy = c.copy_offset + @as(u32, @intCast(f.br.peek(c.copy_extra)));
        f.br.drop(c.copy_extra);
        f.counts[1] -= 1;
        f.remaining -= insert;
        if (limit - f.pos < @as(usize, insert) + copy + fast_room) {
            command(s, c, insert, copy);
            return if (insert == 0) f.stop(s, r, h, .copy) else f.stop(s, r, h, .insert);
        }
        // Its literals.
        var left: u32 = insert;
        while (left != 0) {
            if (f.br.pos > end) {
                command(s, c, left, copy);
                return f.stop(s, r, h, .insert);
            }
            if (f.counts[0] == 0) {
                f.save(s, r, h);
                try blockSwitch(false, s, t, r, 0, f.br.bitOffset());
                f = .load(s, r, h);
            }
            const batch = @min(left, f.counts[0]);
            const p1 = H.backAt(buf, limit, f.pos, base +% f.pos, 1);
            const p2 = H.backAt(buf, limit, f.pos, base +% f.pos, 2);
            const done = literalBatch(s, t, &f, buf, batch, end, p1, p2);
            left -= done;
            f.counts[0] -= done;
        }
        if (insert != 0 and f.remaining <= 0) {
            f.save(s, r, h);
            return endMetablock(s, .command, at);
        }
        // Its distance.
        if (f.br.pos > end) {
            command(s, c, 0, copy);
            return f.stop(s, r, h, .copy);
        }
        const dat = f.br.bitOffset();
        var d: u32 = undefined;
        var push = true;
        if (c.implicit_distance) {
            d = f.distances[0];
            push = false;
        } else {
            if (f.counts[2] == 0) {
                f.save(s, r, h);
                try blockSwitch(false, s, t, r, 2, dat);
                f = .load(s, r, h);
            }
            const symbol = decodeOk(&f.br, t.distance[t.distance_contexts[c.distance_context]..].ptr);
            f.counts[2] -= 1;
            if (symbol < codes.short_distance_codes) {
                d = shortDistance(&f.distances, symbol);
                push = symbol != 0;
            } else {
                const range = t.distance_ranges[symbol];
                f.br.fill(false, range.extra) catch unreachable; // aegis: no-danger: fast reads never fail
                d = range.offset +% (@as(u32, @intCast(f.br.peek(range.extra))) << npostfix);
                f.br.drop(range.extra);
            }
        }
        if (d <= @min(base +% f.pos, max_backward)) {
            if (push) {
                // A copy: an aggregate assigned in place reads what it writes.
                const old = f.distances;
                f.distances = .{ d, old[0], old[1], old[2] };
            }
            if (@as(i64, copy) > f.remaining) {
                f.save(s, r, h);
                return s.fail(.block_length, dat);
            }
            f.remaining -= copy;
            f.pos = H.copyAt(buf, limit, f.pos, d, copy);
        } else {
            f.save(s, r, h);
            s.copy = copy;
            switch (try resolve(s, h, d, push, dat, buf + h.pos)) {
                .history => unreachable, // aegis: no-danger: resolve gives .history only for a distance this branch has excluded
                .prefix => {
                    h.write(h.prefix()[s.prefix_at..][0..copy]);
                    s.from_prefix = false;
                },
                .word => h.pos += s.word_len,
            }
            s.copy = 0;
            f = .load(s, r, h);
        }
        if (f.remaining <= 0) {
            f.save(s, r, h);
            return endMetablock(s, .command, at);
        }
    }
}

/// A command read by the fast loop, handed to the unit path.
inline fn command(s: *State, c: codes.Command, insert: u32, copy: u32) void {
    s.insert = insert;
    s.copy = copy;
    s.implicit = c.implicit_distance;
    s.distance_context = c.distance_context;
}

/// What the fast loop keeps in registers: the reader, the output position,
/// the meta-block's remaining length, the last distances and the block
/// counts. A byte stored through the output could alias any of them in
/// memory, so the loop holds them here and writes them back (`save`)
/// before any call that reads the state.
const Fast = struct {
    br: Reader,
    pos: usize,
    remaining: i64,
    distances: [4]u32,
    counts: [3]u32,

    inline fn load(s: *const State, r: *const Reader, h: anytype) Fast {
        var br: Reader = .{ .in = r.in, .base = r.base };
        br.restore(r.mark());
        return .{ .br = br, .pos = h.pos, .remaining = s.remaining, .distances = s.distances, .counts = s.blocks.counts };
    }

    inline fn save(f: *const Fast, s: *State, r: *Reader, h: anytype) void {
        r.restore(f.br.mark());
        h.pos = f.pos;
        s.remaining = f.remaining;
        s.distances = f.distances;
        s.blocks.counts = f.counts;
    }

    /// Hand the stream to the unit path: at the next command, or along
    /// the edge `on` from it.
    inline fn stop(f: *const Fast, s: *State, r: *Reader, h: anytype, comptime on: ?Event) ?Status {
        f.save(s, r, h);
        if (on) |event| s.go(.command, event);
        return null;
    }
};

/// A fast read's symbol: fast reads fail only on no input.
inline fn decodeOk(r: *Reader, table: [*]const Entry) u32 {
    return huffman.decode(r, false, table) catch unreachable; // unreachable: fast reads never fail
}

/// `literals` by how the current block type finds its trees.
inline fn literalBatch(s: *const State, t: *const Tables, f: *Fast, buf: [*]u8, n: u32, end: usize, p1: u8, p2: u8) u32 {
    if (s.blocks.literal_tree != null) return literals(.trivial, s, t, f, buf, n, end, p1, p2);
    if (s.blocks.literal_bytes) return literals(.bytes, s, t, f, buf, n, end, p1, p2);
    return literals(.contexts, s, t, f, buf, n, end, p1, p2);
}

/// Up to `n` literals of the current block type while the input has its
/// margin; how many.
inline fn literals(comptime by: enum { trivial, contexts, bytes }, s: *const State, t: *const Tables, f: *Fast, buf: [*]u8, n: u32, end: usize, first_p1: u8, first_p2: u8) u32 {
    const lookup = s.blocks.literal_lookup;
    const trees = &t.literal_contexts;
    const bytes = &t.literal_bytes;
    const fixed = if (by == .trivial) t.literal[s.blocks.literal_tree.?..].ptr else undefined;
    var pos = f.pos;
    var p1 = first_p1;
    var p2 = first_p2;
    var left = n;
    while (left != 0 and f.br.pos <= end) : (left -= 1) {
        const table = switch (by) {
            .trivial => fixed,
            .contexts => t.literal[trees[lookup[p1] | lookup[256 + @as(usize, p2)]]..].ptr,
            .bytes => t.literal[bytes[@as(usize, p1) << 3 | lookup[256 + @as(usize, p2)]]..].ptr,
        };
        const literal: u8 = @intCast(decodeOk(&f.br, table));
        buf[pos] = literal;
        pos += 1;
        p2 = p1;
        p1 = literal;
    }
    f.pos = pos;
    return n - left;
}

/// What a command's distance names.
const Source = enum {
    /// `State.distance` back in the history.
    history,
    /// The prefix dictionary, from `State.prefix_at`.
    prefix,
    /// A static dictionary word, now in `State.word`.
    word,
};

/// Commit the command's distance: refuse it, or say what it copies from,
/// with the meta-block's remaining length taken.
noinline fn resolve(s: *State, h: anytype, d: u32, push: bool, at: u64, word_dst: [*]u8) StepError!Source {
    const max_distance: u64 = @min(h.total(), s.max_backward);
    if (d <= max_distance) {
        if (push) pushDistance(s, d);
        if (@as(i64, s.copy) > s.remaining) return s.fail(.block_length, at);
        s.remaining -= s.copy;
        s.distance = d;
        return .history;
    }
    if (d > codes.max_allowed_distance) return s.fail(.distance, at);
    const prefix = h.prefix();
    const beyond = d - max_distance - 1;
    if (beyond < prefix.len) {
        const address = prefix.len - (d - max_distance);
        if (address + s.copy > prefix.len) return s.fail(.prefix_dictionary, at);
        if (push) pushDistance(s, d);
        s.remaining -= s.copy;
        if (s.remaining < 0) return s.fail(.block_length, at);
        s.prefix_at = address;
        s.from_prefix = true;
        return .prefix;
    }
    const len = s.copy;
    if (len < dictionary.min_word or len > dictionary.max_word) return s.fail(.dictionary_word, at);
    const shift = dictionary.size_bits[len];
    const address = beyond - prefix.len;
    const index = address & ((@as(u64, 1) << shift) - 1);
    const transform = address >> shift;
    if (transform >= dictionary.transforms.len) return s.fail(.transform, at);
    const word = dictionary.data[dictionary.offsets[len] + index * len ..][0..len];
    const n = dictionary.transform(word_dst, word, @intCast(transform));
    if (n == 0 and d <= 120) return s.fail(.transform, at);
    s.remaining -= @intCast(n);
    if (s.remaining < 0) return s.fail(.block_length, at);
    s.word_len = @intCast(n);
    s.word_at = 0;
    return .word;
}

fn pushDistance(s: *State, d: u32) void {
    const old = s.distances;
    s.distances = .{ d, old[0], old[1], old[2] };
}

/// The meta-block's commands end in `from`.
fn endMetablock(s: *State, comptime from: Phase, at: u64) StepError!?Status {
    if (s.remaining < 0) return s.fail(.block_length, at);
    s.endPart(from);
    return null;
}

/// Where each tree of a group starts.
fn groupTrees(t: *Tables, group: u2) []u32 {
    return switch (group) {
        0 => &t.literal_trees,
        1 => &t.command_trees,
        2 => &t.distance_trees,
        3 => unreachable,
    };
}

/// The history of a whole-buffer decode: the caller's output, after a
/// prefix dictionary.
pub const Linear = struct {
    buf: []u8,
    /// Where the stream's output starts in `buf`.
    start: usize = 0,
    pos: usize = 0,
    /// `buf.len`: where output ends.
    limit: usize,
    dict: []const u8 = &.{},

    pub inline fn total(h: *const Linear) u64 {
        return h.pos - h.start;
    }

    pub inline fn room(h: *const Linear) usize {
        return h.buf.len - h.pos;
    }

    pub fn full(_: *Linear) StepError!?Status {
        return error.OutputTooSmall;
    }

    /// The output holds any window: there is none to size.
    pub fn begin(_: *Linear, _: u5) StepError!void {}

    pub inline fn prefix(h: *const Linear) []const u8 {
        return h.dict;
    }

    /// The byte `n` (1 or 2) back, 0 before the stream's start.
    pub inline fn back(h: *const Linear, n: usize) u8 {
        return backAt(h.buf.ptr, h.limit, h.pos, h.total(), n);
    }

    /// `back` at `pos`, the stream's output `total` there.
    pub inline fn backAt(buf: [*]const u8, _: usize, pos: usize, written: u64, n: usize) u8 {
        return if (written >= n) buf[pos - n] else 0;
    }

    pub inline fn put(h: *Linear, b: u8) void {
        h.buf[h.pos] = b;
        h.pos += 1;
    }

    pub fn write(h: *Linear, bytes: []const u8) void {
        @memcpy(h.buf[h.pos..][0..bytes.len], bytes);
        h.pos += bytes.len;
    }

    /// Write what fits of `bytes`; how much.
    pub fn writeSome(h: *Linear, bytes: []const u8) usize {
        const n = @min(bytes.len, h.room());
        h.write(bytes[0..n]);
        return n;
    }

    /// Copy `len` bytes from `distance` back of `pos` with 16-byte moves
    /// that may write up to 15 bytes past them; the caller left that room.
    /// Returns the position after them.
    pub inline fn copyAt(buf: [*]u8, limit: usize, pos: usize, distance: u32, len: u32) usize {
        _ = limit;
        linearCopy(buf + pos, distance, len);
        return pos + len;
    }

    pub inline fn copyFast(h: *Linear, distance: u32, len: u32) bool {
        h.pos = copyAt(h.buf.ptr, h.limit, h.pos, distance, len);
        return true;
    }

    inline fn linearCopy(dst: [*]u8, distance: u32, len: u32) void {
        const src = dst - distance;
        if (distance >= 16) {
            var i: usize = 0;
            while (i < len) : (i += 16) dst[i..][0..16].* = src[i..][0..16].*;
        } else if (distance >= 8) {
            var i: usize = 0;
            while (i < len) : (i += 8) dst[i..][0..8].* = src[i..][0..8].*;
        } else if (distance == 1) {
            const v: @Vector(16, u8) = @splat(src[0]);
            var i: usize = 0;
            while (i < len) : (i += 16) dst[i..][0..16].* = v;
        } else {
            for (0..len) |i| dst[i] = src[i];
        }
    }

    /// Copy what fits of `len` bytes from `distance` back; how many.
    pub fn copy(h: *Linear, distance: u32, len: u32) u32 {
        const n: u32 = @intCast(@min(len, h.room()));
        var src = h.pos - distance;
        var dst = h.pos;
        for (0..n) |_| {
            h.buf[dst] = h.buf[src];
            dst += 1;
            src += 1;
        }
        h.pos = dst;
        return n;
    }
};

/// The history of a resumable decode: the caller's window as a ring of
/// 2^WBITS bytes, written up to its end and drained before it wraps. A
/// distance never reaches more than 2^WBITS - 16 back, so a move that
/// writes up to 15 bytes past its end never touches history still needed.
pub const Ring = struct {
    buf: []u8,
    /// The ring's size, 2^WBITS.
    limit: usize,
    pos: usize = 0,
    /// Bytes before `drained` have been handed out.
    drained: usize = 0,
    /// The stream's output before this lap of the ring.
    base: u64 = 0,
    dict: []const u8 = &.{},

    pub inline fn total(h: *const Ring) u64 {
        return h.base + h.pos;
    }

    pub inline fn room(h: *const Ring) usize {
        return h.limit - h.pos;
    }

    pub fn full(_: *Ring) StepError!?Status {
        return .output_full;
    }

    /// Size the ring for the stream's window, if the caller's holds it.
    pub fn begin(h: *Ring, window_bits: u5) StepError!void {
        const size = @as(usize, 1) << window_bits;
        if (size > h.buf.len) return error.WindowTooLarge;
        h.* = .{ .buf = h.buf, .limit = size, .dict = h.dict };
    }

    pub inline fn prefix(h: *const Ring) []const u8 {
        return h.dict;
    }

    pub inline fn back(h: *const Ring, n: usize) u8 {
        return backAt(h.buf.ptr, h.limit, h.pos, h.total(), n);
    }

    pub inline fn backAt(buf: [*]const u8, limit: usize, pos: usize, written: u64, n: usize) u8 {
        return if (written >= n) buf[(pos + limit - n) & (limit - 1)] else 0;
    }

    pub inline fn put(h: *Ring, b: u8) void {
        h.buf[h.pos] = b;
        h.pos += 1;
    }

    pub fn write(h: *Ring, bytes: []const u8) void {
        @memcpy(h.buf[h.pos..][0..bytes.len], bytes);
        h.pos += bytes.len;
    }

    pub fn writeSome(h: *Ring, bytes: []const u8) usize {
        const n = @min(bytes.len, h.room());
        h.write(bytes[0..n]);
        return n;
    }

    /// As `Linear.copyAt`; a source that starts in the last lap, at the
    /// ring's end, is copied from there first, then from the start.
    pub inline fn copyAt(buf: [*]u8, limit: usize, pos: usize, distance: u32, len: u32) usize {
        var at = pos;
        var n = len;
        if (distance > at) {
            // The source is at least 16 bytes ahead of the destination
            // (a distance is at most 2^WBITS - 16), so moving forward in
            // 16-byte pieces reads each byte before it is written.
            const behind = distance - at;
            const src = buf + (limit - behind);
            const dst = buf + at;
            const first = @min(n, behind);
            var i: usize = 0;
            while (i + 16 <= first) : (i += 16) dst[i..][0..16].* = src[i..][0..16].*;
            while (i < first) : (i += 1) dst[i] = src[i];
            at += first;
            n -= first;
            if (n == 0) return at;
        }
        Linear.linearCopy(buf + at, distance, n);
        return at + n;
    }

    pub inline fn copyFast(h: *Ring, distance: u32, len: u32) bool {
        h.pos = copyAt(h.buf.ptr, h.limit, h.pos, distance, len);
        return true;
    }

    pub fn copy(h: *Ring, distance: u32, len: u32) u32 {
        const n: u32 = @intCast(@min(len, h.room()));
        const mask = h.limit - 1;
        var src = (h.pos + h.limit - distance) & mask;
        for (0..n) |_| {
            h.buf[h.pos] = h.buf[src];
            h.pos += 1;
            src = (src + 1) & mask;
        }
        return n;
    }

    /// Bytes written and not yet handed out.
    pub fn pending(h: *const Ring) []const u8 {
        return h.buf[h.drained..h.pos];
    }

    /// Start the next lap once the ring is full and drained.
    pub fn wrap(h: *Ring) void {
        if (h.pos != h.limit or h.drained != h.limit) return;
        h.base += h.limit;
        h.pos = 0;
        h.drained = 0;
    }
};
