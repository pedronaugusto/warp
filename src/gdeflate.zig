//! GDeflate: DEFLATE with its bits dealt across 32 lanes, so a GPU decodes
//! 32 symbols at once, as DirectStorage and nvCOMP do. Pages of up to 64
//! KiB, each its own window; DirectStorage's tile stream holds them with
//! their offsets. Compressed by warp's DEFLATE engine at its levels, the
//! lanes laid out as the format's decoders read them; decoded here on the
//! CPU.

const std = @import("std");
const Allocator = std.mem.Allocator;
const decode = @import("gdeflate/decode.zig");
const lanes = @import("gdeflate/lanes.zig");
const deflate = @import("deflate.zig");

/// Where a page or tile stream was refused, and why.
pub const Diagnostic = @import("gdeflate/Diagnostic.zig");

/// The most a page holds, and every tile but the last.
pub const tile_size = 65536;
/// The tile stream's codec ID: DirectStorage's `DSTORAGE_COMPRESSION_FORMAT_GDEFLATE`.
pub const codec_id = 4;
/// The tile stream's header before its tile offsets.
pub const header_len = 8;
/// The most tiles a tile stream holds.
pub const max_tiles = 65535;

pub const Error = decode.Error;

/// What a tile stream's header says.
pub const Info = struct {
    tiles: u32,
    /// The bytes the tiles decode to.
    size: u64,
    /// The last tile's bytes: `tile_size`, or fewer.
    last_tile: u32,
};

pub const InspectError = error{
    /// Not a tile stream GDeflate's decoder reads.
    InvalidStream,
    /// The input ends inside the header or the offsets.
    Truncated,
};

/// The tile stream header at the start of `in`.
pub fn inspect(in: []const u8, diagnostic: ?*Diagnostic) InspectError!Info {
    if (in.len < header_len) return fail(diagnostic, 0, .truncated);
    if (in[0] != codec_id or in[1] != in[0] ^ 0xff) return fail(diagnostic, 0, .bad_magic);
    const tiles = std.mem.readInt(u16, in[2..4], .little);
    const word = std.mem.readInt(u32, in[4..8], .little);
    const last: u32 = (word >> 2) & 0x3ffff;
    if (word & 3 != 1 or last >= tile_size) return fail(diagnostic, 4, .bad_tile_size);
    const last_tile: u32 = if (tiles == 0) 0 else if (last == 0) tile_size else last;
    return .{
        .tiles = tiles,
        .size = if (tiles == 0) 0 else @as(u64, tiles - 1) * tile_size + last_tile,
        .last_tile = last_tile,
    };
}

fn fail(diagnostic: ?*Diagnostic, offset: u64, reason: Diagnostic.Reason) error{ InvalidStream, Truncated } {
    if (diagnostic) |d| d.* = .{ .offset = .fromRaw(offset), .reason = reason };
    return if (reason == .truncated) error.Truncated else error.InvalidStream;
}

/// Decoding tables for one page at a time: about 12 KiB, so one per thread
/// serves every stream.
pub const Decompressor = struct {
    tables: decode.Tables = .{},

    pub const init: Decompressor = .{};

    pub const Options = struct {
        diagnostic: ?*Diagnostic = null,
    };

    /// Decode one page (nvCOMP's unit) into `out`; the bytes written. Bytes
    /// after the page's final block are not read.
    pub fn decompressPage(d: *Decompressor, in: []const u8, out: []u8, options: Options) Error!usize {
        if (options.diagnostic) |diag| diag.tile = 0;
        return decode.page(&d.tables, in, out, options.diagnostic, 0);
    }

    /// Decode a tile stream into `out`, which holds at least the size its
    /// header gives (`inspect`); that size. Every tile must decode to its
    /// size exactly.
    pub fn decompress(d: *Decompressor, in: []const u8, out: []u8, options: Options) Error!usize {
        const info = try inspect(in, options.diagnostic);
        if (out.len < info.size) return error.OutputTooSmall;
        const tiles = try Tiles.init(in, info, options.diagnostic);
        for (0..info.tiles) |i| try d.tile(tiles, i, out, options.diagnostic);
        return info.size;
    }

    /// Decode tile `i` of `tiles` into its place in `out`.
    fn tile(d: *Decompressor, tiles: Tiles, i: usize, out: []u8, diagnostic: ?*Diagnostic) Error!void {
        const page = tiles.page(i);
        const len = tiles.tileLen(i);
        if (diagnostic) |diag| diag.tile = @intCast(i);
        const n = decode.page(&d.tables, page.bytes, out[i * tile_size ..][0..len], diagnostic, page.at) catch |err| switch (err) {
            // A page that would decode past its tile's size.
            error.OutputTooSmall => return tileLength(diagnostic, i, page.at),
            else => return err,
        };
        if (n != len) return tileLength(diagnostic, i, page.at);
    }
};

fn tileLength(diagnostic: ?*Diagnostic, i: usize, at: u64) error{InvalidStream} {
    if (diagnostic) |d| d.* = .{ .tile = @intCast(i), .offset = .fromRaw(at), .reason = .tile_length };
    return error.InvalidStream;
}

/// A tile stream's offsets, checked: where each tile's page is.
const Tiles = struct {
    in: []const u8,
    info: Info,
    /// The first byte of the pages.
    data: usize,

    fn init(in: []const u8, info: Info, diagnostic: ?*Diagnostic) InspectError!Tiles {
        const data = header_len + 4 * @as(usize, info.tiles);
        if (in.len < data) return fail(diagnostic, in.len, .truncated);
        const t: Tiles = .{ .in = in, .info = info, .data = data };
        // Each tile starts where the last ended or later, and the last ends
        // within the input.
        var at: usize = 0;
        for (1..@max(1, info.tiles)) |i| {
            const next = t.offset(i);
            if (next < at) return fail(diagnostic, header_len + 4 * i, .bad_tile_offsets);
            at = next;
        }
        if (info.tiles != 0 and in.len - data < @as(u64, at) + t.offset(0)) return fail(diagnostic, header_len, .bad_tile_offsets);
        return t;
    }

    /// Offset entry `i`: tile `i`'s start, or (entry 0) the last tile's length.
    fn offset(t: Tiles, i: usize) u32 {
        return std.mem.readInt(u32, t.in[header_len + 4 * i ..][0..4], .little);
    }

    fn page(t: Tiles, i: usize) struct { bytes: []const u8, at: u64 } {
        const start: usize = if (i == 0) 0 else t.offset(i);
        const end: usize = if (i + 1 < t.info.tiles) t.offset(i + 1) else start + t.offset(0);
        return .{ .bytes = t.in[t.data + start .. t.data + end], .at = t.data + start };
    }

    fn tileLen(t: Tiles, i: usize) usize {
        return if (i + 1 == t.info.tiles) t.info.last_tile else tile_size;
    }
};

/// Compression at one of DEFLATE's levels: the engine's match state over
/// a page's whole 64 KiB, taken once, so a match reaches anywhere back in
/// its page (Deflate64's distance codes 30 and 31).
pub const Compressor = struct {
    /// Private: the engine's tables.
    engine: Engine,
    /// Private: the level the tables were sized for.
    level: u4,
    /// Private: the memory `init` allocated, freed by `deinit`; empty after
    /// `initBuffer`.
    owned: []align(64) u8,
    /// Private: the allocator of `owned`.
    gpa: Allocator,

    const Engine = deflate.EngineFor(tile_size);

    pub const Options = struct {
        /// 0 stored, 1-9 zlib's scale, 10-12 the most compression; 13-15
        /// mean 12. As `warp.Compressor`'s.
        level: u4 = 6,
    };

    fn sizes(options: Options) Engine.Sizes {
        return .of(options.level, .default, tile_size);
    }

    /// The bytes `initBuffer` needs for `options`.
    pub fn memory(options: Options) usize {
        return sizes(options).memory();
    }

    pub fn init(gpa: Allocator, options: Options) Allocator.Error!Compressor {
        const buffer = try gpa.alignedAlloc(u8, .@"64", memory(options));
        var c = initBuffer(buffer, options) catch unreachable; // unreachable: buffer is memory(options) bytes
        c.owned = buffer;
        c.gpa = gpa;
        return c;
    }

    /// A compressor in caller memory, refused when shorter than
    /// `memory(options)`; `deinit` then frees nothing.
    pub fn initBuffer(buffer: []align(64) u8, options: Options) error{BufferTooSmall}!Compressor {
        return .{ .engine = try .init(buffer, sizes(options)), .level = options.level, .owned = &.{}, .gpa = undefined };
    }

    pub fn deinit(c: *Compressor) void {
        if (c.owned.len != 0) c.gpa.free(c.owned);
        c.* = undefined;
    }

    pub const CompressError = error{
        /// `out` is shorter than the page or stream; with `out.len >=
        /// pageBound(...)` or `bound(...)` this never happens.
        OutputTooSmall,
        /// A page longer than `tile_size`, or a stream of more than
        /// `max_tiles` tiles.
        InputTooLarge,
    };

    /// One page of `in` (at most `tile_size` bytes) into `out`, as nvCOMP
    /// takes pages; its length.
    pub fn compressPage(c: *Compressor, in: []const u8, out: []u8) CompressError!usize {
        if (in.len > tile_size) return error.InputTooLarge;
        var w: lanes.Writer = .init(out);
        c.engine.compressPasses(in, &.{}, &w, c.level, .default, null);
        if (w.overflow) return error.OutputTooSmall;
        return w.finish();
    }

    /// A tile stream of `in` into `out`, as DirectStorage reads it: a page
    /// a 64 KiB tile. Its length.
    pub fn compress(c: *Compressor, in: []const u8, out: []u8) CompressError!usize {
        // unreachable: tile_size is not zero
        const tiles = std.math.divCeil(usize, in.len, tile_size) catch unreachable;
        if (tiles > max_tiles) return error.InputTooLarge;
        const data = header_len + 4 * tiles;
        if (out.len < data) return error.OutputTooSmall;
        out[0] = codec_id;
        out[1] = codec_id ^ 0xff;
        std.mem.writeInt(u16, out[2..4], @intCast(tiles), .little);
        const last: u32 = @intCast(in.len % tile_size);
        std.mem.writeInt(u32, out[4..8], 1 | (last << 2), .little);
        var at: usize = data;
        for (0..tiles) |i| {
            const page = in[i * tile_size .. @min(in.len, (i + 1) * tile_size)];
            const n = try c.compressPage(page, out[at..]);
            // Entry 0 is the last tile's length; entry i > 0, tile i's start.
            const entry: u32 = if (i == 0) @intCast(if (tiles == 1) n else 0) else @intCast(at - data);
            std.mem.writeInt(u32, out[header_len + 4 * i ..][0..4], entry, .little);
            if (i + 1 == tiles and i != 0) std.mem.writeInt(u32, out[header_len..][0..4], @intCast(n), .little);
            at += n;
        }
        return at;
    }
};

/// The longest page `compressPage` writes for `len` bytes: stored blocks
/// at worst (19 bits each 65,535 bytes and each block the parser may end,
/// at least 5,000 bytes apart), and each lane's word being filled and its
/// next one reserved.
pub fn pageBound(len: usize) usize {
    const blocks = len / 5000 + 2;
    return len + (19 * blocks + 7) / 8 + 2 * 4 * lanes.lanes + 4;
}

/// The longest tile stream `compress` writes for `len` bytes.
pub fn bound(len: usize) usize {
    // unreachable: tile_size is not zero
    const tiles = std.math.divCeil(usize, len, tile_size) catch unreachable;
    return header_len + 4 * tiles + tiles * pageBound(tile_size) - (tiles * tile_size - len);
}
