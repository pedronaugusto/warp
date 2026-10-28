//! LZ4 frames: descriptors, block headers, checksums, skippable frames and
//! the legacy format, read and written.

const std = @import("std");
const Diagnostic = @import("Diagnostic.zig");

pub const magic: u32 = 0x184D2204;
pub const legacy_magic: u32 = 0x184C2102;
/// Skippable frames' magics are 0x184D2A50 to 0x184D2A5F.
pub const skippable_magic: u32 = 0x184D2A50;
/// A legacy frame's blocks decode to at most this, all but the last to
/// exactly this.
pub const legacy_block_len = 8 << 20;
/// A legacy block's compressed length is at most this; a larger length
/// field is the next frame's magic.
pub const legacy_block_max = legacy_block_len + legacy_block_len / 255 + 16;
/// The largest descriptor: magic, FLG, BD, content size, dictionary ID, HC.
pub const max_header_len = 4 + 2 + 8 + 4 + 1;
pub const uncompressed_flag: u32 = 0x8000_0000;

/// The largest a frame's blocks decode to.
pub const BlockSize = enum(u3) {
    @"64KiB" = 4,
    @"256KiB" = 5,
    @"1MiB" = 6,
    @"4MiB" = 7,

    pub fn bytes(b: BlockSize) usize {
        return @as(usize, 1) << (2 * @as(u5, @backingInt(b)) + 8);
    }
};

/// What a frame's descriptor says.
pub const Header = struct {
    block_size: BlockSize = .@"4MiB",
    /// Each block decodes alone; otherwise blocks refer back into the 64
    /// KiB before them.
    independent: bool = true,
    /// Each block is followed by the XXH32 of its stored bytes.
    block_checksum: bool = false,
    /// The XXH32 of the content follows the last block.
    content_checksum: bool = true,
    content_size: ?u64 = null,
    dictionary_id: ?u32 = null,

    /// The descriptor's length, magic included.
    pub fn len(h: Header) usize {
        return 4 + 2 + @as(usize, if (h.content_size != null) 8 else 0) + @as(usize, if (h.dictionary_id != null) 4 else 0) + 1;
    }

    /// Write the magic and descriptor; returns their length.
    pub fn write(h: Header, out: []u8) usize {
        std.mem.writeInt(u32, out[0..4], magic, .little);
        var flg: u8 = 1 << 6;
        if (h.independent) flg |= 1 << 5;
        if (h.block_checksum) flg |= 1 << 4;
        if (h.content_size != null) flg |= 1 << 3;
        if (h.content_checksum) flg |= 1 << 2;
        if (h.dictionary_id != null) flg |= 1;
        out[4] = flg;
        out[5] = @as(u8, @backingInt(h.block_size)) << 4;
        var at: usize = 6;
        if (h.content_size) |n| {
            std.mem.writeInt(u64, out[at..][0..8], n, .little);
            at += 8;
        }
        if (h.dictionary_id) |id| {
            std.mem.writeInt(u32, out[at..][0..4], id, .little);
            at += 4;
        }
        out[at] = headerChecksum(out[4..at]);
        return at + 1;
    }
};

/// The descriptor's checksum byte: XXH32's second byte.
pub fn headerChecksum(descriptor: []const u8) u8 {
    return @truncate(std.hash.XxHash32.hash(0, descriptor) >> 8);
}

/// A frame at the start of an input.
pub const Frame = union(enum) {
    /// A frame of LZ4 blocks, with its descriptor's length.
    standard: struct { header: Header, header_len: usize },
    /// A legacy frame: 8 MiB blocks and nothing else.
    legacy,
    /// A skippable frame: its magic's low four bits and its payload's length.
    skippable: struct { variant: u4, len: u32 },
};

pub const FrameError = error{
    /// Not a frame the format defines.
    InvalidStream,
    /// The input ends inside the frame's header.
    Truncated,
};

/// The frame header at the start of `in`.
pub fn parse(in: []const u8, diagnostic: ?*Diagnostic, base: u64) FrameError!Frame {
    if (in.len < 4) return fail(diagnostic, base, .truncated, error.Truncated);
    const m = std.mem.readInt(u32, in[0..4], .little);
    if (m == legacy_magic) return .legacy;
    if (m & 0xFFFF_FFF0 == skippable_magic) {
        if (in.len < 8) return fail(diagnostic, base, .truncated, error.Truncated);
        return .{ .skippable = .{ .variant = @truncate(m), .len = std.mem.readInt(u32, in[4..8], .little) } };
    }
    if (m != magic) return fail(diagnostic, base, .bad_magic, error.InvalidStream);
    if (in.len < 7) return fail(diagnostic, base, .truncated, error.Truncated);
    const flg = in[4];
    const bd = in[5];
    if (flg >> 6 != 1) return fail(diagnostic, base, .bad_version, error.InvalidStream);
    if (flg & 2 != 0 or bd & 0x8F != 0) return fail(diagnostic, base, .reserved_bits, error.InvalidStream);
    const size_id: u3 = @truncate(bd >> 4);
    var h: Header = .{
        .block_size = switch (size_id) {
            4 => .@"64KiB",
            5 => .@"256KiB",
            6 => .@"1MiB",
            7 => .@"4MiB",
            else => return fail(diagnostic, base, .bad_block_size, error.InvalidStream),
        },
        .independent = flg & (1 << 5) != 0,
        .block_checksum = flg & (1 << 4) != 0,
        .content_checksum = flg & (1 << 2) != 0,
    };
    var at: usize = 6;
    const need = at + @as(usize, if (flg & (1 << 3) != 0) 8 else 0) + @as(usize, if (flg & 1 != 0) 4 else 0) + 1;
    if (in.len < need) return fail(diagnostic, base, .truncated, error.Truncated);
    if (flg & (1 << 3) != 0) {
        h.content_size = std.mem.readInt(u64, in[at..][0..8], .little);
        at += 8;
    }
    if (flg & 1 != 0) {
        h.dictionary_id = std.mem.readInt(u32, in[at..][0..4], .little);
        at += 4;
    }
    if (in[at] != headerChecksum(in[4..at])) return fail(diagnostic, base, .header_checksum, error.InvalidStream);
    return .{ .standard = .{ .header = h, .header_len = at + 1 } };
}

fn fail(diagnostic: ?*Diagnostic, at: u64, reason: Diagnostic.Reason, err: FrameError) FrameError {
    if (diagnostic) |d| d.* = .{ .offset = .fromRaw(at), .reason = reason };
    return err;
}

/// A block header: its stored length and whether it is stored raw. Zero
/// is the end mark.
pub const BlockHeader = struct {
    len: u32,
    uncompressed: bool,

    pub fn read(bytes: *const [4]u8) BlockHeader {
        const v = std.mem.readInt(u32, bytes, .little);
        return .{ .len = v & ~uncompressed_flag, .uncompressed = v & uncompressed_flag != 0 };
    }

    pub fn isEnd(bytes: *const [4]u8) bool {
        return std.mem.readInt(u32, bytes, .little) == 0;
    }
};

/// Write a skippable frame of `payload` with magic variant `variant`;
/// returns its length.
pub fn writeSkippable(out: []u8, variant: u4, payload: []const u8) error{OutputTooSmall}!usize {
    if (out.len < 8 + payload.len) return error.OutputTooSmall;
    std.mem.writeInt(u32, out[0..4], skippable_magic | variant, .little);
    std.mem.writeInt(u32, out[4..8], @intCast(payload.len), .little);
    @memcpy(out[8..][0..payload.len], payload);
    return 8 + payload.len;
}

/// Whether the four bytes at `in` start a frame, for the end of a legacy
/// frame.
pub fn startsFrame(in: []const u8) bool {
    if (in.len < 4) return false;
    const m = std.mem.readInt(u32, in[0..4], .little);
    return m == magic or m == legacy_magic or m & 0xFFFF_FFF0 == skippable_magic;
}

/// What bytes after a frame are: the start of another, the start of a
/// magic the input ends inside, or data that starts none.
pub const After = enum { frame, cut, trailing };

pub fn after(in: []const u8) After {
    if (in.len >= 4) return if (startsFrame(in)) .frame else .trailing;
    for ([_]u32{ magic, legacy_magic, skippable_magic }) |m| {
        var bytes: [4]u8 = undefined;
        std.mem.writeInt(u32, &bytes, m, .little);
        // A skippable magic's first byte is 0x50 to 0x5F.
        const first_ok = if (m == skippable_magic) in[0] & 0xF0 == 0x50 else in[0] == bytes[0];
        if (first_ok and std.mem.eql(u8, in[1..], bytes[1..in.len])) return .cut;
    }
    return .trailing;
}

test "a descriptor reads back as written, checksum included" {
    var buf: [max_header_len]u8 = undefined;
    const h: Header = .{ .block_size = .@"256KiB", .independent = false, .block_checksum = true, .content_checksum = false, .content_size = 123456789, .dictionary_id = 0xdeadbeef };
    const n = h.write(&buf);
    try std.testing.expectEqual(h.len(), n);
    const f = try parse(buf[0..n], null, 0);
    try std.testing.expectEqualDeep(h, f.standard.header);
    try std.testing.expectEqual(n, f.standard.header_len);
    buf[n - 1] +%= 1;
    var d: Diagnostic = .{};
    try std.testing.expectError(error.InvalidStream, parse(buf[0..n], &d, 0));
    try std.testing.expectEqual(Diagnostic.Reason.header_checksum, d.reason);
    for (0..n - 1) |cut| try std.testing.expectError(error.Truncated, parse(buf[0..cut], null, 0));
}

test "lz4frame's default descriptor: 04 22 4d 18 64 40 a7" {
    // Independent 64 KiB blocks with a content checksum.
    var buf: [max_header_len]u8 = undefined;
    const n = (Header{ .block_size = .@"64KiB" }).write(&buf);
    try std.testing.expectEqualSlices(u8, &.{ 0x04, 0x22, 0x4d, 0x18, 0x64, 0x40, 0xa7 }, buf[0..n]);
}
