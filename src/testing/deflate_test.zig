//! The streaming compressor: every level, strategy, container and window
//! round-trips through the streaming and whole-buffer decoders and std's;
//! the bytes out are the same however the input and output are cut; each
//! flush makes what came before decodable, `full` a restart point; level
//! changes, resets and the writer.

const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const gen = @import("gen");
const Deflate = @import("../stream/Deflate.zig");
const Inflate = @import("../stream/Inflate.zig");
const Decompressor = @import("../Decompressor.zig");
const container = @import("../container.zig");

const strategies = std.enums.values(Deflate.Strategy);

fn acceptOf(kind: container.Container) container.Accept {
    return switch (kind) {
        .raw => .raw,
        .zlib => .zlib,
        .gzip => .gzip,
    };
}

/// How a stream is fed: input and output pieces of up to these sizes (0
/// for whole), and flushes every so many bytes.
const Feed = struct {
    in_max: usize = 0,
    out_max: usize = 0,
    seed: u64 = 1,
    flush_every: usize = 0,
    flush: Deflate.Flush = .sync,
};

/// `in` compressed by a streaming compressor fed as `feed` says.
fn compressFed(gpa: std.mem.Allocator, in: []const u8, options: Deflate.Options, feed: Feed) ![]u8 {
    var d = try Deflate.init(gpa, options);
    defer d.deinit();
    return compressWith(gpa, &d, in, feed);
}

fn compressWith(gpa: std.mem.Allocator, d: *Deflate, in: []const u8, feed: Feed) ![]u8 {
    var prng: std.Random.DefaultPrng = .init(feed.seed);
    const random = prng.random();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var piece: [8192]u8 = undefined;
    var at: usize = 0;
    var next_flush = if (feed.flush_every == 0) std.math.maxInt(usize) else feed.flush_every;
    while (at < in.len) {
        const end = @min(in.len, next_flush);
        const want = if (feed.in_max == 0) end - at else @min(end - at, 1 + random.uintLessThan(usize, feed.in_max));
        const room = if (feed.out_max == 0) piece.len else 1 + random.uintLessThan(usize, feed.out_max);
        const step = d.write(in[at..][0..want], piece[0..room]);
        try out.appendSlice(gpa, piece[0..step.out_len]);
        at += step.in_len;
        if (at == next_flush) {
            while (true) {
                const r = if (feed.out_max == 0) piece.len else 1 + random.uintLessThan(usize, feed.out_max);
                const drained = d.flush(feed.flush, piece[0..r]);
                try out.appendSlice(gpa, piece[0..drained.out_len]);
                if (drained.done) break;
            }
            next_flush += feed.flush_every;
        }
    }
    while (true) {
        const r = if (feed.out_max == 0) piece.len else 1 + random.uintLessThan(usize, feed.out_max);
        const drained = d.finish(piece[0..r]);
        try out.appendSlice(gpa, piece[0..drained.out_len]);
        if (drained.done) break;
    }
    return out.toOwnedSlice(gpa);
}

/// `stream` decoded whole and through the streaming decoder, each equal
/// to `in`.
fn expectDecodes(gpa: std.mem.Allocator, stream: []const u8, in: []const u8, kind: container.Container, window_bits: u4, dictionary: []const u8) !void {
    const d = try gpa.create(Decompressor);
    defer gpa.destroy(d);
    d.* = .init;
    const back = try gpa.alloc(u8, in.len);
    defer gpa.free(back);
    const r = try d.inflate(stream, back, .{ .accept = acceptOf(kind), .dictionary = dictionary });
    try testing.expectEqual(stream.len, r.in_len);
    try testing.expectEqual(in.len, r.out_len);
    try testing.expectEqualSlices(u8, in, back);
    // The streaming decoder with the same window: no distance reaches past it.
    try testing.expectEqualSlices(u8, in, try decodeStreaming(gpa, stream, back, kind, window_bits, dictionary));
}

/// `stream` decoded by the streaming decoder into `out`, to its end.
fn decodeStreaming(gpa: std.mem.Allocator, stream: []const u8, out: []u8, kind: container.Container, window_bits: u4, dictionary: []const u8) ![]u8 {
    const window = try gpa.alloc(u8, @as(usize, 1) << window_bits);
    defer gpa.free(window);
    var z: Inflate = .init(window, .{ .accept = acceptOf(kind), .window_bits = window_bits, .dictionary = dictionary });
    var at: usize = 0;
    var written: usize = 0;
    while (true) {
        const step = try z.decode(stream[at..], out[written..]);
        at += step.in_len;
        written += step.out_len;
        switch (step.status) {
            .done => break,
            .member_end => if (at == stream.len) break,
            .block_end => {},
            .need_input, .output_full => return error.TestUnexpectedResult,
        }
    }
    try testing.expectEqual(stream.len, at);
    return out[0..written];
}

test "every level, strategy and container round-trips, fed in pieces, through both decoders" {
    const gpa = testing.allocator;
    var inputs: std.ArrayList([]u8) = .empty;
    defer {
        for (inputs.items) |in| gpa.free(in);
        inputs.deinit(gpa);
    }
    for (std.enums.values(gen.Kind)) |kind| for ([_]usize{ 0, 1, 37, 4096, 100_000 }) |n| {
        try inputs.append(gpa, try gen.alloc(gpa, kind, 31, n));
    };
    for (0..13) |level| for (strategies) |strategy| {
        for (inputs.items, 0..) |in, i| {
            const kind = std.enums.values(container.Container)[i % 3];
            const options: Deflate.Options = .{ .level = @intCast(level), .strategy = strategy, .container = kind };
            const feed: Feed = .{ .in_max = if (i % 2 == 0) 3000 else 0, .out_max = if (i % 4 < 2) 700 else 0, .seed = i };
            const stream = try compressFed(gpa, in, options, feed);
            defer gpa.free(stream);
            expectDecodes(gpa, stream, in, kind, 15, &.{}) catch |err| {
                std.debug.print("level {d} {t} {t} input {d} ({d} bytes)\n", .{ level, strategy, kind, i, in.len });
                return err;
            };
        }
    };
}

test "the bytes out are the same however the input and the output are cut" {
    const gpa = testing.allocator;
    const in = try gen.alloc(gpa, .text, 3, 300_000);
    defer gpa.free(in);
    for ([_]u4{ 0, 1, 2, 4, 6, 9 }) |level| for ([_]u4{ 9, 15 }) |window_bits| {
        const options: Deflate.Options = .{ .level = level, .window_bits = window_bits, .container = .gzip };
        const whole = try compressFed(gpa, in, options, .{});
        defer gpa.free(whole);
        const feeds = [_]Feed{
            .{ .in_max = 1, .out_max = 0 },
            .{ .in_max = 7, .out_max = 1 },
            .{ .in_max = 70_000, .out_max = 3 },
            .{ .in_max = 300, .out_max = 5000, .seed = 9 },
        };
        for (feeds) |feed| {
            // A byte at a time costs a call per byte: a slice of the input.
            const part = if (feed.in_max == 1) in[0..20_000] else in;
            const expected = if (feed.in_max == 1) try compressFed(gpa, part, options, .{}) else try gpa.dupe(u8, whole);
            defer gpa.free(expected);
            const cut = try compressFed(gpa, part, options, feed);
            defer gpa.free(cut);
            testing.expectEqualSlices(u8, expected, cut) catch |err| {
                std.debug.print("level {d} window {d} feed {any}\n", .{ level, window_bits, feed });
                return err;
            };
        }
        try expectDecodes(gpa, whole, in, .gzip, window_bits, &.{});
    };
}

test "a window of 2^w bytes: every distance written is within it, for every window" {
    const gpa = testing.allocator;
    const in = try gen.alloc(gpa, .json, 5, 200_000);
    defer gpa.free(in);
    for (8..16) |bits| for ([_]u4{ 1, 5, 9 }) |level| {
        const options: Deflate.Options = .{ .level = level, .window_bits = @intCast(bits), .container = .zlib };
        const stream = try compressFed(gpa, in, options, .{ .in_max = 5000, .seed = bits });
        defer gpa.free(stream);
        // The header names the window: 8 as CINFO 0.
        try testing.expectEqual(@as(u8, @intCast(bits - 8)), stream[0] >> 4);
        try expectDecodes(gpa, stream, in, .zlib, @intCast(bits), &.{});
    };
}

test "a sync flush makes everything before it decodable, a full flush a restart point" {
    const gpa = testing.allocator;
    const in = try gen.alloc(gpa, .text, 8, 50_000);
    defer gpa.free(in);
    var piece: [1 << 17]u8 = undefined;
    for ([_]Deflate.Flush{ .sync, .full, .partial }) |mode| for ([_]u4{ 1, 6 }) |level| {
        var d = try Deflate.init(gpa, .{ .level = level, .container = .raw });
        defer d.deinit();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        const half = 30_000;
        const w = d.write(in[0..half], &piece);
        try testing.expectEqual(@as(usize, half), w.in_len);
        try out.appendSlice(gpa, piece[0..w.out_len]);
        const f = d.flush(mode, &piece);
        try testing.expect(f.done);
        try out.appendSlice(gpa, piece[0..f.out_len]);
        const flush_end = out.items.len;
        if (mode != .partial) try testing.expectEqualSlices(u8, &.{ 0, 0, 0xff, 0xff }, out.items[flush_end - 4 ..]);
        // Everything before the flush decodes from what came out so far.
        var window: [1 << 15]u8 = undefined;
        var z: Inflate = .init(&window, .{ .accept = .raw });
        const back = try gpa.alloc(u8, in.len);
        defer gpa.free(back);
        var at: usize = 0;
        var written: usize = 0;
        while (at < out.items.len) {
            const step = try z.decode(out.items[at..], back[written..]);
            at += step.in_len;
            written += step.out_len;
            if (step.status == .need_input) break;
        }
        try testing.expectEqual(@as(usize, half), written);
        try testing.expectEqualSlices(u8, in[0..half], back[0..half]);
        const rest = d.write(in[half..], &piece);
        try out.appendSlice(gpa, piece[0..rest.out_len]);
        const done = d.finish(&piece);
        try testing.expect(done.done);
        try out.appendSlice(gpa, piece[0..done.out_len]);
        try expectDecodes(gpa, out.items, in, .raw, 15, &.{});
        if (mode == .full) {
            // After a full flush, a decoder that starts there needs nothing
            // before it.
            const after = try decodeStreaming(gpa, out.items[flush_end..], back, .raw, 15, &.{});
            try testing.expectEqualSlices(u8, in[half..], after);
        }
    };
}

test "a flush with nothing new still writes its mark, and the empty stream is each container's" {
    const gpa = testing.allocator;
    var piece: [64]u8 = undefined;
    var d = try Deflate.init(gpa, .{});
    defer d.deinit();
    var f = d.flush(.sync, &piece);
    // The zlib header, then the empty stored block.
    try testing.expectEqualSlices(u8, &.{ 0x78, 0x9c, 0, 0, 0, 0xff, 0xff }, piece[0..f.out_len]);
    f = d.flush(.sync, &piece);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 0xff, 0xff }, piece[0..f.out_len]);
    for (std.enums.values(container.Container)) |kind| {
        const stream = try compressFed(gpa, "", .{ .container = kind }, .{});
        defer gpa.free(stream);
        try expectDecodes(gpa, stream, "", kind, 15, &.{});
        if (kind == .zlib) try testing.expectEqualSlices(u8, &.{ 0x78, 0x9c, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01 }, stream);
    }
}

test "a dictionary primes the window, and a zlib stream names it" {
    const gpa = testing.allocator;
    const dictionary = try gen.alloc(gpa, .json, 5, 40_000);
    defer gpa.free(dictionary);
    const message = try gen.alloc(gpa, .json, 6, 3000);
    defer gpa.free(message);
    for ([_]container.Container{ .raw, .zlib }) |kind| for ([_]u4{ 1, 6 }) |level| {
        const plain = try compressFed(gpa, message, .{ .level = level, .container = kind }, .{});
        defer gpa.free(plain);
        const primed = try compressFed(gpa, message, .{ .level = level, .container = kind, .dictionary = dictionary }, .{ .in_max = 10 });
        defer gpa.free(primed);
        try testing.expect(primed.len < plain.len);
        try expectDecodes(gpa, primed, message, kind, 15, dictionary);
    };
}

test "context takeover: a reset that keeps the history, on both sides" {
    const gpa = testing.allocator;
    var d = try Deflate.init(gpa, .{ .level = 12, .container = .raw, .window_bits = 12 });
    defer d.deinit();
    var window: [1 << 12]u8 = undefined;
    var z: Inflate = .init(&window, .{ .accept = .raw, .window_bits = 12 });
    var sizes: [2]usize = undefined;
    for (0..2) |round| {
        // The same kind of message twice: the second refers to the first.
        const message = try gen.alloc(gpa, .json, 40 + round, 1500);
        defer gpa.free(message);
        if (round > 0) {
            d.reset(.history);
            z.reset(.history);
        }
        const stream = try compressWith(gpa, &d, message, .{});
        defer gpa.free(stream);
        sizes[round] = stream.len;
        var back: [2000]u8 = undefined;
        var at: usize = 0;
        var written: usize = 0;
        while (true) {
            const step = try z.decode(stream[at..], back[written..]);
            at += step.in_len;
            written += step.out_len;
            if (step.status == .done) break;
        }
        try testing.expectEqualSlices(u8, message, back[0..written]);
    }
    try testing.expect(sizes[1] < sizes[0]);
}

test "a level change ends a block where it is asked, and the bytes come out the same however fed" {
    const gpa = testing.allocator;
    const in = try gen.alloc(gpa, .text, 12, 120_000);
    defer gpa.free(in);
    const changes = [_]struct { u4, Deflate.Strategy }{ .{ 12, .default }, .{ 10, .default }, .{ 9, .default }, .{ 0, .default }, .{ 1, .default }, .{ 6, .huffman_only }, .{ 4, .rle }, .{ 2, .filtered } };
    var expected: ?[]u8 = null;
    defer if (expected) |e| gpa.free(e);
    for ([_]usize{ 0, 1, 17, 5000 }) |in_max| {
        var d = try Deflate.init(gpa, .{ .level = 6, .max_level = 12, .passes = 1, .container = .gzip });
        defer d.deinit();
        var out: std.ArrayList(u8) = .empty;
        defer out.deinit(gpa);
        var piece: [512]u8 = undefined;
        var at: usize = 0;
        for (changes, 0..) |change, k| {
            const until = (k + 1) * in.len / (changes.len + 1);
            while (at < until) {
                const want = if (in_max == 0) until - at else @min(until - at, in_max);
                const step = d.write(in[at..][0..want], &piece);
                try out.appendSlice(gpa, piece[0..step.out_len]);
                at += step.in_len;
            }
            while (true) {
                const drained = d.setLevel(change[0], change[1], &piece);
                try out.appendSlice(gpa, piece[0..drained.out_len]);
                if (drained.done) break;
            }
        }
        while (at < in.len) {
            const step = d.write(in[at..], &piece);
            try out.appendSlice(gpa, piece[0..step.out_len]);
            at += step.in_len;
        }
        while (true) {
            const drained = d.finish(&piece);
            try out.appendSlice(gpa, piece[0..drained.out_len]);
            if (drained.done) break;
        }
        try expectDecodes(gpa, out.items, in, .gzip, 15, &.{});
        if (expected) |e| try testing.expectEqualSlices(u8, e, out.items) else expected = try out.toOwnedSlice(gpa);
    }
}

test "the writer compresses into a std.Io.Writer, and its flush is a sync flush" {
    const gpa = testing.allocator;
    const in = try gen.alloc(gpa, .binary, 4, 100_000);
    defer gpa.free(in);
    var d = try Deflate.init(gpa, .{ .container = .gzip, .gzip = .{ .name = "data.bin" } });
    defer d.deinit();
    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    var staging: [4096]u8 = undefined;
    var w: Deflate.Writer = .init(&d, &sink.writer, &staging);
    try w.interface.writeAll(in[0..10]);
    try w.interface.flush();
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0xff, 0xff }, sink.written()[sink.written().len - 4 ..]);
    for (0..10) |i| try w.interface.writeAll(in[10 + i * 9999 ..][0..9999]);
    try w.interface.splatByteAll('z', 3);
    try w.finish();
    const expected = try std.mem.concat(gpa, u8, &.{ in[0 .. 10 + 10 * 9999], "zzz" });
    defer gpa.free(expected);
    try expectDecodes(gpa, sink.written(), expected, .gzip, 15, &.{});
}

test "std decodes what the streaming compressor writes, at every level" {
    const gpa = testing.allocator;
    const in = try gen.alloc(gpa, .png, 2, 80_000);
    defer gpa.free(in);
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    const back = try gpa.alloc(u8, in.len);
    defer gpa.free(back);
    for (0..13) |level| {
        const stream = try compressFed(gpa, in, .{ .level = @intCast(level), .container = .raw }, .{ .in_max = 1000, .flush_every = 30_000 });
        defer gpa.free(stream);
        var r: std.Io.Reader = .fixed(stream);
        var sd: std.compress.flate.Decompress = .init(&r, .raw, window);
        try sd.reader.readSliceAll(back);
        try testing.expectEqualSlices(u8, in, back);
    }
}

test "memory is what init takes, a stream allocates nothing, and init survives every allocation failure" {
    const gpa = testing.allocator;
    const in = try gen.alloc(gpa, .text, 2, 70_000);
    defer gpa.free(in);
    for ([_]u4{ 0, 1, 6, 12 }) |level| for ([_]u4{ 8, 12, 15 }) |bits| {
        const options: Deflate.Options = .{ .level = level, .window_bits = bits, .gzip = .{ .comment = "a comment" }, .container = .gzip };
        var counting: std.testing.FailingAllocator = .init(gpa, .{});
        var d = try Deflate.init(counting.allocator(), options);
        defer d.deinit();
        try testing.expectEqual(Deflate.memory(options), counting.allocated_bytes);
        const allocations = counting.allocations;
        const stream = try compressWith(gpa, &d, in, .{ .in_max = 9000, .flush_every = 20_000 });
        defer gpa.free(stream);
        try testing.expectEqual(allocations, counting.allocations);
        try expectDecodes(gpa, stream, in, .gzip, bits, &.{});
        try testing.checkAllAllocationFailures(gpa, struct {
            fn initOnce(a: std.mem.Allocator, o: Deflate.Options) !void {
                var s = try Deflate.init(a, o);
                s.deinit();
            }
        }.initOnce, .{options});
    };
}

/// Arbitrary input, options, flushes and cuts: the stream decodes to the
/// input, and comes out the same fed whole.
fn streamAnything(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const input = if (shakedown.gen.boolean(s))
        try shakedown.gen.string(s, case.gpa, .{ .kind = .bytes, .max_len = 5000, .average = 300 })
    else
        try gen.alloc(case.gpa, shakedown.gen.enumValue(s, gen.Kind), shakedown.gen.int(s, u16), shakedown.gen.intRange(s, usize, 0, 70_000));
    const options: Deflate.Options = .{
        .level = shakedown.gen.intRange(s, u4, 0, 15),
        .strategy = shakedown.gen.enumValue(s, Deflate.Strategy),
        .container = shakedown.gen.enumValue(s, container.Container),
        .window_bits = shakedown.gen.intRange(s, u4, 8, 15),
    };
    const feed: Feed = .{
        .in_max = shakedown.gen.intRange(s, usize, 0, 2000),
        .out_max = shakedown.gen.intRange(s, usize, 0, 2000),
        .seed = shakedown.gen.int(s, u64),
        .flush_every = shakedown.gen.intRange(s, usize, 0, 20_000),
        .flush = shakedown.gen.enumValue(s, Deflate.Flush),
    };
    case.note("{d} bytes, level {d}, {t}, {t}, window {d}, feed {any}", .{ input.len, options.level, options.strategy, options.container, options.window_bits, feed });
    const stream = try compressFed(case.gpa, input, options, feed);
    try expectDecodes(case.gpa, stream, input, options.container, options.window_bits, &.{});
    var whole = feed;
    whole.in_max = 0;
    whole.out_max = 0;
    const again = try compressFed(case.gpa, input, options, whole);
    try testing.expectEqualSlices(u8, stream, again);
}

test "fuzz: any input, options, flushes and cuts round-trip, the same however cut" {
    try shakedown.check(testing.allocator, {}, streamAnything, .{ .cases = 300 });
}

test "near-optimal streams keep block bytes across small window slides" {
    const gpa = testing.allocator;
    const in = try gen.alloc(gpa, .text, 91, 180000);
    defer gpa.free(in);
    for ([_]u4{ 8, 10, 15 }) |window_bits| {
        const options: Deflate.Options = .{ .level = 12, .container = .raw, .window_bits = window_bits };
        const whole = try compressFed(gpa, in, options, .{});
        defer gpa.free(whole);
        try expectDecodes(gpa, whole, in, .raw, window_bits, &.{});
        const pieces = try compressFed(gpa, in, options, .{ .in_max = 97, .out_max = 73 });
        defer gpa.free(pieces);
        try testing.expectEqualSlices(u8, whole, pieces);
    }
}

test "changing to a near-optimal level preserves the requested pass budget" {
    const gpa = testing.allocator;
    const in = try gen.alloc(gpa, .text, 18, 20000);
    defer gpa.free(in);
    const options: Deflate.Options = .{ .level = 12, .max_level = 12, .passes = 1, .container = .raw };
    const direct = try compressFed(gpa, in, options, .{});
    defer gpa.free(direct);
    var low = options;
    low.level = 6;
    var d = try Deflate.init(gpa, low);
    defer d.deinit();
    var piece: [128]u8 = undefined;
    const change = d.setLevel(12, .default, &piece);
    try testing.expect(change.done);
    try testing.expectEqual(@as(usize, 0), change.out_len);
    const changed = try compressWith(gpa, &d, in, .{});
    defer gpa.free(changed);
    try testing.expectEqualSlices(u8, direct, changed);
}
