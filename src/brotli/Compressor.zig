//! Whole-buffer Brotli compression: one stream from one input, as the
//! reference's `BrotliEncoderCompress` writes it, the same bytes for the
//! same parameters.

const Compressor = @This();

const std = @import("std");
const encode = @import("encode.zig");
const settings = @import("settings.zig");

pub const Mode = settings.Mode;

pub const Options = settings.Options;

pub const Error = std.mem.Allocator.Error || error{
    /// `out` cannot hold the stream; `bound(in.len)` always can.
    OutputTooSmall,
};

gpa: std.mem.Allocator,
options: Options,

pub fn init(gpa: std.mem.Allocator, options: Options) Compressor {
    return .{ .gpa = gpa, .options = options };
}

pub fn deinit(c: *Compressor) void {
    c.* = undefined;
}

/// The largest stream an input of `len` bytes compresses to.
pub fn bound(len: usize) usize {
    return encode.maxCompressedSize(len);
}

/// Compress `in` into `out`; returns the stream's length.
pub fn compress(c: *Compressor, in: []const u8, out: []u8) Error!usize {
    if (out.len == 0) return error.OutputTooSmall;
    if (in.len == 0) {
        out[0] = 6;
        return 1;
    }
    const o = c.options;
    const max_out = bound(in.len);
    var e: encode.Encoder = try .init(c.gpa, o.params(in.len), o.dictionary);
    defer e.deinit();
    var rest = in;
    var room = out;
    const finished = blk: {
        e.compressStream(.finish, &rest, &room) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.InvalidOperation => break :blk false,
        };
        break :blk e.isFinished();
    };
    const written = out.len - room.len;
    if (finished and written <= max_out) return written;
    // The reference's fallback: the input stored, if it fits.
    if (out.len < max_out) return error.OutputTooSmall;
    return encode.uncompressedStream(in, out);
}
