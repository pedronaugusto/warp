//! LZMA, LZMA2 and `.lzma` encoding: warp's streams decode to their inputs
//! in warp's decoders at every preset and format.

const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const corpus = @import("corpus.zig");
const lzma = @import("../lzma.zig");
const xz = @import("../xz.zig");

const streams_corpus = @embedFile("xz-streams.corpus");

const Options = lzma.Compressor.Options;

/// The presets: 0-9, then 3, 6 and 9 extreme.
const presets = blk: {
    var p: [13]Options = undefined;
    for (0..10) |l| p[l] = .preset(l, false);
    p[10] = .preset(3, true);
    p[11] = .preset(6, true);
    p[12] = .preset(9, true);
    break :blk p;
};

/// `in` through each format at `options` (LZMA2 alone without `all`),
/// decoded back.
fn roundTrip(gpa: std.mem.Allocator, options: Options, in: []const u8, all: bool) !void {
    var c: lzma.Compressor = try .init(gpa, options, .fromRaw(in.len));
    defer c.deinit();
    const out = try gpa.alloc(u8, lzma.Compressor.bound(.{ .lzma1 = .{} }, in.len) + lzma.Compressor.alone_header_len);
    defer gpa.free(out);
    const back = try gpa.alloc(u8, in.len + 1);
    defer gpa.free(back);
    var d: lzma.Decompressor = .init;
    {
        const n = try c.compress(in, out, .lzma2);
        try testing.expect(n <= lzma.Compressor.bound(.lzma2, in.len));
        const r = try d.decompressLzma2(out[0..n], back, .{ .dictionary = options.dictionary });
        try testing.expectEqual(n, r.in_len);
        try testing.expectEqualSlices(u8, in, back[0..r.out_len]);
    }
    if (!all) return;
    for ([_]bool{ false, true }) |marker| {
        const n = try c.compress(in, out, .{ .lzma1 = .{ .end_marker = marker } });
        const r = try d.decompressLzma1(out[0..n], back, .{
            .properties = options.properties,
            .dictionary = options.dictionary,
            .size = if (marker) null else in.len,
        });
        try testing.expectEqual(n, r.in_len);
        try testing.expectEqualSlices(u8, in, back[0..r.out_len]);
    }
    for ([_]bool{ false, true }) |known| {
        const n = try c.compress(in, out, .{ .alone = .{ .size_known = known } });
        const r = try d.decompressAlone(out[0..n], back, .{});
        try testing.expectEqual(n, r.in_len);
        try testing.expectEqualSlices(u8, in, back[0..r.out_len]);
    }
}

/// The corpus's inputs, each once, to `f`.
fn eachInput(gpa: std.mem.Allocator, f: anytype) !void {
    const c = try corpus.Corpus.parse(streams_corpus);
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(gpa);
    var it = c.records();
    while (it.next()) |r| {
        const spec = r.fields[3];
        if ((try seen.getOrPut(gpa, spec)).found_existing) continue;
        const in = if (spec.len == 0) try gpa.alloc(u8, 0) else try corpus.input(gpa, spec);
        defer gpa.free(in);
        errdefer std.debug.print("input {s}\n", .{spec});
        try f.run(gpa, in);
    }
}

test "warp's LZMA, LZMA2 and .lzma streams of short inputs decode to them at every preset" {
    try eachInput(testing.allocator, struct {
        fn run(_: @This(), gpa: std.mem.Allocator, in: []const u8) !void {
            if (in.len > 64 << 10) return;
            for (presets, 0..) |o, i| {
                errdefer std.debug.print("preset {d}\n", .{i});
                try roundTrip(gpa, o, in, true);
            }
        }
    }{});
}

test "warp's LZMA2 streams of long inputs decode to them at presets 0, 3, 6 and 9e" {
    try eachInput(testing.allocator, struct {
        fn run(_: @This(), gpa: std.mem.Allocator, in: []const u8) !void {
            if (in.len <= 64 << 10) return;
            for ([_]usize{ 0, 3, 6, 12 }) |i| {
                errdefer std.debug.print("preset {d}\n", .{i});
                try roundTrip(gpa, presets[i], in, false);
            }
        }
    }{});
}

test "warp's .xz streams decode to their inputs: each check, filter chain and block size" {
    try eachInput(testing.allocator, struct {
        fn run(_: @This(), gpa: std.mem.Allocator, in: []const u8) !void {
            if (in.len > 300_000) return;
            const filters = [_][]const xz.Filter{
                &.{},
                &.{.{ .delta = 4 }},
                &.{.{ .bcj = .{ .kind = .x86, .start = 0 } }},
                &.{ .{ .bcj = .{ .kind = .arm64, .start = 4096 } }, .{ .delta = 1 } },
                &.{ .{ .bcj = .{ .kind = .riscv, .start = 0 } }, .{ .bcj = .{ .kind = .armthumb, .start = 2 } }, .{ .delta = 256 } },
            };
            const checks = [_]xz.Check{ .none, .crc32, .crc64, .sha256 };
            for (filters, 0..) |chain, i| for ([_]?u64{ null, 1, 5000, 1 << 16 }) |block_size| {
                if (block_size == 1 and in.len > 2000) continue;
                const options: xz.Compressor.Options = .{
                    .lzma = .preset(@intCast(i % 4), false),
                    .check = checks[i % checks.len],
                    .filters = chain,
                    .block_size = block_size,
                    .max_input = .fromRaw(in.len),
                };
                errdefer std.debug.print("filters {d} block {?d}\n", .{ i, block_size });
                try xzRoundTrip(gpa, options, in);
            };
        }
    }{});
}

fn xzRoundTrip(gpa: std.mem.Allocator, options: xz.Compressor.Options, in: []const u8) !void {
    var c: xz.Compressor = try .init(gpa, options);
    defer c.deinit();
    const out = try gpa.alloc(u8, xz.Compressor.bound(options, in.len));
    defer gpa.free(out);
    const n = try c.compress(in, out);
    const back = try gpa.alloc(u8, in.len + 1);
    defer gpa.free(back);
    var d: xz.Decompressor = .init;
    const r = try d.decompress(out[0..n], back, .{});
    try testing.expectEqual(n, r.in_len);
    try testing.expectEqualSlices(u8, in, back[0..r.out_len]);
    // The resumable decoder, given the stream and room for its output in
    // pieces, pairs each converter with its own filter as the whole-buffer
    // one does (a chain with a start offset once decoded wrong).
    const window = try gpa.alloc(u8, xz.Decompress.windowLength(options.lzma.dictionary));
    defer gpa.free(window);
    var z: xz.Decompress = .init(window, .{ .streams = .one });
    var ip: usize = 0;
    var op: usize = 0;
    while (true) {
        const step = try z.decode(out[ip..n][0..@min(n - ip, 777)], back[op..][0..@min(back.len - op, 1001)]);
        ip += step.in_len;
        op += step.out_len;
        if (step.status == .done) break;
        try testing.expect(step.in_len != 0 or step.out_len != 0);
    }
    try testing.expectEqual(n, ip);
    try testing.expectEqualSlices(u8, in, back[0..op]);
    // Every block header names its sizes: the parallel decoder splits them.
    var stats: xz.parallel.Decompressor.Statistics = .{};
    var p: xz.parallel.Decompressor = try .init(gpa, .{ .concurrency = 2, .statistics = &stats });
    defer p.deinit();
    const r2 = try p.decompress(testing.io, out[0..n], back, .{});
    try testing.expectEqualSlices(u8, in, back[0..r2.out_len]);
    try testing.expect(!stats.serial);
}

/// `in` through the resumable encoder in pieces of `piece` bytes into
/// outputs of `room` bytes.
fn streamed(gpa: std.mem.Allocator, options: lzma.Compress.Options, in: []const u8, piece: usize, room: usize) ![]u8 {
    var s: lzma.Compress = try .init(gpa, options);
    defer s.deinit();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const buf = try gpa.alloc(u8, room);
    defer gpa.free(buf);
    var at: usize = 0;
    while (at < in.len) {
        const n = @min(piece, in.len - at);
        var part = in[at..][0..n];
        while (true) {
            const step = try s.write(part, buf);
            try out.appendSlice(gpa, buf[0..step.out_len]);
            part = part[step.in_len..];
            if (part.len == 0 and step.out_len < buf.len) break;
        }
        at += n;
    }
    while (true) {
        const d = try s.finish(buf);
        try out.appendSlice(gpa, buf[0..d.out_len]);
        if (d.done) break;
    }
    return out.toOwnedSlice(gpa);
}

test "resumable LZMA, LZMA2 and .lzma encoding writes the whole-buffer encoder's bytes, however the input arrives" {
    try eachInput(testing.allocator, struct {
        fn run(_: @This(), gpa: std.mem.Allocator, in: []const u8) !void {
            if (in.len > 300_000) return;
            const formats = [_]lzma.Compressor.Format{ .lzma2, .{ .lzma1 = .{ .end_marker = true } }, .{ .alone = .{ .size_known = false } }, .{ .alone = .{} } };
            const levels = [_]usize{ 6, 1, 0, 10 };
            for (formats, levels, 0..) |format, level, i| {
                const options: Options = presets[level];
                var c: lzma.Compressor = try .init(gpa, options, null);
                defer c.deinit();
                const whole = try gpa.alloc(u8, lzma.Compressor.bound(format, in.len));
                defer gpa.free(whole);
                const n = try c.compress(in, whole, format);
                for ([_][2]usize{ .{ 1 << 30, 1 << 20 }, .{ 7, 3 }, .{ 4096, 100 } }) |cut| {
                    if (cut[0] < 100 and in.len > 20_000) continue;
                    errdefer std.debug.print("format {d} pieces {d} room {d}\n", .{ i, cut[0], cut[1] });
                    const got = try streamed(gpa, .{ .lzma = options, .format = format, .pledged_size = .fromRaw(in.len) }, in, cut[0], cut[1]);
                    defer gpa.free(got);
                    try testing.expectEqualSlices(u8, whole[0..n], got);
                }
            }
        }
    }{});
}

test "resumable encoding slides its window: a small dictionary over a long input" {
    const gpa = testing.allocator;
    const in = try corpus.input(gpa, "text 11 950000 + zeros 8 300000 + png 10 250000 + text 11 950000");
    defer gpa.free(in);
    for ([_]usize{ 6, 1 }) |level| {
        var options = presets[level];
        options.dictionary = 1 << 16;
        var c: lzma.Compressor = try .init(gpa, options, null);
        defer c.deinit();
        const whole = try gpa.alloc(u8, lzma.Compressor.bound(.lzma2, in.len));
        defer gpa.free(whole);
        const n = try c.compress(in, whole, .lzma2);
        const got = try streamed(gpa, .{ .lzma = options }, in, 100_003, 1 << 16);
        defer gpa.free(got);
        try testing.expectEqualSlices(u8, whole[0..n], got);
        const back = try gpa.alloc(u8, in.len);
        defer gpa.free(back);
        var d: lzma.Decompressor = .init;
        const r = try d.decompressLzma2(got, back, .{ .dictionary = options.dictionary });
        try testing.expectEqualSlices(u8, in, back[0..r.out_len]);
    }
}

/// `in` through the resumable .xz encoder in pieces of `piece` bytes into
/// outputs of `room` bytes, flushed after the first piece if `flush_first`.
fn streamedXz(gpa: std.mem.Allocator, options: xz.Compress.Options, in: []const u8, piece: usize, room: usize, flush_first: bool) ![]u8 {
    var s: xz.Compress = try .init(gpa, options);
    defer s.deinit();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const buf = try gpa.alloc(u8, room);
    defer gpa.free(buf);
    var at: usize = 0;
    var first = true;
    while (at < in.len) {
        const n = @min(piece, in.len - at);
        var part = in[at..][0..n];
        while (true) {
            const step = try s.write(part, buf);
            try out.appendSlice(gpa, buf[0..step.out_len]);
            part = part[step.in_len..];
            if (part.len == 0 and step.out_len < buf.len) break;
        }
        at += n;
        if (first and flush_first) while (true) {
            const d = try s.flush(buf);
            try out.appendSlice(gpa, buf[0..d.out_len]);
            if (d.done) break;
        };
        first = false;
    }
    while (true) {
        const d = try s.finish(buf);
        try out.appendSlice(gpa, buf[0..d.out_len]);
        if (d.done) break;
    }
    return out.toOwnedSlice(gpa);
}

test "resumable .xz encoding: streams decode to their inputs, with and without block sizes and filters" {
    try eachInput(testing.allocator, struct {
        fn run(_: @This(), gpa: std.mem.Allocator, in: []const u8) !void {
            if (in.len > 300_000) return;
            const chains = [_][]const xz.Filter{ &.{}, &.{ .{ .bcj = .{ .kind = .x86, .start = 0 } }, .{ .delta = 2 } } };
            for (chains, 0..) |chain, i| for ([_]?u64{ null, 7000 }) |block_size| for ([_][2]usize{ .{ 1 << 30, 1 << 20 }, .{ 999, 17 } }) |cut| {
                const options: xz.Compress.Options = .{ .lzma = presets[1 + 5 * i], .check = if (i == 0) .crc32 else .sha256, .filters = chain, .block_size = block_size, .pledged_size = .fromRaw(in.len) };
                errdefer std.debug.print("chain {d} block {?d} pieces {d}\n", .{ i, block_size, cut[0] });
                const got = try streamedXz(gpa, options, in, cut[0], cut[1], true);
                defer gpa.free(got);
                const back = try gpa.alloc(u8, in.len + 1);
                defer gpa.free(back);
                var d: xz.Decompressor = .init;
                const r = try d.decompress(got, back, .{});
                try testing.expectEqual(got.len, r.in_len);
                try testing.expectEqualSlices(u8, in, back[0..r.out_len]);
                if (block_size != null and in.len != 0) {
                    var stats: xz.parallel.Decompressor.Statistics = .{};
                    var p: xz.parallel.Decompressor = try .init(gpa, .{ .concurrency = 2, .statistics = &stats });
                    defer p.deinit();
                    _ = try p.decompress(testing.io, got, back, .{});
                    try testing.expect(!stats.serial);
                }
            };
        }
    }{});
}

test "parallel .xz encoding writes the whole-buffer encoder's stream, at any concurrency" {
    try eachInput(testing.allocator, struct {
        fn run(_: @This(), gpa: std.mem.Allocator, in: []const u8) !void {
            if (in.len > 300_000) return;
            for ([_]u64{ 3000, 1 << 16 }) |block_size| {
                const options: xz.Compressor.Options = .{ .lzma = presets[2], .check = .crc64, .filters = &.{.{ .delta = 3 }}, .block_size = block_size };
                var c: xz.Compressor = try .init(gpa, options);
                defer c.deinit();
                const whole = try gpa.alloc(u8, xz.Compressor.bound(options, in.len));
                defer gpa.free(whole);
                const n = try c.compress(in, whole);
                for ([_]u16{ 1, 3 }) |concurrency| {
                    var p: xz.parallel.Compressor = try .init(gpa, .{ .concurrency = concurrency, .xz = options });
                    defer p.deinit();
                    const out = try gpa.alloc(u8, xz.parallel.Compressor.bound(.{ .xz = options }, in.len));
                    defer gpa.free(out);
                    const m = try p.compress(testing.io, in, out);
                    try testing.expectEqualSlices(u8, whole[0..n], out[0..m]);
                }
            }
        }
    }{});
}

/// Any options liblzma's encoder takes, with a small dictionary.
fn anyOptions(s: *shakedown.Source) Options {
    const lc = shakedown.gen.intRange(s, u4, 0, 4);
    const finder = shakedown.gen.enumValue(s, lzma.Compressor.MatchFinder);
    return .{
        .dictionary = shakedown.gen.intRange(s, u32, 4096, 1 << 18),
        .properties = .{ .lc = lc, .lp = @intCast(shakedown.gen.intRange(s, u4, 0, 4 - lc)), .pb = shakedown.gen.intRange(s, u3, 0, 4) },
        .mode = shakedown.gen.enumValue(s, lzma.Compressor.Mode),
        .match_finder = finder,
        .nice_len = shakedown.gen.intRange(s, u32, 2, 273),
        .depth = shakedown.gen.intRange(s, u32, 0, 70),
    };
}

fn anyEncoding(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const gpa = case.gpa;
    const in = if (shakedown.gen.boolean(s)) try shakedown.gen.string(s, gpa, .{ .kind = .bytes, .max_len = 3000, .average = 300 }) else blk: {
        const whole = try corpus.input(gpa, shakedown.gen.oneOf(s, []const u8, &.{ "text 1 20000", "json 6 40000", "binary 5 5000", "runs 7 100000", "png 10 250000" }));
        break :blk whole[0..shakedown.gen.intRange(s, usize, 0, whole.len)];
    };
    const options = anyOptions(s);
    const format: lzma.Compressor.Format = switch (shakedown.gen.intRange(s, u2, 0, 2)) {
        0 => .lzma2,
        1 => .{ .lzma1 = .{ .end_marker = shakedown.gen.boolean(s) } },
        else => .{ .alone = .{ .size_known = shakedown.gen.boolean(s) } },
    };
    case.note("{d} bytes, {any}, {any}", .{ in.len, options, format });
    var c: lzma.Compressor = try .init(gpa, options, if (shakedown.gen.boolean(s)) .fromRaw(in.len) else null);
    defer c.deinit();
    const out = try gpa.alloc(u8, lzma.Compressor.bound(format, in.len));
    const n = try c.compress(in, out, format);
    const back = try gpa.alloc(u8, in.len + 1);
    var d: lzma.Decompressor = .init;
    const r = switch (format) {
        .lzma2 => try d.decompressLzma2(out[0..n], back, .{ .dictionary = options.dictionary }),
        .lzma1 => |o| try d.decompressLzma1(out[0..n], back, .{ .properties = options.properties, .dictionary = options.dictionary, .size = if (o.end_marker) null else in.len }),
        .alone => try d.decompressAlone(out[0..n], back, .{}),
    };
    try testing.expectEqual(n, r.in_len);
    try testing.expectEqualSlices(u8, in, back[0..r.out_len]);
    // The same bytes from the resumable encoder, with tables for any input.
    var whole: lzma.Compressor = try .init(gpa, options, null);
    defer whole.deinit();
    const m = try whole.compress(in, out, format);
    const got = try streamed(gpa, .{ .lzma = options, .format = format, .pledged_size = .fromRaw(in.len) }, in, shakedown.gen.intRange(s, usize, 1, 5000), shakedown.gen.intRange(s, usize, 1, 3000));
    try testing.expectEqualSlices(u8, out[0..m], got);
}

test "fuzz: any input at any options encodes to a stream that decodes to it, the same whole or resumable" {
    try shakedown.check(testing.allocator, {}, anyEncoding, .{ .cases = 150 });
}

test "std's .xz decoder reads warp's streams: one block or many, each check" {
    try eachInput(testing.allocator, struct {
        fn run(_: @This(), gpa: std.mem.Allocator, in: []const u8) !void {
            if (in.len > 300_000) return;
            const checks = [_]xz.Check{ .none, .crc32, .crc64, .sha256 };
            for (checks, 0..) |check, i| {
                const options: xz.Compressor.Options = .{ .lzma = presets[i * 2], .check = check, .block_size = if (i % 2 == 0) null else 40_000 };
                var c: xz.Compressor = try .init(gpa, options);
                defer c.deinit();
                const out = try gpa.alloc(u8, xz.Compressor.bound(options, in.len));
                defer gpa.free(out);
                const n = try c.compress(in, out);
                var source: std.Io.Reader = .fixed(out[0..n]);
                var d = try std.compress.xz.Decompress.init(&source, gpa, try gpa.alloc(u8, 1 << 16));
                defer d.deinit();
                const got = try d.reader.allocRemaining(gpa, .unlimited);
                defer gpa.free(got);
                try testing.expectEqualSlices(u8, in, got);
            }
        }
    }{});
}

/// A preset named in a record's parameters: "-6", "-6e", "-0".
fn presetIn(params: []const u8) !Options {
    const at = (std.mem.findScalar(u8, params, '-') orelse return error.BadCorpus) + 1;
    var end = at;
    while (end < params.len and std.ascii.isDigit(params[end])) end += 1;
    const level = try std.fmt.parseInt(u4, params[at..end], 10);
    return .preset(level, end < params.len and params[end] == 'e');
}

/// The filters a record's parameters name before "lzma2".
fn filtersIn(params: []const u8, buf: *[3]xz.Filter) ![]const xz.Filter {
    const at = (std.mem.find(u8, params, "filters ") orelse return &.{}) + "filters ".len;
    var n: usize = 0;
    var it = std.mem.splitSequence(u8, params[at..], ", ");
    while (it.next()) |f| {
        if (std.mem.eql(u8, f, "lzma2")) break;
        var words = std.mem.splitScalar(u8, f, ' ');
        const name = words.next().?;
        const arg = words.next();
        const value: u32 = if (arg) |a| try std.fmt.parseInt(u32, a[std.mem.findScalar(u8, a, '=').? + 1 ..], 10) else 0;
        buf[n] = if (std.mem.eql(u8, name, "delta")) .{ .delta = @intCast(value) } else .{ .bcj = .{ .kind = std.meta.stringToEnum(xz.Bcj, name) orelse return error.BadCorpus, .start = value } };
        n += 1;
    }
    return buf[0..n];
}

test "warp's encoder writes liblzma's streams byte for byte: .lzma, raw LZMA and LZMA2, and .xz" {
    const gpa = testing.allocator;
    const c = try corpus.Corpus.parse(streams_corpus);
    var it = c.records();
    var count: usize = 0;
    while (it.next()) |r| {
        const format = r.fields[1];
        const params = r.fields[2];
        const want = r.fields[4];
        errdefer std.debug.print("{s} ({s}): {s}\n", .{ format, params, r.fields[3] });
        const in = if (r.fields[3].len == 0) try gpa.alloc(u8, 0) else try corpus.input(gpa, r.fields[3]);
        defer gpa.free(in);
        var got: []u8 = undefined;
        if (std.mem.eql(u8, format, "xz")) {
            if (std.mem.startsWith(u8, params, "two streams")) continue;
            var filters: [3]xz.Filter = undefined;
            const check: xz.Check = if (std.mem.find(u8, params, "check ")) |at| std.meta.stringToEnum(xz.Check, params[at + 6 ..]).? else .crc64;
            const block: ?u64 = if (std.mem.find(u8, params, "block ")) |at| try std.fmt.parseInt(u64, params[at + 6 ..], 10) else null;
            got = try streamedXz(gpa, .{ .lzma = try presetIn(params), .check = check, .filters = try filtersIn(params, &filters), .block_size = block }, in, 1 << 30, 1 << 20, false);
        } else if (std.mem.eql(u8, format, "lzma")) {
            got = try streamed(gpa, .{ .lzma = try presetIn(params), .format = .{ .alone = .{ .size_known = false } } }, in, 1 << 30, 1 << 20);
        } else if (std.mem.startsWith(u8, format, "lzma2 ")) {
            got = try streamed(gpa, .{ .lzma = try presetIn(params) }, in, 1 << 30, 1 << 20);
        } else if (std.mem.startsWith(u8, format, "lzma1 ")) {
            var o: Options = .preset(6, false);
            o.dictionary = 1 << 20;
            o.properties = .{ .lc = @intCast(try number(format, "lc")), .lp = @intCast(try number(format, "lp")), .pb = @intCast(try number(format, "pb")) };
            got = try streamed(gpa, .{ .lzma = o, .format = .{ .lzma1 = .{ .end_marker = !std.mem.eql(u8, params, "known") } } }, in, 1 << 30, 1 << 20);
        } else continue;
        defer gpa.free(got);
        try testing.expectEqualSlices(u8, want, got);
        count += 1;
    }
    try testing.expectEqual(129, count);
}

fn number(format: []const u8, comptime key: []const u8) !u64 {
    const at = (std.mem.find(u8, format, " " ++ key ++ "=") orelse return error.BadCorpus) + key.len + 2;
    const end = std.mem.findScalarPos(u8, format, at, ' ') orelse format.len;
    return std.fmt.parseInt(u64, format[at..end], 10);
}

fn canceledStreams(io: std.Io, p: *xz.parallel.Decompressor, in: []const u8, out: []u8) !void {
    try testing.expectError(error.Canceled, p.decompress(io, in, out, .{}));
}

test "xz parallel decode: streams of no blocks are canceled between streams" {
    const gpa = testing.allocator;
    var c: xz.Compressor = try .init(gpa, .{});
    defer c.deinit();
    var empty: [64]u8 = undefined;
    const n = try c.compress("", &empty);
    // No block starts a job: only the stream loop's own point sees the cancel.
    const in = try gpa.alloc(u8, 64 * n);
    defer gpa.free(in);
    for (0..64) |i| @memcpy(in[i * n ..][0..n], empty[0..n]);
    var out: [16]u8 = undefined;
    var p: xz.parallel.Decompressor = try .init(gpa, .{ .concurrency = 2 });
    defer p.deinit();
    const sim = try shakedown.Sim.init(gpa, .{ .faults = &.{.{ .at = .{ .nth = .{ .call = .checkCancel, .n = 1 } }, .fault = .cancel }} });
    defer sim.deinit();
    switch (sim.run(canceledStreams, .{ sim.io(), &p, in, &out })) {
        .finished => {},
        .failed => |err| return err,
        else => return error.UnfinishedCancellation,
    }
    try testing.expectEqual(@as(u64, 1), sim.faults().?.count(.checkCancel));
}
