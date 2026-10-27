//! The `.xz` container's parts, read as liblzma 5.8.4 reads them, each
//! check in its order: the stream header and footer, a block header and
//! its filter chain, variable-length integers, and the checks' sizes.

const std = @import("std");
const filter_ = @import("filter.zig");
const decode = @import("../lzma/decode.zig");
const Diagnostic = @import("../lzma/Diagnostic.zig");

pub const header_magic = [6]u8{ 0xfd, '7', 'z', 'X', 'Z', 0 };
pub const footer_magic = [2]u8{ 'Y', 'Z' };
pub const header_len = 12;
pub const footer_len = 12;

/// A block's check.
pub const Check = enum(u4) {
    none = 0x00,
    crc32 = 0x01,
    crc64 = 0x04,
    sha256 = 0x0a,
    _,

    /// The check's length; the ids xz reserves have lengths too, so a
    /// stream naming one is read with its checks skipped, as liblzma does.
    pub fn size(c: Check) usize {
        const id = @backingInt(c);
        if (id == 0) return 0;
        return @as(usize, 4) << @intCast((id - 1) / 3);
    }
};

/// A part refused: why, and the byte it starts at.
pub const Fault = struct { reason: Diagnostic.Reason, at: usize };

/// A stream header's flags: the check. `in` is 12 bytes.
pub fn streamHeader(in: *const [header_len]u8) union(enum) { check: Check, fault: Diagnostic.Reason } {
    if (!std.mem.eql(u8, in[0..6], &header_magic)) return .{ .fault = .stream_magic };
    if (std.hash.Crc32.hash(in[6..8]) != std.mem.readInt(u32, in[8..12], .little)) return .{ .fault = .stream_header_crc };
    if (in[6] != 0 or in[7] & 0xf0 != 0) return .{ .fault = .stream_flags };
    return .{ .check = @fromBackingInt(@intCast(@as(u4, @truncate(in[7])))) };
}

pub const Footer = struct { backward_size: u64, check: Check };

/// A stream footer: the index's size and the check. `in` is 12 bytes.
pub fn streamFooter(in: *const [footer_len]u8) union(enum) { footer: Footer, fault: Diagnostic.Reason } {
    if (!std.mem.eql(u8, in[10..12], &footer_magic)) return .{ .fault = .footer_magic };
    if (std.hash.Crc32.hash(in[4..10]) != std.mem.readInt(u32, in[0..4], .little)) return .{ .fault = .footer_crc };
    if (in[8] != 0 or in[9] & 0xf0 != 0) return .{ .fault = .stream_flags };
    return .{ .footer = .{
        .backward_size = (@as(u64, std.mem.readInt(u32, in[4..8], .little)) + 1) * 4,
        .check = @fromBackingInt(@intCast(@as(u4, @truncate(in[9])))),
    } };
}

/// The largest variable-length integer, 2^63 - 1.
pub const vli_max = std.math.maxInt(u63);

/// A variable-length integer of `in` from `pos.*`: seven bits a byte,
/// least significant first, at most nine bytes, no zero byte last but
/// alone. Null where it breaks those or runs past `in`.
pub fn vli(in: []const u8, pos: *usize) ?u64 {
    var v: u64 = 0;
    var n: u6 = 0;
    while (pos.* < in.len) {
        const b = in[pos.*];
        pos.* += 1;
        v |= @as(u64, b & 0x7f) << (n * 7);
        n += 1;
        if (b & 0x80 == 0) {
            if (b == 0 and n > 1) return null;
            return v;
        }
        if (n == 9) return null;
    }
    return null;
}

pub const BlockHeader = struct {
    /// The header's length, 8 to 1024.
    len: usize,
    compressed: ?u64,
    uncompressed: ?u64,
    /// The filters before LZMA2, in the order they were applied when
    /// encoding.
    filters: [3]filter_.Filter,
    filter_count: u2,
    /// LZMA2's dictionary.
    dictionary: u32,
};

/// A block header, `in` its `(in[0] + 1) * 4` bytes; the check names the
/// check's size for the unpadded size's limit.
pub fn blockHeader(in: []const u8, check: Check) union(enum) { header: BlockHeader, fault: Fault } {
    const n = in.len - 4;
    if (std.hash.Crc32.hash(in[0..n]) != std.mem.readInt(u32, in[n..][0..4], .little)) return .{ .fault = .{ .reason = .block_header_crc, .at = n } };
    const flags = in[1];
    if (flags & 0x3c != 0) return .{ .fault = .{ .reason = .block_header, .at = 1 } };
    var pos: usize = 2;
    var h: BlockHeader = .{ .len = in.len, .compressed = null, .uncompressed = null, .filters = undefined, .filter_count = 0, .dictionary = 0 };
    if (flags & 0x40 != 0) {
        const at = pos;
        const c = vli(in[0..n], &pos) orelse return .{ .fault = .{ .reason = .block_header, .at = at } };
        // The unpadded size (header, data, check) must be 5 to 2^63 - 4.
        if (c == 0 or c > (vli_max & ~@as(u64, 3)) - in.len - check.size()) return .{ .fault = .{ .reason = .block_size, .at = at } };
        h.compressed = c;
    }
    if (flags & 0x80 != 0) {
        const at = pos;
        h.uncompressed = vli(in[0..n], &pos) orelse return .{ .fault = .{ .reason = .block_header, .at = at } };
    }
    const count = (flags & 3) + 1;
    var lzma2: ?u32 = null;
    for (0..count) |i| {
        const at = pos;
        const id = vli(in[0..n], &pos) orelse return .{ .fault = .{ .reason = .block_header, .at = at } };
        if (id >= 1 << 62) return .{ .fault = .{ .reason = .block_header, .at = at } };
        const props_len = vli(in[0..n], &pos) orelse return .{ .fault = .{ .reason = .block_header, .at = at } };
        if (props_len > n - pos) return .{ .fault = .{ .reason = .block_header, .at = at } };
        const props = in[pos..][0..@intCast(props_len)];
        pos += props.len;
        const fid: filter_.Id = @fromBackingInt(@intCast(id));
        if (fid == .lzma2) {
            // Last and only last; one property byte, the dictionary.
            if (i != count - 1 or props.len != 1) return .{ .fault = .{ .reason = .filter_options, .at = at } };
            const dict = decode.lzma2Dictionary(props[0]) orelse return .{ .fault = .{ .reason = .filter_options, .at = at } };
            lzma2 = @intCast(dict);
            continue;
        }
        const f = filter_.parse(fid, props) orelse return .{ .fault = .{
            .reason = if (switch (fid) {
                .delta, .x86, .powerpc, .ia64, .arm, .armthumb, .sparc, .arm64, .riscv => true,
                else => false,
            }) .filter_options else .unsupported_filter,
            .at = at,
        } };
        if (i == count - 1) return .{ .fault = .{ .reason = .filter_options, .at = at } };
        h.filters[i] = f;
        h.filter_count += 1;
    }
    h.dictionary = lzma2 orelse return .{ .fault = .{ .reason = .filter_options, .at = 2 } };
    while (pos < n) : (pos += 1) if (in[pos] != 0) return .{ .fault = .{ .reason = .block_header, .at = pos } };
    return .{ .header = h };
}

test "variable-length integers as liblzma reads them" {
    var pos: usize = 0;
    try std.testing.expectEqual(@as(?u64, 0), vli(&.{0}, &pos));
    pos = 0;
    try std.testing.expectEqual(@as(?u64, 300), vli(&.{ 0xac, 0x02 }, &pos));
    pos = 0;
    try std.testing.expectEqual(@as(?u64, null), vli(&.{ 0x80, 0x00 }, &pos));
    pos = 0;
    try std.testing.expectEqual(@as(?u64, null), vli(&.{0x80}, &pos));
    try std.testing.expectEqual(@as(usize, 8), Check.crc64.size());
    try std.testing.expectEqual(@as(usize, 32), Check.sha256.size());
    try std.testing.expectEqual(@as(usize, 4), @as(Check, @fromBackingInt(@intCast(2))).size());
    try std.testing.expectEqual(@as(usize, 64), @as(Check, @fromBackingInt(@intCast(15))).size());
}
