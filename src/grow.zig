//! A list whose length its input sets (an xz index's records, a DEFLATE index's points), bounded
//! by the most its format can name: an `aegis.bounded.Buffer`, which grows only when asked, grown
//! here by half again at a time up to that most.
const std = @import("std");
const aegis = @import("aegis");

/// Room in `list` for `n` more items: its storage grown by half again (at least `min_grow`) and
/// to at most `maximum`, the list's own; `LimitExceeded` when `n` more would pass it.
pub fn room(comptime T: type, list: *aegis.bounded.Buffer(T), maximum: usize, n: usize) error{ OutOfMemory, LimitExceeded }!void {
    if (n > maximum - @min(maximum, list.len())) return error.LimitExceeded;
    const wanted = list.len() + n;
    if (wanted <= list.capacity()) return;
    const grown = @min(maximum, @max(wanted, list.capacity() +| @max(list.capacity() / 2, min_grow)));
    list.reserve(grown) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.CapacityExceeded, error.CallerBacked => aegis.assert.never("an allocated list grows within the maximum it was made with"),
    };
}

/// The fewest items a list grows by.
const min_grow = 16;

/// `bytes` on the end of `list`, with room for them made first.
pub fn appendBytes(list: *aegis.bounded.Buffer(u8), maximum: usize, bytes: []const u8) error{ OutOfMemory, LimitExceeded }!void {
    try room(u8, list, maximum, bytes.len);
    for (bytes) |b| {
        var byte = b;
        list.append(&byte) catch aegis.assert.never("room was made for every byte");
    }
}

/// An item's cleanup when it holds nothing to release.
pub fn keep(comptime T: type) fn (*T) void {
    return struct {
        fn f(_: *T) void {}
    }.f;
}

test "a list grows to its maximum and no further" {
    var list: aegis.bounded.Buffer(u8) = try .initAllocated(std.testing.allocator, 0, 40);
    defer list.deinit(keep(u8));
    try appendBytes(&list, 40, &@as([39]u8, @splat(7)));
    try appendBytes(&list, 40, &.{8});
    try std.testing.expectEqual(40, list.len());
    try std.testing.expectError(error.LimitExceeded, appendBytes(&list, 40, &.{9}));
    try std.testing.expectEqual(40, list.len());
    try std.testing.expectEqual(8, list.items()[39]);
}
