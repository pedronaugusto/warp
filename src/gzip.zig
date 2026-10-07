//! gzip member headers (RFC 1952): every field, read and written.
//!
//! One parser reads a header from any byte source and hands the variable
//! fields (extra, name, comment) to a sink: `parseHeader` keeps slices of
//! its input, the decoder skips them.

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
    var src: SliceSource = .{ .in = in };
    var sink: SliceSink = .{ .src = &src };
    var header = try parse(SliceSource, &src, &sink);
    header.extra = sink.field(.extra);
    header.name = sink.field(.name);
    header.comment = sink.field(.comment);
    return .{ .header = header, .len = src.at };
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

/// Read a header from `src`, which has `byte() Src.Error!u8` and
/// `invalid(Diagnostic.Reason) Src.Error`; hand the variable fields to
/// `sink`, which has `begin(Field)`, `byte(Field, u8)` and `end(Field)`.
/// The header CRC, when present, is checked.
pub fn parse(comptime Src: type, src: *Src, sink: anytype) Src.Error!Header {
    var crc: checksum.Crc32 = .init;
    var fixed: [10]u8 = undefined;
    for (&fixed, 0..) |*b, i| {
        b.* = try src.byte();
        // zlib checks the magic on two bytes, then the method and flags.
        if (i == 1 and (fixed[0] != 0x1f or fixed[1] != 0x8b)) return src.invalid(.bad_gzip_header);
        if (i == 3) {
            if (fixed[2] != 8) return src.invalid(.bad_gzip_header);
            if (fixed[3] & 0xe0 != 0) return src.invalid(.reserved_flags);
        }
    }
    crc.update(&fixed);
    const flags = fixed[3];
    var header: Header = .{
        .text = flags & flag_text != 0,
        .mtime = std.mem.readInt(u32, fixed[4..8], .little),
        .xfl = fixed[8],
        .os = fixed[9],
        .header_crc = flags & flag_hcrc != 0,
    };
    if (flags & flag_extra != 0) {
        var len_bytes: [2]u8 = undefined;
        for (&len_bytes) |*b| b.* = try src.byte();
        crc.update(&len_bytes);
        const len = std.mem.readInt(u16, &len_bytes, .little);
        sink.begin(.extra);
        for (0..len) |_| {
            const b = try src.byte();
            crc.update(&.{b});
            sink.byte(.extra, b);
        }
        sink.end(.extra);
        header.extra = &.{};
    }
    for ([_]struct { u8, Field }{ .{ flag_name, .name }, .{ flag_comment, .comment } }) |f| {
        if (flags & f[0] == 0) continue;
        sink.begin(f[1]);
        while (true) {
            const b = try src.byte();
            crc.update(&.{b});
            if (b == 0) break;
            sink.byte(f[1], b);
        }
        sink.end(f[1]);
        if (f[1] == .name) header.name = &.{} else header.comment = &.{};
    }
    if (header.header_crc) {
        const lo = try src.byte();
        const hi = try src.byte();
        if (@as(u16, hi) << 8 | lo != @as(u16, @truncate(crc.final()))) return src.invalid(.header_crc);
    }
    return header;
}

/// A sink that keeps nothing.
pub const skip: Skip = .{};

pub const Skip = struct {
    pub fn begin(_: Skip, _: Field) void {}
    pub fn byte(_: Skip, _: Field, _: u8) void {}
    pub fn end(_: Skip, _: Field) void {}
};

const SliceSource = struct {
    in: []const u8,
    at: usize = 0,

    const Error = ParseError;

    fn byte(s: *SliceSource) Error!u8 {
        if (s.at >= s.in.len) return error.Truncated;
        s.at += 1;
        return s.in[s.at - 1];
    }

    fn invalid(_: *SliceSource, _: Diagnostic.Reason) Error {
        return error.InvalidHeader;
    }
};

/// Records where each field lies in the input, for slices of it.
const SliceSink = struct {
    src: *const SliceSource,
    spans: [3]?[2]usize = .{ null, null, null },

    pub fn begin(s: *SliceSink, f: Field) void {
        s.spans[@backingInt(f)] = .{ s.src.at, s.src.at };
    }

    pub fn byte(_: *SliceSink, _: Field, _: u8) void {}

    pub fn end(s: *SliceSink, f: Field) void {
        // A name or comment ends at its terminating zero, already read.
        s.spans[@backingInt(f)].?[1] = if (f == .extra) s.src.at else s.src.at - 1;
    }

    fn field(s: *const SliceSink, f: Field) ?[]const u8 {
        const span = s.spans[@backingInt(f)] orelse return null;
        return s.src.in[span[0]..span[1]];
    }
};
