//! Whole-buffer LZ4 frame decoding: concatenated frames, skippable and
//! legacy ones, straight into the caller's output, which is their own
//! history. Nothing is held between calls: LZ4 has no tables.

const std = @import("std");
const aegis = @import("aegis");
const block = @import("block.zig");
const frame = @import("frame.zig");
const Diagnostic = @import("Diagnostic.zig");

/// How many frames a call reads.
pub const Frames = enum {
    /// The first LZ4 or legacy frame (skippable frames before it are
    /// skipped); what follows it is left unread.
    one,
    /// Every frame, skippable ones skipped; anything after the last that is
    /// not a frame is refused.
    all,
};

pub const Options = struct {
    frames: Frames = .all,
    /// Stop without error when `out` is full; `Result.finished` is then
    /// false and the output so far is a prefix of the content.
    partial: bool = false,
    /// Check block and content checksums where frames carry them.
    verify_checksum: bool = true,
    /// What frames that name a dictionary, and any whose sender agreed on
    /// one, refer back into; the last 64 KiB count.
    dictionary: []const u8 = &.{},
    /// The dictionary's ID: a frame naming another is refused. null: any.
    dictionary_id: ?u32 = null,
    /// The largest block maximum accepted: a frame declaring a larger one
    /// is refused.
    max_block_size: aegis.units.Bytes(usize) = .literal("4MiB"),
    diagnostic: ?*Diagnostic = null,
};

pub const Result = struct {
    /// Input bytes the frames took; what follows them is not read.
    in_len: usize,
    /// Output bytes written.
    out_len: usize,
    /// Every frame asked for ended (always, unless `partial` stopped it).
    finished: bool,
};

pub const Error = error{
    /// Not LZ4 frames, or frames that break the format.
    InvalidStream,
    /// A block or content checksum is not the data's.
    ChecksumMismatch,
    /// A frame names a dictionary that was not given, or another one.
    DictionaryMismatch,
    /// The input ends inside a frame.
    Truncated,
    /// The frames decode to more than `out` holds.
    OutputTooSmall,
};

/// Decode the frames of `in` into `out`. Bytes of `out` past
/// `Result.out_len` may have been written and are scratch afterwards.
pub fn decompress(in: []const u8, out: []u8, options: Options) Error!Result {
    var d: Decoder = .{ .in = in, .out = out, .options = options };
    return d.run();
}

const Decoder = struct {
    in: []const u8,
    out: []u8,
    options: Options,
    ip: usize = 0,
    op: usize = 0,

    fn run(d: *Decoder) Error!Result {
        var frames: usize = 0;
        while (true) {
            if (frames > 0 and (d.options.frames == .one or d.ip == d.in.len)) break;
            // After a frame, what does not start one is trailing data.
            if (frames > 0) switch (frame.after(d.in[d.ip..])) {
                .frame => {},
                .cut => return d.fail(d.ip, .truncated, error.Truncated),
                .trailing => return d.fail(d.ip, .trailing_data, error.InvalidStream),
            };
            const parsed = try frame.parse(d.in[d.ip..], d.options.diagnostic, d.ip);
            switch (parsed) {
                .skippable => |s| {
                    if (d.in.len - d.ip - 8 < s.len) return d.fail(d.ip, .truncated, error.Truncated);
                    d.ip += 8 + s.len;
                    // A skippable frame alone at the end is a complete input.
                    if (d.ip == d.in.len and frames == 0) return .{ .in_len = d.ip, .out_len = d.op, .finished = true };
                    continue;
                },
                .legacy => {
                    if (!try d.legacy()) return .{ .in_len = d.ip, .out_len = d.op, .finished = false };
                },
                .standard => |s| {
                    if (!try d.standard(s.header, s.header_len)) return .{ .in_len = d.ip, .out_len = d.op, .finished = false };
                },
            }
            frames += 1;
        }
        return .{ .in_len = d.ip, .out_len = d.op, .finished = true };
    }

    /// One frame of LZ4 blocks; false where `partial` stopped it.
    fn standard(d: *Decoder, h: frame.Header, header_len: usize) Error!bool {
        const frame_at = d.ip;
        if (h.dictionary_id) |id| {
            if (d.options.dictionary.len == 0) return d.fail(frame_at, .dictionary_mismatch, error.DictionaryMismatch);
            if (d.options.dictionary_id) |want| if (want != id) return d.fail(frame_at, .dictionary_mismatch, error.DictionaryMismatch);
        }
        const block_max = h.block_size.bytes();
        if (aegis.units.Bytes(usize).fromRaw(block_max).compare(d.options.max_block_size) == .gt) return d.fail(frame_at, .block_too_large, error.InvalidStream);
        const history = d.options.dictionary[d.options.dictionary.len -| block.max_offset..];
        d.ip += header_len;
        const frame_out = d.op;
        var content: std.hash.XxHash32 = .init(0);
        while (true) {
            if (d.in.len - d.ip < 4) return d.fail(d.ip, .truncated, error.Truncated);
            const head = d.in[d.ip..][0..4];
            if (frame.BlockHeader.isEnd(head)) {
                d.ip += 4;
                break;
            }
            const bh = frame.BlockHeader.read(head);
            const block_at = d.ip;
            if (bh.len > block_max) return d.fail(block_at, .block_too_large, error.InvalidStream);
            const tail: usize = if (h.block_checksum) 4 else 0;
            if (d.in.len - d.ip - 4 < @as(usize, bh.len) + tail) return d.fail(block_at, .truncated, error.Truncated);
            const data = d.in[d.ip + 4 ..][0..bh.len];
            if (h.block_checksum and d.options.verify_checksum) {
                const want = std.mem.readInt(u32, d.in[d.ip + 4 + bh.len ..][0..4], .little);
                if (std.hash.XxHash32.hash(0, data) != want) return d.fail(block_at, .block_checksum, error.ChecksumMismatch);
            }
            const start = d.op;
            if (bh.uncompressed) {
                if (!d.stored(data)) return false;
            } else {
                // Linked blocks reach back through the frame's output; every
                // block starts after the dictionary.
                const origin = if (h.independent) start else frame_out;
                if (!try d.decodeBlock(data, origin, block_max, history, d.ip + 4)) return false;
            }
            if (h.content_checksum) content.update(d.out[start..d.op]);
            d.ip += 4 + bh.len + tail;
        }
        if (h.content_size) |n| if (n != d.op - frame_out) return d.fail(frame_at, .content_size, error.InvalidStream);
        if (h.content_checksum) {
            if (d.in.len - d.ip < 4) return d.fail(d.ip, .truncated, error.Truncated);
            const want = std.mem.readInt(u32, d.in[d.ip..][0..4], .little);
            if (d.options.verify_checksum and content.final() != want) return d.fail(d.ip, .content_checksum, error.ChecksumMismatch);
            d.ip += 4;
        }
        return true;
    }

    /// A legacy frame: 8 MiB blocks until the input ends or a frame starts;
    /// false where `partial` stopped it.
    fn legacy(d: *Decoder) Error!bool {
        d.ip += 4;
        while (d.ip < d.in.len) {
            if (d.in.len - d.ip < 4) return d.fail(d.ip, .truncated, error.Truncated);
            const len = std.mem.readInt(u32, d.in[d.ip..][0..4], .little);
            // Past the largest block: the next frame's magic.
            if (len > frame.legacy_block_max) break;
            if (d.in.len - d.ip - 4 < len) return d.fail(d.ip, .truncated, error.Truncated);
            if (!try d.decodeBlock(d.in[d.ip + 4 ..][0..len], d.op, frame.legacy_block_len, &.{}, d.ip + 4)) return false;
            d.ip += 4 + len;
        }
        return true;
    }

    /// A stored block; false where `partial` stopped it.
    fn stored(d: *Decoder, data: []const u8) bool {
        const n = @min(data.len, d.out.len - d.op);
        @memcpy(d.out[d.op..][0..n], data[0..n]);
        d.op += n;
        return n == data.len;
    }

    /// Decode a block into the output after `origin`, at most `block_max`
    /// bytes of it; false where `partial` stopped it.
    fn decodeBlock(d: *Decoder, data: []const u8, origin: usize, block_max: usize, history: []const u8, at: usize) Error!bool {
        const limit = @min(d.out.len, d.op + block_max);
        const r = block.decode(data, d.out[origin..limit], d.op - origin, .{
            .history = history,
            .partial = d.options.partial and limit == d.out.len,
            .diagnostic = d.options.diagnostic,
            .in_base = at,
        }) catch |err| switch (err) {
            error.OutputTooSmall => {
                if (limit < d.out.len or d.out.len - d.op >= block_max) return d.fail(at, .block_too_large, error.InvalidStream);
                // A partial decode stops at a full output.
                if (d.options.partial) aegis.assert.never("a partial decode stops at a full output");
                return error.OutputTooSmall;
            },
            else => |e| return e,
        };
        d.op += r.written.len;
        return r.finished;
    }

    fn fail(d: *Decoder, at: usize, why: Diagnostic.Reason, err: Error) Error {
        if (d.options.diagnostic) |diag| diag.* = .{ .offset = .fromRaw(at), .reason = why };
        return err;
    }
};
