//! One of xz's filters before LZMA2, Delta or a branch converter, decoded
//! as a `std.Io.Reader` over another reader: the converter xz's own
//! decoders run, through the same pipe, so a converter's held-back tail
//! (x86's up to four bytes, the others' part of an instruction) stays
//! here until the input ends. 7z's coders of the same filters read so.

const FilterReader = @This();

const std = @import("std");
const Io = std.Io;
const aegis = @import("aegis");
const filter_ = @import("filter.zig");

interface: Io.Reader,
input: *Io.Reader,
pipe: filter_.Pipe,
/// The input has ended: the converter's tail has gone on as it is.
ended: bool = false,

/// Decode `filter` over what `input` gives; `buffer` is the reader's own
/// buffering.
pub fn init(input: *Io.Reader, buffer: []u8, filter: filter_.Filter) FilterReader {
    var r: FilterReader = .{
        .interface = .{ .vtable = &.{ .stream = stream, .readVec = readVec }, .buffer = buffer, .seek = 0, .end = 0 },
        .input = input,
        .pipe = .{},
    };
    r.pipe.reset(&.{filter});
    return r;
}

fn readInto(r: *FilterReader, out: []u8) Io.Reader.Error!usize {
    while (true) {
        const ready = r.pipe.ready();
        if (ready.len != 0) {
            const n = @min(ready.len, out.len);
            @memcpy(out[0..n], ready[0..n]);
            r.pipe.take(n);
            return n;
        }
        if (r.ended) return error.EndOfStream;
        const in = r.input.peekGreedy(1) catch |failure| {
            if (failure == error.ReadFailed) return failure;
            r.ended = true;
            r.pipe.convert(true);
            continue;
        };
        // A converter holds back less than an instruction, so a pipe with
        // nothing ready has room.
        const room = r.pipe.room();
        aegis.assert.invariant(room.len != 0, "room.len != 0");
        const n = @min(in.len, room.len);
        @memcpy(room[0..n], in[0..n]);
        r.input.toss(n);
        r.pipe.added(n);
        r.pipe.convert(false);
    }
}

fn stream(interface: *Io.Reader, writer: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
    const r: *FilterReader = @alignCast(@fieldParentPtr("interface", interface));
    _ = writer;
    if (limit == .nothing) return 0;
    const n = try r.readInto(limit.slice(interface.buffer));
    interface.seek = 0;
    interface.end = n;
    return 0;
}

fn readVec(interface: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
    const r: *FilterReader = @alignCast(@fieldParentPtr("interface", interface));
    if (data[0].len != 0) return r.readInto(data[0]);
    const n = try r.readInto(interface.buffer[interface.end..]);
    interface.end += n;
    return 0;
}

const testing = std.testing;

/// `filter` decoded over `encoded` given at most `step` bytes at a time,
/// read out `piece` bytes at a time.
fn decodeIn(encoded: []const u8, filter: filter_.Filter, step: usize, piece: usize, out: []u8) !usize {
    var source: Io.Reader = .fixed(encoded);
    var small: [64]u8 = undefined;
    var pieces = source.limited(.unlimited, small[0..step]);
    var buffer: [256]u8 = undefined;
    var r: FilterReader = .init(&pieces.interface, &buffer, filter);
    var done: usize = 0;
    while (done < out.len) {
        const n = try r.interface.readSliceShort(out[done..][0..@min(piece, out.len - done)]);
        if (n == 0) break;
        done += n;
    }
    return done;
}

test "each filter read back through a reader is the converter run on the whole" {
    var prng: std.Random.DefaultPrng = .init(0x7a);
    const random = prng.random();
    var plain: [9000]u8 = undefined;
    // Code-like bytes: runs of call and branch opcodes among random ones.
    for (&plain, 0..) |*b, i| b.* = if (i % 7 == 0) 0xe8 else if (i % 11 == 0) 0x94 else random.int(u8);
    const filters = [_]filter_.Filter{
        .{ .delta = 1 },
        .{ .delta = 7 },
        .{ .delta = 256 },
        .{ .bcj = .{ .kind = .x86, .start = 0 } },
        .{ .bcj = .{ .kind = .x86, .start = 0x1000 } },
        .{ .bcj = .{ .kind = .powerpc, .start = 0 } },
        .{ .bcj = .{ .kind = .ia64, .start = 16 } },
        .{ .bcj = .{ .kind = .arm, .start = 4 } },
        .{ .bcj = .{ .kind = .armthumb, .start = 2 } },
        .{ .bcj = .{ .kind = .sparc, .start = 0 } },
        .{ .bcj = .{ .kind = .arm64, .start = 0 } },
        .{ .bcj = .{ .kind = .riscv, .start = 2 } },
    };
    for (filters) |f| {
        var encoded = plain;
        var es: filter_.State = .init(f);
        _ = filter_.run(f, &es, &encoded, true);
        var want = encoded;
        var ds: filter_.State = .init(f);
        _ = filter_.run(f, &ds, &want, false);
        try testing.expectEqualSlices(u8, &plain, &want);
        for ([_][2]usize{ .{ 64, 4096 }, .{ 1, 1 }, .{ 3, 5 }, .{ 7, 64 }, .{ 64, 1 } }) |sizes| {
            var got: [9000]u8 = undefined;
            try testing.expectEqual(plain.len, try decodeIn(&encoded, f, sizes[0], sizes[1], &got));
            try testing.expectEqualSlices(u8, &want, &got);
        }
    }
}

test "an empty input reads as empty" {
    var out: [4]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), try decodeIn("", .{ .delta = 1 }, 64, 4, &out));
}
