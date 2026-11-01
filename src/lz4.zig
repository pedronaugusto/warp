//! LZ4: the block and frame formats, compressed and decompressed, at
//! lz4's levels, from its fast parser to LZ4-HC's optimal one.

const block = @import("lz4/block.zig");
const seq = @import("lz4/sequence.zig");

/// Where a block or frame was refused, and why.
pub const Diagnostic = @import("lz4/Diagnostic.zig");
/// Block and frame compression at one level band.
pub const Compressor = @import("lz4/Compressor.zig");

const frame_ = @import("lz4/frame.zig");
const decompress_ = @import("lz4/frames.zig");

/// The fastest level: acceleration 65537.
pub const min_level = Compressor.min_level;
/// The highest level; higher ones mean this.
pub const max_level = Compressor.max_level;
pub const default_level = Compressor.default_level;

/// What a frame's descriptor says.
pub const FrameHeader = frame_.Header;
/// A frame at the start of an input: LZ4, legacy or skippable.
pub const Frame = frame_.Frame;
/// The largest a frame's blocks decode to.
pub const BlockSize = frame_.BlockSize;
/// Frame inspection errors.
pub const FrameError = frame_.FrameError;

/// The frame header at the start of `in`.
pub fn frameHeader(in: []const u8) FrameError!Frame {
    return frame_.parse(in, null, 0);
}

/// Write a skippable frame of `payload`, magic variant 0-15.
pub const writeSkippable = frame_.writeSkippable;

/// How many frames `decompress` reads.
pub const Frames = decompress_.Frames;
pub const Options = decompress_.Options;
pub const Result = decompress_.Result;
pub const Error = decompress_.Error;

/// Decode the frames of `in` into `out`: LZ4 frames, legacy frames,
/// skippable frames skipped. Bytes of `out` past `Result.out_len` may have
/// been written.
pub const decompress = decompress_.decompress;

/// Resumable frame decoding and its `std.Io.Reader`.
pub const Decompress = @import("lz4/Decompress.zig");
/// Resumable frame compression, flushes, and its `std.Io.Writer`.
pub const Compress = @import("lz4/Compress.zig");

/// Spare output past a block's decoded size that lets the decoder's fast
/// loop run to its end; the exact size works too.
pub const decompress_margin = block.margin;
/// The longest block `len` bytes compress to.
pub const blockBound = seq.bound;

pub const BlockOptions = struct {
    /// Bytes before the output that matches may reach into: a dictionary,
    /// or the blocks before this one; the last 64 KiB count.
    history: []const u8 = &.{},
    /// Stop without error when `out` is full; `BlockResult.finished` is then
    /// false and the output so far is a prefix of the block's.
    partial: bool = false,
    diagnostic: ?*Diagnostic = null,
};

pub const BlockResult = struct {
    out_len: usize,
    /// The whole block was decoded (always, unless `partial` stopped it).
    finished: bool,
};

pub const BlockError = block.Error;

/// Decode the block `in`, the whole of it, into `out`. Bytes of `out` past
/// `BlockResult.out_len` may have been written.
pub fn decompressBlock(in: []const u8, out: []u8, options: BlockOptions) BlockError!BlockResult {
    const r = try block.decode(in, out, 0, .{
        .history = options.history[options.history.len -| block.max_offset..],
        .partial = options.partial,
        .diagnostic = options.diagnostic,
    });
    return .{ .out_len = r.written.len, .finished = r.finished };
}

test {
    _ = block;
    _ = seq;
    _ = frame_;
    _ = @import("lz4/fast.zig");
    _ = @import("lz4/hc.zig");
}
