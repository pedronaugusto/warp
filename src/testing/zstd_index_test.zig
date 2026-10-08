const std = @import("std");
const testing = std.testing;
const gen = @import("gen");
const zstd = @import("../zstd.zig");
const Encoder = @import("../zstd/Encoder.zig");

fn stream(gpa: std.mem.Allocator, input: []const u8, output: []u8, options: zstd.Compress.Options, high: bool) !usize {
    var s = try zstd.Compress.init(gpa, options);
    defer s.deinit();
    if (high) {
        s.base = std.math.maxInt(u32) - (1 << 20);
        s.encoder.prepare(s.params, s.base);
    }
    var sink: std.Io.Writer = .fixed(output);
    var w: zstd.Compress.Writer = .init(&s, &sink, &.{});
    try w.interface.writeAll(input);
    try w.finish();
    return sink.buffered().len;
}

test "zstd indices: normalization preserves history and positional rings" {
    const gpa = testing.allocator;
    const input = try gen.alloc(gpa, .text, 763, 1_400_000);
    defer gpa.free(input);
    const output = try gpa.alloc(u8, Encoder.bound(input.len));
    defer gpa.free(output);
    const other = try gpa.alloc(u8, output.len);
    defer gpa.free(other);
    const decoded = try gpa.alloc(u8, input.len);
    defer gpa.free(decoded);
    var d: zstd.Decompressor = .init;
    inline for (std.meta.tags(zstd.Strategy)) |strategy| {
        const tuning: zstd.Tuning = .{ .strategy = strategy, .window_log = 17, .hash_log = 12, .chain_log = 12, .search_log = 3 };
        var c = try Encoder.init(gpa, .{ .tuning = tuning });
        defer c.deinit();
        const n = try c.compress(input, output, .{});
        const m = try c.compressLong(input, other, .{}, 1 << 19);
        if (!std.mem.eql(u8, output[0..n], other[0..m])) std.debug.print("whole normalization strategy={t}\n", .{strategy});
        try testing.expectEqualSlices(u8, output[0..n], other[0..m]);
        _ = try d.decompress(other[0..m], decoded, .{});
        try testing.expectEqualSlices(u8, input, decoded);
        const options: zstd.Compress.Options = .{ .tuning = tuning, .pledged_size = input.len };
        const a = try stream(gpa, input, output, options, false);
        const b = try stream(gpa, input, other, options, true);
        if (!std.mem.eql(u8, output[0..a], other[0..b])) std.debug.print("stream normalization strategy={t}\n", .{strategy});
        try testing.expectEqualSlices(u8, output[0..a], other[0..b]);
    }
}
