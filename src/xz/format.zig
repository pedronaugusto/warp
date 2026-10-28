//! The `.xz` container's parts, read as liblzma 5.8.4 reads them, each
//! check in its order: the stream header and footer, a block header and
//! its filter chain, variable-length integers, and the checks' sizes; and
//! written as liblzma writes them.

const std = @import("std");
const filter_ = @import("filter.zig");
const Crc32 = @import("../checksum/crc32.zig").Crc32;
const Crc64Xz = @import("../checksum/crc64xz.zig").Crc64Xz;
const Sha256 = std.crypto.hash.sha2.Sha256;
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

/// A block's check over its output as it comes.
pub const Hasher = union(enum) {
    none,
    crc32: Crc32,
    crc64: Crc64Xz,
    sha256: Sha256,

    pub fn init(c: Check) Hasher {
        return switch (c) {
            .crc32 => .{ .crc32 = .init },
            .crc64 => .{ .crc64 = .init },
            .sha256 => .{ .sha256 = .init(.{}) },
            else => .none,
        };
    }

    pub fn update(h: *Hasher, bytes: []const u8) void {
        switch (h.*) {
            .none => {},
            inline else => |*x| x.update(bytes),
        }
    }

    /// Whether the output's check is `stored`.
    pub fn matches(h: *Hasher, stored: []const u8) bool {
        return switch (h.*) {
            .none => true,
            .crc32 => |*x| x.final() == std.mem.readInt(u32, stored[0..4], .little),
            .crc64 => |*x| x.final() == std.mem.readInt(u64, stored[0..8], .little),
            .sha256 => |*x| std.mem.eql(u8, &x.finalResult(), stored[0..32]),
        };
    }

    /// The check, as a block stores it, into `out` (the check's size).
    pub fn final(h: *Hasher, out: []u8) void {
        switch (h.*) {
            .none => {},
            .crc32 => |*x| std.mem.writeInt(u32, out[0..4], x.final(), .little),
            .crc64 => |*x| std.mem.writeInt(u64, out[0..8], x.final(), .little),
            .sha256 => |*x| x.final(out[0..32]),
        }
    }
};

/// A part refused: why, and the byte it starts at.
pub const Fault = struct { reason: Diagnostic.Reason, at: usize };

/// A stream header's flags: the check. `in` is 12 bytes.
pub fn streamHeader(in: *const [header_len]u8) union(enum) { check: Check, fault: Diagnostic.Reason } {
    if (!std.mem.eql(u8, in[0..6], &header_magic)) return .{ .fault = .stream_magic };
    if (std.hash.Crc32.hash(in[6..8]) != std.mem.readInt(u32, in[8..12], .little)) return .{ .fault = .stream_header_crc };
    if (in[6] != 0 or in[7] & 0xf0 != 0) return .{ .fault = .stream_flags };
    return .{ .check = @fromBackingInt(@as(u4, @truncate(in[7]))) };
}

pub const Footer = struct { backward_size: u64, check: Check };

/// A stream footer: the index's size and the check. `in` is 12 bytes.
pub fn streamFooter(in: *const [footer_len]u8) union(enum) { footer: Footer, fault: Diagnostic.Reason } {
    if (!std.mem.eql(u8, in[10..12], &footer_magic)) return .{ .fault = .footer_magic };
    if (std.hash.Crc32.hash(in[4..10]) != std.mem.readInt(u32, in[0..4], .little)) return .{ .fault = .footer_crc };
    if (in[8] != 0 or in[9] & 0xf0 != 0) return .{ .fault = .stream_flags };
    return .{ .footer = .{
        .backward_size = (@as(u64, std.mem.readInt(u32, in[4..8], .little)) + 1) * 4,
        .check = @fromBackingInt(@as(u4, @truncate(in[9]))),
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
        const fid: filter_.Id = @fromBackingInt(id);
        if (fid == .lzma2) {
            // Last and only last; one property byte, the dictionary.
            if (i != count - 1 or props.len != 1) return .{ .fault = .{ .reason = .filter_options, .at = at } };
            const dict = decode.lzma2Dictionary(props[0]) orelse return .{ .fault = .{ .reason = .filter_options, .at = at } };
            lzma2 = dict;
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

/// A stream header for `check`.
pub fn writeStreamHeader(out: *[header_len]u8, check: Check) void {
    out[0..6].* = header_magic;
    out[6] = 0;
    out[7] = @backingInt(check);
    std.mem.writeInt(u32, out[8..12], std.hash.Crc32.hash(out[6..8]), .little);
}

/// A stream footer: the index's length (a multiple of 4) and the check.
pub fn writeStreamFooter(out: *[footer_len]u8, index_len: u64, check: Check) void {
    std.mem.writeInt(u32, out[4..8], @intCast(index_len / 4 - 1), .little);
    out[8] = 0;
    out[9] = @backingInt(check);
    std.mem.writeInt(u32, out[0..4], std.hash.Crc32.hash(out[4..10]), .little);
    out[10..12].* = footer_magic;
}

/// The bytes `v` takes as a variable-length integer.
pub fn vliLen(v: u64) usize {
    var n: usize = 1;
    var rest = v >> 7;
    while (rest != 0) : (rest >>= 7) n += 1;
    return n;
}

/// `v` as a variable-length integer at `out[pos.*..]`.
pub fn putVli(out: []u8, pos: *usize, v: u64) void {
    var rest = v;
    while (rest >= 0x80) : (rest >>= 7) {
        out[pos.*] = @as(u8, @truncate(rest)) | 0x80;
        pos.* += 1;
    }
    out[pos.*] = @intCast(rest);
    pos.* += 1;
}

/// LZMA2's dictionary as its property byte: the smallest size it names
/// that holds `dictionary`, as liblzma rounds it.
pub fn lzma2DictionaryByte(dictionary: u32) u8 {
    var d = @max(dictionary, 4096) - 1;
    d |= d >> 2;
    d |= d >> 3;
    d |= d >> 4;
    d |= d >> 8;
    d |= d >> 16;
    if (d == std.math.maxInt(u32)) return 40;
    const v = d + 1;
    // The distance slot of `v`, less 24.
    const n: u5 = @intCast(31 - @clz(v));
    return @intCast(((@as(u32, n) << 1) | ((v >> (n - 1)) & 1)) - 24);
}

/// What a block header names: its sizes where known, the filters before
/// LZMA2, the dictionary.
pub const BlockSpec = struct {
    compressed: ?u64,
    uncompressed: ?u64,
    filters: []const filter_.Filter,
    dictionary: u32,
};

/// The length of `spec`'s block header, a multiple of 4.
pub fn blockHeaderLen(spec: BlockSpec) usize {
    var n: usize = 2;
    if (spec.compressed) |c| n += vliLen(c);
    if (spec.uncompressed) |u| n += vliLen(u);
    for (spec.filters) |f| n += filterFlagsLen(f);
    n += 3; // LZMA2: id, property length, the dictionary byte
    return std.mem.alignForward(usize, n, 4) + 4;
}

fn filterFlagsLen(f: filter_.Filter) usize {
    return switch (f) {
        .delta => 3,
        .bcj => |b| if (b.start == 0) 2 else 6,
    };
}

/// `spec`'s block header into `out` (`blockHeaderLen(spec)` bytes).
pub fn writeBlockHeader(out: []u8, spec: BlockSpec) void {
    const len = blockHeaderLen(spec);
    @memset(out[0..len], 0);
    out[0] = @intCast(len / 4 - 1);
    out[1] = @intCast(spec.filters.len);
    var pos: usize = 2;
    if (spec.compressed) |c| {
        out[1] |= 0x40;
        putVli(out, &pos, c);
    }
    if (spec.uncompressed) |u| {
        out[1] |= 0x80;
        putVli(out, &pos, u);
    }
    for (spec.filters) |f| switch (f) {
        .delta => |dist| {
            putVli(out, &pos, @backingInt(filter_.Id.delta));
            out[pos] = 1;
            out[pos + 1] = @intCast(dist - 1);
            pos += 2;
        },
        .bcj => |b| {
            putVli(out, &pos, @backingInt(bcjId(b.kind)));
            if (b.start == 0) {
                out[pos] = 0;
                pos += 1;
            } else {
                out[pos] = 4;
                std.mem.writeInt(u32, out[pos + 1 ..][0..4], b.start, .little);
                pos += 5;
            }
        },
    };
    out[pos] = @intCast(@backingInt(filter_.Id.lzma2));
    out[pos + 1] = 1;
    out[pos + 2] = lzma2DictionaryByte(spec.dictionary);
    std.mem.writeInt(u32, out[len - 4 ..][0..4], std.hash.Crc32.hash(out[0 .. len - 4]), .little);
}

fn bcjId(kind: filter_.Bcj) filter_.Id {
    return switch (kind) {
        .x86 => .x86,
        .powerpc => .powerpc,
        .ia64 => .ia64,
        .arm => .arm,
        .armthumb => .armthumb,
        .sparc => .sparc,
        .arm64 => .arm64,
        .riscv => .riscv,
    };
}

test "written parts read back" {
    var h: [header_len]u8 = undefined;
    writeStreamHeader(&h, .crc64);
    try std.testing.expectEqual(Check.crc64, streamHeader(&h).check);
    var f: [footer_len]u8 = undefined;
    writeStreamFooter(&f, 16, .sha256);
    try std.testing.expectEqual(@as(u64, 16), streamFooter(&f).footer.backward_size);
    var buf: [16]u8 = undefined;
    for ([_]u64{ 0, 127, 128, 300, vli_max }) |v| {
        var pos: usize = 0;
        putVli(&buf, &pos, v);
        try std.testing.expectEqual(vliLen(v), pos);
        var at: usize = 0;
        try std.testing.expectEqual(@as(?u64, v), vli(buf[0..pos], &at));
    }
    for ([_]u32{ 4096, 1 << 20, 3 << 20, 8 << 20, (1 << 30) + (1 << 29), std.math.maxInt(u32) }) |d| {
        const named = decode.lzma2Dictionary(lzma2DictionaryByte(d)).?;
        try std.testing.expect(named >= d);
    }
    try std.testing.expectEqual(@as(u8, 16), lzma2DictionaryByte(1 << 20));
    const filters = [_]filter_.Filter{ .{ .delta = 4 }, .{ .bcj = .{ .kind = .arm64, .start = 64 } } };
    const spec: BlockSpec = .{ .compressed = 1000, .uncompressed = 70000, .filters = &filters, .dictionary = 1 << 20 };
    var block: [64]u8 = undefined;
    writeBlockHeader(&block, spec);
    const got = blockHeader(block[0..blockHeaderLen(spec)], .crc32).header;
    try std.testing.expectEqual(@as(?u64, 1000), got.compressed);
    try std.testing.expectEqual(@as(?u64, 70000), got.uncompressed);
    try std.testing.expectEqual(@as(u2, 2), got.filter_count);
    try std.testing.expectEqual(@as(u32, 1 << 20), got.dictionary);
    const open: BlockSpec = .{ .compressed = null, .uncompressed = null, .filters = &.{}, .dictionary = 1 << 20 };
    writeBlockHeader(&block, open);
    const bare = blockHeader(block[0..blockHeaderLen(open)], .crc32).header;
    try std.testing.expectEqual(@as(?u64, null), bare.compressed);
    try std.testing.expectEqual(@as(usize, 12), blockHeaderLen(open));
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
