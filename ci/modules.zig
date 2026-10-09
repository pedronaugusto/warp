//! Independent module imports compose with the aggregate without duplicate types.
const std = @import("std");
const warp = @import("warp");
const checksums = @import("checksums");
const flate = @import("deflate");
const zstd = @import("zstd");

comptime {
    std.debug.assert(warp.Compressor == flate.Compressor);
    std.debug.assert(warp.zstd.Compressor == zstd.Compressor);
    std.debug.assert(warp.Crc32 == checksums.Crc32);
}

pub fn main() !void {
    const input = "independent codec modules share their lower layers";
    var out: [256]u8 = undefined;
    var back: [input.len]u8 = undefined;
    var c = try flate.Compressor.init(std.heap.page_allocator, .{ .max_input = input.len });
    defer c.deinit();
    const n = try c.compress(input, &out, .{});
    var d: warp.Decompressor = .init;
    const r = try d.inflate(out[0..n], &back, .{});
    if (r.out_len != input.len or !std.mem.eql(u8, input, &back)) return error.WrongOutput;
    var z = try zstd.Compressor.init(std.heap.page_allocator, .{ .max_input = input.len });
    defer z.deinit();
    const zn = try z.compress(input, &out, .{});
    var zd: warp.zstd.Decompressor = .init;
    const zr = try zd.decompress(out[0..zn], &back, .{});
    if (zr.out_len != input.len or !std.mem.eql(u8, input, &back)) return error.WrongOutput;
    if (checksums.Crc32.hash(&back) != warp.Crc32.hash(input) or checksums.kernels().crc32 != warp.kernels().crc32) return error.WrongChecksum;
}
