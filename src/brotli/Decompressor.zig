//! Whole-buffer Brotli decoding: streams decoded straight into the caller's
//! output, which is their own history.
//!
//! A `Decompressor` holds the prefix code tables and context maps a
//! meta-block can need at the format's worst case (about 1.3 MiB); a stream
//! touches only the part its meta-blocks use, so pages it never reaches
//! are never written. It holds no stream: one serves any number of calls.
//! Nothing is allocated. Acceptance is the format reference's (google/brotli
//! 1.2.1): what it decodes, this decodes, and what it refuses, this refuses
//! for the same reason.

const Decompressor = @This();

const decode = @import("decode.zig");
const bits = @import("bits.zig");
const Diagnostic = @import("Diagnostic.zig");

/// Private: the tables of the meta-block being decoded.
tables: decode.Tables,

pub const init: Decompressor = .{ .tables = undefined };

/// How many streams a decoder reads.
pub const Streams = enum {
    /// The first stream; what follows it is left unread (`Result.in_len`).
    one,
    /// Streams one after another until the input ends, each decoded on its
    /// own (no history across them), as `brotli -d` reads concatenated
    /// streams.
    all,
};

pub const Options = struct {
    /// Bytes before the output that distances reach past it into (RFC
    /// 9842's dictionary-compressed Brotli), the reference's raw
    /// ("compound") dictionary.
    dictionary: []const u8 = &.{},
    /// Accept the large-window extension (window up to 2^30, not RFC 7932;
    /// the reference's `BROTLI_DECODER_PARAM_LARGE_WINDOW`); refused
    /// otherwise.
    large_window: bool = false,
    streams: Streams = .all,
    diagnostic: ?*Diagnostic = null,
};

pub const Result = struct {
    /// Input bytes the streams took; what follows them is not read.
    in_len: usize,
    /// Output bytes written.
    out_len: usize,
};

pub const Error = error{
    /// Not a Brotli stream, or one that breaks the format as the reference
    /// decoder reads it.
    InvalidStream,
    /// The input ends inside a stream.
    Truncated,
    /// The streams decode to more than `out` holds.
    OutputTooSmall,
};

/// Decode the streams of `in` into `out`. Bytes of `out` past
/// `Result.out_len` may have been written and are scratch afterwards.
pub fn decompress(d: *Decompressor, in: []const u8, out: []u8, options: Options) Error!Result {
    var r: bits.Reader = .{ .in = in };
    var h: decode.Linear = .{ .buf = out, .limit = out.len, .dict = options.dictionary };
    while (true) {
        var s: decode.State = .{ .large_window = options.large_window };
        const status = decode.run(&s, &d.tables, &r, &h) catch |err| switch (err) {
            error.InvalidStream => return fail(options, error.InvalidStream, s.fail_bit, s.reason),
            error.OutputTooSmall => return error.OutputTooSmall,
            error.WindowTooLarge => unreachable,
        };
        switch (status) {
            .need_input => return fail(options, error.Truncated, r.bitOffset(), .truncated),
            .output_full => unreachable,
            .done => {},
        }
        if (options.streams == .one or r.pos == in.len) return .{ .in_len = r.pos, .out_len = h.pos };
        h.start = h.pos;
    }
}

fn fail(options: Options, err: Error, bit: u64, reason: Diagnostic.Reason) Error {
    if (options.diagnostic) |diag| diag.* = .{ .bit_offset = .fromRaw(bit), .reason = reason };
    return err;
}
