//! A zstd dictionary: content that frames may refer back into, and, in the
//! formatted kind, entropy tables and repeat offsets that a frame's first
//! block starts from (RFC 8878 5). Parsed once and read-only after: any
//! number of decoders and encoders may share one.

const Dictionary = @This();

const std = @import("std");
const fse = @import("fse.zig");
const huffman = @import("huffman.zig");
const codes = @import("codes.zig");
const decode = @import("decode.zig");

pub const magic: u32 = 0xEC30A437;

/// 0 for raw content.
id: u32,
/// The content, borrowed from the bytes given to `parse`.
content: []const u8,
/// Private: the dictionary carried entropy tables.
formatted: bool,
/// Private: those tables (undefined for raw content).
entropy: Entropy,

/// A formatted dictionary's tables, in the forms both directions need.
pub const Entropy = struct {
    huffman: huffman.Table,
    weights: huffman.Weights,
    ll: fse.LlTable,
    of: fse.OfTable,
    ml: fse.MlTable,
    ll_counts: fse.Counts,
    of_counts: fse.Counts,
    ml_counts: fse.Counts,
    reps: [3]u32,
};

pub const ParseError = error{InvalidDictionary};

/// A formatted dictionary (starting with the magic number), or raw content
/// otherwise. The value holds decoding tables (about 30 KiB); `content`
/// borrows `bytes`.
pub fn parse(bytes: []const u8) ParseError!Dictionary {
    if (bytes.len < 8 or std.mem.readInt(u32, bytes[0..4], .little) != magic) return raw(bytes);
    var d: Dictionary = .{ .id = std.mem.readInt(u32, bytes[4..8], .little), .content = undefined, .formatted = true, .entropy = undefined };
    const e = &d.entropy;
    var pos: usize = 8;
    huffman.readWeights(bytes[pos..], &e.weights) catch return error.InvalidDictionary;
    e.huffman.build(&e.weights);
    pos += e.weights.len;
    pos += try counts(bytes[pos..], codes.max_of, codes.max_of_log, &e.of_counts);
    e.of.build(e.of_counts.norm[0 .. @as(usize, e.of_counts.max_symbol) + 1], e.of_counts.log, &codes.of_base, &codes.of_bits);
    pos += try counts(bytes[pos..], codes.max_ml, codes.max_ml_log, &e.ml_counts);
    e.ml.build(e.ml_counts.norm[0 .. @as(usize, e.ml_counts.max_symbol) + 1], e.ml_counts.log, &codes.ml_base, &codes.ml_bits);
    pos += try counts(bytes[pos..], codes.max_ll, codes.max_ll_log, &e.ll_counts);
    e.ll.build(e.ll_counts.norm[0 .. @as(usize, e.ll_counts.max_symbol) + 1], e.ll_counts.log, &codes.ll_base, &codes.ll_bits);
    if (bytes.len - pos < 12) return error.InvalidDictionary;
    const content_len = bytes.len - pos - 12;
    for (&e.reps, 0..) |*rep, i| {
        rep.* = std.mem.readInt(u32, bytes[pos + 4 * i ..][0..4], .little);
        if (rep.* == 0 or rep.* > content_len) return error.InvalidDictionary;
    }
    d.content = bytes[pos + 12 ..];
    return d;
}

/// `bytes` as raw content, even if they start with the magic number.
pub fn raw(bytes: []const u8) Dictionary {
    return .{ .id = 0, .content = bytes, .formatted = false, .entropy = undefined };
}

fn counts(in: []const u8, max: u8, max_log: u4, c: *fse.Counts) ParseError!usize {
    fse.readCounts(in, max, c) catch return error.InvalidDictionary;
    if (c.log > max_log) return error.InvalidDictionary;
    return c.len;
}

/// The entropy a frame using this dictionary starts from.
pub fn startEntropy(d: *const Dictionary) decode.Entropy {
    if (!d.formatted) return .{};
    const e = &d.entropy;
    return .{ .huffman = &e.huffman, .ll = &e.ll, .of = &e.of, .ml = &e.ml, .fse_ready = true, .reps = e.reps };
}

test "short or unmarked bytes are raw content; a marked dictionary with broken tables is refused" {
    const plain = try parse("raw content");
    try std.testing.expectEqual(@as(u32, 0), plain.id);
    try std.testing.expect(!plain.formatted);
    const short = try parse(&.{ 0x37, 0xa4, 0x30, 0xec });
    try std.testing.expectEqual(@as(usize, 4), short.content.len);
    try std.testing.expectError(error.InvalidDictionary, parse(&.{ 0x37, 0xa4, 0x30, 0xec, 1, 0, 0, 0, 0 }));
}
