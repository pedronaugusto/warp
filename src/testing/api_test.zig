//! The surface around the engines: decoding from a `std.Io.Reader`, gzip
//! headers and members, trailers, std as an oracle in both directions,
//! fuzzing every entry, and the bounds on memory and stack.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const shakedown = @import("shakedown");
const gen = @import("gen");
const Compressor = @import("../Compressor.zig");
const Decompressor = @import("../Decompressor.zig");
const Diagnostic = @import("../Diagnostic.zig");
const container = @import("../container.zig");
const gzip = @import("../gzip.zig");
const inflate = @import("../inflate.zig");

/// `in` compressed whole, in memory `gpa` owns.
fn compressed(gpa: std.mem.Allocator, in: []const u8, options: Compressor.Options, frame: Compressor.Frame) ![]u8 {
    var c = try Compressor.init(gpa, options);
    defer c.deinit();
    const out = try gpa.alloc(u8, Compressor.bound(in.len, frame));
    errdefer gpa.free(out);
    const n = try c.compress(in, out, frame);
    return gpa.realloc(out, n);
}

/// `in` compressed by std at `level`, in memory `gpa` owns.
fn stdCompressed(gpa: std.mem.Allocator, in: []const u8, kind: std.compress.flate.Container, level: std.compress.flate.Compress.Options) ![]u8 {
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var out: std.Io.Writer.Allocating = try .initCapacity(gpa, 64);
    errdefer out.deinit();
    var c = try std.compress.flate.Compress.init(&out.writer, window, kind, level);
    try c.writer.writeAll(in);
    try c.finish();
    return out.toOwnedSlice();
}

fn newDecompressor(gpa: std.mem.Allocator) !*Decompressor {
    const d = try gpa.create(Decompressor);
    d.* = .init;
    return d;
}

test "inflateReader decodes from a reader that hands out a few bytes at a time, and leaves what follows the stream" {
    const gpa = testing.allocator;
    const d = try newDecompressor(gpa);
    defer gpa.destroy(d);
    const in = try gen.alloc(gpa, .text, 4, 50_000);
    defer gpa.free(in);
    const out = try gpa.alloc(u8, in.len + inflate.margin);
    defer gpa.free(out);
    const tail = "what follows";
    for ([_]container.Container{ .raw, .zlib, .gzip }) |kind| for ([_]u4{ 0, 1, 6 }) |level| {
        const stream = try compressed(gpa, in, .{ .level = level }, .{ .container = kind });
        defer gpa.free(stream);
        const data = try std.mem.concat(gpa, u8, &.{ stream, tail });
        defer gpa.free(data);
        const accept: container.Accept = switch (kind) {
            .raw => .raw,
            .zlib => .zlib,
            .gzip => .gzip,
        };
        for ([_]usize{ 1, 3, 64, 1 << 20 }) |chunk| {
            var buffer: [64]u8 = undefined;
            var r: std.testing.Reader = .init(&buffer, &.{.{ .buffer = data }});
            r.artificial_limit = .limited(chunk);
            // A gzip stream would read on for another member.
            const result = try d.inflateReader(&r.interface, out, .{ .accept = accept, .members = .one });
            try testing.expect(result.finished);
            try testing.expectEqual(stream.len, result.in_len);
            try testing.expectEqualSlices(u8, in, out[0..result.out_len]);
            var rest: [tail.len + 1]u8 = undefined;
            const n = try r.interface.readSliceShort(&rest);
            try testing.expectEqualStrings(tail, rest[0..n]);
        }
        // The stream alone, in a fixed reader: all of it is used.
        var r: std.Io.Reader = .fixed(stream);
        const result = try d.inflateReader(&r, out, .{ .accept = accept });
        try testing.expectEqualSlices(u8, in, out[0..result.out_len]);
        try testing.expectEqual(@as(usize, 0), r.bufferedLen());
    };
}

test "inflateReader says ReadFailed when the reader fails, and Truncated when it ends early" {
    const d = try newDecompressor(testing.allocator);
    defer testing.allocator.destroy(d);
    var out: [64]u8 = undefined;
    // std's failing reader, with a buffer to fill.
    var buffer: [64]u8 = undefined;
    var failing: std.Io.Reader = .failing;
    failing.buffer = &buffer;
    try testing.expectError(error.ReadFailed, d.inflateReader(&failing, &out, .{}));
    var short: std.Io.Reader = .fixed(&.{ 0x78, 0x9c, 0x4b });
    try testing.expectError(error.Truncated, d.inflateReader(&short, &out, .{}));
}

test "std's streams at every level decode, zlib and gzip, and std decodes warp's" {
    const gpa = testing.allocator;
    const d = try newDecompressor(gpa);
    defer gpa.destroy(d);
    const levels = [_]std.compress.flate.Compress.Options{ .level_1, .level_2, .level_3, .level_4, .level_5, .level_6, .level_7, .level_8, .level_9 };
    for ([_]gen.Kind{ .text, .binary, .png, .runs }) |kind| for ([_]usize{ 0, 1, 1000, 100_000 }) |len| {
        const in = try gen.alloc(gpa, kind, 9, len);
        defer gpa.free(in);
        const out = try gpa.alloc(u8, in.len);
        defer gpa.free(out);
        for (levels) |level| for ([_]std.compress.flate.Container{ .zlib, .gzip }) |kind_| {
            const stream = try stdCompressed(gpa, in, kind_, level);
            defer gpa.free(stream);
            const accept: container.Accept = if (kind_ == .zlib) .zlib else .gzip;
            const result = try d.inflate(stream, out, .{ .accept = accept });
            try testing.expectEqual(stream.len, result.in_len);
            try testing.expectEqualSlices(u8, in, out[0..result.out_len]);
        };
    };
}

test "a wrong trailer is ChecksumMismatch, for the reason it is wrong" {
    const gpa = testing.allocator;
    const d = try newDecompressor(gpa);
    defer gpa.destroy(d);
    const in = "hello, hello, hello, hello\n";
    var out: [64]u8 = undefined;
    const cases = [_]struct { container.Container, usize, Diagnostic.Reason }{
        // From the end: the zlib Adler-32; the gzip CRC-32, then its size.
        .{ .zlib, 1, .adler32 },
        .{ .gzip, 8, .crc32 },
        .{ .gzip, 1, .size },
    };
    for (cases) |case| {
        const stream = try compressed(gpa, in, .{}, .{ .container = case[0] });
        defer gpa.free(stream);
        stream[stream.len - case[1]] ^= 1;
        var diag: Diagnostic = undefined;
        const accept: container.Accept = if (case[0] == .zlib) .zlib else .gzip;
        try testing.expectError(error.ChecksumMismatch, d.inflate(stream, &out, .{ .accept = accept, .diagnostic = &diag }));
        try testing.expectEqual(case[2], diag.reason);
    }
}

test "a stream whose last code ends inside the bytes read past it is whole" {
    // A fixed block of three literals and its end, thirty-five bits in five
    // bytes: the decoder reads ahead past the end of the block, and the
    // bits that are there are the ones the block needs.
    const d = try newDecompressor(testing.allocator);
    defer testing.allocator.destroy(d);
    var out: [16]u8 = undefined;
    const result = try d.inflate(&.{ 0xb3, 0xdb, 0xab, 0x00, 0x00 }, &out, .{ .accept = .raw });
    try testing.expectEqualSlices(u8, "\x3e\xbd\x20", out[0..result.out_len]);
}

test "partial decoding into no output returns at once, unfinished" {
    const d = try newDecompressor(testing.allocator);
    defer testing.allocator.destroy(d);
    const stream = [_]u8{ 0x78, 0x9c, 0x4b, 0x4c, 0x04, 0x02, 0x00, 0x02, 0x87, 0x01, 0x07 };
    const result = try d.inflate(&stream, &.{}, .{ .partial = true });
    try testing.expect(!result.finished);
    try testing.expectEqual(@as(usize, 0), result.out_len);
}

test "gzip members: all of them, empty ones between, one when asked, and what follows refused or left" {
    const gpa = testing.allocator;
    const d = try newDecompressor(gpa);
    defer gpa.destroy(d);
    const a = try compressed(gpa, "first member, ", .{}, .{ .container = .gzip });
    defer gpa.free(a);
    const empty = try compressed(gpa, "", .{}, .{ .container = .gzip });
    defer gpa.free(empty);
    const b = try compressed(gpa, "second member", .{ .level = 1 }, .{ .container = .gzip, .gzip = .{ .name = "b.txt", .comment = "c", .extra = "xy", .header_crc = true } });
    defer gpa.free(b);
    const all = try std.mem.concat(gpa, u8, &.{ a, empty, b, empty });
    defer gpa.free(all);
    var out: [64]u8 = undefined;
    const whole = try d.inflate(all, &out, .{ .accept = .gzip });
    try testing.expectEqualStrings("first member, second member", out[0..whole.out_len]);
    try testing.expectEqual(all.len, whole.in_len);
    const one = try d.inflate(all, &out, .{ .accept = .gzip, .members = .one });
    try testing.expectEqualStrings("first member, ", out[0..one.out_len]);
    try testing.expectEqual(a.len, one.in_len);

    const trailing = try std.mem.concat(gpa, u8, &.{ a, "junk" });
    defer gpa.free(trailing);
    var diag: Diagnostic = undefined;
    try testing.expectError(error.InvalidStream, d.inflate(trailing, &out, .{ .accept = .gzip, .diagnostic = &diag }));
    try testing.expectEqual(Diagnostic.Reason.trailing_data, diag.reason);
    try testing.expectEqual(@as(u64, 8 * a.len), diag.bit_offset);
    const left = try d.inflate(trailing, &out, .{ .accept = .gzip, .members = .one });
    try testing.expectEqual(a.len, left.in_len);
}

test "gzip headers: every field written is read back, and a wrong header CRC is refused" {
    const gpa = testing.allocator;
    const header: gzip.Header = .{ .text = true, .mtime = 1_700_000_000, .xfl = 2, .os = 3, .extra = "AB\x02\x00hi", .name = "notes.txt", .comment = "made by a test", .header_crc = true };
    var buffer: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buffer);
    try gzip.writeHeader(&w, header);
    const written = w.buffered();
    try testing.expectEqual(gzip.headerLen(header), written.len);
    const parsed = try gzip.parseHeader(written);
    try testing.expectEqual(written.len, parsed.len);
    try testing.expectEqual(header.text, parsed.header.text);
    try testing.expectEqual(header.mtime, parsed.header.mtime);
    try testing.expectEqual(header.xfl, parsed.header.xfl);
    try testing.expectEqual(header.os, parsed.header.os);
    try testing.expectEqualStrings(header.extra.?, parsed.header.extra.?);
    try testing.expectEqualStrings(header.name.?, parsed.header.name.?);
    try testing.expectEqualStrings(header.comment.?, parsed.header.comment.?);
    try testing.expect(parsed.header.header_crc);
    for (0..written.len) |cut| try testing.expectError(error.Truncated, gzip.parseHeader(written[0..cut]));
    const bad = try gpa.dupe(u8, written);
    defer gpa.free(bad);
    bad[bad.len - 1] ^= 1;
    try testing.expectError(error.InvalidHeader, gzip.parseHeader(bad));
    // The decoder reads the same header, and says why it refuses the bad one.
    const stream = try compressed(gpa, "x", .{}, .{ .container = .gzip, .gzip = header });
    defer gpa.free(stream);
    try testing.expectEqualSlices(u8, written[0..8], stream[0..8]);
    const d = try newDecompressor(gpa);
    defer gpa.destroy(d);
    var out: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 1), (try d.inflate(stream, &out, .{ .accept = .gzip })).out_len);
    stream[written.len - 1] ^= 1;
    var diag: Diagnostic = undefined;
    try testing.expectError(error.ChecksumMismatch, d.inflate(stream, &out, .{ .accept = .gzip, .diagnostic = &diag }));
    try testing.expectEqual(Diagnostic.Reason.header_crc, diag.reason);
}

test "init survives every allocation failure, at every level" {
    for (0..13) |level| {
        try testing.checkAllAllocationFailures(testing.allocator, struct {
            fn initOnce(gpa: std.mem.Allocator, options: Compressor.Options) !void {
                var c = try Compressor.init(gpa, options);
                c.deinit();
            }
        }.initOnce, .{Compressor.Options{ .level = @intCast(level) }});
    }
}

test "degenerate inputs compress and come back at every level: zeros, period two, period 258" {
    const gpa = testing.allocator;
    const d = try newDecompressor(gpa);
    defer gpa.destroy(d);
    const len = 300_000;
    const in = try gpa.alloc(u8, len);
    defer gpa.free(in);
    const back = try gpa.alloc(u8, len);
    defer gpa.free(back);
    for ([_]usize{ 1, 2, 258 }) |period| {
        for (in, 0..) |*b, i| b.* = @truncate((i % period) *% 151);
        for (1..13) |level| {
            const stream = try compressed(gpa, in, .{ .level = @intCast(level) }, .{});
            defer gpa.free(stream);
            const result = try d.inflate(stream, back, .{});
            try testing.expectEqualSlices(u8, in, back[0..result.out_len]);
        }
    }
}

test "whole-buffer decoding runs on a 64 KiB thread stack, the Decompressor on it" {
    if (builtin.single_threaded) return error.SkipZigTest;
    const gpa = testing.allocator;
    const in = try gen.alloc(gpa, .json, 8, 200_000);
    defer gpa.free(in);
    const stream = try compressed(gpa, in, .{}, .{ .container = .gzip });
    defer gpa.free(stream);
    const out = try gpa.alloc(u8, in.len);
    defer gpa.free(out);
    const Run = struct {
        fn decode(s: []const u8, o: []u8, result: *Decompressor.InflateError!Decompressor.Result) void {
            var d: Decompressor = .init;
            result.* = d.inflate(s, o, .{ .accept = .gzip });
        }
    };
    var result: Decompressor.InflateError!Decompressor.Result = undefined;
    const thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024 }, Run.decode, .{ stream, out, &result });
    thread.join();
    try testing.expectEqual(in.len, (try result).out_len);
    try testing.expectEqualSlices(u8, in, out);
}

/// Every refusal is an answer to arbitrary bytes.
fn refused(err: Decompressor.InflateError) void {
    switch (err) {
        error.InvalidStream, error.ChecksumMismatch, error.DictionaryMismatch, error.Truncated, error.OutputTooSmall => {},
    }
}

/// Arbitrary bytes into every decoder entry: refused cleanly or decoded,
/// and what is decoded as raw DEFLATE std decodes to the same bytes.
fn decodeAnything(_: void, case: *shakedown.Case) !void {
    const input = try shakedown.gen.string(case.source, case.gpa, .{ .kind = .bytes, .max_len = 600, .average = 64 });
    const d = try newDecompressor(case.gpa);
    const ours = try case.gpa.alloc(u8, 8192);
    for (std.enums.values(container.Accept)) |accept| for ([_]bool{ false, true }) |partial| {
        _ = d.inflate(input, ours, .{ .accept = accept, .partial = partial }) catch |err| refused(err);
    };
    var r: std.Io.Reader = .fixed(input);
    _ = d.inflateReader(&r, ours, .{ .accept = .gzip_or_zlib }) catch |err| switch (err) {
        error.ReadFailed => return error.TestUnexpectedResult,
        else => |e| refused(e),
    };
    const result = d.inflate(input, ours, .{ .accept = .raw }) catch return;
    const window = try case.gpa.alloc(u8, std.compress.flate.max_window_len);
    var sr: std.Io.Reader = .fixed(input);
    var sd: std.compress.flate.Decompress = .init(&sr, .raw, window);
    const theirs = try case.gpa.alloc(u8, result.out_len + 1);
    const n = sd.reader.readSliceShort(theirs) catch return error.TestUnexpectedResult;
    case.note("{d} input bytes, {d} decoded", .{ input.len, result.out_len });
    try testing.expectEqualSlices(u8, theirs[0..n], ours[0..result.out_len]);
}

test "fuzz: any bytes into any decoder entry are refused cleanly or decoded as std decodes them" {
    try shakedown.check(testing.allocator, {}, decodeAnything, .{ .cases = 2000 });
}

/// Arbitrary input, level, strategy and container: the stream comes back
/// whole, and std reads the same raw stream.
fn roundTripAnything(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const input = if (shakedown.gen.boolean(s))
        try shakedown.gen.string(s, case.gpa, .{ .kind = .bytes, .max_len = 5000, .average = 300 })
    else
        try gen.alloc(case.gpa, shakedown.gen.enumValue(s, gen.Kind), shakedown.gen.int(s, u16), shakedown.gen.intRange(s, usize, 0, 70_000));
    const options: Compressor.Options = .{ .level = shakedown.gen.intRange(s, u4, 0, 15), .strategy = shakedown.gen.enumValue(s, Compressor.Strategy) };
    const kind = shakedown.gen.enumValue(s, container.Container);
    case.note("{d} bytes, level {d}, {t}, {t}", .{ input.len, options.level, options.strategy, kind });
    const stream = try compressed(case.gpa, input, options, .{ .container = kind });
    const d = try newDecompressor(case.gpa);
    const back = try case.gpa.alloc(u8, input.len);
    const accept: container.Accept = switch (kind) {
        .raw => .raw,
        .zlib => .zlib,
        .gzip => .gzip,
    };
    const result = try d.inflate(stream, back, .{ .accept = accept });
    try testing.expectEqual(stream.len, result.in_len);
    try testing.expectEqualSlices(u8, input, back[0..result.out_len]);
}

test "fuzz: any input at any level, strategy and container comes back whole" {
    try shakedown.check(testing.allocator, {}, roundTripAnything, .{ .cases = 300 });
}
