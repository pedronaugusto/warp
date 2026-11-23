//! The join of two end-to-end slices (src/adjacent.zig, a P007 seam): any split of one buffer
//! joins back to that buffer, the same bytes at the same address, and a back that does not start
//! where the front ends (a gap, an overlap, the halves swapped) does not join.

const std = @import("std");
const testing = std.testing;
const shakedown = @import("shakedown");
const adjacent = @import("../adjacent.zig");

fn splits(_: void, case: *shakedown.Case) !void {
    const s = case.source;
    const whole: []const u8 = try shakedown.gen.string(s, case.gpa, .{ .kind = .bytes, .max_len = 300 });
    const cut = shakedown.gen.intRange(s, usize, 0, whole.len);
    const other = shakedown.gen.intRange(s, usize, 0, whole.len);
    case.note("{d} bytes, cut at {d}, another back at {d}", .{ whole.len, cut, other });
    const front = whole[0..cut];
    const joined = adjacent.joined(front, whole[cut..]) orelse return error.SplitDidNotJoin;
    try testing.expect(joined.ptr == whole.ptr);
    try testing.expectEqualSlices(u8, whole, joined);
    if (other != cut) try testing.expect(adjacent.joined(front, whole[other..]) == null);
    if (cut > 0) try testing.expect(adjacent.joined(whole[cut..], front) == null);
}

test "fuzz: any split of one buffer joins back to it, and no other pair joins" {
    try shakedown.check(testing.allocator, {}, splits, .{ .cases = 2000 });
}
