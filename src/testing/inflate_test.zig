//! The streaming decoder against the corpora: every stream decodes the same
//! however its input and output are cut, every invalid stream gets the
//! whole-buffer decoder's verdict (zlib 1.3.1's), every prefix of a valid
//! stream asks for more input, and the `std.Io.Reader` reads what the
//! whole-buffer decoder writes.

const std = @import("std");
const testing = std.testing;
const corpus = @import("corpus.zig");
const gen = @import("gen");
const Inflate = @import("../stream/Inflate.zig");
const Decompressor = @import("../Decompressor.zig");
const Compressor = @import("../Compressor.zig");
const Diagnostic = @import("../Diagnostic.zig");
const container = @import("../container.zig");
const checksum = @import("checksum");
const gzip = @import("../gzip.zig");

fn accept(name: []const u8) container.Accept {
    return std.meta.stringToEnum(container.Accept, name).?;
}

/// How a streaming decode went: the output, the input taken, and the
/// last status or the error.
const Outcome = struct {
    out: []u8,
    in_len: usize,
    result: Inflate.DecodeError!Inflate.Status,
};

/// Pieces of input and output of the sizes `next` gives, until the stream
/// ends, it is refused, or the input runs out (`need_input`).
fn decodeInPieces(gpa: std.mem.Allocator, stream: []const u8, max_out: usize, options: Inflate.Options, random: ?std.Random) !Outcome {
    const window = try gpa.alloc(u8, @as(usize, 1) << options.window_bits);
    defer gpa.free(window);
    var z: Inflate = .init(window, options);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var piece: [4096]u8 = undefined;
    var at: usize = 0;
    var last: Inflate.Status = .need_input;
    while (true) {
        const in_len = if (random) |r| @min(stream.len - at, 1 + r.uintLessThan(usize, 40)) else stream.len - at;
        const out_len = if (random) |r| 1 + r.uintLessThan(usize, 300) else piece.len;
        const step = z.decode(stream[at..][0..in_len], piece[0..out_len]) catch |err| {
            return .{ .out = try out.toOwnedSlice(gpa), .in_len = at, .result = err };
        };
        try out.appendSlice(gpa, piece[0..step.out_len]);
        if (out.items.len > max_out) return error.TestUnexpectedResult;
        at += step.in_len;
        last = step.status;
        switch (step.status) {
            .done => break,
            .need_input, .member_end => if (at == stream.len and step.out_len == 0 and in_len == 0) break,
            .output_full, .block_end => {},
        }
    }
    return .{ .out = try out.toOwnedSlice(gpa), .in_len = at, .result = last };
}

test "every stream in the corpus decodes through the streaming decoder, cut anywhere" {
    const gpa = testing.allocator;
    const c = try corpus.Corpus.parse(corpus.streams);
    var it = c.records();
    var prng: std.Random.DefaultPrng = .init(0x57ea);
    var count: usize = 0;
    while (it.next()) |r| {
        const in = try corpus.input(gpa, r.fields[2]);
        defer gpa.free(in);
        const dictionary = if (r.fields[3].len != 0) try corpus.input(gpa, r.fields[3]) else try gpa.alloc(u8, 0);
        defer gpa.free(dictionary);
        const stream = r.fields[5];
        // A stream written for a smaller window decodes with that window.
        const bits: u4 = if (std.mem.find(u8, r.fields[1], "wbits=")) |i| blk: {
            var words = std.mem.tokenizeScalar(u8, r.fields[1][i + 6 ..], ' ');
            break :blk try std.fmt.parseInt(u4, words.next().?, 10);
        } else 15;
        const options: Inflate.Options = .{ .accept = accept(r.fields[4]), .dictionary = dictionary, .window_bits = bits };
        // Every 7th stream in tiny pieces; every stream whole.
        const random: ?std.Random = if (r.index % 7 == 0 and in.len < 300_000) prng.random() else null;
        const got = try decodeInPieces(gpa, stream, in.len, options, random);
        defer gpa.free(got.out);
        const status = got.result catch |err| {
            std.debug.print("{s} {s} {s}: {t}\n", .{ r.fields[0], r.fields[1], r.fields[2], err });
            return err;
        };
        testing.expect(status == .done or status == .member_end) catch |err| {
            std.debug.print("{s} {s} {s}: ended {t} after {d} of {d}\n", .{ r.fields[0], r.fields[1], r.fields[2], status, got.in_len, stream.len });
            return err;
        };
        try testing.expectEqual(stream.len, got.in_len);
        try testing.expectEqualSlices(u8, in, got.out);
        count += 1;
    }
    try testing.expect(count > 3000);
}

test "every invalid stream gets the same verdict streamed, whole and a byte at a time" {
    const gpa = testing.allocator;
    const c = try corpus.Corpus.parse(corpus.invalid);
    var it = c.records();
    const d = try gpa.create(Decompressor);
    defer gpa.destroy(d);
    d.* = .init;
    const out = try gpa.alloc(u8, 4 << 20);
    defer gpa.free(out);
    var count: usize = 0;
    while (it.next()) |r| {
        const kind = std.meta.stringToEnum(container.Container, r.fields[1]).?;
        const bits = try std.fmt.parseInt(u4, r.fields[2], 10);
        const dictionary = if (r.fields[3].len != 0) try corpus.input(gpa, r.fields[3]) else try gpa.alloc(u8, 0);
        defer gpa.free(dictionary);
        const stream = r.fields[4];
        const verdict = r.fields[5];
        const options: Inflate.Options = .{ .accept = accept(r.fields[1]), .dictionary = dictionary, .members = .one, .window_bits = bits };
        for ([_]bool{ false, true }) |bytewise| {
            var diag: Diagnostic = .{};
            var o = options;
            o.diagnostic = &diag;
            const got = try decodeBytewise(gpa, stream, o, bytewise);
            defer gpa.free(got.out);
            checkVerdict(gpa, verdict, kind, stream, options, got, &diag) catch |err| {
                std.debug.print("{s} ({s}, window {d}, {s}): zlib says \"{s}\", streaming says ", .{ r.fields[0], r.fields[1], bits, if (bytewise) "bytewise" else "whole", verdict });
                if (got.result) |ok| std.debug.print("{t} after {d} in, {d} out\n", .{ ok, got.in_len, got.out.len }) else |e| std.debug.print("{t} ({t} at bit {d})\n", .{ e, diag.reason, diag.bit_offset });
                return err;
            };
        }
        count += 1;
    }
    try testing.expect(count > 1000);
}

fn decodeBytewise(gpa: std.mem.Allocator, stream: []const u8, options: Inflate.Options, bytewise: bool) !Outcome {
    const window = try gpa.alloc(u8, @as(usize, 1) << options.window_bits);
    defer gpa.free(window);
    var z: Inflate = .init(window, options);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var piece: [1 << 16]u8 = undefined;
    var at: usize = 0;
    var last: Inflate.Status = .need_input;
    while (true) {
        const in_len = if (bytewise) @min(1, stream.len - at) else stream.len - at;
        const step = z.decode(stream[at..][0..in_len], &piece) catch |err| return .{ .out = try out.toOwnedSlice(gpa), .in_len = at, .result = err };
        try out.appendSlice(gpa, piece[0..step.out_len]);
        at += step.in_len;
        last = step.status;
        if (step.status == .done) break;
        if (step.status == .need_input and in_len == 0) break;
        if (out.items.len > 8 << 20) break;
    }
    return .{ .out = try out.toOwnedSlice(gpa), .in_len = at, .result = last };
}

fn checkVerdict(gpa: std.mem.Allocator, verdict: []const u8, kind: container.Container, stream: []const u8, options: Inflate.Options, got: Outcome, diag: *const Diagnostic) !void {
    var words = std.mem.tokenizeScalar(u8, verdict, ' ');
    const word = words.next().?;
    const refused_window = if (got.result) |_| false else |err| err == error.InvalidStream and diag.reason == .window_exceeded;
    if (refused_window and options.window_bits < 15) {
        // zlib enforces its window only across calls; this decoder always
        // does. With the largest window, the verdict is zlib's.
        var wide = options;
        wide.window_bits = 15;
        var wide_diag: Diagnostic = .{};
        wide.diagnostic = &wide_diag;
        const again = try decodeBytewise(gpa, stream, wide, false);
        defer gpa.free(again.out);
        return checkVerdict(gpa, verdict, kind, stream, wide, again, &wide_diag);
    }
    if (std.mem.eql(u8, word, "end")) {
        const status = try got.result;
        try testing.expectEqual(Inflate.Status.done, status);
        const in_len = try std.fmt.parseInt(usize, words.next().?, 10);
        const out_len = try std.fmt.parseInt(usize, words.next().?, 10);
        const crc = try std.fmt.parseInt(u32, words.next().?, 16);
        try testing.expectEqual(in_len, got.in_len);
        try testing.expectEqual(out_len, got.out.len);
        try testing.expectEqual(crc, checksum.crc32(0, got.out));
        return;
    }
    if (std.mem.eql(u8, word, "short")) {
        // The input ran out with the stream unfinished.
        try testing.expectEqual(Inflate.Status.need_input, try got.result);
        try testing.expectEqual(stream.len, got.in_len);
        return;
    }
    if (std.mem.eql(u8, word, "dict")) {
        try testing.expectError(error.InvalidStream, got.result);
        try testing.expectEqual(Diagnostic.Reason.dictionary_required, diag.reason);
        return;
    }
    const want = corpus.expected(verdict["data ".len..], kind);
    if (got.result) |_| return error.TestExpectedError else |err| try testing.expectEqual(want.err, err);
    for (want.reasons) |reason| {
        if (reason != diag.reason) continue;
        if (options.window_bits == 15) {
            // Where the whole-buffer decoder refuses it too.
            const d = try gpa.create(Decompressor);
            defer gpa.destroy(d);
            d.* = .init;
            const out = try gpa.alloc(u8, 4 << 20);
            defer gpa.free(out);
            var whole: Diagnostic = .{};
            if (d.inflate(stream, out, .{ .accept = options.accept, .dictionary = options.dictionary, .members = .one, .diagnostic = &whole })) |_| return error.TestExpectedError else |err| try testing.expectEqual(want.err, err);
            try testing.expectEqual(whole.bit_offset, diag.bit_offset);
        }
        return;
    }
    return error.TestUnexpectedReason;
}

test "every prefix of a valid stream asks for more input, a byte at a time too" {
    const gpa = testing.allocator;
    const c = try corpus.Corpus.parse(corpus.streams);
    var it = c.records();
    var streams: usize = 0;
    while (it.next()) |r| {
        if (r.index % 40 != 0 or r.fields[5].len > 2000 or r.fields[3].len != 0) continue;
        const stream = r.fields[5];
        const in = try corpus.input(gpa, r.fields[2]);
        defer gpa.free(in);
        const options: Inflate.Options = .{ .accept = accept(r.fields[4]), .members = .one };
        for (0..stream.len) |cut| {
            const got = try decodeBytewise(gpa, stream[0..cut], options, cut % 2 == 0);
            defer gpa.free(got.out);
            const status = try got.result;
            testing.expectEqual(Inflate.Status.need_input, status) catch |err| {
                std.debug.print("{s} {s} {s} cut at {d} of {d}\n", .{ r.fields[0], r.fields[1], r.fields[2], cut, stream.len });
                return err;
            };
            try testing.expectEqual(cut, got.in_len);
            // What came out is the input's start.
            try testing.expectEqualSlices(u8, in[0..got.out.len], got.out);
        }
        streams += 1;
    }
    try testing.expect(streams >= 80);
}

test "the reader reads every stream, from a reader that hands out a few bytes at a time" {
    const gpa = testing.allocator;
    const c = try corpus.Corpus.parse(corpus.streams);
    var it = c.records();
    const buffer = try gpa.alloc(u8, (1 << 15) + 4096);
    defer gpa.free(buffer);
    var tried: usize = 0;
    while (it.next()) |r| {
        if (r.index % 13 != 0) continue;
        const in = try corpus.input(gpa, r.fields[2]);
        defer gpa.free(in);
        const dictionary = if (r.fields[3].len != 0) try corpus.input(gpa, r.fields[3]) else try gpa.alloc(u8, 0);
        defer gpa.free(dictionary);
        const tail = "after";
        const data = try std.mem.concat(gpa, u8, &.{ r.fields[5], tail });
        defer gpa.free(data);
        var input_buffer: [64]u8 = undefined;
        var input: std.testing.Reader = .init(&input_buffer, &.{.{ .buffer = data }});
        input.artificial_limit = .limited(1 + r.index % 50);
        var reader: Inflate.Reader = .init(&input.interface, buffer, .{ .accept = accept(r.fields[4]), .dictionary = dictionary, .members = .one });
        const out = try reader.interface.allocRemaining(gpa, .unlimited);
        defer gpa.free(out);
        try testing.expectEqualSlices(u8, in, out);
        var rest: [tail.len + 1]u8 = undefined;
        const n = try input.interface.readSliceShort(&rest);
        try testing.expectEqualStrings(tail, rest[0..n]);
        tried += 1;
    }
    try testing.expect(tried > 200);
}

test "the reader says why it failed: the stream refused, or cut short" {
    const gpa = testing.allocator;
    var c = try Compressor.init(gpa, .{});
    defer c.deinit();
    var stream: [64]u8 = undefined;
    const n = try c.compress("hello, hello, hello", &stream, .{});
    const buffer = try gpa.alloc(u8, (1 << 15) + 4096);
    defer gpa.free(buffer);
    var cut: std.Io.Reader = .fixed(stream[0 .. n - 1]);
    var reader: Inflate.Reader = .init(&cut, buffer, .{});
    try testing.expectError(error.ReadFailed, reader.interface.allocRemaining(gpa, .unlimited));
    try testing.expectEqual(error.Truncated, reader.err().?);
    stream[n - 1] ^= 1;
    var bad: std.Io.Reader = .fixed(stream[0..n]);
    reader = .init(&bad, buffer, .{});
    try testing.expectError(error.ReadFailed, reader.interface.allocRemaining(gpa, .unlimited));
    try testing.expectEqual(error.ChecksumMismatch, reader.err().?);
}

test "a distance past the window is refused, and a stream written for the window decodes" {
    const gpa = testing.allocator;
    // Twenty bytes of noise, 280 other bytes, then the twenty again 300
    // back: past a window of 256, inside one of 512.
    var data: [320]u8 = undefined;
    gen.fill(.noise, 3, &data);
    @memcpy(data[300..320], data[0..20]);
    var c = try Compressor.init(gpa, .{ .level = 9 });
    defer c.deinit();
    var stream: [400]u8 = undefined;
    const n = try c.compress(&data, &stream, .{ .container = .raw });
    var diag: Diagnostic = .{};
    const narrow = try decodeBytewise(gpa, stream[0..n], .{ .accept = .raw, .window_bits = 8, .diagnostic = &diag }, false);
    defer gpa.free(narrow.out);
    try testing.expectError(error.InvalidStream, narrow.result);
    try testing.expectEqual(Diagnostic.Reason.window_exceeded, diag.reason);
    const wide = try decodeBytewise(gpa, stream[0..n], .{ .accept = .raw, .window_bits = 9 }, false);
    defer gpa.free(wide.out);
    try testing.expectEqualSlices(u8, &data, wide.out);
}

test "gzip: members one by one, member_end between them, and the first header's fields" {
    const gpa = testing.allocator;
    var c = try Compressor.init(gpa, .{});
    defer c.deinit();
    var a: [128]u8 = undefined;
    const a_len = try c.compress("first member, ", &a, .{ .container = .gzip, .gzip = .{ .name = "a-long-name.txt", .comment = "hi", .extra = "XY\x00\x00", .mtime = 9, .header_crc = true } });
    var b: [128]u8 = undefined;
    const b_len = try c.compress("second member", &b, .{ .container = .gzip });
    const both = try std.mem.concat(gpa, u8, &.{ a[0..a_len], b[0..b_len] });
    defer gpa.free(both);
    var name: [8]u8 = undefined;
    var comment: [8]u8 = undefined;
    var extra: [8]u8 = undefined;
    var fields: gzip.Fields = .{ .name_buffer = &name, .comment_buffer = &comment, .extra_buffer = &extra };
    var window: [1 << 15]u8 = undefined;
    var z: Inflate = .init(&window, .{ .accept = .gzip, .gzip_fields = &fields });
    var out: [64]u8 = undefined;
    const first = try z.decode(both, &out);
    try testing.expectEqual(Inflate.Status.member_end, first.status);
    try testing.expectEqual(a_len, first.in_len);
    try testing.expectEqualStrings("first member, ", out[0..first.out_len]);
    try testing.expectEqualStrings("a-long-n", fields.header.name.?);
    try testing.expect(fields.cut);
    try testing.expectEqualStrings("hi", fields.header.comment.?);
    try testing.expectEqualStrings("XY\x00\x00", fields.header.extra.?);
    try testing.expectEqual(@as(u32, 9), fields.header.mtime);
    try testing.expect(fields.header.header_crc);
    // At the boundary with no input: complete there.
    try testing.expectEqual(Inflate.Status.member_end, (try z.decode(&.{}, &out)).status);
    const second = try z.decode(both[first.in_len..], &out);
    try testing.expectEqualStrings("second member", out[0..second.out_len]);
    try testing.expectEqual(Inflate.Status.member_end, second.status);
    // Anything else after a member is refused where it starts.
    var diag: Diagnostic = .{};
    z = .init(&window, .{ .accept = .gzip, .diagnostic = &diag });
    _ = try z.decode(a[0..a_len], &out);
    try testing.expectError(error.InvalidStream, z.decode("j", &out));
    try testing.expectEqual(Diagnostic.Reason.trailing_data, diag.reason);
    try testing.expectEqual(@as(u64, 8 * a_len), diag.bit_offset);
    // A refused stream stays refused.
    try testing.expectError(error.InvalidStream, z.decode(b[0..b_len], &out));
}

test "a dictionary: raw streams reach into it, zlib streams name it, and reset keeps the window" {
    const gpa = testing.allocator;
    const dictionary = try gen.alloc(gpa, .json, 5, 40_000);
    defer gpa.free(dictionary);
    const message = try gen.alloc(gpa, .json, 6, 3000);
    defer gpa.free(message);
    var c = try Compressor.init(gpa, .{});
    defer c.deinit();
    for ([_]container.Container{ .raw, .zlib }) |kind| {
        const stream = try gpa.alloc(u8, Compressor.bound(message.len, .{ .container = kind, .dictionary = dictionary }));
        defer gpa.free(stream);
        const n = try c.compress(message, stream, .{ .container = kind, .dictionary = dictionary });
        const got = try decodeInPieces(gpa, stream[0..n], message.len, .{ .accept = if (kind == .raw) .raw else .zlib, .dictionary = dictionary }, null);
        defer gpa.free(got.out);
        try testing.expectEqualSlices(u8, message, got.out);
    }
    // Context takeover: a second raw stream refers into the first's output.
    const second = try gen.alloc(gpa, .json, 7, 2000);
    defer gpa.free(second);
    var s1: [8192]u8 = undefined;
    const n1 = try c.compress(message, &s1, .{ .container = .raw });
    var s2: [8192]u8 = undefined;
    const n2 = try c.compress(second, &s2, .{ .container = .raw, .dictionary = message });
    var window: [1 << 15]u8 = undefined;
    var z: Inflate = .init(&window, .{ .accept = .raw });
    var out: [4096]u8 = undefined;
    const r1 = try z.decode(s1[0..n1], &out);
    try testing.expectEqual(Inflate.Status.done, r1.status);
    z.reset(.history);
    const r2 = try z.decode(s2[0..n2], &out);
    try testing.expectEqual(Inflate.Status.done, r2.status);
    try testing.expectEqualSlices(u8, second, out[0..r2.out_len]);
}
