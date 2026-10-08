//! Whole-buffer zstd compression over the shared encoder.
const Compressor = @This();
const std = @import("std");
const Encoder = @import("Encoder.zig");

/// Private: match tables, sequences, entropy and owned storage.
encoder: Encoder,

pub const Strategy = Encoder.Strategy;
pub const Tuning = Encoder.Tuning;
pub const Options = Encoder.Options;
pub const Frame = Encoder.Frame;
pub const CompressError = Encoder.CompressError;

/// The bytes `initBuffer` needs for `options`.
pub fn memory(options: Options) usize {
    return Encoder.memory(options);
}

pub fn init(gpa: std.mem.Allocator, options: Options) std.mem.Allocator.Error!Compressor {
    return .{ .encoder = try Encoder.init(gpa, options) };
}

/// A compressor in caller memory: `buffer.len >= memory(options)`.
pub fn initBuffer(buffer: []align(64) u8, options: Options) Compressor {
    return .{ .encoder = Encoder.initBuffer(buffer, options) };
}

pub fn deinit(c: *Compressor) void {
    c.encoder.deinit();
    c.* = undefined;
}

pub fn bound(len: usize) usize {
    return Encoder.bound(len);
}

/// One complete frame into `out`; returns its compressed length.
pub fn compress(c: *Compressor, in: []const u8, out: []u8, frame: Frame) CompressError!usize {
    return c.encoder.compress(in, out, frame);
}
