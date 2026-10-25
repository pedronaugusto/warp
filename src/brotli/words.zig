//! The encoder's index of the static dictionary for qualities 2-9: two
//! buckets per 14-bit hash of a word's first four bytes, one for words of
//! eight bytes or more and one for shorter, each naming one word. It is
//! built at comptime as the reference builds it (longest words first, the
//! last word of each length first, a word staying once the reference's
//! "frozen" bitmap fixes it), and pinned against the reference's table.

const std = @import("std");
const dictionary = @import("dictionary.zig");
const find = @import("find.zig");
const tables = @import("tables.zig");

pub const buckets = 1 << 15;

pub inline fn hash14(data: []const u8, at: usize) u32 {
    return (find.load32(data, at) *% find.hash_mul32) >> (32 - 14);
}

pub const Hash = struct { words: [buckets]u16, lengths: [buckets]u8 };

pub const hash: Hash = blk: {
    @setEvalBranchQuota(4_000_000);
    var h: Hash = .{ .words = @splat(0), .lengths = @splat(0) };
    var global: usize = 0;
    var len: usize = dictionary.max_word;
    while (len >= dictionary.min_word) : (len -= 1) {
        const n = @as(usize, 1) << dictionary.size_bits[len];
        const base = dictionary.offsets[len];
        for (0..n) |i| {
            const j = n - 1 - i;
            const at = base + len * j;
            const key = (std.mem.readInt(u32, dictionary.data[at..][0..4], .little) *% find.hash_mul32) >> (32 - 14);
            const idx = (key << 1) + @intFromBool(len < 8);
            if (h.lengths[idx] & 0x80 == 0) {
                const final = tables.dictionary_hash_frozen[global / 8] & (1 << (global % 8)) != 0;
                h.words[idx] = j;
                h.lengths[idx] = len + if (final) 0x80 else 0;
            }
            global += 1;
        }
    }
    for (&h.lengths) |*l| l.* &= 0x7f;
    break :blk h;
};

pub inline fn hash15(data: []const u8, at: usize) u32 {
    return (find.load32(data, at) *% find.hash_mul32) >> (32 - 15);
}

/// A dictionary word as the lookup of qualities 10-11 lists it: its length
/// (the top bit ends a bucket's list), its transform (identity, uppercase
/// first, uppercase all) and its index.
pub const Word = extern struct { len: u8, transform: u8, idx: u16 };

pub const lut_buckets = 1 << 15;
pub const lut_items = 31705;
pub const Lut = struct { buckets: [lut_buckets]u16, words: [lut_items]Word };

const identity = 0;
const uppercase_first = 10;
const uppercase_all = 11;

fn hash15Of(w: []const u8) u32 {
    return (std.mem.readInt(u32, w[0..4], .little) *% find.hash_mul32) >> (32 - 15);
}

fn prefixOf(w: []const u8) u32 {
    return std.mem.readInt(u32, w[0..4], .little) & ~@as(u32, 0x20202020);
}

/// Every word of 4-24 bytes, its uppercase-first form where it starts with
/// a lowercase letter and differs from a word, and its uppercase-all form
/// where it is ASCII with a lowercase letter past the first and differs
/// from both, in buckets by the hash of the first four bytes of the form;
/// the reference's `BrotliEncoderInitStaticDictionaryLut`. Static data, as
/// the reference's generated tables are: each bucket's start (u16), then the
/// words (`Word`), little-endian. `build` makes it again in the tests,
/// which pin both against the reference's.
const lut = @embedFile("dictionary_lut.bin");

/// Where bucket `i`'s words start, 0 for none.
pub inline fn bucketStart(i: usize) u16 {
    return std.mem.readInt(u16, lut[2 * i ..][0..2], .little);
}

/// The lookup's `j`-th word.
pub inline fn lutWord(j: usize) Word {
    const b = lut[2 * lut_buckets + 4 * j ..][0..4];
    return .{ .len = b[0], .transform = b[1], .idx = std.mem.readInt(u16, b[2..4], .little) };
}

comptime {
    std.debug.assert(lut.len == 2 * lut_buckets + 4 * lut_items);
}

/// The chains of the words hashing to each bucket, newest first, as the
/// reference's generator adds them.
const Chains = struct {
    slots: [lut_items]Word,
    heads: [lut_buckets]u16,
    counts: [lut_buckets]u16,
    prev: [lut_items]u16,
    next: usize,

    fn reset(c: *Chains) void {
        @memset(&c.heads, 0);
        @memset(&c.counts, 0);
        @memset(&c.prev, 0);
        c.next = 0;
    }

    fn push(c: *Chains, key: usize, w: Word) void {
        c.slots[c.next] = w;
        c.prev[c.next] = c.heads[key];
        c.heads[key] = @intCast(c.next);
        c.counts[key] += 1;
        c.next += 1;
    }

    fn word(i: usize, len: usize) []const u8 {
        return dictionary.data[dictionary.offsets[len] + len * i ..][0..len];
    }

    fn identities(c: *Chains, l: usize, n: usize) void {
        for (0..n) |i| c.push(hash15Of(word(i, l)), .{ .len = @intCast(l), .transform = identity, .idx = @intCast(i) });
    }

    /// Lowercase-initial words with the first letter uppercased, unless a
    /// word already in the chain spells the same.
    fn uppercaseFirsts(c: *Chains, l: usize, n: usize) void {
        for (0..n) |i| {
            const w = word(i, l);
            if (w[0] < 'a' or w[0] > 'z') continue;
            var t: [24]u8 = undefined;
            @memcpy(t[0..l], w);
            t[0] -= 32;
            const key = hash15Of(t[0..l]);
            const prefix = prefixOf(t[0..l]);
            var curr: usize = c.heads[key];
            const found = while (curr != 0) : (curr = c.prev[curr]) {
                if (c.slots[curr].len != l) break false;
                const other = word(c.slots[curr].idx, l);
                if (prefix == prefixOf(other) and std.mem.eql(u8, t[0..l], other)) break true;
            } else false;
            if (!found) c.push(key, .{ .len = @intCast(l), .transform = uppercase_first, .idx = @intCast(i) });
        }
    }

    /// ASCII words with a lowercase letter past the first, all uppercased,
    /// unless a word already in the chain, as it is transformed, spells
    /// the same.
    fn uppercaseAlls(c: *Chains, l: usize, n: usize) void {
        for (0..n) |i| {
            const w = word(i, l);
            var ascii = true;
            var has_lower = false;
            for (w, 0..) |byte, k| {
                if (byte >= 128) ascii = false;
                if (k > 0 and byte >= 'a' and byte <= 'z') has_lower = true;
            }
            if (!ascii or !has_lower) continue;
            var t: [24]u8 = undefined;
            @memcpy(t[0..l], w);
            const prefix = prefixOf(t[0..l]);
            for (t[0..l]) |*byte| {
                if (byte.* >= 'a' and byte.* <= 'z') byte.* -= 32;
            }
            const key = hash15Of(t[0..l]);
            var curr: usize = c.heads[key];
            const found = while (curr != 0) : (curr = c.prev[curr]) {
                if (c.slots[curr].len != l) break false;
                const other = word(c.slots[curr].idx, l);
                if (prefix != prefixOf(other)) continue;
                if (spells(t[0..l], other, c.slots[curr].transform)) break true;
            } else false;
            if (!found) c.push(key, .{ .len = @intCast(l), .transform = uppercase_all, .idx = @intCast(i) });
        }
    }

    /// Whether `other` under `transform` is `t`.
    fn spells(t: []const u8, other: []const u8, transform: u8) bool {
        if (transform == identity) return std.mem.eql(u8, t, other);
        if (transform == uppercase_first) return t[0] == other[0] -% 32 and std.mem.eql(u8, t[1..], other[1..]);
        var o: [24]u8 = undefined;
        for (other, 0..) |c, k| o[k] = if (c >= 'a' and c <= 'z') c - 32 else c;
        return std.mem.eql(u8, t, o[0..t.len]);
    }
};

/// The lookup as the reference makes it, into `r`, with `c` for scratch.
fn build(r: *Lut, c: *Chains) void {
    c.reset();
    for (dictionary.min_word..dictionary.max_word + 1) |l| {
        const n = @as(usize, 1) << dictionary.size_bits[l];
        c.identities(l, n);
        c.uppercaseFirsts(l, n);
        c.uppercaseAlls(l, n);
    }
    std.debug.assert(c.next == lut_items - 1);
    // Offsets start at 1: entry 0 is unused.
    r.words[0] = .{ .len = 0, .transform = 0, .idx = 0 };
    var pos: usize = 1;
    for (0..lut_buckets) |i| {
        const num = c.counts[i];
        if (num == 0) {
            r.buckets[i] = 0;
            continue;
        }
        r.buckets[i] = @intCast(pos);
        var curr: usize = c.heads[i];
        pos += num;
        for (0..num) |k| {
            r.words[pos - 1 - k] = c.slots[curr];
            curr = c.prev[curr];
        }
        r.words[pos - 1].len |= 0x80;
    }
}

test "the dictionary lookup is the reference's, and what `build` makes" {
    var sha: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(lut[0 .. 2 * lut_buckets], &sha, .{});
    try std.testing.expectEqualSlices(u8, &try hex("7b6539ba4c302b1ebc592faec82fbf0c1f6530f7d143db3f411c1ee666958077"), &sha);
    std.crypto.hash.sha2.Sha256.hash(lut[2 * lut_buckets ..], &sha, .{});
    try std.testing.expectEqualSlices(u8, &try hex("0b553e04dcf6c5371875a40b54ac4115dd450f2b0cef444a16c8531d4c49f891"), &sha);
    const gpa = std.testing.allocator;
    const r = try gpa.create(Lut);
    defer gpa.destroy(r);
    const c = try gpa.create(Chains);
    defer gpa.destroy(c);
    build(r, c);
    for (r.buckets, 0..) |start, i| try std.testing.expectEqual(start, bucketStart(i));
    for (r.words, 0..) |w, j| try std.testing.expectEqual(w, lutWord(j));
}

test "the dictionary hash is the reference's" {
    var sha: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(std.mem.sliceAsBytes(&hash.words), &sha, .{});
    try std.testing.expectEqualSlices(u8, &try hex("5f60018015074e571ec29147973866b82ada416b08325bf75d8e3c94bc83fb37"), &sha);
    std.crypto.hash.sha2.Sha256.hash(&hash.lengths, &sha, .{});
    try std.testing.expectEqualSlices(u8, &try hex("05720624c4ffa3f378a4b9363e32627cbecd7efc761009aa49d5e78d65b0c82b"), &sha);
}

fn hex(comptime s: []const u8) ![32]u8 {
    var out: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&out, s);
    return out;
}
