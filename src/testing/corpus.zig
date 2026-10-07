//! Reads warp's captured corpora (testdata/*.corpus, written by
//! pedronaugusto/trials warp/src/capture.zig): a text header ending at an
//! empty line, then records of a fixed number of fields, each a
//! little-endian u32 length and that many bytes (shakedown's corpus-entry
//! form).

const std = @import("std");
const gen = @import("gen");
const Diagnostic = @import("../Diagnostic.zig");
const container = @import("../container.zig");

pub const max_fields = 8;

pub const Corpus = struct {
    /// The header's second line: where the records came from.
    sources: []const u8,
    fields: usize,
    body: []const u8,

    pub fn parse(bytes: []const u8) error{BadCorpus}!Corpus {
        const end = std.mem.find(u8, bytes, "\n\n") orelse return error.BadCorpus;
        var lines = std.mem.splitScalar(u8, bytes[0..end], '\n');
        _ = lines.next() orelse return error.BadCorpus;
        const sources = lines.next() orelse return error.BadCorpus;
        const fields_line = lines.next() orelse return error.BadCorpus;
        if (!std.mem.startsWith(u8, fields_line, "fields: ")) return error.BadCorpus;
        return .{
            .sources = sources,
            .fields = std.mem.count(u8, fields_line["fields: ".len..], " ") + 1,
            .body = bytes[end + 2 ..],
        };
    }

    pub fn records(c: Corpus) Iterator {
        return .{ .corpus = c };
    }
};

pub const Record = struct {
    fields: [max_fields][]const u8,
    index: usize,
};

pub const Iterator = struct {
    corpus: Corpus,
    at: usize = 0,
    index: usize = 0,

    pub fn next(it: *Iterator) ?Record {
        const body = it.corpus.body;
        if (it.at >= body.len) return null;
        var r: Record = .{ .fields = undefined, .index = it.index };
        for (0..it.corpus.fields) |f| {
            const len = std.mem.readInt(u32, body[it.at..][0..4], .little);
            it.at += 4;
            r.fields[f] = body[it.at..][0..len];
            it.at += len;
        }
        it.index += 1;
        return r;
    }
};

/// The input a generator spec names, regenerated.
pub fn input(gpa: std.mem.Allocator, spec_text: []const u8) ![]u8 {
    const spec = try gen.Spec.parse(spec_text);
    return gen.alloc(gpa, spec.kind, spec.seed, spec.len);
}

/// What a zlib message means for warp: the error, and the reasons that
/// say it.
pub const Expected = struct { err: anyerror, reasons: []const Diagnostic.Reason };

pub fn expected(msg: []const u8, kind: container.Container) Expected {
    const Map = struct { []const u8, anyerror, []const Diagnostic.Reason };
    const header: Diagnostic.Reason = if (kind == .gzip) .bad_gzip_header else .bad_zlib_header;
    const table = [_]Map{
        .{ "incorrect data check", error.ChecksumMismatch, &.{ .adler32, .crc32 } },
        .{ "incorrect length check", error.ChecksumMismatch, &.{.size} },
        .{ "header crc mismatch", error.ChecksumMismatch, &.{.header_crc} },
        .{ "incorrect header check", error.InvalidStream, &.{header} },
        .{ "unknown compression method", error.InvalidStream, &.{header} },
        .{ "invalid window size", error.InvalidStream, &.{.bad_zlib_header} },
        .{ "unknown header flags set", error.InvalidStream, &.{.reserved_flags} },
        .{ "invalid block type", error.InvalidStream, &.{.bad_block_type} },
        .{ "invalid stored block lengths", error.InvalidStream, &.{.stored_length} },
        .{ "too many length or distance symbols", error.InvalidStream, &.{.too_many_codes} },
        .{ "invalid code lengths set", error.InvalidStream, &.{ .incomplete_code, .oversubscribed_code } },
        .{ "invalid bit length repeat", error.InvalidStream, &.{.bad_code_lengths} },
        .{ "invalid code -- missing end-of-block", error.InvalidStream, &.{.no_end_code} },
        .{ "invalid literal/lengths set", error.InvalidStream, &.{ .incomplete_code, .oversubscribed_code } },
        .{ "invalid distances set", error.InvalidStream, &.{ .incomplete_code, .oversubscribed_code } },
        .{ "invalid literal/length code", error.InvalidStream, &.{.bad_symbol} },
        .{ "invalid distance code", error.InvalidStream, &.{.bad_symbol} },
        .{ "invalid distance too far back", error.InvalidStream, &.{.distance_too_far} },
    };
    for (table) |m| if (std.mem.eql(u8, m[0], msg)) return .{ .err = m[1], .reasons = m[2] };
    std.debug.panic("unmapped zlib message: {s}", .{msg});
}

pub const streams = @embedFile("streams.corpus");
pub const sizes = @embedFile("sizes.corpus");
pub const invalid = @embedFile("invalid.corpus");
