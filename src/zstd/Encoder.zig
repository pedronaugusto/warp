//! Whole-buffer zstd compression: one complete frame per call, from memory
//! taken once.
//!
//! The tables are sized when the compressor is made; a call clears none of
//! them (its positions continue from the call before, so what an earlier
//! call left is out of reach). Nothing is allocated per call.

const Encoder = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const params_ = @import("params.zig");
const encode = @import("encode.zig");
const frame = @import("frame.zig");
const match = @import("match.zig");
const window = match.window;
const fast = match.fast;
const dfast = match.dfast;
const lazy_ = match.lazy;
const opt_ = match.opt;
const split = @import("split.zig");
const post = @import("post.zig");
const sequences = @import("sequences.zig");
const Dictionary = @import("Dictionary.zig");
const dictionary_match = @import("match/dictionary.zig");
const long_match = @import("match/long.zig");

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
/// Private: optimal parsing tables and adaptive prices.
optimal: opt_.State,
hash3_table: []u32,
opt_workspace: ?*opt_.Workspace,
/// Private: one block's sequences and literals.
store: encode.SeqStore,
/// Private: the tables the last block left, and the block's own.
entropy: [2]encode.Entropy,
/// Private: the index the next call's input starts at.
next_index: u32,
/// Private: the memory `init` allocated, freed by `deinit`.
owned: []align(64) u8,
gpa: Allocator,
/// Private: immutable dictionary index and prefix sequence scratch.
dictionary_index: ?dictionary_match.Index,
dictionary_sequences: []encode.Sequence,
long: ?long_match.State,

/// Settings the level does not decide: each null keeps the level's.
/// Logs and minimum lengths outside the supported range are clamped.
pub const Tuning = struct {
    window_log: ?u5 = null,
    hash_log: ?u5 = null,
    chain_log: ?u5 = null,
    search_log: ?u5 = null,
    min_match: ?u3 = null,
    target_length: ?u32 = null,
    strategy: ?Strategy = null,
    /// Sparse matching over a larger retained window (128 MiB by default).
    long_distance: bool = false,
};

pub const Options = struct {
    /// -131072 (fastest) to 22 (smallest); 0 means 3.
    level: i32 = params_.default_level,
    tuning: Tuning = .{},
    /// The largest input `compress` will see: it sizes the tables. A larger
    /// input still compresses, with tables of this size. null: any input.
    max_input: ?usize = null,
    /// Borrowed and indexed once; must outlive the compressor.
    dictionary: ?*const Dictionary = null,
};

/// What surrounds the compressed data.
pub const Frame = struct {
    /// An XXH64 checksum of the content after the last block.
    checksum: bool = true,
    /// The content size in the header.
    content_size: bool = true,
    format: frame.Format = .standard,
    dictionary_id: bool = true,
};

pub fn resolve(options: Options, size: ?u64) Params {
    const dict_len = if (options.dictionary) |d| d.content.len else 0;
    var p = params_.forLevel(options.level, size, dict_len);
    const t = options.tuning;
    var changed = false;
    if (t.long_distance and t.window_log == null) {
        p.window_log = 27;
        changed = true;
    }
    if (t.window_log) |v| {
        p.window_log = std.math.clamp(v, params_.window_log_min, params_.window_log_max);
        changed = true;
    }
    if (t.hash_log) |v| {
        p.hash_log = std.math.clamp(v, params_.hash_log_min, 30);
        changed = true;
    }
    if (t.chain_log) |v| {
        p.chain_log = std.math.clamp(v, 6, if (@sizeOf(usize) == 4) 29 else 30);
        changed = true;
    }
    if (t.search_log) |v| p.search_log = std.math.clamp(v, 1, params_.window_log_max - 1);
    if (t.min_match) |v| p.min_match = std.math.clamp(v, 3, 7);
    if (t.target_length) |v| p.target_length = v;
    if (t.strategy) |v| {
        p.strategy = v;
        changed = true;
    }
    if (changed) p = params_.adjust(p, size, dict_len);
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
    hash3: usize,
    opt: usize,
    dict_heads: usize = 0,
    dict_chain: usize = 0,
    dict_sequences: usize = 0,
    long_entries: usize = 0,
    long_heads: usize = 0,
    long_matches: usize = 0,

    fn fromParams(p: Params) Layout {
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
            .hash3 = if (p.min_match == 3) @as(usize, 1) << @min(17, p.window_log) else 0,
            .opt = if (@backingInt(p.strategy) >= @backingInt(Strategy.btopt)) @sizeOf(opt_.Workspace) else 0,
        };
    }

    fn of(options: Options) Layout {
        var l = fromParams(resolve(options, if (options.max_input) |n| n else null));
        // Smaller size classes can select another strategy at the same
        // level. Reserve all tables those calls may use, not only the
        // strategy selected for the largest input.
        for ([_]usize{ 0, 16 << 10, 128 << 10, 256 << 10 }) |n| {
            if (options.max_input) |max| if (n > max) continue;
            var small = fromParams(resolve(options, n));
            // Hashing smaller inputs uses at most the largest input's
            // table. Other roles must exist when a size class changes
            // strategy, but do not need a larger hash table.
            small.tags = @min(small.tags, l.hash);
            inline for (.{ "chain", "tags", "seqs", "lits", "hash3", "opt" }) |field| {
                @field(l, field) = @max(@field(l, field), @field(small, field));
            }
        }
        if (options.dictionary) |d| {
            l.dict_heads = @as(usize, 1) << dictionary_match.Index.hashLog(d.content.len);
            l.dict_chain = d.content.len;
            l.dict_sequences = l.seqs;
        }
        if (options.tuning.long_distance) {
            const p = resolve(options, if (options.max_input) |n| n else null);
            l.long_entries = @as(usize, 1) << long_match.State.hashLog(p);
            l.long_heads = l.long_entries >> 4;
            l.long_matches = encode.block_max / 64 + 1;
        }
        return l;
    }

    fn bytes(l: Layout) usize {
        const size = @as(u64, l.hash) * 4 + @as(u64, l.chain) * 4 + l.tags + @as(u64, l.hash3) * 4 + l.opt + @as(u64, l.seqs) * (@sizeOf(encode.Sequence) + 3) + l.lits + 4 * (@as(u64, l.dict_heads) + l.dict_chain) + @sizeOf(encode.Sequence) * @as(u64, l.dict_sequences) + @as(u64, l.long_entries) * @sizeOf(long_match.Entry) + @as(u64, l.long_matches) * @sizeOf(long_match.Match) + l.long_heads;
        if (size > std.math.maxInt(usize) - 63) return std.math.maxInt(usize);
        return std.mem.alignForward(usize, @intCast(size), 64);
    }
};

/// The bytes `initBuffer` needs, or maxInt(usize) when they do not fit the
/// address space. `init` returns OutOfMemory for that configuration.
pub fn memory(options: Options) usize {
    return Layout.of(options).bytes();
}

pub fn init(gpa: Allocator, options: Options) Allocator.Error!Encoder {
    const size = memory(options);
    if (size == std.math.maxInt(usize)) return error.OutOfMemory;
    const buffer = try gpa.alignedAlloc(u8, .@"64", size);
    var c = initBuffer(buffer, options);
    c.owned = buffer;
    c.gpa = gpa;
    return c;
}

/// A compressor in caller memory: `buffer.len >= memory(options)`; `deinit`
/// then frees nothing.
pub fn initBuffer(buffer: []align(64) u8, options: Options) Encoder {
    const p = resolve(options, if (options.max_input) |n| n else null);
    const l = Layout.of(options);
    std.debug.assert(buffer.len >= l.bytes());
    var at: usize = 0;
    const long_matches: []long_match.Match = @alignCast(std.mem.bytesAsSlice(long_match.Match, buffer[at..][0 .. l.long_matches * @sizeOf(long_match.Match)])); // safe: base has 64-byte alignment
    at += l.long_matches * @sizeOf(long_match.Match);
    const long_entries: []long_match.Entry = @alignCast(std.mem.bytesAsSlice(long_match.Entry, buffer[at..][0 .. l.long_entries * @sizeOf(long_match.Entry)])); // safe: preceding table size is divisible by eight
    at += l.long_entries * @sizeOf(long_match.Entry);
    const long_heads = buffer[at..][0..l.long_heads];
    at += l.long_heads;
    // Even the smallest long table has four heads.
    const dictionary_heads: []u32 = @alignCast(std.mem.bytesAsSlice(u32, buffer[at..][0 .. l.dict_heads * 4])); // safe: base has 64-byte alignment
    at += l.dict_heads * 4;
    const dictionary_chain: []u32 = @alignCast(std.mem.bytesAsSlice(u32, buffer[at..][0 .. l.dict_chain * 4])); // safe: preceding table size is divisible by four
    at += l.dict_chain * 4;
    const dictionary_sequences: []encode.Sequence = @alignCast(std.mem.bytesAsSlice(encode.Sequence, buffer[at..][0 .. l.dict_sequences * @sizeOf(encode.Sequence)])); // safe: preceding tables and Sequence have four-byte alignment
    at += l.dict_sequences * @sizeOf(encode.Sequence);
    const hash_table: []u32 = @alignCast(std.mem.bytesAsSlice(u32, buffer[at..][0 .. l.hash * 4])); // safe: 64-byte base and preceding tables have sizes divisible by four
    at += l.hash * 4;
    const chain_table: []u32 = @alignCast(std.mem.bytesAsSlice(u32, buffer[at..][0 .. l.chain * 4])); // safe: 64-byte base and preceding tables have sizes divisible by four
    at += l.chain * 4;
    const tag_table = buffer[at..][0..l.tags];
    at += l.tags;
    const hash3_table: []u32 = @alignCast(std.mem.bytesAsSlice(u32, buffer[at..][0 .. l.hash3 * 4])); // safe: preceding tables have sizes divisible by four
    at += l.hash3 * 4;
    const opt_workspace: ?*opt_.Workspace = if (l.opt != 0) @ptrCast(@alignCast(buffer[at..][0..l.opt])) else null; // safe: preceding tables and Workspace have four-byte alignment
    at += l.opt;
    const seqs: []encode.Sequence = @alignCast(std.mem.bytesAsSlice(encode.Sequence, buffer[at..][0 .. l.seqs * @sizeOf(encode.Sequence)])); // safe: 64-byte base and preceding tables have sizes divisible by four
    at += l.seqs * @sizeOf(encode.Sequence);
    const codes_ = buffer[at..][0 .. 3 * l.seqs];
    at += 3 * l.seqs;
    const lits = buffer[at..][0..l.lits];
    @memset(hash_table, 0);
    @memset(chain_table, 0);
    @memset(tag_table, 0);
    @memset(hash3_table, 0);
    var c: Encoder = .{
        .options = options,
        .capacity = p,
        .hash_table = hash_table,
        .chain_table = chain_table,
        .tag_table = tag_table,
        .lazy = undefined,
        .optimal = undefined,
        .hash3_table = hash3_table,
        .opt_workspace = opt_workspace,
        .store = .{ .seqs = seqs, .lits = lits, .ll_codes = codes_[0..l.seqs], .ml_codes = codes_[l.seqs..][0..l.seqs], .of_codes = codes_[2 * l.seqs ..][0..l.seqs] },
        .entropy = undefined,
        .next_index = first_index,
        .owned = &.{},
        .gpa = undefined,
        .dictionary_index = if (options.dictionary) |d| dictionary_match.Index.init(d.content, dictionary_heads, dictionary_chain) else null,
        .dictionary_sequences = dictionary_sequences,
        .long = if (options.tuning.long_distance) long_match.State.init(long_entries, long_heads, long_matches) else null,
    };
    c.entropy[0].reset();
    c.entropy[1].reset();
    return c;
}

pub fn deinit(c: *Encoder) void {
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
    return len +| (len >> 8) +| small;
}

/// One complete frame of `in` into `out`; returns its length.
pub fn compress(c: *Encoder, in: []const u8, out: []u8, f: Frame) CompressError!usize {
    const p = c.parameters(in.len);
    if (c.next_index + @as(u64, in.len) + encode.block_max >= index_limit) {
        @memset(c.hash_table, 0);
        @memset(c.chain_table, 0);
        @memset(c.tag_table, 0);
        @memset(c.hash3_table, 0);
        c.next_index = first_index;
        if (c.long) |*state| state.reset();
    }
    if (c.long) |*state| state.reset();
    var start = c.next_index;
    c.next_index += @intCast(in.len + 1);
    if (params_.usesRows(p.strategy) or p.strategy == .btlazy2) c.prepareLazy(p, start);
    if (@backingInt(p.strategy) >= @backingInt(Strategy.btopt)) c.prepareOptimal(p, start);
    var o = try c.header(out, p, in.len, f);
    const block_max: usize = @min(encode.block_max, @as(usize, 1) << p.window_log);
    var reps = c.initialReps();
    var prev: usize = 0;
    c.startEntropy();
    var pos: usize = 0;
    var first = true;
    // Bytes saved so far: a block is split only once there are some, so
    // incompressible input is never cut into more blocks.
    var savings: i64 = 0;
    const raw_literals = p.strategy == .fast and p.target_length > 0;
    while (true) {
        const len = blockSize(in[pos..], block_max, p.strategy, savings);
        const last = pos + len == in.len;
        // The first ultra2 pass seeds prices. Advancing the virtual base
        // invalidates its positions without clearing the large tables.
        if (first and p.strategy == .btultra2 and len > 8) {
            c.store.reset();
            var seed_reps = reps;
            _ = c.searchPrefix(p, .{ .in = in, .start = start, .low = start }, &seed_reps, pos, pos + len);
            c.store.reset();
            start += @intCast(len);
            c.next_index += @intCast(len);
            c.optimal.next = start;
            c.optimal.next3 = start;
        }
        const w: window.Window = .{ .in = in, .start = start, .low = 0 };
        var block_w = w;
        block_w.low = w.lowFor(pos + len, p.window_log);
        var next_reps = reps;
        c.store.reset();
        if (len >= 7) {
            const rest = c.search(p, block_w, &next_reps, pos, pos + len);
            c.store.storeLast(in[pos + len - rest .. pos + len]);
        } else c.store.storeLast(in[pos..][0..len]);
        c.mergeDictionary(in, pos, pos + len, pos, p, reps, &next_reps);
        const bytes = try c.writeBlocks(p, in[pos..][0..len], out[o..], raw_literals, &reps, next_reps, &prev, first, last);
        savings += @as(i64, @intCast(len)) - @as(i64, @intCast(bytes));
        o += bytes;
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

pub fn writeBlocks(c: *Encoder, p: Params, in: []const u8, out: []u8, raw_literals: bool, reps: *[3]u32, searched_reps: [3]u32, prev: *usize, first: bool, last: bool) CompressError!usize {
    var plan: post.Plan = .{};
    if (@backingInt(p.strategy) >= @backingInt(Strategy.btopt) and p.window_log >= 17) {
        plan = post.plan(&c.store, &c.entropy[prev.*], &c.entropy[1 - prev.*], p.strategy);
    } else {
        plan.ends[0] = @intCast(c.store.count);
        plan.count = 1;
    }
    if (plan.count == 1) return c.writeBlock(&c.store, p.strategy, in, out, raw_literals, reps, searched_reps, prev, first, last);
    var from: usize = 0;
    var at: usize = 0;
    var o: usize = 0;
    var parse_reps = reps.*;
    for (plan.ends[0..plan.count], 0..) |to, i| {
        var part = c.store.chunk(from, to);
        const len = part.decodedLen();
        var next_reps = reps.*;
        for (part.seqs[0..part.count], 0..) |*q, seq| {
            const zero = part.litLen(seq) == 0;
            const original = q.off;
            if (original <= 3 and sequences.distance(parse_reps, original, zero) != sequences.distance(next_reps, original, zero)) {
                q.off = sequences.distance(parse_reps, original, zero) + 3;
            }
            parse_reps = sequences.updateReps(parse_reps, original, zero);
            next_reps = sequences.updateReps(next_reps, q.off, zero);
        }
        o += try c.writeBlock(&part, p.strategy, in[at..][0..len], out[o..], raw_literals, reps, next_reps, prev, first and i == 0, last and i + 1 == plan.count);
        at += len;
        from = to;
    }
    return o;
}

fn writeBlock(c: *Encoder, store: *encode.SeqStore, strategy: Strategy, in: []const u8, out: []u8, raw_literals: bool, reps: *[3]u32, next_reps: [3]u32, prev: *usize, first: bool, last: bool) CompressError!usize {
    if (out.len < 3) return error.OutputTooSmall;
    var size = if (in.len >= 7) encode.compressBlock(store, in.len, &c.entropy[prev.*], &c.entropy[1 - prev.*], strategy, raw_literals, out[3..]) else 0;
    if (!first and in.len > 0 and size < 25 and allSame(in)) size = 1;
    const end: usize = @intFromBool(last);
    var written: usize = 0;
    if (size == 0) {
        if (out.len - 3 < in.len) return error.OutputTooSmall;
        std.mem.writeInt(u24, out[0..3], @intCast(end | in.len << 3), .little);
        @memcpy(out[3..][0..in.len], in);
        written = 3 + in.len;
    } else if (size == 1) {
        if (out.len < 4) return error.OutputTooSmall;
        std.mem.writeInt(u24, out[0..3], @intCast(end | 1 << 1 | in.len << 3), .little);
        out[3] = in[0];
        written = 4;
    } else {
        std.mem.writeInt(u24, out[0..3], @intCast(end | 2 << 1 | size << 3), .little);
        prev.* = 1 - prev.*;
        written = 3 + size;
        reps.* = next_reps;
    }
    if (c.entropy[prev.*].of_repeat == .valid) c.entropy[prev.*].of_repeat = .check;
    return written;
}

/// The next block's size: a full block, cut where its statistics change
/// once compression has saved a few bytes (the reference's pre-splitter).
pub fn blockSize(rest: []const u8, block_max: usize, strategy: Strategy, savings: i64) usize {
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

/// Reset a frame's entropy and the insertion state for fixed parameters.
pub fn prepare(c: *Encoder, p: Params, start: u32) void {
    c.startEntropy();
    c.entropy[1].reset();
    if (c.long) |*state| state.reset();
    if (params_.usesRows(p.strategy) or p.strategy == .btlazy2) c.prepareLazy(p, start);
    if (@backingInt(p.strategy) >= @backingInt(Strategy.btopt)) c.prepareOptimal(p, start);
}

/// Keep indices bounded while preserving active match history.
pub fn reduceIndices(c: *Encoder, amount: u32) void {
    if (c.long) |*state| state.reduceIndices(amount);
    for (c.hash_table) |*n| n.* -|= amount;
    for (c.chain_table) |*n| n.* -|= amount;
    for (c.hash3_table) |*n| n.* -|= amount;
    c.next_index -|= amount;
    if (params_.usesRows(c.capacity.strategy) or c.capacity.strategy == .btlazy2) c.lazy.next -|= amount;
    if (@backingInt(c.capacity.strategy) >= @backingInt(Strategy.btopt)) {
        c.optimal.next -|= amount;
        c.optimal.next3 -|= amount;
    }
}

fn prepareLazy(c: *Encoder, p: Params, start: u32) void {
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

fn prepareOptimal(c: *Encoder, p: Params, start: u32) void {
    const workspace = c.opt_workspace.?;
    workspace.model.reset();
    const hash3_log: u5 = @min(17, p.window_log);
    c.optimal = .{
        .hash = c.hash_table[0 .. @as(usize, 1) << p.hash_log],
        .tree = c.chain_table[0 .. @as(usize, 1) << p.chain_log],
        .hash3 = if (p.min_match == 3) c.hash3_table[0 .. @as(usize, 1) << hash3_log] else &.{},
        .hash_log = p.hash_log,
        .hash3_log = hash3_log,
        .window_log = p.window_log,
        .search_log = p.search_log,
        .target = p.target_length,
        .next = start,
        .next3 = start,
        .workspace = workspace,
    };
}

/// Run the strategy over one block; returns the trailing literals.
pub fn search(c: *Encoder, p: Params, w: window.Window, reps: *[3]u32, start: usize, end: usize) usize {
    if (c.long) |*state| {
        const matches = state.generate(w, start, end);
        var at = start;
        for (matches) |m| {
            const tail = c.searchPrefix(p, w, reps, at, m.at);
            const off = m.distance + 3;
            c.store.store(w.in, m.at - tail, m.at, end, off, m.len);
            reps.* = sequences.updateReps(reps.*, off, tail == 0);
            at = m.at + m.len;
        }
        return c.searchPrefix(p, w, reps, at, end);
    }
    return c.searchPrefix(p, w, reps, start, end);
}

pub fn searchPrefix(c: *Encoder, p: Params, w: window.Window, reps: *[3]u32, start: usize, end: usize) usize {
    const table = c.hash_table[0 .. @as(usize, 1) << p.hash_log];
    const cmov = p.window_log < 19;
    if (params_.usesRows(p.strategy) or p.strategy == .btlazy2) {
        // After a match running far into this block, insertion resumes
        // near the block's start.
        const curr = w.index(start);
        if (curr > c.lazy.next + 384) c.lazy.next = curr - @min(192, curr - c.lazy.next - 384);
    }
    return switch (p.strategy) {
        .fast => switch (@max(4, @min(p.min_match, 7))) {
            inline 4, 5, 6, 7 => |mls| if (cmov)
                fast.compress(mls, true, table, p.hash_log, w, &c.store, reps, start, end, p.target_length)
            else
                fast.compress(mls, false, table, p.hash_log, w, &c.store, reps, start, end, p.target_length),
            else => unreachable,
        },
        .dfast => switch (@max(4, @min(p.min_match, 7))) {
            inline 4, 5, 6, 7 => |mls| dfast.compress(mls, table, p.hash_log, c.chain_table[0 .. @as(usize, 1) << p.chain_log], p.chain_log, w, &c.store, reps, start, end),
            else => unreachable,
        },
        .btlazy2 => switch (@max(4, @min(p.min_match, 6))) {
            inline 4, 5, 6 => |mls| lazy_.compress(.tree, 2, mls, &c.lazy, w, &c.store, reps, start, end),
            else => unreachable,
        },
        .greedy, .lazy, .lazy2 => switch (@max(4, @min(p.min_match, 6))) {
            inline 4, 5, 6 => |mls| switch (p.strategy) {
                inline .greedy, .lazy, .lazy2 => |s| if (rows(p))
                    lazy_.compress(.row, depthOf(s), mls, &c.lazy, w, &c.store, reps, start, end)
                else
                    lazy_.compress(.chain, depthOf(s), mls, &c.lazy, w, &c.store, reps, start, end),
                else => unreachable,
            },
            else => unreachable,
        },
        .btopt, .btultra, .btultra2 => switch (@max(3, @min(p.min_match, 6))) {
            inline 3, 4, 5, 6 => |mls| if (p.strategy == .btopt)
                opt_.compress(false, mls, &c.optimal, w, &c.store, reps, start, end)
            else
                opt_.compress(true, mls, &c.optimal, w, &c.store, reps, start, end),
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

pub fn writeHeader(out: []u8, p: Params, size: u64, f: Frame) CompressError!usize {
    return writeHeaderWithDictionary(out, p, size, f, 0);
}

pub fn header(c: *const Encoder, out: []u8, p: Params, size: u64, f: Frame) CompressError!usize {
    const id = if (f.dictionary_id) if (c.options.dictionary) |d| d.id else 0 else 0;
    return writeHeaderWithDictionary(out, p, size, f, id);
}

fn writeHeaderWithDictionary(out: []u8, p: Params, size: u64, f: Frame, id: u32) CompressError!usize {
    const window_size = @as(u64, 1) << p.window_log;
    const single = f.content_size and window_size >= size;
    const fcs: u8 = if (f.content_size) @as(u8, @intFromBool(size >= 256)) + @intFromBool(size >= 65536 + 256) + @intFromBool(size >= 0xffff_ffff) else 0;
    const fields = [4]u8{ @intFromBool(single), 2, 4, 8 };
    const dict_bytes: usize = if (id == 0) 0 else if (id < 256) 1 else if (id < 65536) 2 else 4;
    const dict_flag: u8 = if (dict_bytes == 4) 3 else @intCast(dict_bytes);
    const header_len: usize = (if (f.format == .standard) @as(usize, 4) else 0) + 1 + @intFromBool(!single) + fields[fcs] + dict_bytes;
    if (out.len < header_len) return error.OutputTooSmall;
    var o: usize = 0;
    if (f.format == .standard) {
        std.mem.writeInt(u32, out[0..4], frame.magic, .little);
        o = 4;
    }
    out[o] = @as(u8, @intFromBool(f.checksum)) << 2 | @as(u8, @intFromBool(single)) << 5 | fcs << 6 | dict_flag;
    o += 1;
    if (!single) {
        out[o] = (@as(u8, p.window_log) - params_.window_log_min) << 3;
        o += 1;
    }
    switch (dict_bytes) {
        1 => out[o] = @intCast(id),
        2 => std.mem.writeInt(u16, out[o..][0..2], @intCast(id), .little),
        4 => std.mem.writeInt(u32, out[o..][0..4], id, .little),
        else => {},
    }
    o += dict_bytes;
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

/// Repeat offsets before the first compressed block.
pub fn initialReps(c: *const Encoder) [3]u32 {
    if (c.options.dictionary) |d| if (d.formatted) return d.entropy.reps;
    return .{ 1, 4, 8 };
}

fn startEntropy(c: *Encoder) void {
    if (c.options.dictionary) |d| if (d.formatted) {
        c.entropy[0] = d.encoding;
        return;
    };
    c.entropy[0].reset();
}

/// Dictionary candidates use the same block sequence and entropy engine.
pub fn mergeDictionary(c: *Encoder, in: []const u8, start: usize, end: usize, frame_pos: u64, p: Params, before: [3]u32, after: *[3]u32) void {
    if (c.dictionary_index) |*index| {
        after.* = before;
        dictionary_match.merge(index, &c.store, c.dictionary_sequences, in, start, end, frame_pos, p.window_log, p.search_log, after);
    }
}

/// A training sample's sequences, using the same search and dictionary
/// candidate paths as compression; samples fit one block.
pub fn analyze(c: *Encoder, in: []const u8) void {
    const p = c.parameters(in.len);
    if (c.next_index + @as(u64, in.len) >= index_limit) {
        @memset(c.hash_table, 0);
        @memset(c.chain_table, 0);
        @memset(c.tag_table, 0);
        @memset(c.hash3_table, 0);
        c.next_index = first_index;
    }
    const base = c.next_index;
    c.next_index += @intCast(in.len + 1);
    c.prepare(p, base);
    c.store.reset();
    var reps = c.initialReps();
    if (in.len >= 7) {
        const tail = c.search(p, .{ .in = in, .start = base, .low = base }, &reps, 0, in.len);
        c.store.storeLast(in[in.len - tail ..]);
    } else c.store.storeLast(in);
    c.mergeDictionary(in, 0, in.len, 0, p, c.initialReps(), &reps);
}

fn parameters(c: *const Encoder, size: usize) Params {
    var p = resolve(c.options, size);
    p.window_log = @min(p.window_log, c.capacity.window_log);
    p.hash_log = @min(p.hash_log, std.math.log2_int(usize, c.hash_table.len));
    if (c.chain_table.len != 0) p.chain_log = @min(p.chain_log, std.math.log2_int(usize, c.chain_table.len));
    return p;
}
