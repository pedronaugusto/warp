//! xz's filters read through `xz.FilterReader`: any filter (Delta at any
//! distance, any branch converter from any aligned start) over any bytes,
//! code-like or not, encoded first or not, given in pieces of any size and
//! read out in pieces of any size, reads as the converter run over the
//! whole buffer at once, and an encoded buffer reads back as the original.

const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const xz = @import("../xz.zig");
const filter_ = @import("../xz/filter.zig");

fn anyFilter(s: anytype) xz.Filter {
    if (shakedown.gen.intRange(s, u8, 0, 3) == 0) return .{ .delta = shakedown.gen.intRange(s, u16, 1, 256) };
    const kinds = [_]xz.Bcj{ .x86, .powerpc, .ia64, .arm, .armthumb, .sparc, .arm64, .riscv };
    const kind = kinds[shakedown.gen.intRange(s, usize, 0, kinds.len - 1)];
    const start = shakedown.gen.int(s, u32) & ~(kind.alignment() - 1);
    return .{ .bcj = .{ .kind = kind, .start = if (shakedown.gen.boolean(s)) 0 else start } };
}

fn bytes(case: *shakedown.Case) ![]u8 {
    const s = case.source;
    const out = try case.gpa.alloc(u8, shakedown.gen.intRange(s, usize, 0, 6000));
    // Code-like: the opcodes the converters look for, often; or any bytes.
    const code = shakedown.gen.boolean(s);
    for (out) |*b| b.* = if (code and shakedown.gen.intRange(s, u8, 0, 3) == 0)
        ([_]u8{ 0xe8, 0xe9, 0x0f, 0x94, 0xeb, 0x48, 0x40, 0xf0, 0x97, 0x6f, 0x17 })[shakedown.gen.intRange(s, usize, 0, 10)]
    else
        shakedown.gen.int(s, u8);
    return out;
}

/// `filter` decoded through a reader over `encoded`, given `step` bytes at
/// a time and read `piece` at a time.
fn readThrough(gpa: std.mem.Allocator, encoded: []const u8, filter: xz.Filter, step: usize, piece: usize) ![]u8 {
    var source: std.Io.Reader = .fixed(encoded);
    var small: [97]u8 = undefined;
    var pieces = source.limited(.unlimited, small[0..step]);
    var buffer: [131]u8 = undefined;
    var r: xz.FilterReader = .init(&pieces.interface, &buffer, filter);
    const out = try gpa.alloc(u8, encoded.len);
    errdefer gpa.free(out);
    var done: usize = 0;
    while (true) {
        const room = out[done..][0..@min(piece, out.len - done)];
        const n = try r.interface.readSliceShort(room);
        done += n;
        if (n < room.len or done == out.len) break;
    }
    // Nothing past the input.
    var extra: [1]u8 = undefined;
    try testing.expectEqual(@as(usize, 0), try r.interface.readSliceShort(&extra));
    try testing.expectEqual(encoded.len, done);
    return out;
}

fn readsAsWhole(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const filter = anyFilter(s);
    const plain = try bytes(case);
    const step = shakedown.gen.intRange(s, usize, 1, 97);
    const piece = shakedown.gen.intRange(s, usize, 1, 300);
    const encode = shakedown.gen.boolean(s);
    case.note("{any}, {d} bytes, encoded {}, in {d} out {d}", .{ filter, plain.len, encode, step, piece });
    const in = try case.gpa.dupe(u8, plain);
    if (encode) {
        var state: filter_.State = .init(filter);
        _ = filter_.run(filter, &state, in, true);
    }
    const whole = try case.gpa.dupe(u8, in);
    var state: filter_.State = .init(filter);
    _ = filter_.run(filter, &state, whole, false);
    const got = try readThrough(case.gpa, in, filter, step, piece);
    try testing.expectEqualSlices(u8, whole, got);
    if (encode) try testing.expectEqualSlices(u8, plain, got);
}

test "fuzz: a filter read through xz.FilterReader in any pieces is the converter over the whole" {
    try shakedown.check(testing.allocator, {}, readsAsWhole, .{ .cases = 3000, .seed = 0x7f17 });
}
