//! Whole-buffer decoding of raw DEFLATE, zlib and gzip: the stream is
//! decoded straight into the caller's output, which is its own history.
//!
//! A `Decompressor` holds only decoding tables (about 11 KiB), no stream:
//! one serves any number of calls, any container. Nothing is allocated.

const Decompressor = @This();

const std = @import("std");
const Io = std.Io;
const inflate_ = @import("inflate.zig");
const checksum = @import("checksum.zig");
const container = @import("container.zig");
const gzip = @import("gzip.zig");
const Diagnostic = @import("Diagnostic.zig");

/// Private: the current block's tables.
tables: inflate_.Tables = .{},

pub const init: Decompressor = .{};

pub const Options = struct {
    accept: container.Accept = .zlib,
    /// Bytes that precede the output as history: what a raw stream may
    /// reach back into, and what a zlib stream with FDICT must name by its
    /// Adler-32. A zlib stream without FDICT ignores it.
    dictionary: []const u8 = &.{},
    members: container.Members = .all,
    /// Stop without error when `out` is full; `Result.finished` is then
    /// false.
    partial: bool = false,
    diagnostic: ?*Diagnostic = null,
};

pub const Result = struct {
    /// Input bytes the stream took, its trailer included; what follows a
    /// raw or zlib stream is not read.
    in_len: usize,
    /// Output bytes written.
    out_len: usize,
    /// The stream ended (always, unless `partial` stopped it).
    finished: bool,
};

pub const InflateError = error{
    /// Not a stream of the container accepted, or one that breaks
    /// DEFLATE's rules as zlib 1.3.1 reads them.
    InvalidStream,
    /// The Adler-32, CRC-32 or length in a trailer, or a gzip header CRC,
    /// is not the data's.
    ChecksumMismatch,
    /// A zlib stream names a dictionary other than the one given.
    DictionaryMismatch,
    /// The input ends inside the stream.
    Truncated,
    /// The stream decodes to more than `out` holds.
    OutputTooSmall,
};

/// Decode `in` into `out`. Bytes of `out` past `Result.out_len` may have
/// been written and are scratch afterwards. With `out.len >= expected +
/// inflate_margin` the fast loop runs to the end of the stream.
pub fn inflate(d: *Decompressor, in: []const u8, out: []u8, options: Options) InflateError!Result {
    var s: inflate_.Stream = .{ .in = in, .ip = 0, .out = out, .op = 0, .start = 0, .partial = options.partial, .diagnostic = options.diagnostic };
    return run(d, &s, inflate_.no_more, options);
}

pub const InflateReaderError = InflateError || error{ReadFailed};

/// Decode from `r`'s buffer, refilling it, into `out`. What the stream did
/// not use stays in `r`. A reader that refills needs a buffer of 16 bytes
/// or more: the bytes the decoder has read ahead stay in it while it
/// refills.
pub fn inflateReader(d: *Decompressor, r: *Io.Reader, out: []u8, options: Options) InflateReaderError!Result {
    var source: ReaderSource = .{ .r = r };
    var s: inflate_.Stream = .{ .in = r.buffered(), .ip = 0, .out = out, .op = 0, .start = 0, .partial = options.partial, .diagnostic = options.diagnostic };
    const result = run(d, &s, &source, options) catch |err| {
        if (source.failed) return error.ReadFailed;
        return err;
    };
    // Hand back what the bit buffer holds unconsumed.
    r.toss(s.ip - s.bitsleft / 8);
    return result;
}

/// A reader's buffer as the engine's input: consumed bytes are tossed and
/// whole unconsumed bytes handed back before the buffer is refilled, so
/// the bit buffer never holds a byte the reader lost.
const ReaderSource = struct {
    r: *Io.Reader,
    ended: bool = false,
    failed: bool = false,

    pub fn more(src: *ReaderSource, s: *inflate_.Stream) bool {
        if (src.ended) return false;
        const back = s.bitsleft / 8;
        const used = s.ip - back;
        src.r.toss(used);
        s.in_base += used;
        s.bitsleft &= 7;
        s.bitbuf &= (@as(u64, 1) << @intCast(s.bitsleft)) - 1;
        const before = src.r.bufferedLen();
        src.r.fillMore() catch |err| switch (err) {
            error.EndOfStream => src.ended = true,
            error.ReadFailed => {
                src.ended = true;
                src.failed = true;
            },
        };
        s.in = src.r.buffered();
        s.ip = 0;
        return s.in.len > before or back > 0;
    }
};

fn run(d: *Decompressor, s: *inflate_.Stream, source: anytype, options: Options) InflateError!Result {
    s.need(source, 16);
    var first: [2]u8 = .{ @truncate(s.bitbuf), @truncate(s.bitbuf >> 8) };
    const real = @min(2, s.bitsleft / 8 - s.virtual);
    const kind = container.detect(options.accept, first[0..real]);
    switch (kind) {
        .raw => {
            s.dictionary = options.dictionary;
            const status = try inflate_.decode(&d.tables, s, source);
            return finish(s, status == .done);
        },
        .zlib => return zlib(d, s, source, options),
        .gzip => return gzipMembers(d, s, source, options),
    }
}

/// The result at the end, or a partial stop.
fn finish(s: *inflate_.Stream, finished: bool) Result {
    // Whole bytes still in the bit buffer were not used.
    return .{ .in_len = @intCast(s.in_base + s.ip - s.bitsleft / 8), .out_len = s.op, .finished = finished };
}

fn zlib(d: *Decompressor, s: *inflate_.Stream, source: anytype, options: Options) InflateError!Result {
    const header = try s.take(source, 16);
    const cmf: u8 = @truncate(header);
    const flg: u8 = @truncate(header >> 8);
    if ((@as(u16, cmf) << 8 | flg) % 31 != 0 or cmf & 15 != 8 or cmf >> 4 > 7) return s.fail(.bad_zlib_header);
    if (flg & 0x20 != 0) {
        var id: u32 = 0;
        for (0..4) |_| id = id << 8 | try s.take(source, 8);
        if (options.dictionary.len == 0) return s.fail(.dictionary_required);
        if (checksum.adler32(1, options.dictionary) != id) {
            if (options.diagnostic) |diag| diag.* = .{ .bit_offset = s.bitOffset(), .reason = .dictionary_mismatch };
            return error.DictionaryMismatch;
        }
        s.dictionary = options.dictionary;
    }
    const status = try inflate_.decode(&d.tables, s, source);
    if (status == .output_full) return finish(s, false);
    s.consume(@intCast(s.bitsleft & 7));
    var want: u32 = 0;
    for (0..4) |_| want = want << 8 | try s.take(source, 8);
    if (checksum.adler32(1, s.out[0..s.op]) != want) return mismatch(s, .adler32);
    return finish(s, true);
}

fn gzipMembers(d: *Decompressor, s: *inflate_.Stream, source: anytype, options: Options) InflateError!Result {
    while (true) {
        const start = s.op;
        var src: StreamSource(@TypeOf(source)) = .{ .s = s, .source = source };
        _ = try gzip.parse(@TypeOf(src), &src, gzip.skip);
        // Members are independent streams: no distance reaches before one.
        s.start = start;
        const status = try inflate_.decode(&d.tables, s, source);
        if (status == .output_full) return finish(s, false);
        s.consume(@intCast(s.bitsleft & 7));
        // Each check as soon as its bytes are read, as zlib makes them.
        if (checksum.crc32(0, s.out[start..s.op]) != try takeLittle(s, source)) return mismatch(s, .crc32);
        const size = try takeLittle(s, source);
        // safe: ISIZE is the length modulo 2^32
        if (@as(u32, @truncate(s.op - start)) != size) return mismatch(s, .size);
        if (options.members == .one) return finish(s, true);
        // Another member, or the end; anything else is refused.
        s.need(source, 8);
        if (s.bitsleft < 8 * (s.virtual + 1)) return finish(s, true);
        s.need(source, 16);
        const magic = s.peek(16);
        if (magic & 0xff != 0x1f or (s.bitsleft >= 8 * (s.virtual + 2) and magic >> 8 != 0x8b)) return s.fail(.trailing_data);
    }
}

fn takeLittle(s: *inflate_.Stream, source: anytype) inflate_.Error!u32 {
    var v: u32 = 0;
    for (0..4) |i| v |= try s.take(source, 8) << @intCast(8 * i);
    return v;
}

fn mismatch(s: *inflate_.Stream, reason: Diagnostic.Reason) InflateError {
    if (s.diagnostic) |diag| diag.* = .{ .bit_offset = s.bitOffset(), .reason = reason };
    return error.ChecksumMismatch;
}

/// The engine's stream as a byte source for the gzip header parser.
fn StreamSource(comptime Source: type) type {
    return struct {
        s: *inflate_.Stream,
        source: Source,

        const Self = @This();
        pub const Error = InflateError;

        pub fn byte(src: *Self) Error!u8 {
            return @intCast(try src.s.take(src.source, 8));
        }

        pub fn invalid(src: *Self, reason: Diagnostic.Reason) Error {
            if (reason == .header_crc) return mismatch(src.s, .header_crc);
            return src.s.fail(reason);
        }
    };
}
