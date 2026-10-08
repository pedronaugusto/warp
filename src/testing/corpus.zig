//! Reads warp's captured corpora (testdata/*.corpus, written by
//! pedronaugusto/trials warp/src/capture.zig): a text header ending at an
//! empty line, then records of a fixed number of fields, each a
//! little-endian u32 length and that many bytes (shakedown's corpus-entry
//! form).

const std = @import("std");
const Diagnostic = @import("../Diagnostic.zig");
const container = @import("../container.zig");

const data = @import("corpus/data.zig");

pub const max_fields = data.max_fields;
pub const Corpus = data.Corpus;
pub const Record = data.Record;
pub const Iterator = data.Iterator;
pub const input = data.input;

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
pub const sizes = data.sizes;
pub const invalid = @embedFile("invalid.corpus");
