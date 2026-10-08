const std = @import("std");
const warp = @import("warp");
const compressed = @embedFile("asset");
const original = @embedFile("original");

pub fn main() !void {
    const output = try std.heap.page_allocator.alloc(u8, original.len);
    defer std.heap.page_allocator.free(output);
    var d: warp.Decompressor = .init;
    const result = try d.inflate(compressed, output, .{ .accept = .gzip });
    if (!std.mem.eql(u8, original, output[0..result.out_len])) return error.AssetMismatch;
}
