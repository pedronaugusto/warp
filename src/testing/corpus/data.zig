//! Captured records and the fixed generator inputs they name.
const std = @import("std");
const gen = @import("gen");

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

/// The input generator specs name, regenerated: one spec, or several
/// joined with " + ", one after another.
pub fn input(gpa: std.mem.Allocator, spec_text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var it = std.mem.splitSequence(u8, spec_text, " + ");
    while (it.next()) |part| {
        const spec = try gen.Spec.parse(part);
        const at = out.items.len;
        try out.resize(gpa, at + spec.len);
        gen.fill(spec.kind, spec.seed, out.items[at..]);
    }
    return out.toOwnedSlice(gpa);
}

pub const sizes = @embedFile("sizes.corpus");
