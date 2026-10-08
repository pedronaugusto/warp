//! Whole-buffer zstd decoding: frames decoded straight into the caller's
//! output, which is their own history.
//!
//! A `Decompressor` holds decoding tables and literal scratch (under 96 KiB),
//! no stream: one serves any number of calls. Nothing is allocated. Acceptance is the
//! format's reference decoder's (zstd 1.5.7): what it decodes, this
//! decodes, and what it refuses, this refuses for the same reason.

const Decompressor = @This();

const std = @import("std");
const Io = std.Io;
const decode = @import("decode.zig");
const frame = @import("frame.zig");
const Dictionary = @import("Dictionary.zig");
const Diagnostic = @import("Diagnostic.zig");

/// Private: the tables of the block being decoded.
tables: decode.Tables,
literals: [(64 << 10) + decode.margin]u8,

pub const init: Decompressor = .{ .tables = undefined, .literals = undefined };

/// How many frames a decoder reads.
pub const Frames = enum {
    /// The first zstd frame (skippable frames before it are skipped); what
    /// follows it is left unread.
    one,
    /// Every frame, skippable ones skipped; anything after the last that
    /// is not a frame is refused.
    all,
};

pub const Options = struct {
    /// Dictionaries a frame may name by ID; a frame naming none uses the
    /// first, if any.
    dictionaries: []const *const Dictionary = &.{},
    frames: Frames = .all,
    /// Stop without error when `out` is full; `Result.finished` is then
    /// false and the output so far is a prefix of the content. Raw and RLE
    /// and compressed blocks fill `out` to its end.
    partial: bool = false,
    /// Check content checksums where frames carry them.
    verify_checksum: bool = true,
    /// Largest accepted frame window.
    max_window: u64 = 1 << 27,
    format: frame.Format = .standard,
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
    /// Not zstd frames, or frames that break the format as the reference
    /// decoder reads it.
    InvalidStream,
    /// A content checksum is not the content's.
    ChecksumMismatch,
    /// A frame names a dictionary that was not given.
    DictionaryMismatch,
    /// A frame declares a window larger than 2^31 bytes (2^30 on 32-bit
    /// targets).
    WindowTooLarge,
    /// The input ends inside a frame.
    Truncated,
    /// The frames decode to more than `out` holds.
    OutputTooSmall,
};

/// Decode the frames of `in` into `out`. Bytes of `out` past
/// `Result.out_len` may have been written and are scratch afterwards.
pub fn decompress(d: *Decompressor, in: []const u8, out: []u8, options: Options) Error!Result {
    var source: SliceSource = .{ .in = in };
    return d.run(&source, out, options);
}

/// A reader's buffer that holds the largest block plus its header.
pub const reader_buffer_min = decode.block_max + 32;

pub const ReaderError = Error || error{ReadFailed};

/// Decode frames from `r` into `out`; what follows them stays in `r`.
/// `r`'s buffer holds at least `reader_buffer_min` bytes, or the whole
/// input.
pub fn decompressReader(d: *Decompressor, r: *Io.Reader, out: []u8, options: Options) ReaderError!Result {
    var source: ReaderSource = .{ .r = r };
    return d.run(&source, out, options) catch |err| {
        if (source.failed) return error.ReadFailed;
        return err;
    };
}

/// Input bytes from a slice.
const SliceSource = struct {
    in: []const u8,
    pos: usize = 0,

    /// The next `n` bytes, or null if fewer remain.
    fn bytes(s: *SliceSource, n: usize) ?[]const u8 {
        if (s.in.len - s.pos < n) return null;
        return s.in[s.pos..][0..n];
    }

    /// Up to `n` bytes: what remains if fewer.
    fn upTo(s: *SliceSource, n: usize) []const u8 {
        return s.in[s.pos..][0..@min(n, s.in.len - s.pos)];
    }

    fn advance(s: *SliceSource, n: usize) void {
        s.pos += n;
    }

    fn available(s: *const SliceSource, n: usize) bool {
        return s.in.len - s.pos >= n;
    }

    fn offset(s: *const SliceSource) usize {
        return s.pos;
    }

    fn copy(s: *SliceSource, dst: []u8) bool {
        const src = s.bytes(dst.len) orelse return false;
        @memcpy(dst, src);
        s.pos += dst.len;
        return true;
    }
};

/// Input bytes from a reader's buffer.
const ReaderSource = struct {
    r: *Io.Reader,
    pos: usize = 0,
    failed: bool = false,

    fn bytes(s: *ReaderSource, n: usize) ?[]const u8 {
        return s.r.peek(n) catch |err| {
            if (err == error.ReadFailed) s.failed = true;
            return null;
        };
    }

    fn upTo(s: *ReaderSource, n: usize) []const u8 {
        s.r.fill(n) catch |err| switch (err) {
            error.EndOfStream => {},
            error.ReadFailed => {
                s.failed = true;
                return &.{};
            },
        };
        const buffered = s.r.buffered();
        return buffered[0..@min(n, buffered.len)];
    }

    fn advance(s: *ReaderSource, n: usize) void {
        s.r.toss(n);
        s.pos += n;
    }

    /// Whether `n` more bytes are there; past the buffer's capacity it
    /// cannot tell without reading them, and says yes.
    fn available(s: *ReaderSource, n: usize) bool {
        if (n > s.r.buffer.len) return true;
        return s.bytes(n) != null;
    }

    fn offset(s: *const ReaderSource) usize {
        return s.pos;
    }

    fn copy(s: *ReaderSource, dst: []u8) bool {
        s.r.readSliceAll(dst) catch |err| {
            if (err == error.ReadFailed) s.failed = true;
            return false;
        };
        s.pos += dst.len;
        return true;
    }
};

fn fail(options: Options, err: Error, offset: usize, reason: Diagnostic.Reason) Error {
    if (options.diagnostic) |diag| diag.* = .{ .offset = offset, .reason = reason };
    return err;
}

fn run(d: *Decompressor, source: anytype, out: []u8, options: Options) Error!Result {
    var op: usize = 0;
    var frames: usize = 0;
    const prefix: usize = if (options.format == .standard) 5 else 1;
    while (true) {
        const at = source.offset();
        const head = source.upTo(prefix);
        if (head.len == 0) {
            if (frames == 0 and options.frames == .one) return fail(options, error.Truncated, at, .truncated);
            break;
        }
        if (head.len < prefix) {
            // Fewer bytes than any frame starts with.
            return fail(options, error.Truncated, at, if (frames == 0) .truncated else .trailing_data);
        }
        var fault: frame.Fault = undefined;
        const header_bytes = source.upTo(18);
        const parsed = frame.parse(header_bytes, options.format, &fault) catch |err| switch (err) {
            error.Truncated => return fail(options, error.Truncated, at + fault.offset, .truncated),
            error.WindowTooLarge => return fail(options, error.WindowTooLarge, at + fault.offset, fault.reason),
            error.InvalidStream => return fail(options, error.InvalidStream, at + fault.offset, if (frames != 0 and fault.reason == .bad_magic) .trailing_data else fault.reason),
        };
        switch (parsed) {
            .skippable => |s| {
                // The reference refuses a length that overflows with the header's.
                if (s.len > std.math.maxInt(u32) - 8) return fail(options, error.InvalidStream, at, .bad_magic);
                source.advance(8);
                var left: u64 = s.len;
                while (left > 0) {
                    const n: usize = @intCast(@min(left, 1 << 16));
                    const chunk = source.upTo(n);
                    if (chunk.len == 0) return fail(options, error.Truncated, at, .truncated);
                    source.advance(chunk.len);
                    left -= chunk.len;
                }
                continue;
            },
            .zstd => |header| {
                if (header.window_size > options.max_window) return fail(options, error.WindowTooLarge, at, .window_too_large);
                source.advance(header.header_len);
                const status = try d.decodeFrame(source, header, out, &op, options, at);
                frames += 1;
                if (status == .stopped) return .{ .in_len = source.offset(), .out_len = op, .finished = false };
                if (options.frames == .one) break;
            },
        }
    }
    return .{ .in_len = source.offset(), .out_len = op, .finished = true };
}

const Status = enum { done, stopped };

fn decodeFrame(d: *Decompressor, source: anytype, header: frame.Header, out: []u8, op: *usize, options: Options, at: usize) Error!Status {
    var dict: ?*const Dictionary = null;
    if (header.dictionary_id != 0) {
        for (options.dictionaries) |candidate| {
            if (candidate.id == header.dictionary_id) {
                dict = candidate;
                break;
            }
        }
        if (dict == null) return fail(options, error.DictionaryMismatch, at, .dictionary_mismatch);
    } else if (options.dictionaries.len != 0) {
        dict = options.dictionaries[0];
    }
    const start = op.*;
    var f: decode.Frame = .{
        .tables = &d.tables,
        .literal_buffer = &d.literals,
        .entropy = if (dict) |x| x.startEntropy() else .{},
        .out = out,
        .start = start,
        .dict = if (dict) |x| x.content else &.{},
        .block_max = header.blockMax(),
    };
    const verify = header.checksum and options.verify_checksum;
    var hash: std.hash.XxHash64 = .init(0);
    while (true) {
        const block_at = source.offset();
        const bh = source.bytes(3) orelse return fail(options, error.Truncated, block_at, .truncated);
        const b = frame.blockHeader(bh[0..3]);
        source.advance(3);
        const before = op.*;
        switch (b.kind) {
            .raw => {
                const room = out.len - op.*;
                if (b.size > room) {
                    if (!options.partial) {
                        if (!source.available(b.size)) return fail(options, error.Truncated, block_at, .truncated);
                        return fail(options, error.OutputTooSmall, block_at, .truncated);
                    }
                    if (!source.copy(out[op.*..][0..room])) return fail(options, error.Truncated, block_at, .truncated);
                    op.* += room;
                    return .stopped;
                }
                if (!source.copy(out[op.*..][0..b.size])) return fail(options, error.Truncated, block_at, .truncated);
                op.* += b.size;
            },
            .rle => {
                const byte = source.bytes(1) orelse return fail(options, error.Truncated, block_at, .truncated);
                const room = out.len - op.*;
                if (b.regenerated > room) {
                    if (!options.partial) return fail(options, error.OutputTooSmall, block_at, .truncated);
                    @memset(out[op.*..], byte[0]);
                    op.* = out.len;
                    source.advance(1);
                    return .stopped;
                }
                @memset(out[op.*..][0..b.regenerated], byte[0]);
                source.advance(1);
                op.* += b.regenerated;
            },
            .compressed => {
                if (b.size > f.block_max) return fail(options, error.InvalidStream, block_at, .block_too_large);
                const content = source.bytes(b.size) orelse return fail(options, error.Truncated, block_at, .truncated);
                const decoded = if (options.partial) f.blockPartial(content, op.*) else f.block(content, op.*);
                const n = decoded catch |err| {
                    if (err == error.OutputTooSmall and options.partial) return .stopped;
                    return fail(options, err, block_at + 3 + f.fault.offset, f.fault.reason);
                };
                source.advance(b.size);
                op.* += n;
                if (f.stopped) return .stopped;
            },
            .reserved => return fail(options, error.InvalidStream, block_at, .bad_block_type),
        }
        if (verify) hash.update(out[before..op.*]);
        if (b.last) break;
    }
    if (header.content_size) |size| {
        if (op.* - start != size) return fail(options, error.InvalidStream, at, .content_size);
    }
    if (header.checksum) {
        const sum_at = source.offset();
        // A frame cut inside its checksum is cut, though the reference
        // decoder calls it a wrong checksum.
        const sum = source.bytes(4) orelse return fail(options, error.Truncated, sum_at, .truncated);
        if (verify and std.mem.readInt(u32, sum[0..4], .little) != @as(u32, @truncate(hash.final()))) {
            return fail(options, error.ChecksumMismatch, sum_at, .checksum);
        }
        source.advance(4);
    }
    return .done;
}
