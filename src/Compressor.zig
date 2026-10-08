//! Whole-buffer compression to raw DEFLATE, zlib or gzip: one complete
//! stream per call, from memory taken once.
//!
//! The tables are sized when the compressor is made, and each call clears
//! only the part its input uses: a 37-byte input clears about 2 KiB.
//! Nothing is allocated per call.

const Compressor = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const bits = @import("bits.zig");
const deflate = @import("deflate.zig");
const container = @import("container.zig");
const checksum = @import("checksum.zig");
const gzip = @import("gzip.zig");

/// Private: the engine's tables.
engine: deflate.Engine,
/// Private: the options the tables were sized for.
options: Options,
/// Private: the memory `init` allocated, freed by `deinit`; empty after
/// `initBuffer`.
owned: []align(64) u8,
/// Private: the allocator of `owned`.
gpa: Allocator,

pub const Strategy = deflate.Strategy;

pub const Options = struct {
    /// 0 stored, 1-9 zlib's scale (aggregate size on the standard corpora
    /// no larger than zlib's), 10-12 the most compression; 13-15 mean 12.
    level: u4 = 6,
    strategy: Strategy = .default,
    /// The largest input `compress` will see: it sizes the tables. A larger
    /// input still compresses, with tables sized for this one. null sizes
    /// them for any input.
    max_input: ?usize = null,
    /// Cost-model passes at levels 10-12; null uses the level default.
    passes: ?u32 = null,
};

/// The bytes `initBuffer` needs for `options`.
pub fn memory(options: Options) usize {
    return deflate.Sizes.of(options.level, options.strategy, options.max_input).memory();
}

pub fn init(gpa: Allocator, options: Options) Allocator.Error!Compressor {
    const buffer = try gpa.alignedAlloc(u8, .@"64", memory(options));
    var c = initBuffer(buffer, options);
    c.owned = buffer;
    c.gpa = gpa;
    return c;
}

/// A compressor in caller memory: `buffer.len >= memory(options)`; `deinit`
/// then frees nothing.
pub fn initBuffer(buffer: []align(64) u8, options: Options) Compressor {
    const sizes = deflate.Sizes.of(options.level, options.strategy, options.max_input);
    std.debug.assert(buffer.len >= sizes.memory());
    return .{ .engine = .init(buffer, sizes), .options = options, .owned = &.{}, .gpa = undefined };
}

pub fn deinit(c: *Compressor) void {
    if (c.owned.len != 0) c.gpa.free(c.owned);
    c.* = undefined;
}

/// What surrounds the stream.
pub const Frame = struct {
    container: container.Container = .zlib,
    /// Bytes the stream may refer back into. A zlib stream names its
    /// Adler-32 (FDICT); a decoder needs the same bytes.
    dictionary: []const u8 = &.{},
    /// The gzip member header.
    gzip: gzip.Header = .{},
};

pub const CompressError = error{
    /// `out` is shorter than the stream; with `out.len >= bound(...)` this
    /// never happens.
    OutputTooSmall,
};

/// One complete stream of `in` into `out`; returns its length.
pub fn compress(c: *Compressor, in: []const u8, out: []u8, frame: Frame) CompressError!usize {
    var w: bits.Writer = .init(out, 0);
    const level = c.options.level;
    switch (frame.container) {
        .raw => {},
        .zlib => {
            var header: [6]u8 = undefined;
            const id: ?u32 = if (frame.dictionary.len != 0) checksum.adler32(1, frame.dictionary) else null;
            const n = container.zlibHeader(15, level, c.options.strategy == .huffman_only, id, &header);
            w.writeBytes(header[0..n]);
        },
        .gzip => {
            const header_len = gzip.headerLen(frame.gzip);
            if (out.len < header_len) return error.OutputTooSmall;
            var fixed: Writer = .fixed(out);
            gzip.writeHeader(&fixed, withXfl(frame.gzip, level)) catch return error.OutputTooSmall;
            w.at = header_len;
        },
    }
    c.engine.compressPasses(in, frame.dictionary, &w, level, c.options.strategy, c.options.passes);
    w.alignToByte();
    switch (frame.container) {
        .raw => {},
        .zlib => {
            var trailer: [4]u8 = undefined;
            std.mem.writeInt(u32, &trailer, checksum.adler32(1, in), .big);
            w.writeBytes(&trailer);
        },
        .gzip => {
            var trailer: [8]u8 = undefined;
            std.mem.writeInt(u32, trailer[0..4], checksum.crc32(0, in), .little);
            std.mem.writeInt(u32, trailer[4..8], @truncate(in.len), .little);
            w.writeBytes(&trailer);
        },
    }
    if (w.overflow) return error.OutputTooSmall;
    return w.at;
}

const Writer = std.Io.Writer;

/// gzip's extra flags as gzip(1) sets them, unless given.
fn withXfl(header: gzip.Header, level: u4) gzip.Header {
    var h = header;
    if (h.xfl == null) h.xfl = if (level >= 9) 2 else if (level == 1) 4 else 0;
    return h;
}

/// The longest stream `compress` writes for `in_len` bytes in `frame`.
pub fn bound(in_len: usize, frame: Frame) usize {
    // Stored blocks at worst: five bytes per 65,535 and per block the
    // parser may end early (at least every 5,000 bytes, once the input is
    // that long), and the bit writer's eight bytes of room.
    const blocks = in_len / 5000 + in_len / 65535 + 2;
    const wrapper: usize = switch (frame.container) {
        .raw => 0,
        .zlib => if (frame.dictionary.len != 0) 10 else 6,
        .gzip => gzip.headerLen(frame.gzip) + 8,
    };
    return in_len + 5 * blocks + 8 + wrapper;
}
