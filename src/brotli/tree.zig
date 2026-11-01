//! H10, the match finder of qualities 10-11: a binary tree of the
//! positions sharing a 4-byte hash (17 bits of buckets), each node's
//! children at twice its position in the window, re-rooted at every
//! position stored. A search walks one bucket's tree to depth 64 comparing
//! up to 128 bytes, and reports the matches in increasing length; short
//! matches nearby and the static dictionary's are added around it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const find = @import("find.zig");
const static = @import("static.zig");
const settings = @import("settings.zig");

const bucket_bits = 17;
const bucket_size = 1 << bucket_bits;
const max_tree_search_depth = 64;
pub const max_tree_comp_length = 128;
/// Matches a search reports at most: 64 by the tree, 64 nearby.
pub const max_num_matches = 128;

const BackwardMatch = find.BackwardMatch;

pub const H10 = struct {
    pub const hash_type_length = 4;
    pub const store_lookahead = max_tree_comp_length;

    window_mask: usize,
    buckets: []u32,
    /// A position that marks no node: the tree is empty at it, a node with
    /// both children at it is a leaf.
    invalid_pos: u32,
    /// Node `pos`'s left and right children at `2 * pos` and `2 * pos + 1`.
    forest: []u32,

    /// The nodes a stream needs: the window's, or a one-shot input's when
    /// it is shorter.
    pub fn nodes(params: *const settings.Resolved, one_shot: bool, input_size: usize) usize {
        const window = @as(usize, 1) << params.lgwin;
        return if (one_shot and input_size < window) input_size else window;
    }

    pub fn init(gpa: Allocator, params: *const settings.Resolved, one_shot: bool, input_size: usize) Allocator.Error!H10 {
        const num_nodes = nodes(params, one_shot, input_size);
        const buckets = try gpa.alloc(u32, bucket_size);
        errdefer gpa.free(buckets);
        const window_mask = (@as(usize, 1) << params.lgwin) - 1;
        return .{
            .window_mask = window_mask,
            .buckets = buckets,
            .invalid_pos = @truncate(0 -% window_mask),
            .forest = try gpa.alloc(u32, 2 * num_nodes),
        };
    }

    pub fn deinit(h: *H10, gpa: Allocator) void {
        gpa.free(h.buckets);
        gpa.free(h.forest);
    }

    /// A new stream: `prepare` empties every tree, and a node is read only
    /// through one.
    pub fn rewind(h: *H10) void {
        _ = h;
    }

    inline fn hashBytes(data: []const u8, at: usize) usize {
        return (find.load32(data, at) *% find.hash_mul32) >> (32 - bucket_bits);
    }

    pub fn prepare(h: *H10, one_shot: bool, input_size: usize, data: []const u8) void {
        _ = one_shot;
        _ = input_size;
        _ = data;
        @memset(h.buckets, h.invalid_pos);
    }

    inline fn left(h: *const H10, pos: usize) usize {
        return 2 * (pos & h.window_mask);
    }

    inline fn right(h: *const H10, pos: usize) usize {
        return 2 * (pos & h.window_mask) + 1;
    }

    /// Store the position and, in the same walk, find its matches in its
    /// bucket's tree, re-rooting it there; with less than 128 bytes ahead
    /// the tree is searched but left as it is. Positions only increase.
    pub fn storeAndFindMatches(h: *H10, data: []const u8, cur_ix: usize, mask: usize, max_length: usize, max_backward: usize, best_len: ?*usize, matches_in: ?[*]BackwardMatch) ?[*]BackwardMatch {
        var matches = matches_in;
        const cur = cur_ix & mask;
        const max_comp_len = @min(max_length, max_tree_comp_length);
        const reroot = max_length >= max_tree_comp_length;
        const key = hashBytes(data, cur);
        const forest = h.forest;
        var prev_ix: usize = h.buckets[key];
        // The rightmost node of the new root's left subtree and the leftmost
        // of its right, and their match lengths.
        var node_left = h.left(cur_ix);
        var node_right = h.right(cur_ix);
        var best_len_left: usize = 0;
        var best_len_right: usize = 0;
        if (reroot) h.buckets[key] = @truncate(cur_ix);
        var depth_remaining: usize = max_tree_search_depth;
        while (true) : (depth_remaining -= 1) {
            const backward = cur_ix -% prev_ix;
            const prev = prev_ix & mask;
            if (backward == 0 or backward > max_backward or depth_remaining == 0) {
                if (reroot) {
                    forest[node_left] = h.invalid_pos;
                    forest[node_right] = h.invalid_pos;
                }
                break;
            }
            const cur_len = @min(best_len_left, best_len_right);
            const len = cur_len + find.matchLength(data, cur + cur_len, prev + cur_len, max_length - cur_len);
            if (matches) |m| {
                if (len > best_len.?.*) {
                    best_len.?.* = len;
                    m[0] = .init(backward, len);
                    matches = m + 1;
                }
            }
            if (len >= max_comp_len) {
                if (reroot) {
                    forest[node_left] = forest[h.left(prev_ix)];
                    forest[node_right] = forest[h.right(prev_ix)];
                }
                break;
            }
            if (data[cur + len] > data[prev + len]) {
                best_len_left = len;
                if (reroot) forest[node_left] = @truncate(prev_ix);
                node_left = h.right(prev_ix);
                prev_ix = forest[node_left];
            } else {
                best_len_right = len;
                if (reroot) forest[node_right] = @truncate(prev_ix);
                node_right = h.left(prev_ix);
                prev_ix = forest[node_right];
            }
        }
        return matches;
    }

    /// The matches at `cur_ix`, in increasing length and non-decreasing
    /// distance, into `matches`; returns how many.
    pub fn findAllMatches(h: *H10, data: []const u8, mask: usize, cur_ix: usize, max_length: usize, max_backward: usize, dictionary_distance: usize, params: *const settings.Resolved, matches: [*]BackwardMatch) usize {
        var out = matches;
        const cur = cur_ix & mask;
        var best_len: usize = 1;
        const short_max_backward: usize = if (params.quality != 11) 16 else 64;
        const stop = if (cur_ix < short_max_backward) 0 else cur_ix - short_max_backward;
        var i = cur_ix -% 1;
        while (i > stop and best_len <= 2) : (i -%= 1) {
            const backward = cur_ix -% i;
            if (backward > max_backward) break;
            const prev = i & mask;
            if (data[cur] != data[prev] or data[cur + 1] != data[prev + 1]) continue;
            const len = find.matchLength(data, prev, cur, max_length);
            if (len > best_len) {
                best_len = len;
                out[0] = .init(backward, len);
                out += 1;
            }
        }
        if (best_len < max_length) out = h.storeAndFindMatches(data, cur_ix, mask, max_length, max_backward, &best_len, out).?;
        var dict_matches: [static.max_match_len + 1]u32 = @splat(static.invalid_match);
        const minlen = @max(4, best_len + 1);
        if (static.findAll(data[cur..], minlen, max_length, &dict_matches)) {
            const maxlen = @min(static.max_match_len, max_length);
            var l: usize = minlen;
            while (l <= maxlen) : (l += 1) {
                const dict_id = dict_matches[l];
                if (dict_id < static.invalid_match) {
                    const distance = dictionary_distance + (dict_id >> 5) + 1;
                    if (distance <= params.dist.max_distance) {
                        out[0] = .dictionary(distance, l, dict_id & 31);
                        out += 1;
                    }
                }
            }
        }
        return @intCast(out - matches);
    }

    /// Store `ix` (128 bytes ahead of it in the block) with no matches.
    pub fn store(h: *H10, data: []const u8, mask: usize, ix: usize) void {
        // Distances reach the window less 16 (RFC 7932 §9.1).
        const max_backward = h.window_mask - 16 + 1;
        _ = h.storeAndFindMatches(data, ix, mask, max_tree_comp_length, max_backward, null, null);
    }

    pub fn storeRange(h: *H10, data: []const u8, mask: usize, start: usize, end: usize) void {
        var i = start;
        var j = start;
        if (start + 63 <= end) i = end - 63;
        if (start + 512 <= i) {
            while (j < i) : (j += 8) h.store(data, mask, j);
        }
        while (i < end) : (i += 1) h.store(data, mask, i);
    }

    pub fn stitch(h: *H10, num_bytes: usize, position: usize, data: []const u8, mask: usize) void {
        if (num_bytes < hash_type_length - 1 or position < max_tree_comp_length) return;
        // The last 127 positions of the previous block, which needed this
        // one's bytes; distances stay within the window from this block's
        // start, so nothing overwritten is reached.
        const i_start = position - max_tree_comp_length + 1;
        const i_end = @min(position, i_start + num_bytes);
        var i = i_start;
        while (i < i_end) : (i += 1) {
            const max_backward = h.window_mask - @max(16 - 1, position - i);
            _ = h.storeAndFindMatches(data, i, mask, max_tree_comp_length, max_backward, null, null);
        }
    }
};
