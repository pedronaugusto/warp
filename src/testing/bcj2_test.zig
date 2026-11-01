//! BCJ2 read through `warp.Bcj2`: every set of four streams 7-Zip 26.05
//! writes (testdata/bcj2.corpus) decodes to its input, its streams given
//! in pieces of any size and read out in pieces of any size, with its
//! length known or not; and any four streams read the same in pieces as
//! whole, a length cutting them short giving their start.

const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const Bcj2 = @import("../Bcj2.zig");
const corpus = @import("corpus.zig");

const captured = @embedFile("bcj2.corpus");

const Pieces = struct {
    source: std.Io.Reader,
    small: [97]u8 = undefined,
    limited: std.Io.Reader.Limited = undefined,

    fn init(p: *Pieces, bytes: []const u8, step: usize) *std.Io.Reader {
        p.source = .fixed(bytes);
        p.limited = p.source.limited(.unlimited, p.small[0..step]);
        return &p.limited.interface;
    }
};

/// The four streams decoded, each given `step` bytes at a time and read
/// `piece` at a time; null where the streams are refused.
fn decode(gpa: std.mem.Allocator, streams: [4][]const u8, size: ?u64, step: usize, piece: usize) !?[]u8 {
    var pieces: [4]Pieces = undefined;
    var buffer: [131]u8 = undefined;
    var r: Bcj2 = .init(.{
        .main = pieces[0].init(streams[0], step),
        .call = pieces[1].init(streams[1], step),
        .jump = pieces[2].init(streams[2], step),
        .range = pieces[3].init(streams[3], step),
    }, &buffer, size);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var chunk: [300]u8 = undefined;
    while (true) {
        const n = r.interface.readSliceShort(chunk[0..piece]) catch {
            try testing.expectEqual(@as(?Bcj2.Error, error.Truncated), r.err());
            out.deinit(gpa);
            return null;
        };
        try out.appendSlice(gpa, chunk[0..n]);
        if (n < piece) break;
    }
    return try out.toOwnedSlice(gpa);
}

test "7-Zip's BCJ2 streams decode to their inputs, whole and in pieces" {
    const gpa = testing.allocator;
    const c = try corpus.Corpus.parse(captured);
    var it = c.records();
    var count: usize = 0;
    while (it.next()) |r| : (count += 1) {
        const plain = try corpus.input(gpa, r.fields[2]);
        defer gpa.free(plain);
        const streams: [4][]const u8 = .{ r.fields[3], r.fields[4], r.fields[5], r.fields[6] };
        for ([_]?u64{ null, plain.len }) |size| {
            for ([_][2]usize{ .{ 97, 300 }, .{ 1, 1 }, .{ 3, 7 }, .{ 64, 5 } }) |sizes| {
                const got = (try decode(gpa, streams, size, sizes[0], sizes[1])) orelse return error.Refused;
                defer gpa.free(got);
                testing.expectEqualSlices(u8, plain, got) catch |e| {
                    std.debug.print("record {d} ({s}), size {?d}, in {d} out {d}\n", .{ r.index, r.fields[2], size, sizes[0], sizes[1] });
                    return e;
                };
            }
        }
    }
    try testing.expect(count >= 10);
}

fn anyBytes(case: *shakedown.Case, max: usize, code: bool) ![]u8 {
    const s = case.source;
    const out = try case.gpa.alloc(u8, shakedown.gen.intRange(s, usize, 0, max));
    for (out) |*b| b.* = if (code and shakedown.gen.intRange(s, u8, 0, 2) == 0)
        ([_]u8{ 0xe8, 0xe9, 0x0f, 0x80, 0x85, 0x8f })[shakedown.gen.intRange(s, usize, 0, 5)]
    else
        shakedown.gen.int(s, u8);
    return out;
}

fn readsAsWhole(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const streams: [4][]const u8 = .{
        try anyBytes(case, 3000, shakedown.gen.boolean(s)),
        try anyBytes(case, 400, false),
        try anyBytes(case, 400, false),
        try anyBytes(case, 300, false),
    };
    const step = shakedown.gen.intRange(s, usize, 1, 97);
    const piece = shakedown.gen.intRange(s, usize, 1, 300);
    case.note("streams of {d}, {d}, {d}, {d} bytes; in {d} out {d}", .{ streams[0].len, streams[1].len, streams[2].len, streams[3].len, step, piece });
    const whole = try decode(case.gpa, streams, null, 97, 300);
    const got = try decode(case.gpa, streams, null, step, piece);
    if (whole) |w| {
        try testing.expectEqualSlices(u8, w, got orelse return error.RefusedInPieces);
        // A length cuts the output short: its start, never more.
        const size = shakedown.gen.intRange(s, usize, 0, w.len);
        const cut = (try decode(case.gpa, streams, size, step, piece)) orelse return error.RefusedWhenCut;
        try testing.expectEqualSlices(u8, w[0..size], cut);
    } else try testing.expect(got == null);
}

test "fuzz: any four streams read through warp.Bcj2 in any pieces as they read whole" {
    try shakedown.check(testing.allocator, {}, readsAsWhole, .{ .cases = 3000, .seed = 0xbc72 });
}
