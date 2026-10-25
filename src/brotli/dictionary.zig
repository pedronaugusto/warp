//! RFC 7932's static dictionary (Appendix A) and its 121 word transforms
//! (Appendix B): what a distance past the history names.

const std = @import("std");

/// The dictionary's words, grouped by length and sorted within each group.
pub const data: *const [122784]u8 = @embedFile("dictionary.bin");

pub const min_word = 4;
pub const max_word = 24;

/// Bits of a word's index, by word length: 2^bits words of each length.
pub const size_bits = [max_word + 1]u5{ 0, 0, 0, 0, 10, 10, 11, 11, 10, 10, 10, 10, 10, 9, 9, 8, 7, 7, 8, 7, 7, 6, 6, 5, 5 };

/// Where the words of each length start in `data`.
pub const offsets = blk: {
    var o: [max_word + 1]u32 = @splat(0);
    var at: u32 = 0;
    for (min_word..max_word + 1) |len| {
        o[len] = at;
        at += @as(u32, len) << size_bits[len];
    }
    std.debug.assert(at == data.len);
    break :blk o;
};

pub const Kind = enum(u5) {
    identity,
    omit_last_1,
    omit_last_2,
    omit_last_3,
    omit_last_4,
    omit_last_5,
    omit_last_6,
    omit_last_7,
    omit_last_8,
    omit_last_9,
    uppercase_first,
    uppercase_all,
    omit_first_1,
    omit_first_2,
    omit_first_3,
    omit_first_4,
    omit_first_5,
    omit_first_6,
    omit_first_7,
    omit_first_8,
    omit_first_9,
};

pub const Transform = struct { prefix: []const u8, kind: Kind, suffix: []const u8 };

pub const transforms = blk: {
    const table = .{
        .{ "", .identity, "" },
        .{ "", .identity, " " },
        .{ " ", .identity, " " },
        .{ "", .omit_first_1, "" },
        .{ "", .uppercase_first, " " },
        .{ "", .identity, " the " },
        .{ " ", .identity, "" },
        .{ "s ", .identity, " " },
        .{ "", .identity, " of " },
        .{ "", .uppercase_first, "" },
        .{ "", .identity, " and " },
        .{ "", .omit_first_2, "" },
        .{ "", .omit_last_1, "" },
        .{ ", ", .identity, " " },
        .{ "", .identity, ", " },
        .{ " ", .uppercase_first, " " },
        .{ "", .identity, " in " },
        .{ "", .identity, " to " },
        .{ "e ", .identity, " " },
        .{ "", .identity, "\"" },
        .{ "", .identity, "." },
        .{ "", .identity, "\">" },
        .{ "", .identity, "\n" },
        .{ "", .omit_last_3, "" },
        .{ "", .identity, "]" },
        .{ "", .identity, " for " },
        .{ "", .omit_first_3, "" },
        .{ "", .omit_last_2, "" },
        .{ "", .identity, " a " },
        .{ "", .identity, " that " },
        .{ " ", .uppercase_first, "" },
        .{ "", .identity, ". " },
        .{ ".", .identity, "" },
        .{ " ", .identity, ", " },
        .{ "", .omit_first_4, "" },
        .{ "", .identity, " with " },
        .{ "", .identity, "'" },
        .{ "", .identity, " from " },
        .{ "", .identity, " by " },
        .{ "", .omit_first_5, "" },
        .{ "", .omit_first_6, "" },
        .{ " the ", .identity, "" },
        .{ "", .omit_last_4, "" },
        .{ "", .identity, ". The " },
        .{ "", .uppercase_all, "" },
        .{ "", .identity, " on " },
        .{ "", .identity, " as " },
        .{ "", .identity, " is " },
        .{ "", .omit_last_7, "" },
        .{ "", .omit_last_1, "ing " },
        .{ "", .identity, "\n\t" },
        .{ "", .identity, ":" },
        .{ " ", .identity, ". " },
        .{ "", .identity, "ed " },
        .{ "", .omit_first_9, "" },
        .{ "", .omit_first_7, "" },
        .{ "", .omit_last_6, "" },
        .{ "", .identity, "(" },
        .{ "", .uppercase_first, ", " },
        .{ "", .omit_last_8, "" },
        .{ "", .identity, " at " },
        .{ "", .identity, "ly " },
        .{ " the ", .identity, " of " },
        .{ "", .omit_last_5, "" },
        .{ "", .omit_last_9, "" },
        .{ " ", .uppercase_first, ", " },
        .{ "", .uppercase_first, "\"" },
        .{ ".", .identity, "(" },
        .{ "", .uppercase_all, " " },
        .{ "", .uppercase_first, "\">" },
        .{ "", .identity, "=\"" },
        .{ " ", .identity, "." },
        .{ ".com/", .identity, "" },
        .{ " the ", .identity, " of the " },
        .{ "", .uppercase_first, "'" },
        .{ "", .identity, ". This " },
        .{ "", .identity, "," },
        .{ ".", .identity, " " },
        .{ "", .uppercase_first, "(" },
        .{ "", .uppercase_first, "." },
        .{ "", .identity, " not " },
        .{ " ", .identity, "=\"" },
        .{ "", .identity, "er " },
        .{ " ", .uppercase_all, " " },
        .{ "", .identity, "al " },
        .{ " ", .uppercase_all, "" },
        .{ "", .identity, "='" },
        .{ "", .uppercase_all, "\"" },
        .{ "", .uppercase_first, ". " },
        .{ " ", .identity, "(" },
        .{ "", .identity, "ful " },
        .{ " ", .uppercase_first, ". " },
        .{ "", .identity, "ive " },
        .{ "", .identity, "less " },
        .{ "", .uppercase_all, "'" },
        .{ "", .identity, "est " },
        .{ " ", .uppercase_first, "." },
        .{ "", .uppercase_all, "\">" },
        .{ " ", .identity, "='" },
        .{ "", .uppercase_first, "," },
        .{ "", .identity, "ize " },
        .{ "", .uppercase_all, "." },
        .{ "\xc2\xa0", .identity, "" },
        .{ " ", .identity, "," },
        .{ "", .uppercase_first, "=\"" },
        .{ "", .uppercase_all, "=\"" },
        .{ "", .identity, "ous " },
        .{ "", .uppercase_all, ", " },
        .{ "", .uppercase_first, "='" },
        .{ " ", .uppercase_first, "," },
        .{ " ", .uppercase_all, "=\"" },
        .{ " ", .uppercase_all, ", " },
        .{ "", .uppercase_all, "," },
        .{ "", .uppercase_all, "(" },
        .{ "", .uppercase_all, ". " },
        .{ " ", .uppercase_all, "." },
        .{ "", .uppercase_all, "='" },
        .{ " ", .uppercase_all, ". " },
        .{ " ", .uppercase_first, "=\"" },
        .{ " ", .uppercase_all, "='" },
        .{ " ", .uppercase_first, "='" },
    };
    var t: [table.len]Transform = undefined;
    for (&t, table) |*x, e| x.* = .{ .prefix = e[0], .kind = e[1], .suffix = e[2] };
    break :blk t;
};

/// The longest a transformed word can be.
pub const max_transformed = blk: {
    var longest: usize = 0;
    for (transforms) |t| longest = @max(longest, t.prefix.len + max_word + t.suffix.len);
    break :blk longest;
};

/// The bytes a transform may write: up to 7 past its result.
pub const transform_room = max_transformed + 8;

/// Each transform's affixes padded to 8 bytes, for 8-byte writes.
const Affixes = struct { prefix: [8]u8, prefix_len: u8, suffix: [8]u8, suffix_len: u8 };
const affixes = blk: {
    var a: [transforms.len]Affixes = undefined;
    for (&a, transforms) |*x, t| {
        x.* = .{ .prefix = @splat(0), .prefix_len = t.prefix.len, .suffix = @splat(0), .suffix_len = t.suffix.len };
        @memcpy(x.prefix[0..t.prefix.len], t.prefix);
        @memcpy(x.suffix[0..t.suffix.len], t.suffix);
    }
    break :blk a;
};

/// Write word `word` transformed by transform `index` (< `transforms.len`)
/// at `dst`, which has `transform_room` bytes; return its length. Bytes
/// past it may be written.
pub inline fn transform(dst: [*]u8, word: []const u8, index: usize) usize {
    const t = transforms[index];
    const a = affixes[index];
    dst[0..8].* = a.prefix;
    var n: usize = a.prefix_len;
    const k = @backingInt(t.kind);
    var w = word;
    if (k <= @backingInt(Kind.omit_last_9)) {
        w = w[0..w.len -| k];
    } else if (k >= @backingInt(Kind.omit_first_1)) {
        w = w[@min(w.len, k - @backingInt(Kind.omit_first_1) + 1)..];
    }
    copySmall(dst + n, w);
    switch (t.kind) {
        .uppercase_first => _ = upper(dst[n..][0..w.len]),
        .uppercase_all => {
            var i: usize = 0;
            while (i < w.len) i += upper(dst[n + i ..][0 .. w.len - i]);
        },
        else => {},
    }
    n += w.len;
    dst[n..][0..8].* = a.suffix;
    return n + a.suffix_len;
}

/// Copy up to 24 bytes with two overlapping moves, no byte past `src`
/// read and none past its length written.
inline fn copySmall(dst: [*]u8, src: []const u8) void {
    const n = src.len;
    if (n >= 16) {
        dst[0..16].* = src[0..16].*;
        dst[n - 16 ..][0..16].* = src[n - 16 ..][0..16].*;
    } else if (n >= 8) {
        dst[0..8].* = src[0..8].*;
        dst[n - 8 ..][0..8].* = src[n - 8 ..][0..8].*;
    } else if (n >= 4) {
        dst[0..4].* = src[0..4].*;
        dst[n - 4 ..][0..4].* = src[n - 4 ..][0..4].*;
    } else for (0..n) |i| {
        dst[i] = src[i];
    }
}

/// The RFC's uppercasing of the character at the start of `p`: ASCII
/// letters, the second byte of a two-byte sequence flipped by 32, the third
/// of a three-byte one by 5; bytes past `p` are not changed. Returns the
/// bytes the character takes.
fn upper(p: []u8) usize {
    if (p.len == 0) return 1;
    if (p[0] < 0xc0) {
        if (p[0] >= 'a' and p[0] <= 'z') p[0] ^= 32;
        return 1;
    }
    if (p[0] < 0xe0) {
        if (p.len > 1) p[1] ^= 32;
        return 2;
    }
    if (p.len > 2) p[2] ^= 5;
    return 3;
}

test "the dictionary is RFC 7932's" {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    try std.testing.expectEqualSlices(u8, &.{ 0x20, 0xe4, 0x2e, 0xb1, 0xb5, 0x11, 0xc2, 0x18, 0x06, 0xd4, 0xd2, 0x27, 0xd0, 0x7e, 0x5d, 0xd0, 0x68, 0x77, 0xd8, 0xce, 0x7b, 0x3a, 0x81, 0x7f, 0x37, 0x8f, 0x31, 0x36, 0x53, 0xf3, 0x5c, 0x70 }, &digest);
    try std.testing.expectEqual(121, transforms.len);
}

test "transforms: omissions, uppercasing and affixes" {
    var buf: [transform_room]u8 = undefined;
    // 4: "", uppercase_first, " "
    try std.testing.expectEqualStrings("Time ", buf[0..transform(&buf, "time", 4)]);
    // 3: "", omit_first_1, ""
    try std.testing.expectEqualStrings("ime", buf[0..transform(&buf, "time", 3)]);
    // 12: "", omit_last_1, ""
    try std.testing.expectEqualStrings("tim", buf[0..transform(&buf, "time", 12)]);
    // 54: "", omit_first_9, "": longer than the word leaves it empty
    try std.testing.expectEqual(0, transform(&buf, "time", 54));
    // 44: "", uppercase_all, "": a two-byte character's second byte flips
    try std.testing.expectEqualSlices(u8, &.{ 'A', 0xc3, 0xa9 ^ 32 }, buf[0..transform(&buf, &.{ 'a', 0xc3, 0xa9 }, 44)]);
}
