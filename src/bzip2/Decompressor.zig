//! Whole-buffer bzip2 decoding: streams decoded straight into the caller's
//! output.
//!
//! A `Decompressor` holds the largest block's BWT vector (900,000 entries,
//! 3.5 MiB) and its code tables, taken once; a call allocates nothing.
//! Acceptance is the format reference's (libbz2 1.0.8): what it decodes,
//! this decodes, and what it refuses, this refuses for the same reason.

const Decompressor = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const decode = @import("decode.zig");
const bits = @import("bits.zig");
const Diagnostic = @import("Diagnostic.zig");

/// Private: the BWT vector.
tt: []u32,
/// Private: the code tables and the stream's state.
tables: decode.Tables,
state: decode.State,
/// Private: the memory `init` allocated; empty after `initBuffer`.
owned: []u32,
/// Private: the allocator of `owned`.
gpa: Allocator,

/// How many streams a decoder reads.
pub const Streams = enum {
    /// The first stream; what follows it is left unread (`Result.in_len`).
    one,
    /// Streams one after another while the input goes on with a stream
    /// header, each decoded on its own, as `bzip2 -d` reads concatenated
    /// streams; it stops before anything else (`Result.in_len`).
    all,
};

pub const Options = struct {
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
    /// Not a bzip2 stream, or one that breaks the format as 1.0.8 reads it.
    InvalidStream,
    /// A block's or a stream's CRC does not match.
    ChecksumMismatch,
    /// The input ends inside a stream.
    Truncated,
    /// The streams decode to more than `out` holds.
    OutputTooSmall,
};

/// The bytes `initBuffer` needs.
pub const memory = decode.block_max * @sizeOf(u32);

pub fn init(gpa: Allocator) Allocator.Error!Decompressor {
    const tt = try gpa.alloc(u32, decode.block_max);
    var d = initBuffer(std.mem.sliceAsBytes(tt)) catch unreachable; // unreachable: tt is memory bytes
    d.owned = tt;
    d.gpa = gpa;
    return d;
}

/// A decompressor over caller memory aligned to 4, refused when shorter
/// than `memory`.
pub fn initBuffer(buffer: []align(4) u8) error{BufferTooSmall}!Decompressor {
    if (buffer.len < memory) return error.BufferTooSmall;
    return .{ .tt = std.mem.bytesAsSlice(u32, buffer[0..memory]), .tables = undefined, .state = .{}, .owned = &.{}, .gpa = undefined };
}

pub fn deinit(d: *Decompressor) void {
    if (d.owned.len != 0) d.gpa.free(d.owned);
    d.* = undefined;
}

/// Decode the streams of `in` into `out`. Bytes of `out` past
/// `Result.out_len` may have been written and are scratch afterwards.
pub fn decompress(d: *Decompressor, in: []const u8, out: []u8, options: Options) Error!Result {
    var r: bits.Reader = .{ .in = in };
    var op: usize = 0;
    while (true) {
        d.state = .{};
        const status = decode.run(&d.state, .{ .tt = d.tt, .tables = &d.tables }, &r, out, &op) catch |err| switch (err) {
            error.NeedInput => return fail(options, error.Truncated, r.bitOffset(), .truncated),
            error.InvalidStream, error.ChecksumMismatch => |e| return fail(options, e, d.state.fail_bit, d.state.reason),
        };
        if (status == .output_full) return error.OutputTooSmall;
        // A stream ends at a byte boundary.
        const at: usize = @intCast(r.bitOffset() / 8);
        if (options.streams == .one) return .{ .in_len = at, .out_len = op };
        switch (next(in[at..])) {
            .stream => {},
            .end => return .{ .in_len = at, .out_len = op },
            .truncated => return fail(options, error.Truncated, 8 * @as(u64, in.len), .truncated),
        }
    }
}

/// What follows a stream: another (its header whole), the end of the
/// streams (nothing, or bytes that are no stream header, which `bzip2 -d`
/// ignores), or a stream header cut short.
pub fn next(rest: []const u8) enum { stream, end, truncated } {
    const header = "BZh";
    if (rest.len == 0) return .end;
    const n = @min(rest.len, header.len);
    if (!std.mem.eql(u8, rest[0..n], header[0..n])) return .end;
    if (rest.len <= header.len) return .truncated;
    return if (rest[3] >= '1' and rest[3] <= '9') .stream else .end;
}

fn fail(options: Options, err: Error, bit: u64, reason: Diagnostic.Reason) Error {
    if (options.diagnostic) |diag| diag.* = .{ .bit_offset = .fromRaw(bit), .reason = reason };
    return err;
}
