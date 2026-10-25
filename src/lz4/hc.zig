//! LZ4-HC: levels 2 to 12 over one state. Level 2 is LZ4MID (a 4-byte and
//! an 8-byte hash table, one candidate each); 3-9 search hash chains,
//! 2^(level-1) candidates, with lz4's three-match lookahead and, from 9,
//! its repeated-pattern analysis; 10-12 parse optimally over the matches
//! the chains find (12 searching at every position). The parses are lz4
//! 1.10's (`lz4hc.c`), so a block without history comes out byte for byte
//! as `LZ4_compress_HC` writes it.
//!
//! Positions are virtual and continue across calls, each starting a
//! window past the last, so a call clears nothing: every entry older than
//! a call is out of its reach, as a cleared table's is for lz4.

const std = @import("std");
const seq = @import("sequence.zig");

const hash_log = 15;
const mid_hash_log = hash_log - 1;
const opt_num = 1 << 12;
const trailing_literals = 3;
const optimal_ml = 15 - 1 + seq.min_match;
const max_distance = seq.max_offset;
const window_gap = 65536;
const rebase_at = 1 << 30;

const Strategy = enum { mid, chains, optimal };

const Params = struct { strategy: Strategy, searches: i32, target: u32 };

/// lz4hc.c's level table.
fn params(level: i32) Params {
    const table = [_]Params{
        .{ .strategy = .mid, .searches = 2, .target = 16 },
        .{ .strategy = .mid, .searches = 2, .target = 16 },
        .{ .strategy = .mid, .searches = 2, .target = 16 },
        .{ .strategy = .chains, .searches = 4, .target = 16 },
        .{ .strategy = .chains, .searches = 8, .target = 16 },
        .{ .strategy = .chains, .searches = 16, .target = 16 },
        .{ .strategy = .chains, .searches = 32, .target = 16 },
        .{ .strategy = .chains, .searches = 64, .target = 16 },
        .{ .strategy = .chains, .searches = 128, .target = 16 },
        .{ .strategy = .chains, .searches = 256, .target = 16 },
        .{ .strategy = .optimal, .searches = 96, .target = 64 },
        .{ .strategy = .optimal, .searches = 512, .target = 128 },
        .{ .strategy = .optimal, .searches = 16384, .target = opt_num },
    };
    return table[@intCast(std.math.clamp(level, 0, 12))];
}

/// What precedes a call's input.
pub const Prefix = union(enum) {
    none,
    /// The last call's input, indexed already.
    previous: []const u8,
    /// Bytes indexed for this call.
    bytes: []const u8,
    /// A dictionary in chains of its own.
    attached: struct { bytes: []const u8, chains: *const Chains },
};

const Cost = struct { price: i32, off: i32, mlen: i32, litlen: i32 };

const Match = struct { len: i32 = 0, off: i32 = 0, back: i32 = 0 };

pub const Chains = struct {
    hash: [1 << hash_log]u32,
    chain: [1 << 16]u16,
    /// The virtual index of the input's first byte (lz4's `dictLimit`), of
    /// the history's first (`lowLimit`), the next position to index, and
    /// where the indexed bytes end.
    prefix_idx: u32,
    low_limit: u32,
    next_to_update: u32,
    end_idx: u32,
    /// The tables hold LZ4MID's two hashes, not the chains'.
    mid: bool = false,
    /// The optimal parser's costs, when the levels reach it.
    costs: ?*[opt_num + trailing_literals]Cost,

    pub fn memory(optimal: bool) usize {
        const costs: usize = @sizeOf([opt_num + trailing_literals]Cost);
        return @sizeOf(Chains) + if (optimal) costs else 0;
    }

    pub fn initBuffer(buffer: []align(64) u8, optimal: bool) *Chains {
        const c: *Chains = @ptrCast(@alignCast(buffer.ptr)); // safe: 64-aligned bytes of `memory`, the Chains first
        c.hash = @splat(0);
        c.chain = @splat(0xFFFF);
        c.prefix_idx = window_gap;
        c.low_limit = window_gap;
        c.next_to_update = window_gap;
        c.end_idx = window_gap;
        c.mid = false;
        c.costs = if (optimal) @ptrCast(@alignCast(buffer[@sizeOf(Chains)..].ptr)) else null; // safe: the costs follow at a multiple of Chains' 8-byte alignment
        return c;
    }

    /// Index a dictionary (its last 64 KiB) as lz4's `LZ4_loadDictHC` does,
    /// for LZ4MID's tables or the chains'.
    pub fn load(c: *Chains, bytes: []const u8, mid: bool) void {
        c.hash = @splat(0);
        c.chain = @splat(0xFFFF);
        c.prefix_idx = window_gap;
        c.low_limit = window_gap;
        c.next_to_update = window_gap;
        c.end_idx = window_gap + @as(u32, @intCast(bytes.len));
        c.mid = mid;
        const v: View = .{ .src = bytes, .prefix_idx = c.prefix_idx, .hist = &.{}, .dict_idx = c.prefix_idx };
        if (mid) c.midFill(v) else if (bytes.len >= 4) c.insert(v, bytes.len - 3);
    }

    /// Start a call: the input's first byte a window past the last's, or
    /// right after it when it is the history.
    fn begin(c: *Chains, in_len: usize, history_len: usize, keep: bool) void {
        if (!keep or c.end_idx > rebase_at) {
            if (c.end_idx > rebase_at) {
                c.hash = @splat(0);
                c.chain = @splat(0xFFFF);
                c.end_idx = 0;
            }
            const start = c.end_idx + window_gap + @as(u32, @intCast(history_len));
            c.prefix_idx = start;
            c.low_limit = start - @as(u32, @intCast(history_len));
            c.next_to_update = start;
        } else {
            // The last input is the history: positions run on.
            c.prefix_idx = c.end_idx;
            c.low_limit = c.end_idx - @as(u32, @intCast(history_len));
            c.next_to_update = c.end_idx;
        }
        c.end_idx = c.prefix_idx + @as(u32, @intCast(in_len));
    }

    /// Compress `in` at `level` into `out`.
    pub fn compress(c: *Chains, comptime directive: seq.Directive, level: i32, favor: bool, in: []const u8, out: []u8, prefix: Prefix) ?seq.Written {
        const p = params(level);
        var v: View = .{ .src = in, .prefix_idx = 0, .hist = &.{}, .dict_idx = 0 };
        var dict: ?Dict = null;
        switch (prefix) {
            .none => c.begin(in.len, 0, false),
            .previous => |prev| {
                if (prev.len > 0 and prev.ptr + prev.len == in.ptr and c.end_idx <= rebase_at) {
                    // Just before the input in memory: one prefix, as lz4
                    // continues a stream whose blocks lie end to end.
                    const first = c.end_idx - @as(u32, @intCast(prev.len));
                    c.prefix_idx = first;
                    c.low_limit = first;
                    c.next_to_update = @max(c.next_to_update, first);
                    c.end_idx += @intCast(in.len);
                    v.src = prev.ptr[0 .. prev.len + in.len];
                    v.begin = prev.len;
                } else {
                    // Elsewhere: an external dictionary, its last positions
                    // indexed first, as lz4 does.
                    if (prev.len >= 4 and c.next_to_update < c.end_idx - 3) {
                        const pv: View = .{ .src = prev, .prefix_idx = c.end_idx - @as(u32, @intCast(prev.len)), .hist = &.{}, .dict_idx = 0 };
                        if (!c.mid) c.insert(pv, prev.len - 3);
                    }
                    c.begin(in.len, prev.len, true);
                    v.hist = prev;
                }
            },
            .bytes => |bytes| {
                c.begin(in.len, bytes.len, false);
                const hv: View = .{ .src = bytes, .prefix_idx = c.low_limit, .hist = &.{}, .dict_idx = c.low_limit };
                c.next_to_update = c.low_limit;
                if (p.strategy == .mid) {
                    c.midFill(hv);
                } else if (bytes.len >= 4) c.insert(hv, bytes.len - 3);
                c.next_to_update = c.prefix_idx;
                v.hist = bytes;
            },
            .attached => |a| {
                c.begin(in.len, 0, false);
                dict = .{ .chains = a.chains, .bytes = a.bytes };
            },
        }
        c.mid = p.strategy == .mid;
        v.prefix_idx = c.prefix_idx;
        v.dict_idx = c.low_limit;
        return switch (p.strategy) {
            .mid => c.midCompress(directive, v, out, dict),
            .chains => c.chainCompress(directive, v, out, p.searches, dict),
            .optimal => c.optimalCompress(directive, v, out, p.searches, p.target, level >= 12, dict, favor),
        };
    }

    // ---- Indexing ----

    fn hashPtr(bytes: []const u8) u32 {
        return (std.mem.readInt(u32, bytes[0..4], .little) *% 2654435761) >> (32 - hash_log);
    }

    /// Index every position from `next_to_update` up to `ip` (excluded).
    fn insert(c: *Chains, v: View, ip: usize) void {
        const target = v.prefix_idx + @as(u32, @intCast(ip));
        var idx = c.next_to_update;
        while (idx < target) : (idx += 1) {
            const h = hashPtr(v.src[idx - v.prefix_idx ..]);
            const delta = @min(idx -% c.hash[h], max_distance);
            c.chain[@as(u16, @truncate(idx))] = @intCast(delta);
            c.hash[h] = idx;
        }
        c.next_to_update = target;
    }

    // ---- The chains' search ----

    fn widerMatch(
        c: *Chains,
        v: View,
        ip: usize,
        i_low: usize,
        i_high: usize,
        longest_in: i32,
        max_attempts: i32,
        pattern_analysis: bool,
        chain_swap: bool,
        dict: ?Dict,
        favor: bool,
    ) Match {
        const src = v.src;
        const prefix_idx = v.prefix_idx;
        const ip_index = prefix_idx + @as(u32, @intCast(ip));
        const within_start = c.low_limit + max_distance + 1 > ip_index;
        const lowest = if (within_start) c.low_limit else ip_index - max_distance;
        const dict_idx = c.low_limit;
        const look_back: i32 = @intCast(ip - i_low);
        var attempts = max_attempts;
        var chain_pos: u32 = 0;
        const pattern = read32(src[ip..]);
        var repeat: @FieldType(Repeat, "state") = .untested;
        var src_pattern_len: usize = 0;
        var offset: i32 = 0;
        var s_back: i32 = 0;
        var longest = longest_in;

        c.insert(v, ip);
        var match_index = c.hash[hashPtr(src[ip..])];
        while (match_index >= lowest and attempts > 0) {
            var match_len: i32 = 0;
            attempts -= 1;
            if (favor and ip_index - match_index < 8) {
                // Matches of offset below 8 decode slower: skipped.
            } else if (match_index >= prefix_idx) {
                const mp: usize = match_index - prefix_idx;
                const at: usize = @intCast(@as(isize, @intCast(i_low)) + longest - 1);
                const at_m: usize = @intCast(@as(isize, @intCast(mp)) - look_back + longest - 1);
                if (read16(src[at..]) == read16(src[at_m..]) and read32(src[mp..]) == pattern) {
                    const back: i32 = if (look_back != 0) countBack(src, ip, src, mp, i_low, 0) else 0;
                    match_len = @intCast(seq.min_match + seq.countMatch(src[ip + seq.min_match .. i_high], src[mp + seq.min_match ..]));
                    match_len -= back;
                    if (match_len > longest) {
                        longest = match_len;
                        offset = @intCast(ip_index - match_index);
                        s_back = back;
                    }
                }
            } else {
                const mp: usize = match_index - dict_idx;
                if (match_index <= prefix_idx - 4 and read32(v.hist[mp..]) == pattern) {
                    const v_limit = @min(ip + (prefix_idx - match_index), i_high);
                    var n: usize = seq.countMatch(src[ip + seq.min_match .. v_limit], v.hist[mp + seq.min_match ..]) + seq.min_match;
                    if (ip + n == v_limit and v_limit < i_high) n += seq.countMatch(src[ip + n .. i_high], src);
                    const back: i32 = if (look_back != 0) countBack(src, ip, v.hist, mp, i_low, 0) else 0;
                    match_len = @as(i32, @intCast(n)) - back;
                    if (match_len > longest) {
                        longest = match_len;
                        offset = @intCast(ip_index - match_index);
                        s_back = back;
                    }
                }
            }

            if (chain_swap and match_len == longest) {
                // A better match: follow the chain of whichever of its
                // positions jumps farthest back.
                if (match_index + @as(u32, @intCast(longest)) <= ip_index) {
                    const k_trigger = 4;
                    var distance_to_next: u32 = 1;
                    const end: i32 = longest - seq.min_match + 1;
                    var step: i32 = 1;
                    var accel: i32 = 1 << k_trigger;
                    var pos: i32 = 0;
                    while (pos < end) : (pos += step) {
                        const candidate_dist = c.chain[@as(u16, @truncate(match_index + @as(u32, @intCast(pos))))];
                        step = accel >> k_trigger;
                        accel += 1;
                        if (candidate_dist > distance_to_next) {
                            distance_to_next = candidate_dist;
                            chain_pos = @intCast(pos);
                            accel = 1 << k_trigger;
                        }
                    }
                    if (distance_to_next > 1) {
                        if (distance_to_next > match_index) break;
                        match_index -= distance_to_next;
                        continue;
                    }
                }
            }

            if (pattern_analysis and chain_pos == 0 and c.chain[@as(u16, @truncate(match_index))] == 1) {
                var p: Repeat = .{ .match_index = match_index, .longest = longest, .offset = offset, .state = repeat, .src_len = src_pattern_len };
                const step = c.patternStep(v, &p, ip, i_high, lowest, look_back, pattern);
                repeat = p.state;
                src_pattern_len = p.src_len;
                match_index = p.match_index;
                longest = p.longest;
                offset = p.offset;
                switch (step) {
                    .follow => {},
                    .next => continue,
                    .stop => break,
                }
            }

            match_index -= c.chain[@as(u16, @truncate(match_index + chain_pos))];
        }

        var best: Match = .{ .len = longest, .off = offset, .back = s_back };
        if (dict) |d| if (attempts > 0 and within_start) dictSearch(d, src, ip, i_low, i_high, ip_index, lowest, look_back, pattern, attempts, &best);
        return best;
    }

    /// Where the search of a repeated pattern goes next.
    const RepeatStep = enum { follow, next, stop };

    const Repeat = struct {
        match_index: u32,
        longest: i32,
        offset: i32,
        state: enum { untested, not, confirmed },
        /// How far the pattern repeats from the position searched.
        src_len: usize,
    };

    /// lz4's repeated-pattern analysis at a candidate whose chain steps one
    /// back: jump along the run of the pattern rather than one position at
    /// a time, and take the run itself as a match where it is longer.
    fn patternStep(c: *Chains, v: View, p: *Repeat, ip: usize, i_high: usize, lowest: u32, look_back: i32, pattern: u32) RepeatStep {
        const src = v.src;
        const prefix_idx = v.prefix_idx;
        const dict_idx = c.low_limit;
        const ip_index = prefix_idx + @as(u32, @intCast(ip));
        const cand = p.match_index - 1;
        if (p.state == .untested) {
            if ((pattern & 0xFFFF) == (pattern >> 16) and (pattern & 0xFF) == (pattern >> 24)) {
                p.state = .confirmed;
                p.src_len = countPattern(src, ip + 4, i_high, pattern) + 4;
            } else p.state = .not;
        }
        if (!(p.state == .confirmed and cand >= lowest and protectDictEnd(prefix_idx, cand))) return .follow;
        const ext = cand < prefix_idx;
        const seg = if (ext) v.hist else src;
        const mp: usize = if (ext) cand - dict_idx else cand - prefix_idx;
        if (read32(seg[mp..]) != pattern) return .follow;
        const i_limit = if (ext) v.hist.len else i_high;
        var forward = countPattern(seg, mp + 4, i_limit, pattern) + 4;
        if (ext and mp + forward == i_limit) {
            const rotated = rotatePattern(forward, pattern);
            forward += countPattern(src, 0, i_high, rotated);
        }
        var back_len = reverseCountPattern(seg, mp, 0, pattern);
        if (!ext and mp - back_len == 0 and dict_idx < prefix_idx) {
            const rotated = rotatePattern(0 -% back_len, pattern);
            back_len += reverseCountPattern(v.hist, v.hist.len, 0, rotated);
        }
        // Not past the lowest index.
        back_len = cand - @max(cand - @as(u32, @intCast(back_len)), lowest);
        const segment_len = back_len + forward;
        if (segment_len >= p.src_len and forward <= p.src_len) {
            const new_index: u32 = cand + @as(u32, @intCast(forward)) - @as(u32, @intCast(p.src_len));
            p.match_index = if (protectDictEnd(prefix_idx, new_index)) new_index else prefix_idx;
            return .next;
        }
        const new_index: u32 = cand - @as(u32, @intCast(back_len));
        if (!protectDictEnd(prefix_idx, new_index)) {
            p.match_index = prefix_idx;
            return .next;
        }
        p.match_index = new_index;
        if (look_back == 0) {
            const max_ml = @min(segment_len, p.src_len);
            if (@as(usize, @intCast(p.longest)) < max_ml) {
                if (ip_index - p.match_index > max_distance) return .stop;
                p.longest = @intCast(max_ml);
                p.offset = @intCast(ip_index - p.match_index);
            }
            const dist_to_next_pattern = c.chain[@as(u16, @truncate(p.match_index))];
            if (dist_to_next_pattern > p.match_index) return .stop;
            p.match_index -= dist_to_next_pattern;
        }
        return .next;
    }

    /// The tail of a search into an attached dictionary's chains.
    fn dictSearch(d: Dict, src: []const u8, ip: usize, i_low: usize, i_high: usize, ip_index: u32, lowest: u32, look_back: i32, pattern: u32, attempts_in: i32, best: *Match) void {
        const dc = d.chains;
        const dict_end = dc.end_idx;
        var attempts = attempts_in;
        var dict_match = dc.hash[hashPtr(src[ip..])];
        var m = dict_match +% lowest -% dict_end;
        while (ip_index -% m <= max_distance and attempts > 0) {
            attempts -= 1;
            const mp = dict_match -% dc.prefix_idx;
            if (mp + 4 <= d.bytes.len and read32(d.bytes[mp..]) == pattern) {
                const v_limit = @min(ip + (dict_end - dict_match), i_high);
                var mlt: i32 = @intCast(seq.countMatch(src[ip + seq.min_match .. v_limit], d.bytes[mp + seq.min_match ..]) + seq.min_match);
                const back: i32 = if (look_back != 0) countBack(src, ip, d.bytes, mp, i_low, 0) else 0;
                mlt -= back;
                if (mlt > best.len) best.* = .{ .len = mlt, .off = @intCast(ip_index -% m), .back = back };
            }
            const next = dc.chain[@as(u16, @truncate(dict_match))];
            dict_match -%= next;
            m -%= next;
        }
    }

    fn bestMatch(c: *Chains, v: View, ip: usize, i_limit: usize, attempts: i32, pattern_analysis: bool, dict: ?Dict) Match {
        return c.widerMatch(v, ip, ip, i_limit, seq.min_match - 1, attempts, pattern_analysis, false, dict, false);
    }

    // ---- Levels 3 to 9 ----

    fn chainCompress(c: *Chains, comptime directive: seq.Directive, v_in: View, out: []u8, attempts: i32, dict: ?Dict) ?seq.Written {
        // A local copy: the caller's may alias the tables, and its fields
        // would be loaded again after every store into them.
        var v = v_in;
        _ = &v;
        const src = v.src;
        const pattern_analysis = attempts > 128;
        var e: Encoder(directive) = .init(out, v.begin);
        var ip: usize = v.begin;
        if (src.len - v.begin < seq.min_length) return e.last(src);
        const mflimit = src.len - seq.mf_limit;
        const match_limit = src.len - seq.last_literals;
        var start0: usize = 0;
        var start2: usize = 0;
        var start3: usize = 0;
        var m0: Match = .{};
        var m1: Match = .{};
        var m2: Match = .{};
        var m3: Match = .{};

        main: while (ip <= mflimit) {
            m1 = c.bestMatch(v, ip, match_limit, attempts, pattern_analysis, dict);
            if (m1.len < seq.min_match) {
                ip += 1;
                continue;
            }
            start0 = ip;
            m0 = m1;
            search2: while (true) {
                if (ip + length(m1) <= mflimit) {
                    start2 = ip + length(m1) - 2;
                    m2 = c.widerMatch(v, start2, ip, match_limit, m1.len, attempts, pattern_analysis, false, dict, false);
                    start2 = addBack(start2, m2.back);
                } else m2 = .{};
                if (m2.len <= m1.len) {
                    if (!e.sequence(src, &ip, m1.len, m1.off)) return e.overflow(src, &ip, m1);
                    continue :main;
                }
                if (start0 < ip and start2 < ip + length(m0)) {
                    // Squeeze the first match between the original and
                    // the second.
                    ip = start0;
                    m1 = m0;
                }
                if (start2 - ip < 3) {
                    // The first match is too short: the second replaces it.
                    ip = start2;
                    m1 = m2;
                    continue :search2;
                }
                search3: while (true) {
                    if (start2 - ip < optimal_ml) {
                        var new_ml: i32 = @min(m1.len, optimal_ml);
                        if (ip + len2(new_ml) > start2 + length(m2) - seq.min_match) new_ml = @as(i32, @intCast(start2 - ip)) + m2.len - seq.min_match;
                        const correction = new_ml - @as(i32, @intCast(start2 - ip));
                        if (correction > 0) {
                            start2 += @intCast(correction);
                            m2.len -= correction;
                        }
                    }
                    if (start2 + length(m2) <= mflimit) {
                        start3 = start2 + length(m2) - 3;
                        m3 = c.widerMatch(v, start3, start2, match_limit, m2.len, attempts, pattern_analysis, false, dict, false);
                        start3 = addBack(start3, m3.back);
                    } else m3 = .{};
                    if (m3.len <= m2.len) {
                        // No better third: write the first two.
                        if (start2 < ip + length(m1)) m1.len = @intCast(start2 - ip);
                        if (!e.sequence(src, &ip, m1.len, m1.off)) return e.overflow(src, &ip, m1);
                        ip = start2;
                        if (!e.sequence(src, &ip, m2.len, m2.off)) return e.overflow(src, &ip, m2);
                        continue :main;
                    }
                    if (start3 < ip + length(m1) + 3) {
                        // No room for the second: remove it.
                        if (start3 >= ip + length(m1)) {
                            // The first can be written; the third becomes it.
                            if (start2 < ip + length(m1)) {
                                const correction: i32 = @intCast(ip + length(m1) - start2);
                                start2 += @intCast(correction);
                                m2.len -= correction;
                                if (m2.len < seq.min_match) {
                                    start2 = start3;
                                    m2 = m3;
                                }
                            }
                            if (!e.sequence(src, &ip, m1.len, m1.off)) return e.overflow(src, &ip, m1);
                            ip = start3;
                            m1 = m3;
                            start0 = start2;
                            m0 = m2;
                            continue :search2;
                        }
                        start2 = start3;
                        m2 = m3;
                        continue :search3;
                    }
                    // Three ascending matches: write the first.
                    if (start2 < ip + length(m1)) {
                        if (start2 - ip < optimal_ml) {
                            if (m1.len > optimal_ml) m1.len = optimal_ml;
                            if (ip + length(m1) > start2 + length(m2) - seq.min_match) m1.len = @as(i32, @intCast(start2 - ip)) + m2.len - seq.min_match;
                            const correction = m1.len - @as(i32, @intCast(start2 - ip));
                            if (correction > 0) {
                                start2 += @intCast(correction);
                                m2.len -= correction;
                            }
                        } else m1.len = @intCast(start2 - ip);
                    }
                    if (!e.sequence(src, &ip, m1.len, m1.off)) return e.overflow(src, &ip, m1);
                    ip = start2;
                    m1 = m2;
                    start2 = start3;
                    m2 = m3;
                    continue :search3;
                }
            }
        }
        return e.last(src);
    }

    // ---- Levels 10 to 12 ----

    fn longerMatch(c: *Chains, v: View, ip: usize, i_high: usize, min_len: i32, searches: i32, dict: ?Dict, favor: bool) Match {
        var m = c.widerMatch(v, ip, ip, i_high, min_len, searches, true, true, dict, favor);
        if (m.len <= min_len) return .{};
        if (favor and m.len > 18 and m.len <= 36) m.len = 18;
        return m;
    }

    fn optimalCompress(c: *Chains, comptime directive: seq.Directive, v_in: View, out: []u8, searches: i32, sufficient_in: u32, full_update: bool, dict: ?Dict, favor: bool) ?seq.Written {
        // A local copy: the caller's may alias the tables, and its fields
        // would be loaded again after every store into them.
        var v = v_in;
        _ = &v;
        const src = v.src;
        const opt = c.costs.?;
        var e: Encoder(directive) = .init(out, v.begin);
        var ip: usize = v.begin;
        if (src.len - v.begin < seq.min_length) return e.last(src);
        const mflimit = src.len - seq.mf_limit;
        const match_limit = src.len - seq.last_literals;
        const sufficient: usize = @min(sufficient_in, opt_num - 1);
        const fav: i32 = @intFromBool(favor);

        while (ip <= mflimit) {
            const llen: i32 = @intCast(ip - e.anchor);
            const first = c.longerMatch(v, ip, match_limit, seq.min_match - 1, searches, dict, favor);
            if (first.len == 0) {
                ip += 1;
                continue;
            }
            if (length(first) > sufficient) {
                // Good enough: written at once.
                if (!e.sequence(src, &ip, first.len, first.off)) return e.overflow(src, &ip, first);
                continue;
            }
            for (0..seq.min_match) |r| {
                const rp: i32 = @intCast(r);
                opt[r] = .{ .mlen = 1, .off = 0, .litlen = llen + rp, .price = literalsPrice(llen + rp) };
            }
            {
                var ml: i32 = seq.min_match;
                while (ml <= first.len) : (ml += 1) {
                    opt[@intCast(ml)] = .{ .mlen = ml, .off = first.off, .litlen = llen, .price = sequencePrice(llen, ml) };
                }
            }
            var last_match_pos: usize = length(first);
            fillTrailing(opt, last_match_pos);

            var best_mlen: i32 = undefined;
            var best_off: i32 = undefined;
            var cur: usize = 1;
            var encode_now = false;
            while (cur < last_match_pos) : (cur += 1) {
                const cur_ip = ip + cur;
                if (cur_ip > mflimit) break;
                if (full_update) {
                    if (opt[cur + 1].price <= opt[cur].price and opt[cur + seq.min_match].price < opt[cur].price + 3) continue;
                } else if (opt[cur + 1].price <= opt[cur].price) continue;
                const new = if (full_update)
                    c.longerMatch(v, cur_ip, match_limit, seq.min_match - 1, searches, dict, favor)
                else
                    c.longerMatch(v, cur_ip, match_limit, @intCast(last_match_pos - cur), searches, dict, favor);
                if (new.len == 0) continue;
                if (length(new) > sufficient or length(new) + cur >= opt_num) {
                    best_mlen = new.len;
                    best_off = new.off;
                    last_match_pos = cur + 1;
                    encode_now = true;
                    break;
                }
                priceMatch(opt, cur, new, &last_match_pos, fav);
                fillTrailing(opt, last_match_pos);
            }
            if (!encode_now) {
                best_mlen = opt[last_match_pos].mlen;
                best_off = opt[last_match_pos].off;
                cur = last_match_pos - @as(usize, @intCast(best_mlen));
            }
            // Walk back from the end, then write the chosen path in order.
            {
                var candidate_pos = cur;
                var selected_ml = best_mlen;
                var selected_off = best_off;
                while (true) {
                    const next_ml = opt[candidate_pos].mlen;
                    const next_off = opt[candidate_pos].off;
                    opt[candidate_pos].mlen = selected_ml;
                    opt[candidate_pos].off = selected_off;
                    selected_ml = next_ml;
                    selected_off = next_off;
                    if (next_ml > @as(i32, @intCast(candidate_pos))) break;
                    candidate_pos -= @intCast(next_ml);
                }
            }
            var r: usize = 0;
            while (r < last_match_pos) {
                const ml = opt[r].mlen;
                const off = opt[r].off;
                if (ml == 1) {
                    ip += 1;
                    r += 1;
                    continue;
                }
                r += @intCast(ml);
                if (!e.sequence(src, &ip, ml, off)) return e.overflow(src, &ip, .{ .len = ml, .off = off });
            }
        }
        return e.last(src);
    }

    /// The prices a match found at `cur` makes: literals up to it, then
    /// each of its lengths, where cheaper than the path there so far.
    fn priceMatch(opt: *[opt_num + trailing_literals]Cost, cur: usize, new: Match, last_match_pos: *usize, fav: i32) void {
        const base_litlen = opt[cur].litlen;
        var litlen: i32 = 1;
        while (litlen < seq.min_match) : (litlen += 1) {
            const price = opt[cur].price - literalsPrice(base_litlen) + literalsPrice(base_litlen + litlen);
            const pos = cur + @as(usize, @intCast(litlen));
            if (price < opt[pos].price) opt[pos] = .{ .mlen = 1, .off = 0, .litlen = base_litlen + litlen, .price = price };
        }
        var ml: i32 = seq.min_match;
        while (ml <= new.len) : (ml += 1) {
            const pos = cur + @as(usize, @intCast(ml));
            var ll: i32 = undefined;
            var price: i32 = undefined;
            if (opt[cur].mlen == 1) {
                ll = opt[cur].litlen;
                const before: i32 = if (@as(i32, @intCast(cur)) > ll) opt[cur - @as(usize, @intCast(ll))].price else 0;
                price = before + sequencePrice(ll, ml);
            } else {
                ll = 0;
                price = opt[cur].price + sequencePrice(0, ml);
            }
            if (pos > last_match_pos.* + trailing_literals or price <= opt[pos].price - fav) {
                if (ml == new.len and last_match_pos.* < pos) last_match_pos.* = pos;
                opt[pos] = .{ .mlen = ml, .off = new.off, .litlen = ll, .price = price };
            }
        }
    }

    fn fillTrailing(opt: *[opt_num + trailing_literals]Cost, last_match_pos: usize) void {
        for (1..trailing_literals + 1) |add| {
            const a: i32 = @intCast(add);
            opt[last_match_pos + add] = .{ .mlen = 1, .off = 0, .litlen = a, .price = opt[last_match_pos].price + literalsPrice(a) };
        }
    }

    // ---- Level 2 ----

    fn hash4(bytes: []const u8) u32 {
        return (std.mem.readInt(u32, bytes[0..4], .little) *% 2654435761) >> (32 - mid_hash_log);
    }

    fn hash8(bytes: []const u8) u32 {
        const value = std.mem.readInt(u64, bytes[0..8], .little);
        return @intCast(((value << 8) *% 58295818150454627) >> (64 - mid_hash_log));
    }

    fn table4(c: *Chains) *[1 << mid_hash_log]u32 {
        return c.hash[0 .. 1 << mid_hash_log];
    }

    fn table8(c: *Chains) *[1 << mid_hash_log]u32 {
        return c.hash[1 << mid_hash_log ..][0 .. 1 << mid_hash_log];
    }

    /// LZ4MID's dictionary indexing (`LZ4MID_fillHTable`).
    fn midFill(c: *Chains, v: View) void {
        const size = v.src.len;
        if (size <= 8) return;
        const prefix_idx = v.prefix_idx;
        const target = prefix_idx + @as(u32, @intCast(size)) - 8;
        var idx = c.next_to_update;
        while (idx < target) : (idx += 3) {
            c.table4()[hash4(v.src[idx - prefix_idx ..])] = idx;
            c.table8()[hash8(v.src[idx + 1 - prefix_idx ..])] = idx + 1;
        }
        idx = if (size > 32 * 1024 + 8) target - 32 * 1024 else c.next_to_update;
        while (idx < target) : (idx += 1) c.table8()[hash8(v.src[idx - prefix_idx ..])] = idx;
        c.next_to_update = target;
    }

    fn midCompress(c: *Chains, comptime directive: seq.Directive, v_in: View, out: []u8, dict: ?Dict) ?seq.Written {
        // A local copy: the caller's may alias the tables, and its fields
        // would be loaded again after every store into them.
        var v = v_in;
        _ = &v;
        const src = v.src;
        const t4 = c.table4();
        const t8 = c.table8();
        var e: Encoder(directive) = .init(out, v.begin);
        var ip: usize = v.begin;
        if (src.len - v.begin < seq.min_length) return e.last(src);
        const mflimit = src.len - seq.mf_limit;
        const match_limit = src.len - seq.last_literals;
        const ilimit = src.len - 8;
        const prefix_idx = v.prefix_idx;
        const ilimit_idx = prefix_idx + @as(u32, @intCast(ilimit));
        const dict_idx = c.low_limit;
        const g_dict_end = c.low_limit;

        while (ip <= mflimit) {
            const ip_index = prefix_idx + @as(u32, @intCast(ip));
            var match_len: usize = 0;
            var distance: u32 = 0;
            found: {
                // A long match first.
                {
                    const h8 = hash8(src[ip..]);
                    const pos8 = t8[h8];
                    t8[h8] = ip_index;
                    if (ip_index - pos8 <= max_distance) {
                        if (pos8 >= prefix_idx) {
                            match_len = seq.countMatch(src[ip..match_limit], src[pos8 - prefix_idx ..]);
                            if (match_len >= seq.min_match) {
                                distance = ip_index - pos8;
                                break :found;
                            }
                        } else if (pos8 >= dict_idx) {
                            const mp = pos8 - dict_idx;
                            const safe = @min(prefix_idx - pos8, match_limit - ip);
                            match_len = seq.countMatch(src[ip..][0..safe], v.hist[mp..]);
                            if (match_len >= seq.min_match) {
                                distance = ip_index - pos8;
                                break :found;
                            }
                        }
                    }
                }
                // Then a short one.
                {
                    const h4 = hash4(src[ip..]);
                    const pos4 = t4[h4];
                    t4[h4] = ip_index;
                    if (ip_index - pos4 <= max_distance) {
                        if (pos4 >= prefix_idx) {
                            match_len = seq.countMatch(src[ip..match_limit], src[pos4 - prefix_idx ..]);
                            if (match_len >= seq.min_match) {
                                // A short match: check one position on for a longer.
                                const h8 = hash8(src[ip + 1 ..]);
                                const pos8 = t8[h8];
                                const m2_distance = ip_index + 1 -% pos8;
                                distance = ip_index - pos4;
                                if (m2_distance <= max_distance and pos8 >= prefix_idx and ip < mflimit) {
                                    const ml2 = seq.countMatch(src[ip + 1 .. match_limit], src[pos8 - prefix_idx ..]);
                                    if (ml2 > match_len) {
                                        t8[h8] = ip_index + 1;
                                        ip += 1;
                                        match_len = ml2;
                                        distance = m2_distance;
                                    }
                                }
                                break :found;
                            }
                        } else if (pos4 >= dict_idx) {
                            const mp = pos4 - dict_idx;
                            const safe = @min(prefix_idx - pos4, match_limit - ip);
                            match_len = seq.countMatch(src[ip..][0..safe], v.hist[mp..]);
                            if (match_len >= seq.min_match) {
                                distance = ip_index - pos4;
                                break :found;
                            }
                        }
                    }
                }
                // Nothing in the input: the dictionary.
                if (dict) |d| if (ip_index - g_dict_end < max_distance - 8) {
                    const m = if (d.chains.mid) midSearchDict(d, src, ip, ip_index, match_limit, g_dict_end) else d.hcSearch(src, ip, ip_index, match_limit, g_dict_end);
                    if (m.len >= seq.min_match) {
                        match_len = @intCast(m.len);
                        distance = @intCast(m.off);
                        break :found;
                    }
                };
                // Faster over input that does not compress.
                ip += 1 + ((ip - e.anchor) >> 9);
                continue;
            }
            // Catch back.
            while (ip > e.anchor and ip > distance and src[ip - 1] == src[ip - distance - 1]) {
                ip -= 1;
                match_len += 1;
            }
            // Index the match's start: lz4 names these positions by the
            // index of where the search began, before the step to `ip + 1`
            // and the catch back, and so does this, for its bytes.
            t8[hash8(src[ip + 1 ..])] = ip_index + 1;
            t8[hash8(src[ip + 2 ..])] = ip_index + 2;
            t4[hash4(src[ip + 1 ..])] = ip_index + 1;
            if (!e.sequence(src, &ip, @intCast(match_len), @intCast(distance))) return e.overflow(src, &ip, .{ .len = @intCast(match_len), .off = @intCast(distance) });
            // And its end.
            const end_idx = prefix_idx + @as(u32, @intCast(ip));
            if (end_idx - 2 < ilimit_idx) {
                if (ip > 5) t8[hash8(src[ip - 5 ..])] = end_idx - 5;
                t8[hash8(src[ip - 3 ..])] = end_idx - 3;
                t8[hash8(src[ip - 2 ..])] = end_idx - 2;
                t4[hash4(src[ip - 2 ..])] = end_idx - 2;
                t4[hash4(src[ip - 1 ..])] = end_idx - 1;
            }
        }
        return e.last(src);
    }
};

/// An attached dictionary: its bytes and the chains that index them.
const Dict = struct {
    chains: *const Chains,
    bytes: []const u8,

    /// A chains dictionary searched for LZ4MID: two candidates.
    fn hcSearch(d: Dict, src: []const u8, ip: usize, ip_index: u32, i_high: usize, g_dict_end: u32) Match {
        const dc = d.chains;
        const dict_end = dc.end_idx;
        var dict_match = dc.hash[Chains.hashPtr(src[ip..])];
        var m = dict_match +% g_dict_end -% dict_end;
        var longest: i32 = seq.min_match - 1;
        var offset: i32 = 0;
        var attempts: i32 = 2;
        const pattern = read32(src[ip..]);
        while (ip_index -% m <= max_distance and attempts > 0) {
            attempts -= 1;
            const mp = dict_match -% dc.prefix_idx;
            if (mp + 4 <= d.bytes.len and read32(d.bytes[mp..]) == pattern) {
                const v_limit = @min(ip + (dict_end - dict_match), i_high);
                const mlt: i32 = @intCast(seq.countMatch(src[ip + seq.min_match .. v_limit], d.bytes[mp + seq.min_match ..]) + seq.min_match);
                if (mlt > longest) {
                    longest = mlt;
                    offset = @intCast(ip_index -% m);
                }
            }
            const next = dc.chain[@as(u16, @truncate(dict_match))];
            dict_match -%= next;
            m -%= next;
        }
        return .{ .len = longest, .off = offset };
    }
};

/// LZ4MID's search of a dictionary indexed for LZ4MID.
fn midSearchDict(d: Dict, src: []const u8, ip: usize, ip_index: u32, i_high: usize, g_dict_end: u32) Match {
    const dc = d.chains;
    const dict_end = dc.end_idx;
    const t4 = dc.hash[0 .. 1 << mid_hash_log];
    const t8 = dc.hash[1 << mid_hash_log ..][0 .. 1 << mid_hash_log];
    for ([_]u32{ t8[Chains.hash8(src[ip..])], t4[Chains.hash4(src[ip..])] }) |l_dict| {
        const m = l_dict +% g_dict_end -% dict_end;
        if (ip_index -% m <= max_distance) {
            const mp = l_dict -% dc.prefix_idx;
            if (mp < d.bytes.len) {
                const safe = @min(dict_end - l_dict, i_high - ip);
                const mlt = seq.countMatch(src[ip..][0..safe], d.bytes[mp..]);
                if (mlt >= seq.min_match) return .{ .len = @intCast(mlt), .off = @intCast(ip_index -% m) };
            }
        }
    }
    return .{};
}

/// The input and the history before it, in virtual positions: `src` from
/// `begin` is the input, before it history in the same memory (lz4's
/// prefix), and `hist` history elsewhere (its external dictionary).
const View = struct {
    src: []const u8,
    begin: usize = 0,
    prefix_idx: u32,
    hist: []const u8,
    dict_idx: u32,
};

/// Sequences written as lz4hc writes them, with its room checks.
fn Encoder(comptime directive: seq.Directive) type {
    return struct {
        const Self = @This();
        o: seq.Out,
        /// The output's end as the parser checks it: room for the last
        /// literals is kept back while filling.
        end: usize,
        anchor: usize = 0,
        /// Where the parse started: the input taken counts from here.
        begin: usize = 0,
        /// The output before the last sequence tried.
        saved: usize = 0,

        fn init(out: []u8, begin: usize) Self {
            return .{ .o = .{ .buf = out }, .end = if (directive == .fill) out.len -| seq.last_literals else out.len, .anchor = begin, .begin = begin };
        }

        /// One sequence: literals from the anchor to `ip.*`, then the match.
        /// False when it does not fit (never for `.unlimited`).
        fn sequence(e: *Self, src: []const u8, ip: *usize, ml: i32, off: i32) bool {
            e.saved = e.o.pos;
            const lits = src[e.anchor..ip.*];
            if (directive != .unlimited and e.o.pos + 1 + lits.len / 255 + lits.len + 2 + 1 + seq.last_literals > e.end) return false;
            const token = e.o.literalsBefore(src, e.anchor, ip.*);
            e.o.offset(@intCast(off));
            const code: usize = @intCast(ml - seq.min_match);
            if (directive != .unlimited and e.o.pos + code / 255 + 1 + seq.last_literals > e.end) {
                e.o.pos = e.saved;
                return false;
            }
            e.o.matchLength(token, code);
            ip.* += @intCast(ml);
            e.anchor = ip.*;
            return true;
        }

        /// A sequence that did not fit: refused for `.limited`; for `.fill`,
        /// shortened to fit, or dropped, then the last literals.
        fn overflow(e: *Self, src: []const u8, ip: *usize, m: Match) ?seq.Written {
            if (directive != .fill) return null;
            e.o.pos = e.saved;
            const ll = ip.* - e.anchor;
            const ll_cost = 1 + (ll + 240) / 255 + ll;
            const max_lit_pos = e.end -| 3;
            if (e.o.pos + ll_cost <= max_lit_pos) {
                const left = max_lit_pos - (e.o.pos + ll_cost);
                const max_ml = seq.min_match + (15 - 1) + left * 255;
                var ml: usize = @intCast(m.len);
                if (ml > max_ml) ml = max_ml;
                if ((e.end + seq.last_literals) - (e.o.pos + ll_cost + 2) - 1 + ml >= seq.mf_limit) {
                    const token = e.o.literalsBefore(src, e.anchor, ip.*);
                    e.o.offset(@intCast(m.off));
                    e.o.matchLength(token, ml - seq.min_match);
                    ip.* += ml;
                    e.anchor = ip.*;
                }
            }
            return e.last(src);
        }

        fn last(e: *Self, src: []const u8) ?seq.Written {
            return e.o.last(directive, src, e.anchor, e.begin);
        }
    };
}

fn literalsPrice(litlen: i32) i32 {
    var price = litlen;
    if (litlen >= 15) price += 1 + @divTrunc(litlen - 15, 255);
    return price;
}

fn sequencePrice(litlen: i32, mlen: i32) i32 {
    var price: i32 = 1 + 2 + literalsPrice(litlen);
    if (mlen >= 15 + seq.min_match) price += 1 + @divTrunc(mlen - (15 + seq.min_match), 255);
    return price;
}

inline fn length(m: Match) usize {
    return @intCast(m.len);
}

inline fn len2(ml: i32) usize {
    return @intCast(ml);
}

inline fn addBack(pos: usize, back: i32) usize {
    return @intCast(@as(isize, @intCast(pos)) + back);
}

inline fn read32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

inline fn read16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}

/// The equal bytes before `a[ip]` and `b[mp]` (as a negative count), at
/// most back to `a[a_min]` and `b[b_min]`.
fn countBack(a: []const u8, ip: usize, b: []const u8, mp: usize, a_min: usize, b_min: usize) i32 {
    const limit = @min(ip - a_min, mp - b_min);
    var back: usize = 0;
    while (limit - back > 3) {
        const x = read32(a[ip - back - 4 ..]) ^ read32(b[mp - back - 4 ..]);
        if (x != 0) return -@as(i32, @intCast(back + @clz(x) / 8));
        back += 4;
    }
    while (back < limit and a[ip - back - 1] == b[mp - back - 1]) back += 1;
    return -@as(i32, @intCast(back));
}

fn rotatePattern(rotate: usize, pattern: u32) u32 {
    const bits: u5 = @intCast((rotate & 3) << 3);
    if (bits == 0) return pattern;
    return std.math.rotl(u32, pattern, bits);
}

/// How far the 1-, 2- or 4-byte `pattern` repeats from `bytes[at]` on,
/// below `end`.
fn countPattern(bytes: []const u8, at: usize, end: usize, pattern32: u32) usize {
    const pattern: u64 = @as(u64, pattern32) | (@as(u64, pattern32) << 32);
    var ip = at;
    while (ip + 8 <= end) {
        const diff = std.mem.readInt(u64, bytes[ip..][0..8], .little) ^ pattern;
        if (diff == 0) {
            ip += 8;
            continue;
        }
        return ip + @ctz(diff) / 8 - at;
    }
    var p = pattern;
    while (ip < end and bytes[ip] == @as(u8, @truncate(p))) {
        ip += 1;
        p >>= 8;
    }
    return ip - at;
}

/// How far `pattern` repeats backwards before `bytes[at]`, above `low`.
fn reverseCountPattern(bytes: []const u8, at: usize, low: usize, pattern: u32) usize {
    var ip = at;
    while (ip >= low + 4) {
        if (read32(bytes[ip - 4 ..]) != pattern) break;
        ip -= 4;
    }
    var i: u5 = 24;
    while (ip > low) {
        if (bytes[ip - 1] != @as(u8, @truncate(pattern >> i))) break;
        ip -= 1;
        if (i == 0) break;
        i -= 8;
    }
    return at - ip;
}

/// Whether reading four bytes at `match_index` stays inside its segment.
fn protectDictEnd(dict_limit: u32, match_index: u32) bool {
    return (dict_limit -% 1 -% match_index) >= 3;
}
