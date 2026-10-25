//! The match finders of qualities 2-9, the reference encoder's (google/brotli
//! 1.2.1) hashers, each a type the parser is instantiated for:
//!
//! - `Quickly`: one table of 5- or 7-byte hashes, 1-4 slots a bucket
//!   (H2, H3, H4, H54: qualities 2-4).
//! - `LongestMatch`: buckets of the last 2^block_bits positions of a 4-byte
//!   hash (H5), or of a 5-byte hash in 2^15 buckets (H6): qualities 7-9.
//! - `Tagged`: the same with an 8-bit tag beside each position, the
//!   candidates found by comparing tags 16 at a time (H58, H68: qualities
//!   5-6, as the reference builds them with a 64-bit count-trailing-zeros
//!   on clang and gcc).
//! - `ForgetfulChain`: chains of 16-bit deltas in banks of slots that are
//!   overwritten in turn (H40, H41, H42: qualities 5-9 with windows of 64
//!   KiB or less).
//!
//! Each tries the last distances first, then its candidates, and the static
//! dictionary when nothing scored; the scores are the reference's.

const std = @import("std");
const Allocator = std.mem.Allocator;
const find = @import("find.zig");
const words = @import("words.zig");
const dictionary = @import("dictionary.zig");
const settings = @import("settings.zig");

const Params = settings.HasherParams;
const SearchResult = find.SearchResult;
const backwardReferenceScore = find.backwardReferenceScore;
const scoreUsingLastDistance = find.scoreUsingLastDistance;
const penaltyUsingLastDistance = find.penaltyUsingLastDistance;

/// Distances 4-15 of the cache: the last two, each give or take 1-3.
pub fn extendDistanceCache(cache: *[16]i32, num: usize) void {
    if (num <= 4) return;
    const last = cache[0];
    cache[4] = last - 1;
    cache[5] = last + 1;
    cache[6] = last - 2;
    cache[7] = last + 2;
    cache[8] = last - 3;
    cache[9] = last + 3;
    if (num <= 10) return;
    const next = cache[1];
    cache[10] = next - 1;
    cache[11] = next + 1;
    cache[12] = next - 2;
    cache[13] = next + 2;
    cache[14] = next - 3;
    cache[15] = next + 3;
}

pub inline fn cached(cache: *const [16]i32, i: usize) usize {
    return @bitCast(@as(isize, cache[i]));
}

/// What the dictionary lookups have found, to stop looking when it is
/// little.
pub const Common = struct {
    dict_num_lookups: usize = 0,
    dict_num_matches: usize = 0,
};

const cutoff_transforms_count = 10;
const cutoff_transforms: u64 = 0x071B520A_DA2D3200;

fn testStaticDictionaryItem(len: usize, word_idx: usize, data: []const u8, at: usize, max_length: usize, max_backward: usize, max_distance: usize, out: *SearchResult) bool {
    if (len > max_length) return false;
    const offset = dictionary.offsets[len] + len * word_idx;
    const matchlen = find.matchLengthIn(data[at..], dictionary.data[offset..][0..len], len);
    if (matchlen + cutoff_transforms_count <= len or matchlen == 0) return false;
    const cut = len - matchlen;
    const transform_id = (cut << 2) + @as(usize, @intCast((cutoff_transforms >> @intCast(cut * 6)) & 0x3f));
    const backward = max_backward + 1 + word_idx + (transform_id << dictionary.size_bits[len]);
    if (backward > max_distance) return false;
    const score = backwardReferenceScore(matchlen, backward);
    if (score < out.score) return false;
    out.len = matchlen;
    out.len_code_delta = @intCast(@as(isize, @intCast(len)) - @as(isize, @intCast(matchlen)));
    out.distance = backward;
    out.score = score;
    return true;
}

pub fn searchStaticDictionary(common: *Common, data: []const u8, at: usize, max_length: usize, max_backward: usize, max_distance: usize, out: *SearchResult, shallow: bool) void {
    if (common.dict_num_matches < common.dict_num_lookups >> 7) return;
    var key: usize = @as(usize, words.hash14(data, at)) << 1;
    const n: usize = if (shallow) 1 else 2;
    for (0..n) |_| {
        common.dict_num_lookups += 1;
        const len = words.hash.lengths[key];
        if (len != 0 and testStaticDictionaryItem(len, words.hash.words[key], data, at, max_length, max_backward, max_distance, out)) {
            common.dict_num_matches += 1;
        }
        key += 1;
    }
}

/// H2, H3, H4, H54: a table of `hash_len`-byte hashes, `2^sweep_bits`
/// slots a bucket.
pub fn Quickly(comptime bucket_bits: u5, comptime sweep_bits: u2, comptime hash_len: u4, comptime use_dictionary: bool) type {
    return struct {
        const Self = @This();
        const bucket_size = 1 << bucket_bits;
        const bucket_mask = bucket_size - 1;
        const sweep = 1 << sweep_bits;
        const sweep_mask = (sweep - 1) << 3;
        pub const hash_type_length = 8;
        pub const store_lookahead = 8;

        buckets: []u32,

        fn init(gpa: Allocator) Allocator.Error!Self {
            return .{ .buckets = try gpa.alloc(u32, bucket_size) };
        }

        fn deinit(h: *Self, gpa: Allocator) void {
            gpa.free(h.buckets);
        }

        inline fn hashBytes(data: []const u8, at: usize) u32 {
            const v = find.load64(data, at) << (64 - 8 * @as(u7, hash_len));
            return @intCast((v *% find.hash_mul64) >> (64 - @as(u7, bucket_bits)));
        }

        fn prepare(h: *Self, one_shot: bool, input_size: usize, data: []const u8) void {
            if (one_shot and input_size <= bucket_size >> 5) {
                for (0..input_size) |i| {
                    const key = hashBytes(data, i);
                    for (0..sweep) |j| h.buckets[(key + (j << 3)) & bucket_mask] = 0;
                }
            } else @memset(h.buckets, 0);
        }

        pub inline fn store(h: *Self, data: []const u8, mask: usize, ix: usize) void {
            const key = hashBytes(data, ix & mask);
            if (sweep == 1) {
                h.buckets[key] = @truncate(ix);
            } else {
                const off: u32 = @intCast(ix & sweep_mask);
                h.buckets[(key + off) & bucket_mask] = @truncate(ix);
            }
        }

        pub fn storeRange(h: *Self, data: []const u8, mask: usize, start: usize, end: usize) void {
            var i = start;
            while (i < end) : (i += 1) h.store(data, mask, i);
        }

        fn stitch(h: *Self, num_bytes: usize, position: usize, data: []const u8, mask: usize) void {
            if (num_bytes >= hash_type_length - 1 and position >= 3) {
                h.store(data, mask, position - 3);
                h.store(data, mask, position - 2);
                h.store(data, mask, position - 1);
            }
        }

        pub inline fn prepareDistanceCache(h: *Self, cache: *[16]i32) void {
            _ = h;
            _ = cache;
        }

        pub fn findLongestMatch(h: *Self, common: *Common, data: []const u8, mask: usize, cache: *const [16]i32, cur_ix: usize, max_length: usize, max_backward: usize, dictionary_distance: usize, max_distance: usize, out: *SearchResult) void {
            const buckets = h.buckets;
            const best_len_in = out.len;
            const cur = cur_ix & mask;
            var compare_char = data[cur + best_len_in];
            const key = hashBytes(data, cur);
            const min_score = out.score;
            var best_score = out.score;
            var best_len = best_len_in;
            const cached_backward = cached(cache, 0);
            var prev_ix = cur_ix -% cached_backward;
            out.len_code_delta = 0;
            if (prev_ix < cur_ix) {
                prev_ix &= @as(u32, @truncate(mask));
                if (compare_char == data[prev_ix + best_len]) {
                    const len = find.matchLength(data, prev_ix, cur, max_length);
                    if (len >= 4) {
                        const score = scoreUsingLastDistance(len);
                        if (best_score < score) {
                            out.len = len;
                            out.distance = cached_backward;
                            out.score = score;
                            if (sweep == 1) {
                                buckets[key] = @truncate(cur_ix);
                                return;
                            }
                            best_len = len;
                            best_score = score;
                            compare_char = data[cur + len];
                        }
                    }
                }
            }
            var key_out: usize = undefined;
            if (sweep == 1) {
                prev_ix = buckets[key];
                buckets[key] = @truncate(cur_ix);
                const backward = cur_ix -% prev_ix;
                prev_ix &= @as(u32, @truncate(mask));
                if (compare_char != data[prev_ix + best_len_in]) return;
                if (backward == 0 or backward > max_backward) return;
                const len = find.matchLength(data, prev_ix, cur, max_length);
                if (len >= 4) {
                    const score = backwardReferenceScore(len, backward);
                    if (best_score < score) {
                        out.len = len;
                        out.distance = backward;
                        out.score = score;
                        return;
                    }
                }
            } else {
                var keys: [sweep]usize = undefined;
                for (&keys, 0..) |*k, i| k.* = (key + (i << 3)) & bucket_mask;
                key_out = keys[(cur_ix & sweep_mask) >> 3];
                for (keys) |k| {
                    prev_ix = buckets[k];
                    const backward = cur_ix -% prev_ix;
                    prev_ix &= @as(u32, @truncate(mask));
                    if (compare_char != data[prev_ix + best_len]) continue;
                    if (backward == 0 or backward > max_backward) continue;
                    const len = find.matchLength(data, prev_ix, cur, max_length);
                    if (len >= 4) {
                        const score = backwardReferenceScore(len, backward);
                        if (best_score < score) {
                            best_len = len;
                            out.len = len;
                            compare_char = data[cur + len];
                            best_score = score;
                            out.score = score;
                            out.distance = backward;
                        }
                    }
                }
            }
            if (use_dictionary and min_score == out.score) {
                searchStaticDictionary(common, data, cur, max_length, dictionary_distance, max_distance, out, true);
            }
            if (sweep != 1) buckets[key_out] = @truncate(cur_ix);
        }
    };
}

/// The candidates' loop shared by the bucket hashers: last distances first.
inline fn tryLastDistances(data: []const u8, mask: usize, cache: *const [16]i32, num: usize, cur_ix: usize, max_length: usize, max_backward: usize, best_score: *usize, best_len: *usize, out: *SearchResult) void {
    const cur = cur_ix & mask;
    for (0..num) |i| {
        const backward = cached(cache, i);
        var prev_ix = cur_ix -% backward;
        if (prev_ix >= cur_ix) continue;
        if (backward > max_backward) continue;
        prev_ix &= mask;
        if (cur + best_len.* > mask) break;
        if (prev_ix + best_len.* > mask or data[cur + best_len.*] != data[prev_ix + best_len.*]) continue;
        const len = find.matchLength(data, prev_ix, cur, max_length);
        if (len >= 3 or (len == 2 and i < 2)) {
            var score = scoreUsingLastDistance(len);
            if (best_score.* < score) {
                if (i != 0) score -= penaltyUsingLastDistance(i);
                if (best_score.* < score) {
                    best_score.* = score;
                    best_len.* = len;
                    out.len = len;
                    out.distance = backward;
                    out.score = score;
                }
            }
        }
    }
}

/// One candidate of a bucket hasher. `wide`: the 64-bit hashers' check of
/// the first four bytes and length from there.
inline fn tryCandidate(data: []const u8, mask: usize, cur_ix: usize, prev_in: usize, max_length: usize, best_score: *usize, best_len: *usize, out: *SearchResult, comptime wide: bool) void {
    const cur = cur_ix & mask;
    const backward = cur_ix -% prev_in;
    const prev_ix = prev_in & mask;
    if (prev_ix + best_len.* > mask or find.load32(data, cur + best_len.* - 3) != find.load32(data, prev_ix + best_len.* - 3)) return;
    if (wide) {
        if (find.load32(data, cur) != find.load32(data, prev_ix)) return;
        const len = find.matchLength(data, prev_ix + 4, cur + 4, max_length - 4) + 4;
        const score = backwardReferenceScore(len, backward);
        if (best_score.* < score) {
            best_score.* = score;
            best_len.* = len;
            out.len = len;
            out.distance = backward;
            out.score = score;
        }
        return;
    }
    const len = find.matchLength(data, prev_ix, cur, max_length);
    if (len >= 4) {
        const score = backwardReferenceScore(len, backward);
        if (best_score.* < score) {
            best_score.* = score;
            best_len.* = len;
            out.len = len;
            out.distance = backward;
            out.score = score;
        }
    }
}

/// H5 (`wide` false: 4-byte hash, 2^bucket_bits buckets) and H6 (`wide`:
/// 5-byte hash, 2^15 buckets).
pub fn LongestMatch(comptime wide: bool) type {
    return struct {
        const Self = @This();
        pub const hash_type_length = if (wide) 8 else 4;
        pub const store_lookahead = hash_type_length;

        bucket_size: usize,
        block_size: usize,
        hash_shift: u5,
        block_mask: u32,
        block_bits: u5,
        num_last_distances_to_check: usize,
        num: []u16,
        buckets: []u32,

        fn init(gpa: Allocator, p: Params) Allocator.Error!Self {
            const bucket_size = @as(usize, 1) << p.bucket_bits;
            const block_size = @as(usize, 1) << p.block_bits;
            const num = try gpa.alloc(u16, bucket_size);
            errdefer gpa.free(num);
            return .{
                .bucket_size = bucket_size,
                .block_size = block_size,
                .hash_shift = @intCast(32 - @as(u6, p.bucket_bits)),
                .block_mask = @intCast(block_size - 1),
                .block_bits = p.block_bits,
                .num_last_distances_to_check = p.num_last_distances_to_check,
                .num = num,
                .buckets = try gpa.alloc(u32, bucket_size * block_size),
            };
        }

        fn deinit(h: *Self, gpa: Allocator) void {
            gpa.free(h.num);
            gpa.free(h.buckets);
        }

        inline fn hashBytes(h: *const Self, data: []const u8, at: usize) usize {
            if (wide) return @intCast((find.load64(data, at) *% (find.hash_mul64 << 24)) >> (64 - 15));
            return (find.load32(data, at) *% find.hash_mul32) >> h.hash_shift;
        }

        fn prepare(h: *Self, one_shot: bool, input_size: usize, data: []const u8) void {
            if (one_shot and input_size <= h.bucket_size >> 6) {
                for (0..input_size) |i| h.num[h.hashBytes(data, i)] = 0;
            } else @memset(h.num, 0);
        }

        pub inline fn store(h: *Self, data: []const u8, mask: usize, ix: usize) void {
            const key = h.hashBytes(data, ix & mask);
            const minor = h.num[key] & h.block_mask;
            h.num[key] +%= 1;
            h.buckets[minor + (key << h.block_bits)] = @truncate(ix);
        }

        pub fn storeRange(h: *Self, data: []const u8, mask: usize, start: usize, end: usize) void {
            var i = start;
            while (i < end) : (i += 1) h.store(data, mask, i);
        }

        fn stitch(h: *Self, num_bytes: usize, position: usize, data: []const u8, mask: usize) void {
            if (num_bytes >= hash_type_length - 1 and position >= 3) {
                h.store(data, mask, position - 3);
                h.store(data, mask, position - 2);
                h.store(data, mask, position - 1);
            }
        }

        pub inline fn prepareDistanceCache(h: *Self, cache: *[16]i32) void {
            extendDistanceCache(cache, h.num_last_distances_to_check);
        }

        pub fn findLongestMatch(h: *Self, common: *Common, data: []const u8, mask: usize, cache: *const [16]i32, cur_ix: usize, max_length: usize, max_backward: usize, dictionary_distance: usize, max_distance: usize, out: *SearchResult) void {
            const cur = cur_ix & mask;
            const min_score = out.score;
            var best_score = out.score;
            var best_len = out.len;
            const key = h.hashBytes(data, cur);
            const bucket = h.buckets[key << h.block_bits ..][0..h.block_size];
            // The reference's prefetches.
            @prefetch(bucket.ptr, .{});
            if (h.block_bits > 4) @prefetch(bucket.ptr + 16, .{});
            out.len = 0;
            out.len_code_delta = 0;
            tryLastDistances(data, mask, cache, h.num_last_distances_to_check, cur_ix, max_length, max_backward, &best_score, &best_len, out);
            // Matches of 4 and more: compare 4 bytes always.
            if (best_len < 3) best_len = 3;
            const n = h.num[key];
            const down: usize = if (n > h.block_size) n - h.block_size else 0;
            var i: usize = n;
            while (i > down) {
                i -= 1;
                const prev_ix: usize = bucket[i & h.block_mask];
                if (cur_ix -% prev_ix > max_backward) break;
                if (cur + best_len > mask) break;
                tryCandidate(data, mask, cur_ix, prev_ix, max_length, &best_score, &best_len, out, wide);
            }
            bucket[n & h.block_mask] = @truncate(cur_ix);
            h.num[key] +%= 1;
            if (min_score == out.score) searchStaticDictionary(common, data, cur, max_length, dictionary_distance, max_distance, out, false);
        }
    };
}

/// H58 and H68: `LongestMatch` with an 8-bit tag beside each position, the
/// count going down from 65535, newest first.
pub fn Tagged(comptime wide: bool) type {
    return struct {
        const Self = @This();
        const tag_bits = 8;
        pub const hash_type_length = if (wide) 8 else 4;
        pub const store_lookahead = hash_type_length;

        bucket_size: usize,
        block_size: usize,
        hash_shift: u5,
        block_mask: u32,
        block_bits: u5,
        num_last_distances_to_check: usize,
        num: []u16,
        tags: []u8,
        buckets: []u32,

        fn init(gpa: Allocator, p: Params) Allocator.Error!Self {
            const bucket_size = @as(usize, 1) << p.bucket_bits;
            const block_size = @as(usize, 1) << p.block_bits;
            const num = try gpa.alloc(u16, bucket_size);
            errdefer gpa.free(num);
            const tags = try gpa.alloc(u8, bucket_size * block_size + 16);
            errdefer gpa.free(tags);
            return .{
                .bucket_size = bucket_size,
                .block_size = block_size,
                .hash_shift = @intCast(32 - @as(u6, p.bucket_bits) - tag_bits),
                .block_mask = @intCast(block_size - 1),
                .block_bits = p.block_bits,
                .num_last_distances_to_check = p.num_last_distances_to_check,
                .num = num,
                .tags = tags,
                .buckets = try gpa.alloc(u32, bucket_size * block_size),
            };
        }

        fn deinit(h: *Self, gpa: Allocator) void {
            gpa.free(h.num);
            gpa.free(h.tags);
            gpa.free(h.buckets);
        }

        inline fn hashBytes(h: *const Self, data: []const u8, at: usize) usize {
            if (wide) return @intCast((find.load64(data, at) *% (find.hash_mul64 << 24)) >> (64 - 15 - tag_bits));
            return (find.load32(data, at) *% find.hash_mul32) >> h.hash_shift;
        }

        fn prepare(h: *Self, one_shot: bool, input_size: usize, data: []const u8) void {
            if (one_shot and input_size <= h.bucket_size >> 6) {
                for (0..input_size) |i| h.num[h.hashBytes(data, i) >> tag_bits] = 65535;
            } else @memset(h.num, 65535);
        }

        pub inline fn store(h: *Self, data: []const u8, mask: usize, ix: usize) void {
            const hash = h.hashBytes(data, ix & mask);
            const key = hash >> tag_bits;
            const offset = (h.num[key] & h.block_mask) + (key << h.block_bits);
            h.num[key] -%= 1;
            h.buckets[offset] = @truncate(ix);
            h.tags[offset] = @truncate(hash);
        }

        pub fn storeRange(h: *Self, data: []const u8, mask: usize, start: usize, end: usize) void {
            var i = start;
            while (i < end) : (i += 1) h.store(data, mask, i);
        }

        fn stitch(h: *Self, num_bytes: usize, position: usize, data: []const u8, mask: usize) void {
            if (num_bytes >= hash_type_length - 1 and position >= 3) {
                h.store(data, mask, position - 3);
                h.store(data, mask, position - 2);
                h.store(data, mask, position - 1);
            }
        }

        pub inline fn prepareDistanceCache(h: *Self, cache: *[16]i32) void {
            extendDistanceCache(cache, h.num_last_distances_to_check);
        }

        /// Bit i set when the tag `i` slots after `head` (in the ring of the
        /// block) is `tag`.
        inline fn matchingTags(h: *const Self, tag_bucket: []const u8, tag: u8, head: usize) u64 {
            var matches: u64 = 0;
            const chunks = h.block_size / 16;
            for (0..@min(chunks, 4)) |c| {
                const v: @Vector(16, u8) = tag_bucket[16 * c ..][0..16].*;
                const eq: u16 = @bitCast(v == @as(@Vector(16, u8), @splat(tag)));
                matches |= @as(u64, eq) << @intCast(16 * c);
            }
            return switch (chunks) {
                1 => std.math.rotr(u16, @truncate(matches), head),
                2 => std.math.rotr(u32, @truncate(matches), head),
                else => std.math.rotr(u64, matches, head),
            };
        }

        pub fn findLongestMatch(h: *Self, common: *Common, data: []const u8, mask: usize, cache: *const [16]i32, cur_ix: usize, max_length: usize, max_backward: usize, dictionary_distance: usize, max_distance: usize, out: *SearchResult) void {
            const cur = cur_ix & mask;
            const min_score = out.score;
            var best_score = out.score;
            var best_len = out.len;
            const hash = h.hashBytes(data, cur);
            const key = hash >> tag_bits;
            const bucket = h.buckets[key << h.block_bits ..][0..h.block_size];
            const tag_bucket = h.tags[key << h.block_bits ..][0..h.block_size];
            // The reference's prefetches.
            @prefetch(bucket.ptr, .{});
            @prefetch(tag_bucket.ptr, .{});
            if (h.block_bits > 4) @prefetch(bucket.ptr + 16, .{});
            out.len = 0;
            out.len_code_delta = 0;
            tryLastDistances(data, mask, cache, h.num_last_distances_to_check, cur_ix, max_length, max_backward, &best_score, &best_len, out);
            if (best_len < 3) best_len = 3;
            const tag: u8 = @truncate(hash);
            const head = (@as(usize, h.num[key]) + 1) & h.block_mask;
            var matches = h.matchingTags(tag_bucket, tag, head);
            // Slots never written hold no positions.
            const n: u16 = 65535 - h.num[key];
            const unused: u64 = @intFromBool(h.block_size > n);
            matches &= (unused << @intCast(n & 63)) -% 1;
            while (matches > 0) : (matches &= matches - 1) {
                const rb_index = (head + @ctz(matches)) & h.block_mask;
                const prev_ix: usize = bucket[rb_index];
                if (cur_ix -% prev_ix > max_backward) break;
                if (cur + best_len > mask) break;
                tryCandidate(data, mask, cur_ix, prev_ix, max_length, &best_score, &best_len, out, wide);
            }
            bucket[h.num[key] & h.block_mask] = @truncate(cur_ix);
            tag_bucket[h.num[key] & h.block_mask] = tag;
            h.num[key] -%= 1;
            if (min_score == out.score) searchStaticDictionary(common, data, cur, max_length, dictionary_distance, max_distance, out, false);
        }
    };
}

/// H40, H41, H42: chains of 16-bit deltas in `banks` banks of 2^bank_bits
/// slots, `max_hops` links followed.
pub fn ForgetfulChain(comptime banks: usize, comptime bank_bits: u5, comptime num_last: usize) type {
    return struct {
        const Self = @This();
        const bucket_bits = 15;
        const bucket_size = 1 << bucket_bits;
        const bank_size = 1 << bank_bits;
        pub const hash_type_length = 4;
        pub const store_lookahead = 4;
        const Slot = struct { delta: u16, next: u16 };

        free_slot_idx: [banks]u16 = @splat(0),
        max_hops: usize,
        addr: []u32,
        head: []u16,
        tiny_hash: []u8,
        slots: []Slot,

        fn init(gpa: Allocator, quality: u4) Allocator.Error!Self {
            const addr = try gpa.alloc(u32, bucket_size);
            errdefer gpa.free(addr);
            const head = try gpa.alloc(u16, bucket_size);
            errdefer gpa.free(head);
            const tiny = try gpa.alloc(u8, 65536);
            errdefer gpa.free(tiny);
            return .{
                .max_hops = (if (quality > 6) @as(usize, 7) else 8) << @intCast(quality - 4),
                .addr = addr,
                .head = head,
                .tiny_hash = tiny,
                .slots = try gpa.alloc(Slot, banks * bank_size),
            };
        }

        fn deinit(h: *Self, gpa: Allocator) void {
            gpa.free(h.addr);
            gpa.free(h.head);
            gpa.free(h.tiny_hash);
            gpa.free(h.slots);
        }

        inline fn hashBytes(data: []const u8, at: usize) usize {
            return (find.load32(data, at) *% find.hash_mul32) >> (32 - bucket_bits);
        }

        fn prepare(h: *Self, one_shot: bool, input_size: usize, data: []const u8) void {
            if (one_shot and input_size <= bucket_size >> 6) {
                for (0..input_size) |i| {
                    const b = hashBytes(data, i);
                    h.addr[b] = 0xCCCCCCCC;
                    h.head[b] = 0xCCCC;
                }
            } else {
                // Positions never reach 3 GiB + 64 MiB: every new chain
                // ends after its first node.
                @memset(h.addr, 0xCCCCCCCC);
                @memset(h.head, 0);
            }
            @memset(h.tiny_hash, 0);
            h.free_slot_idx = @splat(0);
        }

        pub inline fn store(h: *Self, data: []const u8, mask: usize, ix: usize) void {
            const key = hashBytes(data, ix & mask);
            const bank = key & (banks - 1);
            const idx = h.free_slot_idx[bank] & (bank_size - 1);
            h.free_slot_idx[bank] +%= 1;
            var delta = ix -% h.addr[key];
            h.tiny_hash[@as(u16, @truncate(ix))] = @truncate(key);
            if (delta > 0xFFFF) delta = 0xFFFF;
            h.slots[bank * bank_size + idx] = .{ .delta = @intCast(delta), .next = h.head[key] };
            h.addr[key] = @truncate(ix);
            h.head[key] = @intCast(idx);
        }

        pub fn storeRange(h: *Self, data: []const u8, mask: usize, start: usize, end: usize) void {
            var i = start;
            while (i < end) : (i += 1) h.store(data, mask, i);
        }

        fn stitch(h: *Self, num_bytes: usize, position: usize, data: []const u8, mask: usize) void {
            if (num_bytes >= hash_type_length - 1 and position >= 3) {
                h.store(data, mask, position - 3);
                h.store(data, mask, position - 2);
                h.store(data, mask, position - 1);
            }
        }

        pub inline fn prepareDistanceCache(h: *Self, cache: *[16]i32) void {
            _ = h;
            extendDistanceCache(cache, num_last);
        }

        pub fn findLongestMatch(h: *Self, common: *Common, data: []const u8, mask: usize, cache: *const [16]i32, cur_ix: usize, max_length: usize, max_backward: usize, dictionary_distance: usize, max_distance: usize, out: *SearchResult) void {
            const cur = cur_ix & mask;
            const min_score = out.score;
            var best_score = out.score;
            var best_len = out.len;
            const key = hashBytes(data, cur);
            const tiny: u8 = @truncate(key);
            out.len = 0;
            out.len_code_delta = 0;
            for (0..num_last) |i| {
                const backward = cached(cache, i);
                var prev_ix = cur_ix -% backward;
                // Distance code 0 takes 2-byte matches too.
                if (i > 0 and h.tiny_hash[@as(u16, @truncate(prev_ix))] != tiny) continue;
                if (prev_ix >= cur_ix or backward > max_backward) continue;
                prev_ix &= mask;
                const len = find.matchLength(data, prev_ix, cur, max_length);
                if (len >= 2) {
                    var score = scoreUsingLastDistance(len);
                    if (best_score < score) {
                        if (i != 0) score -= penaltyUsingLastDistance(i);
                        if (best_score < score) {
                            best_score = score;
                            best_len = len;
                            out.len = len;
                            out.distance = backward;
                            out.score = score;
                        }
                    }
                }
            }
            if (best_len < 3) best_len = 3;
            {
                const bank = key & (banks - 1);
                var backward: usize = 0;
                var hops = h.max_hops;
                var delta = cur_ix -% h.addr[key];
                var slot: usize = h.head[key];
                while (hops > 0) : (hops -= 1) {
                    const last = slot;
                    backward +%= delta;
                    if (backward > max_backward) break;
                    const prev_ix = (cur_ix -% backward) & mask;
                    slot = h.slots[bank * bank_size + last].next;
                    delta = h.slots[bank * bank_size + last].delta;
                    if (cur + best_len > mask or prev_ix + best_len > mask or
                        find.load32(data, cur + best_len - 3) != find.load32(data, prev_ix + best_len - 3)) continue;
                    const len = find.matchLength(data, prev_ix, cur, max_length);
                    if (len >= 4) {
                        const score = backwardReferenceScore(len, backward);
                        if (best_score < score) {
                            best_score = score;
                            best_len = len;
                            out.len = len;
                            out.distance = backward;
                            out.score = score;
                        }
                    }
                }
                h.store(data, mask, cur_ix);
            }
            if (out.score == min_score) searchStaticDictionary(common, data, cur, max_length, dictionary_distance, max_distance, out, false);
        }
    };
}

/// The large-window backup hasher: a rolling hash of 32 bytes at every
/// `jump`th position, a 64th of the hashes kept, each the latest position
/// in its one of 2^24 buckets. It finds the long matches far back that the
/// main hasher's window misses, and searches no dictionary.
pub fn Rolling(comptime jump: usize) type {
    return struct {
        const Self = @This();
        const chunk_len = 32;
        const num_buckets = 1 << 24;
        const code_mask = num_buckets * 64 - 1;
        const factor: u32 = 69069;
        const invalid_pos: u32 = 0xffffffff;
        // Longer than it looks: it checks its own lookahead, so the main
        // hasher keeps its own.
        pub const hash_type_length = 4;
        pub const store_lookahead = 4;

        state: u32 = 0,
        table: []u32,
        next_ix: usize = 0,
        /// `factor` to the power of the bytes in the chunk: the weight of
        /// the byte leaving it.
        factor_remove: u32,

        fn init(gpa: Allocator) Allocator.Error!Self {
            const table = try gpa.alloc(u32, num_buckets);
            @memset(table, invalid_pos);
            var f: u32 = 1;
            var i: usize = 0;
            while (i < chunk_len) : (i += jump) f *%= factor;
            return .{ .table = table, .factor_remove = f };
        }

        fn deinit(h: *Self, gpa: Allocator) void {
            gpa.free(h.table);
        }

        fn prepare(h: *Self, one_shot: bool, input_size: usize, data: []const u8) void {
            _ = one_shot;
            if (input_size < chunk_len) return;
            h.state = 0;
            var i: usize = 0;
            while (i < chunk_len) : (i += jump) h.state = factor *% h.state +% (@as(u32, data[i]) + 1);
        }

        pub inline fn store(h: *Self, data: []const u8, mask: usize, ix: usize) void {
            _ = .{ h, data, mask, ix };
        }

        pub fn storeRange(h: *Self, data: []const u8, mask: usize, start: usize, end: usize) void {
            _ = .{ h, data, mask, start, end };
        }

        /// Start again from the block: the hash is of the bytes before it.
        fn stitch(h: *Self, num_bytes: usize, position_in: usize, data: []const u8, mask: usize) void {
            var position = position_in;
            var available = num_bytes;
            if (position & (jump - 1) != 0) {
                const diff = jump - (position & (jump - 1));
                available = if (diff > available) 0 else available - diff;
                position += diff;
            }
            const at = position & mask;
            // Not across the ring's end.
            available = @min(available, mask - at);
            h.prepare(false, available, data[at..]);
            h.next_ix = position;
        }

        pub inline fn prepareDistanceCache(h: *Self, cache: *[16]i32) void {
            _ = .{ h, cache };
        }

        pub fn findLongestMatch(h: *Self, common: *Common, data: []const u8, mask: usize, cache: *const [16]i32, cur_ix: usize, max_length: usize, max_backward: usize, dictionary_distance: usize, max_distance: usize, out: *SearchResult) void {
            _ = .{ common, cache, dictionary_distance, max_distance };
            if (cur_ix & (jump - 1) != 0 or max_length < chunk_len) return;
            const cur = cur_ix & mask;
            var pos = h.next_ix;
            while (pos <= cur_ix) : (pos += jump) {
                const code = h.state & code_mask;
                const rem: u32 = data[pos & mask];
                const add: u32 = data[(pos + chunk_len) & mask];
                h.state = factor *% h.state +% (add + 1) -% h.factor_remove *% (rem + 1);
                if (code >= num_buckets) continue;
                const found_ix = h.table[code];
                h.table[code] = @truncate(pos);
                if (pos != cur_ix or found_ix == invalid_pos) continue;
                // Distances to 4 GiB past a position over 4 GiB.
                const backward: usize = @as(u32, @truncate(cur_ix -% found_ix));
                if (backward > max_backward) continue;
                const len = find.matchLength(data, found_ix & mask, cur, max_length);
                if (len >= 4 and len > out.len) {
                    const score = backwardReferenceScore(len, backward);
                    if (score > out.score) out.* = .{ .len = len, .distance = backward, .score = score, .len_code_delta = 0 };
                }
            }
            h.next_ix = cur_ix + jump;
        }
    };
}

/// Two hashers searched one after the other: a main one and `Rolling`.
pub fn Composite(comptime A: type, comptime B: type) type {
    return struct {
        const Self = @This();
        pub const hash_type_length = @max(A.hash_type_length, B.hash_type_length);
        pub const store_lookahead = @max(A.store_lookahead, B.store_lookahead);

        a: A,
        b: B,

        /// Around `a`, which it then owns, with a new `b`.
        fn init(gpa: Allocator, a: A) Allocator.Error!Self {
            var h: Self = .{ .a = a, .b = undefined };
            errdefer h.a.deinit(gpa);
            h.b = try .init(gpa);
            return h;
        }

        fn deinit(h: *Self, gpa: Allocator) void {
            h.a.deinit(gpa);
            h.b.deinit(gpa);
        }

        fn prepare(h: *Self, one_shot: bool, input_size: usize, data: []const u8) void {
            h.a.prepare(one_shot, input_size, data);
            h.b.prepare(one_shot, input_size, data);
        }

        pub inline fn store(h: *Self, data: []const u8, mask: usize, ix: usize) void {
            h.a.store(data, mask, ix);
            h.b.store(data, mask, ix);
        }

        pub fn storeRange(h: *Self, data: []const u8, mask: usize, start: usize, end: usize) void {
            h.a.storeRange(data, mask, start, end);
            h.b.storeRange(data, mask, start, end);
        }

        fn stitch(h: *Self, num_bytes: usize, position: usize, data: []const u8, mask: usize) void {
            h.a.stitch(num_bytes, position, data, mask);
            h.b.stitch(num_bytes, position, data, mask);
        }

        pub inline fn prepareDistanceCache(h: *Self, cache: *[16]i32) void {
            h.a.prepareDistanceCache(cache);
            h.b.prepareDistanceCache(cache);
        }

        pub fn findLongestMatch(h: *Self, common: *Common, data: []const u8, mask: usize, cache: *const [16]i32, cur_ix: usize, max_length: usize, max_backward: usize, dictionary_distance: usize, max_distance: usize, out: *SearchResult) void {
            h.a.findLongestMatch(common, data, mask, cache, cur_ix, max_length, max_backward, dictionary_distance, max_distance, out);
            h.b.findLongestMatch(common, data, mask, cache, cur_ix, max_length, max_backward, dictionary_distance, max_distance, out);
        }
    };
}

pub const H2 = Quickly(16, 0, 5, true);
pub const H3 = Quickly(16, 1, 5, false);
pub const H4 = Quickly(17, 2, 5, true);
pub const H54 = Quickly(20, 2, 7, false);
pub const H5 = LongestMatch(false);
pub const H6 = LongestMatch(true);
pub const H58 = Tagged(false);
pub const H68 = Tagged(true);
pub const H40 = ForgetfulChain(1, 16, 4);
pub const H41 = ForgetfulChain(1, 16, 10);
pub const H42 = ForgetfulChain(512, 9, 16);
pub const H10 = @import("tree.zig").H10;
pub const H35 = Composite(H3, Rolling(4));
pub const H55 = Composite(H54, Rolling(4));
pub const H65 = Composite(H6, Rolling(1));

pub const Impl = union(enum) {
    none,
    h2: H2,
    h3: H3,
    h4: H4,
    h54: H54,
    h5: H5,
    h6: H6,
    h58: H58,
    h68: H68,
    h40: H40,
    h41: H41,
    h42: H42,
    h10: H10,
    h35: H35,
    h55: H55,
    h65: H65,
};

/// The hasher of a stream: set up on its first block, prepared after a
/// reset, stitched to each block before it is parsed.
pub const Hasher = struct {
    common: Common = .{},
    impl: Impl = .none,
    prepared: bool = false,

    pub fn deinit(h: *Hasher, gpa: Allocator) void {
        switch (h.impl) {
            .none => {},
            inline else => |*x| x.deinit(gpa),
        }
        h.* = undefined;
    }

    pub fn reset(h: *Hasher) void {
        h.prepared = false;
    }

    fn setup(h: *Hasher, gpa: Allocator, params: *const settings.Resolved, data: []const u8, position: usize, input_size: usize, is_last: bool) Allocator.Error!void {
        const one_shot = position == 0 and is_last;
        if (h.impl == .none) {
            const p = params.hasher;
            h.common = .{};
            h.impl = switch (p.type) {
                .h2 => .{ .h2 = try .init(gpa) },
                .h3 => .{ .h3 = try .init(gpa) },
                .h4 => .{ .h4 = try .init(gpa) },
                .h54 => .{ .h54 = try .init(gpa) },
                .h5 => .{ .h5 = try .init(gpa, p) },
                .h6 => .{ .h6 = try .init(gpa, p) },
                .h58 => .{ .h58 = try .init(gpa, p) },
                .h68 => .{ .h68 = try .init(gpa, p) },
                .h40 => .{ .h40 = try .init(gpa, params.quality) },
                .h41 => .{ .h41 = try .init(gpa, params.quality) },
                .h42 => .{ .h42 = try .init(gpa, params.quality) },
                .h10 => .{ .h10 = try .init(gpa, params, one_shot, input_size) },
                .h35 => .{ .h35 = try .init(gpa, try .init(gpa)) },
                .h55 => .{ .h55 = try .init(gpa, try .init(gpa)) },
                .h65 => .{ .h65 = try .init(gpa, try .init(gpa, p)) },
            };
            h.prepared = false;
        }
        if (!h.prepared) {
            switch (h.impl) {
                .none => unreachable,
                inline else => |*x| x.prepare(one_shot, input_size, data),
            }
            h.prepared = true;
        }
    }

    pub fn initOrStitch(h: *Hasher, gpa: Allocator, data: []const u8, mask: u32, params: *const settings.Resolved, position: u32, input_size: u32, is_last: bool) Allocator.Error!void {
        try h.setup(gpa, params, data, position, input_size, is_last);
        switch (h.impl) {
            .none => unreachable,
            inline else => |*x| x.stitch(input_size, position, data, mask),
        }
    }
};
