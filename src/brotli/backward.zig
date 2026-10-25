//! Greedy parsing with lazy matching, qualities 2-9: the reference
//! encoder's `CreateBackwardReferences`, instantiated for each hasher.
//! A match is taken when it scores; a better one a byte later delays it
//! (up to four times); long runs without matches are skipped through,
//! hashing less of them.

const command = @import("command.zig");
const hash = @import("hash.zig");
const find = @import("find.zig");
const settings = @import("settings.zig");

const Command = command.Command;

pub const Out = struct {
    commands: []Command,
    num_commands: usize = 0,
    last_insert_len: *usize,
    num_literals: *usize,
};

/// The distance code for `distance`: one of the 16 short codes when the
/// cache holds it or a near one, else `distance + 15`.
pub fn distanceCode(distance: usize, max_distance: usize, cache: *const [16]i32) usize {
    if (distance <= max_distance) {
        const plus3 = distance + 3;
        const offset0 = plus3 -% hash.cached(cache, 0);
        const offset1 = plus3 -% hash.cached(cache, 1);
        if (distance == hash.cached(cache, 0)) return 0;
        if (distance == hash.cached(cache, 1)) return 1;
        if (offset0 < 7) return (@as(usize, 0x9750468) >> @intCast(4 * offset0)) & 0xf;
        if (offset1 < 7) return (@as(usize, 0xFDB1ACE) >> @intCast(4 * offset1)) & 0xf;
        if (distance == hash.cached(cache, 2)) return 2;
        if (distance == hash.cached(cache, 3)) return 3;
    }
    return distance + command.short_distance_codes - 1;
}

pub fn create(num_bytes: u32, position: u32, data: []const u8, mask: u32, mode: anytype, params: *const settings.Resolved, hasher: *hash.Hasher, cache: *[16]i32, out: *Out) void {
    _ = mode;
    switch (hasher.impl) {
        .none, .h10 => unreachable,
        // The quick hashers of qualities 2-4 search no prefix dictionary
        // (H55's composite does).
        inline .h2, .h3, .h4, .h54, .h35 => |*h| createWith(@TypeOf(h.*), false, h, &hasher.common, num_bytes, position, data, mask, params, cache, out),
        inline else => |*h| if (params.dictionary != null)
            createWith(@TypeOf(h.*), true, h, &hasher.common, num_bytes, position, data, mask, params, cache, out)
        else
            createWith(@TypeOf(h.*), false, h, &hasher.common, num_bytes, position, data, mask, params, cache, out),
    }
}

fn createWith(comptime H: type, comptime prefix: bool, h: *H, common: *hash.Common, num_bytes: usize, position_in: usize, data: []const u8, mask: usize, params: *const settings.Resolved, cache: *[16]i32, out: *Out) void {
    const max_backward_limit = (@as(usize, 1) << params.lgwin) - 16;
    const position_offset = params.stream_offset;
    var position = position_in;
    var insert_length = out.last_insert_len.*;
    const pos_end = position + num_bytes;
    const store_end = if (num_bytes >= H.store_lookahead) position + num_bytes - H.store_lookahead + 1 else position;
    // Skipping through data with no matches.
    const random_window: usize = if (params.quality < 9) 64 else 512;
    var apply_random_heuristics = position + random_window;
    const gap: usize = if (params.dictionary) |d| d.total_size else 0;
    const min_score = find.score_base + 100;
    var n: usize = 0;
    h.prepareDistanceCache(cache);
    while (position + H.hash_type_length < pos_end) {
        var max_length = pos_end - position;
        var max_distance = @min(position, max_backward_limit);
        var dictionary_start = @min(position + position_offset, max_backward_limit);
        var sr: find.SearchResult = .{ .len = 0, .len_code_delta = 0, .distance = 0, .score = min_score };
        h.findLongestMatch(common, data, mask, cache, position, max_length, max_distance, dictionary_start + gap, params.dist.max_distance, &sr);
        if (prefix) params.dictionary.?.lookup(data, mask, cache, position, max_length, dictionary_start, params.dist.max_distance, &sr);
        if (sr.score > min_score) {
            // A match: look for a better one a byte later.
            var delayed: usize = 0;
            max_length -= 1;
            while (true) : (max_length -= 1) {
                const cost_diff_lazy = 175;
                var sr2: find.SearchResult = .{
                    .len = if (params.quality < 5) @min(sr.len - 1, max_length) else 0,
                    .len_code_delta = 0,
                    .distance = 0,
                    .score = min_score,
                };
                max_distance = @min(position + 1, max_backward_limit);
                dictionary_start = @min(position + 1 + position_offset, max_backward_limit);
                h.findLongestMatch(common, data, mask, cache, position + 1, max_length, max_distance, dictionary_start + gap, params.dist.max_distance, &sr2);
                if (prefix) params.dictionary.?.lookup(data, mask, cache, position + 1, max_length, dictionary_start, params.dist.max_distance, &sr2);
                if (sr2.score >= sr.score + cost_diff_lazy) {
                    // One literal now, the match from the next byte.
                    position += 1;
                    insert_length += 1;
                    sr = sr2;
                    delayed += 1;
                    if (delayed < 4 and position + H.hash_type_length < pos_end) continue;
                }
                break;
            }
            apply_random_heuristics = position + 2 * sr.len + random_window;
            dictionary_start = @min(position + position_offset, max_backward_limit);
            {
                // The first 16 codes are the short codes; distances start at 1.
                const code = distanceCode(sr.distance, dictionary_start + gap, cache);
                if (sr.distance <= dictionary_start + gap and code > 0) {
                    cache[3] = cache[2];
                    cache[2] = cache[1];
                    cache[1] = cache[0];
                    cache[0] = @intCast(sr.distance);
                    h.prepareDistanceCache(cache);
                }
                out.commands[n] = .init(&params.dist, insert_length, sr.len, sr.len_code_delta, code);
                n += 1;
            }
            out.num_literals.* += insert_length;
            insert_length = 0;
            // Hash the copy's positions, but not a run's: it would poison
            // the table.
            {
                var range_start = position + 2;
                const range_end = @min(position + sr.len, store_end);
                if (sr.distance < sr.len >> 2) {
                    range_start = @min(range_end, @max(range_start, position + sr.len - (sr.distance << 2)));
                }
                h.storeRange(data, mask, range_start, range_end);
            }
            position += sr.len;
        } else {
            insert_length += 1;
            position += 1;
            if (position > apply_random_heuristics) {
                // No matches for long: hash less of what follows.
                if (position > apply_random_heuristics + 4 * random_window) {
                    const margin = @max(H.store_lookahead - 1, 4);
                    const pos_jump = @min(position + 16, pos_end -% margin);
                    while (position < pos_jump) : (position += 4) {
                        h.store(data, mask, position);
                        insert_length += 4;
                    }
                } else {
                    const margin = @max(H.store_lookahead - 1, 2);
                    const pos_jump = @min(position + 8, pos_end -% margin);
                    while (position < pos_jump) : (position += 2) {
                        h.store(data, mask, position);
                        insert_length += 2;
                    }
                }
            }
        }
    }
    insert_length += pos_end - position;
    out.last_insert_len.* = insert_length;
    out.num_commands = n;
}
