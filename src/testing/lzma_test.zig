//! LZMA, LZMA2, `.lzma` and `.xz` decoding against liblzma 5.8.4: its
//! streams decoded to their inputs, and its verdicts on constructed and
//! mutated streams given for the same reasons.

const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const corpus = @import("corpus.zig");
const lzma = @import("../lzma.zig");
const xz = @import("../xz.zig");

const streams_corpus = @embedFile("xz-streams.corpus");
const invalid_corpus = @embedFile("xz-invalid.corpus");

const Error = xz.Decompressor.Error;

const Decoders = struct { lzma: lzma.Decompressor = .init, xz: xz.Decompressor = .init };

fn input(gpa: std.mem.Allocator, spec: []const u8) ![]u8 {
    return if (spec.len == 0) gpa.alloc(u8, 0) else corpus.input(gpa, spec);
}

/// A `key=value` of a format's text.
fn field(format: []const u8, comptime key: []const u8) ?[]const u8 {
    const at = (std.mem.find(u8, format, " " ++ key ++ "=") orelse return null) + key.len + 2;
    const end = std.mem.findScalarPos(u8, format, at, ' ') orelse format.len;
    return format[at..end];
}

fn number(format: []const u8, comptime key: []const u8) !u64 {
    return std.fmt.parseInt(u64, field(format, key) orelse return error.BadCorpus, 10);
}

/// `in` decoded as the record's format says; null for formats this file
/// does not read.
fn decodeAs(d: *Decoders, format: []const u8, in: []const u8, out: []u8, diag: *lzma.Diagnostic) !?(Error!lzma.Decompressor.Result) {
    if (std.mem.eql(u8, format, "xz")) return d.xz.decompress(in, out, .{ .diagnostic = diag });
    if (std.mem.eql(u8, format, "xz one")) return d.xz.decompress(in, out, .{ .streams = .one, .diagnostic = diag });
    if (std.mem.eql(u8, format, "lzma")) return d.lzma.decompressAlone(in, out, .{ .diagnostic = diag });
    if (std.mem.startsWith(u8, format, "lzma1 ")) {
        const size = field(format, "size") orelse return error.BadCorpus;
        return d.lzma.decompressLzma1(in, out, .{
            .properties = .{ .lc = @intCast(try number(format, "lc")), .lp = @intCast(try number(format, "lp")), .pb = @intCast(try number(format, "pb")) },
            .dictionary = @intCast(try number(format, "dict")),
            .size = if (std.mem.eql(u8, size, "unknown")) null else try std.fmt.parseInt(u64, size, 10),
            .diagnostic = diag,
        });
    }
    if (std.mem.startsWith(u8, format, "lzma2 ")) return d.lzma.decompressLzma2(in, out, .{ .dictionary = @intCast(try number(format, "dict")), .diagnostic = diag });
    return null;
}

test "liblzma's LZMA, LZMA2, .lzma and .xz streams decode to their inputs" {
    const gpa = testing.allocator;
    var d: Decoders = .{};
    const c = try corpus.Corpus.parse(streams_corpus);
    var it = c.records();
    var count: usize = 0;
    while (it.next()) |r| {
        errdefer std.debug.print("{s} {s} ({s}): {s}\n", .{ r.fields[0], r.fields[1], r.fields[2], r.fields[3] });
        const in = try input(gpa, r.fields[3]);
        defer gpa.free(in);
        const out = try gpa.alloc(u8, in.len + 1);
        defer gpa.free(out);
        var diag: lzma.Diagnostic = .{};
        const result = (try decodeAs(&d, r.fields[1], r.fields[4], out, &diag)) orelse continue;
        count += 1;
        const got = result catch |err| {
            std.debug.print("{s} at {d}\n", .{ @tagName(diag.reason), diag.offset.raw() });
            return err;
        };
        try testing.expectEqual(try std.fmt.parseInt(usize, r.fields[5], 10), got.in_len);
        try testing.expectEqualSlices(u8, in, out[0..got.out_len]);
        if (in.len != 0) try testing.expectError(error.OutputTooSmall, (try decodeAs(&d, r.fields[1], r.fields[4], out[0 .. in.len - 1], &diag)).?);
    }
    try testing.expectEqual(131, count);
}

/// liblzma's verdict, as warp answers it.
fn agrees(verdict: []const u8, result: Error!lzma.Decompressor.Result, out: []const u8) !void {
    if (std.mem.startsWith(u8, verdict, "ok ")) {
        const r = try result;
        var h: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(out[0..r.out_len], &h, .{});
        var want: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&want, verdict[3..]);
        try testing.expectEqualSlices(u8, &want, &h);
    } else if (std.mem.eql(u8, verdict, "LZMA_BUF_ERROR")) {
        try testing.expectError(error.Truncated, result);
    } else if (result) |_| return error.TestUnexpectedResult else |err| {
        try testing.expect(err == error.InvalidStream or err == error.ChecksumMismatch);
    }
}

test "liblzma's verdicts on LZMA, LZMA2, .lzma and .xz streams are warp's" {
    const gpa = testing.allocator;
    var d: Decoders = .{};
    const out = try gpa.alloc(u8, 64 << 20);
    defer gpa.free(out);
    const c = try corpus.Corpus.parse(invalid_corpus);
    var it = c.records();
    var count: usize = 0;
    while (it.next()) |r| {
        errdefer std.debug.print("{s} ({s}): {s}\n", .{ r.fields[0], r.fields[1], r.fields[3] });
        var diag: lzma.Diagnostic = .{};
        const result = (try decodeAs(&d, r.fields[1], r.fields[2], out, &diag)) orelse continue;
        count += 1;
        agrees(r.fields[3], result, out) catch |err| {
            std.debug.print("warp: {s} at {d}\n", .{ @tagName(diag.reason), diag.offset.raw() });
            return err;
        };
    }
    try testing.expect(count > 300);
}

/// The resumable decoder's format for a record's, null for .xz.
fn resumableFormat(format: []const u8) !?lzma.Decompress.Format {
    if (std.mem.eql(u8, format, "lzma")) return .alone;
    if (std.mem.startsWith(u8, format, "lzma1 ")) {
        const size = field(format, "size") orelse return error.BadCorpus;
        return .{ .lzma1 = .{
            .properties = .{ .lc = @intCast(try number(format, "lc")), .lp = @intCast(try number(format, "lp")), .pb = @intCast(try number(format, "pb")) },
            .dictionary = @intCast(try number(format, "dict")),
            .size = if (std.mem.eql(u8, size, "unknown")) null else try std.fmt.parseInt(u64, size, 10),
        } };
    }
    if (std.mem.startsWith(u8, format, "lzma2 ")) return .{ .lzma2 = .{ .dictionary = @intCast(try number(format, "dict")) } };
    return null;
}

/// What the resumable decoder makes of `in` given in pieces of `cut` bytes
/// (0: whole) into pieces of output of `out_cut` bytes.
fn streamed(gpa: std.mem.Allocator, format: lzma.Decompress.Format, in: []const u8, out: []u8, cut: usize, out_cut: usize) !lzma.Decompressor.Result {
    const window = try gpa.alloc(u8, 64 << 20);
    defer gpa.free(window);
    var z: lzma.Decompress = .init(window, format, .{});
    var ip: usize = 0;
    var op: usize = 0;
    while (true) {
        const piece = in[ip..@min(in.len, ip + if (cut == 0) in.len else cut)];
        const room = out[op..@min(out.len, op + if (out_cut == 0) out.len else out_cut)];
        const step = try z.decode(piece, room);
        ip += step.in_len;
        op += step.out_len;
        switch (step.status) {
            .end => return .{ .in_len = ip, .out_len = op },
            .output_full => if (op == out.len) return error.OutputTooSmall,
            .need_input => if (ip == in.len) {
                try z.finish();
                return .{ .in_len = ip, .out_len = op };
            },
        }
    }
}

test "liblzma's LZMA, LZMA2 and .lzma streams decode in pieces of any size, to their exact end" {
    const gpa = testing.allocator;
    const c = try corpus.Corpus.parse(streams_corpus);
    var it = c.records();
    var count: usize = 0;
    while (it.next()) |r| {
        const format = try resumableFormat(r.fields[1]) orelse continue;
        errdefer std.debug.print("{s} {s} ({s}): {s}\n", .{ r.fields[0], r.fields[1], r.fields[2], r.fields[3] });
        count += 1;
        const in = try input(gpa, r.fields[3]);
        defer gpa.free(in);
        const out = try gpa.alloc(u8, in.len + 1);
        defer gpa.free(out);
        const stream = r.fields[4];
        // Followed by bytes that are no part of it: never taken.
        const followed = try std.mem.concat(gpa, u8, &.{ stream, "trailing" });
        defer gpa.free(followed);
        for ([_][2]usize{ .{ 1, 0 }, .{ 7, 3 }, .{ 4096, 1000 }, .{ 0, 65536 } }) |cuts| {
            if (cuts[0] == 1 and stream.len > 30_000) continue;
            const got = try streamed(gpa, format, followed, out, cuts[0], cuts[1]);
            try testing.expectEqual(try std.fmt.parseInt(usize, r.fields[5], 10), got.in_len);
            try testing.expectEqualSlices(u8, in, out[0..got.out_len]);
        }
    }
    try testing.expectEqual(50, count);
}

/// What the resumable .xz decoder makes of `in` in pieces, its window
/// given as each block's header asks, up to 64 MiB.
fn streamedXz(gpa: std.mem.Allocator, streams: xz.Streams, in: []const u8, out: []u8, cut: usize, out_cut: usize) (xz.Decompress.Error || error{ OutputTooSmall, OutOfMemory })!lzma.Decompressor.Result {
    var window: []u8 = &.{};
    defer gpa.free(window);
    var z: xz.Decompress = .init(window, .{ .streams = streams });
    var ip: usize = 0;
    var op: usize = 0;
    while (true) {
        const piece = in[ip..@min(in.len, ip + if (cut == 0) in.len else cut)];
        const room = out[op..@min(out.len, op + if (out_cut == 0) out.len else out_cut)];
        const step = try z.decode(piece, room);
        ip += step.in_len;
        op += step.out_len;
        switch (step.status) {
            .done => return .{ .in_len = ip, .out_len = op },
            .output_full => if (op == out.len) return error.OutputTooSmall,
            .need_input => if (ip == in.len) {
                try z.finish();
                return .{ .in_len = ip, .out_len = op };
            },
            .need_window => {
                if (z.windowNeeded() > 64 << 20) return z.refuseWindow();
                gpa.free(window);
                window = &.{};
                window = try gpa.alloc(u8, z.windowNeeded());
                z.setWindow(window);
            },
        }
    }
}

test "liblzma's .xz streams decode in pieces of any size, the first stream to its exact end" {
    const gpa = testing.allocator;
    const c = try corpus.Corpus.parse(streams_corpus);
    var it = c.records();
    var count: usize = 0;
    while (it.next()) |r| {
        const one = std.mem.eql(u8, r.fields[1], "xz one");
        if (!one and !std.mem.eql(u8, r.fields[1], "xz")) continue;
        errdefer std.debug.print("{s} {s} ({s}): {s}\n", .{ r.fields[0], r.fields[1], r.fields[2], r.fields[3] });
        count += 1;
        const in = try input(gpa, r.fields[3]);
        defer gpa.free(in);
        const out = try gpa.alloc(u8, in.len + 1);
        defer gpa.free(out);
        const stream = r.fields[4];
        const in_len = try std.fmt.parseInt(usize, r.fields[5], 10);
        for ([_][2]usize{ .{ 1, 0 }, .{ 7, 3 }, .{ 4096, 1000 }, .{ 0, 65536 } }) |cuts| {
            if (cuts[0] == 1 and stream.len > 30_000) continue;
            const got = try streamedXz(gpa, if (one) .one else .all, stream, out, cuts[0], cuts[1]);
            try testing.expectEqual(in_len, got.in_len);
            try testing.expectEqualSlices(u8, in, out[0..got.out_len]);
        }
    }
    try testing.expectEqual(81, count);
}

test "liblzma's verdicts on .xz streams are the resumable decoder's too" {
    const gpa = testing.allocator;
    const out = try gpa.alloc(u8, 64 << 20);
    defer gpa.free(out);
    const c = try corpus.Corpus.parse(invalid_corpus);
    var it = c.records();
    while (it.next()) |r| {
        if (!std.mem.eql(u8, r.fields[1], "xz")) continue;
        errdefer std.debug.print("{s}: {s}\n", .{ r.fields[0], r.fields[3] });
        const got = streamedXz(gpa, .all, r.fields[2], out, 13, 0);
        try agrees(r.fields[3], if (got) |g| g else |err| switch (err) {
            error.WindowTooLarge, error.OutOfMemory => return err,
            else => |e| e,
        }, out);
    }
}

/// Arbitrary bytes, or a corpus stream mutated, as .xz and as .lzma: the
/// resumable decoders at any cuts answer as the whole-buffer ones.
fn anyStream(d: *Decoders, case: *shakedown.Case) !void {
    const s = case.source;
    const in = if (shakedown.gen.boolean(s)) try shakedown.gen.string(s, case.gpa, .{ .kind = .bytes, .max_len = 600, .average = 80 }) else blk: {
        const c = try corpus.Corpus.parse(streams_corpus);
        var it = c.records();
        var r = it.next().?;
        for (0..shakedown.gen.intRange(s, usize, 0, 130)) |_| r = it.next() orelse break;
        const bytes = try case.gpa.dupe(u8, r.fields[4][0..@min(r.fields[4].len, 3000)]);
        for (0..shakedown.gen.intRange(s, usize, 0, 4)) |_| bytes[shakedown.gen.intRange(s, usize, 0, bytes.len - 1)] ^= @as(u8, 1) << shakedown.gen.int(s, u3);
        break :blk bytes;
    };
    case.note("{d} bytes", .{in.len});
    const out = try case.gpa.alloc(u8, 1 << 20);
    const back = try case.gpa.alloc(u8, out.len);
    const cut = shakedown.gen.intRange(s, usize, 1, 200);
    const out_cut = shakedown.gen.intRange(s, usize, 0, 5000);
    {
        const whole = d.xz.decompress(in, out, .{});
        const got = streamedXz(case.gpa, .all, in, back, cut, out_cut);
        if (whole) |w| {
            const g = try got;
            try testing.expectEqual(w.in_len, g.in_len);
            try testing.expectEqualSlices(u8, out[0..w.out_len], back[0..g.out_len]);
        } else |err| try testing.expectError(err, got);
    }
    {
        const whole = d.lzma.decompressAlone(in, out, .{});
        const got = streamed(case.gpa, .alone, in, back, cut, out_cut);
        // A header naming a dictionary past the 64 MiB window the helper
        // gives is refused before its data.
        if (got) |_| {} else |err| if (err == error.WindowTooLarge) return;
        if (whole) |w| {
            const g = try got;
            try testing.expectEqual(w.in_len, g.in_len);
            try testing.expectEqualSlices(u8, out[0..w.out_len], back[0..g.out_len]);
        } else |err| switch (err) {
            // The resumable decoder's window is the 64 MiB the helper gives.
            error.Truncated, error.InvalidStream => try testing.expectError(err, got),
            else => {},
        }
    }
}

test "fuzz: any bytes into the resumable LZMA and .xz decoders at any cuts answer as the whole-buffer ones" {
    var d: Decoders = .{};
    try shakedown.check(testing.allocator, &d, anyStream, .{ .cases = 300 });
}

test "the reader adapters read what the decoders write, and leave what follows the stream" {
    const gpa = testing.allocator;
    const c = try corpus.Corpus.parse(streams_corpus);
    var it = c.records();
    const window = try gpa.alloc(u8, 16 << 20);
    defer gpa.free(window);
    var buffer: [4096]u8 = undefined;
    var seen: usize = 0;
    while (it.next()) |r| {
        const is_xz = std.mem.eql(u8, r.fields[1], "xz one");
        const format = try resumableFormat(r.fields[1]);
        if (!is_xz and format == null) continue;
        if (!std.mem.eql(u8, r.fields[3], "json 6 40000") and !is_xz) continue;
        seen += 1;
        const in = try input(gpa, r.fields[3]);
        defer gpa.free(in);
        const in_len = try std.fmt.parseInt(usize, r.fields[5], 10);
        var source: std.Io.Reader = .fixed(r.fields[4]);
        const got = if (is_xz) blk: {
            var reader: xz.Decompress.Reader = .init(gpa, &source, &buffer, 16 << 20, .{ .streams = .one });
            defer reader.deinit();
            break :blk try reader.interface.allocRemaining(gpa, .unlimited);
        } else blk: {
            var reader: lzma.Decompress.Reader = .init(&source, &buffer, window, format.?, .{});
            break :blk try reader.interface.allocRemaining(gpa, .unlimited);
        };
        defer gpa.free(got);
        try testing.expectEqualSlices(u8, in, got);
        try testing.expectEqual(in_len, source.seek);
    }
    try testing.expect(seen >= 10);
}

test "the parallel .xz decoder answers as the whole-buffer one, and decodes multi-block streams in workers" {
    const gpa = testing.allocator;
    var d: xz.Decompressor = .init;
    const out = try gpa.alloc(u8, 4 << 20);
    defer gpa.free(out);
    const back = try gpa.alloc(u8, out.len);
    defer gpa.free(back);
    var stats: xz.parallel.Decompressor.Statistics = .{};
    var p: xz.parallel.Decompressor = try .init(gpa, .{ .concurrency = 3, .statistics = &stats });
    defer p.deinit();
    var parallel_blocks: usize = 0;
    for ([_][]const u8{ streams_corpus, invalid_corpus }, [_]usize{ 4, 2 }, [_]usize{ 1, 3 }) |text, stream_field, format_field| {
        const c = try corpus.Corpus.parse(text);
        var it = c.records();
        while (it.next()) |r| {
            const one = std.mem.eql(u8, r.fields[format_field], "xz one");
            if (!one and !std.mem.eql(u8, r.fields[format_field], "xz")) continue;
            errdefer std.debug.print("{s}\n", .{r.fields[0]});
            const in = r.fields[stream_field];
            const options: xz.Decompressor.Options = .{ .streams = if (one) .one else .all };
            var want_diag: lzma.Diagnostic = .{};
            var got_diag: lzma.Diagnostic = .{};
            const want = d.decompress(in, out, .{ .streams = options.streams, .diagnostic = &want_diag });
            const got = p.decompress(testing.io, in, back, .{ .streams = options.streams, .diagnostic = &got_diag });
            if (want) |w| {
                const g = try got;
                try testing.expectEqual(w, g);
                try testing.expectEqualSlices(u8, out[0..w.out_len], back[0..g.out_len]);
                if (!stats.serial) parallel_blocks += stats.parallel;
            } else |err| {
                try testing.expectError(err, got);
                try testing.expectEqual(want_diag, got_diag);
            }
        }
    }
    // The two multi-block streams (10 and 4 blocks) and the single-block
    // ones with sizes.
    try testing.expect(parallel_blocks >= 14);
}

test "liblzma's filtered .xz streams: their LZMA2 through xz.FilterReader, one reader a filter, is the input" {
    const format = @import("../xz/format.zig");
    const gpa = testing.allocator;
    const c = try corpus.Corpus.parse(streams_corpus);
    var it = c.records();
    var count: usize = 0;
    while (it.next()) |r| {
        if (!std.mem.eql(u8, r.fields[1], "xz") or std.mem.find(u8, r.fields[2], "filters ") == null) continue;
        errdefer std.debug.print("{s} ({s}): {s}\n", .{ r.fields[1], r.fields[2], r.fields[3] });
        count += 1;
        const in = try input(gpa, r.fields[3]);
        defer gpa.free(in);
        const stream = r.fields[4];
        const check = switch (format.streamHeader(stream[0..format.header_len])) {
            .check => |k| k,
            .fault => return error.TestUnexpectedResult,
        };
        const block = stream[format.header_len..];
        var fault: format.Fault = undefined;
        const header = try format.blockHeader(.{ .check = check, .fault = &fault }, block[0 .. (@as(usize, block[0]) + 1) * 4]);
        // liblzma's filtered bytes: the block's LZMA2, decoded alone.
        var source: std.Io.Reader = .fixed(block[header.len..]);
        const window = try gpa.alloc(u8, lzma.Decompress.windowLength(header.dictionary));
        defer gpa.free(window);
        var lzma_buffer: [4096]u8 = undefined;
        var lzma2: lzma.Decompress.Reader = .init(&source, &lzma_buffer, window, .{ .lzma2 = .{ .dictionary = header.dictionary } }, .{});
        // Each filter undone, the last applied first.
        var readers: [3]xz.FilterReader = undefined;
        var buffers: [3][300]u8 = undefined;
        var top: *std.Io.Reader = &lzma2.interface;
        var i: usize = header.filter_count;
        while (i > 0) {
            i -= 1;
            readers[i] = .init(top, &buffers[i], header.filters[i]);
            top = &readers[i].interface;
        }
        const out = try gpa.alloc(u8, in.len + 1);
        defer gpa.free(out);
        const n = try top.readSliceShort(out);
        try testing.expectEqualSlices(u8, in, out[0..n]);
    }
    try testing.expectEqual(12, count);
}

/// `s` `n` times over.
fn repeated(comptime s: []const u8, comptime n: usize) *const [s.len * n]u8 {
    const text = comptime blk: {
        var out: [s.len * n]u8 = undefined;
        for (0..n) |i| @memcpy(out[i * s.len ..][0..s.len], s);
        break :blk out;
    };
    return &text;
}

/// `in` as one .xz stream, compressed at liblzma's preset `level`.
fn xzStream(gpa: std.mem.Allocator, in: []const u8, level: u4) ![]u8 {
    const options: xz.Compressor.Options = .{ .lzma = .preset(level, false) };
    var c: xz.Compressor = try .init(gpa, options);
    defer c.deinit();
    const out = try gpa.alloc(u8, xz.Compressor.bound(options, in.len));
    errdefer gpa.free(out);
    const n = try c.compress(in, out);
    return gpa.realloc(out, n);
}

test "the .xz reader sizes its window from each block's header: grown for a larger dictionary, refused past its limit" {
    const gpa = testing.allocator;
    const first = comptime repeated("a first stream, at preset 0: a 256 KiB dictionary. ", 40);
    const second = comptime repeated("a second stream, at preset 1: a 1 MiB dictionary. ", 40);
    const small = try xzStream(gpa, first, 0);
    defer gpa.free(small);
    const large = try xzStream(gpa, second, 1);
    defer gpa.free(large);
    const both = try std.mem.concat(gpa, u8, &.{ small, large });
    defer gpa.free(both);
    var buffer: [4096]u8 = undefined;

    // Room for both: the window grows at the second stream's block.
    {
        var source: std.Io.Reader = .fixed(both);
        var reader: xz.Decompress.Reader = .init(gpa, &source, &buffer, xz.Decompress.windowLength(1 << 20), .{});
        defer reader.deinit();
        const got = try reader.interface.allocRemaining(gpa, .unlimited);
        defer gpa.free(got);
        try testing.expectEqualStrings(first ++ second, got);
        try testing.expectEqual(xz.Decompress.windowLength(1 << 20), reader.state.window.len);
    }

    // Room for the first only: the second's block header is refused, where
    // it starts.
    {
        var diagnostic: lzma.Diagnostic = .{};
        var source: std.Io.Reader = .fixed(both);
        var reader: xz.Decompress.Reader = .init(gpa, &source, &buffer, xz.Decompress.windowLength(256 << 10), .{ .diagnostic = &diagnostic });
        defer reader.deinit();
        try testing.expectError(error.ReadFailed, reader.interface.allocRemaining(gpa, .unlimited));
        try testing.expectEqual(error.WindowTooLarge, reader.err().?);
        try testing.expectEqual(lzma.Diagnostic.Reason.memory_limit, diagnostic.reason);
        // The second stream's header, then its block's.
        try testing.expectEqual(small.len + 12, diagnostic.offset.raw());
    }
}
