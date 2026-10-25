//! A prefix dictionary prepared for the encoder: bytes a stream may copy
//! from as though they came just before its first byte, past the window
//! (the decoder's `dictionary`, RFC 9842's raw dictionary). The reference's
//! "lean" prepared dictionary: 5-byte hashes into 2^17-2^22 buckets, each
//! keeping its 32 latest positions, the buckets' chains packed per slot so
//! a chain is a 16-bit offset into its slot's items. It borrows the bytes.

const Prepared = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const find = @import("find.zig");
const command = @import("command.zig");

/// The longest dictionary the format addresses: the largest distance less
/// the largest window.
pub const max_len = 0x3FFFFFC - ((1 << 24) - 16);

const hash_bits = 40;
const bucket_limit = 32;
/// The last item of a chain.
const last_item = 0x80000000;
const no_chain = 0xFFFF;

source: []const u8,
bucket_bits: u5,
slot_bits: u5,
/// Where each slot's items start.
slot_offsets: []u32,
/// Each bucket's chain within its slot, or `no_chain`.
heads: []u16,
/// Positions in the dictionary, newest first per bucket.
items: []u32,
total_size: usize,

pub const Error = Allocator.Error || error{DictionaryTooLong};

pub fn init(gpa: Allocator, source: []const u8) Error!Prepared {
    if (source.len > max_len) return error.DictionaryTooLong;
    var bucket_bits: u5 = 17;
    var slot_bits: u5 = 7;
    var volume: usize = 16 << 17;
    while (volume < source.len and bucket_bits < 22) {
        bucket_bits += 1;
        slot_bits += 1;
        volume <<= 1;
    }
    return build(gpa, source, bucket_bits, slot_bits);
}

pub fn deinit(p: *Prepared, gpa: Allocator) void {
    gpa.free(p.slot_offsets);
    gpa.free(p.heads);
    gpa.free(p.items);
}

inline fn key(p: *const Prepared, data: []const u8, at: usize) usize {
    const h = (find.load64(data, at) & ((@as(u64, 1) << hash_bits) - 1)) *% find.hash_mul64;
    return @intCast(h >> @intCast(64 - @as(u7, p.bucket_bits)));
}

fn build(gpa: Allocator, source: []const u8, bucket_bits: u5, slot_bits: u5) Allocator.Error!Prepared {
    const num_slots = @as(usize, 1) << slot_bits;
    const num_buckets = @as(usize, 1) << bucket_bits;
    const slot_mask = num_slots - 1;
    const slot_size = try gpa.alloc(u32, num_slots);
    defer gpa.free(slot_size);
    const slot_limit = try gpa.alloc(u32, num_slots);
    defer gpa.free(slot_limit);
    const num = try gpa.alloc(u16, num_buckets);
    defer gpa.free(num);
    const bucket_heads = try gpa.alloc(u32, num_buckets);
    defer gpa.free(bucket_heads);
    const next_bucket = try gpa.alloc(u32, source.len);
    defer gpa.free(next_bucket);
    @memset(num, 0);
    var p: Prepared = .{ .source = source, .bucket_bits = bucket_bits, .slot_bits = slot_bits, .slot_offsets = &.{}, .heads = &.{}, .items = &.{}, .total_size = source.len };
    // Every position's bucket, chained newest first.
    var i: usize = 0;
    while (i + 7 < source.len) : (i += 1) {
        const k = p.key(source, i);
        next_bucket[i] = if (num[k] == 0) std.math.maxInt(u32) else bucket_heads[k];
        bucket_heads[k] = @intCast(i);
        num[k] = @min(num[k] + 1, bucket_limit);
    }
    // Each slot's chains cut to one length that keeps them within 16-bit
    // offsets.
    var total_items: usize = 0;
    for (0..num_slots) |s| {
        slot_limit[s] = bucket_limit;
        while (true) : (slot_limit[s] -= 1) {
            var count: u32 = 0;
            var overflow = false;
            var j = s;
            while (j < num_buckets) : (j += num_slots) {
                // The last chain may pass 64K; only an offset of 0xFFFF
                // overflows.
                if (count >= 0xFFFF) {
                    overflow = true;
                    break;
                }
                count += @min(num[j], slot_limit[s]);
            }
            if (!overflow) {
                slot_size[s] = count;
                total_items += count;
                break;
            }
        }
    }
    p.slot_offsets = try gpa.alloc(u32, num_slots);
    errdefer gpa.free(p.slot_offsets);
    p.heads = try gpa.alloc(u16, num_buckets);
    errdefer gpa.free(p.heads);
    p.items = try gpa.alloc(u32, total_items);
    total_items = 0;
    for (0..num_slots) |s| {
        p.slot_offsets[s] = @intCast(total_items);
        total_items += slot_size[s];
        slot_size[s] = 0;
    }
    for (0..num_buckets) |b| {
        const slot = b & slot_mask;
        const count = @min(num[b], slot_limit[slot]);
        if (count == 0) {
            p.heads[b] = no_chain;
            continue;
        }
        p.heads[b] = @intCast(slot_size[slot]);
        var cursor = slot_size[slot] + p.slot_offsets[slot];
        slot_size[slot] += count;
        var pos = bucket_heads[b];
        for (0..count) |_| {
            p.items[cursor] = pos;
            cursor += 1;
            pos = next_bucket[pos];
        }
        p.items[cursor - 1] |= last_item;
    }
    return p;
}

/// The chain of the bucket the 5 bytes at `at` hash to; empty for none.
fn chain(p: *const Prepared, data: []const u8, at: usize) []const u32 {
    const k = p.key(data, at);
    const head = p.heads[k];
    if (head == no_chain) return &.{};
    return p.items[p.slot_offsets[k & ((@as(usize, 1) << p.slot_bits) - 1)] + head ..];
}

/// Improve `sr` with a match in the dictionary at `cur_ix`: one of the
/// cache's four last distances, or the longest 4+ byte match on the chain.
/// The dictionary ends `max_ring_distance` back.
pub fn lookup(p: *const Prepared, data: []const u8, mask: usize, cache: *const [16]i32, cur_ix: usize, max_length: usize, max_ring_distance: usize, max_distance: usize, sr: *find.SearchResult) void {
    const source = p.source;
    const distance_offset = max_ring_distance + p.total_size;
    const boundary = distance_offset - source.len;
    const cur = cur_ix & mask;
    var best_score = sr.score;
    var best_len = sr.len;
    for (0..4) |i| {
        const distance: usize = @intCast(cache[i]);
        if (distance <= boundary or distance > distance_offset) continue;
        const offset = distance_offset - distance;
        const limit = @min(source.len - offset, max_length);
        const len = find.matchLengthIn(source[offset..], data[cur..], limit);
        if (len >= 2) {
            var score = find.scoreUsingLastDistance(len);
            if (best_score < score) {
                if (i != 0) score -= find.penaltyUsingLastDistance(i);
                if (best_score < score) {
                    best_score = score;
                    best_len = @max(best_len, len);
                    sr.* = .{ .len = len, .len_code_delta = 0, .distance = distance, .score = best_score };
                }
            }
        }
    }
    // Chain matches are 4 bytes or more: compare the 4 ending a byte past
    // the best.
    best_len = @max(best_len, 3);
    const items = p.chain(data, cur);
    var more = items.len != 0;
    var n: usize = 0;
    while (more) : (n += 1) {
        const item = items[n];
        more = item & last_item == 0;
        const offset = item & ~@as(u32, last_item);
        const distance = distance_offset - offset;
        const limit = @min(source.len - offset, max_length);
        if (distance > max_distance) continue;
        if (cur + best_len > mask or best_len >= limit or
            find.load32(data, cur + best_len - 3) != find.load32(source, offset + best_len - 3)) continue;
        const len = find.matchLengthIn(source[offset..], data[cur..], limit);
        if (len >= 4) {
            const score = find.backwardReferenceScore(len, distance);
            if (best_score < score) {
                best_score = score;
                best_len = len;
                sr.* = .{ .len = len, .len_code_delta = 0, .distance = distance, .score = best_score };
            }
        }
    }
}

/// The dictionary's matches at `cur_ix` longer than `min_length`, in
/// increasing length, into `matches`; returns how many.
pub fn findAll(p: *const Prepared, data: []const u8, mask: usize, cur_ix: usize, min_length: usize, max_length: usize, max_ring_distance: usize, max_distance: usize, matches: []find.BackwardMatch) usize {
    const source = p.source;
    const distance_offset = max_ring_distance + p.total_size;
    const cur = cur_ix & mask;
    var best_len = min_length;
    var found: usize = 0;
    const items = p.chain(data, cur);
    var more = items.len != 0;
    var n: usize = 0;
    while (more) : (n += 1) {
        const item = items[n];
        more = item & last_item == 0;
        const offset = item & ~@as(u32, last_item);
        const distance = distance_offset - offset;
        const limit = @min(source.len - offset, max_length);
        if (distance > max_distance) continue;
        if (cur + best_len > mask or best_len >= limit or data[cur + best_len] != source[offset + best_len]) continue;
        const len = find.matchLengthIn(source[offset..], data[cur..], limit);
        if (len > best_len) {
            best_len = len;
            matches[found] = .init(distance, len);
            found += 1;
            if (found == matches.len) break;
        }
    }
    return found;
}

/// The length of a match `backward` back from `at`, into the dictionary
/// (which ends `dictionary_start` back), when it is longer than
/// `best_len`: its next byte must be `continuation`.
pub fn matchAt(p: *const Prepared, at: []const u8, dictionary_start: usize, backward: usize, best_len: usize, max_length: usize, continuation: u8) ?usize {
    const offset = dictionary_start + p.total_size - backward;
    const limit = @min(p.total_size - offset, max_length);
    if (best_len >= limit or continuation != p.source[offset + best_len]) return null;
    return find.matchLengthIn(p.source[offset..], at, limit);
}

/// Extend the last command's copy `distance_past` beyond the window into
/// the dictionary while the input repeats it.
pub fn extendCopy(p: *const Prepared, data: []const u8, mask: u32, distance_past: u64, last_copy_len: u64, last: *command.Command, bytes: *u32, pos: *u32) void {
    if (distance_past - 1 >= p.total_size or last_copy_len >= distance_past) return;
    var offset: usize = @intCast(p.total_size - distance_past + last_copy_len);
    while (bytes.* != 0 and data[pos.* & mask] == p.source[offset]) {
        last.copy_len += 1;
        bytes.* -= 1;
        pos.* +%= 1;
        offset += 1;
        if (offset == p.total_size) break;
    }
}
