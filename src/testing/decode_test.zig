//! The decoder against other implementations: every stream they wrote
//! decodes to its input, every invalid stream gets zlib 1.3.1's verdict,
//! every prefix of a valid stream is `Truncated`.

const std = @import("std");
const testing = std.testing;
const corpus = @import("corpus.zig");
const gen = @import("gen");
const Decompressor = @import("../Decompressor.zig");
const Diagnostic = @import("../Diagnostic.zig");
const container = @import("../container.zig");
const checksum = @import("../checksum.zig");
const inflate = @import("../inflate.zig");

fn accept(name: []const u8) container.Accept {
    return std.meta.stringToEnum(container.Accept, name).?;
}

test "every stream in the corpus decodes to its input, with an exact output and with the margin" {
    const gpa = testing.allocator;
    const c = try corpus.Corpus.parse(corpus.streams);
    var it = c.records();
    const d = try gpa.create(Decompressor);
    defer gpa.destroy(d);
    d.* = .init;
    var count: usize = 0;
    while (it.next()) |r| {
        const producer = r.fields[0];
        const params = r.fields[1];
        const in = try corpus.input(gpa, r.fields[2]);
        defer gpa.free(in);
        const dictionary = if (r.fields[3].len != 0) try corpus.input(gpa, r.fields[3]) else try gpa.alloc(u8, 0);
        defer gpa.free(dictionary);
        const stream = r.fields[5];
        const out = try gpa.alloc(u8, in.len + inflate.margin);
        defer gpa.free(out);
        for ([_]usize{ in.len, in.len + inflate.margin }) |out_len| {
            var diag: Diagnostic = .{};
            const result = d.inflate(stream, out[0..out_len], .{ .accept = accept(r.fields[4]), .dictionary = dictionary, .diagnostic = &diag }) catch |err| {
                std.debug.print("{s} {s} {s} {s}: {t} ({t} at bit {d})\n", .{ producer, params, r.fields[2], r.fields[4], err, diag.reason, diag.bit_offset });
                return err;
            };
            testing.expectEqual(in.len, result.out_len) catch |err| {
                std.debug.print("{s} {s} {s}\n", .{ producer, params, r.fields[2] });
                return err;
            };
            try testing.expectEqualSlices(u8, in, out[0..in.len]);
            try testing.expectEqual(stream.len, result.in_len);
            try testing.expect(result.finished);
        }
        count += 1;
    }
    try testing.expect(count > 3000);
}

test "every invalid stream in the corpus gets zlib 1.3.1's verdict, for the same reason" {
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
        const name = r.fields[0];
        const kind = std.meta.stringToEnum(container.Container, r.fields[1]).?;
        // Window sizes below 15 are a streaming decoder's (zlib enforces
        // them only across calls); the whole-buffer decoder has no window.
        if (!std.mem.eql(u8, r.fields[2], "15")) continue;
        const dictionary = if (r.fields[3].len != 0) try corpus.input(gpa, r.fields[3]) else try gpa.alloc(u8, 0);
        defer gpa.free(dictionary);
        const stream = r.fields[4];
        const verdict = r.fields[5];
        var diag: Diagnostic = .{};
        // zlib's inflate reads one gzip member.
        const result = d.inflate(stream, out, .{ .accept = accept(r.fields[1]), .dictionary = dictionary, .members = .one, .diagnostic = &diag });
        checkVerdict(verdict, kind, result, out, &diag) catch |err| {
            std.debug.print("{s} ({s}): zlib says \"{s}\", warp says ", .{ name, r.fields[1], verdict });
            if (result) |ok| std.debug.print("{d} in, {d} out\n", .{ ok.in_len, ok.out_len }) else |e| std.debug.print("{t} ({t} at bit {d})\n", .{ e, diag.reason, diag.bit_offset });
            return err;
        };
        count += 1;
    }
    try testing.expect(count > 1000);
}

fn checkVerdict(verdict: []const u8, kind: container.Container, result: Decompressor.InflateError!Decompressor.Result, out: []const u8, diag: *const Diagnostic) !void {
    var words = std.mem.tokenizeScalar(u8, verdict, ' ');
    const word = words.next().?;
    if (std.mem.eql(u8, word, "end")) {
        const ok = try result;
        const in_len = try std.fmt.parseInt(usize, words.next().?, 10);
        const out_len = try std.fmt.parseInt(usize, words.next().?, 10);
        const crc = try std.fmt.parseInt(u32, words.next().?, 16);
        try testing.expectEqual(in_len, ok.in_len);
        try testing.expectEqual(out_len, ok.out_len);
        try testing.expectEqual(crc, checksum.crc32(0, out[0..ok.out_len]));
        return;
    }
    if (std.mem.eql(u8, word, "short")) {
        try testing.expectError(error.Truncated, result);
        try testing.expectEqual(Diagnostic.Reason.truncated, diag.reason);
        return;
    }
    if (std.mem.eql(u8, word, "dict")) {
        try testing.expectError(error.InvalidStream, result);
        try testing.expectEqual(Diagnostic.Reason.dictionary_required, diag.reason);
        return;
    }
    const want = corpus.expected(verdict["data ".len..], kind);
    if (result) |_| return error.TestExpectedError else |err| try testing.expectEqual(want.err, err);
    for (want.reasons) |reason| {
        if (reason == diag.reason) return;
    }
    return error.TestUnexpectedReason;
}

test "every prefix of a valid stream is Truncated, and says where the input ended" {
    const gpa = testing.allocator;
    const c = try corpus.Corpus.parse(corpus.streams);
    var it = c.records();
    const d = try gpa.create(Decompressor);
    defer gpa.destroy(d);
    d.* = .init;
    var streams: usize = 0;
    while (it.next()) |r| {
        // Every 20th stream of at most 3 KiB: about 200, every producer.
        if (r.index % 20 != 0 or r.fields[5].len > 3000 or r.fields[3].len != 0) continue;
        const stream = r.fields[5];
        const spec = try gen.Spec.parse(r.fields[2]);
        const out = try gpa.alloc(u8, spec.len);
        defer gpa.free(out);
        for (0..stream.len) |cut| {
            var diag: Diagnostic = .{};
            const result = d.inflate(stream[0..cut], out, .{ .accept = accept(r.fields[4]), .diagnostic = &diag });
            testing.expectError(error.Truncated, result) catch |err| {
                std.debug.print("{s} {s} {s} cut at {d} of {d}\n", .{ r.fields[0], r.fields[1], r.fields[2], cut, stream.len });
                return err;
            };
            try testing.expectEqual(@as(u64, cut) * 8, diag.bit_offset);
        }
        streams += 1;
    }
    try testing.expect(streams >= 150);
}

test "partial decoding into an output of every length gives the prefix and stops" {
    const gpa = testing.allocator;
    const c = try corpus.Corpus.parse(corpus.streams);
    var it = c.records();
    const d = try gpa.create(Decompressor);
    defer gpa.destroy(d);
    d.* = .init;
    var tried: usize = 0;
    while (it.next()) |r| {
        if (r.index % 97 != 0 or r.fields[3].len != 0) continue;
        const in = try corpus.input(gpa, r.fields[2]);
        defer gpa.free(in);
        if (in.len > 5000) continue;
        const out = try gpa.alloc(u8, in.len);
        defer gpa.free(out);
        for (0..in.len + 1) |n| {
            const result = try d.inflate(r.fields[5], out[0..n], .{ .accept = accept(r.fields[4]), .partial = true });
            try testing.expectEqual(n, result.out_len);
            try testing.expectEqual(n == in.len, result.finished);
            try testing.expectEqualSlices(u8, in[0..n], out[0..n]);
        }
        tried += 1;
    }
    try testing.expect(tried > 10);
}

test "an output one byte short is OutputTooSmall, without partial" {
    const gpa = testing.allocator;
    const c = try corpus.Corpus.parse(corpus.streams);
    var it = c.records();
    const d = try gpa.create(Decompressor);
    defer gpa.destroy(d);
    d.* = .init;
    while (it.next()) |r| {
        if (r.index % 50 != 0 or r.fields[3].len != 0) continue;
        const in = try corpus.input(gpa, r.fields[2]);
        defer gpa.free(in);
        if (in.len == 0) continue;
        const out = try gpa.alloc(u8, in.len - 1);
        defer gpa.free(out);
        try testing.expectError(error.OutputTooSmall, d.inflate(r.fields[5], out, .{ .accept = accept(r.fields[4]) }));
    }
}
