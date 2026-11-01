//! Snappy and S2 streams against klauspost/compress s2 v1.20.3's writer,
//! reader and index, golang/snappy v1.0.0's and snap 1.1.2's writers
//! (testdata/snappy-stream*.corpus, captured in trials warp/snappy):
//! warp writes S2's streams and indexes byte for byte, reads every
//! stream, finds as S2 finds, and gives every mutated and constructed
//! stream S2's reader's verdict.

const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const gen = @import("gen");
const corpus = @import("corpus.zig");
const snappy = @import("../snappy.zig");

const streams = @embedFile("snappy-streams.corpus");
const invalid = @embedFile("snappy-stream-invalid.corpus");

/// An S2 writer's settings as the corpus names them: "<mode> <format>
/// block=<n> pad=<n> index=<i> concurrency=<n> cuts=<a,b>".
const Writer = struct {
    options: snappy.Compressor.Options,
    stream: snappy.Stream,
    /// Where the input was cut, a flush after each piece but the last.
    cuts: []const u8,

    fn parse(params: []const u8) !Writer {
        var it = std.mem.splitScalar(u8, params, ' ');
        const mode = it.next().?;
        const format = std.meta.stringToEnum(snappy.Format, it.next().?).?;
        var w: Writer = .{ .options = .{ .format = format }, .stream = .{}, .cuts = "" };
        if (std.mem.eql(u8, mode, "uncompressed")) w.stream.store = true else w.options.level = std.meta.stringToEnum(snappy.Compressor.Level, mode).?;
        while (it.next()) |kv| {
            const eq = std.mem.findScalar(u8, kv, '=').?;
            const key = kv[0..eq];
            const value = kv[eq + 1 ..];
            if (std.mem.eql(u8, key, "block")) {
                const b = try std.fmt.parseInt(usize, value, 10);
                if (b != 0) w.stream.block_size = .fromRaw(b);
            } else if (std.mem.eql(u8, key, "pad")) {
                w.stream.padding = .fromRaw(try std.fmt.parseInt(usize, value, 10));
            } else if (std.mem.eql(u8, key, "index")) {
                w.stream.index = std.meta.stringToEnum(snappy.IndexPlace, value).?;
            } else if (std.mem.eql(u8, key, "cuts")) {
                w.cuts = value;
            }
        }
        return w;
    }
};

/// A stream as the corpus stores it: its bytes, or "sha256 <hex> <len>".
fn same(stored: []const u8, got: []const u8) !void {
    if (!std.mem.startsWith(u8, stored, "sha256 ")) return testing.expectEqualSlices(u8, stored, got);
    var it = std.mem.splitScalar(u8, stored, ' ');
    _ = it.next();
    var want: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want, it.next().?);
    try testing.expectEqual(try std.fmt.parseInt(usize, it.next().?, 10), got.len);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(got, &digest, .{});
    try testing.expectEqualSlices(u8, &want, &digest);
}

test "warp writes S2's streams and indexes byte for byte, whole" {
    const gpa = testing.allocator;
    const parsed = try corpus.Corpus.parse(streams);
    var it = parsed.records();
    var count: usize = 0;
    while (it.next()) |r| {
        if (!std.mem.eql(u8, r.fields[0], "s2 v1.20.3")) continue;
        const params = r.fields[1];
        if (std.mem.startsWith(u8, params, "indexstream ") or std.mem.startsWith(u8, params, "find ")) continue;
        const w = try Writer.parse(params);
        if (w.cuts.len != 0) continue;
        errdefer std.debug.print("{s}: {s}\n", .{ params, r.fields[2] });
        const in = try corpus.input(gpa, r.fields[2]);
        defer gpa.free(in);
        var c: snappy.Compressor = try .init(gpa, w.options);
        defer c.deinit();
        const out = try gpa.alloc(u8, snappy.streamBound(w.options, in.len, w.stream));
        defer gpa.free(out);
        const result = try c.compress(in, out, w.stream);
        try same(r.fields[3], out[0..result.len]);
        try testing.expectEqualSlices(u8, r.fields[4], out[result.len..][0..result.index_len]);
        // And it reads back.
        const back = try gpa.alloc(u8, in.len);
        defer gpa.free(back);
        try testing.expectEqual(in.len, try snappy.decompress(out[0..result.len], back, .{}));
        try testing.expectEqualSlices(u8, in, back);
        try testing.expectEqual(@as(u64, in.len), try snappy.decompressedLen(out[0..result.len], .{}));
        count += 1;
    }
    // Each mode and format on nine inputs, and each setting on two.
    try testing.expect(count >= 118);
}

test "an existing stream's index as S2's IndexStream writes it, and found in as its Find finds" {
    const gpa = testing.allocator;
    const parsed = try corpus.Corpus.parse(streams);
    var it = parsed.records();
    var indexed: usize = 0;
    var found: usize = 0;
    while (it.next()) |r| {
        const params = r.fields[1];
        errdefer std.debug.print("{s}: {s}\n", .{ params, r.fields[2] });
        if (std.mem.startsWith(u8, params, "indexstream ")) {
            const in = try corpus.input(gpa, r.fields[2]);
            defer gpa.free(in);
            const w = try Writer.parse(params["indexstream ".len..]);
            var c: snappy.Compressor = try .init(gpa, w.options);
            defer c.deinit();
            const out = try gpa.alloc(u8, snappy.streamBound(w.options, in.len, w.stream));
            defer gpa.free(out);
            const result = try c.compress(in, out, w.stream);
            const stream = out[0..result.len];
            const index = try gpa.alloc(u8, snappy.Index.bound(try snappy.Index.streamEntries(stream)));
            defer gpa.free(index);
            const n = try snappy.indexStream(stream, index);
            try testing.expectEqualSlices(u8, r.fields[4], index[0..n]);
            indexed += 1;
        } else if (std.mem.startsWith(u8, params, "find ")) {
            const storage = try gpa.alloc(snappy.Index.Entry, snappy.Index.max_entries);
            defer gpa.free(storage);
            const index, _ = try snappy.Index.load(r.fields[3], storage);
            const list = params[std.mem.find(u8, params, "offsets=").? + "offsets=".len ..];
            var offsets = std.mem.splitScalar(u8, list, ',');
            var answers = r.fields[4];
            while (offsets.next()) |text| {
                const offset = try std.fmt.parseInt(i64, text, 10);
                const ok = answers[0] == 1;
                const c = std.mem.readInt(u64, answers[1..9], .little);
                const u = std.mem.readInt(u64, answers[9..17], .little);
                answers = answers[17..];
                if (index.find(offset)) |e| {
                    try testing.expect(ok);
                    try testing.expectEqual(snappy.Index.Entry{ .compressed = c, .uncompressed = u }, e);
                } else |_| try testing.expect(!ok);
                found += 1;
            }
        }
    }
    try testing.expect(indexed >= 22);
    try testing.expect(found >= 22 * 14);
}

test "every stream S2, golang/snappy and snap wrote decodes to its input" {
    const gpa = testing.allocator;
    const parsed = try corpus.Corpus.parse(streams);
    var it = parsed.records();
    var count: usize = 0;
    while (it.next()) |r| {
        const params = r.fields[1];
        if (std.mem.startsWith(u8, params, "indexstream ") or std.mem.startsWith(u8, params, "find ")) continue;
        // Long inputs' streams are digests; warp's own, the same bytes,
        // are read back where they are written.
        const stored = r.fields[3];
        if (std.mem.startsWith(u8, stored, "sha256 ")) continue;
        errdefer std.debug.print("{s} {s}: {s}\n", .{ r.fields[0], params, r.fields[2] });
        const in = try corpus.input(gpa, r.fields[2]);
        defer gpa.free(in);
        const out = try gpa.alloc(u8, in.len);
        defer gpa.free(out);
        try testing.expectEqual(in.len, try snappy.decompress(stored, out, .{}));
        try testing.expectEqualSlices(u8, in, out);
        count += 1;
    }
    try testing.expect(count >= 28);
}

test "mutated and constructed streams get S2's reader's verdict" {
    const gpa = testing.allocator;
    const parsed = try corpus.Corpus.parse(invalid);
    var it = parsed.records();
    var count: usize = 0;
    while (it.next()) |r| : (count += 1) {
        errdefer std.debug.print("{s}: {s}\n", .{ r.fields[0], r.fields[3] });
        const max_block = std.mem.readInt(u32, r.fields[1][0..4], .little);
        const stream = r.fields[2];
        const verdict = r.fields[3];
        const options: snappy.StreamOptions = .{ .max_block_size = .fromRaw(if (max_block == 0) 4 << 20 else max_block) };
        // The streams decode to 40 KB at most; more is refused before
        // it is written.
        const out = try gpa.alloc(u8, 1 << 20);
        defer gpa.free(out);
        const got = snappy.decompress(stream, out, options);
        if (std.mem.startsWith(u8, verdict, "ok ")) {
            var v = std.mem.splitScalar(u8, verdict["ok ".len..], ' ');
            const want_len = try std.fmt.parseInt(usize, v.next().?, 10);
            const want_crc = try std.fmt.parseInt(u32, v.next().?, 10);
            const n = try got;
            try testing.expectEqual(want_len, n);
            try testing.expectEqual(want_crc, std.hash.Crc32.hash(out[0..n]));
        } else if (std.mem.eql(u8, verdict, "error crc")) {
            try testing.expectError(error.ChecksumMismatch, got);
        } else if (std.mem.eql(u8, verdict, "error unsupported")) {
            try testing.expectError(error.Unsupported, got);
        } else if (std.mem.eql(u8, verdict, "error corrupt")) {
            if (got) |_| return error.Accepted else |err| try testing.expect(err == error.InvalidStream or err == error.Truncated);
        } else return error.BadCorpus;
    }
    try testing.expect(count >= 337);
}

/// The stream `Compress` writes for `in` taken `step` bytes at a time
/// into outputs of `room` bytes, flushed at each of `cuts`; with its index
/// apart.
fn compressInPieces(gpa: std.mem.Allocator, w: Writer, in: []const u8, cuts: []const u8, step: usize, room: usize) !struct { []u8, []u8 } {
    var s: snappy.Compress = try .init(gpa, .{ .compressor = w.options, .stream = w.stream });
    defer s.deinit();
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const buffer = try gpa.alloc(u8, room);
    defer gpa.free(buffer);
    var at: usize = 0;
    var bounds = std.mem.splitScalar(u8, cuts, ',');
    while (true) {
        const text = bounds.next();
        const end = if (text) |t| (if (t.len == 0) in.len else try std.fmt.parseInt(usize, t, 10)) else in.len;
        while (at < end) {
            const r = try s.write(in[at..@min(end, at + step)], buffer);
            at += r.in_len;
            try out.appendSlice(gpa, buffer[0..r.out_len]);
        }
        if (text == null or text.?.len == 0) break;
        while (true) {
            const d = try s.flush(buffer);
            try out.appendSlice(gpa, buffer[0..d.out_len]);
            if (d.done) break;
        }
    }
    while (true) {
        const d = try s.finish(buffer);
        try out.appendSlice(gpa, buffer[0..d.out_len]);
        if (d.done) break;
    }
    const index = try gpa.dupe(u8, if (w.stream.index == .apart) s.index() else "");
    return .{ try out.toOwnedSlice(gpa), index };
}

test "the resumable compressor writes S2's streams, in pieces, flushed where S2's writer was" {
    const gpa = testing.allocator;
    const parsed = try corpus.Corpus.parse(streams);
    var it = parsed.records();
    var count: usize = 0;
    while (it.next()) |r| : (count += 1) {
        if (!std.mem.eql(u8, r.fields[0], "s2 v1.20.3")) continue;
        const params = r.fields[1];
        if (std.mem.startsWith(u8, params, "indexstream ") or std.mem.startsWith(u8, params, "find ")) continue;
        const w = try Writer.parse(params);
        errdefer std.debug.print("{s}: {s}\n", .{ params, r.fields[2] });
        const in = try corpus.input(gpa, r.fields[2]);
        defer gpa.free(in);
        // Pieces of input and output from one byte to more than a block.
        const steps = [_]usize{ 1, 7, 4096, 65536, 1 << 22 };
        const rooms = [_]usize{ 1, 13, 5000, 1 << 21 };
        const big = in.len > 1 << 20;
        const stream, const index = try compressInPieces(gpa, w, in, w.cuts, if (big) 1 << 18 else steps[count % steps.len], if (big) 1 << 16 else rooms[count % rooms.len]);
        defer gpa.free(stream);
        defer gpa.free(index);
        try same(r.fields[3], stream);
        try testing.expectEqualSlices(u8, r.fields[4], index);
    }
}

/// What `Decompress` makes of `stream` given `step` bytes at a time into
/// outputs of `room` bytes: the output, or the error.
fn decodeInPieces(gpa: std.mem.Allocator, stream: []const u8, options: snappy.StreamOptions, step: usize, room: usize, out: *std.ArrayList(u8)) !void {
    const window = try gpa.alloc(u8, snappy.Decompress.memory(options.max_block_size));
    defer gpa.free(window);
    var d: snappy.Decompress = try .init(window, options);
    const buffer = try gpa.alloc(u8, room);
    defer gpa.free(buffer);
    var at: usize = 0;
    while (true) {
        const r = try d.decode(stream[at..@min(stream.len, at + step)], buffer);
        at += r.in_len;
        try out.appendSlice(gpa, buffer[0..r.out_len]);
        if (r.status == .need_input and at == stream.len) break;
    }
    try d.finish();
}

test "the resumable decoder answers as the whole-buffer one, at every cut and output size" {
    const gpa = testing.allocator;
    for ([_][]const u8{ streams, invalid }) |file| {
        const parsed = try corpus.Corpus.parse(file);
        var it = parsed.records();
        var count: usize = 0;
        while (it.next()) |r| : (count += 1) {
            const stream = if (file.ptr == streams.ptr) r.fields[3] else r.fields[2];
            if (std.mem.startsWith(u8, stream, "sha256 ") or stream.len > 1 << 20) continue;
            var options: snappy.StreamOptions = .{};
            if (file.ptr == invalid.ptr) {
                const max_block = std.mem.readInt(u32, r.fields[1][0..4], .little);
                if (max_block != 0) options.max_block_size = .fromRaw(max_block);
            }
            const whole = try gpa.alloc(u8, 1 << 20);
            defer gpa.free(whole);
            const want = snappy.decompress(stream, whole, options);
            for ([_][2]usize{ .{ 1, 1 }, .{ 3, 4097 }, .{ 4096, 7 }, .{ 1 << 20, 1 << 20 }, .{ 9 + count % 13, 1 + count % 300 } }) |cut| {
                var out: std.ArrayList(u8) = .empty;
                defer out.deinit(gpa);
                const got = decodeInPieces(gpa, stream, options, cut[0], cut[1], &out);
                errdefer std.debug.print("{s} at {d}/{d}: {any} vs {any}\n", .{ r.fields[0], cut[0], cut[1], got, want });
                if (want) |n| {
                    try got;
                    try testing.expectEqualSlices(u8, whole[0..n], out.items);
                } else |err| {
                    try testing.expectError(err, got);
                    // Output before the refusal is a prefix of the whole.
                }
            }
        }
    }
}

test "a seek by the index: the reader starts at the entry found and skips to the offset" {
    const gpa = testing.allocator;
    const in = try corpus.input(gpa, "text 70 3000000");
    defer gpa.free(in);
    const options: snappy.Compressor.Options = .{ .format = .s2 };
    const stream_options: snappy.Stream = .{ .block_size = .fromRaw(65536), .index = .append };
    var c: snappy.Compressor = try .init(gpa, options);
    defer c.deinit();
    const out = try gpa.alloc(u8, snappy.streamBound(options, in.len, stream_options));
    defer gpa.free(out);
    const stream = out[0..(try c.compress(in, out, stream_options)).len];
    const storage = try gpa.alloc(snappy.Index.Entry, snappy.Index.max_entries);
    defer gpa.free(storage);
    const index = try snappy.Index.loadFromEnd(stream, storage);
    for ([_]i64{ 0, 1, 65535, 65536, 1 << 20, (1 << 20) + 77, 2_999_999, -5 }) |offset| {
        const e = try index.find(offset);
        const at: u64 = @intCast(if (offset < 0) @as(i64, @intCast(in.len)) + offset else offset);
        const window = try gpa.alloc(u8, snappy.Decompress.memory(.literal("4MiB")));
        defer gpa.free(window);
        var d: snappy.Decompress = try .init(window, .{ .from_chunk = true });
        d.skip(at - e.uncompressed);
        var buffer: [100]u8 = undefined;
        var got: usize = 0;
        var ip: usize = @intCast(e.compressed);
        while (got < @min(buffer.len, in.len - at)) {
            const r = try d.decode(stream[ip..], buffer[got..]);
            ip += r.in_len;
            got += r.out_len;
        }
        try testing.expectEqualSlices(u8, in[@intCast(at)..][0..got], buffer[0..got]);
    }
}

test "the parallel encoder writes the whole-buffer encoder's streams, and the parallel decoder answers as the whole-buffer one" {
    const gpa = testing.allocator;
    const parsed = try corpus.Corpus.parse(streams);
    var it = parsed.records();
    var count: usize = 0;
    while (it.next()) |r| {
        if (!std.mem.eql(u8, r.fields[0], "s2 v1.20.3")) continue;
        const params = r.fields[1];
        if (std.mem.startsWith(u8, params, "indexstream ") or std.mem.startsWith(u8, params, "find ")) continue;
        const w = try Writer.parse(params);
        if (w.cuts.len != 0) continue;
        errdefer std.debug.print("{s}: {s}\n", .{ params, r.fields[2] });
        const in = try corpus.input(gpa, r.fields[2]);
        defer gpa.free(in);
        for ([_]u16{ 1, 3 }) |workers| {
            var p: snappy.parallel.Compressor = try .init(gpa, .{ .concurrency = workers, .compressor = w.options, .stream = w.stream });
            defer p.deinit();
            const out = try gpa.alloc(u8, snappy.parallel.Compressor.bound(p.options, in.len));
            defer gpa.free(out);
            const result = try p.compress(testing.io, in, out);
            try same(r.fields[3], out[0..result.len]);
            try testing.expectEqualSlices(u8, r.fields[4], out[result.len..][0..result.index_len]);
            var d: snappy.parallel.Decompressor = try .init(gpa, .{ .concurrency = workers });
            defer d.deinit();
            const back = try gpa.alloc(u8, in.len);
            defer gpa.free(back);
            try testing.expectEqual(in.len, try d.decompress(testing.io, out[0..result.len], back, .{}));
            try testing.expectEqualSlices(u8, in, back);
        }
        count += 1;
    }
    try testing.expect(count >= 118);

    // Refused streams: the whole-buffer decoder's errors.
    const bad = try corpus.Corpus.parse(invalid);
    var bad_it = bad.records();
    var d: snappy.parallel.Decompressor = try .init(gpa, .{ .concurrency = 3 });
    defer d.deinit();
    const a = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(a);
    const b = try gpa.alloc(u8, 1 << 20);
    defer gpa.free(b);
    while (bad_it.next()) |r| {
        const max_block = std.mem.readInt(u32, r.fields[1][0..4], .little);
        const options: snappy.StreamOptions = .{ .max_block_size = .fromRaw(if (max_block == 0) 4 << 20 else max_block) };
        const want = snappy.decompress(r.fields[2], a, options);
        const got = d.decompress(testing.io, r.fields[2], b, options);
        if (want) |n| {
            try testing.expectEqual(n, try got);
            try testing.expectEqualSlices(u8, a[0..n], b[0..n]);
        } else |err| try testing.expectError(err, got);
    }
}

/// A stream of generated input at random settings, written whole.
fn someStream(case: *shakedown.Case, plain: []const u8) !struct { []u8, snappy.Compressor.Options, snappy.Stream } {
    const s = case.source;
    const level = shakedown.gen.enumValue(s, snappy.Compressor.Level);
    const format = shakedown.gen.enumValue(s, snappy.Format);
    const options: snappy.Compressor.Options = .{ .format = format, .level = level };
    const max: usize = if (format == .snappy) 64 << 10 else 4 << 20;
    var stream: snappy.Stream = .{
        .padding = .fromRaw(if (shakedown.gen.boolean(s)) shakedown.gen.intRange(s, usize, 0, 70_000) else 0),
        .index = shakedown.gen.enumValue(s, snappy.IndexPlace),
        .store = shakedown.gen.intRange(s, u8, 0, 5) == 0,
    };
    if (shakedown.gen.boolean(s)) stream.block_size = .fromRaw(shakedown.gen.intRange(s, usize, 4096, @min(max, 70_000)));
    var c: snappy.Compressor = try .init(case.gpa, options);
    defer c.deinit();
    const out = try case.gpa.alloc(u8, snappy.streamBound(options, plain.len, stream));
    const r = try c.compress(plain, out, stream);
    return .{ out[0..r.len], options, stream };
}

/// Arbitrary bytes and mutated real streams: the whole-buffer, resumable
/// and parallel decoders give one answer.
fn streamsAgree(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    var input: []u8 = undefined;
    if (shakedown.gen.boolean(s)) {
        input = try shakedown.gen.string(s, case.gpa, .{ .kind = .bytes, .max_len = 400, .average = 60 });
        if (input.len >= 10 and shakedown.gen.boolean(s)) @memcpy(input[0..10], if (shakedown.gen.boolean(s)) "\xff\x06\x00\x00S2sTwO" else "\xff\x06\x00\x00sNaPpY");
    } else {
        const plain = try gen.alloc(case.gpa, shakedown.gen.enumValue(s, gen.Kind), shakedown.gen.int(s, u16), shakedown.gen.intRange(s, usize, 0, 100_000));
        input, _, _ = try someStream(case, plain);
        for (0..shakedown.gen.intRange(s, usize, 0, 3)) |_| {
            if (input.len > 0) input[shakedown.gen.intRange(s, usize, 0, input.len - 1)] ^= @as(u8, 1) << shakedown.gen.intRange(s, u3, 0, 7);
        }
        if (shakedown.gen.boolean(s)) input = input[0..shakedown.gen.intRange(s, usize, 0, input.len)];
    }
    const options: snappy.StreamOptions = .{ .max_block_size = .fromRaw(if (shakedown.gen.boolean(s)) 4 << 20 else shakedown.gen.intRange(s, usize, 1, 70_000)) };
    case.note("{d} bytes, max block {d}", .{ input.len, options.max_block_size.raw() });
    const whole = try case.gpa.alloc(u8, 1 << 20);
    const want = snappy.decompress(input, whole, options);
    var out: std.ArrayList(u8) = .empty;
    const got = decodeInPieces(case.gpa, input, options, shakedown.gen.intRange(s, usize, 1, 5000), shakedown.gen.intRange(s, usize, 1, 5000), &out);
    var d: snappy.parallel.Decompressor = try .init(case.gpa, .{ .concurrency = 3 });
    defer d.deinit();
    const back = try case.gpa.alloc(u8, 1 << 20);
    const par = d.decompress(testing.io, input, back, options);
    if (want) |n| {
        try got;
        try testing.expectEqualSlices(u8, whole[0..n], out.items);
        try testing.expectEqual(n, try par);
        try testing.expectEqualSlices(u8, whole[0..n], back[0..n]);
    } else |err| {
        try testing.expectError(err, got);
        try testing.expectError(err, par);
    }
}

test "fuzz: any bytes into the stream decoders, whole, resumable and parallel, get one answer" {
    try shakedown.check(testing.allocator, {}, streamsAgree, .{ .cases = 1500, .seed = 0x5a5d });
}

/// Any input at any parser, format and stream setting: the resumable and
/// parallel encoders write the whole-buffer stream, flushes and skippable
/// chunks keep it decoding to the input, and its index finds every block.
fn streamRoundTrips(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const plain = try gen.alloc(case.gpa, shakedown.gen.enumValue(s, gen.Kind), shakedown.gen.int(s, u16), shakedown.gen.intRange(s, usize, 0, 300_000));
    const stream, const options, const settings = try someStream(case, plain);
    case.note("{d} bytes, {t} {t}, block {?d}, padding {d}, index {t}, store {}", .{ plain.len, options.format, options.parser(), if (settings.block_size) |b| b.raw() else null, settings.padding.raw(), settings.index, settings.store });
    const w: Writer = .{ .options = options, .stream = settings, .cuts = "" };
    const pieces, const index = try compressInPieces(case.gpa, w, plain, "", shakedown.gen.intRange(s, usize, 1, 100_000), shakedown.gen.intRange(s, usize, 1, 100_000));
    try testing.expectEqualSlices(u8, stream, pieces);
    var p: snappy.parallel.Compressor = try .init(case.gpa, .{ .concurrency = 2, .compressor = options, .stream = settings });
    defer p.deinit();
    const par = try case.gpa.alloc(u8, snappy.parallel.Compressor.bound(p.options, plain.len));
    try testing.expectEqualSlices(u8, stream, par[0..(try p.compress(testing.io, plain, par)).len]);
    const back = try case.gpa.alloc(u8, plain.len);
    try testing.expectEqual(plain.len, try snappy.decompress(stream, back, .{}));
    try testing.expectEqualSlices(u8, plain, back);
    if (settings.index != .none) {
        const storage = try case.gpa.alloc(snappy.Index.Entry, snappy.Index.max_entries);
        const loaded = if (settings.index == .append) try snappy.Index.loadFromEnd(stream, storage) else (try snappy.Index.load(index, storage))[0];
        try testing.expectEqual(@as(u64, plain.len), loaded.total_uncompressed);
        if (plain.len > 0) {
            const at = shakedown.gen.intRange(s, usize, 0, plain.len - 1);
            const e = try loaded.find(@intCast(at));
            const window = try case.gpa.alloc(u8, snappy.Decompress.memory(.literal("4MiB")));
            var d: snappy.Decompress = try .init(window, .{ .from_chunk = true });
            d.skip(at - e.uncompressed);
            var one: [1]u8 = undefined;
            const r = try d.decode(stream[@intCast(e.compressed)..], &one);
            try testing.expectEqual(@as(usize, 1), r.out_len);
            try testing.expectEqual(plain[at], one[0]);
        }
    }
    // Flushes and skippable chunks anywhere: the stream still decodes.
    var c: snappy.Compress = try .init(case.gpa, .{ .compressor = options, .stream = settings });
    defer c.deinit();
    var out: std.ArrayList(u8) = .empty;
    var buffer: [3000]u8 = undefined;
    var at: usize = 0;
    while (at < plain.len) {
        const r = try c.write(plain[at..@min(plain.len, at + shakedown.gen.intRange(s, usize, 1, 90_000))], &buffer);
        at += r.in_len;
        try out.appendSlice(case.gpa, buffer[0..r.out_len]);
        switch (shakedown.gen.intRange(s, u8, 0, 9)) {
            0 => while (true) {
                const f = try c.flush(&buffer);
                try out.appendSlice(case.gpa, buffer[0..f.out_len]);
                if (f.done) break;
            },
            1 => while (true) {
                const f = try c.skippable(0x80 + shakedown.gen.intRange(s, u8, 0, 0x7e), "skip me", &buffer);
                try out.appendSlice(case.gpa, buffer[0..f.out_len]);
                if (f.done) break;
            },
            else => {},
        }
    }
    while (true) {
        const f = try c.finish(&buffer);
        try out.appendSlice(case.gpa, buffer[0..f.out_len]);
        if (f.done) break;
    }
    try testing.expectEqual(plain.len, try snappy.decompress(out.items, back, .{}));
    try testing.expectEqualSlices(u8, plain, back);
}

test "fuzz: any input at any stream setting is written alike by every encoder and comes back whole" {
    try shakedown.check(testing.allocator, {}, streamRoundTrips, .{ .cases = 150, .seed = 0x5a5e });
}

/// Arbitrary and mutated indexes: loaded or refused, and searched at any
/// offset once loaded.
fn indexesLoad(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    var bytes: []u8 = undefined;
    if (shakedown.gen.boolean(s)) {
        bytes = try shakedown.gen.string(s, case.gpa, .{ .kind = .bytes, .max_len = 300, .average = 60 });
        if (bytes.len > 10 and shakedown.gen.boolean(s)) @memcpy(bytes[0..10], "\x99\x00\x01\x00s2idx\x00");
    } else {
        const plain = try gen.alloc(case.gpa, .runs, shakedown.gen.int(s, u16), shakedown.gen.intRange(s, usize, 0, 9 << 20));
        var c: snappy.Compressor = try .init(case.gpa, .{ .format = .s2 });
        defer c.deinit();
        const settings: snappy.Stream = .{ .block_size = .fromRaw(65536), .index = .apart, .store = true };
        const out = try case.gpa.alloc(u8, snappy.streamBound(c.options, plain.len, settings));
        const r = try c.compress(plain, out, settings);
        bytes = out[r.len..][0..r.index_len];
        for (0..shakedown.gen.intRange(s, usize, 0, 3)) |_| {
            if (bytes.len > 0) bytes[shakedown.gen.intRange(s, usize, 0, bytes.len - 1)] ^= @as(u8, 1) << shakedown.gen.intRange(s, u3, 0, 7);
        }
        if (shakedown.gen.boolean(s)) bytes = bytes[0..shakedown.gen.intRange(s, usize, 0, bytes.len)];
    }
    case.note("{d} bytes", .{bytes.len});
    const storage = try case.gpa.alloc(snappy.Index.Entry, snappy.Index.max_entries);
    const index, _ = snappy.Index.load(bytes, storage) catch return;
    for (0..20) |_| {
        const offset = shakedown.gen.intRange(s, i64, -2 * @as(i64, @intCast(@min(index.total_uncompressed, 1 << 40))) - 1, 2 * @as(i64, @intCast(@min(index.total_uncompressed, 1 << 40))) + 1);
        const e = index.find(offset) catch continue;
        const at: u64 = @intCast(if (offset < 0) @as(i64, @intCast(index.total_uncompressed)) + offset else offset);
        if (index.entries.len > 0 and index.entries[0].uncompressed == 0) try testing.expect(e.uncompressed <= at);
    }
}

test "fuzz: any bytes into the index loader, and any offset into a loaded index" {
    try shakedown.check(testing.allocator, {}, indexesLoad, .{ .cases = 2000, .seed = 0x5a51 });
}

test "resumable decoder and whole-stream decoder refuse a maximum past 4 MiB and a short buffer" {
    const gpa = testing.allocator;
    const window = try gpa.alloc(u8, snappy.Decompress.memory(.literal("64KiB")));
    defer gpa.free(window);
    try testing.expectError(error.BufferTooSmall, snappy.Decompress.init(window[0 .. window.len - 1], .{ .max_block_size = .literal("64KiB") }));
    _ = try snappy.Decompress.init(window, .{ .max_block_size = .literal("64KiB") });
    const past: snappy.StreamOptions = .{ .max_block_size = .fromRaw((4 << 20) + 1) };
    try testing.expectError(error.InvalidOptions, snappy.Decompress.init(window, past));
    try testing.expectEqual(snappy.Decompress.memory(.literal("4MiB")), snappy.Decompress.memory(.fromRaw(std.math.maxInt(usize))));
    var out: [16]u8 = undefined;
    try testing.expectError(error.InvalidOptions, snappy.decompress("", &out, past));
}

test "a stream bound is maxInt for a stream the compressor refuses" {
    const options: snappy.Compressor.Options = .{};
    try testing.expectEqual(std.math.maxInt(usize), snappy.streamBound(options, 100, .{ .block_size = .fromRaw(0) }));
    try testing.expectEqual(std.math.maxInt(usize), snappy.streamBound(options, 100, .{ .padding = .fromRaw(std.math.maxInt(usize)) }));
    // A valid stream bounds a whole block: the identifier, one chunk, the padding's header.
    const b = snappy.Compressor.blockSize(options, .{});
    try testing.expectEqual(10 + snappy.Compressor.chunkBound(b) + 4, snappy.streamBound(options, 100, .{}));
}
