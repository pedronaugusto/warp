//! Whole-buffer LZMA decoding straight into the caller's output, which is
//! the dictionary: raw LZMA (`decompressLzma1`, properties given apart, as
//! 7z and zip store it), raw LZMA2 (`decompressLzma2`, as 7z and xz store
//! it) and `.lzma` files (`decompressAlone`). A `Decompressor` holds one
//! coder's probabilities (about 30 KiB) and allocates nothing.

const Decompressor = @This();

const std = @import("std");
const decode = @import("decode.zig");
const range = @import("range.zig");
const Diagnostic = @import("Diagnostic.zig");

pub const Properties = decode.Properties;

/// Private: the coder.
coder: decode.Coder = .{},

pub const init: Decompressor = .{};

pub const Error = error{
    /// Not LZMA data, or data that breaks the format as liblzma reads it.
    InvalidStream,
    /// The input ends inside the stream.
    Truncated,
    /// The stream decodes to more than `out` holds.
    OutputTooSmall,
};

pub const Result = struct {
    /// Input bytes the stream took; what follows is not read.
    in_len: usize,
    /// Output bytes written.
    out_len: usize,
};

pub const Lzma1 = struct {
    properties: Properties = .{},
    /// The declared dictionary size.
    dictionary: u32,
    /// The uncompressed size where it is known: the stream ends there, with
    /// or without an end marker (as LZMA1EXT with ALLOW_EOPM reads it);
    /// null, the end marker ends it.
    size: ?u64 = null,
    diagnostic: ?*Diagnostic = null,
};

/// Decode raw LZMA from `in` into `out`.
pub fn decompressLzma1(d: *Decompressor, in: []const u8, out: []u8, options: Lzma1) Error!Result {
    return d.lzma1(in, 0, out, options);
}

fn lzma1(d: *Decompressor, in: []const u8, base: u64, out: []u8, options: Lzma1) Error!Result {
    d.coder.reset(options.properties);
    d.coder.left = options.size;
    d.coder.allow_marker = true;
    var rc: range.Decoder = .{ .in = in, .pos = 0 };
    if (!(rc.start() catch return fail(options.diagnostic, error.Truncated, base + in.len, .truncated)))
        return fail(options.diagnostic, error.InvalidStream, base, .range_start);
    const limit = if (options.size) |s| @min(out.len, s) else out.len;
    var w: decode.Linear = .{ .buf = out, .pos = 0, .start = 0, .dict_size = decode.dictionary(options.dictionary), .limit = limit };
    const status = decode.run(&d.coder, &rc, &w, base) catch |err| switch (err) {
        error.NeedInput => return fail(options.diagnostic, error.Truncated, base + in.len, .truncated),
        error.InvalidStream => return fail(options.diagnostic, error.InvalidStream, d.coder.fail_at, d.coder.reason),
    };
    if (status == .output_full) return error.OutputTooSmall;
    return .{ .in_len = rc.pos, .out_len = w.pos };
}

pub const Lzma2 = struct {
    /// The declared dictionary size.
    dictionary: u32,
    diagnostic: ?*Diagnostic = null,
};

/// Decode raw LZMA2 from `in` into `out`, to its end chunk.
pub fn decompressLzma2(d: *Decompressor, in: []const u8, out: []u8, options: Lzma2) Error!Result {
    return d.lzma2(in, 0, out, options);
}

/// LZMA2 at offset `base` of a larger input, for the diagnostic.
pub fn lzma2(d: *Decompressor, in: []const u8, base: u64, out: []u8, options: Lzma2) Error!Result {
    const diag = options.diagnostic;
    var w: decode.Linear = .{ .buf = out, .pos = 0, .start = 0, .dict_size = decode.dictionary(options.dictionary), .limit = out.len };
    var ip: usize = 0;
    var need_reset = true;
    var need_properties = true;
    while (true) {
        const at = base + ip;
        if (ip == in.len) return fail(diag, error.Truncated, at, .truncated);
        const control = in[ip];
        ip += 1;
        if (control == 0) return .{ .in_len = ip, .out_len = w.pos };
        if (control >= 0xe0 or control == 1) {
            need_properties = true;
            need_reset = true;
        } else if (need_reset) return fail(diag, error.InvalidStream, at, .dictionary_reset);
        if (control >= 0x80) {
            if (in.len - ip < 4) return fail(diag, error.Truncated, base + in.len, .truncated);
            const size = (@as(u64, control & 0x1f) << 16 | @as(u64, in[ip]) << 8 | in[ip + 1]) + 1;
            const packed_size = (@as(usize, in[ip + 2]) << 8 | in[ip + 3]) + 1;
            ip += 4;
            if (control >= 0xc0) {
                if (ip == in.len) return fail(diag, error.Truncated, base + in.len, .truncated);
                const props = Properties.parse(in[ip]) orelse return fail(diag, error.InvalidStream, base + ip, .properties);
                ip += 1;
                need_properties = false;
                d.coder.reset(props);
            } else if (need_properties) {
                return fail(diag, error.InvalidStream, at, .properties_needed);
            } else if (control >= 0xa0) d.coder.reset(d.coder.props);
            if (need_reset) {
                need_reset = false;
                w.start = w.pos;
            }
            // The coder may read one byte past the chunk, which liblzma
            // then refuses.
            const chunk = in[ip..@min(in.len, ip + packed_size + 1)];
            d.coder.left = size;
            d.coder.allow_marker = false;
            d.coder.marker_next = false;
            var rc: range.Decoder = .{ .in = chunk, .pos = 0 };
            const started = rc.start() catch return d.chunkShort(diag, chunk, packed_size, base + ip);
            if (!started) return fail(diag, error.InvalidStream, base + ip, .range_start);
            w.limit = @min(out.len, w.pos + size);
            const status = decode.run(&d.coder, &rc, &w, base + ip) catch |err| switch (err) {
                error.NeedInput => return d.chunkShort(diag, chunk, packed_size, base + ip),
                error.InvalidStream => return fail(diag, error.InvalidStream, d.coder.fail_at, d.coder.reason),
            };
            if (status == .output_full) return error.OutputTooSmall;
            if (rc.pos != packed_size) return fail(diag, error.InvalidStream, base + ip, .chunk_size);
            ip += packed_size;
        } else {
            if (control > 2) return fail(diag, error.InvalidStream, at, .control);
            if (in.len - ip < 2) return fail(diag, error.Truncated, base + in.len, .truncated);
            const size = (@as(usize, in[ip]) << 8 | in[ip + 1]) + 1;
            ip += 2;
            if (need_reset) {
                need_reset = false;
                w.start = w.pos;
            }
            if (in.len - ip < size) return fail(diag, error.Truncated, base + in.len, .truncated);
            if (out.len - w.pos < size) return error.OutputTooSmall;
            @memcpy(out[w.pos..][0..size], in[ip..][0..size]);
            w.pos += size;
            ip += size;
        }
    }
}

/// An LZMA chunk's coder ran out of input: past the chunk (liblzma's
/// "used more than the compressed size"), or at the input's end.
fn chunkShort(d: *Decompressor, diag: ?*Diagnostic, chunk: []const u8, packed_size: usize, at: u64) Error {
    _ = d;
    if (chunk.len > packed_size) return fail(diag, error.InvalidStream, at, .chunk_size);
    return fail(diag, error.Truncated, at + chunk.len, .truncated);
}

pub const Alone = struct {
    diagnostic: ?*Diagnostic = null,
};

/// The `.lzma` header's length: properties, dictionary, size.
pub const alone_header_len = 13;

/// Decode a `.lzma` file (LZMA_Alone): its 13-byte header, then LZMA data
/// to the header's size or the end marker.
pub fn decompressAlone(d: *Decompressor, in: []const u8, out: []u8, options: Alone) Error!Result {
    const diag = options.diagnostic;
    if (in.len == 0) return fail(diag, error.Truncated, 0, .truncated);
    const props = Properties.parse(in[0]) orelse return fail(diag, error.InvalidStream, 0, .properties);
    if (in.len < alone_header_len) return fail(diag, error.Truncated, in.len, .truncated);
    const dict = std.mem.readInt(u32, in[1..5], .little);
    const size = std.mem.readInt(u64, in[5..13], .little);
    const r = try d.lzma1(in[alone_header_len..], alone_header_len, out, .{
        .properties = props,
        .dictionary = dict,
        .size = if (size == std.math.maxInt(u64)) null else size,
        .diagnostic = diag,
    });
    return .{ .in_len = alone_header_len + r.in_len, .out_len = r.out_len };
}

fn fail(diag: ?*Diagnostic, err: Error, at: u64, reason: Diagnostic.Reason) Error {
    if (diag) |p| p.* = .{ .offset = .fromRaw(at), .reason = reason };
    return err;
}
