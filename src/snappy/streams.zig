//! Whole streams decoded: chunks read in place from the caller's input,
//! each block straight into the caller's output. Acceptance is S2's
//! reader's (v1.20.3), which reads both identifiers: blocks are read by
//! S2's rules in either (a Snappy stream's may hold repeats), at most 64
//! KiB after a Snappy identifier, and the identifier may come again,
//! switching the stream's kind.

const std = @import("std");
const aegis = @import("aegis");
const frame = @import("frame.zig");
const block = @import("block.zig");
const Diagnostic = @import("Diagnostic.zig");

pub const Options = struct {
    /// The largest block taken (S2's `ReaderMaxBlockSize`): a block past
    /// it, or a chunk past its bound, is refused. 4 MiB at most.
    max_block_size: aegis.units.Bytes(usize) = .literal("4MiB"),
    verify_checksum: bool = true,
    /// The input starts at a chunk after the identifier, as an index
    /// points (S2's `ReaderIgnoreStreamIdentifier`).
    from_chunk: bool = false,
    diagnostic: ?*Diagnostic = null,
};

pub const Error = error{
    /// A chunk or block the formats do not allow.
    InvalidStream,
    /// The input ends inside a chunk.
    Truncated,
    /// A data chunk's checksum is not its data's.
    ChecksumMismatch,
    /// An unskippable chunk of a type the format reserves.
    Unsupported,
    /// The output is shorter than the stream's.
    OutputTooSmall,
};

/// What a chunk header begins.
pub const Chunk = union(enum) {
    /// A block, compressed or stored: the bytes after the header (checksum
    /// and data), the output it declares.
    data: struct { compressed: bool, body: []const u8, len: usize },
    /// The identifier, naming the stream's kind.
    identifier: frame.Format,
    /// A chunk read past: padding, an index, a skippable chunk.
    skipped,
};

/// The checks S2's reader makes of a chunk's header at `at` before it
/// reads the chunk: the identifier first, a data chunk's length within
/// its bounds, an identifier's of six bytes, no reserved type.
pub fn checkHeader(h: frame.Header, at: u64, first: bool, options: Options) Error!void {
    if (first and h.type != frame.Type.identifier) return fail(options, at, .no_identifier, error.InvalidStream);
    const max = options.max_block_size.raw();
    switch (h.type) {
        frame.Type.compressed, frame.Type.uncompressed => if (h.len < frame.checksum_len or h.len > frame.maxChunk(max))
            return fail(options, at, .bad_chunk_length, error.InvalidStream),
        frame.Type.identifier => if (h.len != frame.identifier_len - frame.header_len)
            return fail(options, at, .bad_identifier, error.InvalidStream),
        else => if (!frame.Type.skippable(h.type)) return fail(options, at, .reserved_chunk, error.Unsupported),
    }
}

/// A chunk whose header passed `checkHeader`, from its whole body at
/// `body_at`: a data chunk's block length within the stream's limits
/// (`snappy` when the last identifier named a Snappy stream), an
/// identifier's name.
pub fn readBody(h: frame.Header, body: []const u8, body_at: u64, snappy: bool, options: Options) Error!Chunk {
    switch (h.type) {
        frame.Type.compressed, frame.Type.uncompressed => {
            const compressed = h.type == frame.Type.compressed;
            const len: usize = if (compressed)
                (block.header(body[frame.checksum_len..]) catch return fail(options, body_at + frame.checksum_len, .bad_length, error.InvalidStream)).len
            else
                h.len - frame.checksum_len;
            const max = options.max_block_size.raw();
            if ((snappy and len > frame.max_snappy_block_size) or len > max) return fail(options, body_at - frame.header_len, .block_too_large, error.InvalidStream);
            return .{ .data = .{ .compressed = compressed, .body = body, .len = len } };
        },
        frame.Type.identifier => {
            if (std.mem.eql(u8, body, frame.identifier_s2[frame.header_len..])) return .{ .identifier = .s2 };
            if (std.mem.eql(u8, body, frame.identifier_snappy[frame.header_len..])) return .{ .identifier = .snappy };
            return fail(options, body_at - frame.header_len, .bad_identifier, error.InvalidStream);
        },
        else => return .skipped,
    }
}

/// One chunk at `in[at..]`, read as S2's reader reads it; the chunk and
/// where the next begins. `snappy` is the kind the last identifier named.
pub fn readChunk(in: []const u8, at: usize, first: bool, snappy: bool, options: Options) Error!struct { Chunk, usize } {
    if (in.len - at < frame.header_len) return fail(options, at, .truncated, error.Truncated);
    const h = frame.readHeader(in[at..][0..frame.header_len]);
    try checkHeader(h, at, first, options);
    const body_at = at + frame.header_len;
    if (in.len - body_at < h.len) return fail(options, at, .truncated, error.Truncated);
    return .{ try readBody(h, in[body_at..][0..h.len], body_at, snappy, options), body_at + h.len };
}

/// A data chunk's block into `out` (at least its length): decoded or
/// copied, and its checksum checked. `body_at` is where its body starts in
/// the caller's input.
pub fn readData(data: @FieldType(Chunk, "data"), body_at: u64, out: []u8, options: Options) Error!void {
    if (out.len < data.len) return error.OutputTooSmall;
    const payload = data.body[frame.checksum_len..];
    if (data.compressed) {
        _ = block.decode(payload, out, .{ .format = .s2, .diagnostic = options.diagnostic, .in_base = body_at + frame.checksum_len }) catch |err| return switch (err) {
            error.OutputTooSmall => error.OutputTooSmall,
            error.InvalidStream, error.Truncated => error.InvalidStream,
        };
    } else @memcpy(out[0..data.len], payload);
    if (options.verify_checksum and frame.checksum(out[0..data.len]) != std.mem.readInt(u32, data.body[0..4], .little))
        return fail(options, body_at, .checksum, error.ChecksumMismatch);
}

/// Decode the whole stream `in` into `out`; the output's length.
pub fn decompress(in: []const u8, out: []u8, options: Options) Error!usize {
    const max = options.max_block_size.raw();
    std.debug.assert(max <= frame.max_block_size);
    var at: usize = 0;
    var op: usize = 0;
    var first = !options.from_chunk;
    var snappy = false;
    while (at < in.len) {
        const chunk, const end = try readChunk(in, at, first, snappy, options);
        first = false;
        switch (chunk) {
            .data => |data| {
                try readData(data, at + frame.header_len, out[op..], options);
                op += data.len;
            },
            .identifier => |format| snappy = format == .snappy,
            .skipped => {},
        }
        at = end;
    }
    return op;
}

/// The output of a whole stream, from its blocks' lengths: the chunks
/// read as `decompress` reads them, the blocks not decoded.
pub fn decodedLen(in: []const u8, options: Options) Error!u64 {
    var at: usize = 0;
    var total: u64 = 0;
    var first = !options.from_chunk;
    var snappy = false;
    while (at < in.len) {
        const chunk, const end = try readChunk(in, at, first, snappy, options);
        first = false;
        switch (chunk) {
            .data => |data| total += data.len,
            .identifier => |format| snappy = format == .snappy,
            .skipped => {},
        }
        at = end;
    }
    return total;
}

pub fn fail(options: Options, at: u64, reason: Diagnostic.Reason, err: Error) Error {
    if (options.diagnostic) |diag| diag.* = .{ .offset = .fromRaw(at), .reason = reason };
    return err;
}
