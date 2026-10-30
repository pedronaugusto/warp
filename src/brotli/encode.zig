//! The encoder's engine: the reference encoder's (google/brotli 1.2.1)
//! stream state, ported so its choices, and so its output, are kept. Input
//! is gathered in a ring of 2^(1 + max(lgwin, lgblock)) bytes plus a copy
//! of its start (qualities 2-11), parsed into commands block by block,
//! and written as a meta-block once the commands of up to a meta-block's
//! worth of blocks are in, or on flush and finish. Qualities 0 and 1 code
//! each piece of input in place, with no ring. All memory is the
//! encoder's, kept between calls and streams; it grows to the reference's
//! sizes for the input it is given.

const std = @import("std");
const Allocator = std.mem.Allocator;
const bits = @import("bits.zig");
const command = @import("command.zig");
const fragment = @import("fragment.zig");
const fragment2 = @import("fragment2.zig");
const hash = @import("hash.zig");
const backward = @import("backward.zig");
const zopfli = @import("zopfli.zig");
const metablock = @import("metablock.zig");
const Prepared = @import("Prepared.zig");
const settings = @import("settings.zig");

const Writer = bits.Writer;
const Params = settings.Params;
const Resolved = settings.Resolved;
const resolve = settings.resolve;
const ringBits = settings.ringBits;
const maxMetaBlockSize = settings.maxMetaBlockSize;
const wrapPosition = settings.wrapPosition;
const window_gap = settings.window_gap;
const Command = command.Command;

/// Below block splitting, commands and literals are written once this many
/// are waiting.
const max_delayed_symbols = 0x2fff;
pub const two_pass_block_size = 1 << 17;

/// The window bits of the stream header, as `last_bytes`.
fn windowBits(lgwin: u5, large_window: bool) struct { bytes: u16, count: u8 } {
    if (large_window) return .{ .bytes = (@as(u16, lgwin) << 8) | 0x11, .count = 14 };
    if (lgwin == 16) return .{ .bytes = 0, .count = 1 };
    if (lgwin == 17) return .{ .bytes = 1, .count = 7 };
    if (lgwin > 17) return .{ .bytes = (@as(u16, lgwin - 17) << 1) | 1, .count = 4 };
    return .{ .bytes = (@as(u16, lgwin - 8) << 4) | 1, .count = 7 };
}

/// The input ring: 2^bits bytes, a copy of the first `tail` bytes after
/// them, two bytes before them (the last two of the ring), and seven zero
/// bytes past the end for eight-byte hashing.
pub const Ring = struct {
    size: u32,
    mask: u32,
    tail_size: u32,
    total_size: u32,
    cur_size: u32 = 0,
    pos: u32 = 0,
    /// Whether this stream has written to the ring: its buffer may be one
    /// an earlier stream left (`Encoder.reset`).
    written: bool = false,
    /// Two bytes before `buffer`, at least `cur_size + 7` after.
    data: []u8 = &.{},

    const slack = 7;

    fn setup(r: *const Resolved) Ring {
        const window_bits = ringBits(r);
        const size = @as(u32, 1) << window_bits;
        const tail = @as(u32, 1) << r.lgblock;
        return .{ .size = size, .mask = size - 1, .tail_size = tail, .total_size = size + tail };
    }

    pub fn buffer(rb: *const Ring) []u8 {
        return rb.data[2..];
    }

    /// The buffer grown to `len`, what it holds kept; one already large
    /// enough is kept as it is.
    fn initBuffer(rb: *Ring, gpa: Allocator, len: u32) Allocator.Error!void {
        if (rb.data.len < 2 + len + slack) {
            const new = try gpa.alloc(u8, 2 + len + slack);
            if (rb.data.len != 0) {
                @memcpy(new[0 .. 2 + rb.cur_size + slack], rb.data[0 .. 2 + rb.cur_size + slack]);
                gpa.free(rb.data);
            }
            rb.data = new;
        }
        rb.written = true;
        rb.cur_size = len;
        rb.data[0] = 0;
        rb.data[1] = 0;
        @memset(rb.data[2 + len ..][0..slack], 0);
    }

    fn writeTail(rb: *Ring, bytes: []const u8) void {
        const masked = rb.pos & rb.mask;
        if (masked < rb.tail_size) {
            const p = rb.size + masked;
            const n = @min(bytes.len, rb.tail_size - masked);
            @memcpy(rb.buffer()[p..][0..n], bytes[0..n]);
        }
    }

    fn write(rb: *Ring, gpa: Allocator, bytes: []const u8) Allocator.Error!void {
        const n: u32 = @intCast(bytes.len);
        if (rb.pos == 0 and n < rb.tail_size) {
            // A first write below an input block needs no more.
            rb.pos = n;
            try rb.initBuffer(gpa, n);
            @memcpy(rb.buffer()[0..n], bytes);
            return;
        }
        const buf_ = blk: {
            if (rb.cur_size < rb.total_size) {
                try rb.initBuffer(gpa, rb.total_size);
                const b = rb.buffer();
                b[rb.size - 2] = 0;
                b[rb.size - 1] = 0;
                // The match finders' "best_len + 1" probe may touch it.
                b[rb.size] = 241;
            }
            break :blk rb.buffer();
        };
        const masked = rb.pos & rb.mask;
        rb.writeTail(bytes);
        if (masked + n <= rb.size) {
            @memcpy(buf_[masked..][0..n], bytes);
        } else {
            const first = @min(n, rb.total_size - masked);
            @memcpy(buf_[masked..][0..first], bytes[0..first]);
            const split = rb.size - masked;
            @memcpy(buf_[0 .. n - split], bytes[split..]);
        }
        const not_first_lap = rb.pos & (1 << 31) != 0;
        const pos_mask: u32 = (1 << 31) - 1;
        rb.data[0] = buf_[rb.size - 2];
        rb.data[1] = buf_[rb.size - 1];
        rb.pos = (rb.pos & pos_mask) +% (n & pos_mask);
        if (not_first_lap) rb.pos |= 1 << 31;
    }

    fn deinit(rb: *Ring, gpa: Allocator) void {
        if (rb.data.len != 0) gpa.free(rb.data);
        rb.* = undefined;
    }
};

pub const Operation = enum { process, flush, finish, emit_metadata };

const StreamState = enum { processing, flush_requested, finished, metadata_head, metadata_body };

const flint_needs_2_bytes: i8 = 2;
const flint_waiting_for_processing: i8 = 0;
const flint_waiting_for_flushing: i8 = -1;
const flint_done: i8 = -2;

pub const Error = Allocator.Error || error{
    /// The operation does not fit the stream's state (input after finish,
    /// metadata over 16 MiB or with other input, ...).
    InvalidOperation,
};

pub const Encoder = struct {
    gpa: Allocator,
    params: Resolved,
    hasher: hash.Hasher = .{},
    input_pos: u64 = 0,
    ring: Ring,
    commands: []Command = &.{},
    num_commands: usize = 0,
    num_literals: usize = 0,
    last_insert_len: usize = 0,
    last_flush_pos: u64 = 0,
    last_processed_pos: u64 = 0,
    dist_cache: [16]i32 = .{ 4, 11, 15, 16 } ++ @as([12]i32, @splat(0)),
    saved_dist_cache: [4]i32 = .{ 4, 11, 15, 16 },
    last_bytes: u16 = 0,
    last_bytes_bits: u8 = 0,
    flint: i8 = flint_done,
    prev_byte: u8 = 0,
    prev_byte2: u8 = 0,
    storage: []u8 = &.{},
    small_table: [1 << 10]i32 = undefined,
    large_table: []i32 = &.{},
    one_pass: ?*fragment.Arena = null,
    two_pass: ?*fragment2.Arena = null,
    command_buf: []u32 = &.{},
    literal_buf: []u8 = &.{},
    total_in: u64 = 0,
    /// Output waiting to be taken: `next_out[0..available_out]`.
    next_out: [*]u8 = undefined,
    available_out: usize = 0,
    total_out: u64 = 0,
    tiny_buf: [16]u8 = undefined,
    remaining_metadata_bytes: u32 = std.math.maxInt(u32),
    stream_state: StreamState = .processing,
    is_last_block_emitted: bool = false,
    /// Scratch the meta-block builders keep between meta-blocks.
    scratch: metablock.Scratch = .{},

    pub fn init(gpa: Allocator, p: Params, dictionary: ?*const Prepared) Allocator.Error!Encoder {
        var e: Encoder = .fresh(gpa, p, dictionary);
        try e.makeArena();
        return e;
    }

    /// The encoder ready for a new stream, as `init` leaves one, its
    /// buffers kept where they are large enough for it. Nothing an earlier
    /// stream left in them is read: what a stream reads it has written, as
    /// with a fresh allocation, and the hasher keeps its tables only for
    /// the same hasher, rewound (`Hasher.startStream`). On failure the
    /// encoder is still one `deinit` frees.
    pub fn reset(e: *Encoder, p: Params, dictionary: ?*const Prepared) Allocator.Error!void {
        const gpa = e.gpa;
        const old = e.*;
        e.* = .fresh(gpa, p, dictionary);
        e.storage = old.storage;
        e.commands = old.commands;
        e.large_table = old.large_table;
        e.command_buf = old.command_buf;
        e.literal_buf = old.literal_buf;
        e.scratch = old.scratch;
        e.ring.data = old.ring.data;
        e.hasher = old.hasher;
        e.hasher.startStream();
        // The fragment coders' arena, kept for the quality that takes it.
        if (old.one_pass) |a| {
            if (e.params.quality == 0) e.one_pass = a else gpa.destroy(a);
        }
        if (old.two_pass) |a| {
            if (e.params.quality == 1) e.two_pass = a else gpa.destroy(a);
        }
        try e.makeArena();
    }

    /// The fragment coders' arena, set as new: quality 0's or 1's.
    fn makeArena(e: *Encoder) Allocator.Error!void {
        if (e.params.quality == 0) {
            const arena = e.one_pass orelse try e.gpa.create(fragment.Arena);
            arena.* = .{};
            e.one_pass = arena;
        } else if (e.params.quality == 1) {
            const arena = e.two_pass orelse try e.gpa.create(fragment2.Arena);
            arena.* = .{};
            e.two_pass = arena;
        }
    }

    /// The state `init` starts from, before its arena.
    fn fresh(gpa: Allocator, p: Params, dictionary: ?*const Prepared) Encoder {
        var r = resolve(p);
        r.dictionary = dictionary;
        settings.chooseHasher(&r);
        var e: Encoder = .{ .gpa = gpa, .params = r, .ring = .setup(&r) };
        if (r.stream_offset != 0) {
            e.flint = flint_needs_2_bytes;
            // Poisoned: -16 +- 3 is still not a distance.
            e.dist_cache[0..4].* = @splat(-16);
            e.saved_dist_cache = @splat(-16);
        }
        var lgwin = r.lgwin;
        if (r.quality <= 1) lgwin = @max(lgwin, 18);
        if (r.stream_offset == 0) {
            const wb = windowBits(lgwin, r.large_window);
            e.last_bytes = wb.bytes;
            e.last_bytes_bits = wb.count;
        } else {
            e.params.stream_offset = @min(r.stream_offset, (@as(usize, 1) << lgwin) - window_gap);
        }
        return e;
    }

    pub fn deinit(e: *Encoder) void {
        const gpa = e.gpa;
        if (e.storage.len != 0) gpa.free(e.storage);
        if (e.commands.len != 0) gpa.free(e.commands);
        e.ring.deinit(gpa);
        e.hasher.deinit(gpa);
        if (e.large_table.len != 0) gpa.free(e.large_table);
        if (e.one_pass) |a| gpa.destroy(a);
        if (e.two_pass) |a| gpa.destroy(a);
        if (e.command_buf.len != 0) gpa.free(e.command_buf);
        if (e.literal_buf.len != 0) gpa.free(e.literal_buf);
        e.scratch.deinit(gpa);
        e.* = undefined;
    }

    fn inputBlockSize(e: *const Encoder) usize {
        return @as(usize, 1) << e.params.lgblock;
    }

    fn unprocessedInputSize(e: *const Encoder) u64 {
        return e.input_pos - e.last_processed_pos;
    }

    fn remainingInputBlockSize(e: *const Encoder) usize {
        const delta = e.unprocessedInputSize();
        const block = e.inputBlockSize();
        if (delta >= block) return 0;
        return block - @as(usize, @intCast(delta));
    }

    fn getStorage(e: *Encoder, size: usize) Error![]u8 {
        if (e.storage.len < size) {
            if (e.storage.len != 0) e.gpa.free(e.storage);
            e.storage = &.{};
            e.storage = try e.gpa.alloc(u8, size);
        }
        return e.storage;
    }

    /// Quality 1's command and literal buffers, at least `size` long, kept
    /// for the calls and streams after (`size` is at most a whole block).
    fn twoPassBuffers(e: *Encoder, size: usize) Error!void {
        if (e.command_buf.len < size) {
            if (e.command_buf.len != 0) e.gpa.free(e.command_buf);
            e.command_buf = &.{};
            e.command_buf = try e.gpa.alloc(u32, size);
        }
        if (e.literal_buf.len < size) {
            if (e.literal_buf.len != 0) e.gpa.free(e.literal_buf);
            e.literal_buf = &.{};
            e.literal_buf = try e.gpa.alloc(u8, size);
        }
    }

    fn hashTable(e: *Encoder, quality: u4, input_size: usize) Error![]i32 {
        const max_size: usize = if (quality == 0) 1 << 15 else 1 << 17;
        var size: usize = 256;
        while (size < max_size and size < input_size) size <<= 1;
        // Quality 0 takes odd shifts only.
        if (quality == 0 and size & 0xAAAAA == 0) size <<= 1;
        var table: []i32 = undefined;
        if (size <= e.small_table.len) {
            table = e.small_table[0..size];
        } else {
            if (size > e.large_table.len) {
                if (e.large_table.len != 0) e.gpa.free(e.large_table);
                e.large_table = &.{};
                e.large_table = try e.gpa.alloc(i32, size);
            }
            table = e.large_table[0..size];
        }
        @memset(table, 0);
        return table;
    }

    fn copyInputToRing(e: *Encoder, input: []const u8) Error!void {
        try e.ring.write(e.gpa, input);
        e.input_pos += input.len;
        // On the first lap, the seven bytes after the input are zeros, so
        // eight-byte hashing past it is deterministic.
        if (e.ring.pos <= e.ring.mask) @memset(e.ring.buffer()[e.ring.pos..][0..7], 0);
    }

    /// Mark all input processed; true when the wrapped position wrapped.
    fn updateLastProcessedPos(e: *Encoder) bool {
        const wrapped_last = wrapPosition(e.last_processed_pos);
        const wrapped_input = wrapPosition(e.input_pos);
        e.last_processed_pos = e.input_pos;
        return wrapped_input < wrapped_last;
    }

    /// Extend the last command's copy over new input that continues it.
    fn extendLastCommand(e: *Encoder, bytes: *u32, wrapped_last_processed_pos: *u32) void {
        const last = &e.commands[e.num_commands - 1];
        const data = e.ring.buffer();
        const mask = e.ring.mask;
        const max_backward: u64 = (@as(u64, 1) << e.params.lgwin) - window_gap;
        const last_copy_len: u64 = last.copy_len & 0x1ffffff;
        const last_processed_pos = e.last_processed_pos - last_copy_len;
        const max_distance = @min(last_processed_pos, max_backward);
        const cmd_dist: u64 = @intCast(e.dist_cache[0]);
        const distance_code = last.restoreDistanceCode(&e.params.dist);
        if (distance_code < command.short_distance_codes or distance_code - (command.short_distance_codes - 1) == cmd_dist) {
            if (cmd_dist <= max_distance) {
                while (bytes.* != 0 and data[wrapped_last_processed_pos.* & mask] == data[(wrapped_last_processed_pos.* -% @as(u32, @intCast(cmd_dist))) & mask]) {
                    last.copy_len += 1;
                    bytes.* -= 1;
                    wrapped_last_processed_pos.* +%= 1;
                }
            } else if (e.params.dictionary) |dict| {
                dict.extendCopy(data, mask, cmd_dist - max_distance, last_copy_len, last, bytes, wrapped_last_processed_pos);
            }
            // The copy length stays within the meta-block: expressible.
            last.cmd_prefix = command.lengthCode(last.insert_len, @intCast(@as(i64, last.copy_len & 0x1ffffff) + (last.copy_len >> 25)), last.dist_prefix & 0x3ff == 0);
        }
    }

    /// Process the input gathered since the last call into a meta-block when
    /// it is time (or `is_last`, `force_flush`); the output is
    /// `next_out[0..available_out]`, or nothing when the input is buffered.
    fn encodeData(e: *Encoder, is_last: bool, force_flush: bool) Error!void {
        const delta = e.unprocessedInputSize();
        var bytes: u32 = @intCast(delta);
        var wrapped_last_processed_pos = wrapPosition(e.last_processed_pos);
        const quality = e.params.quality;
        const fast = quality <= 1;
        e.available_out = 0;
        if (delta == 0) {
            if (!e.ring.written) {
                if (is_last) {
                    // The stream header, then ISLAST and ISEMPTY.
                    e.last_bytes |= @as(u16, 3) << @intCast(e.last_bytes_bits);
                    e.last_bytes_bits += 2;
                    e.tiny_buf[0] = @truncate(e.last_bytes);
                    e.tiny_buf[1] = @truncate(e.last_bytes >> 8);
                    e.next_out = &e.tiny_buf;
                    e.available_out = (e.last_bytes_bits + 7) >> 3;
                }
                return;
            }
            // Fast qualities flush every block: a flush has nothing to do.
            if (!is_last and (!force_flush or fast)) return;
        }
        if (e.is_last_block_emitted) return error.InvalidOperation;
        if (is_last) e.is_last_block_emitted = true;
        std.debug.assert(delta <= e.inputBlockSize());
        const data = e.ring.buffer();
        const mask = e.ring.mask;

        if (quality == 1) try e.twoPassBuffers(two_pass_block_size);
        if (fast) {
            const storage = try e.getStorage(2 * bytes + 503);
            var w: Writer = .{ .buf = storage, .pos = e.last_bytes_bits };
            storage[0] = @truncate(e.last_bytes);
            storage[1] = @truncate(e.last_bytes >> 8);
            const table = try e.hashTable(quality, bytes);
            const input = data[wrapped_last_processed_pos & mask ..][0..bytes];
            if (quality == 0) {
                fragment.compress(e.one_pass.?, input, is_last, table, &w);
            } else {
                fragment2.compress(e.two_pass.?, input, is_last, e.command_buf, e.literal_buf, table, &w);
            }
            e.last_bytes = storage[w.pos >> 3];
            e.last_bytes_bits = @intCast(w.pos & 7);
            _ = e.updateLastProcessedPos();
            e.next_out = storage.ptr;
            e.available_out = w.pos >> 3;
            return;
        }

        // At most one command per two bytes.
        const needed = e.num_commands + bytes / 2 + 1;
        if (needed > e.commands.len) {
            // Room to merge the next block without growing again.
            const size = needed + bytes / 4 + 16;
            const new = try e.gpa.alloc(Command, size);
            @memcpy(new[0..e.num_commands], e.commands[0..e.num_commands]);
            if (e.commands.len != 0) e.gpa.free(e.commands);
            e.commands = new;
        }
        try e.hasher.initOrStitch(e.gpa, data, mask, &e.params, wrapped_last_processed_pos, bytes, is_last);
        const context_mode = metablock.chooseContextMode(&e.params, data, wrapPosition(e.last_flush_pos), mask, @intCast(e.input_pos - e.last_flush_pos));
        if (e.num_commands != 0 and e.last_insert_len == 0) e.extendLastCommand(&bytes, &wrapped_last_processed_pos);

        const cmds = e.commands[e.num_commands..];
        var refs: backward.Out = .{ .commands = cmds, .last_insert_len = &e.last_insert_len, .num_literals = &e.num_literals };
        if (quality == 10) {
            try zopfli.create(e.gpa, &e.scratch.zopfli, bytes, wrapped_last_processed_pos, data, mask, context_mode, &e.params, &e.hasher, &e.dist_cache, &refs);
        } else if (quality == 11) {
            try zopfli.createHq(e.gpa, &e.scratch.zopfli, bytes, wrapped_last_processed_pos, data, mask, context_mode, &e.params, &e.hasher, &e.dist_cache, &refs);
        } else {
            backward.create(bytes, wrapped_last_processed_pos, data, mask, context_mode, &e.params, &e.hasher, &e.dist_cache, &refs);
        }
        e.num_commands += refs.num_commands;

        {
            const max_length = maxMetaBlockSize(&e.params);
            const max_literals = max_length / 8;
            const max_commands = max_length / 8;
            const processed: usize = @intCast(e.input_pos - e.last_flush_pos);
            // Flush now when another whole block would not fit.
            const next_fits = processed + e.inputBlockSize() <= max_length;
            // Without block splitting, flush once enough is waiting.
            const should_flush = quality < 4 and e.num_literals + e.num_commands >= max_delayed_symbols;
            if (!is_last and !force_flush and !should_flush and next_fits and e.num_literals < max_literals and e.num_commands < max_commands) {
                // Merged with the next input block, later.
                if (e.updateLastProcessedPos()) e.hasher.reset();
                return;
            }
        }
        if (e.last_insert_len > 0) {
            e.commands[e.num_commands] = .insertOnly(e.last_insert_len);
            e.num_commands += 1;
            e.num_literals += e.last_insert_len;
            e.last_insert_len = 0;
        }
        if (!is_last and e.input_pos == e.last_flush_pos) return;
        std.debug.assert(e.input_pos - e.last_flush_pos <= 1 << 24);
        const metablock_size: u32 = @intCast(e.input_pos - e.last_flush_pos);
        const storage = try e.getStorage(2 * @as(usize, metablock_size) + 503);
        var w: Writer = .{ .buf = storage, .pos = e.last_bytes_bits };
        storage[0] = @truncate(e.last_bytes);
        storage[1] = @truncate(e.last_bytes >> 8);
        try metablock.write(e.gpa, &e.scratch, data, mask, e.last_flush_pos, metablock_size, is_last, context_mode, &e.params, e.prev_byte, e.prev_byte2, e.num_literals, e.commands[0..e.num_commands], &e.saved_dist_cache, &e.dist_cache, &w);
        e.last_bytes = storage[w.pos >> 3];
        e.last_bytes_bits = @intCast(w.pos & 7);
        e.last_flush_pos = e.input_pos;
        if (e.updateLastProcessedPos()) e.hasher.reset();
        if (e.last_flush_pos > 0) e.prev_byte = data[@as(u32, @truncate(e.last_flush_pos - 1)) & mask];
        if (e.last_flush_pos > 1) e.prev_byte2 = data[@as(u32, @truncate(e.last_flush_pos - 2)) & mask];
        e.num_commands = 0;
        e.num_literals = 0;
        // Kept in case the next meta-block is stored raw.
        e.saved_dist_cache = e.dist_cache[0..4].*;
        e.next_out = storage.ptr;
        e.available_out = w.pos >> 3;
    }

    /// The pending bits and a metadata block header into `header` (16
    /// bytes); returns its length. `block_size <= 1 << 24`.
    fn writeMetadataHeader(e: *Encoder, block_size: usize, header: []u8) usize {
        @memset(header, 0);
        var w: Writer = .{ .buf = header, .pos = e.last_bytes_bits };
        header[0] = @truncate(e.last_bytes);
        header[1] = @truncate(e.last_bytes >> 8);
        e.last_bytes = 0;
        e.last_bytes_bits = 0;
        w.bits(1, 0);
        w.bits(2, 3);
        w.bits(1, 0);
        if (block_size == 0) {
            w.bits(2, 0);
        } else {
            const nbits: u32 = if (block_size == 1) 1 else command.log2Floor(block_size - 1) + 1;
            const nbytes = (nbits + 7) / 8;
            w.bits(2, nbytes);
            w.bits(8 * nbytes, block_size - 1);
        }
        return (w.pos + 7) >> 3;
    }

    /// An empty metadata block padding the pending bits to a byte.
    fn injectBytePaddingBlock(e: *Encoder) void {
        var seal: u32 = e.last_bytes;
        var seal_bits: usize = e.last_bytes_bits;
        e.last_bytes = 0;
        e.last_bytes_bits = 0;
        // ISLAST 0, MNIBBLES 11, reserved 0, MSKIPBYTES 00.
        seal |= @as(u32, 0x6) << @intCast(seal_bits);
        seal_bits += 6;
        var dest: [*]u8 = undefined;
        if (e.available_out != 0) {
            dest = e.next_out + e.available_out;
        } else {
            dest = &e.tiny_buf;
            e.next_out = dest;
        }
        dest[0] = @truncate(seal);
        if (seal_bits > 8) dest[1] = @truncate(seal >> 8);
        if (seal_bits > 16) dest[2] = @truncate(seal >> 16);
        e.available_out += (seal_bits + 7) >> 3;
    }

    fn injectFlushOrPushOutput(e: *Encoder, out: *[]u8) bool {
        if (e.stream_state == .flush_requested and e.last_bytes_bits != 0) {
            e.injectBytePaddingBlock();
            return true;
        }
        if (e.available_out != 0 and out.len != 0) {
            const n = @min(e.available_out, out.len);
            @memcpy(out.*[0..n], e.next_out[0..n]);
            out.* = out.*[n..];
            e.next_out += n;
            e.available_out -= n;
            e.total_out += n;
            return true;
        }
        return false;
    }

    fn checkFlushComplete(e: *Encoder) void {
        if (e.stream_state == .flush_requested and e.available_out == 0) e.stream_state = .processing;
    }

    fn compressStreamFast(e: *Encoder, op: Operation, in: *[]const u8, out: *[]u8) Error!void {
        const block_size_limit = @as(usize, 1) << e.params.lgwin;
        const buf_size: usize = @min(two_pass_block_size, @min(in.len, block_size_limit));
        if (e.params.quality == 1) try e.twoPassBuffers(buf_size);
        while (true) {
            if (e.injectFlushOrPushOutput(out)) continue;
            if (e.available_out == 0 and e.stream_state == .processing and (in.len != 0 or op != .process)) {
                const block_size = @min(block_size_limit, in.len);
                const is_last = in.len == block_size and op == .finish;
                const force_flush = in.len == block_size and op == .flush;
                const max_out_size = 2 * block_size + 503;
                if (force_flush and block_size == 0) {
                    e.stream_state = .flush_requested;
                    continue;
                }
                const in_place = max_out_size <= out.len;
                const storage = if (in_place) out.* else try e.getStorage(max_out_size);
                var w: Writer = .{ .buf = storage, .pos = e.last_bytes_bits };
                storage[0] = @truncate(e.last_bytes);
                storage[1] = @truncate(e.last_bytes >> 8);
                const table = try e.hashTable(e.params.quality, block_size);
                if (e.params.quality == 0) {
                    fragment.compress(e.one_pass.?, in.*[0..block_size], is_last, table, &w);
                } else {
                    fragment2.compress(e.two_pass.?, in.*[0..block_size], is_last, e.command_buf, e.literal_buf, table, &w);
                }
                in.* = in.*[block_size..];
                e.total_in += block_size;
                const out_bytes = w.pos >> 3;
                if (in_place) {
                    out.* = out.*[out_bytes..];
                    e.total_out += out_bytes;
                    e.last_bytes = out.*[0];
                } else {
                    e.next_out = storage.ptr;
                    e.available_out = out_bytes;
                    e.last_bytes = storage[out_bytes];
                }
                e.last_bytes_bits = @intCast(w.pos & 7);
                if (force_flush) e.stream_state = .flush_requested;
                if (is_last) e.stream_state = .finished;
                continue;
            }
            break;
        }
        e.checkFlushComplete();
    }

    fn processMetadata(e: *Encoder, in: *[]const u8, out: *[]u8) Error!void {
        if (in.len > 1 << 24) return error.InvalidOperation;
        if (e.stream_state == .processing) {
            e.remaining_metadata_bytes = @intCast(in.len);
            e.stream_state = .metadata_head;
        }
        if (e.stream_state != .metadata_head and e.stream_state != .metadata_body) return error.InvalidOperation;
        while (true) {
            if (e.injectFlushOrPushOutput(out)) continue;
            if (e.available_out != 0) break;
            if (e.input_pos != e.last_flush_pos) {
                try e.encodeData(false, true);
                continue;
            }
            if (e.stream_state == .metadata_head) {
                e.next_out = &e.tiny_buf;
                e.available_out = e.writeMetadataHeader(e.remaining_metadata_bytes, &e.tiny_buf);
                e.stream_state = .metadata_body;
                continue;
            }
            // Leave only with no input and no output left; otherwise the
            // caller may go on with empty metadata blocks.
            if (e.remaining_metadata_bytes == 0) {
                e.remaining_metadata_bytes = std.math.maxInt(u32);
                e.stream_state = .processing;
                break;
            }
            if (out.len != 0) {
                const copy = @min(e.remaining_metadata_bytes, out.len);
                @memcpy(out.*[0..copy], in.*[0..copy]);
                in.* = in.*[copy..];
                e.total_in += copy;
                e.remaining_metadata_bytes -= @intCast(copy);
                out.* = out.*[copy..];
            } else {
                // Progress for callers that take output on their own.
                const copy = @min(e.remaining_metadata_bytes, 16);
                e.next_out = &e.tiny_buf;
                @memcpy(e.tiny_buf[0..copy], in.*[0..copy]);
                in.* = in.*[copy..];
                e.total_in += copy;
                e.remaining_metadata_bytes -= copy;
                e.available_out = copy;
            }
        }
    }

    fn updateSizeHint(e: *Encoder, available_in: usize) void {
        if (e.params.size_hint != 0) return;
        const delta = e.unprocessedInputSize();
        const tail: u64 = available_in;
        const limit: u64 = 1 << 30;
        e.params.size_hint = if (delta >= limit or tail >= limit or delta + tail >= limit) limit else @intCast(delta + tail);
    }

    /// The reference's `BrotliEncoderCompressStream`: take what fits of
    /// `in`, give what is ready into `out`; both advance.
    pub fn compressStream(e: *Encoder, op: Operation, in: *[]const u8, out: *[]u8) Error!void {
        if (e.remaining_metadata_bytes != std.math.maxInt(u32)) {
            if (in.len != e.remaining_metadata_bytes or op != .emit_metadata) return error.InvalidOperation;
        }
        if (op == .emit_metadata) {
            e.updateSizeHint(0);
            return e.processMetadata(in, out);
        }
        if (e.stream_state == .metadata_head or e.stream_state == .metadata_body) return error.InvalidOperation;
        if (e.stream_state != .processing and in.len != 0) return error.InvalidOperation;
        if (e.params.quality <= 1) return e.compressStreamFast(op, in, out);
        while (true) {
            var remaining_block_size = e.remainingInputBlockSize();
            if (e.flint >= 0 and remaining_block_size > @as(usize, @intCast(e.flint))) remaining_block_size = @intCast(e.flint);
            if (remaining_block_size != 0 and in.len != 0) {
                const n = @min(remaining_block_size, in.len);
                try e.copyInputToRing(in.*[0..n]);
                in.* = in.*[n..];
                e.total_in += n;
                if (e.flint > 0) e.flint -= @intCast(n);
                continue;
            }
            if (e.injectFlushOrPushOutput(out)) {
                // Leave the "emit flint" workflow.
                if (e.flint == flint_waiting_for_flushing) {
                    e.checkFlushComplete();
                    if (e.stream_state == .processing) e.flint = flint_done;
                }
                continue;
            }
            if (e.available_out == 0 and e.stream_state == .processing) {
                if (remaining_block_size == 0 or op != .process) {
                    const is_last = in.len == 0 and op == .finish;
                    var force_flush = in.len == 0 and op == .flush;
                    // The piece holding the flint goes out on its own.
                    if (!is_last and e.flint == flint_waiting_for_processing) {
                        e.flint = flint_waiting_for_flushing;
                        force_flush = true;
                    }
                    e.updateSizeHint(in.len);
                    try e.encodeData(is_last, force_flush);
                    if (force_flush) e.stream_state = .flush_requested;
                    if (is_last) e.stream_state = .finished;
                    continue;
                }
            }
            break;
        }
        e.checkFlushComplete();
    }

    pub fn isFinished(e: *const Encoder) bool {
        return e.stream_state == .finished and e.available_out == 0;
    }

    pub fn hasMoreOutput(e: *const Encoder) bool {
        return e.available_out != 0;
    }
};

/// The reference's `BrotliEncoderMaxCompressedSize`: the input stored in
/// uncompressed meta-blocks, with their headers; 0 when it overflows.
pub fn maxCompressedSize(input_size: usize) usize {
    if (input_size == 0) return 2;
    const num_large_blocks = input_size >> 14;
    const overhead = 2 + 4 * num_large_blocks + 3 + 1;
    return std.math.add(usize, input_size, overhead) catch 0;
}

/// A stream of uncompressed meta-blocks with the smallest window, as the
/// reference falls back to; `out` holds `maxCompressedSize(input.len)`.
pub fn uncompressedStream(input: []const u8, out: []u8) usize {
    if (input.len == 0) {
        out[0] = 6;
        return 1;
    }
    var result: usize = 0;
    out[0] = 0x21; // window bits 10, not last
    out[1] = 0x03; // empty metadata, padding
    result = 2;
    var offset: usize = 0;
    while (offset < input.len) {
        const chunk: u32 = @intCast(@min(input.len - offset, 1 << 24));
        const nibbles: u32 = if (chunk > 1 << 16) (if (chunk > 1 << 20) 2 else 1) else 0;
        const v: u32 = (nibbles << 1) | ((chunk - 1) << 3) | (@as(u32, 1) << @intCast(19 + 4 * nibbles));
        out[result] = @truncate(v);
        out[result + 1] = @truncate(v >> 8);
        out[result + 2] = @truncate(v >> 16);
        result += 3;
        if (nibbles == 2) {
            out[result] = @truncate(v >> 24);
            result += 1;
        }
        @memcpy(out[result..][0..chunk], input[offset..][0..chunk]);
        result += chunk;
        offset += chunk;
    }
    out[result] = 3;
    return result + 1;
}
