//! Two slices that lie end to end in one buffer, joined into one: an lz4 stream's previous
//! block and the input that follows it, and a decoder's window and stage. No checked slice
//! spans both, so the join is made here from their pointers, and only once `b` is known to
//! start where `a` ends.

const std = @import("std");

/// `a` and `b` as one slice when `b` starts where `a` ends in memory, else null.
pub fn joined(a: anytype, b: @TypeOf(a)) ?@TypeOf(a) {
    if (a.ptr + a.len != b.ptr) return null;
    return a.ptr[0 .. a.len + b.len];
}

test "two halves of one buffer join, and slices apart do not" {
    var buffer: [8]u8 = "abcdefgh".*;
    const whole: []u8 = &buffer;
    const front: []u8 = whole[0..3];
    const back: []u8 = whole[3..];
    const empty: []u8 = whole[3..3];
    const apart: []u8 = whole[4..];
    try std.testing.expectEqualStrings("abcdefgh", joined(front, back).?);
    try std.testing.expectEqualStrings("abc", joined(front, empty).?);
    try std.testing.expect(joined(front, apart) == null);
    try std.testing.expect(joined(back, front) == null);
}
