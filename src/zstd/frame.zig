//! Frame headers, block headers and skippable frames (RFC 8878 3.1), and
//! what can be learned about frames without decoding them: their header,
//! their length, their content size and a bound on it.

const std = @import("std");
const builtin = @import("builtin");
const Diagnostic = @import("Diagnostic.zig");

pub const magic: u32 = 0xFD2FB528;
pub const skippable_magic: u32 = 0x184D2A50;
pub const skippable_mask: u32 = 0xFFFFFFF0;
pub const block_max = 1 << 17;
/// The largest window a frame may declare: 2^31 (2^30 on 32-bit targets).
pub const window_log_max: u6 = if (@sizeOf(usize) == 4) 30 else 31;
pub const window_log_min = 10;

/// zstd frames with or without the leading magic number.
pub const Format = enum {
    standard,
    /// No magic number: the frame starts at its header descriptor. Such
    /// frames cannot be told from skippable ones, so none are skipped.
    magicless,
};

/// What a zstd frame header says.
pub const Header = struct {
    /// The history a decoder keeps: from the window descriptor, or the
    /// content size in a single-segment frame.
    window_size: u64,
    /// The decoded size, when the frame states it.
    content_size: ?u64,
    /// 0: none.
    dictionary_id: u32,
    /// A content checksum follows the last block.
    checksum: bool,
    single_segment: bool,
    /// Bytes of the header, magic number included.
    header_len: u8,

    /// The largest block this frame may hold: min(window, 128 KiB).
    pub fn blockMax(h: Header) usize {
        return @intCast(@min(h.window_size, block_max));
    }
};

/// A frame at the start of an input.
pub const Frame = union(enum) {
    zstd: Header,
    skippable: Skippable,
};

pub const Skippable = struct {
    /// The low 4 bits of its magic number.
    variant: u4,
    /// Bytes of payload after the 8-byte header.
    len: u32,
};

pub const Fault = struct { offset: usize, reason: Diagnostic.Reason };

pub const ParseError = error{ InvalidStream, Truncated, WindowTooLarge };

fn prefixLen(format: Format) usize {
    return switch (format) {
        .standard => 5,
        .magicless => 1,
    };
}

/// The header of the frame at the start of `in`.
pub fn parse(in: []const u8, format: Format, fault: *Fault) ParseError!Frame {
    fault.* = .{ .offset = 0, .reason = .truncated };
    if (format == .standard) {
        if (in.len < 4) {
            // A short input that cannot start any frame is refused as such.
            var head: [4]u8 = undefined;
            std.mem.writeInt(u32, &head, magic, .little);
            @memcpy(head[0..in.len], in);
            if (std.mem.readInt(u32, &head, .little) != magic) {
                std.mem.writeInt(u32, &head, skippable_magic, .little);
                @memcpy(head[0..in.len], in);
                if (std.mem.readInt(u32, &head, .little) & skippable_mask != skippable_magic) {
                    fault.reason = .bad_magic;
                    return error.InvalidStream;
                }
            }
            return error.Truncated;
        }
        const m = std.mem.readInt(u32, in[0..4], .little);
        if (m != magic) {
            if (m & skippable_mask == skippable_magic) {
                if (in.len < 8) return error.Truncated;
                return .{ .skippable = .{ .variant = @truncate(m), .len = std.mem.readInt(u32, in[4..8], .little) } };
            }
            fault.reason = .bad_magic;
            return error.InvalidStream;
        }
    }
    const start = prefixLen(format) - 1;
    if (in.len <= start) return error.Truncated;
    const fhd = in[start];
    const len = headerLen(fhd, format);
    if (in.len < len) return error.Truncated;
    return .{ .zstd = try parseFields(in[0..len], format, fault) };
}

/// The header's length from its descriptor byte.
pub fn headerLen(fhd: u8, format: Format) usize {
    const did = [4]u8{ 0, 1, 2, 4 };
    const fcs = [4]u8{ 0, 2, 4, 8 };
    const single = fhd & 0x20 != 0;
    const fcs_id = fhd >> 6;
    return prefixLen(format) + @intFromBool(!single) + did[fhd & 3] + fcs[fcs_id] + @intFromBool(single and fcs_id == 0);
}

fn parseFields(h: []const u8, format: Format, fault: *Fault) ParseError!Header {
    var pos = prefixLen(format);
    const fhd = h[pos - 1];
    if (fhd & 0x08 != 0) {
        fault.* = .{ .offset = pos - 1, .reason = .reserved_bit };
        return error.InvalidStream;
    }
    const single = fhd & 0x20 != 0;
    var window: u64 = 0;
    if (!single) {
        const wd = h[pos];
        pos += 1;
        const log: u6 = @intCast((wd >> 3) + window_log_min);
        if (log > window_log_max) {
            fault.* = .{ .offset = pos - 1, .reason = .window_too_large };
            return error.WindowTooLarge;
        }
        window = @as(u64, 1) << log;
        window += (window >> 3) * (wd & 7);
    }
    var id: u32 = 0;
    switch (fhd & 3) {
        0 => {},
        1 => {
            id = h[pos];
            pos += 1;
        },
        2 => {
            id = std.mem.readInt(u16, h[pos..][0..2], .little);
            pos += 2;
        },
        3 => {
            id = std.mem.readInt(u32, h[pos..][0..4], .little);
            pos += 4;
        },
        else => unreachable,
    }
    var content: ?u64 = null;
    switch (fhd >> 6) {
        0 => if (single) {
            content = h[pos];
        },
        1 => content = @as(u64, std.mem.readInt(u16, h[pos..][0..2], .little)) + 256,
        2 => content = std.mem.readInt(u32, h[pos..][0..4], .little),
        3 => content = std.mem.readInt(u64, h[pos..][0..8], .little),
        else => unreachable,
    }
    if (single) window = content.?;
    return .{
        .window_size = window,
        .content_size = content,
        .dictionary_id = id,
        .checksum = fhd & 0x04 != 0,
        .single_segment = single,
        .header_len = @intCast(h.len),
    };
}

pub const Block = struct {
    last: bool,
    kind: Kind,
    /// Bytes of the block's content (1 for an RLE block).
    size: usize,
    /// Bytes it decodes to, for raw and RLE blocks.
    regenerated: usize,

    pub const Kind = enum(u2) { raw, rle, compressed, reserved };
};

/// The block header at the start of `in` (three bytes).
pub fn blockHeader(in: *const [3]u8) Block {
    const h = std.mem.readInt(u24, in, .little);
    const kind: Block.Kind = @enumFromInt(@as(u2, @truncate(h >> 1)));
    const size: usize = h >> 3;
    return .{
        .last = h & 1 != 0,
        .kind = kind,
        .size = if (kind == .rle) 1 else size,
        .regenerated = size,
    };
}

/// The length of a skippable frame at the start of `in`.
pub fn skippableLen(in: []const u8, s: Skippable) ParseError!usize {
    const total = @as(u64, s.len) + 8;
    if (total > in.len) return error.Truncated;
    return @intCast(total);
}

/// The length of the frame at the start of `in`, and a bound on what it
/// decodes to.
pub const Extent = struct { len: usize, bound: u64 };

pub fn extent(in: []const u8, format: Format, fault: *Fault) ParseError!Extent {
    switch (try parse(in, format, fault)) {
        .skippable => |s| return .{ .len = try skippableLen(in, s), .bound = 0 },
        .zstd => |h| {
            var pos: usize = h.header_len;
            var blocks: u64 = 0;
            while (true) {
                if (in.len - pos < 3) {
                    fault.* = .{ .offset = pos, .reason = .truncated };
                    return error.Truncated;
                }
                const b = blockHeader(in[pos..][0..3]);
                if (b.kind == .reserved) {
                    fault.* = .{ .offset = pos, .reason = .bad_block_type };
                    return error.InvalidStream;
                }
                if (in.len - pos - 3 < b.size) {
                    fault.* = .{ .offset = pos, .reason = .truncated };
                    return error.Truncated;
                }
                pos += 3 + b.size;
                blocks += 1;
                if (b.last) break;
            }
            if (h.checksum) {
                if (in.len - pos < 4) {
                    fault.* = .{ .offset = pos, .reason = .truncated };
                    return error.Truncated;
                }
                pos += 4;
            }
            return .{ .len = pos, .bound = h.content_size orelse blocks * h.blockMax() };
        },
    }
}

/// Write a skippable frame of `payload` with magic variant `variant`.
pub fn writeSkippable(out: []u8, variant: u4, payload: []const u8) error{OutputTooSmall}!usize {
    if (out.len < payload.len + 8) return error.OutputTooSmall;
    std.mem.writeInt(u32, out[0..4], skippable_magic | variant, .little);
    std.mem.writeInt(u32, out[4..8], @intCast(payload.len), .little);
    @memcpy(out[8..][0..payload.len], payload);
    return payload.len + 8;
}

const testing = std.testing;

test "headers: single segment with a 1-byte size, windows, dictionary IDs, and every size field" {
    var fault: Fault = undefined;
    // Single segment, content size 0 in one byte.
    const empty = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd, 0x20, 0x00 };
    const h = (try parse(&empty, .standard, &fault)).zstd;
    try testing.expectEqual(@as(?u64, 0), h.content_size);
    try testing.expectEqual(@as(u64, 0), h.window_size);
    try testing.expectEqual(@as(u8, 6), h.header_len);
    // Window descriptor 0x00: 1 KiB; checksum; 2-byte dictionary ID; a
    // 2-byte content size (value + 256).
    const full = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd, 0x46, 0x00, 0x34, 0x12, 0x10, 0x00 };
    const g = (try parse(&full, .standard, &fault)).zstd;
    try testing.expectEqual(@as(u64, 1024), g.window_size);
    try testing.expectEqual(@as(u32, 0x1234), g.dictionary_id);
    try testing.expectEqual(@as(?u64, 0x10 + 256), g.content_size);
    try testing.expect(g.checksum);
    // Window 2^10 * (1 + 3/8) from mantissa 3.
    const w = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x03 };
    try testing.expectEqual(@as(u64, 1408), (try parse(&w, .standard, &fault)).zstd.window_size);
    // The reserved bit.
    try testing.expectError(error.InvalidStream, parse(&.{ 0x28, 0xb5, 0x2f, 0xfd, 0x08, 0x00 }, .standard, &fault));
    try testing.expectEqual(Diagnostic.Reason.reserved_bit, fault.reason);
    // A window of 2^42.
    try testing.expectError(error.WindowTooLarge, parse(&.{ 0x28, 0xb5, 0x2f, 0xfd, 0x00, 0xf8 }, .standard, &fault));
    // Short inputs: a prefix of the magic is truncated, anything else not a frame.
    try testing.expectError(error.Truncated, parse(&.{ 0x28, 0xb5 }, .standard, &fault));
    try testing.expectError(error.InvalidStream, parse(&.{ 0x28, 0xb6 }, .standard, &fault));
    try testing.expectError(error.Truncated, parse(&.{ 0x5a, 0x2a, 0x4d }, .standard, &fault));
    // Magicless.
    try testing.expectEqual(@as(u8, 2), (try parse(&.{ 0x20, 0x07 }, .magicless, &fault)).zstd.header_len);
}

test "skippable frames: written, recognized, measured" {
    var buf: [16]u8 = undefined;
    const n = try writeSkippable(&buf, 7, "abc");
    try testing.expectEqual(@as(usize, 11), n);
    var fault: Fault = undefined;
    const f = try parse(buf[0..n], .standard, &fault);
    try testing.expectEqual(@as(u4, 7), f.skippable.variant);
    try testing.expectEqual(Extent{ .len = 11, .bound = 0 }, try extent(buf[0..n], .standard, &fault));
    try testing.expectError(error.Truncated, extent(buf[0 .. n - 1], .standard, &fault));
}
