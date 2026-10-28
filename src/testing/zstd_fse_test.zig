//! zstd's table descriptions read on their own: FSE counts and Huffman
//! weights, as the frame decoder meets them, but with the description at
//! the very end of its input. The frame-level targets rarely put one there:
//! a block's description is followed by its other sections, and the short
//! path pads a description under eight bytes. So arbitrary short inputs,
//! runs of one bits (the zero-count repeat codes), and the encoder's own
//! descriptions cut, flipped and ended early are read here, each read
//! either refused or giving counts that fill the table exactly.

const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const fse = @import("../zstd/fse.zig");
const huffman = @import("../zstd/huffman.zig");

fn description(case: *shakedown.Case) ![]u8 {
    const s = case.source;
    switch (shakedown.gen.intRange(s, u8, 0, 2)) {
        // Any bytes, mostly short.
        0 => return shakedown.gen.string(s, case.gpa, .{ .kind = .bytes, .max_len = 40, .average = 10 }),
        // Runs of one bits: repeat codes, each run of twelve a reload.
        1 => {
            const in = try case.gpa.alloc(u8, shakedown.gen.intRange(s, usize, 1, 24));
            for (in) |*b| b.* = if (shakedown.gen.intRange(s, u8, 0, 3) == 0) shakedown.gen.int(s, u8) else 0xff;
            in[0] = shakedown.gen.int(s, u8);
            return in;
        },
        // The encoder's own description, with what follows it cut away and
        // a few bits changed.
        else => {
            const max_log = shakedown.gen.intRange(s, u4, 5, 9);
            const symbols = shakedown.gen.intRange(s, usize, 2, 53);
            var counts: [64]u32 = undefined;
            var total: usize = 0;
            for (counts[0..symbols]) |*c| {
                c.* = if (shakedown.gen.boolean(s)) 0 else shakedown.gen.intRange(s, u32, 1, 1000);
                total += c.*;
            }
            counts[0] += 2;
            counts[symbols - 1] += 1;
            total += 3;
            // The log the encoder would choose for these counts.
            const log = fse.optimalLog(max_log, total, @intCast(symbols - 1), 2);
            var norm: [64]i16 = undefined;
            fse.normalize(norm[0..symbols], log, counts[0..symbols], total, true) catch return case.gpa.dupe(u8, &.{0});
            const out = try case.gpa.alloc(u8, fse.countsBound(@intCast(symbols - 1), log));
            var n = fse.writeCounts(out, norm[0..symbols], log);
            if (shakedown.gen.boolean(s)) n = shakedown.gen.intRange(s, usize, 0, n);
            for (0..shakedown.gen.intRange(s, usize, 0, 2)) |_| {
                if (n > 0) out[shakedown.gen.intRange(s, usize, 0, n - 1)] ^= @as(u8, 1) << shakedown.gen.intRange(s, u3, 0, 7);
            }
            return out[0..n];
        },
    }
}

fn readsWhole(_: void, case: *shakedown.Case) !void {
    const in = try description(case);
    const max_symbol = shakedown.gen.int(case.source, u8);
    case.note("{d} bytes, max symbol {d}", .{ in.len, max_symbol });
    if (fse.readCounts(max_symbol, in)) |counts| {
        try testing.expect(counts.len <= in.len);
        try testing.expect(counts.max_symbol <= max_symbol);
        var sum: u32 = 0;
        for (counts.norm[0 .. @as(usize, counts.max_symbol) + 1]) |n| sum += if (n == -1) 1 else @intCast(n);
        try testing.expectEqual(@as(u32, 1) << counts.log, sum);
    } else |_| {}
    _ = huffman.readWeights({}, in) catch return;
}

test "fuzz: FSE and Huffman descriptions ending their input are refused or fill their tables" {
    try shakedown.check(testing.allocator, {}, readsWhole, .{ .cases = 4000, .seed = 0xf5e0 });
}
