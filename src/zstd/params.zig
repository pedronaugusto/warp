//! Compression parameters: the reference encoder's level table (four
//! tables by input size, levels 1-22 and a base for the negative levels)
//! and its adjustment to a known input size, so a level means here what it
//! means there.

const std = @import("std");
const Strategy = @import("sequences.zig").Strategy;

pub const min_level: i32 = -(1 << 17);
pub const max_level: i32 = 22;
pub const default_level: i32 = 3;

pub const window_log_min = 10;
pub const window_log_max = if (@sizeOf(usize) == 4) 30 else 31;
pub const hash_log_min = 6;

pub const Params = struct {
    window_log: u5,
    chain_log: u5,
    hash_log: u5,
    search_log: u5,
    min_match: u3,
    /// The length a match search stops at; for `fast`, the acceleration.
    target_length: u32,
    strategy: Strategy,
};

const P = struct { u5, u5, u5, u5, u3, u32, Strategy };

fn row(p: P) Params {
    return .{ .window_log = p[0], .chain_log = p[1], .hash_log = p[2], .search_log = p[3], .min_match = p[4], .target_length = p[5], .strategy = p[6] };
}

/// [size class][level]: any size, up to 256 KiB, up to 128 KiB, up to 16 KiB.
const table = [4][23]Params{
    .{
        row(.{ 19, 12, 13, 1, 6, 1, .fast }),       row(.{ 19, 13, 14, 1, 7, 0, .fast }),       row(.{ 20, 15, 16, 1, 6, 0, .fast }),
        row(.{ 21, 16, 17, 1, 5, 0, .dfast }),      row(.{ 21, 18, 18, 1, 5, 0, .dfast }),      row(.{ 21, 18, 19, 3, 5, 2, .greedy }),
        row(.{ 21, 18, 19, 3, 5, 4, .lazy }),       row(.{ 21, 19, 20, 4, 5, 8, .lazy }),       row(.{ 21, 19, 20, 4, 5, 16, .lazy2 }),
        row(.{ 22, 20, 21, 4, 5, 16, .lazy2 }),     row(.{ 22, 21, 22, 5, 5, 16, .lazy2 }),     row(.{ 22, 21, 22, 6, 5, 16, .lazy2 }),
        row(.{ 22, 22, 23, 6, 5, 32, .lazy2 }),     row(.{ 22, 22, 22, 4, 5, 32, .btlazy2 }),   row(.{ 22, 22, 23, 5, 5, 32, .btlazy2 }),
        row(.{ 22, 23, 23, 6, 5, 32, .btlazy2 }),   row(.{ 22, 22, 22, 5, 5, 48, .btopt }),     row(.{ 23, 23, 22, 5, 4, 64, .btopt }),
        row(.{ 23, 23, 22, 6, 3, 64, .btultra }),   row(.{ 23, 24, 22, 7, 3, 256, .btultra2 }), row(.{ 25, 25, 23, 7, 3, 256, .btultra2 }),
        row(.{ 26, 26, 24, 7, 3, 512, .btultra2 }), row(.{ 27, 27, 25, 9, 3, 999, .btultra2 }),
    },
    .{
        row(.{ 18, 12, 13, 1, 5, 1, .fast }),        row(.{ 18, 13, 14, 1, 6, 0, .fast }),        row(.{ 18, 14, 14, 1, 5, 0, .dfast }),
        row(.{ 18, 16, 16, 1, 4, 0, .dfast }),       row(.{ 18, 16, 17, 3, 5, 2, .greedy }),      row(.{ 18, 17, 18, 5, 5, 2, .greedy }),
        row(.{ 18, 18, 19, 3, 5, 4, .lazy }),        row(.{ 18, 18, 19, 4, 4, 4, .lazy }),        row(.{ 18, 18, 19, 4, 4, 8, .lazy2 }),
        row(.{ 18, 18, 19, 5, 4, 8, .lazy2 }),       row(.{ 18, 18, 19, 6, 4, 8, .lazy2 }),       row(.{ 18, 18, 19, 5, 4, 12, .btlazy2 }),
        row(.{ 18, 19, 19, 7, 4, 12, .btlazy2 }),    row(.{ 18, 18, 19, 4, 4, 16, .btopt }),      row(.{ 18, 18, 19, 4, 3, 32, .btopt }),
        row(.{ 18, 18, 19, 6, 3, 128, .btopt }),     row(.{ 18, 19, 19, 6, 3, 128, .btultra }),   row(.{ 18, 19, 19, 8, 3, 256, .btultra }),
        row(.{ 18, 19, 19, 6, 3, 128, .btultra2 }),  row(.{ 18, 19, 19, 8, 3, 256, .btultra2 }),  row(.{ 18, 19, 19, 10, 3, 512, .btultra2 }),
        row(.{ 18, 19, 19, 12, 3, 512, .btultra2 }), row(.{ 18, 19, 19, 13, 3, 999, .btultra2 }),
    },
    .{
        row(.{ 17, 12, 12, 1, 5, 1, .fast }),       row(.{ 17, 12, 13, 1, 6, 0, .fast }),        row(.{ 17, 13, 15, 1, 5, 0, .fast }),
        row(.{ 17, 15, 16, 2, 5, 0, .dfast }),      row(.{ 17, 17, 17, 2, 4, 0, .dfast }),       row(.{ 17, 16, 17, 3, 4, 2, .greedy }),
        row(.{ 17, 16, 17, 3, 4, 4, .lazy }),       row(.{ 17, 16, 17, 3, 4, 8, .lazy2 }),       row(.{ 17, 16, 17, 4, 4, 8, .lazy2 }),
        row(.{ 17, 16, 17, 5, 4, 8, .lazy2 }),      row(.{ 17, 16, 17, 6, 4, 8, .lazy2 }),       row(.{ 17, 17, 17, 5, 4, 8, .btlazy2 }),
        row(.{ 17, 18, 17, 7, 4, 12, .btlazy2 }),   row(.{ 17, 18, 17, 3, 4, 12, .btopt }),      row(.{ 17, 18, 17, 4, 3, 32, .btopt }),
        row(.{ 17, 18, 17, 6, 3, 256, .btopt }),    row(.{ 17, 18, 17, 6, 3, 128, .btultra }),   row(.{ 17, 18, 17, 8, 3, 256, .btultra }),
        row(.{ 17, 18, 17, 10, 3, 512, .btultra }), row(.{ 17, 18, 17, 5, 3, 256, .btultra2 }),  row(.{ 17, 18, 17, 7, 3, 512, .btultra2 }),
        row(.{ 17, 18, 17, 9, 3, 512, .btultra2 }), row(.{ 17, 18, 17, 11, 3, 999, .btultra2 }),
    },
    .{
        row(.{ 14, 12, 13, 1, 5, 1, .fast }),       row(.{ 14, 14, 15, 1, 5, 0, .fast }),        row(.{ 14, 14, 15, 1, 4, 0, .fast }),
        row(.{ 14, 14, 15, 2, 4, 0, .dfast }),      row(.{ 14, 14, 14, 4, 4, 2, .greedy }),      row(.{ 14, 14, 14, 3, 4, 4, .lazy }),
        row(.{ 14, 14, 14, 4, 4, 8, .lazy2 }),      row(.{ 14, 14, 14, 6, 4, 8, .lazy2 }),       row(.{ 14, 14, 14, 8, 4, 8, .lazy2 }),
        row(.{ 14, 15, 14, 5, 4, 8, .btlazy2 }),    row(.{ 14, 15, 14, 9, 4, 8, .btlazy2 }),     row(.{ 14, 15, 14, 3, 4, 12, .btopt }),
        row(.{ 14, 15, 14, 4, 3, 24, .btopt }),     row(.{ 14, 15, 14, 5, 3, 32, .btultra }),    row(.{ 14, 15, 15, 6, 3, 64, .btultra }),
        row(.{ 14, 15, 15, 7, 3, 256, .btultra }),  row(.{ 14, 15, 15, 5, 3, 48, .btultra2 }),   row(.{ 14, 15, 15, 6, 3, 128, .btultra2 }),
        row(.{ 14, 15, 15, 7, 3, 256, .btultra2 }), row(.{ 14, 15, 15, 8, 3, 256, .btultra2 }),  row(.{ 14, 15, 15, 8, 3, 512, .btultra2 }),
        row(.{ 14, 15, 15, 9, 3, 512, .btultra2 }), row(.{ 14, 15, 15, 10, 3, 999, .btultra2 }),
    },
};

/// The parameters for `level` on an input of `size` bytes (null: any
/// size) with a dictionary of `dict` bytes, as the reference picks them.
pub fn forLevel(level: i32, size: ?u64, dict: u64) Params {
    const row_size: ?u64 = if (size) |n| n + dict else if (dict > 0) dict + 500 else null;
    const class: usize = if (row_size) |r| @as(usize, @intFromBool(r <= 256 * 1024)) + @intFromBool(r <= 128 * 1024) + @intFromBool(r <= 16 * 1024) else 0;
    const index: usize = if (level == 0) default_level else if (level < 0) 0 else @intCast(@min(level, max_level));
    var p = table[class][index];
    if (level < 0) p.target_length = @intCast(-@max(level, min_level));
    return adjust(p, size, dict);
}

/// Shrink the window and tables to what an input of `size` bytes can use.
pub fn adjust(p_: Params, size: ?u64, dict: u64) Params {
    var p = p_;
    const resize_max: u64 = @as(u64, 1) << (window_log_max - 1);
    if (size) |n| {
        if (n <= resize_max and dict <= resize_max) {
            const total: u32 = @intCast(n + dict);
            const src_log: u5 = if (total < (1 << hash_log_min)) hash_log_min else @intCast(std.math.log2_int(u32, total - 1) + 1);
            if (p.window_log > src_log) p.window_log = src_log;
        }
        const dict_window = dictAndWindowLog(p.window_log, n, dict);
        const cycle = cycleLog(p.chain_log, p.strategy);
        if (p.hash_log > dict_window + 1) p.hash_log = dict_window + 1;
        if (cycle > dict_window) p.chain_log -= cycle - dict_window;
    }
    if (p.window_log < window_log_min) p.window_log = window_log_min;
    if (usesRows(p.strategy)) {
        const row_log: u5 = std.math.clamp(p.search_log, 4, 6);
        const max_hash: u5 = 32 - 8 + row_log;
        if (p.hash_log > max_hash) p.hash_log = max_hash;
    }
    return p;
}

fn dictAndWindowLog(window_log: u5, size: u64, dict: u64) u5 {
    if (dict == 0) return window_log;
    const window = @as(u64, 1) << window_log;
    if (window >= dict + size) return window_log;
    const both = dict + window;
    if (both >= @as(u64, 1) << window_log_max) return window_log_max;
    return @intCast(std.math.log2_int(u64, both - 1) + 1);
}

/// The span a chain or tree covers: binary trees use two entries a position.
pub fn cycleLog(chain_log: u5, strategy: Strategy) u5 {
    return chain_log - @intFromBool(@backingInt(strategy) >= @backingInt(Strategy.btlazy2));
}

/// Whether greedy, lazy and lazy2 search rows of a hash table rather than
/// chains (larger windows, as the reference decides).
pub fn usesRows(strategy: Strategy) bool {
    return strategy == .greedy or strategy == .lazy or strategy == .lazy2;
}

test "levels on small and unknown inputs pick the reference's rows" {
    const l3 = forLevel(3, null, 0);
    try std.testing.expectEqual(Strategy.dfast, l3.strategy);
    try std.testing.expectEqual(@as(u5, 21), l3.window_log);
    // A 37-byte input at level 3: the 16 KiB row, the window cut to the input.
    const tiny = forLevel(3, 37, 0);
    try std.testing.expectEqual(@as(u5, 10), tiny.window_log);
    try std.testing.expectEqual(@as(u5, 7), tiny.hash_log);
    const fast = forLevel(-5, null, 0);
    try std.testing.expectEqual(@as(u32, 5), fast.target_length);
    try std.testing.expectEqual(Strategy.btultra2, forLevel(19, null, 0).strategy);
}
