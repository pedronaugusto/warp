//! The zstd decoder against the format's reference library (zstd 1.5.7):
//! every frame it wrote decodes to its input, every frame it judged gets
//! its judgment, every prefix of a frame is `Truncated`, and what frames
//! say about themselves agrees with what they decode to.

const std = @import("std");
const testing = std.testing;
const gen = @import("gen");
const corpus = @import("corpus.zig");
const Decompressor = @import("../zstd/Decompressor.zig");
const Dictionary = @import("../zstd/Dictionary.zig");
const Diagnostic = @import("../zstd/Diagnostic.zig");
const frame = @import("../zstd/frame.zig");
const decode = @import("../zstd/decode.zig");
const zstd = @import("../zstd.zig");

pub const frames = @embedFile("zstd-frames.corpus");
pub const invalid = @embedFile("zstd-invalid.corpus");
pub const dictionaries = @embedFile("zstd-dictionaries.corpus");

/// An input named by specs joined with " + ".
pub fn input(gpa: std.mem.Allocator, expr: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var it = std.mem.splitSequence(u8, expr, " + ");
    while (it.next()) |part| {
        const s = try gen.Spec.parse(part);
        const at = out.items.len;
        try out.resize(gpa, at + s.len);
        gen.fill(s.kind, s.seed, out.items[at..]);
    }
    return out.toOwnedSlice(gpa);
}

/// The corpus's dictionaries, parsed, by name.
pub const Dictionaries = struct {
    names: [8][]const u8 = undefined,
    values: [8]*Dictionary = undefined,
    count: usize = 0,

    pub fn load(gpa: std.mem.Allocator) !Dictionaries {
        var d: Dictionaries = .{};
        const c = try corpus.Corpus.parse(dictionaries);
        var it = c.records();
        while (it.next()) |r| {
            const value = try gpa.create(Dictionary);
            value.* = try Dictionary.parse(r.fields[1]);
            d.names[d.count] = r.fields[0];
            d.values[d.count] = value;
            d.count += 1;
        }
        return d;
    }

    pub fn deinit(d: *Dictionaries, gpa: std.mem.Allocator) void {
        for (d.values[0..d.count]) |v| gpa.destroy(v);
        d.* = undefined;
    }

    /// The dictionaries a decoder is given for `name` ("" for none).
    pub fn get(d: *const Dictionaries, name: []const u8) []const *const Dictionary {
        if (name.len == 0) return &.{};
        for (d.names[0..d.count], 0..) |n, i| if (std.mem.eql(u8, n, name)) return @ptrCast(d.values[i .. i + 1]);
        std.debug.panic("no dictionary {s}", .{name});
    }
};

fn format(params: []const u8) frame.Format {
    return if (std.mem.find(u8, params, "magicless=true") != null) .magicless else .standard;
}

test "every frame the reference wrote decodes to its input, with an exact output and with the margin" {
    const gpa = testing.allocator;
    var dicts: Dictionaries = try .load(gpa);
    defer dicts.deinit(gpa);
    try testing.expect(@sizeOf(Decompressor) <= 96 << 10);
    const d = try gpa.create(Decompressor);
    defer gpa.destroy(d);
    d.* = .init;
    const c = try corpus.Corpus.parse(frames);
    var it = c.records();
    var count: usize = 0;
    while (it.next()) |r| {
        const params = r.fields[1];
        const in = try input(gpa, r.fields[2]);
        defer gpa.free(in);
        const z = r.fields[4];
        const out = try gpa.alloc(u8, in.len + decode.margin);
        defer gpa.free(out);
        for ([_]usize{ in.len, in.len + decode.margin }) |out_len| {
            var diag: Diagnostic = .{};
            const result = d.decompress(z, out[0..out_len], .{ .dictionaries = dicts.get(r.fields[3]), .format = format(params), .diagnostic = &diag }) catch |err| {
                std.debug.print("{s} | {s} | {s}: {t} ({t} at {d})\n", .{ params, r.fields[2], r.fields[3], err, diag.reason, diag.offset });
                return err;
            };
            try testing.expectEqual(in.len, result.out_len);
            try testing.expectEqualSlices(u8, in, out[0..in.len]);
            try testing.expectEqual(z.len, result.in_len);
            try testing.expect(result.finished);
        }
        count += 1;
    }
    try testing.expect(count > 1500);
}

/// What a reference error means for warp: the errors that say it, and
/// for `InvalidStream` the reasons that may (empty: any).
const Expected = struct { errs: []const anyerror, reasons: []const Diagnostic.Reason = &.{} };

fn expected(code: []const u8) Expected {
    const Map = struct { []const u8, Expected };
    const table = [_]Map{
        .{ "prefix_unknown", .{ .errs = &.{error.InvalidStream}, .reasons = &.{ .bad_magic, .trailing_data } } },
        .{ "srcSize_wrong", .{ .errs = &.{ error.Truncated, error.InvalidStream }, .reasons = &.{ .trailing_data, .block_too_large, .bad_magic, .truncated } } },
        .{ "corruption_detected", .{ .errs = &.{error.InvalidStream} } },
        .{ "literals_headerWrong", .{ .errs = &.{error.InvalidStream}, .reasons = &.{.bad_literals_header} } },
        .{ "checksum_wrong", .{ .errs = &.{ error.ChecksumMismatch, error.Truncated } } },
        .{ "dictionary_wrong", .{ .errs = &.{error.DictionaryMismatch} } },
        .{ "dictionary_corrupted", .{ .errs = &.{error.InvalidStream}, .reasons = &.{ .treeless_first, .repeat_first } } },
        .{ "frameParameter_windowTooLarge", .{ .errs = &.{error.WindowTooLarge} } },
        .{ "frameParameter_unsupported", .{ .errs = &.{error.InvalidStream}, .reasons = &.{ .reserved_bit, .bad_magic } } },
        .{ "dstSize_tooSmall", .{ .errs = &.{error.OutputTooSmall} } },
        .{ "tableLog_tooLarge", .{ .errs = &.{error.InvalidStream} } },
        .{ "maxSymbolValue_tooSmall", .{ .errs = &.{error.InvalidStream} } },
        .{ "GENERIC", .{ .errs = &.{error.InvalidStream} } },
    };
    for (table) |m| if (std.mem.eql(u8, m[0], code)) return m[1];
    std.debug.panic("unmapped reference error: {s}", .{code});
}

test "every frame the reference judged gets its judgment, for the same reason" {
    const gpa = testing.allocator;
    var dicts: Dictionaries = try .load(gpa);
    defer dicts.deinit(gpa);
    const d = try gpa.create(Decompressor);
    defer gpa.destroy(d);
    d.* = .init;
    const c = try corpus.Corpus.parse(invalid);
    var it = c.records();
    var failures: usize = 0;
    var count: usize = 0;
    while (it.next()) |r| {
        const name = r.fields[0];
        const z = r.fields[2];
        const capacity = try std.fmt.parseInt(usize, r.fields[3], 10);
        const verdict = r.fields[4];
        const out = try gpa.alloc(u8, capacity);
        defer gpa.free(out);
        var diag: Diagnostic = .{};
        const got = d.decompress(z, out, .{ .dictionaries = dicts.get(r.fields[1]), .diagnostic = &diag, .max_window = std.math.maxInt(u64) });
        count += 1;
        if (std.mem.startsWith(u8, verdict, "ok ")) {
            var parts = std.mem.splitScalar(u8, verdict[3..], ' ');
            const len = try std.fmt.parseInt(usize, parts.next().?, 10);
            const hash = try std.fmt.parseInt(u64, parts.next().?, 16);
            const result = got catch |err| {
                std.debug.print("{s}: reference decodes {d} bytes, warp says {t} ({t} at {d})\n", .{ name, len, err, diag.reason, diag.offset });
                failures += 1;
                continue;
            };
            if (result.out_len != len or std.hash.XxHash64.hash(0, out[0..result.out_len]) != hash) {
                std.debug.print("{s}: reference decodes {d} bytes, warp {d} bytes, other content\n", .{ name, len, result.out_len });
                failures += 1;
            }
            continue;
        }
        const want = expected(verdict[4..]);
        if (got) |result| {
            std.debug.print("{s}: reference says {s}, warp decodes {d} bytes\n", .{ name, verdict, result.out_len });
            failures += 1;
            continue;
        } else |err| {
            const err_ok = for (want.errs) |e| {
                if (e == err) break true;
            } else false;
            const reason_ok = err != error.InvalidStream or want.reasons.len == 0 or for (want.reasons) |reason| {
                if (reason == diag.reason) break true;
            } else false;
            if (!err_ok or !reason_ok) {
                std.debug.print("{s}: reference says {s}, warp says {t} ({t} at {d})\n", .{ name, verdict, err, diag.reason, diag.offset });
                failures += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
    try testing.expect(count > 1500);
}

test "every prefix of a frame is Truncated, and frames measure themselves as they decode" {
    const gpa = testing.allocator;
    var dicts: Dictionaries = try .load(gpa);
    defer dicts.deinit(gpa);
    const d = try gpa.create(Decompressor);
    defer gpa.destroy(d);
    d.* = .init;
    const c = try corpus.Corpus.parse(frames);
    var it = c.records();
    var checked: usize = 0;
    while (it.next()) |r| {
        const params = r.fields[1];
        if (format(params) != .standard or std.mem.startsWith(u8, params, "concatenated")) continue;
        const z = r.fields[4];
        const in = try input(gpa, r.fields[2]);
        defer gpa.free(in);
        // What the frame says about itself.
        var fault: frame.Fault = undefined;
        const extent = try frame.extent(z, .standard, &fault);
        try testing.expectEqual(z.len, extent.len);
        try testing.expect(extent.bound >= in.len);
        const header = (try frame.parse(z, .standard, &fault)).zstd;
        if (header.content_size) |size| try testing.expectEqual(@as(u64, in.len), size);
        if (z.len > 2000 or checked >= 200) continue;
        checked += 1;
        const out = try gpa.alloc(u8, in.len);
        defer gpa.free(out);
        for (1..z.len) |n| {
            var diag: Diagnostic = .{};
            if (d.decompress(z[0..n], out, .{ .dictionaries = dicts.get(r.fields[3]), .frames = .one, .diagnostic = &diag })) |_| {
                std.debug.print("{s} {s}: the first {d} of {d} bytes decode\n", .{ params, r.fields[2], n, z.len });
                return error.TestUnexpectedResult;
            } else |err| {
                if (err != error.Truncated) {
                    std.debug.print("{s} {s}: the first {d} of {d} bytes: {t} ({t} at {d})\n", .{ params, r.fields[2], n, z.len, err, diag.reason, diag.offset });
                    return err;
                }
            }
        }
    }
    try testing.expect(checked >= 200);
}

test "zstd frame inspection: public helpers count concatenated and skippable frames" {
    var c = try zstd.Compressor.init(testing.allocator, .{ .max_input = 1024 });
    defer c.deinit();
    var out: [256]u8 = undefined;
    const a = try c.compress("abcabcabcabc", &out, .{});
    const b = try zstd.writeSkippable(out[a..], 9, "padding");
    const d = try c.compress("hello hello", out[a + b ..], .{});
    try testing.expectEqual(@as(?u64, 23), try zstd.contentSize(out[0 .. a + b + d], .standard));
    try testing.expectEqual(@as(u64, 23), try zstd.decompressBound(out[0 .. a + b + d], .standard));
    try testing.expectEqual(a, try zstd.frameLength(out[0 .. a + b + d], .standard));
    try testing.expectEqual(@as(?u64, 12), (try zstd.frameHeader(out[0..a], .standard)).zstd.content_size);
    const e = try c.compress("no declared size", &out, .{ .content_size = false });
    try testing.expectEqual(@as(?u64, null), try zstd.contentSize(out[0..e], .standard));
    try testing.expect((try zstd.decompressBound(out[0..e], .standard)) >= 16);
    try testing.expectError(error.Truncated, zstd.frameLength(out[0 .. e - 1], .standard));
}

test "zstd decode: caller window limit is checked for memory and reader inputs" {
    const d = try testing.allocator.create(Decompressor);
    defer testing.allocator.destroy(d);
    d.* = .init;
    const in = [_]u8{ 0x28, 0xb5, 0x2f, 0xfd, 0x00, 0x10, 0x01, 0x00, 0x00 };
    var diag: Diagnostic = .{};
    try testing.expectError(error.WindowTooLarge, d.decompress(&in, &.{}, .{ .max_window = 1024, .diagnostic = &diag }));
    try testing.expectEqual(Diagnostic.Reason.window_too_large, diag.reason);
    var r: std.Io.Reader = .fixed(&in);
    try testing.expectError(error.WindowTooLarge, d.decompressReader(&r, &.{}, .{ .max_window = 1024 }));
    try testing.expect((try d.decompress(&in, &.{}, .{ .max_window = 4096 })).finished);
}

test "zstd partial decode: every output length ends at the right literal or match byte" {
    const gpa = testing.allocator;
    const d = try gpa.create(Decompressor);
    defer gpa.destroy(d);
    d.* = .init;
    const in = try gen.alloc(gpa, .json, 39, 2000);
    defer gpa.free(in);
    var c = try zstd.Compressor.init(gpa, .{ .level = 6, .max_input = in.len });
    defer c.deinit();
    const compressed = try gpa.alloc(u8, zstd.Compressor.bound(in.len));
    defer gpa.free(compressed);
    const n = try c.compress(in, compressed, .{});
    const out = try gpa.alloc(u8, in.len);
    defer gpa.free(out);
    for (0..in.len + 1) |len| {
        const r = try d.decompress(compressed[0..n], out[0..len], .{ .partial = true });
        try testing.expectEqual(len, r.out_len);
        try testing.expectEqualSlices(u8, in[0..len], out[0..len]);
        try testing.expectEqual(len == in.len, r.finished);
    }
}

test "zstd partial decode: captured frames give their prefixes, including dictionaries" {
    const gpa = testing.allocator;
    var dicts: Dictionaries = try .load(gpa);
    defer dicts.deinit(gpa);
    const d = try gpa.create(Decompressor);
    defer gpa.destroy(d);
    d.* = .init;
    const c = try corpus.Corpus.parse(frames);
    var it = c.records();
    var checked: usize = 0;
    while (it.next()) |r| {
        if (std.mem.startsWith(u8, r.fields[1], "concatenated")) continue;
        const in = try input(gpa, r.fields[2]);
        defer gpa.free(in);
        const out = try gpa.alloc(u8, in.len);
        defer gpa.free(out);
        for ([_]usize{ 0, 1, 2, 3, 7, 31, 64, 127, 257, in.len / 2, in.len }) |limit| {
            const len = @min(limit, in.len);
            const decoded = try d.decompress(r.fields[4], out[0..len], .{ .dictionaries = dicts.get(r.fields[3]), .format = format(r.fields[1]), .partial = true });
            try testing.expectEqual(len, decoded.out_len);
            try testing.expectEqualSlices(u8, in[0..len], out[0..len]);
            try testing.expectEqual(len == in.len, decoded.finished);
        }
        checked += 1;
    }
    try testing.expect(checked > 1500);
}
