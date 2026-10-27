//! bzip2 decoding against libbz2 1.0.8: its streams and 7-Zip 26.05's
//! decoded whole, by the stream, at every cut and in parallel, its verdicts
//! on constructed and mutated streams given for the same reasons, and the
//! resumable and parallel decoders fuzzed against the whole-buffer one.

const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const corpus = @import("corpus.zig");
const bzip2 = @import("../bzip2.zig");
const Decompress = @import("../bzip2/Decompress.zig");

const streams_corpus = @embedFile("bzip2-streams.corpus");
const invalid_corpus = @embedFile("bzip2-invalid.corpus");

const Error = bzip2.Decompressor.Error;

fn input(gpa: std.mem.Allocator, spec: []const u8) ![]u8 {
    return if (spec.len == 0) gpa.alloc(u8, 0) else corpus.input(gpa, spec);
}

/// What the resumable decoder makes of `in` given in pieces of `cut` bytes
/// (0: whole) into pieces of output of `out_cut` bytes.
fn streamed(gpa: std.mem.Allocator, in: []const u8, out: []u8, cut: usize, out_cut: usize, streams: bzip2.Streams) (Error || error{OutOfMemory})!struct { in_len: usize, out_len: usize } {
    const buffer = try gpa.alignedAlloc(u8, .@"4", Decompress.memory);
    defer gpa.free(buffer);
    var s: Decompress = .init(buffer, .{ .streams = streams });
    var ip: usize = 0;
    var op: usize = 0;
    // Bytes given back, given again with more.
    var back: usize = 0;
    while (true) {
        const piece = in[ip..@min(in.len, ip + back + if (cut == 0) in.len else cut)];
        const room = out[op..@min(out.len, op + if (out_cut == 0) out.len else out_cut)];
        const step = try s.decode(piece, room);
        ip += step.in_len;
        op += step.out_len;
        back = 0;
        switch (step.status) {
            .done => return .{ .in_len = ip, .out_len = op },
            .output_full => if (op == out.len) return error.OutputTooSmall,
            .need_input => {
                back = piece.len - step.in_len;
                if (ip + back == in.len) {
                    try s.finish();
                    return .{ .in_len = ip, .out_len = op };
                }
            },
        }
    }
}

test "libbz2's streams decode to their inputs, whole, by the stream and at every cut" {
    const gpa = testing.allocator;
    var d: bzip2.Decompressor = try .init(gpa);
    defer d.deinit();
    const c = try corpus.Corpus.parse(streams_corpus);
    var it = c.records();
    var count: usize = 0;
    var randomised: usize = 0;
    while (it.next()) |r| : (count += 1) {
        errdefer std.debug.print("{s} level {s}: {s}\n", .{ r.fields[0], r.fields[1], r.fields[2] });
        const in = try input(gpa, r.fields[2]);
        defer gpa.free(in);
        const stream = r.fields[3];
        const in_len = try std.fmt.parseInt(usize, r.fields[4], 10);
        if (std.mem.startsWith(u8, r.fields[0], "constructed: randomised")) randomised += 1;
        const out = try gpa.alloc(u8, in.len + 1);
        defer gpa.free(out);
        const whole = try d.decompress(stream, out, .{});
        try testing.expectEqual(in_len, whole.in_len);
        try testing.expectEqualSlices(u8, in, out[0..whole.out_len]);
        if (in.len != 0) try testing.expectError(error.OutputTooSmall, d.decompress(stream, out[0 .. in.len - 1], .{}));
        // Pieces of input and output, small and large.
        for ([_][2]usize{ .{ 1, 0 }, .{ 7, 3 }, .{ 4096, 1000 }, .{ 0, 65536 } }) |cuts| {
            if (cuts[0] == 1 and stream.len > 20_000) continue;
            const s = try streamed(gpa, stream, out[0..in.len], cuts[0], cuts[1], .all);
            try testing.expectEqual(in_len, s.in_len);
            try testing.expectEqualSlices(u8, in, out[0..s.out_len]);
        }
        // Every prefix of a small stream is cut short.
        if (stream.len <= 400 and in_len == stream.len) for (0..stream.len) |n| {
            try testing.expectError(error.Truncated, d.decompress(stream[0..n], out, .{}));
        };
    }
    try testing.expectEqual(62, count);
    try testing.expectEqual(3, randomised);
}

test "a decoder told to read one stream stops after it" {
    const gpa = testing.allocator;
    var d: bzip2.Decompressor = try .init(gpa);
    defer d.deinit();
    const c = try corpus.Corpus.parse(streams_corpus);
    var it = c.records();
    while (it.next()) |r| {
        if (!std.mem.eql(u8, r.fields[0], "libbz2 1.0.8, two streams")) continue;
        const stream = r.fields[3];
        const out = try gpa.alloc(u8, 1 << 20);
        defer gpa.free(out);
        const one = try d.decompress(stream, out, .{ .streams = .one });
        try testing.expect(one.in_len < stream.len);
        const rest = try d.decompress(stream[one.in_len..], out[one.out_len..], .{ .streams = .one });
        try testing.expectEqual(stream.len, one.in_len + rest.in_len);
        const s = try streamed(gpa, stream, out, 100, 0, .one);
        try testing.expectEqual(one.in_len, s.in_len);
    }
}

/// libbz2's verdict, as warp answers it.
fn agrees(verdict: []const u8, result: Error!bzip2.Decompressor.Result, out: []const u8, diag: bzip2.Diagnostic) !void {
    if (std.mem.startsWith(u8, verdict, "ok ")) {
        const r = try result;
        var h: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(out[0..r.out_len], &h, .{});
        var want: [32]u8 = undefined;
        _ = try std.fmt.hexToBytes(&want, verdict[3..]);
        try testing.expectEqualSlices(u8, &want, &h);
    } else if (std.mem.eql(u8, verdict, "BZ_DATA_ERROR")) {
        if (result) |_| return error.TestUnexpectedResult else |err| try testing.expect(err == error.InvalidStream or err == error.ChecksumMismatch);
        try testing.expect(diag.reason != .bad_magic and diag.reason != .bad_level and diag.reason != .truncated);
    } else if (std.mem.eql(u8, verdict, "BZ_DATA_ERROR_MAGIC")) {
        try testing.expectError(error.InvalidStream, result);
        try testing.expect(diag.reason == .bad_magic or diag.reason == .bad_level);
    } else if (std.mem.eql(u8, verdict, "BZ_UNEXPECTED_EOF")) {
        try testing.expectError(error.Truncated, result);
    } else {
        // 1.0.8's answer depends on memory it never wrote: warp refuses.
        try testing.expectError(error.InvalidStream, result);
    }
}

test "libbz2's verdicts on constructed and mutated streams are warp's, for the same reasons, whole and streamed" {
    const gpa = testing.allocator;
    var d: bzip2.Decompressor = try .init(gpa);
    defer d.deinit();
    const out = try gpa.alloc(u8, 32 << 20);
    defer gpa.free(out);
    const c = try corpus.Corpus.parse(invalid_corpus);
    var it = c.records();
    const reasons = [_]struct { []const u8, bzip2.Diagnostic.Reason }{
        .{ "constructed: stream magic", .bad_magic },
        .{ "constructed: level 0", .bad_level },
        .{ "constructed: level past 9", .bad_level },
        .{ "constructed: block magic", .bad_block_magic },
        .{ "constructed: origPtr past the block", .orig_ptr },
        .{ "constructed: block CRC", .block_crc },
        .{ "constructed: stream CRC", .stream_crc },
        .{ "constructed: no symbols", .no_symbols },
    };
    var count: usize = 0;
    var constructed: usize = 0;
    while (it.next()) |r| : (count += 1) {
        errdefer std.debug.print("{s}: {s}\n", .{ r.fields[0], r.fields[2] });
        var diag: bzip2.Diagnostic = .{};
        const result = d.decompress(r.fields[1], out, .{ .diagnostic = &diag });
        try agrees(r.fields[2], result, out, diag);
        for (reasons) |want| if (std.mem.eql(u8, r.fields[0], want[0])) {
            try testing.expectEqual(want[1], diag.reason);
            constructed += 1;
        };
        // In pieces: the same answer.
        const s = streamed(gpa, r.fields[1], out, 13, 0, .all);
        if (result) |whole| {
            const got = try s;
            try testing.expectEqual(whole.out_len, got.out_len);
        } else |err| try testing.expectError(err, s);
    }
    try testing.expectEqual(reasons.len, constructed);
    try testing.expect(count > 2000);
}

const Decoders = struct { whole: bzip2.Decompressor, parallel: bzip2.parallel.Decompressor };

/// Arbitrary bytes, or a corpus stream mutated: the resumable decoder at
/// any cuts and the parallel one answer as the whole-buffer one.
fn anyStream(decoders: *Decoders, case: *shakedown.Case) !void {
    const d = &decoders.whole;
    const s = case.source;
    const in = if (shakedown.gen.boolean(s)) try shakedown.gen.string(s, case.gpa, .{ .kind = .bytes, .max_len = 600, .average = 80 }) else blk: {
        const c = try corpus.Corpus.parse(streams_corpus);
        var it = c.records();
        var r = it.next().?;
        for (0..shakedown.gen.intRange(s, usize, 0, 20)) |_| r = it.next() orelse break;
        const bytes = try case.gpa.dupe(u8, r.fields[3][0..@min(r.fields[3].len, 3000)]);
        for (0..shakedown.gen.intRange(s, usize, 0, 4)) |_| bytes[shakedown.gen.intRange(s, usize, 0, bytes.len - 1)] ^= @as(u8, 1) << shakedown.gen.int(s, u3);
        break :blk bytes;
    };
    case.note("{d} bytes", .{in.len});
    const out = try case.gpa.alloc(u8, 1 << 20);
    const back = try case.gpa.alloc(u8, out.len);
    const whole = d.decompress(in, out, .{});
    const cut = shakedown.gen.intRange(s, usize, 1, 200);
    const s2 = streamed(case.gpa, in, back, cut, shakedown.gen.intRange(s, usize, 0, 5000), .all);
    if (whole) |w| {
        const got = try s2;
        try testing.expectEqual(w.in_len, got.in_len);
        try testing.expectEqualSlices(u8, out[0..w.out_len], back[0..got.out_len]);
    } else |err| try testing.expectError(err, s2);
    try agreesInParallel(d, &decoders.parallel, in, out, back);
}

test "fuzz: any bytes into the resumable decoder at any cuts and the parallel one answer as the whole-buffer decoder" {
    var decoders: Decoders = .{ .whole = try .init(testing.allocator), .parallel = undefined };
    defer decoders.whole.deinit();
    decoders.parallel = try .init(testing.allocator, .{ .concurrency = 2, .block_out = .fromRaw(4096) });
    defer decoders.parallel.deinit();
    try shakedown.check(testing.allocator, &decoders, anyStream, .{ .cases = 600 });
}

test "the reader adapter reads what the decoder writes" {
    const gpa = testing.allocator;
    const c = try corpus.Corpus.parse(streams_corpus);
    var it = c.records();
    for (0..8) |_| _ = it.next();
    const r = it.next().?;
    const in = try input(gpa, r.fields[2]);
    defer gpa.free(in);
    var source: std.Io.Reader = .fixed(r.fields[3]);
    const buffer = try gpa.alignedAlloc(u8, .@"4", 4096 + Decompress.memory);
    defer gpa.free(buffer);
    var reader: Decompress.Reader = .init(&source, buffer, .{});
    const got = try reader.interface.allocRemaining(gpa, .unlimited);
    defer gpa.free(got);
    try testing.expectEqualSlices(u8, in, got);
}

/// A source that gives `size` bytes at a time.
const Pieces = struct {
    interface: std.Io.Reader,
    data: []const u8,
    size: usize,
    /// Bytes given to the buffer.
    pos: usize = 0,

    fn init(data: []const u8, size: usize, buffer: []u8) Pieces {
        return .{ .interface = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 }, .data = data, .size = size };
    }

    fn stream(interface: *std.Io.Reader, w: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const p: *Pieces = @alignCast(@fieldParentPtr("interface", interface));
        if (p.pos == p.data.len) return error.EndOfStream;
        const n = limit.minInt(@min(p.size, p.data.len - p.pos));
        try w.writeAll(p.data[p.pos..][0..n]);
        p.pos += n;
        return n;
    }

    /// Bytes the reader's user has taken.
    fn taken(p: *const Pieces) usize {
        return p.pos - (p.interface.end - p.interface.seek);
    }
};

test "the reader adapter leaves what follows the streams in its source, at every buffer size" {
    const gpa = testing.allocator;
    const c = try corpus.Corpus.parse(streams_corpus);
    var it = c.records();
    var count: usize = 0;
    while (it.next()) |r| {
        if (!std.mem.startsWith(u8, r.fields[0], "libbz2 1.0.8, then ")) continue;
        count += 1;
        const stream = r.fields[3];
        const in_len = try std.fmt.parseInt(usize, r.fields[4], 10);
        for ([_]usize{ 1, 2, 3, 5, 64 }) |size| {
            var source_buffer: [64]u8 = undefined;
            var source: Pieces = .init(stream, size, &source_buffer);
            const buffer = try gpa.alignedAlloc(u8, .@"4", 4096 + Decompress.memory);
            defer gpa.free(buffer);
            var reader: Decompress.Reader = .init(&source.interface, buffer, .{});
            const got = try reader.interface.allocRemaining(gpa, .unlimited);
            defer gpa.free(got);
            try testing.expectEqual(in_len, source.taken());
        }
    }
    try testing.expectEqual(3, count);
}

/// The parallel decoder's answer is the whole-buffer one's, with the same
/// diagnostic.
fn agreesInParallel(d: *bzip2.Decompressor, p: *bzip2.parallel.Decompressor, in: []const u8, out: []u8, back: []u8) !void {
    var want_diag: bzip2.Diagnostic = .{};
    var got_diag: bzip2.Diagnostic = .{};
    const want = d.decompress(in, out, .{ .diagnostic = &want_diag });
    const got = p.decompress(testing.io, in, back, .{ .diagnostic = &got_diag });
    if (want) |w| {
        const g = try got;
        try testing.expectEqual(w, g);
        try testing.expectEqualSlices(u8, out[0..w.out_len], back[0..g.out_len]);
    } else |err| {
        try testing.expectError(err, got);
        if (err != error.OutputTooSmall) try testing.expectEqual(want_diag, got_diag);
    }
}

test "the parallel decoder answers as the whole-buffer one, blocks whole or longer than a worker's output" {
    const gpa = testing.allocator;
    var d: bzip2.Decompressor = try .init(gpa);
    defer d.deinit();
    const out = try gpa.alloc(u8, 2 << 20);
    defer gpa.free(out);
    const back = try gpa.alloc(u8, out.len);
    defer gpa.free(back);
    for ([_]bzip2.parallel.Decompressor.Options{
        .{ .concurrency = 1 },
        .{ .concurrency = 3, .block_out = .fromRaw(1000) },
    }) |options| {
        var p: bzip2.parallel.Decompressor = try .init(gpa, options);
        defer p.deinit();
        const c = try corpus.Corpus.parse(streams_corpus);
        var it = c.records();
        while (it.next()) |r| {
            errdefer std.debug.print("{s} level {s}: {s}\n", .{ r.fields[0], r.fields[1], r.fields[2] });
            const stream = r.fields[3];
            try agreesInParallel(&d, &p, stream, out, back);
            // Short of output, and the streams read at the level of a
            // smaller block.
            try agreesInParallel(&d, &p, stream, out[0..100], back[0..100]);
            if (stream.len > 4 and stream[3] > '1') {
                const smaller = try gpa.dupe(u8, stream);
                defer gpa.free(smaller);
                smaller[3] = '1';
                try agreesInParallel(&d, &p, smaller, out, back);
            }
        }
        const v = try corpus.Corpus.parse(invalid_corpus);
        var vit = v.records();
        while (vit.next()) |r| {
            errdefer std.debug.print("{s}: {s}\n", .{ r.fields[0], r.fields[2] });
            try agreesInParallel(&d, &p, r.fields[1], out, back);
        }
    }
}

test "the parallel decoder joins a stream's blocks from its workers" {
    const gpa = testing.allocator;
    var stats: bzip2.parallel.Decompressor.Statistics = .{};
    var p: bzip2.parallel.Decompressor = try .init(gpa, .{ .concurrency = 3, .statistics = &stats });
    defer p.deinit();
    const c = try corpus.Corpus.parse(streams_corpus);
    var it = c.records();
    while (it.next()) |r| {
        if (!std.mem.eql(u8, r.fields[1], "1") or !std.mem.eql(u8, r.fields[2], "text 11 950000")) continue;
        const in = try input(gpa, r.fields[2]);
        defer gpa.free(in);
        const out = try gpa.alloc(u8, in.len);
        defer gpa.free(out);
        const got = try p.decompress(testing.io, r.fields[3], out, .{});
        try testing.expectEqualSlices(u8, in, out[0..got.out_len]);
        // Ten blocks of 100 kB, every one a worker's.
        try testing.expectEqual(bzip2.parallel.Decompressor.Statistics{ .joined = 10 }, stats);
        return;
    }
    return error.TestUnexpectedResult;
}
