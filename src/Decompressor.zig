//! Whole-buffer decoding of raw DEFLATE, zlib and gzip: the stream is
//! decoded straight into the caller's output, which is its own history.
//!
//! A `Decompressor` holds only decoding tables (about 11 KiB), no stream:
//! one serves any number of calls, any container. Nothing is allocated.

const Decompressor = @This();

const std = @import("std");
const Io = std.Io;
const inflate_ = @import("inflate.zig");
const container = @import("container.zig");
const unwrap = @import("unwrap.zig");
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

    pub fn commit(_: *ReaderSource, _: *inflate_.Stream) void {}
};

/// The whole stream, every member when asked, in one pass of the machine.
fn run(d: *Decompressor, s: *inflate_.Stream, source: anytype, options: Options) InflateError!Result {
    var state: unwrap.State = .{};
    const machine: unwrap.Options = .{ .accept = options.accept, .dictionary = options.dictionary, .members = options.members };
    while (true) {
        switch (try unwrap.run(&d.tables, &state, s, source, machine)) {
            .block_end => {},
            .done => return finish(s, true),
            .output_full => return finish(s, false),
            .member_end => {
                // Another member, or the end of the input.
                s.need(source, 8);
                if (s.bitsleft < 8 * (s.virtual + 1)) return finish(s, true);
            },
        }
    }
}

/// The result at the end, or a partial stop.
fn finish(s: *inflate_.Stream, finished: bool) Result {
    // Whole bytes still in the bit buffer were not used.
    return .{ .in_len = @intCast(s.in_base + s.ip - s.bitsleft / 8), .out_len = s.op, .finished = finished };
}
