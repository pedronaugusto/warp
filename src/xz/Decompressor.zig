//! Whole-buffer `.xz` decoding straight into the caller's output: streams,
//! their blocks (LZMA2, then the filters before it undone in place over
//! the block's output), checks and indexes, read as liblzma 5.8.4 reads
//! them. A `Decompressor` holds one LZMA2 coder (about 30 KiB) and
//! allocates nothing.

const Decompressor = @This();

const std = @import("std");
const lzma = @import("../lzma/Decompressor.zig");
const format = @import("format.zig");
const filter_ = @import("filter.zig");
const Diagnostic = @import("../lzma/Diagnostic.zig");
const Crc32 = @import("../checksum/crc32.zig").Crc32;
const Crc64Xz = @import("../checksum/crc64xz.zig").Crc64Xz;

/// Private: LZMA2's coder.
lzma2: lzma = .init,

pub const init: Decompressor = .{};

/// How many streams a decoder reads.
pub const Streams = enum {
    /// The first stream; what follows it is left unread.
    one,
    /// Streams and stream padding while the input goes on, as `xz -d`
    /// reads them; anything else after them is refused.
    all,
};

pub const Options = struct {
    streams: Streams = .all,
    diagnostic: ?*Diagnostic = null,
};

pub const Result = lzma.Result;

pub const Error = error{
    /// Not an .xz stream, or one that breaks the format as liblzma reads it.
    InvalidStream,
    /// A block's check does not match its output.
    ChecksumMismatch,
    /// The input ends inside a stream.
    Truncated,
    /// The streams decode to more than `out` holds.
    OutputTooSmall,
};

/// Decode the streams of `in` into `out`. Bytes of `out` past
/// `Result.out_len` may have been written and are scratch afterwards.
pub fn decompress(d: *Decompressor, in: []const u8, out: []u8, options: Options) Error!Result {
    const diag = options.diagnostic;
    // What is left of each, ends cut as they are taken.
    var rest = in;
    var room = out;
    while (true) {
        rest = try d.stream(in, rest, &room, diag);
        if (options.streams == .one) return .{ .in_len = in.len - rest.len, .out_len = out.len - room.len };
        // Stream padding: zeros, four at a time, then another stream or
        // the end.
        const zeros = std.mem.findNone(u8, rest, &.{0}) orelse rest.len;
        if (zeros % 4 != 0) return fail(diag, error.InvalidStream, in.len - rest.len + zeros, .stream_padding);
        rest = rest[zeros..];
        if (rest.len == 0) return .{ .in_len = in.len, .out_len = out.len - room.len };
    }
}

/// One stream from the start of `rest` into `room`, which it cuts past
/// what it writes; what follows the stream.
fn stream(d: *Decompressor, in: []const u8, start: []const u8, room: *[]u8, diag: ?*Diagnostic) Error![]const u8 {
    if (start.len < format.header_len) return fail(diag, error.Truncated, in.len, .truncated);
    const check = switch (format.streamHeader(start[0..format.header_len])) {
        .check => |c| c,
        .fault => |reason| return fail(diag, error.InvalidStream, in.len - start.len, reason),
    };
    var rest = start[format.header_len..];
    // The blocks' records, hashed as the index's are, to compare.
    var blocks: Records = .{};
    while (true) {
        if (rest.len == 0) return fail(diag, error.Truncated, in.len, .truncated);
        if (rest[0] == 0) break;
        const block_start = rest;
        const header_len = (@as(usize, rest[0]) + 1) * 4;
        if (rest.len < header_len) return fail(diag, error.Truncated, in.len, .truncated);
        const h = switch (format.blockHeader(rest[0..header_len], check)) {
            .header => |h| h,
            .fault => |f| return fail(diag, error.InvalidStream, in.len - rest.len +| f.at, f.reason),
        };
        const data = rest[header_len..];
        const b = try d.block(in, data, room.*, h, diag);
        room.* = room.*[b.output.len..];
        rest = data[b.input.len..];
        const unpadded_end = rest;
        // Block padding, to four bytes, then the check.
        const padding: u2 = @truncate(0 -% b.input.len);
        if (rest.len < padding) return fail(diag, error.Truncated, in.len, .truncated);
        for (rest[0..padding]) |byte| if (byte != 0) return fail(diag, error.InvalidStream, in.len - rest.len, .block_padding);
        rest = rest[padding..];
        if (rest.len < check.size()) return fail(diag, error.Truncated, in.len, .truncated);
        if (!verify(check, b.output, rest[0..check.size()])) return fail(diag, error.ChecksumMismatch, in.len - rest.len, .check);
        rest = rest[check.size()..];
        blocks.add(block_start.len - unpadded_end.len + check.size(), b.output.len);
    }
    return readIndex(in, rest, check, blocks, diag);
}

/// The index at the start of `index` against the blocks' records, then
/// the footer; what follows the stream.
pub fn readIndex(in: []const u8, index: []const u8, check: format.Check, blocks: Records, diag: ?*Diagnostic) Error![]const u8 {
    const index_at = in.len - index.len;
    // The fields, cut as they are read.
    var fields = index[1..];
    const count = format.vli(&fields) orelse return indexFault(diag, in, index, fields);
    if (count != blocks.count) return fail(diag, error.InvalidStream, index_at, .index);
    var records: Records = .{};
    for (0..count) |_| {
        const unpadded = format.vli(&fields) orelse return indexFault(diag, in, index, fields);
        const size = format.vli(&fields) orelse return indexFault(diag, in, index, fields);
        if (unpadded < 5 or unpadded > format.vli_max & ~@as(u64, 3)) return fail(diag, error.InvalidStream, index_at, .index);
        records.add(unpadded, size);
    }
    if (!std.meta.eql(records, blocks)) return fail(diag, error.InvalidStream, index_at, .index);
    var rest = fields;
    // Index padding: zeros to four bytes.
    const padding: u2 = @truncate(0 -% (index.len - rest.len));
    const zeros = rest[0..@min(padding, rest.len)];
    for (zeros, 0..) |b, i| if (b != 0) return fail(diag, error.InvalidStream, in.len - rest.len + i, .index);
    if (zeros.len < padding) return fail(diag, error.Truncated, in.len, .truncated);
    rest = rest[padding..];
    if (rest.len < 4) return fail(diag, error.Truncated, in.len, .truncated);
    const index_len = index.len - rest.len;
    if (Crc32.hash(index[0..index_len]) != std.mem.readInt(u32, rest[0..4], .little)) return fail(diag, error.InvalidStream, in.len - rest.len, .index_crc);
    rest = rest[4..];
    if (rest.len < format.footer_len) return fail(diag, error.Truncated, in.len, .truncated);
    const footer = switch (format.streamFooter(rest[0..format.footer_len])) {
        .footer => |f| f,
        .fault => |reason| return fail(diag, error.InvalidStream, in.len - rest.len, reason),
    };
    if (footer.check != check) return fail(diag, error.InvalidStream, in.len - rest.len, .footer_flags);
    if (footer.backward_size != index.len - rest.len) return fail(diag, error.InvalidStream, in.len - rest.len, .backward_size);
    return rest[format.footer_len..];
}

/// An index field that does not read: past the input, or malformed.
/// `rest` is what follows the field.
fn indexFault(diag: ?*Diagnostic, in: []const u8, index: []const u8, rest: []const u8) Error {
    if (rest.len == 0) return fail(diag, error.Truncated, in.len, .truncated);
    return fail(diag, error.InvalidStream, in.len - index.len, .index);
}

/// The input a block's data took and the output it wrote.
const Block = struct { input: []const u8, output: []u8 };

/// One block's data, at the start of `rest`, into `out`: LZMA2 to its
/// end, held to the header's sizes, then the filters undone.
fn block(d: *Decompressor, in: []const u8, rest: []const u8, out: []u8, h: format.BlockHeader, diag: ?*Diagnostic) Error!Block {
    const data = in.len - rest.len;
    const src = if (h.compressed) |c| rest[0..@intCast(@min(rest.len, c))] else rest;
    const room = if (h.uncompressed) |u| out[0..@intCast(@min(out.len, u))] else out;
    const r = d.lzma2.lzma2(src, data, room, .{ .dictionary = h.dictionary, .diagnostic = diag }) catch |err| switch (err) {
        // Short of the header's compressed size, or of its uncompressed one.
        error.Truncated => return if (h.compressed != null and src.len == h.compressed.?)
            fail(diag, error.InvalidStream, data, .block_size)
        else
            err,
        error.OutputTooSmall => return if (h.uncompressed != null and room.len == h.uncompressed.?)
            fail(diag, error.InvalidStream, data, .block_size)
        else
            err,
        else => |e| return e,
    };
    if (h.compressed) |c| if (r.in_len != c) return fail(diag, error.InvalidStream, data, .block_size);
    if (h.uncompressed) |u| if (r.out_len != u) return fail(diag, error.InvalidStream, data, .block_size);
    // LZMA2 takes and writes no more than it is given.
    if (r.in_len > src.len or r.out_len > room.len) return fail(diag, error.InvalidStream, data, .block_size);
    const b: Block = .{ .input = src[0..r.in_len], .output = room[0..r.out_len] };
    var i: usize = h.filter_count;
    while (i > 0) {
        i -= 1;
        var s: filter_.State = .init(h.filters[i]);
        _ = filter_.run(h.filters[i], &s, b.output, false);
    }
    return b;
}

/// The blocks' or the index's records: their count and a hash of them.
pub const Records = struct {
    count: u64 = 0,
    crc: u64 = 0,

    pub fn add(r: *Records, unpadded: u64, size: u64) void {
        var bytes: [16]u8 = undefined;
        std.mem.writeInt(u64, bytes[0..8], unpadded, .little);
        std.mem.writeInt(u64, bytes[8..16], size, .little);
        var c: Crc64Xz = .{ .value = r.crc };
        c.update(&bytes);
        r.crc = c.final();
        r.count += 1;
    }
};

/// Whether `output`'s check is `stored`; a check id warp does not compute
/// (those xz reserves) is skipped, as liblzma skips it.
pub fn verify(check: format.Check, output: []const u8, stored: []const u8) bool {
    switch (check) {
        .none => return true,
        .crc32 => return Crc32.hash(output) == std.mem.readInt(u32, stored[0..4], .little),
        .crc64 => return Crc64Xz.hash(output) == std.mem.readInt(u64, stored[0..8], .little),
        .sha256 => {
            var h: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(output, &h, .{});
            return std.mem.eql(u8, &h, stored[0..32]);
        },
        _ => return true,
    }
}

fn fail(diag: ?*Diagnostic, err: Error, at: u64, reason: Diagnostic.Reason) Error {
    if (diag) |p| p.* = .{ .offset = .fromRaw(at), .reason = reason };
    return err;
}
