//! What the encoder's options resolve to: the reference's quality.h and
//! parameter sanitizing, the window, block and distance codes a quality
//! uses, and the match finder it chooses.

const command = @import("command.zig");
const Prepared = @import("Prepared.zig");

pub const min_window_bits = 10;
pub const max_window_bits = 24;
pub const large_max_window_bits = 30;
pub const min_block_bits = 16;
pub const max_block_bits = 24;
/// Distances reach the window less this (RFC 7932 §9.1).
pub const window_gap = 16;

pub const Mode = enum(u2) {
    /// No assumption about the input.
    generic = 0,
    /// UTF-8 text.
    text = 1,
    /// WOFF 2.0 fonts.
    font = 2,
};

/// The choices a caller makes: `Compressor`'s and `Compress`'s options.
pub const Options = struct {
    /// 0 (fastest) to 11 (densest); 11 is the reference's default.
    quality: u4 = 11,
    /// log2 of the window, 10-24 (to 30 with `large_window`).
    window_bits: u5 = 22,
    /// Window bits past 24 (not RFC 7932; the reference's large window),
    /// which only a decoder told to accept them reads.
    large_window: bool = false,
    mode: Mode = .generic,
    /// log2 of the input block, 16-24; null: the quality's.
    block_bits: ?u5 = null,
    /// No literal context modelling (faster decoding, larger output).
    disable_literal_context_modeling: bool = false,
    /// Bytes the stream may copy from as though they came before it (a
    /// decoder needs the same as its `dictionary`); qualities 0-1 and 2-4's
    /// match finders do not search it.
    dictionary: ?*const Prepared = null,
    /// The input's expected length, which tunes the match finder and the
    /// blocks; null: what has arrived when the first block is encoded.
    /// `Compressor` takes the input's.
    size_hint: ?usize = null,

    pub fn params(o: Options, size_hint: ?usize) Params {
        return .{
            .quality = o.quality,
            .lgwin = o.window_bits,
            .lgblock = o.block_bits orelse 0,
            .mode = o.mode,
            .large_window = o.large_window or o.window_bits > max_window_bits,
            .size_hint = @min(size_hint orelse 0, 1 << 30),
            .disable_literal_context_modeling = o.disable_literal_context_modeling,
        };
    }
};

/// The parameters as the caller gives them, before sanitizing.
pub const Params = struct {
    quality: u4 = 11,
    lgwin: u5 = 22,
    /// 0: chosen from the quality.
    lgblock: u5 = 0,
    mode: Mode = .generic,
    large_window: bool = false,
    size_hint: usize = 0,
    disable_literal_context_modeling: bool = false,
    npostfix: u32 = 0,
    ndirect: u32 = 0,
    /// The reference's `BROTLI_PARAM_STREAM_OFFSET`: bytes of an earlier
    /// stream this one continues (at most 2^30).
    stream_offset: usize = 0,
};

/// What the parameters resolve to.
pub const Resolved = struct {
    quality: u4,
    lgwin: u5,
    lgblock: u5,
    mode: Mode,
    large_window: bool,
    size_hint: usize,
    disable_literal_context_modeling: bool,
    stream_offset: usize,
    dist: command.DistanceParams,
    hasher: HasherParams,
    /// The prefix dictionary, when there is one.
    dictionary: ?*const Prepared = null,
};

pub fn resolve(p: Params) Resolved {
    var r: Resolved = .{
        .quality = p.quality,
        .lgwin = p.lgwin,
        .lgblock = p.lgblock,
        .mode = p.mode,
        .large_window = p.large_window and p.quality > 2,
        .size_hint = p.size_hint,
        .disable_literal_context_modeling = p.disable_literal_context_modeling,
        .stream_offset = p.stream_offset,
        .dist = undefined,
        .hasher = undefined,
    };
    if (r.lgwin < min_window_bits) {
        r.lgwin = min_window_bits;
    } else {
        const max: u5 = if (r.large_window) large_max_window_bits else max_window_bits;
        r.lgwin = @min(r.lgwin, max);
    }
    r.lgblock = lgBlock(r);
    r.dist = distanceParams(r.quality, r.mode, p.npostfix, p.ndirect, r.large_window);
    return r;
}

fn lgBlock(r: Resolved) u5 {
    if (r.quality <= 1) return r.lgwin;
    if (r.quality < 4) return 14;
    if (r.lgblock == 0) {
        if (r.quality >= 9 and r.lgwin > 16) return @min(18, r.lgwin);
        return 16;
    }
    return @min(max_block_bits, @max(min_block_bits, r.lgblock));
}

fn distanceParams(quality: u4, mode: Mode, npostfix_in: u32, ndirect_in: u32, large_window: bool) command.DistanceParams {
    var npostfix: u32 = 0;
    var ndirect: u32 = 0;
    if (quality >= 4) {
        if (mode == .font) {
            npostfix = 1;
            ndirect = 12;
        } else {
            npostfix = npostfix_in;
            ndirect = ndirect_in;
        }
        const ndirect_msb = (ndirect >> @intCast(@min(npostfix, 31))) & 0x0f;
        if (npostfix > 3 or ndirect > 120 or (ndirect_msb << @intCast(npostfix)) != ndirect) {
            npostfix = 0;
            ndirect = 0;
        }
    }
    return command.initDistanceParams(npostfix, ndirect, large_window);
}

/// log2 of the ring's size, past the window: room for a whole input block.
pub fn ringBits(r: *const Resolved) u5 {
    return 1 + @max(r.lgwin, r.lgblock);
}

pub fn maxMetaBlockSize(r: *const Resolved) usize {
    return @as(usize, 1) << @min(ringBits(r), max_block_bits);
}

/// Wrap a 64-bit position into the ring's 32-bit space, keeping the "not
/// the first lap" bit: the first 3 GiB are continuous, then every 2 GiB
/// wraps.
pub fn wrapPosition(position: u64) u32 {
    var result: u32 = @truncate(position);
    const gb = position >> 30;
    if (gb > 2) result = (result & ((1 << 30) - 1)) | (@as(u32, @intCast((gb - 1) & 1)) + 1) << 30;
    return result;
}

pub const Type = enum { h2, h3, h4, h5, h6, h10, h35, h40, h41, h42, h54, h55, h58, h65, h68 };

/// The match finder a quality uses, and its sizes.
pub const HasherParams = struct {
    type: Type = .h2,
    bucket_bits: u5 = 0,
    block_bits: u5 = 0,
    num_last_distances_to_check: u5 = 0,
};

/// The reference's quality-to-hasher choice (`ChooseHasher`), with its SIMD
/// hashers up to quality 6, as clang and gcc build it.
pub fn chooseHasher(r: *Resolved) void {
    const q = r.quality;
    var p: HasherParams = .{};
    if (q > 9) {
        p.type = .h10;
    } else if (q == 4 and r.size_hint >= 1 << 20) {
        p.type = .h54;
    } else if (q < 5) {
        p.type = switch (q) {
            2 => .h2,
            3 => .h3,
            else => .h4,
        };
    } else if (r.lgwin <= 16) {
        p.type = if (q < 7) .h40 else if (q < 9) .h41 else .h42;
    } else {
        const large = r.size_hint >= 1 << 20 and r.lgwin >= 19;
        p.type = if (large) (if (q <= max_simd_quality) .h68 else .h6) else (if (q <= max_simd_quality) .h58 else .h5);
        p.block_bits = q - 1;
        p.bucket_bits = if (large or q >= 7) 15 else 14;
        p.num_last_distances_to_check = if (q < 7) 4 else if (q < 9) 10 else 16;
    }
    if (r.lgwin > 24) {
        // Large windows: composite hashers with a rolling hash, except at
        // qualities 2 (too fast) and 10-11 (their tree already reaches).
        p.type = switch (p.type) {
            .h3 => .h35,
            .h54 => .h55,
            .h6, .h68 => .h65,
            else => p.type,
        };
    }
    r.hasher = p;
}

pub const max_simd_quality = 6;
