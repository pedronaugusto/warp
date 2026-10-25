//! LZ4 compression: blocks and frames, with the match state of a level
//! band held in memory taken once. A call clears nothing and allocates
//! nothing; a dictionary given at `init` is indexed once.
const Compressor = @This();

const std = @import("std");
const seq = @import("sequence.zig");
const fast = @import("fast.zig");
const hc = @import("hc.zig");
const frame = @import("frame.zig");

/// Private: the fast parser's table.
table: *fast.Table,
/// Private: the chains, LZ4MID's tables and the optimal parser's costs,
/// when `max_level` reaches them.
chains: ?*hc.Chains,
/// Private: the bound dictionary's tables, when there is one.
dictionary: ?Bound,
level: i32,
/// Private: the highest level the state reaches.
top_level: i32,
favor_decompression_speed: bool,
/// Private: the last block's input, for `history = .previous`.
previous: []const u8 = &.{},
/// Private: what `init` allocated, freed by `deinit`; null in caller memory.
gpa: ?std.mem.Allocator,
storage: []align(64) u8,

const Bound = struct {
    bytes: []const u8,
    table: *fast.Table,
    chains: ?*hc.Chains,
};

/// The fastest level: acceleration 65537.
pub const min_level = -65536;
/// The highest level; higher ones mean this.
pub const max_level = 12;
pub const default_level = 1;

pub const Options = struct {
    /// -65536 to 12 on lz4frame's scale: 1 and below the fast parser
    /// (acceleration 1 - level below 0), 2 LZ4MID, 3-9 hash chains, 10-12
    /// optimal parsing; above 12 means 12.
    level: i32 = default_level,
    /// The highest level `setLevel` may choose: it sizes the state. null:
    /// `level`.
    max_level: ?i32 = null,
    /// Bytes every block may refer back into (`History.dictionary`) and
    /// that frames name; the last 64 KiB count. Borrowed, indexed once at
    /// `init`; it must outlive the compressor.
    dictionary: ?[]const u8 = null,
    /// At levels 10-12, prefer matches that decode faster over the
    /// smallest output (lz4's `favorDecSpeed`).
    favor_decompression_speed: bool = false,
};

/// What a block may refer back into.
pub const History = union(enum) {
    /// Nothing: the block alone.
    none,
    /// The dictionary given at `init`.
    dictionary,
    /// The last block this compressor wrote, by any call, whose input is
    /// still in place and unchanged (lz4's `_continue`): a run of linked
    /// blocks starts with `.none` or `.dictionary` and goes on with this.
    previous,
    /// These bytes, which precede the block; the last 64 KiB count.
    bytes: []const u8,
};

pub const BlockOptions = struct {
    history: History = .none,
};

pub const Error = error{
    /// The output cannot hold the block.
    OutputTooSmall,
};

/// What `compressBlockDestSize` took and wrote.
pub const Filled = seq.Written;

fn band(level: i32) enum { fast, mid, chains, optimal } {
    return if (level < 2) .fast else if (level == 2) .mid else if (level < 10) .chains else .optimal;
}

/// The bytes `initBuffer` needs for `options`.
pub fn memory(options: Options) usize {
    const top = @max(options.level, options.max_level orelse options.level);
    var total: usize = std.mem.alignForward(usize, @sizeOf(fast.Table), 64);
    if (band(top) != .fast) total += std.mem.alignForward(usize, hc.Chains.memory(top >= 10), 64);
    if (options.dictionary != null) {
        total += std.mem.alignForward(usize, @sizeOf(fast.Table), 64);
        if (band(top) != .fast) total += std.mem.alignForward(usize, hc.Chains.memory(false), 64);
    }
    return total;
}

pub fn init(gpa: std.mem.Allocator, options: Options) std.mem.Allocator.Error!Compressor {
    const buffer = try gpa.alignedAlloc(u8, .@"64", memory(options));
    var c = initBuffer(buffer, options);
    c.gpa = gpa;
    return c;
}

/// A compressor in caller memory: `buffer.len >= memory(options)`.
pub fn initBuffer(buffer: []align(64) u8, options: Options) Compressor {
    std.debug.assert(buffer.len >= memory(options));
    const top = @max(options.level, options.max_level orelse options.level);
    var at: usize = 0;
    const table = take(fast.Table, buffer, &at);
    table.* = .empty;
    var chains: ?*hc.Chains = null;
    if (band(top) != .fast) chains = hc.Chains.initBuffer(takeBytes(buffer, &at, hc.Chains.memory(top >= 10)), top >= 10);
    var attached: ?Bound = null;
    if (options.dictionary) |bytes| {
        const dict_table = take(fast.Table, buffer, &at);
        const indexed = fast.load(dict_table, bytes);
        var dict_chains: ?*hc.Chains = null;
        if (band(top) != .fast) {
            dict_chains = hc.Chains.initBuffer(takeBytes(buffer, &at, hc.Chains.memory(false)), false);
            dict_chains.?.load(indexed, band(options.level) == .mid);
        }
        attached = .{ .bytes = indexed, .table = dict_table, .chains = dict_chains };
    }
    return .{
        .table = table,
        .chains = chains,
        .dictionary = attached,
        .level = @min(options.level, max_level),
        .top_level = @min(top, max_level),
        .favor_decompression_speed = options.favor_decompression_speed,
        .gpa = null,
        .storage = buffer,
    };
}

fn take(comptime T: type, buffer: []align(64) u8, at: *usize) *T {
    const bytes = takeBytes(buffer, at, @sizeOf(T));
    return @ptrCast(@alignCast(bytes.ptr)); // aegis: no-danger: 64-aligned bytes of T's size, which no T exceeds in alignment
}

fn takeBytes(buffer: []align(64) u8, at: *usize, len: usize) []align(64) u8 {
    const bytes: []align(64) u8 = @alignCast(buffer[at.*..][0..len]); // aegis: no-danger: every piece starts at a multiple of 64
    at.* += std.mem.alignForward(usize, len, 64);
    return bytes;
}

pub fn deinit(c: *Compressor) void {
    if (c.gpa) |gpa| gpa.free(c.storage);
    c.* = undefined;
}

/// Change the level for the next call; at most `Options.max_level`'s band.
pub fn setLevel(c: *Compressor, level: i32) void {
    const l = @min(level, max_level);
    std.debug.assert(band(l) == .fast or c.chains != null);
    std.debug.assert(band(l) != .optimal or c.top_level >= 10);
    c.level = l;
}

/// The longest block `len` bytes compress to.
pub const blockBound = seq.bound;

/// The largest a frame's blocks decode to.
pub const BlockSize = frame.BlockSize;

/// A frame's kind.
pub const Format = enum {
    /// The LZ4 frame format.
    standard,
    /// The legacy format `lz4 -l` and the Linux kernel write: 8 MiB blocks,
    /// always compressed, no checksums, sizes or dictionary; levels below 3
    /// use the fast parser, as `lz4 -l` does.
    legacy,
};

/// What surrounds the compressed blocks. The defaults are the `lz4`
/// command's: 4 MiB independent blocks and a content checksum.
pub const Frame = struct {
    format: Format = .standard,
    block_size: BlockSize = .@"4MiB",
    /// Each block alone; otherwise each refers back into the one before
    /// (smaller, but decoded in order only).
    independent: bool = true,
    block_checksum: bool = false,
    content_checksum: bool = true,
    /// The content's length in the descriptor.
    content_size: bool = true,
    /// Written to the descriptor. The frame refers into the compressor's
    /// dictionary when it has one, named or not.
    dictionary_id: ?u32 = null,
};

/// The longest frame `compress` writes for `len` bytes: an `out` this long
/// never fails.
pub fn bound(len: usize, f: Frame) usize {
    switch (f.format) {
        .legacy => {
            // unreachable: the divisor is a constant, not zero
            const blocks = std.math.divCeil(usize, len, frame.legacy_block_len) catch unreachable;
            return 4 + blocks * (4 + seq.bound(frame.legacy_block_len));
        },
        .standard => {
            const block_len = f.block_size.bytes();
            // unreachable: a block size is at least 64 KiB
            const blocks = std.math.divCeil(usize, len, block_len) catch unreachable;
            const per_block: usize = 4 + @as(usize, if (f.block_checksum) 4 else 0);
            // A block that does not compress is stored: its own length.
            return frame.max_header_len + len + blocks * per_block + 4 + 4;
        },
    }
}

/// One complete frame of `in` into `out`; returns its length.
pub fn compress(c: *Compressor, in: []const u8, out: []u8, f: Frame) Error!usize {
    return switch (f.format) {
        .standard => c.standardFrame(in, out, f),
        .legacy => c.legacyFrame(in, out),
    };
}

fn standardFrame(c: *Compressor, in: []const u8, out: []u8, f: Frame) Error!usize {
    const header: frame.Header = .{
        .block_size = f.block_size,
        .independent = f.independent,
        .block_checksum = f.block_checksum,
        .content_checksum = f.content_checksum,
        .content_size = if (f.content_size) in.len else null,
        .dictionary_id = f.dictionary_id,
    };
    if (out.len < header.len()) return error.OutputTooSmall;
    var at = header.write(out);
    const block_len = f.block_size.bytes();
    var pos: usize = 0;
    while (pos < in.len) {
        const src = in[pos..][0..@min(block_len, in.len - pos)];
        at += try c.frameBlock(src, out[at..], f, pos == 0);
        pos += src.len;
    }
    const footer: usize = 4 + @as(usize, if (f.content_checksum) 4 else 0);
    if (out.len - at < footer) return error.OutputTooSmall;
    std.mem.writeInt(u32, out[at..][0..4], 0, .little);
    at += 4;
    if (f.content_checksum) {
        std.mem.writeInt(u32, out[at..][0..4], std.hash.XxHash32.hash(0, in), .little);
        at += 4;
    }
    return at;
}

/// One block of a frame with its header and checksum: compressed if that
/// saves a byte, as lz4frame decides, else stored. `first` starts the
/// frame's history. Returns the bytes written.
pub fn frameBlock(c: *Compressor, src: []const u8, out: []u8, f: Frame, first: bool) Error!usize {
    // Linked blocks keep one match state through the frame, from an empty
    // history (lz4frame's `_continue` from a reset stream).
    const history: History = if (c.dictionary != null and (f.independent or first))
        .dictionary
    else if (f.independent) .none else if (first) .{ .bytes = &.{} } else .previous;
    const tail: usize = if (f.block_checksum) 4 else 0;
    if (out.len < 4 + tail) return error.OutputTooSmall;
    const room = out.len - 4 - tail;
    const n: usize = blk: {
        if (src.len < 2) break :blk 0;
        const w = c.run(.limited, src, out[4..][0..@min(room, src.len - 1)], history) orelse break :blk 0;
        break :blk w.out_len;
    };
    if (n == 0) {
        if (room < src.len) return error.OutputTooSmall;
        std.mem.writeInt(u32, out[0..4], @as(u32, @intCast(src.len)) | frame.uncompressed_flag, .little);
        @memcpy(out[4..][0..src.len], src);
    } else std.mem.writeInt(u32, out[0..4], @intCast(n), .little);
    const stored = if (n == 0) src.len else n;
    if (f.block_checksum) std.mem.writeInt(u32, out[4 + stored ..][0..4], std.hash.XxHash32.hash(0, out[4..][0..stored]), .little);
    return 4 + stored + tail;
}

fn legacyFrame(c: *Compressor, in: []const u8, out: []u8) Error!usize {
    if (out.len < 4) return error.OutputTooSmall;
    std.mem.writeInt(u32, out[0..4], frame.legacy_magic, .little);
    var at: usize = 4;
    const level = c.level;
    defer c.level = level;
    if (level < 3) c.level = @min(level, 1);
    var pos: usize = 0;
    while (pos < in.len) {
        const src = in[pos..][0..@min(frame.legacy_block_len, in.len - pos)];
        if (out.len - at < 4) return error.OutputTooSmall;
        const n = try c.compressBlock(src, out[at + 4 ..], .{});
        std.mem.writeInt(u32, out[at..][0..4], @intCast(n), .little);
        at += 4 + n;
        pos += src.len;
    }
    return at;
}

/// One block of `in` into `out`; returns its length. An `out` of
/// `blockBound(in.len)` never fails.
pub fn compressBlock(c: *Compressor, in: []const u8, out: []u8, options: BlockOptions) Error!usize {
    if (out.len >= seq.bound(in.len)) {
        const w = c.run(.unlimited, in, out, options.history);
        return w.?.out_len;
    }
    const w = c.run(.limited, in, out, options.history) orelse return error.OutputTooSmall;
    return w.out_len;
}

/// As much of `in` as one block of at most `out.len` bytes holds (lz4's
/// `destSize`): says how much input it took and the block's length.
pub fn compressBlockDestSize(c: *Compressor, in: []const u8, out: []u8, options: BlockOptions) Filled {
    return c.run(.fill, in, out, options.history).?;
}

fn run(c: *Compressor, comptime directive: seq.Directive, in: []const u8, out: []u8, history: History) ?seq.Written {
    defer c.previous = in;
    const level = c.level;
    switch (band(level)) {
        .fast => {
            const accel: u32 = if (level < 0) @intCast(1 - @as(i64, level)) else 1;
            switch (history) {
                .none => {
                    if (in.len < fast.small_limit) {
                        const start = c.table.begin(in.len, .small, false);
                        return fast.compress(.small, .none, directive, c.table, .{ .src = in, .start = start, .acceleration = accel }, out);
                    }
                    const start = c.table.begin(in.len, .large, false);
                    return fast.compress(.large, .none, directive, c.table, .{ .src = in, .start = start, .acceleration = accel }, out);
                },
                .previous => {
                    const prev = c.previous[c.previous.len -| 65536..];
                    // A block after one in the small-input table: its bytes
                    // indexed again, in this table's hash.
                    const reindex = c.table.kind != .large;
                    const start = c.table.begin(in.len, .large, true);
                    if (reindex) fast.loadFast(c.table, start, prev);
                    if (prev.len > 0 and prev.ptr + prev.len == in.ptr) {
                        // Just before the input in memory: one prefix.
                        const src = prev.ptr[0 .. prev.len + in.len];
                        return fast.compress(.large, .table, directive, c.table, .{ .src = src, .begin = prev.len, .start = start - @as(u32, @intCast(prev.len)), .acceleration = accel }, out);
                    }
                    return fast.compress(.large, .table, directive, c.table, .{ .src = in, .start = start, .history = prev, .acceleration = accel }, out);
                },
                .bytes => |bytes| {
                    const prev = bytes[bytes.len -| 65536..];
                    // The bytes are new to the table: a fresh window for them.
                    _ = c.table.begin(prev.len, .large, false);
                    const start = c.table.begin(in.len, .large, false);
                    fast.loadFast(c.table, start, prev);
                    return fast.compress(.large, .table, directive, c.table, .{ .src = in, .start = start, .history = prev, .acceleration = accel }, out);
                },
                .dictionary => {
                    const d = c.dictionary.?;
                    const start = c.table.begin(in.len, .large, false);
                    return fast.compress(.large, .attached, directive, c.table, .{
                        .src = in,
                        .start = start,
                        .history = d.bytes,
                        .dictionary = d.table,
                        .dictionary_end = d.table.next,
                        .acceleration = accel,
                    }, out);
                },
            }
        },
        .mid, .chains, .optimal => {
            const chains = c.chains.?;
            const prefix: hc.Prefix = switch (history) {
                .none => .none,
                .previous => .{ .previous = c.previous[c.previous.len -| 65536..] },
                .bytes => |bytes| .{ .bytes = bytes[bytes.len -| 65536..] },
                .dictionary => .{ .attached = .{ .bytes = c.dictionary.?.bytes, .chains = c.dictionary.?.chains.? } },
            };
            return chains.compress(directive, level, c.favor_decompression_speed, in, out, prefix);
        },
    }
}
