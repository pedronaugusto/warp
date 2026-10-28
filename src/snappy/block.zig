//! The Snappy and S2 block formats decoded: a varint of the decoded
//! length, then elements (literals, and copies of 1-, 2- and 4-byte
//! offsets) into the caller's output, which is its own history. S2 adds
//! repeats (a 1-byte-offset copy of offset 0 copies from the last offset
//! again, with longer lengths) and dictionaries (content before the output
//! that the first 64 KiB of output may copy from).
//!
//! Each element is checked whole before it is written; literals of up to
//! 16 bytes and copies are stored 16 and 32 bytes at a time where the
//! input and output have that much room past them, so an output of exactly
//! the decoded length works and spare output only lets more elements take
//! the wide stores. What a block decodes to, and whether it is refused,
//! never depends on the spare output.

const std = @import("std");
const Diagnostic = @import("Diagnostic.zig");
const Dict = @import("Dict.zig");
const copy = @import("../match/copy.zig");

/// Snappy's elements, or S2's, which add repeats.
pub const Format = enum { snappy, s2 };

/// The longest length a block declares.
pub const max_len = std.math.maxInt(u32);

pub const Error = error{
    /// An element the format does not define, a copy before the output,
    /// output past the declared length, or bytes after the last element.
    InvalidStream,
    /// The input ends inside an element or before the declared output.
    Truncated,
    /// The block declares more than the output holds.
    OutputTooSmall,
};

pub const Options = struct {
    format: Format = .snappy,
    /// S2's dictionary (with `format = .s2`).
    dictionary: ?Dict = null,
    diagnostic: ?*Diagnostic = null,
    /// Where `in` starts in the caller's input, for the diagnostic.
    in_base: u64 = 0,
};

pub const Header = struct {
    /// The decoded length.
    len: u32,
    /// The bytes of the varint.
    size: u8,
};

/// The varint of the decoded length at the start of a block: at most five
/// bytes and below 2^32, in both formats (google's `Varint::Parse32`, S2's
/// `decodedLen`).
pub fn header(in: []const u8) error{ InvalidStream, Truncated }!Header {
    var v: u64 = 0;
    for (0..5) |i| {
        if (i == in.len) return error.Truncated;
        const b = in[i];
        v |= @as(u64, b & 0x7f) << @intCast(7 * i);
        if (b < 0x80) {
            if (v > max_len) return error.InvalidStream;
            return .{ .len = @intCast(v), .size = @intCast(i + 1) };
        }
    }
    return error.InvalidStream;
}

/// Decode the block `in` into `out` (at least its declared length); the
/// decoded length. Bytes of `out` past it may have been written.
pub fn decode(in: []const u8, out: []u8, options: Options) Error!usize {
    const h = header(in) catch |err| {
        if (options.diagnostic) |diag| diag.* = .{ .offset = .fromRaw(options.in_base), .reason = if (err == error.Truncated) .truncated else .bad_length };
        return err;
    };
    if (h.len > out.len) return error.OutputTooSmall;
    var d: Decoder = .{
        .in = in,
        .out = out,
        .end = h.len,
        .ip = h.size,
        .options = options,
        .dict = if (options.dictionary) |dict| dict.content else &.{},
        .last = if (options.dictionary) |dict| dict.content.len - dict.repeat else 0,
    };
    try d.run();
    return h.len;
}

const Decoder = struct {
    in: []const u8,
    out: []u8,
    /// The declared length.
    end: usize,
    ip: usize,
    op: usize = 0,
    options: Options,
    /// The dictionary's content, before `out[0]`.
    dict: []const u8,
    /// The offset a repeat copies from (S2); 0 for none yet.
    last: usize,

    fn run(d: *Decoder) Error!void {
        const in = d.in;
        while (d.ip < in.len) {
            const at = d.ip;
            const tag = in[at];
            if (tag & 3 == 0) {
                try d.literal(at, tag);
                continue;
            }
            var len: usize = undefined;
            var offset: usize = undefined;
            switch (tag & 3) {
                1 => {
                    if (in.len - at < 2) return d.fail(at, .truncated, error.Truncated);
                    const code: usize = (tag >> 2) & 7;
                    offset = (@as(usize, tag & 0xe0) << 3) | in[at + 1];
                    d.ip = at + 2;
                    len = code + 4;
                    if (offset == 0) {
                        if (d.options.format == .snappy) return d.fail(at, .zero_offset, error.InvalidStream);
                        len = try d.repeatLen(at, code);
                        if (d.last == 0) return d.fail(at, .no_repeat_offset, error.InvalidStream);
                        offset = d.last;
                    }
                },
                2 => {
                    if (in.len - at < 3) return d.fail(at, .truncated, error.Truncated);
                    len = (tag >> 2) + 1;
                    offset = std.mem.readInt(u16, in[at + 1 ..][0..2], .little);
                    d.ip = at + 3;
                    if (offset == 0) return d.fail(at, .zero_offset, error.InvalidStream);
                },
                else => {
                    if (in.len - at < 5) return d.fail(at, .truncated, error.Truncated);
                    len = (tag >> 2) + 1;
                    offset = std.mem.readInt(u32, in[at + 1 ..][0..4], .little);
                    d.ip = at + 5;
                    if (offset == 0) return d.fail(at, .zero_offset, error.InvalidStream);
                },
            }
            d.last = offset;
            try d.match(at, offset, len);
        }
        if (d.op != d.end) return d.fail(d.ip, .truncated, error.Truncated);
    }

    /// A literal: its length in the tag (up to 60) or in the 1-4 bytes
    /// after it, then its bytes.
    inline fn literal(d: *Decoder, at: usize, tag: u8) Error!void {
        const in = d.in;
        var ip = at + 1;
        // At most 4 bytes: a length less one of 32 bits.
        var short: u32 = tag >> 2;
        if (short >= 60) {
            const n: usize = short - 59;
            if (in.len - ip < n) return d.fail(at, .truncated, error.Truncated);
            short = 0;
            for (in[ip..][0..n], 0..) |b, i| short |= @as(u32, b) << @intCast(8 * i);
            ip += n;
        }
        const len = @as(u64, short) + 1;
        if (len > in.len - ip) return d.fail(at, .truncated, error.Truncated);
        if (len > d.end - d.op) return d.fail(at, .too_long, error.InvalidStream);
        const n: usize = @intCast(len);
        const out = d.out;
        if (n <= 16 and in.len - ip >= 16 and out.len - d.op >= 16) {
            out[d.op..][0..16].* = in[ip..][0..16].*;
        } else @memcpy(out[d.op..][0..n], in[ip..][0..n]);
        d.op += n;
        d.ip = ip + n;
    }

    /// An S2 repeat's length: codes 0-4 are lengths 4-8; 5, 6 and 7 take
    /// 1, 2 and 3 bytes more, added to 8, 260 and 65540.
    inline fn repeatLen(d: *Decoder, at: usize, code: usize) Error!usize {
        const in = d.in;
        const ip = d.ip;
        if (code < 5) return code + 4;
        const n = code - 4;
        if (in.len - ip < n) return d.fail(at, .truncated, error.Truncated);
        var extra: u24 = 0;
        for (in[ip..][0..n], 0..) |b, i| extra |= @as(u24, b) << @intCast(8 * i);
        d.ip = ip + n;
        return @as(usize, extra) + switch (code) {
            5 => @as(usize, 8),
            6 => 260,
            else => 65540,
        };
    }

    /// Copy `len` bytes from `offset` back: from the output, or (S2) from
    /// the dictionary, never running from it into the output.
    inline fn match(d: *Decoder, at: usize, offset: usize, len: usize) Error!void {
        const out = d.out;
        const op = d.op;
        if (len > d.end - op) return d.fail(at, .too_long, error.InvalidStream);
        if (offset > op) {
            if (d.dict.len == 0) return d.fail(at, .offset_too_far, error.InvalidStream);
            const back = offset - op;
            if (op > Dict.max_reach or back > d.dict.len or len > back) return d.fail(at, .dictionary_copy, error.InvalidStream);
            const from = d.dict.len - back;
            @memcpy(out[op..][0..len], d.dict[from..][0..len]);
        } else if (out.len - op >= len + 32) {
            copy.copyMatch(out, op, offset, len);
        } else if (offset >= len) {
            @memcpy(out[op..][0..len], out[op - offset ..][0..len]);
        } else for (out[op..][0..len], op - offset..) |*b, from| {
            b.* = out[from];
        }
        d.op = op + len;
    }

    fn fail(d: *Decoder, at: usize, reason: Diagnostic.Reason, err: Error) Error {
        if (d.options.diagnostic) |diag| diag.* = .{ .offset = .fromRaw(d.options.in_base + at), .reason = reason };
        return err;
    }
};

test "a literal, a copy and an S2 repeat" {
    // "a", then 4 bytes from 1 back, then (S2) a repeat of 4.
    const block = "\x09\x00a\x01\x01\x01\x00";
    var out: [9]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 9), try decode(block, &out, .{ .format = .s2 }));
    try std.testing.expectEqualStrings("aaaaaaaaa", &out);
    var diag: Diagnostic = .{};
    try std.testing.expectError(error.InvalidStream, decode(block, &out, .{ .format = .snappy, .diagnostic = &diag }));
    try std.testing.expectEqual(Diagnostic.Reason.zero_offset, diag.reason);
    try std.testing.expectEqual(@as(u64, 5), diag.offset.raw());
}

test "lengths: five bytes at most, below 2^32, in both formats" {
    try std.testing.expectEqual(Header{ .len = 1, .size = 5 }, try header("\x81\x80\x80\x80\x00"));
    try std.testing.expectError(error.InvalidStream, header("\x81\x80\x80\x80\x80\x00"));
    try std.testing.expectError(error.InvalidStream, header("\x80\x80\x80\x80\x10"));
    try std.testing.expectEqual(Header{ .len = max_len, .size = 5 }, try header("\xff\xff\xff\xff\x0f"));
    try std.testing.expectError(error.Truncated, header("\x80"));
}
