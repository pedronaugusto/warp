//! Whole-buffer LZMA encoding: raw LZMA (properties apart, as 7z and zip
//! store it), raw LZMA2 (as 7z and .xz blocks store it) and `.lzma` files,
//! from memory taken once.
//!
//! The encoder is warp's own on warp's matchfinders, with liblzma 5.8.4's
//! parsers and presets; its output is not liblzma's byte for byte (xz has
//! no canonical stream), but decodes in every LZMA decoder. LZMA2 chunks
//! are cut as liblzma cuts them (2 MiB of input, 64 KiB of output) and
//! stored where coding does not pay; output goes straight into the
//! caller's buffer, a chunk's header filled in once its size is known.

const Compressor = @This();

const std = @import("std");
const aegis = @import("aegis");
const Allocator = std.mem.Allocator;
const encode = @import("encode.zig");
const decode = @import("decode.zig");
const optimum = @import("optimum.zig");
const finders = @import("Finder.zig");

pub const Properties = decode.Properties;
pub const Mode = encode.Mode;
pub const MatchFinder = finders.Kind;

/// What an LZMA encoder is set to: liblzma's `lzma_options_lzma`.
pub const Options = struct {
    /// Bytes a match may reach back: 4 KiB to 1.5 GiB.
    dictionary: u32 = 8 << 20,
    properties: Properties = .{},
    mode: Mode = .normal,
    match_finder: MatchFinder = .bt4,
    /// A match this long is taken as is: 2-273 (at least the finder's
    /// hashed bytes, 3 or 4).
    nice_len: u32 = 64,
    /// Nodes or links a search visits; 0: liblzma's default for the
    /// finder and nice length.
    depth: u32 = 0,

    /// liblzma's preset `level` (0-9; past 9, 9), with `extreme` its `-e`.
    pub fn preset(level: u4, extreme: bool) Options {
        const l = @min(level, 9);
        const dict_bits = [_]u5{ 18, 20, 21, 22, 22, 23, 23, 24, 25, 26 };
        var o: Options = .{ .dictionary = @as(u32, 1) << dict_bits[l] };
        if (l <= 3) {
            o.mode = .fast;
            o.match_finder = if (l == 0) .hc3 else .hc4;
            o.nice_len = if (l <= 1) 128 else 273;
            o.depth = ([_]u32{ 4, 8, 24, 48 })[l];
        } else {
            o.nice_len = if (l == 4) 16 else if (l == 5) 32 else 64;
        }
        if (extreme) {
            o.mode = .normal;
            o.match_finder = .bt4;
            if (l == 3 or l == 5) {
                o.nice_len = 192;
                o.depth = 0;
            } else {
                o.nice_len = 273;
                o.depth = 512;
            }
        }
        return o;
    }

    /// Whether liblzma's encoder takes these.
    pub fn valid(o: Options) bool {
        const p = o.properties;
        return o.dictionary >= dictionary_min and o.dictionary <= dictionary_max and
            o.nice_len >= encode.match_len_min and o.nice_len <= encode.match_len_max and
            @as(u32, p.lc) + p.lp <= 4 and p.pb <= 4;
    }

    /// The nice length the finder keeps: at least its hashed bytes.
    pub fn niceLen(o: Options) u32 {
        return @max(o.nice_len, if (o.match_finder == .hc3) @as(u32, 3) else 4);
    }

    /// The depth a search goes to.
    pub fn searchDepth(o: Options) u32 {
        if (o.depth != 0) return o.depth;
        return if (o.match_finder == .bt4) 16 + o.niceLen() / 2 else 4 + o.niceLen() / 4;
    }

    pub fn tuning(o: Options) encode.Tuning {
        return .{ .mode = o.mode, .nice_len = o.niceLen(), .dictionary = o.dictionary };
    }
};

pub const dictionary_min = 4096;
pub const dictionary_max = (1 << 30) + (1 << 29);

/// What surrounds the stream.
pub const Format = union(enum) {
    /// Raw LZMA, its properties and dictionary apart. With `end_marker`
    /// the stream ends in one, so a decoder need not know its size.
    lzma1: struct { end_marker: bool = false },
    /// Raw LZMA2: chunks, then the end byte.
    lzma2,
    /// A `.lzma` file: a 13-byte header (properties, dictionary, size),
    /// then LZMA. With `size_known` false the header's size is unknown
    /// and an end marker ends the stream, as `xz --format=lzma` writes.
    alone: struct { size_known: bool = true },
};

pub const InitError = Allocator.Error || error{InvalidOptions};

pub const Error = error{
    /// `out` is shorter than the stream; `bound(...)` always holds it.
    OutputTooSmall,
};

/// A `.lzma` file's header.
pub const alone_header_len = 13;
/// An LZMA2 chunk's limits.
pub const chunk_max = 1 << 16;
pub const chunk_uncompressed_max = 1 << 21;

/// The largest stream an input of `len` bytes encodes to. LZMA2 stores a
/// chunk that does not shrink, and a coded one is at most 5 bytes longer
/// than its input; every chunk but the last covers more than its 61439
/// bytes of output budget. LZMA, which cannot store, gets the LZMA SDK's
/// margin.
pub fn bound(format: Format, len: usize) usize {
    return switch (format) {
        .lzma2 => len + 6 * (len / (chunk_max - encode.loop_input_max) + 2) + 1,
        .lzma1 => len + len / 3 + 128,
        .alone => alone_header_len + len + len / 3 + 128,
    };
}

/// LZMA2 of `len` bytes in stored chunks.
fn storedLen(len: usize) usize {
    return len + 3 * (std.math.divCeil(usize, len, chunk_max) catch unreachable) + 1;
}

pub const Finders = union(MatchFinder) {
    hc3: finders.Finder(.hc3),
    hc4: finders.Finder(.hc4),
    bt4: finders.Finder(.bt4),
};

/// Private: the coder, in `owned` or the caller's buffer.
coder: *encode.Coder,
/// Private: the matchfinder over its tables.
finder: Finders,
options: Options,
/// Private: the memory `init` allocated; empty after `initBuffer`.
owned: []align(64) u8 = &.{},
gpa: Allocator = undefined,

/// The bytes `initBuffer` needs for `options` over inputs of at most
/// `max_input` bytes (null: any).
pub fn memory(options: Options, max_input: ?aegis.units.Bytes(usize)) usize {
    const sizes = finders.Sizes.of(options.match_finder, options.dictionary, if (max_input) |m| m.raw() else null);
    return coder_bytes + sizes.memory(options.match_finder);
}

const coder_bytes = std.mem.alignForward(usize, @sizeOf(encode.Coder), 64);

pub fn init(gpa: Allocator, options: Options, max_input: ?aegis.units.Bytes(usize)) InitError!Compressor {
    if (!options.valid()) return error.InvalidOptions;
    const buffer = try gpa.alignedAlloc(u8, .@"64", memory(options, max_input));
    var c = initBuffer(buffer, options, max_input) catch unreachable;
    c.owned = buffer;
    c.gpa = gpa;
    return c;
}

/// A compressor in caller memory (`buffer.len >= memory(options,
/// max_input)`); `deinit` then frees nothing. A longer input than
/// `max_input` still compresses, its matches reaching back as far as the
/// tables sized for `max_input` allow.
pub fn initBuffer(buffer: []align(64) u8, options: Options, max_input: ?aegis.units.Bytes(usize)) error{InvalidOptions}!Compressor {
    if (!options.valid()) return error.InvalidOptions;
    const kind = options.match_finder;
    const sizes = finders.Sizes.of(kind, options.dictionary, if (max_input) |m| m.raw() else null);
    std.debug.assert(buffer.len >= coder_bytes + sizes.memory(kind));
    const coder = std.mem.bytesAsValue(encode.Coder, buffer[0..@sizeOf(encode.Coder)]);
    coder.* = .{};
    const tables: []align(64) u8 = buffer[coder_bytes..];
    const nice = options.niceLen();
    const depth = options.searchDepth();
    const f: Finders = switch (kind) {
        inline else => |k| @unionInit(Finders, @tagName(k), .init(tables, sizes, options.dictionary, nice, depth)),
    };
    return .{ .coder = coder, .finder = f, .options = options };
}

pub fn deinit(c: *Compressor) void {
    if (c.owned.len != 0) c.gpa.free(c.owned);
    c.* = undefined;
}

/// One stream of `in` into `out`; its length.
pub fn compress(c: *Compressor, in: []const u8, out: []u8, format: Format) Error!usize {
    switch (c.finder) {
        inline else => |*f| {
            f.reset();
            f.buf = in;
            f.read_limit = in.len;
            f.finishing = true;
            c.coder.init(c.options.properties, c.options.tuning());
            switch (format) {
                .lzma1 => |o| return lzma1(c.coder, f, out, o.end_marker),
                .alone => |o| {
                    if (out.len < alone_header_len) return error.OutputTooSmall;
                    out[0] = c.options.properties.encode();
                    std.mem.writeInt(u32, out[1..5], c.options.dictionary, .little);
                    std.mem.writeInt(u64, out[5..13], if (o.size_known) in.len else std.math.maxInt(u64), .little);
                    return alone_header_len + try lzma1(c.coder, f, out[alone_header_len..], !o.size_known);
                },
                .lzma2 => return lzma2(c.coder, f, c.options.properties, out) catch |err| {
                    // As liblzma's block encoder: stored, where that fits.
                    if (out.len < storedLen(in.len)) return err;
                    return stored(in, out);
                },
            }
        },
    }
}

fn lzma1(coder: *encode.Coder, f: anytype, out: []u8, end_marker: bool) Error!usize {
    coder.rc = .init(out);
    _ = optimum.run(coder, f, null);
    if (end_marker) coder.marker();
    coder.rc.flush();
    if (!coder.rc.fits()) return error.OutputTooSmall;
    return coder.rc.pos;
}

/// LZMA2 chunks of the finder's input into `out`, then the end byte.
pub fn lzma2(coder: *encode.Coder, f: anytype, props: Properties, out: []u8) Error!usize {
    var chunks: Chunks = .{ .props = props };
    var o: usize = 0;
    while (f.read_pos - f.read_ahead < f.buf.len) {
        chunks.begin(coder, out[o..]);
        std.debug.assert(chunks.code(coder, f) == .done);
        o += try chunks.end(coder, f, out[o..]);
    }
    if (o == out.len) return error.OutputTooSmall;
    out[o] = 0;
    return o + 1;
}

/// An LZMA2 stream's chunks, coded one at a time: `begin`, `code` until
/// done (more input may come between), `end`.
pub const Chunks = struct {
    props: Properties,
    need_properties: bool = true,
    need_dictionary_reset: bool = true,
    need_state_reset: bool = false,
    /// The coder's position where the chunk begins, and its header's
    /// length.
    begun: u64 = 0,
    header_len: usize = 0,

    /// A chunk from the finder's coding position into `out`, its header
    /// left for `end`.
    pub fn begin(k: *Chunks, coder: *encode.Coder, out: []u8) void {
        if (k.need_state_reset) coder.reset(k.props);
        k.header_len = if (k.need_properties) 6 else 5;
        k.begun = coder.position;
        coder.rc = .init(out[@min(out.len, k.header_len)..]);
    }

    /// The chunk's symbols, to 2 MiB of input or 64 KiB of output, or the
    /// finder's input.
    pub fn code(k: *const Chunks, coder: *encode.Coder, f: anytype) optimum.Status {
        const coded: usize = @intCast(coder.position - k.begun);
        return optimum.run(coder, f, .{
            .limit = f.read_pos - f.read_ahead + (chunk_uncompressed_max - encode.match_len_max) - coded,
            .budget = chunk_max - encode.loop_input_max,
        });
    }

    /// The chunk begun at `out` ended: coded, or stored where coding did
    /// not shrink it (with the bytes the parser read ahead, whose symbols
    /// the state reset drops); its length.
    pub fn end(k: *Chunks, coder: *encode.Coder, f: anytype, out: []u8) Error!usize {
        coder.rc.flush();
        const coded: usize = @intCast(coder.position - k.begun);
        const len = coder.rc.pos;
        if (len >= coded) {
            const start = f.read_pos - f.read_ahead - coded;
            const n = coded + f.read_ahead;
            coder.position += f.read_ahead;
            f.read_ahead = 0;
            k.need_state_reset = true;
            return k.store(f.buf[start..][0..n], out);
        }
        if (!coder.rc.fits()) return error.OutputTooSmall;
        out[0] = if (k.need_properties)
            (if (k.need_dictionary_reset) @as(u8, 0xe0) else 0xc0)
        else if (k.need_state_reset) @as(u8, 0xa0) else 0x80;
        out[0] |= @intCast((coded - 1) >> 16);
        std.mem.writeInt(u16, out[1..3], @intCast((coded - 1) & 0xffff), .big);
        std.mem.writeInt(u16, out[3..5], @intCast(len - 1), .big);
        if (k.need_properties) out[5] = k.props.encode();
        k.need_properties = false;
        k.need_dictionary_reset = false;
        k.need_state_reset = false;
        return k.header_len + len;
    }

    /// `bytes` as stored chunks.
    fn store(k: *Chunks, bytes: []const u8, out: []u8) Error!usize {
        var o: usize = 0;
        var rest = bytes;
        while (rest.len != 0) {
            const n = @min(rest.len, chunk_max);
            if (out.len - o < 3 + n) return error.OutputTooSmall;
            out[o] = if (k.need_dictionary_reset) 1 else 2;
            k.need_dictionary_reset = false;
            std.mem.writeInt(u16, out[o + 1 ..][0..2], @intCast(n - 1), .big);
            @memcpy(out[o + 3 ..][0..n], rest[0..n]);
            o += 3 + n;
            rest = rest[n..];
        }
        return o;
    }
};

/// `in` as LZMA2 of stored chunks (`out.len >= storedLen(in.len)`).
fn stored(in: []const u8, out: []u8) Error!usize {
    var k: Chunks = .{ .props = .{} };
    const n = try k.store(in, out);
    out[n] = 0;
    return n + 1;
}
