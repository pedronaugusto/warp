//! Restart points, portable indexes and reader seeking.
const std = @import("std");
const testing = std.testing;
const Index = @import("../Index.zig");
const parallel = @import("../parallel.zig");
const Inflate = @import("../stream/Inflate.zig");
const gen = @import("gen");
const shakedown = @import("shakedown");
const Bgzf = @import("../Bgzf.zig");

test "gzip index round-trips and every checkpoint resumes the checksum and history" {
    const gpa = testing.allocator;
    const in = try gen.alloc(gpa, .text, 123, 190000);
    defer gpa.free(in);
    var p = try parallel.Compressor.init(gpa, .{ .chunk_len = 8192, .concurrency = 3 });
    defer p.deinit();
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try p.compress(testing.io, in, &out.writer);
    const stream = out.written();
    var index = try Index.build(gpa, stream, .gzip, 8192);
    defer index.deinit();
    try testing.expectEqual(in.len, index.out_len);
    try testing.expect(index.points.len > 3);
    var persisted: std.Io.Writer.Allocating = .init(gpa);
    defer persisted.deinit();
    try index.write(&persisted.writer);
    var loaded = try Index.read(gpa, persisted.written());
    defer loaded.deinit();
    const back = try gpa.alloc(u8, in.len);
    defer gpa.free(back);
    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    var pd = try parallel.Decompressor.init(gpa, .{ .concurrency = 4 });
    defer pd.deinit();
    const pn = try pd.decompress(threaded.io(), stream, back, &loaded);
    try testing.expectEqualSlices(u8, in, back[0..pn]);
    var window: [32768]u8 = undefined;
    for (loaded.points) |*point| {
        var z: Inflate = .init(&window, .{ .accept = .gzip });
        try z.@"resume"(point);
        var ip: usize = @intCast(point.in_offset);
        var op: usize = @intCast(point.out_offset);
        while (true) {
            const step = try z.decode(stream[ip..], back[op..]);
            ip += step.in_len;
            op += step.out_len;
            if (step.status == .done or step.status == .member_end) break;
            try testing.expect(step.status != .need_input);
        }
        try testing.expectEqual(in.len, op);
        try testing.expectEqualSlices(u8, in[@intCast(point.out_offset)..], back[@intCast(point.out_offset)..op]);
        const found = loaded.find(point.out_offset).?;
        try testing.expectEqual(point.in_offset, found.in_offset);
        var source: std.Io.Reader = .fixed(stream[@intCast(point.in_offset)..]);
        var buffer: [32768 + 4096]u8 = undefined;
        var reader: Inflate.Reader = .init(&source, &buffer, .{ .accept = .gzip });
        try reader.seek(point);
        const n = try reader.interface.readSliceShort(back);
        try testing.expectEqualSlices(u8, in[@intCast(point.out_offset)..], back[0..n]);
    }
    try testing.expectError(error.InvalidIndex, Index.read(gpa, persisted.written()[0 .. persisted.written().len - 1]));
}

test "gzip index allocation failures release every buffer" {
    var no_resize: shakedown.alloc.NoResize = .init(testing.allocator);
    // Empty gzip member.
    const stream = [_]u8{ 31, 139, 8, 0, 0, 0, 0, 0, 0, 255, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    try testing.checkAllAllocationFailures(no_resize.allocator(), struct {
        fn once(gpa: std.mem.Allocator) !void {
            var index = try Index.build(gpa, &stream, .gzip, 1);
            index.deinit();
        }
    }.once, .{});
}

test "BGZF members respect both size bounds and end with the EOF member" {
    const Decompressor = @import("../Decompressor.zig");
    const gzip = @import("../gzip.zig");
    const gpa = testing.allocator;
    for ([_]gen.Kind{ .noise, .text }) |kind| {
        const in = try gen.alloc(gpa, kind, 33, 190000);
        defer gpa.free(in);
        var b = try Bgzf.init(gpa, .{});
        defer b.deinit();
        var out: std.Io.Writer.Allocating = .init(gpa);
        defer out.deinit();
        try b.write(in, &out.writer);
        try b.finish(&out.writer);
        const stream = out.written();
        try testing.expect(std.mem.endsWith(u8, stream, &Bgzf.eof));
        var at: usize = 0;
        var back: [65536]u8 = undefined;
        var offset: usize = 0;
        while (at < stream.len) {
            const header = try gzip.parseHeader(stream[at..]);
            try testing.expectEqualStrings("BC\x02\x00", header.header.extra.?[0..4]);
            const n: usize = @as(usize, std.mem.readInt(u16, header.header.extra.?[4..6], .little)) + 1;
            try testing.expect(n <= 65536);
            var d: Decompressor = .init;
            const r = try d.inflate(stream[at..][0..n], &back, .{ .accept = .gzip });
            try testing.expectEqual(n, r.in_len);
            try testing.expectEqualSlices(u8, in[offset..][0..r.out_len], back[0..r.out_len]);
            offset += r.out_len;
            at += n;
        }
        try testing.expectEqual(in.len, offset);
    }
}

test "checkpoint restoration refuses another window size or container" {
    var window: [32768]u8 = undefined;
    var z: Inflate = .init(&window, .{ .accept = .gzip });
    var point: Inflate.Checkpoint = .{ .in_offset = 10, .out_offset = 100, .window_bits = 14, .bits = 0, .pending = 0, .wrapper = .gzip, .check = 0, .size = 100, .members = 0, .history_len = 0 };
    try testing.expectError(error.InvalidCheckpoint, z.@"resume"(&point));
    point.window_bits = 15;
    point.wrapper = .raw;
    try testing.expectError(error.InvalidCheckpoint, z.@"resume"(&point));
}

test "BGZF and parallel decoder accept exact caller memory and initialization failures" {
    const gpa = testing.allocator;
    var no_resize: shakedown.alloc.NoResize = .init(gpa);
    try testing.checkAllAllocationFailures(no_resize.allocator(), struct {
        fn once(a: std.mem.Allocator) !void {
            var b = try Bgzf.init(a, .{});
            defer b.deinit();
            var p = try parallel.Decompressor.init(a, .{ .concurrency = 2 });
            defer p.deinit();
        }
    }.once, .{});
    const memory = try gpa.alignedAlloc(u8, .@"64", Bgzf.memory(.{}));
    defer gpa.free(memory);
    var b = Bgzf.initBuffer(memory, .{});
    defer b.deinit();
    var output: [128]u8 = undefined;
    var sink: std.Io.Writer = .fixed(&output);
    try b.write("hello", &sink);
    try b.finish(&sink);
    var index = try Index.build(gpa, sink.buffered(), .gzip, 1);
    defer index.deinit();
    const decode_memory = try gpa.alignedAlloc(u8, .@"64", parallel.Decompressor.memory(.{ .concurrency = 2 }));
    defer gpa.free(decode_memory);
    var p = parallel.Decompressor.initBuffer(decode_memory, .{ .concurrency = 2 });
    defer p.deinit();
    var back: [5]u8 = undefined;
    try testing.expectEqual(@as(usize, 5), try p.decompress(testing.io, sink.buffered(), &back, &index));
    try testing.expectEqualStrings("hello", &back);
}
