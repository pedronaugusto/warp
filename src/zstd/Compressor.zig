//! Whole-buffer zstd compression: one complete frame per call, from memory
//! taken once.
//!
//! The tables are sized when the compressor is made; a call clears none of
//! them (its positions continue from the call before, so what an earlier
//! call left is out of reach). Nothing is allocated per call.

const Compressor = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const params_ = @import("params.zig");
const encode = @import("encode.zig");
const frame = @import("frame.zig");
const window = @import("match/window.zig");
const fast = @import("match/fast.zig");
const dfast = @import("match/dfast.zig");
const lazy_ = @import("match/lazy.zig");
const split = @import("split.zig");

pub const Strategy = encode.Strategy;
pub const Params = params_.Params;

/// Private: the options the tables were sized for.
options: Options,
/// Private: the largest table logs the memory holds.
capacity: Params,
/// Private: the match tables.
hash_table: []u32,
chain_table: []u32,
tag_table: []u8,
/// Private: the chain and row matchfinders' insertion state.
lazy: lazy_.State,
/// Private: one block's sequences and literals.
store: encode.SeqStore,
/// Private: the tables the last block left, and the block's own.
entropy: [2]encode.Entropy,
/// Private: the index the next call's input starts at.
next_index: u32,
/// Private: the memory `init` allocated, freed by `deinit`.
owned: []align(64) u8,
gpa: Allocator,

/// Settings the level does not decide: each null keeps the level's.
pub const Tuning = struct {
    window_log: ?u5 = null,
    hash_log: ?u5 = null,
    chain_log: ?u5 = null,
    search_log: ?u5 = null,
    min_match: ?u3 = null,
    target_length: ?u32 = null,
    strategy: ?Strategy = null,
};

pub const Options = struct {
    /// -131072 (fastest) to 22 (smallest); 0 means 3.
    level: i32 = params_.default_level,
    tuning: Tuning = .{},
    /// The largest input `compress` will see: it sizes the tables. A larger
    /// input still compresses, with tables of this size. null: any input.
    max_input: ?usize = null,
};

/// What surrounds the compressed data.
pub const Frame = struct {
    /// An XXH64 checksum of the content after the last block.
    checksum: bool = true,
    /// The content size in the header.
    content_size: bool = true,
    format: frame.Format = .standard,
};

fn resolve(options: Options, size: ?u64) Params {
    var p = params_.forLevel(options.level, size, 0);
    const t = options.tuning;
    var changed = false;
    if (t.window_log) |v| {
        p.window_log = v;
        changed = true;
    }
    if (t.hash_log) |v| {
        p.hash_log = v;
        changed = true;
    }
    if (t.chain_log) |v| {
        p.chain_log = v;
        changed = true;
    }
    if (t.search_log) |v| p.search_log = v;
    if (t.min_match) |v| p.min_match = v;
    if (t.target_length) |v| p.target_length = v;
    if (t.strategy) |v| p.strategy = v;
    if (changed) p = params_.adjust(p, size, 0);
    return p;
}

/// Hash rows rather than chains: greedy to lazy2 over windows above 16 KiB,
/// as the reference decides.
fn rows(p: Params) bool {
    return params_.usesRows(p.strategy) and p.window_log > 14;
}

const Layout = struct {
    hash: usize,
    chain: usize,
    tags: usize,
    seqs: usize,
    lits: usize,

    fn of(p: Params) Layout {
        const block: usize = @min(encode.block_max, @as(usize, 1) << p.window_log);
        const with_rows = rows(p);
        // Rows serve large inputs; an input under 16 KiB is searched by
        // chains, which never need more than 2^15 entries there.
        const chain: usize = if (p.strategy == .fast) 0 else if (with_rows) @as(usize, 1) << @min(p.chain_log, 15) else @as(usize, 1) << p.chain_log;
        return .{
            .hash = @as(usize, 1) << p.hash_log,
            .chain = chain,
            .tags = if (with_rows) @as(usize, 1) << p.hash_log else 0,
            .seqs = encode.SeqStore.capacity(block, p.min_match),
            .lits = block + 32,
        };
    }

    fn bytes(l: Layout) usize {
        return std.mem.alignForward(usize, l.hash * 4 + l.chain * 4 + l.tags + l.seqs * (@sizeOf(encode.Sequence) + 3) + l.lits, 64);
    }
};

/// The bytes `initBuffer` needs for `options`.
pub fn memory(options: Options) usize {
    return Layout.of(resolve(options, if (options.max_input) |n| n else null)).bytes();
}

pub fn init(gpa: Allocator, options: Options) Allocator.Error!Compressor {
    const buffer = try gpa.alignedAlloc(u8, .@"64", memory(options));
    var c = initBuffer(buffer, options);
    c.owned = buffer;
    c.gpa = gpa;
    return c;
}

/// A compressor in caller memory: `buffer.len >= memory(options)`; `deinit`
/// then frees nothing.
pub fn initBuffer(buffer: []align(64) u8, options: Options) Compressor {
    const p = resolve(options, if (options.max_input) |n| n else null);
    const l = Layout.of(p);
    std.debug.assert(buffer.len >= l.bytes());
    var at: usize = 0;
    const hash_table: []u32 = @alignCast(std.mem.bytesAsSlice(u32, buffer[at..][0 .. l.hash * 4]));
    at += l.hash * 4;
    const chain_table: []u32 = @alignCast(std.mem.bytesAsSlice(u32, buffer[at..][0 .. l.chain * 4]));
    at += l.chain * 4;
    const tag_table = buffer[at..][0..l.tags];
    at += l.tags;
    const seqs: []encode.Sequence = @alignCast(std.mem.bytesAsSlice(encode.Sequence, buffer[at..][0 .. l.seqs * @sizeOf(encode.Sequence)]));
    at += l.seqs * @sizeOf(encode.Sequence);
    const codes_ = buffer[at..][0 .. 3 * l.seqs];
    at += 3 * l.seqs;
    const lits = buffer[at..][0..l.lits];
    @memset(hash_table, 0);
    @memset(chain_table, 0);
    @memset(tag_table, 0);
    var c: Compressor = .{
        .options = options,
        .capacity = p,
        .hash_table = hash_table,
        .chain_table = chain_table,
        .tag_table = tag_table,
        .lazy = undefined,
        .store = .{ .seqs = seqs, .lits = lits, .ll_codes = codes_[0..l.seqs], .ml_codes = codes_[l.seqs..][0..l.seqs], .of_codes = codes_[2 * l.seqs ..][0..l.seqs] },
        .entropy = undefined,
        .next_index = first_index,
        .owned = &.{},
        .gpa = undefined,
    };
    c.entropy[0].reset();
    c.entropy[1].reset();
    return c;
}

pub fn deinit(c: *Compressor) void {
    if (c.owned.len != 0) c.gpa.free(c.owned);
    c.* = undefined;
}

/// Indices start above 0, so an empty entry is never a position.
const first_index = 2;
/// Past this, tables are cleared and indices start again.
const index_limit: u64 = 1 << 30;

pub const CompressError = error{
    /// `out` is shorter than the frame; with `out.len >= bound(...)` this
    /// never happens.
    OutputTooSmall,
};

/// The longest frame `compress` writes for `len` bytes of input.
pub fn bound(len: usize) usize {
    const small = if (len < 128 * 1024) (128 * 1024 - len) >> 11 else 0;
    return len + (len >> 8) + small;
}

/// One complete frame of `in` into `out`; returns its length.
pub fn compress(c: *Compressor, in: []const u8, out: []u8, f: Frame) CompressError!usize {
    var p = resolve(c.options, in.len);
    p.hash_log = @min(p.hash_log, c.capacity.hash_log);
    if (c.chain_table.len != 0) p.chain_log = @min(p.chain_log, std.math.log2_int(usize, c.chain_table.len));
    if (c.next_index + @as(u64, in.len) >= index_limit) {
        @memset(c.hash_table, 0);
        @memset(c.chain_table, 0);
        @memset(c.tag_table, 0);
        c.next_index = first_index;
    }
    const start = c.next_index;
    c.next_index += @intCast(in.len + 1);
    if (params_.usesRows(p.strategy) or p.strategy == .btlazy2) c.prepareLazy(p, start);
    var o = try writeHeader(out, p, in.len, f);
    const block_max: usize = @min(encode.block_max, @as(usize, 1) << p.window_log);
    var reps: [3]u32 = .{ 1, 4, 8 };
    var prev: usize = 0;
    c.entropy[0].reset();
    var pos: usize = 0;
    var first = true;
    // Bytes saved so far: a block is split only once there are some, so
    // incompressible input is never cut into more blocks.
    var savings: i64 = 0;
    const raw_literals = p.strategy == .fast and p.target_length > 0;
    while (true) {
        const len = blockSize(in[pos..], block_max, p.strategy, savings);
        const last = pos + len == in.len;
        const w: window.Window = .{ .in = in, .start = start, .low = 0 };
        var block_w = w;
        block_w.low = w.lowFor(pos + len, p.window_log);
        if (out.len - o < 3) return error.OutputTooSmall;
        var size: usize = 0;
        var next_reps = reps;
        // Blocks under 7 bytes are sent raw, as the reference sends them.
        if (len >= 7) {
            c.store.reset();
            const rest = c.search(p, block_w, &next_reps, pos, pos + len);
            c.store.storeLast(in[pos + len - rest .. pos + len]);
            size = encode.compressBlock(&c.store, len, &c.entropy[prev], &c.entropy[1 - prev], p.strategy, raw_literals, out[o + 3 ..]);
            // A block of one byte repeated is RLE, but never the first:
            // decoders up to zstd 1.4.3 refuse a frame that starts so.
            if (!first and size < 25 and allSame(in[pos..][0..len])) size = 1;
        }
        const o_block = o;
        if (size == 0) {
            if (out.len - o - 3 < len) return error.OutputTooSmall;
            std.mem.writeInt(u24, out[o..][0..3], @intCast(@as(usize, @intFromBool(last)) | len << 3), .little);
            @memcpy(out[o + 3 ..][0..len], in[pos..][0..len]);
            o += 3 + len;
        } else if (size == 1) {
            std.mem.writeInt(u24, out[o..][0..3], @intCast(@as(usize, @intFromBool(last)) | 1 << 1 | len << 3), .little);
            out[o + 3] = in[pos];
            o += 4;
        } else {
            std.mem.writeInt(u24, out[o..][0..3], @intCast(@as(usize, @intFromBool(last)) | 2 << 1 | size << 3), .little);
            o += 3 + size;
            prev = 1 - prev;
            reps = next_reps;
        }
        if (c.entropy[prev].of_repeat == .valid) c.entropy[prev].of_repeat = .check;
        savings += @as(i64, @intCast(len)) - @as(i64, @intCast(o - o_block));
        pos += len;
        first = false;
        if (last) break;
    }
    if (f.checksum) {
        if (out.len - o < 4) return error.OutputTooSmall;
        std.mem.writeInt(u32, out[o..][0..4], @truncate(std.hash.XxHash64.hash(0, in)), .little);
        o += 4;
    }
    return o;
}

/// The next block's size: a full block, cut where its statistics change
/// once compression has saved a few bytes (the reference's pre-splitter).
fn blockSize(rest: []const u8, block_max: usize, strategy: Strategy, savings: i64) usize {
    const full = 128 << 10;
    if (rest.len < full or block_max < full) return @min(rest.len, block_max);
    if (savings < 3) return full;
    const levels = [10]u3{ 0, 0, 1, 2, 2, 3, 3, 4, 4, 4 };
    return split.split(rest[0..full], levels[@backingInt(strategy)]);
}

fn allSame(bytes: []const u8) bool {
    for (bytes[1..]) |b| if (b != bytes[0]) return false;
    return true;
}

fn prepareLazy(c: *Compressor, p: Params, start: u32) void {
    const with_rows = rows(p);
    const row_log: u3 = @intCast(std.math.clamp(p.search_log, 4, 6));
    c.lazy = .{
        .hash = c.hash_table[0 .. @as(usize, 1) << p.hash_log],
        .chain = if (with_rows) &.{} else c.chain_table[0 .. @as(usize, 1) << p.chain_log],
        .tags = if (with_rows) c.tag_table[0 .. @as(usize, 1) << p.hash_log] else &.{},
        .hash_log = if (with_rows) p.hash_log - row_log else p.hash_log,
        .chain_log = p.chain_log,
        .row_log = row_log,
        .search_log = p.search_log,
        .window_log = p.window_log,
        .next = start,
    };
}

/// Run the strategy over one block; returns the trailing literals.
fn search(c: *Compressor, p: Params, w: window.Window, reps: *[3]u32, start: usize, end: usize) usize {
    const table = c.hash_table[0 .. @as(usize, 1) << p.hash_log];
    const cmov = p.window_log < 19;
    return switch (p.strategy) {
        .fast => switch (@max(4, @min(p.min_match, 7))) {
            inline 4, 5, 6, 7 => |mls| if (cmov)
                fast.compress(table, p.hash_log, w, &c.store, reps, start, end, p.target_length, mls, true)
            else
                fast.compress(table, p.hash_log, w, &c.store, reps, start, end, p.target_length, mls, false),
            else => unreachable,
        },
        .dfast => switch (@max(4, @min(p.min_match, 7))) {
            inline 4, 5, 6, 7 => |mls| dfast.compress(table, p.hash_log, c.chain_table[0 .. @as(usize, 1) << p.chain_log], p.chain_log, w, &c.store, reps, start, end, mls),
            else => unreachable,
        },
        .btlazy2 => switch (@max(4, @min(p.min_match, 6))) {
            inline 4, 5, 6 => |mls| lazy_.compress(&c.lazy, w, &c.store, reps, start, end, .tree, 2, mls),
            else => unreachable,
        },
        .greedy, .lazy, .lazy2 => switch (@max(4, @min(p.min_match, 6))) {
            inline 4, 5, 6 => |mls| switch (p.strategy) {
                inline .greedy, .lazy, .lazy2 => |s| if (rows(p))
                    lazy_.compress(&c.lazy, w, &c.store, reps, start, end, .row, depthOf(s), mls)
                else
                    lazy_.compress(&c.lazy, w, &c.store, reps, start, end, .chain, depthOf(s), mls),
                else => unreachable,
            },
            else => unreachable,
        },
        else => switch (@max(4, @min(p.min_match, 7))) {
            inline 4, 5, 6, 7 => |mls| dfast.compress(table, p.hash_log, c.chain_table[0 .. @as(usize, 1) << p.chain_log], p.chain_log, w, &c.store, reps, start, end, mls),
            else => unreachable,
        },
    };
}

fn depthOf(s: Strategy) u2 {
    return switch (s) {
        .greedy => 0,
        .lazy => 1,
        else => 2,
    };
}

fn writeHeader(out: []u8, p: Params, size: usize, f: Frame) CompressError!usize {
    if (out.len < 18) return error.OutputTooSmall;
    var o: usize = 0;
    if (f.format == .standard) {
        std.mem.writeInt(u32, out[0..4], frame.magic, .little);
        o = 4;
    }
    const window_size = @as(u64, 1) << p.window_log;
    const single = f.content_size and window_size >= size;
    const fcs: u8 = if (f.content_size) @as(u8, @intFromBool(size >= 256)) + @intFromBool(size >= 65536 + 256) + @intFromBool(size >= 0xffff_ffff) else 0;
    out[o] = @as(u8, @intFromBool(f.checksum)) << 2 | @as(u8, @intFromBool(single)) << 5 | fcs << 6;
    o += 1;
    if (!single) {
        out[o] = (@as(u8, p.window_log) - params_.window_log_min) << 3;
        o += 1;
    }
    switch (fcs) {
        0 => if (single) {
            out[o] = @intCast(size);
            o += 1;
        },
        1 => {
            std.mem.writeInt(u16, out[o..][0..2], @intCast(size - 256), .little);
            o += 2;
        },
        2 => {
            std.mem.writeInt(u32, out[o..][0..4], @intCast(size), .little);
            o += 4;
        },
        else => {
            std.mem.writeInt(u64, out[o..][0..8], size, .little);
            o += 8;
        },
    }
    return o;
}
