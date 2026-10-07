//! What a project that depends on warp and nothing else writes. Built by
//! `zig build check-consumer` with no packages to fetch, so warp's
//! build.zig must work without any of its own CI dependencies.
const std = @import("std");
const warp = @import("warp");

pub fn main() !void {
    var c: warp.Compressor = try .init(std.heap.page_allocator, .{});
    defer c.deinit();
    var stream: [64]u8 = undefined;
    const n = try c.compress("consumer", &stream, .{});
    var d: warp.Decompressor = .init;
    var out: [8]u8 = undefined;
    _ = try d.inflate(stream[0..n], &out, .{});
}
