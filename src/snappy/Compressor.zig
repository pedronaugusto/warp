//! Block compression with one parser: google's levels 1 and 2, or S2's
//! fast, better and best. The compressor owns the parser's tables, taken
//! once; a call clears only what the input's size uses, and allocates
//! nothing.

const Compressor = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const block = @import("block.zig");
const emit = @import("emit.zig");
const reference = @import("reference.zig");
const fast = @import("fast.zig");
const better = @import("better.zig");
const best = @import("best.zig");
const Dict = @import("Dict.zig");

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
/// The parser's tables.
memory_: []align(16) u8,
gpa: ?Allocator,

/// The bytes of the parser's tables.
fn workMemory(options: Options) usize {
    return switch (options.parser()) {
        .snappy_1, .snappy_2 => reference.max_table * @sizeOf(u16),
        .fast => fast.max_table * @sizeOf(u32),
        .better => (better.max_long + better.max_short) * @sizeOf(u32),
        .best => (best.max_long + best.max_short) * @sizeOf(u64),
    };
}

/// The bytes of a dictionary's tables for the parser.
fn dictMemory(options: Options) usize {
    if (options.dictionary == null) return 0;
    return switch (options.parser()) {
        .snappy_1, .snappy_2 => 0,
        .fast => fast.dict_table * @sizeOf(u16),
        .better => (better.dict_long + better.dict_short) * @sizeOf(u16),
        .best => (best.max_long + best.max_short) * @sizeOf(u32),
    };
}

/// The bytes of tables the parser takes, and its dictionary's.
pub fn memory(options: Options) usize {
    return workMemory(options) + dictMemory(options);
}

pub fn init(gpa: Allocator, options: Options) InitError!Compressor {
    if (!options.valid()) return error.InvalidOptions;
    const mem = try gpa.alignedAlloc(u8, .@"16", memory(options));
    var c: Compressor = .{ .options = options, .memory_ = mem, .gpa = gpa };
    c.indexDictionary();
    return c;
}

/// The dictionary's tables, made once.
fn indexDictionary(c: *Compressor) void {
    const dict = c.options.dictionary orelse return;
    switch (c.options.parser()) {
        .snappy_1, .snappy_2 => {},
        .best => {
            const t = c.dictTables(u32);
            best.indexDict(dict.content, t[0..best.max_long], t[best.max_long..][0..best.max_short]);
        },
        .fast => fast.indexDict(dict.content, c.dictTables(u16)),
        .better => {
            const t = c.dictTables(u16);
            better.indexDict(dict.content, t[0..better.dict_long], t[better.dict_long..][0..better.dict_short]);
        },
    }
}

fn dictTables(c: *Compressor, comptime T: type) []T {
    return std.mem.bytesAsSlice(T, c.memory_)[workMemory(c.options) / @sizeOf(T) ..];
}

/// A compressor over the caller's `buffer` (at least `memory(options)`
/// bytes, aligned to 16).
pub fn initBuffer(buffer: []align(16) u8, options: Options) error{InvalidOptions}!Compressor {
    if (!options.valid()) return error.InvalidOptions;
    std.debug.assert(buffer.len >= memory(options));
    var c: Compressor = .{ .options = options, .memory_ = buffer[0..memory(options)], .gpa = null };
    c.indexDictionary();
    return c;
}

pub fn deinit(c: *Compressor) void {
    if (c.gpa) |gpa| gpa.free(c.memory_);
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
    const snappy = c.options.format == .snappy;
    return switch (c.options.parser()) {
        .snappy_1 => reference.compress(.one, in, out, at, c.tables(u16)),
        .snappy_2 => reference.compress(.two, in, out, at, c.tables(u16)),
        // S2's parsers give up on input they cannot shrink enough, and
        // the block is then one literal.
        .fast => (if (in.len < fast.min_len)
            null
        else if (c.options.dictionary) |dict|
            fast.encodeDict(dict.content, dict.repeat, c.dictTables(u16), in, out, at, c.tables(u32))
        else if (snappy)
            fast.encode(true, in, out, at, c.tables(u32))
        else
            fast.encode(false, in, out, at, c.tables(u32))) orelse emit.literal(out, at, in, 0, in.len),
        .better => blk: {
            const t = c.tables(u32);
            const long = t[0..better.max_long];
            const short = t[better.max_long..][0..better.max_short];
            break :blk (if (in.len < fast.min_len)
                null
            else if (c.options.dictionary) |dict| dict: {
                const d = c.dictTables(u16);
                break :dict better.encodeDict(dict.content, dict.repeat, d[0..better.dict_long], d[better.dict_long..][0..better.dict_short], in, out, at, long, short);
            } else if (snappy)
                better.encode(true, in, out, at, long, short)
            else
                better.encode(false, in, out, at, long, short)) orelse emit.literal(out, at, in, 0, in.len);
        },
        .best => blk: {
            const t = c.tables(u64);
            const long = t[0..best.max_long];
            const short = t[best.max_long..][0..best.max_short];
            break :blk (if (in.len < fast.min_len)
                null
            else if (c.options.dictionary) |dict| dict: {
                const d = c.dictTables(u32);
                break :dict best.encode(.dict, in, out, at, long, short, .{ .content = dict.content, .repeat = dict.repeat, .long = d[0..best.max_long], .short = d[best.max_long..][0..best.max_short] });
            } else if (snappy)
                best.encode(.snappy, in, out, at, long, short, null)
            else
                best.encode(.s2, in, out, at, long, short, null)) orelse emit.literal(out, at, in, 0, in.len);
        },
    };
}

fn tables(c: *Compressor, comptime T: type) []T {
    return std.mem.bytesAsSlice(T, c.memory_[0..workMemory(c.options)]);
}
