//! Whole-buffer `.xz` encoding: one stream of blocks of LZMA2, the filters
//! before it applied forward, each block's check, the index and footer,
//! written as liblzma 5.8.4 writes them. Every block header names both
//! sizes, so the parallel decoders split any stream warp writes.
//!
//! Blocks are `block_size` bytes of input (one block for all of it by
//! default, as `xz` writes alone; `xz.parallel.Compressor` cuts them as
//! `xz -T` does). The LZMA2 goes straight into the caller's buffer after
//! room for its header, which is moved up to it if shorter; the index is
//! read back from the headers written, so nothing is kept per block.

const Compressor = @This();

const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const format = @import("format.zig");
const grow = @import("../grow.zig");
const filter_ = @import("filter.zig");
const Lzma = @import("../lzma/Compressor.zig");
const Crc32 = @import("../checksum/crc32.zig").Crc32;

pub const Check = format.Check;
pub const Filter = filter_.Filter;
pub const Bcj = filter_.Bcj;

pub const Options = struct {
    lzma: Lzma.Options = .preset(6, false),
    check: Check = .crc64,
    /// At most three filters before LZMA2, applied in order.
    filters: []const Filter = &.{},
    /// Input per block; null: one block.
    block_size: ?u64 = null,
    /// The largest input `compress` will see: it sizes the tables and the
    /// filters' copy. A larger input still compresses (matches reach back
    /// no further than the tables allow; the copy grows). null sizes the
    /// tables for the dictionary.
    max_input: ?aegis.units.Bytes(usize) = null,

    pub fn valid(o: Options) bool {
        if (!o.lzma.valid() or o.filters.len > 3) return false;
        if (o.block_size) |b| if (b == 0) return false;
        return format.Hasher.writer(o.check) != null;
    }

    /// The largest block `compress` makes of an input of `len` bytes.
    fn blockLen(o: Options, len: usize) usize {
        return if (o.block_size) |b| @intCast(@min(b, len)) else len;
    }

    fn tablesInput(o: Options) ?aegis.units.Bytes(usize) {
        const m = o.max_input orelse return if (o.block_size) |b| .fromRaw(@intCast(@min(b, std.math.maxInt(usize)))) else null;
        return .fromRaw(o.blockLen(m.raw()));
    }
};

pub const InitError = Allocator.Error || error{InvalidOptions};
pub const Error = Allocator.Error || error{
    /// `out` is shorter than the stream; `bound(...)` always holds it.
    OutputTooSmall,
    /// The stream's index would pass the 16 GiB its footer can name: more blocks than one
    /// xz stream holds, which a larger `block_size` avoids.
    LimitExceeded,
};

/// Private: LZMA2's encoder.
lzma: Lzma,
options: Options,
/// Private: the check each block ends with, made from `options.check` at
/// `init`, so a block writes only a check `init` accepted.
hasher: format.Hasher,
/// Private: a block's input with the filters applied.
scratch: []u8 = &.{},
/// Private: the records of the blocks `compress` has written of its stream,
/// for the index; at most `max_records`.
records: aegis.bounded.Buffer(Record),
gpa: Allocator,

/// The most records `records` holds: the index's, where the address space allows.
pub const max_records: usize = @min(format.max_records, std.math.maxInt(usize) / @sizeOf(Record));

pub fn init(gpa: Allocator, options: Options) InitError!Compressor {
    if (!options.valid()) return error.InvalidOptions;
    const hasher = format.Hasher.writer(options.check) orelse return error.InvalidOptions;
    var c: Compressor = .{ .lzma = try .init(gpa, options.lzma, options.tablesInput()), .options = options, .hasher = hasher, .gpa = gpa, .records = undefined };
    errdefer c.lzma.deinit();
    c.records = aegis.bounded.Buffer(Record).initAllocated(gpa, 0, max_records) catch |err| switch (err) {
        error.OutOfMemory => |e| return e,
        error.CapacityExceeded => aegis.assert.never("max_records fits the address space"),
    };
    errdefer c.records.deinit(grow.keep(Record));
    if (options.filters.len != 0) if (options.max_input) |m| {
        c.scratch = try gpa.alloc(u8, options.blockLen(m.raw()));
    };
    return c;
}

pub fn deinit(c: *Compressor) void {
    c.lzma.deinit();
    c.gpa.free(c.scratch);
    c.records.deinit(grow.keep(Record));
    c.* = undefined;
}

/// The largest stream an input of `len` bytes encodes to with `options`.
pub fn bound(options: Options, len: usize) usize {
    const most = options.blockLen(len);
    const count = if (len == 0) 0 else std.math.divCeil(usize, len, most) catch unreachable; // glint-ignore: Z026 -- most is at least 1: init refuses a block_size of 0 and len is not 0 here
    const data = Lzma.bound(.lzma2, most);
    const header = format.blockHeaderLen(.{ .compressed = data, .uncompressed = most, .filters = options.filters, .dictionary = options.lzma.dictionary });
    const per_block = header + std.mem.alignForward(usize, data, 4) + options.check.size();
    const index = std.mem.alignForward(usize, 1 + format.vliLen(count) + count * (format.vliLen(per_block) + format.vliLen(most)), 4) + 4;
    return format.header_len + count * per_block + index + format.footer_len;
}

/// One stream of `in` into `out`; its length.
pub fn compress(c: *Compressor, in: []const u8, out: []u8) Error!usize {
    const o = c.options;
    if (out.len < format.header_len) return error.OutputTooSmall;
    format.writeStreamHeader(out[0..format.header_len], o.check);
    var pos: usize = format.header_len;
    const block_len = o.blockLen(in.len);
    c.records.clear(grow.keep(Record));
    // A record for each block, room for them all made first.
    try grow.room(Record, &c.records, max_records, if (in.len == 0) 0 else (in.len - 1) / block_len + 1);
    var rest = in;
    while (rest.len != 0) {
        const n = @min(rest.len, block_len);
        var r = try c.blockRecord(rest[0..n], out[pos..]);
        c.records.append(&r) catch aegis.assert.never("room was made for every block's record");
        pos += r.span;
        rest = rest[n..];
    }
    pos += try writeIndex(out, pos, c.records.items(), o.check);
    return pos;
}

/// One block of `in` into `out`: header, LZMA2, padding, check; its
/// length.
pub fn block(c: *Compressor, in: []const u8, out: []u8) Error!usize {
    return (try c.blockRecord(in, out)).span;
}

/// One block of `in` into `out`, and its index record.
pub fn blockRecord(c: *Compressor, in: []const u8, out: []u8) Error!Record {
    const o = c.options;
    var data = in;
    if (o.filters.len != 0) {
        if (c.scratch.len < in.len) {
            c.gpa.free(c.scratch);
            c.scratch = &.{};
            c.scratch = try c.gpa.alloc(u8, in.len);
        }
        const copy = c.scratch[0..in.len];
        @memcpy(copy, in);
        for (o.filters) |f| {
            var s: filter_.State = .init(f);
            _ = filter_.run(f, &s, copy, true);
        }
        data = copy;
    }
    var spec: format.BlockSpec = .{ .compressed = Lzma.bound(.lzma2, in.len), .uncompressed = in.len, .filters = o.filters, .dictionary = o.lzma.dictionary };
    const room = format.blockHeaderLen(spec);
    if (out.len < room) return error.OutputTooSmall;
    const len = try c.lzma.compress(data, out[room..], .lzma2);
    spec.compressed = len;
    const header = format.blockHeaderLen(spec);
    if (header < room) @memmove(out[header..][0..len], out[room..][0..len]);
    format.writeBlockHeader(out, spec);
    var pos = header + len;
    const padding = (4 - len % 4) % 4;
    const check = c.hasher.len();
    if (out.len - pos < padding + check) return error.OutputTooSmall;
    @memset(out[pos..][0..padding], 0);
    pos += padding;
    var h = c.hasher;
    h.update(in);
    h.final(out[pos..][0..check]);
    return .{ .unpadded = header + len + check, .uncompressed = in.len, .span = pos + check };
}

/// The index of `records`, the stream's blocks in order, then the footer, at
/// `out[end..]`; their length.
pub fn writeIndex(out: []u8, end: usize, records: []const Record, check: Check) Error!usize {
    var len: usize = 1;
    for (records) |r| len += format.vliLen(r.unpadded) + format.vliLen(r.uncompressed);
    len += format.vliLen(records.len);
    const index_len = std.mem.alignForward(usize, len, 4) + 4;
    if (index_len > format.max_index_len) return error.LimitExceeded;
    if (out.len - end < index_len + format.footer_len) return error.OutputTooSmall;
    const index = out[end..][0..index_len];
    @memset(index, 0);
    var pos: usize = 1;
    format.putVli(index, &pos, records.len);
    for (records) |r| {
        format.putVli(index, &pos, r.unpadded);
        format.putVli(index, &pos, r.uncompressed);
    }
    std.mem.writeInt(u32, index[index_len - 4 ..][0..4], Crc32.hash(index[0 .. index_len - 4]), .little);
    format.writeStreamFooter(out[end + index_len ..][0..format.footer_len], index_len, check);
    return index_len + format.footer_len;
}

/// A block's index record, kept as the block is written: its unpadded and
/// uncompressed sizes, and its whole length in the stream.
pub const Record = struct { unpadded: u64, uncompressed: u64, span: usize };
