//! warp's inputs, generated from fixed seeds: the benchmarks' synthetic
//! workloads, the tests' inputs, and the inputs of the corpus captured from
//! other implementations, which names an input by its kind, seed and length
//! and regenerates it here rather than storing it.
//!
//! Every input is a pure function of (kind, seed, length), with its own
//! generator (SplitMix64), so no change to the standard library can move a
//! byte under a captured stream. Text is words from a vocabulary made of
//! syllables, so nothing here is anyone's prose.

const std = @import("std");

/// What an input looks like.
pub const Kind = enum {
    /// Words, spaces, punctuation and line breaks, with a skewed word
    /// frequency, as prose and source code have.
    text,
    /// Fixed-size records of small integers, offsets that grow and short
    /// names, as object files and databases have.
    binary,
    /// Uniform random bytes: incompressible.
    noise,
    /// Runs of one byte, 1 to 300 long.
    runs,
    /// Every byte zero.
    zeros,
    /// Rows of a smooth 3-channel image, each preceded by its PNG filter
    /// type and filtered with it, as a PNG's data before compression.
    png,
    /// One short pattern repeated: periods of 1 to 300 bytes.
    periodic,
    /// JSON-shaped messages: keys from a small set, numbers and strings.
    json,
};

/// SplitMix64: a 64-bit state, one multiply-xorshift chain per draw.
pub const Prng = struct {
    state: u64,

    pub fn init(seed: u64) Prng {
        return .{ .state = seed };
    }

    pub fn next(p: *Prng) u64 {
        p.state +%= 0x9e3779b97f4a7c15;
        var z = p.state;
        z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
        z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
        return z ^ (z >> 31);
    }

    /// A value in `[0, n)`, `n > 0` (Lemire's multiply, no division).
    pub fn below(p: *Prng, n: usize) usize {
        return @intCast((@as(u128, p.next()) * n) >> 64);
    }

    pub fn byte(p: *Prng) u8 {
        return @truncate(p.next());
    }
};

/// Fill `out` with the input of `kind` and `seed`, `out.len` bytes long.
pub fn fill(kind: Kind, seed: u64, out: []u8) void {
    // The kind is mixed into the seed so that two kinds with one seed share
    // no random stream.
    var prng: Prng = .init(seed ^ (@as(u64, @backingInt(kind)) << 56) ^ 0x7761_7270);
    switch (kind) {
        .text => text(&prng, out),
        .binary => binary(&prng, out),
        .noise => for (out) |*b| {
            b.* = prng.byte();
        },
        .runs => runs(&prng, out),
        .zeros => @memset(out, 0),
        .png => png(&prng, out),
        .periodic => periodic(&prng, out),
        .json => json(&prng, out),
    }
}

/// The input as a new slice the caller frees.
pub fn alloc(gpa: std.mem.Allocator, kind: Kind, seed: u64, len: usize) std.mem.Allocator.Error![]u8 {
    const out = try gpa.alloc(u8, len);
    fill(kind, seed, out);
    return out;
}

/// An input's name in a corpus: `<kind> <seed> <len>`.
pub const Spec = struct {
    kind: Kind,
    seed: u64,
    len: usize,

    pub const ParseError = error{InvalidSpec};

    pub fn parse(text_: []const u8) ParseError!Spec {
        var it = std.mem.splitScalar(u8, text_, ' ');
        const kind = std.meta.stringToEnum(Kind, it.next() orelse return error.InvalidSpec) orelse return error.InvalidSpec;
        const seed = std.fmt.parseInt(u64, it.next() orelse return error.InvalidSpec, 10) catch return error.InvalidSpec;
        const len = std.fmt.parseInt(usize, it.next() orelse return error.InvalidSpec, 10) catch return error.InvalidSpec;
        if (it.next() != null) return error.InvalidSpec;
        return .{ .kind = kind, .seed = seed, .len = len };
    }

    pub fn format(s: Spec, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s} {d} {d}", .{ @tagName(s.kind), s.seed, s.len });
    }
};

const vocabulary_size = 2048;
const syllables = [_][]const u8{
    "ka", "ro", "mi", "tel", "an", "us", "be", "lor", "de",  "pha", "si", "on",   "gra", "vi", "ne",  "str",
    "o",  "ul", "en", "qua", "te", "ri", "mo", "dax", "pel", "i",   "zu", "chen", "fa",  "lu", "orb", "et",
};

/// The vocabulary: 2,048 words of 1 to 4 syllables, fixed.
const Vocabulary = struct {
    bytes: [vocabulary_size * 16]u8,
    lens: [vocabulary_size]u8,

    fn init() Vocabulary {
        @setEvalBranchQuota(200_000);
        var v: Vocabulary = undefined;
        var prng: Prng = .init(0x766f_6361_6275_6c61);
        for (0..vocabulary_size) |i| {
            const n = 1 + prng.below(4);
            var len: usize = 0;
            for (0..n) |_| {
                const s = syllables[prng.below(syllables.len)];
                @memcpy(v.bytes[i * 16 + len ..][0..s.len], s);
                len += s.len;
            }
            v.lens[i] = @intCast(len);
        }
        return v;
    }

    fn word(v: *const Vocabulary, i: usize) []const u8 {
        return v.bytes[i * 16 ..][0..v.lens[i]];
    }
};

const vocabulary: Vocabulary = .init();

/// A word index with a skewed frequency: the square of a uniform draw
/// favours low indices, about as Zipf's law does for small vocabularies.
fn wordIndex(p: *Prng) usize {
    const u = p.below(vocabulary_size);
    return @intCast((u * u) / vocabulary_size);
}

fn put(out: []u8, at: *usize, bytes: []const u8) bool {
    const n = @min(bytes.len, out.len - at.*);
    @memcpy(out[at.*..][0..n], bytes[0..n]);
    at.* += n;
    return at.* < out.len;
}

fn text(p: *Prng, out: []u8) void {
    var at: usize = 0;
    var words_in_line: u64 = 0;
    var line_len = 6 + p.below(12);
    while (at < out.len) {
        var w = vocabulary.word(wordIndex(p));
        var buf: [17]u8 = undefined;
        if (words_in_line == 0 and p.below(3) == 0) {
            @memcpy(buf[0..w.len], w);
            buf[0] = std.ascii.toUpper(buf[0]);
            w = buf[0..w.len];
        }
        if (!put(out, &at, w)) return;
        words_in_line += 1;
        const sep: []const u8 = if (words_in_line >= line_len) blk: {
            words_in_line = 0;
            line_len = 6 + p.below(12);
            break :blk if (p.below(4) == 0) ".\n\n" else ".\n";
        } else switch (p.below(16)) {
            0 => ", ",
            1 => "; ",
            2 => " (",
            3 => ") ",
            else => " ",
        };
        if (!put(out, &at, sep)) return;
    }
}

fn binary(p: *Prng, out: []u8) void {
    var at: usize = 0;
    var offset: u32 = 0;
    var id: u32 = @truncate(p.next() & 0xffff);
    while (at < out.len) {
        var record: [32]u8 = @splat(0);
        offset +%= @truncate(16 + p.below(240));
        id +%= 1;
        std.mem.writeInt(u32, record[0..4], id, .little);
        std.mem.writeInt(u32, record[4..8], offset, .little);
        std.mem.writeInt(u16, record[8..10], @truncate(p.below(64)), .little);
        record[10] = @truncate(p.below(4));
        record[11] = 0;
        std.mem.writeInt(u64, record[12..20], p.next() & 0x0000_00ff_00ff_ffff, .little);
        const name = vocabulary.word(wordIndex(p));
        const n = @min(name.len, 12);
        @memcpy(record[20..][0..n], name[0..n]);
        if (!put(out, &at, &record)) return;
    }
}

fn runs(p: *Prng, out: []u8) void {
    var at: usize = 0;
    while (at < out.len) {
        const n = @min(1 + p.below(300), out.len - at);
        @memset(out[at..][0..n], p.byte());
        at += n;
    }
}

fn periodic(p: *Prng, out: []u8) void {
    var pattern: [300]u8 = undefined;
    const period = 1 + p.below(pattern.len);
    for (pattern[0..period]) |*b| b.* = p.byte();
    for (out, 0..) |*b, i| b.* = pattern[i % period];
}

fn png(p: *Prng, out: []u8) void {
    // A width of 16 to 512 pixels, three bytes each; the image is a sum of
    // two gradients and a little noise, then each row is filtered.
    const width = 16 + p.below(497);
    const row_len = 3 * width;
    var prev: [3 * 512]u8 = @splat(0);
    var row: [3 * 512]u8 = undefined;
    var at: usize = 0;
    var y: u64 = 0;
    const gx = 1 + p.below(3);
    const gy = 1 + p.below(3);
    while (at < out.len) : (y += 1) {
        for (0..width) |x| for (0..3) |c| {
            const smooth = (x * gx + y * gy + c * 40) & 0xff;
            const grain = if (p.below(8) == 0) p.below(5) else 0;
            row[3 * x + c] = @truncate(smooth + grain);
        };
        const filter: u8 = @truncate(p.below(5));
        if (!put(out, &at, &.{filter})) return;
        for (0..row_len) |i| {
            const a: u8 = if (i >= 3) row[i - 3] else 0;
            const b = prev[i];
            const c: u8 = if (i >= 3) prev[i - 3] else 0;
            const predicted: u8 = switch (filter) {
                0 => 0,
                1 => a,
                2 => b,
                3 => @truncate((@as(u16, a) + b) / 2),
                else => paeth(a, b, c),
            };
            if (!put(out, &at, &.{row[i] -% predicted})) return;
        }
        @memcpy(prev[0..row_len], row[0..row_len]);
    }
}

fn paeth(a: u8, b: u8, c: u8) u8 {
    const pa = @abs(@as(i16, b) - c);
    const pb = @abs(@as(i16, a) - c);
    const pc = @abs(@as(i16, a) + b - 2 * @as(i16, c));
    if (pa <= pb and pa <= pc) return a;
    if (pb <= pc) return b;
    return c;
}

fn json(p: *Prng, out: []u8) void {
    const keys = [_][]const u8{ "id", "type", "name", "value", "time", "user", "tags", "ok", "count", "path" };
    var at: usize = 0;
    var seq: u64 = p.below(100_000);
    while (at < out.len) {
        if (!put(out, &at, "{")) return;
        const fields = 2 + p.below(6);
        for (0..fields) |f| {
            if (f != 0 and !put(out, &at, ",")) return;
            const key = keys[p.below(keys.len)];
            if (!put(out, &at, "\"") or !put(out, &at, key) or !put(out, &at, "\":")) return;
            var buf: [24]u8 = undefined;
            const value = switch (p.below(4)) {
                // unreachable: 24 bytes hold any u64 in decimal
                0 => std.mem.print(&buf, "{d}", .{seq}) catch unreachable,
                // unreachable: 24 bytes hold any u64 in decimal
                1 => std.mem.print(&buf, "{d}", .{p.below(1000)}) catch unreachable,
                2 => if (p.below(2) == 0) "true" else "false",
                else => blk: {
                    const w = vocabulary.word(wordIndex(p));
                    buf[0] = '"';
                    @memcpy(buf[1..][0..w.len], w);
                    buf[1 + w.len] = '"';
                    break :blk buf[0 .. w.len + 2];
                },
            };
            if (!put(out, &at, value)) return;
        }
        seq += 1;
        if (!put(out, &at, "}\n")) return;
    }
}

test "an input is a function of its kind, seed and length, and a shorter one is a prefix" {
    for (std.enums.values(Kind)) |kind| {
        var a: [5000]u8 = undefined;
        var b: [5000]u8 = undefined;
        var short: [777]u8 = undefined;
        fill(kind, 42, &a);
        fill(kind, 42, &b);
        fill(kind, 42, &short);
        try std.testing.expectEqualSlices(u8, &a, &b);
        try std.testing.expectEqualSlices(u8, a[0..short.len], &short);
    }
}

test "a spec reads back as written" {
    var buf: [64]u8 = undefined;
    const s: Spec = .{ .kind = .png, .seed = 9, .len = 65543 };
    const written = try std.mem.print(&buf, "{f}", .{s});
    try std.testing.expectEqualStrings("png 9 65543", written);
    try std.testing.expectEqual(s, try Spec.parse(written));
    try std.testing.expectError(error.InvalidSpec, Spec.parse("png 9"));
    try std.testing.expectError(error.InvalidSpec, Spec.parse("jpeg 9 1"));
}
