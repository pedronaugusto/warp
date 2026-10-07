//! gzip member headers (RFC 1952): every field, read and written.
//!
//! One parser reads a header from bytes handed to it in pieces of any size,
//! and hands the variable fields (extra, name, comment) to a sink as they
//! pass: `parseHeader` keeps slices of its input, a streaming decoder
//! copies them into `Fields`, the whole-buffer decoder skips them.

const std = @import("std");
const Io = std.Io;
const checksum = @import("checksum.zig");
const Diagnostic = @import("Diagnostic.zig");

const flag_text: u8 = 1;
const flag_hcrc: u8 = 2;
const flag_extra: u8 = 4;
const flag_name: u8 = 8;
const flag_comment: u8 = 16;

/// A member header. Writing it, the defaults are deterministic: no time
/// and an unknown operating system.
pub const Header = struct {
    /// FTEXT: the data is probably text.
    text: bool = false,
    /// Modification time, seconds since the Unix epoch; 0 for none.
    mtime: u32 = 0,
    /// Extra flags; null when written: 2 for levels 9 and up, 4 for level 1,
    /// else 0, as gzip(1) writes them.
    xfl: ?u8 = null,
    /// The operating system the member was made on; 255 is unknown.
    os: u8 = 255,
    /// FEXTRA: the extra field's bytes (subfields included), at most 65,535.
    extra: ?[]const u8 = null,
    /// FNAME: the original file name, without its terminating zero (and
    /// with no other).
    name: ?[]const u8 = null,
    /// FCOMMENT: a comment, without its terminating zero (and with no other).
    comment: ?[]const u8 = null,
    /// FHCRC: the header carries the low 16 bits of its own CRC-32.
    header_crc: bool = false,
};

/// Where a streaming decoder copies a header's fields: the fixed ones, and
/// the variable ones into the caller's buffers. A field longer than its
/// buffer is cut to the buffer and `cut` is set.
pub const Fields = struct {
    /// The fields read; `extra`, `name` and `comment` are slices of the
    /// buffers below, and null when the header has none.
    header: Header = .{},
    extra_buffer: []u8 = &.{},
    name_buffer: []u8 = &.{},
    comment_buffer: []u8 = &.{},
    /// A field was longer than its buffer.
    cut: bool = false,

    /// The parser's sink: each piece of a field appended to its buffer.
    pub fn bytes(f: *Fields, field: Field, piece: []const u8, at: usize) void {
        _ = at;
        const buffer = switch (field) {
            .extra => f.extra_buffer,
            .name => f.name_buffer,
            .comment => f.comment_buffer,
        };
        const slot = switch (field) {
            .extra => &f.header.extra,
            .name => &f.header.name,
            .comment => &f.header.comment,
        };
        const len = if (slot.*) |s| s.len else 0;
        const n = @min(piece.len, buffer.len - len);
        @memcpy(buffer[len..][0..n], piece[0..n]);
        slot.* = buffer[0 .. len + n];
        if (n < piece.len) f.cut = true;
    }
};

pub const ParseError = error{
    /// Not a gzip member header: magic, method, reserved flags, or a header
    /// CRC that does not match.
    InvalidHeader,
    /// The input ends inside the header.
    Truncated,
};

/// A header and how many bytes it took.
pub const Parsed = struct { header: Header, len: usize };

/// The member header at the start of `in`. Slices in the result borrow
/// `in`.
pub fn parseHeader(in: []const u8) ParseError!Parsed {
    var p: Parser = .{};
    var sink: SliceSink = .{ .in = in };
    const fed = p.feed(in, &sink);
    switch (fed.status) {
        .more => return error.Truncated,
        .invalid => return error.InvalidHeader,
        .done => {},
    }
    var header = p.header();
    if (header.extra != null) header.extra = sink.field(.extra);
    if (header.name != null) header.name = sink.field(.name);
    if (header.comment != null) header.comment = sink.field(.comment);
    return .{ .header = header, .len = fed.used };
}

/// Write `header`.
pub fn writeHeader(w: *Io.Writer, header: Header) Io.Writer.Error!void {
    if (header.extra) |extra| std.debug.assert(extra.len <= std.math.maxInt(u16));
    for ([_]?[]const u8{ header.name, header.comment }) |field| if (field) |text| std.debug.assert(std.mem.findScalar(u8, text, 0) == null);
    var fixed: [10]u8 = undefined;
    fixedPart(&fixed, header, header.xfl orelse 0);
    var crc: checksum.Crc32 = .init;
    try w.writeAll(&fixed);
    crc.update(&fixed);
    if (header.extra) |extra| {
        var len: [2]u8 = undefined;
        std.mem.writeInt(u16, &len, @intCast(extra.len), .little);
        try w.writeAll(&len);
        try w.writeAll(extra);
        crc.update(&len);
        crc.update(extra);
    }
    for ([_]?[]const u8{ header.name, header.comment }) |field| if (field) |text| {
        try w.writeAll(text);
        try w.writeByte(0);
        crc.update(text);
        crc.update(&.{0});
    };
    if (header.header_crc) {
        var hcrc: [2]u8 = undefined;
        std.mem.writeInt(u16, &hcrc, @truncate(crc.final()), .little);
        try w.writeAll(&hcrc);
    }
}

/// The bytes `writeHeader` writes for `header`.
pub fn headerLen(header: Header) usize {
    var n: usize = 10;
    if (header.extra) |e| n += 2 + e.len;
    if (header.name) |s| n += s.len + 1;
    if (header.comment) |s| n += s.len + 1;
    if (header.header_crc) n += 2;
    return n;
}

/// The first ten bytes: magic, method, flags, time, extra flags, system.
pub fn fixedPart(out: *[10]u8, header: Header, xfl: u8) void {
    var flags: u8 = 0;
    if (header.text) flags |= flag_text;
    if (header.header_crc) flags |= flag_hcrc;
    if (header.extra != null) flags |= flag_extra;
    if (header.name != null) flags |= flag_name;
    if (header.comment != null) flags |= flag_comment;
    out[0..4].* = .{ 0x1f, 0x8b, 8, flags };
    std.mem.writeInt(u32, out[4..8], header.mtime, .little);
    out[8] = xfl;
    out[9] = header.os;
}

/// A variable field of the header.
pub const Field = enum { extra, name, comment };

/// A header read from bytes given in pieces of any size, checked as zlib
/// checks it: the magic on two bytes, then the method and flags, then the
/// header CRC when there is one.
pub const Parser = struct {
    part: Part = .fixed,
    /// Bytes of the current part read.
    at: u16 = 0,
    fixed: [10]u8 = undefined,
    /// The extra field's length, as it is read.
    extra_len: u16 = 0,
    /// The header's CRC-32 so far, kept only when it has one.
    crc: checksum.Crc32 = .init,
    /// The header CRC's first byte.
    hcrc_low: u8 = 0,

    const Part = enum { fixed, extra_len, extra, name, comment, hcrc, done };

    pub const Status = enum { more, done, invalid };

    /// What a piece did: the bytes it used (through the refused byte when
    /// invalid), and why it was refused.
    pub const Fed = struct { used: usize, status: Status, reason: Diagnostic.Reason = .bad_gzip_header };

    /// Read from `in`, handing the variable fields' bytes to
    /// `sink.bytes(field, piece, at)` (`at` is the piece's offset in `in`).
    pub fn feed(p: *Parser, in: []const u8, sink: anytype) Fed {
        var i: usize = 0;
        while (i < in.len) {
            const flags = p.fixed[3];
            switch (p.part) {
                .fixed => {
                    p.fixed[p.at] = in[i];
                    p.at += 1;
                    i += 1;
                    // zlib checks the magic on two bytes, then the method and flags.
                    if (p.at == 2 and (p.fixed[0] != 0x1f or p.fixed[1] != 0x8b)) return .{ .used = i, .status = .invalid };
                    if (p.at == 4) {
                        if (p.fixed[2] != 8) return .{ .used = i, .status = .invalid };
                        if (p.fixed[3] & 0xe0 != 0) return .{ .used = i, .status = .invalid, .reason = .reserved_flags };
                    }
                    if (p.at == 10) {
                        if (flags & flag_hcrc != 0) p.crc.update(&p.fixed);
                        p.next(.extra_len);
                    }
                },
                .extra_len => {
                    p.extra_len |= @as(u16, in[i]) << @intCast(8 * p.at);
                    p.sum(in[i..][0..1]);
                    p.at += 1;
                    i += 1;
                    if (p.at == 2) {
                        sink.bytes(.extra, in[i..i], i);
                        p.next(if (p.extra_len == 0) .name else .extra);
                    }
                },
                .extra => {
                    const n = @min(in.len - i, p.extra_len - p.at);
                    sink.bytes(.extra, in[i..][0..n], i);
                    p.sum(in[i..][0..n]);
                    p.at += @intCast(n);
                    i += n;
                    if (p.at == p.extra_len) p.next(.name);
                },
                .name, .comment => {
                    const field: Field = if (p.part == .name) .name else .comment;
                    if (p.at == 0) sink.bytes(field, in[i..i], i);
                    p.at = 1;
                    const end = std.mem.findScalarPos(u8, in, i, 0);
                    const stop = end orelse in.len;
                    sink.bytes(field, in[i..stop], i);
                    p.sum(in[i..stop]);
                    i = stop;
                    if (end != null) {
                        p.sum(in[i..][0..1]);
                        i += 1;
                        p.next(if (field == .name) .comment else .hcrc);
                    }
                },
                .hcrc => {
                    if (p.at == 0) {
                        p.hcrc_low = in[i];
                        p.at = 1;
                        i += 1;
                        continue;
                    }
                    i += 1;
                    if (@as(u16, in[i - 1]) << 8 | p.hcrc_low != @as(u16, @truncate(p.crc.final()))) return .{ .used = i, .status = .invalid, .reason = .header_crc };
                    p.part = .done;
                },
                .done => break,
            }
            if (p.part == .done) break;
        }
        // A part that the flags leave out is passed without a byte.
        if (p.part != .done and p.part != .fixed) p.skipAbsent();
        return .{ .used = i, .status = if (p.part == .done) .done else .more };
    }

    /// The fixed fields, and which variable ones are present (as empty
    /// slices), once the header is done.
    pub fn header(p: *const Parser) Header {
        const flags = p.fixed[3];
        return .{
            .text = flags & flag_text != 0,
            .mtime = std.mem.readInt(u32, p.fixed[4..8], .little),
            .xfl = p.fixed[8],
            .os = p.fixed[9],
            .extra = if (flags & flag_extra != 0) &.{} else null,
            .name = if (flags & flag_name != 0) &.{} else null,
            .comment = if (flags & flag_comment != 0) &.{} else null,
            .header_crc = flags & flag_hcrc != 0,
        };
    }

    /// Start `part`, or the first part after it that the flags include.
    fn next(p: *Parser, part: Part) void {
        p.part = part;
        p.at = 0;
        p.skipAbsent();
    }

    fn skipAbsent(p: *Parser) void {
        const flags = p.fixed[3];
        while (true) {
            const present = switch (p.part) {
                .extra_len, .extra => flags & flag_extra != 0,
                .name => flags & flag_name != 0,
                .comment => flags & flag_comment != 0,
                .hcrc => flags & flag_hcrc != 0,
                .fixed, .done => return,
            };
            if (present) return;
            p.part = switch (p.part) {
                .extra_len, .extra => .name,
                .name => .comment,
                .comment => .hcrc,
                else => .done,
            };
            p.at = 0;
        }
    }

    /// The header CRC over `bytes`, when the header has one.
    fn sum(p: *Parser, bytes: []const u8) void {
        if (p.fixed[3] & flag_hcrc != 0) p.crc.update(bytes);
    }
};

/// A sink that keeps nothing.
pub const skip: Skip = .{};

pub const Skip = struct {
    pub fn bytes(_: Skip, _: Field, _: []const u8, _: usize) void {}
};

/// Records where each field lies in the input, for slices of it.
const SliceSink = struct {
    in: []const u8,
    spans: [3]?[2]usize = .{ null, null, null },

    pub fn bytes(s: *SliceSink, f: Field, piece: []const u8, at: usize) void {
        const span = &s.spans[@backingInt(f)];
        if (span.*) |*known| known[1] = at + piece.len else span.* = .{ at, at + piece.len };
    }

    fn field(s: *const SliceSink, f: Field) []const u8 {
        const span = s.spans[@backingInt(f)] orelse return &.{};
        return s.in[span[0]..span[1]];
    }
};

test "a header read a byte at a time is the header read whole" {
    const header: Header = .{ .text = true, .mtime = 7, .xfl = 2, .os = 3, .extra = "AB\x02\x00hi", .name = "notes.txt", .comment = "", .header_crc = true };
    var buffer: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buffer);
    try writeHeader(&w, header);
    const written = w.buffered();
    var name: [4]u8 = undefined;
    var extra: [16]u8 = undefined;
    var fields: Fields = .{ .name_buffer = &name, .extra_buffer = &extra };
    var p: Parser = .{};
    for (written, 0..) |b, i| {
        const fed = p.feed(&.{b}, &fields);
        try std.testing.expectEqual(@as(usize, 1), fed.used);
        try std.testing.expectEqual(if (i + 1 == written.len) Parser.Status.done else .more, fed.status);
    }
    try std.testing.expectEqualStrings("note", fields.header.name.?);
    try std.testing.expect(fields.cut);
    try std.testing.expectEqualStrings("AB\x02\x00hi", fields.header.extra.?);
    // An empty comment is present, and its buffer is empty.
    try std.testing.expectEqualStrings("", fields.header.comment.?);
    const parsed = try parseHeader(written);
    try std.testing.expectEqualStrings("notes.txt", parsed.header.name.?);
    try std.testing.expectEqualStrings("", parsed.header.comment.?);
}
