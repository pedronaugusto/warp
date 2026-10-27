//! Snappy and S2 against google/snappy 1.3.1 and klauspost/compress s2
//! v1.20.3 (testdata/snappy-*.corpus, captured in trials warp/snappy):
//! every block they wrote decodes to its input, and every mutated and
//! constructed block gets each reference's verdict, google's for the
//! Snappy format and S2's for its own.

const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const gen = @import("gen");
const corpus = @import("corpus.zig");
const snappy = @import("../snappy.zig");

const blocks = @embedFile("snappy-blocks.corpus");
const invalid = @embedFile("snappy-invalid.corpus");

/// A dictionary the corpus names: "repeat <n> <spec>", the content the
/// spec's input, its last 64 KiB. The content is owned by the caller.
fn dictionary(gpa: std.mem.Allocator, name: []const u8, content: *[]u8) !?snappy.Dict {
    if (name.len == 0) return null;
    var it = std.mem.splitScalar(u8, name, ' ');
    if (!std.mem.eql(u8, it.next().?, "repeat")) return error.BadCorpus;
    const repeat = try std.fmt.parseInt(u32, it.next().?, 10);
    content.* = try corpus.input(gpa, it.rest());
    return .{ .content = content.*[content.len - @min(content.len, snappy.Dict.max_len) ..], .repeat = repeat };
}

/// The parser a record names, or null for one not built yet.
fn parserOf(producer: []const u8, params: []const u8) ?snappy.Compressor.Options {
    if (std.mem.startsWith(u8, producer, "snappy ")) return .{ .format = .snappy, .level = if (std.mem.eql(u8, params, "level 1")) .snappy_1 else .snappy_2 };
    const snappy_format = std.mem.startsWith(u8, params, "snappy ");
    var mode = if (snappy_format) params["snappy ".len..] else params;
    if (std.mem.endsWith(u8, mode, " dict")) mode = mode[0 .. mode.len - " dict".len];
    const lvl: snappy.Compressor.Level = if (std.mem.eql(u8, mode, "fast")) .fast else if (std.mem.eql(u8, mode, "better")) .better else if (std.mem.eql(u8, mode, "best")) .best else return null;
    return .{ .format = if (snappy_format) .snappy else .s2, .level = lvl };
}

/// A block as the corpus stores it: its bytes, or "sha256 <hex> <len>".
fn sameBlock(stored: []const u8, got: []const u8) !void {
    if (!std.mem.startsWith(u8, stored, "sha256 ")) return testing.expectEqualSlices(u8, stored, got);
    var it = std.mem.splitScalar(u8, stored, ' ');
    _ = it.next();
    var want: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want, it.next().?);
    const len = try std.fmt.parseInt(usize, it.next().?, 10);
    try testing.expectEqual(len, got.len);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(got, &digest, .{});
    try testing.expectEqualSlices(u8, &want, &digest);
}

test "warp writes google's and S2's blocks byte for byte" {
    const gpa = testing.allocator;
    const parsed = try corpus.Corpus.parse(blocks);
    var it = parsed.records();
    var count: usize = 0;
    while (it.next()) |r| {
        var options = parserOf(r.fields[0], r.fields[1]) orelse continue;
        errdefer std.debug.print("{s} {s}: {s}\n", .{ r.fields[0], r.fields[1], r.fields[2] });
        const in = try corpus.input(gpa, r.fields[2]);
        defer gpa.free(in);
        var content: []u8 = &.{};
        defer gpa.free(content);
        options.dictionary = try dictionary(gpa, r.fields[3], &content);
        var c: snappy.Compressor = try .init(gpa, options);
        defer c.deinit();
        const out = try gpa.alloc(u8, snappy.blockBound(in.len));
        defer gpa.free(out);
        const n = try c.compressBlock(in, out);
        try sameBlock(r.fields[4], out[0..n]);
        count += 1;
    }
    // google's and S2's six, on each input, and S2's three with each
    // dictionary on each of its inputs.
    try testing.expect(count >= 1360 + 6 * 8 * 3);
}

test "every block google and S2 wrote decodes to its input" {
    const gpa = testing.allocator;
    const parsed = try corpus.Corpus.parse(blocks);
    var it = parsed.records();
    var count: usize = 0;
    while (it.next()) |r| {
        const params = r.fields[1];
        if (std.mem.eql(u8, params, "makedict") or std.mem.eql(u8, params, "concat")) continue;
        const stored = r.fields[4];
        if (std.mem.startsWith(u8, stored, "sha256 ")) continue;
        errdefer std.debug.print("{s} {s}: {s}\n", .{ r.fields[0], params, r.fields[2] });
        const in = try corpus.input(gpa, r.fields[2]);
        defer gpa.free(in);
        var content: []u8 = &.{};
        defer gpa.free(content);
        const dict = try dictionary(gpa, r.fields[3], &content);
        const out = try gpa.alloc(u8, in.len);
        defer gpa.free(out);
        // google's blocks and S2's Snappy ones are both formats; S2's own
        // only S2.
        const snappy_too = dict == null and (std.mem.startsWith(u8, r.fields[0], "snappy") or std.mem.startsWith(u8, params, "snappy "));
        for ([_]snappy.Format{ .s2, .snappy }) |format| {
            if (format == .snappy and !snappy_too) continue;
            const n = try snappy.decompressBlock(stored, out, .{ .format = format, .dictionary = dict });
            try testing.expectEqualSlices(u8, in, out[0..n]);
            count += 1;
        }
    }
    try testing.expect(count > 1000);
}

test "mutated and constructed blocks get google's verdict as Snappy and S2's as S2" {
    const gpa = testing.allocator;
    const parsed = try corpus.Corpus.parse(invalid);
    var it = parsed.records();
    var count: usize = 0;
    while (it.next()) |r| : (count += 1) {
        errdefer std.debug.print("{s} ({s}): {s}\n", .{ r.fields[0], r.fields[1], r.fields[4] });
        const format = std.meta.stringToEnum(snappy.Format, r.fields[1]).?;
        var content: []u8 = &.{};
        defer gpa.free(content);
        const dict = try dictionary(gpa, r.fields[2], &content);
        const stored = r.fields[3];
        const verdict = r.fields[4];
        const len = snappy.decodedLen(stored) catch 0;
        const out = try gpa.alloc(u8, len);
        defer gpa.free(out);
        const ours = snappy.decompressBlock(stored, out, .{ .format = format, .dictionary = dict });
        if (std.mem.startsWith(u8, verdict, "ok ")) {
            var fields = std.mem.tokenizeScalar(u8, verdict[3..], ' ');
            const want_len = try std.fmt.parseInt(usize, fields.next().?, 10);
            const crc = try std.fmt.parseInt(u32, fields.next().?, 10);
            const n = try ours;
            try testing.expectEqual(want_len, n);
            try testing.expectEqual(crc, std.hash.Crc32.hash(out[0..n]));
        } else if (ours) |_| return error.AcceptedWhatTheReferenceRefused else |_| {}
    }
    try testing.expect(count > 1500);
}

test "S2's MakeDict: the repeat value warp's Dict.make finds" {
    const gpa = testing.allocator;
    const parsed = try corpus.Corpus.parse(blocks);
    var it = parsed.records();
    var count: usize = 0;
    while (it.next()) |r| {
        if (!std.mem.eql(u8, r.fields[1], "makedict")) continue;
        const data = try corpus.input(gpa, r.fields[2]);
        defer gpa.free(data);
        const search = try corpus.input(gpa, r.fields[3]);
        defer gpa.free(search);
        const made = snappy.Dict.make(data, search);
        if (r.fields[4].len == 0) {
            try testing.expect(made == null);
        } else {
            var buf: [64]u8 = undefined;
            const name = try std.mem.print(&buf, "repeat {d} {s}", .{ made.?.repeat, r.fields[2] });
            try testing.expectEqualStrings(r.fields[4], name);
            try testing.expectEqualSlices(u8, data[data.len - @min(data.len, snappy.Dict.max_len) ..], made.?.content);
        }
        count += 1;
    }
    try testing.expectEqual(@as(usize, 4), count);
}

test "S2's ConcatBlocks: one block of the parts' blocks, as S2 joins them" {
    const gpa = testing.allocator;
    const parsed = try corpus.Corpus.parse(blocks);
    var it = parsed.records();
    var count: usize = 0;
    while (it.next()) |r| {
        if (!std.mem.eql(u8, r.fields[1], "concat")) continue;
        var buffers: std.ArrayList([]u8) = .empty;
        var parts: std.ArrayList([]const u8) = .empty;
        defer {
            for (buffers.items) |b| gpa.free(b);
            buffers.deinit(gpa);
            parts.deinit(gpa);
        }
        var c: snappy.Compressor = try .init(gpa, .{ .format = .s2, .level = .fast });
        defer c.deinit();
        var specs = std.mem.splitSequence(u8, r.fields[2], " | ");
        while (specs.next()) |spec| {
            const in = try corpus.input(gpa, spec);
            defer gpa.free(in);
            const out = try gpa.alloc(u8, snappy.blockBound(in.len));
            try buffers.append(gpa, out);
            const n = try c.compressBlock(in, out);
            try parts.append(gpa, out[0..n]);
        }
        const joined = try gpa.alloc(u8, try snappy.concatBound(parts.items));
        defer gpa.free(joined);
        const n = try snappy.concatBlocks(parts.items, joined);
        try testing.expectEqualSlices(u8, r.fields[4], joined[0..n]);
        count += 1;
    }
    try testing.expectEqual(@as(usize, 3), count);
}

/// A plain decoder, element by element, as the formats say: the decoded
/// length, or null for a block it refuses.
fn plainDecode(in: []const u8, out: []u8, format: snappy.Format, dict: ?snappy.Dict) ?usize {
    const h_len = snappy.decodedLen(in) catch return null;
    if (h_len > out.len) return null;
    var ip: usize = 0;
    while (in[ip] >= 0x80) ip += 1;
    ip += 1;
    const content: []const u8 = if (dict) |d| d.content else &.{};
    var last: usize = if (dict) |d| d.content.len - d.repeat else 0;
    var op: usize = 0;
    while (ip < in.len) {
        const tag = in[ip];
        var len: u64 = undefined;
        var offset: u64 = undefined;
        switch (tag & 3) {
            0 => {
                len = tag >> 2;
                ip += 1;
                if (len >= 60) {
                    const n: usize = @intCast(len - 59);
                    if (in.len - ip < n) return null;
                    len = 0;
                    for (0..n) |i| len |= @as(u64, in[ip + i]) << @intCast(8 * i);
                    ip += n;
                }
                len += 1;
                if (len > in.len - ip or len > h_len - op) return null;
                for (0..@intCast(len)) |i| out[op + i] = in[ip + i];
                ip += @intCast(len);
                op += @intCast(len);
                continue;
            },
            1 => {
                if (in.len - ip < 2) return null;
                len = ((tag >> 2) & 7) + 4;
                offset = @as(u64, tag >> 5) << 8 | in[ip + 1];
                ip += 2;
                if (offset == 0) {
                    if (format == .snappy) return null;
                    const code = (tag >> 2) & 7;
                    const extra: usize = if (code < 5) 0 else code - 4;
                    if (in.len - ip < extra) return null;
                    var v: u64 = 0;
                    for (0..extra) |i| v |= @as(u64, in[ip + i]) << @intCast(8 * i);
                    ip += extra;
                    len = switch (code) {
                        5 => v + 8,
                        6 => v + 260,
                        7 => v + 65540,
                        else => len,
                    };
                    if (last == 0) return null;
                    offset = last;
                }
            },
            2 => {
                if (in.len - ip < 3) return null;
                len = (tag >> 2) + 1;
                offset = std.mem.readInt(u16, in[ip + 1 ..][0..2], .little);
                ip += 3;
                if (offset == 0) return null;
            },
            else => {
                if (in.len - ip < 5) return null;
                len = (tag >> 2) + 1;
                offset = std.mem.readInt(u32, in[ip + 1 ..][0..4], .little);
                ip += 5;
                if (offset == 0) return null;
            },
        }
        last = @intCast(offset);
        if (len > h_len - op) return null;
        for (0..@intCast(len)) |i| {
            if (offset <= op + i) {
                out[op + i] = out[op + i - @as(usize, @intCast(offset))];
            } else {
                // From the dictionary: the whole copy, starting in its
                // first 64 KiB of output, not running out of it.
                if (i != 0 or op > snappy.Dict.max_reach or offset - op > content.len or len > offset - op) return null;
                out[op + i] = content[content.len - @as(usize, @intCast(offset - op))];
                for (1..@intCast(len)) |j| out[op + j] = content[content.len - @as(usize, @intCast(offset - op)) + j];
                break;
            }
        }
        op += @intCast(len);
    }
    return if (op == h_len) op else null;
}

/// Arbitrary bytes and mutated real blocks: the decoder answers as the
/// plain one, in both formats, with and without a dictionary.
fn blocksAgree(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    var input: []u8 = undefined;
    const content = try gen.alloc(case.gpa, .text, 7, 3000);
    const with_dict = shakedown.gen.boolean(s);
    const dict: ?snappy.Dict = if (with_dict) .{ .content = content, .repeat = shakedown.gen.intRange(s, u32, 0, 3000) } else null;
    if (shakedown.gen.boolean(s)) {
        input = try shakedown.gen.string(s, case.gpa, .{ .kind = .bytes, .max_len = 400, .average = 40 });
        if (input.len > 0) input[0] &= 0x7f;
    } else {
        const plain = try gen.alloc(case.gpa, shakedown.gen.enumValue(s, gen.Kind), shakedown.gen.int(s, u16), shakedown.gen.intRange(s, usize, 0, 20_000));
        const level = shakedown.gen.enumValue(s, snappy.Compressor.Level);
        const s2_parser = level != .snappy_1 and level != .snappy_2;
        var c: snappy.Compressor = try .init(case.gpa, .{ .format = if (s2_parser and shakedown.gen.boolean(s)) .s2 else .snappy, .level = level });
        defer c.deinit();
        const out = try case.gpa.alloc(u8, snappy.blockBound(plain.len));
        input = out[0..try c.compressBlock(plain, out)];
        for (0..shakedown.gen.intRange(s, usize, 0, 3)) |_| {
            if (input.len > 2) input[shakedown.gen.intRange(s, usize, 2, input.len - 1)] ^= @as(u8, 1) << shakedown.gen.intRange(s, u3, 0, 7);
        }
        if (shakedown.gen.boolean(s)) input = input[0..shakedown.gen.intRange(s, usize, 0, input.len)];
    }
    case.note("{d} bytes, dictionary {}", .{ input.len, with_dict });
    const out = try case.gpa.alloc(u8, 1 << 17);
    const plain_out = try case.gpa.alloc(u8, 1 << 17);
    for ([_]snappy.Format{ .snappy, .s2 }) |format| {
        if (format == .snappy and with_dict) continue;
        const len = snappy.decodedLen(input) catch null;
        const ours = snappy.decompressBlock(input, out, .{ .format = format, .dictionary = dict });
        const want = plainDecode(input, plain_out, format, dict);
        if (want) |n| {
            try testing.expectEqual(n, len.?);
            try testing.expectEqualSlices(u8, plain_out[0..n], out[0..try ours]);
        } else if (ours) |_| {
            return error.DecodedWhatThePlainDecoderRefused;
        } else |_| {}
    }
}

test "fuzz: any bytes into the block decoder, both formats and with a dictionary, answer as a plain decoder" {
    try shakedown.check(testing.allocator, {}, blocksAgree, .{ .cases = 3000, .seed = 0x5a0f });
}

/// Any input at any parser and format, with a dictionary where S2's,
/// decodes back to itself.
fn roundTrips(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const plain = try gen.alloc(case.gpa, shakedown.gen.enumValue(s, gen.Kind), shakedown.gen.int(s, u16), shakedown.gen.intRange(s, usize, 0, 70_000));
    const level = shakedown.gen.enumValue(s, snappy.Compressor.Level);
    const s2_parser = level != .snappy_1 and level != .snappy_2;
    const format: snappy.Format = if (s2_parser and shakedown.gen.boolean(s)) .s2 else .snappy;
    const content = try gen.alloc(case.gpa, shakedown.gen.enumValue(s, gen.Kind), shakedown.gen.int(s, u16), shakedown.gen.intRange(s, usize, 16, 65536));
    const dict: ?snappy.Dict = if (format == .s2 and shakedown.gen.boolean(s)) .{ .content = content, .repeat = shakedown.gen.intRange(s, u32, 0, @intCast(content.len)) } else null;
    case.note("{d} bytes, {t} {t}, dictionary {}", .{ plain.len, level, format, dict != null });
    var c: snappy.Compressor = try .init(case.gpa, .{ .format = format, .level = level, .dictionary = dict });
    defer c.deinit();
    const out = try case.gpa.alloc(u8, snappy.blockBound(plain.len));
    const n = try c.compressBlock(plain, out);
    const back = try case.gpa.alloc(u8, plain.len);
    const m = try snappy.decompressBlock(out[0..n], back, .{ .format = format, .dictionary = dict });
    try testing.expectEqualSlices(u8, plain, back[0..m]);
}

test "fuzz: any input at any parser, format and dictionary comes back whole" {
    try shakedown.check(testing.allocator, {}, roundTrips, .{ .cases = 400, .seed = 0x5a1e });
}
