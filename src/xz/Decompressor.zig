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
    var at: usize = 0;
    var op: usize = 0;
    while (true) {
        at = try d.stream(in, at, out, &op, diag);
        if (options.streams == .one) return .{ .in_len = at, .out_len = op };
        // Stream padding: zeros, four at a time, then another stream or
        // the end.
        var p = at;
        while (p < in.len and in[p] == 0) p += 1;
        if ((p - at) % 4 != 0) return fail(diag, error.InvalidStream, p, .stream_padding);
        if (p == in.len) return .{ .in_len = p, .out_len = op };
        at = p;
    }
}

/// One stream from `in[at..]` into `out[op.*..]`; its end.
fn stream(d: *Decompressor, in: []const u8, at: usize, out: []u8, op: *usize, diag: ?*Diagnostic) Error!usize {
    if (in.len - at < format.header_len) return fail(diag, error.Truncated, in.len, .truncated);
    const check = switch (format.streamHeader(in[at..][0..format.header_len])) {
        .check => |c| c,
        .fault => |reason| return fail(diag, error.InvalidStream, at, reason),
    };
    var pos = at + format.header_len;
    // The blocks' records, hashed as the index's are, to compare.
    var blocks: Records = .{};
    while (true) {
        if (pos == in.len) return fail(diag, error.Truncated, pos, .truncated);
        if (in[pos] == 0) break;
        const header_len = (@as(usize, in[pos]) + 1) * 4;
        if (in.len - pos < header_len) return fail(diag, error.Truncated, in.len, .truncated);
        const h = switch (format.blockHeader(in[pos..][0..header_len], check)) {
            .header => |h| h,
            .fault => |f| return fail(diag, error.InvalidStream, pos + f.at, f.reason),
        };
        const data = pos + header_len;
        const r = try d.block(in, data, out[op.*..], h, diag);
        // Block padding, then the check.
        var p = data + r.in_len;
        const padding = (4 - r.in_len % 4) % 4;
        if (in.len - p < padding) return fail(diag, error.Truncated, in.len, .truncated);
        for (in[p..][0..padding]) |b| if (b != 0) return fail(diag, error.InvalidStream, p, .block_padding);
        p += padding;
        if (in.len - p < check.size()) return fail(diag, error.Truncated, in.len, .truncated);
        if (!verify(check, out[op.*..][0..r.out_len], in[p..][0..check.size()])) return fail(diag, error.ChecksumMismatch, p, .check);
        p += check.size();
        blocks.add(header_len + r.in_len + check.size(), r.out_len);
        op.* += r.out_len;
        pos = p;
    }
    return readIndex(in, pos, check, blocks, diag);
}

/// The index at `pos` against the blocks' records, then the footer; the
/// stream's end.
pub fn readIndex(in: []const u8, index_at: usize, check: format.Check, blocks: Records, diag: ?*Diagnostic) Error!usize {
    var pos = index_at + 1;
    const count = format.vli(in, &pos) orelse return indexFault(diag, in, pos, index_at);
    if (count != blocks.count) return fail(diag, error.InvalidStream, index_at, .index);
    var records: Records = .{};
    for (0..count) |_| {
        const unpadded = format.vli(in, &pos) orelse return indexFault(diag, in, pos, index_at);
        const size = format.vli(in, &pos) orelse return indexFault(diag, in, pos, index_at);
        if (unpadded < 5 or unpadded > format.vli_max & ~@as(u64, 3)) return fail(diag, error.InvalidStream, index_at, .index);
        records.add(unpadded, size);
    }
    if (!std.meta.eql(records, blocks)) return fail(diag, error.InvalidStream, index_at, .index);
    while ((pos - index_at) % 4 != 0) : (pos += 1) {
        if (pos == in.len) return fail(diag, error.Truncated, pos, .truncated);
        if (in[pos] != 0) return fail(diag, error.InvalidStream, pos, .index);
    }
    if (in.len - pos < 4) return fail(diag, error.Truncated, in.len, .truncated);
    if (Crc32.hash(in[index_at..pos]) != std.mem.readInt(u32, in[pos..][0..4], .little)) return fail(diag, error.InvalidStream, pos, .index_crc);
    pos += 4;
    const index_len = pos - index_at;
    if (in.len - pos < format.footer_len) return fail(diag, error.Truncated, in.len, .truncated);
    const footer = switch (format.streamFooter(in[pos..][0..format.footer_len])) {
        .footer => |f| f,
        .fault => |reason| return fail(diag, error.InvalidStream, pos, reason),
    };
    if (footer.check != check) return fail(diag, error.InvalidStream, pos, .footer_flags);
    if (footer.backward_size != index_len) return fail(diag, error.InvalidStream, pos, .backward_size);
    return pos + format.footer_len;
}

/// An index field that does not read: past the input, or malformed.
fn indexFault(diag: ?*Diagnostic, in: []const u8, pos: usize, index_at: usize) Error {
    if (pos >= in.len) return fail(diag, error.Truncated, in.len, .truncated);
    return fail(diag, error.InvalidStream, index_at, .index);
}

/// One block's data, `in[data..]`, into `out`: LZMA2 to its end, held to
/// the header's sizes, then the filters undone.
fn block(d: *Decompressor, in: []const u8, data: usize, out: []u8, h: format.BlockHeader, diag: ?*Diagnostic) Error!Result {
    const rest = in[data..];
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
    var i: usize = h.filter_count;
    while (i > 0) {
        i -= 1;
        var s: filter_.State = .init(h.filters[i]);
        _ = filter_.run(h.filters[i], &s, out[0..r.out_len], false);
    }
    return r;
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
