//! S2's seek index: where blocks start in a stream, compressed and
//! uncompressed, at least 1 MiB of output apart, so a reader can start at
//! the block holding an offset. It is a skippable chunk (0x99): appended
//! to the stream, where readers skip it, or kept apart. Written as S2's
//! `Index.appendTo` writes it (deltas from predictions, as Go's zigzag
//! varints, entries thinned to at most 65,536), and read as `Index.Load`
//! reads it.
const Index = @This();

const std = @import("std");
const aegis = @import("aegis");
const frame = @import("frame.zig");
const block = @import("block.zig");

pub const Entry = struct { compressed: u64, uncompressed: u64 };

/// The most entries an index holds.
pub const max_entries = 1 << 16;
/// Entries closer than this in output are not added.
pub const min_distance = 1 << 20;
const magic_header = "s2idx\x00";
const magic_trailer = "\x00xdi2s";

/// The output's length, if the index records it.
total_uncompressed: u64,
/// The stream's length up to the index, if it records it (a padded stream
/// does not).
total_compressed: ?u64,
/// The output each block holds, as the writer estimated it.
est_block: u64,
entries: []const Entry,

pub const LoadError = error{
    /// The index ends early.
    Truncated,
    /// Not an index chunk, or a value out of its range.
    InvalidIndex,
    /// An index chunk of another kind (not `s2idx`).
    Unsupported,
    /// More entries than `storage` holds.
    OutputTooSmall,
};

/// Read the index chunk at the start of `bytes`, its entries into
/// `storage` (up to `max_entries`); the index and the bytes after it.
pub fn load(bytes: []const u8, storage: []Entry) LoadError!struct { Index, []const u8 } {
    if (bytes.len <= frame.header_len + magic_header.len + magic_trailer.len) return error.Truncated;
    if (bytes[0] != frame.Type.index) return error.InvalidIndex;
    const h = frame.readHeader(bytes[0..frame.header_len]);
    var r: Reader = .{ .b = bytes[frame.header_len..] };
    if (r.b.len < h.len) return error.Truncated;
    if (!std.mem.eql(u8, r.b[0..magic_header.len], magic_header)) return error.Unsupported;
    r.b = r.b[magic_header.len..];
    const total_u = try r.varint();
    if (total_u < 0) return error.InvalidIndex;
    const total_c = try r.varint();
    const est = try r.varint();
    if (est < 0) return error.InvalidIndex;
    const count = try r.varint();
    if (count < 0 or count > max_entries) return error.InvalidIndex;
    const n: usize = @intCast(count);
    if (n > storage.len) return error.OutputTooSmall;
    if (r.b.len < 1) return error.Truncated;
    const has_uncompressed = r.b[0];
    r.b = r.b[1..];
    if (has_uncompressed > 1) return error.InvalidIndex;
    // Go's int64 arithmetic wraps; the checks after each sum are its.
    var prev: i64 = 0;
    for (storage[0..n], 0..) |*e, i| {
        var u: i64 = if (has_uncompressed != 0) try r.varint() else 0;
        if (i > 0) {
            u +%= prev +% est;
            if (u <= prev) return error.InvalidIndex;
        }
        if (u < 0) return error.InvalidIndex;
        e.uncompressed = @intCast(u);
        prev = u;
    }
    var predict = @divTrunc(est, 2);
    prev = 0;
    for (storage[0..n], 0..) |*e, i| {
        var c = try r.varint();
        if (i > 0) {
            const next = predict +% @divTrunc(c, 2);
            c +%= prev +% predict;
            if (c <= prev) return error.InvalidIndex;
            predict = next;
        }
        if (c < 0) return error.InvalidIndex;
        e.compressed = @intCast(c);
        prev = c;
    }
    if (r.b.len < 4 + magic_trailer.len) return error.Truncated;
    r.b = r.b[4..];
    if (!std.mem.eql(u8, r.b[0..magic_trailer.len], magic_trailer)) return error.InvalidIndex;
    return .{ .{
        .total_uncompressed = @intCast(total_u),
        .total_compressed = if (total_c < 0) null else @intCast(total_c),
        .est_block = @intCast(est),
        .entries = storage[0..n],
    }, r.b[magic_trailer.len..] };
}

/// The index appended to `stream`, found by its trailer and length at the
/// end, as S2's `LoadStream` finds it.
pub fn loadFromEnd(stream: []const u8, storage: []Entry) LoadError!Index {
    const tail = 4 + magic_trailer.len;
    if (stream.len < tail) return error.Truncated;
    const end = stream[stream.len - tail ..];
    if (!std.mem.eql(u8, end[4..], magic_trailer)) return error.Unsupported;
    const size = std.mem.readInt(u32, end[0..4], .little);
    if (size > frame.max_chunk_len + frame.header_len) return error.InvalidIndex;
    if (size > stream.len) return error.Truncated;
    const index, _ = try load(stream[stream.len - size ..], storage);
    return index;
}

pub const FindError = error{
    /// The offset is past the output, or before its start from the end.
    OutOfRange,
};

/// The entry at or before `offset` of output, from the start, or from the
/// end where it is negative (-1 the last byte): where to start reading
/// and how much output to skip there, as S2's `Find` answers.
pub fn find(index: Index, offset: i64) FindError!Entry {
    const total: i64 = @intCast(index.total_uncompressed);
    var at = offset;
    if (at < 0) {
        at = total + at;
        if (at < 0) return error.OutOfRange;
    }
    if (at > total) return error.OutOfRange;
    const e = index.entries;
    if (e.len > 200) {
        var lo: usize = 0;
        var hi: usize = e.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (e[mid].uncompressed > at) hi = mid else lo = mid + 1;
        }
        return e[@max(lo, 1) - 1];
    }
    var found: Entry = .{ .compressed = 0, .uncompressed = 0 };
    for (e) |entry| {
        if (entry.uncompressed > at) break;
        found = entry;
    }
    return found;
}

/// Entries as S2's writer gathers them: one per block start, kept only
/// where the output has moved at least `min_distance` since the last kept
/// (a start at the same output moves the last entry instead).
pub const Gather = struct {
    last: ?Entry = null,

    /// Whether `e` is a new entry; otherwise it moved `last` or was
    /// dropped.
    pub fn add(g: *Gather, e: Entry) enum { new, moved, dropped } {
        if (g.last) |l| {
            if (l.uncompressed == e.uncompressed) {
                g.last = e;
                return .moved;
            }
            aegis.assert.pre(l.uncompressed < e.uncompressed, "l.uncompressed < e.uncompressed");
            aegis.assert.pre(l.compressed <= e.compressed, "l.compressed <= e.compressed");
            if (l.uncompressed + min_distance > e.uncompressed) return .dropped;
        }
        g.last = e;
        return .new;
    }
};

/// The entries S2 keeps of `count` gathered over blocks of `est` bytes,
/// as `reduce` thins them: every `keep_every`-th from the first, the
/// estimate scaled with it.
pub const Thinning = struct {
    keep_every: u64,
    est_block: u64,

    pub fn of(count: u64, est: u64) Thinning {
        if (count < max_entries and est >= min_distance) return .{ .keep_every = 1, .est_block = est };
        var remove = (count + 1) / max_entries;
        while (est * (remove + 1) < min_distance and count / (remove + 1) > 1000) remove += 1;
        return .{ .keep_every = remove + 1, .est_block = est + est * remove };
    }

    pub fn kept(t: Thinning, count: u64) u64 {
        return (count + t.keep_every - 1) / t.keep_every;
    }
};

/// The bytes an index of `count` entries takes at most.
pub fn bound(count: usize) usize {
    return frame.header_len + magic_header.len + 4 * 10 + 1 + count * 2 * 10 + 4 + magic_trailer.len;
}

/// Write the index of the entries `source` gives (gathered, `count` of
/// them; `source.rewind()` starts them again) into `out` (`bound(count)`
/// bytes); its length.
pub fn write(out: []u8, source: anytype, count: u64, est: u64, total_compressed: ?u64, total_uncompressed: u64) usize {
    const t: Thinning = .of(count, est);
    const kept = t.kept(count);
    var w: Writer = .{ .out = out, .at = frame.header_len };
    w.bytes(magic_header);
    w.varint(@intCast(total_uncompressed));
    w.varint(if (total_compressed) |c| @intCast(c) else -1);
    w.varint(@intCast(t.est_block));
    w.varint(@intCast(kept));
    const est_i: i64 = @intCast(t.est_block);

    // Whether the output offsets are other than each block's estimate on.
    var has_uncompressed = false;
    {
        var it: Thinned(@TypeOf(source)) = .{ .source = source, .every = t.keep_every };
        var prev: ?Entry = null;
        while (it.next()) |e| : (prev = e) {
            const want: u64 = if (prev) |p| p.uncompressed + t.est_block else 0;
            if (e.uncompressed != want) {
                has_uncompressed = true;
                break;
            }
        }
    }
    w.byte(@intFromBool(has_uncompressed));
    if (has_uncompressed) {
        var it: Thinned(@TypeOf(source)) = .{ .source = source, .every = t.keep_every };
        var prev: ?Entry = null;
        while (it.next()) |e| : (prev = e) {
            const u: i64 = @intCast(e.uncompressed);
            w.varint(if (prev) |p| u - (@as(i64, @intCast(p.uncompressed)) + est_i) else u);
        }
    }
    {
        var it: Thinned(@TypeOf(source)) = .{ .source = source, .every = t.keep_every };
        var predict = @divTrunc(est_i, 2);
        var prev: ?Entry = null;
        while (it.next()) |e| : (prev = e) {
            var c: i64 = @intCast(e.compressed);
            if (prev) |p| {
                c -= @as(i64, @intCast(p.compressed)) + predict;
                predict += @divTrunc(c, 2);
            }
            w.varint(c);
        }
    }
    const size: u32 = @intCast(w.at + 4 + magic_trailer.len);
    w.bytes(std.mem.asBytes(&std.mem.nativeToLittle(u32, size)));
    w.bytes(magic_trailer);
    frame.writeHeader(out[0..frame.header_len], frame.Type.index, w.at - frame.header_len);
    return w.at;
}

/// Every `every`-th entry of a source, from its first.
fn Thinned(comptime Source: type) type {
    return struct {
        source: Source,
        every: u64,
        n: u64 = 0,
        started: bool = false,

        fn next(it: *@This()) ?Entry {
            if (!it.started) {
                it.source.rewind();
                it.started = true;
            }
            while (it.source.next()) |e| {
                const keep = it.n % it.every == 0;
                it.n += 1;
                if (keep) return e;
            }
            return null;
        }
    };
}

/// Entries kept in a slice, as the resumable compressor gathers them.
pub const Slice = struct {
    entries: []const Entry,
    at: usize = 0,

    pub fn rewind(s: *Slice) void {
        s.at = 0;
    }

    pub fn next(s: *Slice) ?Entry {
        if (s.at == s.entries.len) return null;
        s.at += 1;
        return s.entries[s.at - 1];
    }
};

pub const StreamError = error{
    /// A chunk too short for its kind, an identifier of another length or
    /// name, a block's length unreadable or past 4 MiB, or no identifier
    /// first.
    InvalidStream,
    /// The stream ends inside a chunk.
    Truncated,
    /// An unskippable chunk of a type the format reserves.
    Unsupported,
};

/// The entries of a stream's data chunks, gathered: S2's `IndexStream`'s
/// walk, which checks the chunks' structure but not the blocks inside.
pub const Chunks = struct {
    stream: []const u8,
    at: usize = 0,
    uncompressed: u64 = 0,
    gather: Gather = .{},
    /// The entry gathered and not yet given: a later chunk at the same
    /// output may still move it.
    pending: ?Entry = null,
    /// The first data chunk's output, S2's estimate when none is given.
    first_block: ?u64 = null,

    pub fn rewind(c: *Chunks) void {
        c.* = .{ .stream = c.stream };
    }

    /// The next entry, or null at the stream's end; the stream was checked.
    pub fn next(c: *Chunks) ?Entry {
        return c.step() catch unreachable;
    }

    /// The next entry, checking the chunks up to it.
    pub fn step(c: *Chunks) StreamError!?Entry {
        while (try c.chunk()) |e| switch (c.gather.add(e)) {
            .new => {
                const given = c.pending;
                c.pending = e;
                if (given != null) return given;
            },
            .moved => c.pending = e,
            .dropped => {},
        };
        const given = c.pending;
        c.pending = null;
        return given;
    }

    /// The next data chunk's start, past the chunks without data.
    fn chunk(c: *Chunks) StreamError!?Entry {
        while (c.at < c.stream.len) {
            const start = c.at;
            if (c.stream.len - start < frame.header_len) return error.Truncated;
            const h = frame.readHeader(c.stream[start..][0..frame.header_len]);
            if (start == 0 and h.type != frame.Type.identifier) return error.InvalidStream;
            if (h.len < frame.checksum_len) return error.InvalidStream;
            if (c.stream.len - start - frame.header_len < h.len) return error.Truncated;
            const body = c.stream[start + frame.header_len ..][0..h.len];
            c.at = start + frame.header_len + h.len;
            const out_len: u64 = switch (h.type) {
                frame.Type.compressed => (block.header(body[frame.checksum_len..]) catch return error.InvalidStream).len,
                frame.Type.uncompressed => h.len - frame.checksum_len,
                frame.Type.identifier => {
                    if (h.len != frame.identifier_len - frame.header_len) return error.InvalidStream;
                    if (!std.mem.eql(u8, body, frame.identifier_s2[frame.header_len..]) and !std.mem.eql(u8, body, frame.identifier_snappy[frame.header_len..])) return error.InvalidStream;
                    continue;
                },
                else => {
                    if (!frame.Type.skippable(h.type)) return error.Unsupported;
                    continue;
                },
            };
            if (out_len > frame.max_block_size) return error.InvalidStream;
            if (c.first_block == null) c.first_block = out_len;
            const e: Entry = .{ .compressed = start, .uncompressed = c.uncompressed };
            c.uncompressed += out_len;
            return e;
        }
        return null;
    }
};

/// The index of an existing stream, as S2's `IndexStream` writes it: the
/// stream checked chunk by chunk (the blocks are not decoded), its totals,
/// and the first block's output as the estimate. Into `out`, at least
/// `bound(streamEntries(stream))` bytes; its length.
pub fn ofStream(stream: []const u8, out: []u8) StreamError!usize {
    var c: Chunks = .{ .stream = stream };
    var count: u64 = 0;
    while (try c.step()) |_| count += 1;
    return write(out, &c, count, c.first_block orelse 0, stream.len, c.uncompressed);
}

/// The entries `ofStream` gathers from a stream, for its bound.
pub fn streamEntries(stream: []const u8) StreamError!usize {
    var c: Chunks = .{ .stream = stream };
    var count: usize = 0;
    while (try c.step()) |_| count += 1;
    return count;
}

const Reader = struct {
    b: []const u8,

    /// Go's `binary.Varint`: a zigzag `Uvarint`, at most ten bytes.
    fn varint(r: *Reader) LoadError!i64 {
        var v: u64 = 0;
        for (r.b, 0..) |b, i| {
            if (i == 10) return error.InvalidIndex;
            if (b < 0x80) {
                if (i == 9 and b > 1) return error.InvalidIndex;
                v |= @as(u64, b) << @intCast(7 * i);
                r.b = r.b[i + 1 ..];
                const x: i64 = @bitCast(v >> 1);
                return if (v & 1 != 0) ~x else x;
            }
            v |= @as(u64, b & 0x7f) << @intCast(7 * i);
        }
        return error.InvalidIndex;
    }
};

const Writer = struct {
    out: []u8,
    at: usize,

    fn byte(w: *Writer, b: u8) void {
        w.out[w.at] = b;
        w.at += 1;
    }

    fn bytes(w: *Writer, b: []const u8) void {
        @memcpy(w.out[w.at..][0..b.len], b);
        w.at += b.len;
    }

    /// Go's `binary.PutVarint`.
    fn varint(w: *Writer, x: i64) void {
        var v: u64 = @as(u64, @bitCast(x)) << 1;
        if (x < 0) v = ~v;
        while (v >= 0x80) : (v >>= 7) w.byte(@as(u8, @truncate(v)) | 0x80);
        w.byte(@intCast(v));
    }
};

test "an index written and loaded back, and found in" {
    const entries = [_]Entry{
        .{ .compressed = 10, .uncompressed = 0 },
        .{ .compressed = 400_000, .uncompressed = 1 << 20 },
        .{ .compressed = 900_000, .uncompressed = 2 << 20 },
        .{ .compressed = 1_000_000, .uncompressed = (3 << 20) + 5 },
    };
    var out: [bound(entries.len)]u8 = undefined;
    var source: Slice = .{ .entries = &entries };
    const n = write(&out, &source, entries.len, 1 << 20, 1_200_000, 4 << 20);
    var storage: [8]Entry = undefined;
    const index, const rest = try load(out[0..n], &storage);
    try std.testing.expectEqual(@as(usize, 0), rest.len);
    try std.testing.expectEqualSlices(Entry, &entries, index.entries);
    try std.testing.expectEqual(@as(?u64, 1_200_000), index.total_compressed);
    try std.testing.expectEqual(entries[1], try index.find((1 << 20) + 7));
    try std.testing.expectEqual(entries[3], try index.find(-1));
    try std.testing.expectError(error.OutOfRange, index.find((4 << 20) + 1));
    try std.testing.expectEqual(index, try loadFromEnd(out[0..n], &storage));
}
