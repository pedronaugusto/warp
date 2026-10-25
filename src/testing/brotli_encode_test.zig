//! The Brotli encoder against the format's reference library (google/brotli
//! 1.2.1): for every stream the reference wrote, with its parameters,
//! dictionary, flushes and metadata, the encoder writes the same bytes;
//! what it writes for anything else decodes to its input.

const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const corpus = @import("corpus.zig");
const decode_test = @import("brotli_decode_test.zig");
const Compressor = @import("../brotli/Compressor.zig");
const Compress = @import("../brotli/Compress.zig");
const Decompressor = @import("../brotli/Decompressor.zig");
const Prepared = @import("../brotli/Prepared.zig");

const input = @import("zstd_decode_test.zig").input;

/// A captured record's parameters ("quality=5 window=22 mode=generic ...").
const Params = struct {
    options: Compressor.Options,
    size_hint: bool,
    flush_every: usize,
    metadata: usize,

    fn parse(text: []const u8) !Params {
        var p: Params = .{ .options = .{}, .size_hint = false, .flush_every = 0, .metadata = 0 };
        var it = std.mem.tokenizeScalar(u8, text, ' ');
        while (it.next()) |pair| {
            const eq = std.mem.findScalar(u8, pair, '=').?;
            const key = pair[0..eq];
            const value = pair[eq + 1 ..];
            if (std.mem.eql(u8, key, "quality")) p.options.quality = try std.fmt.parseInt(u4, value, 10);
            if (std.mem.eql(u8, key, "window")) p.options.window_bits = try std.fmt.parseInt(u5, value, 10);
            if (std.mem.eql(u8, key, "mode")) p.options.mode = std.meta.stringToEnum(Compressor.Mode, value).?;
            if (std.mem.eql(u8, key, "large_window")) p.options.large_window = std.mem.eql(u8, value, "true");
            if (std.mem.eql(u8, key, "size_hint")) p.size_hint = std.mem.eql(u8, value, "true");
            if (std.mem.eql(u8, key, "flush_every")) p.flush_every = try std.fmt.parseInt(usize, value, 10);
            if (std.mem.eql(u8, key, "metadata")) p.metadata = try std.fmt.parseInt(usize, value, 10);
        }
        return p;
    }
};

/// Drive `c` as the capture drove the reference: metadata first, then the
/// input whole or in flushed pieces, then the end; output `step` bytes at
/// a time.
fn stream(gpa: std.mem.Allocator, c: *Compress, in: []const u8, p: Params, step: usize) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const buf = try gpa.alloc(u8, step);
    defer gpa.free(buf);
    if (p.metadata != 0) {
        const meta = try gpa.alloc(u8, p.metadata);
        defer gpa.free(meta);
        for (meta, 0..) |*m, i| m.* = @truncate(i * 7);
        var at: usize = 0;
        while (true) {
            const r = try c.metadata(meta[at..], buf);
            at += r.in_len;
            try out.appendSlice(gpa, buf[0..r.out_len]);
            if (r.done) break;
        }
    }
    const piece = if (p.flush_every == 0) @max(in.len, 1) else p.flush_every;
    var at: usize = 0;
    while (at < in.len) {
        const end = @min(at + piece, in.len);
        while (at < end) {
            const r = try c.write(in[at..end], buf);
            at += r.in_len;
            try out.appendSlice(gpa, buf[0..r.out_len]);
        }
        if (p.flush_every != 0) while (true) {
            const r = try c.flush(buf);
            try out.appendSlice(gpa, buf[0..r.out_len]);
            if (r.done) break;
        };
    }
    while (true) {
        const r = try c.finish(buf);
        try out.appendSlice(gpa, buf[0..r.out_len]);
        if (r.done) break;
    }
    return out.toOwnedSlice(gpa);
}

fn prepared(gpa: std.mem.Allocator, dict: []const u8) !?Prepared {
    if (dict.len == 0) return null;
    return try Prepared.init(gpa, dict);
}

test "for every stream the reference wrote, the encoder writes the same bytes, streaming and whole" {
    const gpa = testing.allocator;
    const c = try corpus.Corpus.parse(decode_test.streams);
    var it = c.records();
    var count: usize = 0;
    while (it.next()) |r| {
        if (!std.mem.eql(u8, r.fields[0], "brotli 1.2.1")) continue;
        const p = try Params.parse(r.fields[1]);
        const in = try input(gpa, r.fields[2]);
        defer gpa.free(in);
        const dict = if (r.fields[3].len > 0) try input(gpa, r.fields[3]) else try gpa.alloc(u8, 0);
        defer gpa.free(dict);
        var prep = try prepared(gpa, dict);
        defer if (prep) |*d| d.deinit(gpa);
        var options = p.options;
        options.dictionary = if (prep) |*d| d else null;
        if (p.size_hint) options.size_hint = in.len;
        const want = r.fields[4];
        // Output a byte at a time for small streams: waiting output.
        for ([_]usize{ 1 << 16, if (want.len < 4096) 1 else 777 }) |step| {
            var s = try Compress.init(gpa, options);
            defer s.deinit();
            const got = try stream(gpa, &s, in, p, step);
            defer gpa.free(got);
            testing.expectEqualSlices(u8, want, got) catch |err| {
                std.debug.print("{s} | {s} | {s}: step {d}\n", .{ r.fields[1], r.fields[2], r.fields[3], step });
                return err;
            };
        }
        // The whole-buffer encoder: the input's length is its size hint,
        // as when the reference reads the whole input before its first
        // block.
        if (p.flush_every == 0 and p.metadata == 0 and in.len > 0) {
            var whole = Compressor.init(gpa, options);
            defer whole.deinit();
            const out = try gpa.alloc(u8, Compressor.bound(in.len));
            defer gpa.free(out);
            const n = try whole.compress(in, out);
            try testing.expectEqualSlices(u8, want, out[0..n]);
        }
        count += 1;
    }
    try testing.expect(count > 400);
}

fn roundTrip(gpa: std.mem.Allocator, z: []const u8, in: []const u8, dict: []const u8, large_window: bool) !void {
    const d = try gpa.create(Decompressor);
    defer gpa.destroy(d);
    d.* = .init;
    const back = try gpa.alloc(u8, in.len + 1);
    defer gpa.free(back);
    const r = try d.decompress(z, back, .{ .dictionary = dict, .large_window = large_window, .streams = .one });
    try testing.expectEqual(z.len, r.in_len);
    try testing.expectEqualSlices(u8, in, back[0..r.out_len]);
}

const Case = struct {
    fn run(_: void, case: *shakedown.Case) !void {
        const gpa = case.gpa;
        const src = case.source;
        const in = try shakedown.gen.string(src, gpa, .{ .kind = .bytes, .max_len = 20000, .average = 2000 });
        const repeat = shakedown.gen.intRange(src, usize, 0, 3);
        // Repeats give the match finders something to find.
        for (0..repeat) |_| if (in.len > 64) {
            const from = shakedown.gen.intRange(src, usize, 0, in.len - 32);
            const to = shakedown.gen.intRange(src, usize, 0, in.len - 32);
            const n = shakedown.gen.intRange(src, usize, 1, @min(in.len - from, in.len - to));
            @memmove(in[to..][0..n], in[from..][0..n]);
        };
        const dict = if (shakedown.gen.boolean(src)) in[0..@min(in.len, shakedown.gen.intRange(src, usize, 0, 5000))] else in[0..0];
        var prep = try prepared(gpa, dict);
        defer if (prep) |*d| d.deinit(gpa);
        const large = shakedown.gen.intRange(src, u8, 0, 7) == 0;
        const options: Compressor.Options = .{
            .quality = shakedown.gen.intRange(src, u4, 0, 11),
            .window_bits = shakedown.gen.intRange(src, u5, 10, if (large) 30 else 24),
            .large_window = large,
            .mode = shakedown.gen.enumValue(src, Compressor.Mode),
            .block_bits = if (shakedown.gen.boolean(src)) shakedown.gen.intRange(src, u5, 16, 24) else null,
            .disable_literal_context_modeling = shakedown.gen.boolean(src),
            .dictionary = if (prep) |*d| d else null,
        };
        const p: Params = .{ .options = options, .size_hint = false, .flush_every = if (shakedown.gen.boolean(src)) shakedown.gen.intRange(src, usize, 1, 3000) else 0, .metadata = if (shakedown.gen.intRange(src, u8, 0, 7) == 0) shakedown.gen.intRange(src, usize, 1, 500) else 0 };
        var s = try Compress.init(gpa, options);
        defer s.deinit();
        const z = try stream(gpa, &s, in, p, shakedown.gen.intRange(src, usize, 1, 5000));
        defer gpa.free(z);
        try roundTrip(gpa, z, in, dict, large or options.window_bits > 24);
        var whole = Compressor.init(gpa, options);
        const out = try gpa.alloc(u8, Compressor.bound(in.len));
        defer gpa.free(out);
        const n = try whole.compress(in, out);
        try roundTrip(gpa, out[0..n], in, dict, large or options.window_bits > 24);
    }
};

test "brotli encode fuzz: any input, options, dictionary, flushes and metadata decode to the input" {
    try shakedown.check(testing.allocator, {}, Case.run, .{ .cases = 300 });
}

test "the whole-buffer encoder refuses an output too small for its stream, and stores what does not compress" {
    const gpa = testing.allocator;
    const in = try input(gpa, "noise 3 5000");
    defer gpa.free(in);
    var c = Compressor.init(gpa, .{ .quality = 5 });
    defer c.deinit();
    const out = try gpa.alloc(u8, Compressor.bound(in.len));
    defer gpa.free(out);
    try testing.expectError(error.OutputTooSmall, c.compress(in, out[0..100]));
    try testing.expectError(error.OutputTooSmall, c.compress(in, out[0..0]));
    const n = try c.compress(in, out);
    try testing.expect(n <= Compressor.bound(in.len));
    try roundTrip(gpa, out[0..n], in, &.{}, false);
}

test "streaming refuses input after the end and metadata over 16 MiB or interrupted" {
    const gpa = testing.allocator;
    var s = try Compress.init(gpa, .{ .quality = 2 });
    defer s.deinit();
    var buf: [256]u8 = undefined;
    const big = try gpa.alloc(u8, (1 << 24) + 1);
    defer gpa.free(big);
    try testing.expectError(error.MetadataTooLong, s.metadata(big, &buf));
    // A metadata block that has not ended takes no other input.
    var small: [1]u8 = undefined;
    const meta = [_]u8{ 1, 2, 3, 4, 5 };
    const r = try s.metadata(&meta, small[0..0]);
    if (!r.done) try testing.expectError(error.MetadataPending, s.write("x", &buf));
    var at = r.in_len;
    while (true) {
        const m = try s.metadata(meta[at..], &buf);
        at += m.in_len;
        if (m.done) break;
    }
    _ = try s.write("hello", &buf);
    while (!(try s.finish(&buf)).done) {}
    try testing.expectError(error.Finished, s.write("x", &buf));
    try testing.expectError(error.Finished, s.flush(&buf));
}

test "the writer adapter writes what streaming writes" {
    const gpa = testing.allocator;
    const in = try input(gpa, "text 4 50000");
    defer gpa.free(in);
    var s = try Compress.init(gpa, .{ .quality = 6 });
    defer s.deinit();
    var sink: std.Io.Writer.Allocating = .init(gpa);
    defer sink.deinit();
    var staging: [300]u8 = undefined;
    var w: Compress.Writer = .init(&s, &sink.writer, &staging);
    // As `stream` with a flush every 20000 bytes: after each piece.
    for ([_]usize{ 0, 20000, 40000 }) |at| {
        try w.interface.writeAll(in[at..@min(at + 20000, in.len)]);
        try w.interface.flush();
    }
    try w.finish();
    var direct = try Compress.init(gpa, .{ .quality = 6 });
    defer direct.deinit();
    const want = try stream(gpa, &direct, in, .{ .options = .{ .quality = 6 }, .size_hint = false, .flush_every = 20000, .metadata = 0 }, 4096);
    defer gpa.free(want);
    try testing.expectEqualSlices(u8, want, sink.written());
}

test "a prefix dictionary past the format's reach is refused" {
    const long = try testing.allocator.alloc(u8, Prepared.max_len + 1);
    defer testing.allocator.free(long);
    try testing.expectError(error.DictionaryTooLong, Prepared.init(testing.allocator, long));
}

test "the encoders release everything on allocation failure" {
    const in = try input(testing.allocator, "text 6 3000");
    defer testing.allocator.free(in);
    for ([_]u4{ 0, 1, 2, 4, 5, 9, 10, 11 }) |q| {
        try testing.checkAllAllocationFailures(testing.allocator, struct {
            fn once(gpa: std.mem.Allocator, data: []const u8, quality: u4) !void {
                var prep: Prepared = try .init(gpa, data[0..1000]);
                defer prep.deinit(gpa);
                var c = Compressor.init(gpa, .{ .quality = quality, .dictionary = &prep });
                var out: [4096]u8 = undefined;
                _ = try c.compress(data, &out);
                var s = try Compress.init(gpa, .{ .quality = quality, .window_bits = 16 });
                defer s.deinit();
                _ = try s.write(data, &out);
                _ = try s.finish(&out);
            }
        }.once, .{ in, q });
    }
}
