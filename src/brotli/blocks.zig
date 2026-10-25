//! What the meta-block builders share: the block splits of a meta-block
//! and their histograms, the scratch slices they grow and shrink, and the
//! UTF-8 test that picks literal costs and context modes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const command = @import("command.zig");

const LiteralHistogram = command.LiteralHistogram;
const CommandHistogram = command.CommandHistogram;
const DistanceHistogram = command.DistanceHistogram;

/// Block types and lengths of one category.
pub const BlockSplit = struct {
    num_types: usize = 0,
    num_blocks: usize = 0,
    types: []u8 = &.{},
    lengths: []u32 = &.{},

    pub fn ensure(s: *BlockSplit, gpa: Allocator, n: usize) Allocator.Error!void {
        if (s.types.len < n) {
            const size = @max(n, s.types.len * 2);
            s.types = try grow(u8, gpa, s.types, size, s.num_blocks);
        }
        if (s.lengths.len < n) {
            const size = @max(n, s.lengths.len * 2);
            s.lengths = try grow(u32, gpa, s.lengths, size, s.num_blocks);
        }
    }

    pub fn deinit(s: *BlockSplit, gpa: Allocator) void {
        if (s.types.len != 0) gpa.free(s.types);
        if (s.lengths.len != 0) gpa.free(s.lengths);
        s.* = .{};
    }
};

pub fn grow(comptime T: type, gpa: Allocator, old: []T, size: usize, keep: usize) Allocator.Error![]T {
    const new = try gpa.alloc(T, size);
    @memcpy(new[0..keep], old[0..keep]);
    if (old.len != 0) gpa.free(old);
    return new;
}

pub const MetaBlockSplit = struct {
    literal_split: BlockSplit = .{},
    command_split: BlockSplit = .{},
    distance_split: BlockSplit = .{},
    literal_context_map: []u32 = &.{},
    distance_context_map: []u32 = &.{},
    literal_histograms: []LiteralHistogram = &.{},
    command_histograms: []CommandHistogram = &.{},
    distance_histograms: []DistanceHistogram = &.{},

    pub fn deinit(mb: *MetaBlockSplit, gpa: Allocator) void {
        mb.literal_split.deinit(gpa);
        mb.command_split.deinit(gpa);
        mb.distance_split.deinit(gpa);
        gpa.free(mb.literal_context_map);
        gpa.free(mb.distance_context_map);
        gpa.free(mb.literal_histograms);
        gpa.free(mb.command_histograms);
        gpa.free(mb.distance_histograms);
        mb.* = .{};
    }
};

/// A slice's used part, the rest given back; on failure `s` is as it was.
pub fn shrink(comptime T: type, gpa: Allocator, s: []T, n: usize) Allocator.Error![]T {
    if (gpa.resize(s, n)) return s.ptr[0..n];
    const new = try gpa.alloc(T, n);
    @memcpy(new, s[0..n]);
    gpa.free(s);
    return new;
}

fn utf8Symbol(input: []const u8, size: usize) struct { symbol: u32, len: usize } {
    const b0: u32 = input[0];
    if (b0 & 0x80 == 0 and b0 > 0) return .{ .symbol = b0, .len = 1 };
    if (size > 1 and b0 & 0xE0 == 0xC0 and input[1] & 0xC0 == 0x80) {
        const s = ((b0 & 0x1F) << 6) | (input[1] & 0x3F);
        if (s > 0x7F) return .{ .symbol = s, .len = 2 };
    }
    if (size > 2 and b0 & 0xF0 == 0xE0 and input[1] & 0xC0 == 0x80 and input[2] & 0xC0 == 0x80) {
        const s = ((b0 & 0x0F) << 12) | (@as(u32, input[1] & 0x3F) << 6) | (input[2] & 0x3F);
        if (s > 0x7FF) return .{ .symbol = s, .len = 3 };
    }
    if (size > 3 and b0 & 0xF8 == 0xF0 and input[1] & 0xC0 == 0x80 and input[2] & 0xC0 == 0x80 and input[3] & 0xC0 == 0x80) {
        const s = ((b0 & 0x07) << 18) | (@as(u32, input[1] & 0x3F) << 12) | (@as(u32, input[2] & 0x3F) << 6) | (input[3] & 0x3F);
        if (s > 0xFFFF and s <= 0x10FFFF) return .{ .symbol = s, .len = 4 };
    }
    // Not UTF-8: a symbol above its code space.
    return .{ .symbol = 0x110000 | b0, .len = 1 };
}

/// Whether more than `min_fraction` of `length` ring bytes from `pos`
/// are UTF-8.
pub fn isMostlyUtf8(data: []const u8, pos: usize, mask: usize, length: usize, min_fraction: f64) bool {
    var size_utf8: usize = 0;
    var i: usize = 0;
    while (i < length) {
        const r = utf8Symbol(data[(pos + i) & mask ..], length - i);
        i += r.len;
        if (r.symbol < 0x110000) size_utf8 += r.len;
    }
    return @as(f64, @floatFromInt(size_utf8)) > min_fraction * @as(f64, @floatFromInt(length));
}
