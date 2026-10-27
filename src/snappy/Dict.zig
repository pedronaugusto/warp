//! An S2 dictionary: content that the blocks it encodes may copy from as
//! if it came before them, and a repeat value, the offset an initial repeat
//! copies from. Serialized as S2 writes it: the repeat value's uvarint,
//! then the content (16 bytes to 64 KiB). Copies may reach into it while
//! the output is within its first 64 KiB, and not run from it into the
//! output.
//!
//! A `Dict` borrows its content.

const Dict = @This();

const std = @import("std");

/// The shortest and longest content.
pub const min_len = 16;
pub const max_len = 1 << 16;
/// Output past this many bytes may not copy from the dictionary.
pub const max_reach = 65535;

content: []const u8,
/// Where in the content an initial repeat starts (at most `content.len`).
repeat: u32,

pub const Error = error{
    /// Not a dictionary as S2 serializes one: a bad uvarint, content
    /// shorter than 16 bytes or longer than 64 KiB, or a repeat value
    /// past it.
    InvalidDictionary,
};

/// The dictionary `bytes` serialize, as S2's `NewDict` reads it.
pub fn parse(bytes: []const u8) Error!Dict {
    var repeat: u64 = 0;
    const n = uvarint(bytes, &repeat) orelse return error.InvalidDictionary;
    const content = bytes[n..];
    if (content.len < min_len or content.len > max_len or repeat > content.len) return error.InvalidDictionary;
    return .{ .content = content, .repeat = @intCast(repeat) };
}

/// A dictionary of `data`'s last 64 KiB, its repeat value at the last
/// place that holds the longest prefix of `search` (more than 4 bytes) and
/// is 8 or more bytes before the end, else 0: S2's `MakeDict`. Null when
/// `data` is shorter than 16 bytes.
pub fn make(data: []const u8, search: []const u8) ?Dict {
    const content = data[data.len - @min(data.len, max_len) ..];
    if (content.len < min_len) return null;
    var s = search.len;
    while (s > 4) : (s -= 1) {
        if (std.mem.findLast(u8, content, search[0..s])) |at| if (at <= content.len - 8) {
            return .{ .content = content, .repeat = @intCast(at) };
        };
    }
    return .{ .content = content, .repeat = 0 };
}

/// The serialized length: the repeat value's uvarint and the content.
pub fn serializedLen(d: Dict) usize {
    return uvarintLen(d.repeat) + d.content.len;
}

/// Serialize into `out` (`serializedLen` bytes); the bytes written.
pub fn serialize(d: Dict, out: []u8) usize {
    var n: usize = 0;
    var v = d.repeat;
    while (v >= 0x80) : (v >>= 7) {
        out[n] = @as(u8, @truncate(v)) | 0x80;
        n += 1;
    }
    out[n] = @intCast(v);
    n += 1;
    @memcpy(out[n..][0..d.content.len], d.content);
    return n + d.content.len;
}

fn uvarintLen(v: u64) usize {
    var n: usize = 1;
    var x = v;
    while (x >= 0x80) : (x >>= 7) n += 1;
    return n;
}

/// A Go `binary.Uvarint`: up to ten bytes, the tenth at most 1; the bytes
/// read, or null.
pub fn uvarint(bytes: []const u8, v: *u64) ?usize {
    var x: u64 = 0;
    for (bytes, 0..) |b, i| {
        if (i == 10) return null;
        if (i == 9 and b > 1) return null;
        x |= @as(u64, b & 0x7f) << @intCast(7 * i);
        if (b < 0x80) {
            v.* = x;
            return i + 1;
        }
    }
    return null;
}

test "a dictionary serializes as S2's: the repeat value, then the content" {
    const content = "0123456789abcdefghij";
    var buf: [32]u8 = undefined;
    const d: Dict = .{ .content = content, .repeat = 300 % 21 };
    const n = d.serialize(&buf);
    const back = try parse(buf[0..n]);
    try std.testing.expectEqualStrings(content, back.content);
    try std.testing.expectEqual(d.repeat, back.repeat);
    try std.testing.expectError(error.InvalidDictionary, parse("\x00short"));
    try std.testing.expectError(error.InvalidDictionary, parse("\x30" ++ content));
}

test "make: the repeat value at the last place of the search's longest prefix" {
    const data = "xxabcdefyyyyyyabcdezzzzzzzzzzzz";
    const d = make(data, "abcdefg").?;
    try std.testing.expectEqual(@as(u32, 2), d.repeat);
    const e = make(data, "abcdeq").?;
    try std.testing.expectEqual(@as(u32, 14), e.repeat);
    try std.testing.expect(make("short", "s") == null);
}
