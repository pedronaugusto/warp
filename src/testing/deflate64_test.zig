//! Extended alphabet fixtures, written field by field.
const std = @import("std");
const testing = std.testing;
const deflate64 = @import("../deflate64.zig");
const Decompressor = @import("../Decompressor.zig");
const bits = @import("../bits.zig");

fn fixedSymbol(w: *bits.Writer, symbol: usize) void {
    const length: u6 = if (symbol < 144) 8 else if (symbol < 256) 9 else if (symbol < 280) 7 else 8;
    const code: u16 = @intCast(if (symbol < 144) symbol + 48 else if (symbol < 256) symbol + 256 else if (symbol < 280) symbol - 256 else symbol - 88);
    w.add(@bitReverse(code) >> @intCast(16 - length), length);
    w.flush();
}

test "Deflate64 length 285 has sixteen extra bits and spans a 64 KiB match" {
    var stream: [64]u8 = undefined;
    var w: bits.Writer = .init(&stream, 0);
    w.add(3, 3); // final fixed block
    fixedSymbol(&w, 'a');
    fixedSymbol(&w, 285);
    w.add(65535, 16); // 65,538 bytes, distance one
    w.add(0, 5);
    fixedSymbol(&w, 256);
    w.alignToByte();
    const out = try testing.allocator.alloc(u8, 65539);
    defer testing.allocator.free(out);
    var d: deflate64.Decompressor = .init;
    const r = try d.inflate(stream[0..w.at], out, .{});
    try testing.expectEqual(out.len, r.out_len);
    for (out) |byte| try testing.expectEqual(@as(u8, 'a'), byte);
    try testing.expectEqual(w.at, r.in_len);
    const partial = try d.inflate(stream[0..w.at], out[0..37], .{ .partial = true });
    try testing.expect(!partial.finished);
    for (0..w.at) |n| try testing.expectError(error.Truncated, d.inflate(stream[0..n], out, .{}));
}

test "Deflate64 distance symbols 30 and 31 reach beyond 32 KiB" {
    const gpa = testing.allocator;
    const dictionary = try gpa.alloc(u8, 65536);
    defer gpa.free(dictionary);
    for (dictionary, 0..) |*byte, i| byte.* = @truncate(i *% 17);
    for ([_]usize{ 30, 31 }) |symbol| {
        var stream: [64]u8 = undefined;
        var w: bits.Writer = .init(&stream, 0);
        w.add(3, 3);
        fixedSymbol(&w, 257); // length three
        w.add(@bitReverse(@as(u16, @intCast(symbol))) >> 11, 5);
        w.add(16383, 14);
        fixedSymbol(&w, 256);
        w.alignToByte();
        var out: [3]u8 = undefined;
        var d: deflate64.Decompressor = .init;
        _ = try d.inflate(stream[0..w.at], &out, .{ .dictionary = dictionary });
        const distance: usize = if (symbol == 30) 49152 else 65536;
        try testing.expectEqualSlices(u8, dictionary[65536 - distance ..][0..3], &out);
        var regular: Decompressor = .init;
        try testing.expectError(error.InvalidStream, regular.inflate(stream[0..w.at], &out, .{ .accept = .raw, .dictionary = dictionary }));
    }
}
