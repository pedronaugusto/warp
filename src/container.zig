//! The wrappers around a DEFLATE stream: none (raw, RFC 1951), zlib
//! (RFC 1950) and gzip (RFC 1952), and what a decoder accepts.

const std = @import("std");

/// The wrapper a compressor writes.
pub const Container = enum { raw, zlib, gzip };

/// What a decoder accepts.
pub const Accept = enum {
    raw,
    zlib,
    gzip,
    /// A zlib stream if the first two bytes form a zlib header, else raw:
    /// HTTP's "deflate", which some servers send raw.
    zlib_or_raw,
    /// A gzip member if the input starts with gzip's magic, else zlib: what
    /// zlib's `windowBits + 32` accepts.
    gzip_or_zlib,
};

/// How many gzip members a decoder reads.
pub const Members = enum {
    /// The first; what follows it is left unread.
    one,
    /// Every member, as gzip(1) and zlib's gzread do; anything after the
    /// last that is not a member is refused.
    all,
};

/// Whether `cmf` and `flg` form a zlib header: DEFLATE, a window of at
/// most 32 KiB, and the check.
pub fn isZlibHeader(cmf: u8, flg: u8) bool {
    return (@as(u16, cmf) << 8 | flg) % 31 == 0 and cmf & 15 == 8 and cmf >> 4 <= 7;
}

/// The container a decoder accepting `accept` reads from input starting
/// with `first` (zero, one or two bytes).
pub fn detect(accept: Accept, first: []const u8) Container {
    return switch (accept) {
        .raw => .raw,
        .zlib => .zlib,
        .gzip => .gzip,
        .zlib_or_raw => if (first.len >= 2 and isZlibHeader(first[0], first[1])) .zlib else .raw,
        .gzip_or_zlib => if (first.len >= 2 and first[0] == 0x1f and first[1] == 0x8b) .gzip else .zlib,
    };
}

/// A zlib header for a window of 2^`window_bits` bytes, compression
/// `level` (zlib's FLEVEL, informative) and, with a dictionary, its
/// Adler-32.
pub fn zlibHeader(window_bits: u4, level: u4, huffman_only: bool, dictionary_id: ?u32, out: []u8) usize {
    const cmf: u8 = (@as(u8, window_bits) - 8) << 4 | 8;
    const flevel: u8 = if (huffman_only or level < 2) 0 else if (level < 6) 1 else if (level == 6) 2 else 3;
    var flg: u8 = flevel << 6;
    if (dictionary_id != null) flg |= 0x20;
    flg += @intCast(31 - (@as(u16, cmf) << 8 | flg) % 31);
    out[0] = cmf;
    out[1] = flg;
    if (dictionary_id) |id| {
        std.mem.writeInt(u32, out[2..6], id, .big);
        return 6;
    }
    return 2;
}

test "zlib headers: the one every zlib writes at level 6, with and without a dictionary, read back" {
    var out: [6]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), zlibHeader(15, 6, false, null, &out));
    try std.testing.expectEqualSlices(u8, &.{ 0x78, 0x9c }, out[0..2]);
    _ = zlibHeader(15, 1, false, null, &out);
    try std.testing.expectEqualSlices(u8, &.{ 0x78, 0x01 }, out[0..2]);
    _ = zlibHeader(15, 9, false, null, &out);
    try std.testing.expectEqualSlices(u8, &.{ 0x78, 0xda }, out[0..2]);
    try std.testing.expectEqual(@as(usize, 6), zlibHeader(15, 6, false, 0x1234_5678, &out));
    try std.testing.expect(isZlibHeader(out[0], out[1]));
    try std.testing.expect(out[1] & 0x20 != 0);
    for (8..16) |bits| {
        _ = zlibHeader(@intCast(bits), 6, false, null, &out);
        try std.testing.expect(isZlibHeader(out[0], out[1]));
    }
    try std.testing.expect(!isZlibHeader(0x78, 0x9d));
    try std.testing.expect(!isZlibHeader(0x88, 0x98));
    try std.testing.expectEqual(Container.raw, detect(.zlib_or_raw, &.{ 0x4b, 0x4c }));
    try std.testing.expectEqual(Container.zlib, detect(.zlib_or_raw, &.{ 0x78, 0x9c }));
    try std.testing.expectEqual(Container.gzip, detect(.gzip_or_zlib, &.{ 0x1f, 0x8b }));
    try std.testing.expectEqual(Container.zlib, detect(.gzip_or_zlib, &.{0x78}));
}
