//! The framing format both streams share (google's framing_format.txt):
//! chunks of a type byte and a 24-bit little-endian length, the first a
//! stream identifier; compressed and uncompressed data behind a masked
//! CRC-32C of the data; padding and skippable chunks. Snappy streams
//! (`sNaPpY`) hold blocks of at most 64 KiB, S2 streams (`S2sTwO`) of at
//! most 4 MiB.

const std = @import("std");
const Crc32c = @import("../checksum/crc32c.zig").Crc32c;
const block = @import("block.zig");

pub const Format = block.Format;

pub const Type = struct {
    pub const compressed: u8 = 0x00;
    pub const uncompressed: u8 = 0x01;
    /// S2's index, a skippable chunk.
    pub const index: u8 = 0x99;
    pub const padding: u8 = 0xfe;
    pub const identifier: u8 = 0xff;
    /// 0x02-0x7f: unskippable, refused; 0x80-0xfd: skipped.
    pub fn skippable(t: u8) bool {
        return t >= 0x80;
    }
};

pub const header_len = 4;
pub const checksum_len = 4;
/// The longest chunk a length holds.
pub const max_chunk_len = (1 << 24) - 1;
/// The identifier chunks, whole.
pub const identifier_s2 = "\xff\x06\x00\x00S2sTwO";
pub const identifier_snappy = "\xff\x06\x00\x00sNaPpY";
pub const identifier_len = identifier_s2.len;

/// S2's block sizes: 4 KiB to 4 MiB, 1 MiB by default; a Snappy stream's
/// blocks are at most 64 KiB (S2's writer writes 64 KiB less 8 by default).
pub const min_block_size = 4 << 10;
pub const max_block_size = 4 << 20;
pub const max_snappy_block_size = 64 << 10;

pub fn identifier(format: Format) *const [identifier_len]u8 {
    return switch (format) {
        .snappy => identifier_snappy,
        .s2 => identifier_s2,
    };
}

/// The largest block a stream of `format` holds.
pub fn maxBlock(format: Format) usize {
    return switch (format) {
        .snappy => max_snappy_block_size,
        .s2 => max_block_size,
    };
}

/// The checksum a data chunk carries: CRC-32C, rotated right by 15 bits
/// and offset by 0xa282ead8.
pub fn checksum(data: []const u8) u32 {
    return mask(Crc32c.hash(data));
}

pub fn mask(crc: u32) u32 {
    return std.math.rotr(u32, crc, 15) +% 0xa282ead8;
}

pub fn writeHeader(out: *[header_len]u8, t: u8, len: usize) void {
    std.debug.assert(len <= max_chunk_len);
    out[0] = t;
    out[1] = @truncate(len);
    out[2] = @truncate(len >> 8);
    out[3] = @truncate(len >> 16);
}

pub const Header = struct { type: u8, len: u32 };

pub fn readHeader(in: *const [header_len]u8) Header {
    return .{ .type = in[0], .len = @as(u32, in[1]) | (@as(u32, in[2]) << 8) | (@as(u32, in[3]) << 16) };
}

/// S2's `MaxEncodedLen`: the longest block of `n` bytes, its length
/// included, as S2's reader bounds a chunk.
pub fn maxEncodedLen(n: u64) u64 {
    const bits: u64 = 64 - @clz(n);
    return n + (bits + 7) / 7 + literalExtra(n);
}

fn literalExtra(n: u64) u64 {
    if (n == 0) return 0;
    if (n < 60) return 1;
    if (n < 1 << 8) return 2;
    if (n < 1 << 16) return 3;
    if (n < 1 << 24) return 4;
    return 5;
}

/// The longest chunk S2's reader takes for blocks of at most `max_block`
/// bytes: a block's bound and its checksum.
pub fn maxChunk(max_block: usize) u64 {
    return maxEncodedLen(max_block) + checksum_len;
}

/// The padding S2's writer adds for `written` bytes to be a multiple of
/// `multiple`: none, or a chunk of at least its header.
pub fn paddingLen(written: u64, multiple: u64) u64 {
    const left = written % multiple;
    if (left == 0) return 0;
    var add = multiple - left;
    while (add < header_len) add += multiple;
    return add;
}

test "masked checksums and bounds as S2 computes them" {
    try std.testing.expectEqual(@as(u32, 0xa282ead8), checksum(""));
    try std.testing.expectEqual(@as(u64, 4194312), maxEncodedLen(4 << 20));
    try std.testing.expectEqual(@as(u64, 4101), maxEncodedLen(4096));
    try std.testing.expectEqual(@as(u64, 1), maxEncodedLen(0));
    try std.testing.expectEqual(@as(u64, 127 + 2 + 2), maxEncodedLen(127));
    try std.testing.expectEqual(@as(u64, 0), paddingLen(4096, 4096));
    try std.testing.expectEqual(@as(u64, 4), paddingLen(4092, 4096));
    try std.testing.expectEqual(@as(u64, 4096 + 2), paddingLen(4094, 4096));
    try std.testing.expectEqual(@as(u64, 6), paddingLen(1, 7));
}
