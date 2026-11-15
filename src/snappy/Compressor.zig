//! Block and stream compression with one parser: google's levels 1 and 2,
//! or S2's fast, better and best. The compressor owns the parser's tables,
//! taken once; a call clears only what the input's size uses, and
//! allocates nothing. Streams are S2's writer's, byte for byte.

const Compressor = @This();

const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const block = @import("block.zig");
const emit = @import("emit.zig");
const reference = @import("reference.zig");
const fast = @import("fast.zig");
const better = @import("better.zig");
const best = @import("best.zig");
const Dict = @import("Dict.zig");
const frame = @import("frame.zig");
const Index = @import("Index.zig");

/// The parsers: google/snappy 1.3.1's levels, and klauspost/compress s2
/// v1.20.3's modes.
pub const Level = enum {
    /// google's level 1: one table, skipping ahead through input that
    /// does not match. Writes Snappy (so S2 too).
    snappy_1,
    /// google's level 2: two tables, denser, decodes faster. Writes
    /// Snappy.
    snappy_2,
    /// S2's default (`Encode`, or `EncodeSnappy` for the Snappy format):
    /// faster and denser than google's level 1.
    fast,
    /// S2's better (`EncodeBetter`, `EncodeSnappyBetter`): two tables,
    /// denser again, about half as fast.
    better,
    /// S2's best (`EncodeBest`, `EncodeSnappyBest`): every candidate
    /// scored by what it saves; the densest, and slowest.
    best,

    /// The default level for a format: google's level 1 for Snappy,
    /// S2's default for S2.
    pub fn default(format: block.Format) Level {
        return switch (format) {
            .snappy => .snappy_1,
            .s2 => .fast,
        };
    }
};

pub const Options = struct {
    /// The elements written: Snappy's, or S2's.
    format: block.Format = .snappy,
    /// The parser; null for the format's default.
    level: ?Level = null,
    /// An S2 dictionary every block may copy from (S2's parsers and
    /// format), indexed once at `init`; its content must outlive the
    /// compressor.
    dictionary: ?Dict = null,

    pub fn parser(o: Options) Level {
        return o.level orelse Level.default(o.format);
    }

    /// A dictionary is S2's: it needs the S2 format and an S2 parser.
    pub fn valid(o: Options) bool {
        if (o.dictionary == null) return true;
        return o.format == .s2 and switch (o.parser()) {
            .snappy_1, .snappy_2 => false,
            .fast, .better, .best => true,
        };
    }
};

pub const InitError = Allocator.Error || error{
    /// A dictionary with the Snappy format or one of google's parsers.
    InvalidOptions,
};

pub const Error = error{
    /// The output is shorter than `bound` of the input.
    OutputTooSmall,
    /// An input longer than a block's length holds (2^32 - 1).
    InputTooLarge,
};

options: Options,
/// The parser's tables: those of `options.parser()` hold its counts, the
/// others none.
work: Work,
/// A dictionary's tables for the parser, as `work`; none without one.
dict: DictTables,
/// The block `init` took, which `deinit` frees; null over parts or a buffer.
held: ?struct { gpa: Allocator, block: Block },

fn Pair(comptime T: type) type {
    return struct { long: []T, short: []T };
}

/// The parsers' tables, one parser's in use: they lie over one another.
const Work = struct {
    pub const arrangement: aegis.parts.Arrangement = .overlap;
    reference: []u16,
    fast: []u32,
    better: Pair(u32),
    best: Pair(u64),
};

/// A dictionary's tables for each parser, one parser's in use.
const DictTables = struct {
    pub const arrangement: aegis.parts.Arrangement = .overlap;
    fast: []u16,
    better: Pair(u16),
    best: Pair(u32),
};

/// The bytes of tables the parser takes, and its dictionary's.
pub fn memory(options: Options) usize {
    return (Block.plan(counts(options)).size() catch return std.math.maxInt(usize)).raw();
}

pub fn init(gpa: Allocator, options: Options) InitError!Compressor {
    if (!options.valid()) return error.InvalidOptions;
    const b = try Block.plan(counts(options)).alloc(gpa);
    var c = fromParts(b.parts(), options);
    c.held = .{ .gpa = gpa, .block = b };
    return c;
}

/// The dictionary's tables, made once.
fn indexDictionary(c: *Compressor) void {
    const dict = c.options.dictionary orelse return;
    switch (c.options.parser()) {
        .snappy_1, .snappy_2 => {},
        .best => best.indexDict(dict.content, c.dict.best.long, c.dict.best.short),
        .fast => fast.indexDict(dict.content, c.dict.fast),
        .better => better.indexDict(dict.content, c.dict.better.long, c.dict.better.short),
    }
}

/// A compressor over the caller's `buffer` (aligned to `Block.alignment`), refused when
/// shorter than `memory(options)`.
pub fn initBuffer(buffer: []align(Block.alignment) u8, options: Options) error{ InvalidOptions, BufferTooSmall }!Compressor {
    if (!options.valid()) return error.InvalidOptions;
    return fromParts((try Block.plan(counts(options)).fit(buffer)).parts(), options);
}

/// The parser's and its dictionary's tables, as a part of one block
/// (`aegis.parts`), which the streaming compressor nests in its own.
pub const Parts = struct { work: Work, dict: DictTables };
const Block = aegis.parts.Block(Parts);

/// The parts for valid `options`: the parser's tables, and its
/// dictionary's when it has one.
pub fn counts(options: Options) aegis.parts.Counts(Parts) {
    const parser = options.parser();
    const dict = options.dictionary != null;
    const reference_table: usize = switch (parser) {
        .snappy_1, .snappy_2 => reference.max_table,
        else => 0,
    };
    return .{
        .work = .{
            .reference = reference_table,
            .fast = if (parser == .fast) fast.max_table else 0,
            .better = if (parser == .better) .{ .long = better.max_long, .short = better.max_short } else .{ .long = 0, .short = 0 },
            .best = if (parser == .best) .{ .long = best.max_long, .short = best.max_short } else .{ .long = 0, .short = 0 },
        },
        .dict = .{
            .fast = if (dict and parser == .fast) fast.dict_table else 0,
            .better = if (dict and parser == .better) .{ .long = better.dict_long, .short = better.dict_short } else .{ .long = 0, .short = 0 },
            .best = if (dict and parser == .best) .{ .long = best.max_long, .short = best.max_short } else .{ .long = 0, .short = 0 },
        },
    };
}

/// A compressor over its parts, placed for `counts(options)` of valid
/// `options`; `deinit` frees nothing.
pub fn fromParts(p: Parts, options: Options) Compressor {
    var c: Compressor = .{ .options = options, .work = p.work, .dict = p.dict, .held = null };
    c.indexDictionary();
    return c;
}

pub fn deinit(c: *Compressor) void {
    if (c.held) |h| h.gpa.free(h.block.bytes());
    c.* = undefined;
}

/// The longest block `len` bytes compress to, for any parser and format:
/// google's `MaxCompressedLength`.
pub fn bound(len: usize) usize {
    return 32 + len + len / 6;
}

/// Compress `in` into one block in `out` (at least `bound(in.len)`
/// bytes); its length.
pub fn compressBlock(c: *Compressor, in: []const u8, out: []u8) Error!usize {
    if (in.len > block.max_len) return error.InputTooLarge;
    if (out.len < bound(in.len)) return error.OutputTooSmall;
    const at = emit.length(out, 0, @intCast(in.len));
    if (in.len == 0) return at;
    // S2's parsers give up on input they cannot shrink enough, and the
    // block is then one literal.
    return c.parse(in, out, at) orelse emit.literal(out, at, in, 0, in.len);
}

/// The block's elements after its length at `out[at..]`: where they end,
/// or null where an S2 parser gives up (input shorter than it parses, or
/// that it cannot shrink by its margin).
fn parse(c: *Compressor, in: []const u8, out: []u8, at: usize) ?usize {
    const snappy = c.options.format == .snappy;
    return switch (c.options.parser()) {
        .snappy_1 => reference.compress(.one, in, out, at, c.work.reference),
        .snappy_2 => reference.compress(.two, in, out, at, c.work.reference),
        .fast => if (in.len < fast.min_len)
            null
        else if (c.options.dictionary) |dict|
            fast.encodeDict(dict.content, dict.repeat, c.dict.fast, in, out, at, c.work.fast)
        else if (snappy)
            fast.encode(true, in, out, at, c.work.fast)
        else
            fast.encode(false, in, out, at, c.work.fast),
        .better => blk: {
            if (in.len < fast.min_len) break :blk null;
            const long = c.work.better.long;
            const short = c.work.better.short;
            if (c.options.dictionary) |dict| {
                break :blk better.encodeDict(dict.content, dict.repeat, c.dict.better.long, c.dict.better.short, in, out, at, long, short);
            }
            break :blk if (snappy) better.encode(true, in, out, at, long, short) else better.encode(false, in, out, at, long, short);
        },
        .best => blk: {
            if (in.len < fast.min_len) break :blk null;
            const long = c.work.best.long;
            const short = c.work.best.short;
            if (c.options.dictionary) |dict| {
                break :blk best.encode(.dict, in, out, at, long, short, .{ .content = dict.content, .repeat = dict.repeat, .long = c.dict.best.long, .short = c.dict.best.short });
            }
            break :blk if (snappy) best.encode(.snappy, in, out, at, long, short, null) else best.encode(.s2, in, out, at, long, short, null);
        },
    };
}

/// A stream's settings, S2's writer's.
pub const Stream = struct {
    /// The output each block holds (4 KiB to 4 MiB; 64 KiB at most in a
    /// Snappy stream). Null for S2's writer's: 1 MiB in an S2 stream, 64
    /// KiB less 8 in a Snappy one.
    block_size: ?aegis.units.Bytes(usize) = null,
    /// Pad the stream with a chunk of zeros to a multiple of this many
    /// bytes, at most 4 MiB, as S2's `WriterPadding` (whose padding is
    /// random); 0 and 1 pad nothing. An index records no compressed total
    /// then.
    padding: aegis.units.Bytes(usize) = .fromRaw(0),
    /// S2's seek index: none, appended to the stream (after the padding),
    /// or apart, written after it in the output.
    index: IndexPlace = .none,
    /// Every block stored uncompressed, as S2's `WriterUncompressed`.
    store: bool = false,
};

pub const IndexPlace = enum { none, append, apart };

pub const StreamResult = struct {
    /// The stream's length, its appended index included.
    len: usize,
    /// The index kept apart, at `out[len..][0..index_len]`.
    index_len: usize = 0,
};

pub const StreamError = error{
    /// A block size or padding out of range, or a dictionary: streams
    /// have none.
    InvalidOptions,
    /// The output is shorter than `streamBound`.
    OutputTooSmall,
};

/// The output each block of a stream holds.
pub fn blockSize(options: Options, stream: Stream) usize {
    if (stream.block_size) |b| return b.raw();
    return switch (options.format) {
        .s2 => 1 << 20,
        .snappy => frame.max_snappy_block_size - 8,
    };
}

pub fn validStream(options: Options, stream: Stream) bool {
    const b = blockSize(options, stream);
    return options.dictionary == null and b >= frame.min_block_size and b <= frame.maxBlock(options.format) and stream.padding.compare(.fromRaw(frame.max_block_size)) != .gt;
}

/// The longest stream of `len` bytes, with its index apart; maxInt(usize)
/// for a stream `validStream` refuses (`compress` refuses it as
/// `InvalidOptions`) or one past the address space.
pub fn streamBound(options: Options, len: usize, stream: Stream) usize {
    if (!validStream(options, stream)) return std.math.maxInt(usize);
    const b = blockSize(options, stream);
    const blocks = std.math.divCeil(usize, len, b) catch unreachable; // glint-ignore: Z026 -- a valid stream's block is at least 4 KiB
    const index = if (stream.index == .none) 0 else Index.bound(blocks + 1);
    const chunks = std.math.mul(usize, blocks, chunkBound(b)) catch return std.math.maxInt(usize);
    const ends = (stream.padding.add(.fromRaw(frame.identifier_len + frame.header_len + index)) catch return std.math.maxInt(usize)).raw();
    return std.math.add(usize, chunks, ends) catch std.math.maxInt(usize);
}

/// The longest chunk of a block of `len` bytes.
pub fn chunkBound(len: usize) usize {
    return frame.header_len + frame.checksum_len + bound(len);
}

/// Write `in` as a stream into `out` (at least `streamBound` bytes), cut
/// into blocks of the stream's block size from its start, as S2's writer
/// writes input given whole. Empty input is an empty stream (and its
/// index), as S2's.
pub fn compress(c: *Compressor, in: []const u8, out: []u8, stream: Stream) StreamError!StreamResult {
    if (!validStream(c.options, stream)) return error.InvalidOptions;
    if (out.len < streamBound(c.options, in.len, stream)) return error.OutputTooSmall;
    const b = blockSize(c.options, stream);
    var op: usize = 0;
    if (in.len > 0) {
        @memcpy(out[0..frame.identifier_len], frame.identifier(c.options.format));
        op = frame.identifier_len;
    }
    var ip: usize = 0;
    while (ip < in.len) : (ip += b) op += c.chunk(in[ip..][0..@min(b, in.len - ip)], out[op..], stream.store);
    return finish(out, op, in.len, b, stream);
}

/// The stream's end after its chunks (`out[0..len]`, `total` bytes of
/// input): the index and padding as S2's writer's `Close` writes them.
pub fn finish(out: []u8, len: usize, total: u64, block_size: usize, stream: Stream) StreamResult {
    const padded = stream.padding.compare(.fromRaw(1)) == .gt;
    var index_len: usize = 0;
    if (stream.index != .none) {
        var chunks: Index.Chunks = .{ .stream = out[0..len] };
        var count: u64 = 0;
        while (chunks.next()) |_| count += 1;
        index_len = Index.write(out[len..], &chunks, count, block_size, if (padded) null else len, total);
    }
    var op = len;
    if (padded) {
        const counted = len + if (stream.index == .append) index_len else 0;
        const pad: usize = @intCast(frame.paddingLen(counted, stream.padding.raw()));
        if (pad > 0) {
            @memmove(out[len + pad ..][0..index_len], out[len..][0..index_len]);
            frame.writeHeader(out[len..][0..frame.header_len], frame.Type.padding, pad - frame.header_len);
            @memset(out[len + frame.header_len ..][0 .. pad - frame.header_len], 0);
            op += pad;
        }
    }
    return switch (stream.index) {
        .append => .{ .len = op + index_len },
        .none, .apart => .{ .len = op, .index_len = index_len },
    };
}

/// One block's chunk at the start of `out` (`chunkBound(in.len)` bytes):
/// compressed, or stored where storing is asked for, where an S2 parser
/// gives up, or where google's parse saves less than an eighth (as
/// golang/snappy and snap decide); its length.
pub fn chunk(c: *Compressor, in: []const u8, out: []u8, store: bool) usize {
    aegis.assert.invariant(in.len > 0, "in.len > 0");
    aegis.assert.invariant(in.len <= frame.max_block_size, "in.len <= frame.max_block_size");
    const head = frame.header_len + frame.checksum_len;
    std.mem.writeInt(u32, out[frame.header_len..][0..4], frame.checksum(in), .little);
    const body = if (store) null else body: {
        const at = emit.length(out[head..], 0, @intCast(in.len));
        const end = c.parse(in, out[head..], at) orelse break :body null;
        break :body switch (c.options.parser()) {
            .snappy_1, .snappy_2 => if (end >= in.len - in.len / 8) null else end,
            .fast, .better, .best => end,
        };
    };
    if (body) |n| {
        frame.writeHeader(out[0..frame.header_len], frame.Type.compressed, frame.checksum_len + n);
        return head + n;
    }
    frame.writeHeader(out[0..frame.header_len], frame.Type.uncompressed, frame.checksum_len + in.len);
    @memcpy(out[head..][0..in.len], in);
    return head + in.len;
}
