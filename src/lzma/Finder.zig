//! The LZMA encoder's view of warp's matchfinders: matches from two bytes
//! up, at distances within the dictionary, as liblzma's hc3, hc4 and bt4
//! give them to its parsers (lengths increasing, each to `nice_len`, the
//! longest then extended to 273 where it reached that), over a buffer the
//! encoder fills. With tables sized for the dictionary, the matches are
//! liblzma's: the same hashes and table sizes, the same chains and trees,
//! reaching as liblzma's window of the dictionary and one more position
//! does, to a match exactly the dictionary back.
//!
//! Positions count in the buffer; `read_pos` is the next to search,
//! `read_ahead` how many searched positions the coder has not yet coded,
//! `read_limit` where searching waits for more input (the buffer's end
//! once the input is finishing).

const std = @import("std");
const match = @import("../match.zig");
const encode = @import("encode.zig");

/// liblzma's matchfinders.
pub const Kind = enum {
    /// Hash chains over three bytes (preset 0).
    hc3,
    /// Hash chains over four bytes (presets 1-3).
    hc4,
    /// Binary trees over four bytes (presets 4-9).
    bt4,
};

/// The finders' window: any dictionary LZMA takes (1.5 GiB at most).
const window = 1 << 31;

pub const Trees = match.BinaryTreesWith(.{ .window = window, .shortest = 2 });
pub const Chains4 = match.HashChainsWith(.{ .window = window, .shortest = 2, .chain = 4 });
pub const Chains3 = match.HashChainsWith(.{ .window = window, .shortest = 2, .chain = 3 });
const Pos = i32;

/// The tables' sizes for a dictionary of `dictionary` bytes over inputs
/// of at most `span` bytes (null: any): liblzma's hash sizes, the trees
/// or chains a power of two covering the dictionary or the input.
pub const Sizes = struct {
    hash3_bits: u5,
    hash4_bits: u5,
    /// Positions the chains or trees keep.
    slots: usize,

    pub fn of(kind: Kind, dictionary: u32, span: ?usize) Sizes {
        const reach: u64 = if (span) |n| @min(dictionary, @max(n, 1)) else dictionary;
        // liblzma's: half the dictionary rounded up to a power of two, at
        // least 64 Ki entries, at most 16 Mi for three bytes, halved past
        // 16 Mi for four.
        var bits: u32 = @max(std.math.log2_int_ceil(u64, @max(reach, 2)) - 1, 16);
        if (bits > 24) bits = if (kind == .hc3) 24 else bits - 1;
        // liblzma's hash of three bytes spans 64 Ki entries.
        const bits3: u32 = if (kind == .hc3) 0 else 16;
        if (span) |n| if (n < 1 << 16) {
            // A short input fills few entries: a table of its size.
            bits = @min(bits, @max(std.math.log2_int_ceil(u64, @max(n, 2)), 6));
        };
        return .{
            .hash3_bits = @intCast(bits3),
            .hash4_bits = @intCast(bits),
            .slots = std.math.ceilPowerOfTwoAssert(u64, @max(reach, 64)),
        };
    }

    /// The tables' bytes.
    pub fn memory(s: Sizes, kind: Kind) usize {
        return switch (kind) {
            .bt4 => Trees.memory(s.hash3_bits, s.hash4_bits, s.slots),
            .hc4 => Chains4.memory(s.hash4_bits, s.hash3_bits, s.slots),
            .hc3 => Chains3.memory(s.hash4_bits, s.hash3_bits, s.slots),
        };
    }
};

pub fn Finder(comptime kind: Kind) type {
    return struct {
        const Self = @This();
        pub const Tables = switch (kind) {
            .bt4 => Trees,
            .hc4 => Chains4,
            .hc3 => Chains3,
        };
        const Match = Tables.Match;
        /// A search needs this many bytes from its position: 3 for hc3, 4
        /// for the others, as liblzma's.
        pub const required = Tables.required;

        tables: Tables,
        sizes: Sizes,
        buf: []const u8 = &.{},
        read_pos: usize = 0,
        read_ahead: u32 = 0,
        read_limit: usize = 0,
        /// The buffer's bytes are all the input there is.
        finishing: bool = false,
        nice_len: u32,
        depth: u32,
        dictionary: u32,

        /// Tables in `memory` (at least `sizes.memory(kind)` bytes, aligned
        /// to 4).
        pub fn init(memory: []align(4) u8, sizes: Sizes, dictionary: u32, nice_len: u32, depth: u32) Self {
            const all: []Pos = std.mem.bytesAsSlice(Pos, memory);
            var at: usize = 0;
            const take = struct {
                fn f(from: []Pos, a: *usize, n: usize) []Pos {
                    defer a.* += n;
                    return from[a.*..][0..n];
                }
            }.f;
            var tables: Tables = undefined;
            switch (kind) {
                .bt4 => {
                    tables = .{
                        .hash2 = take(all, &at, 1 << Trees.hash2_bits),
                        .hash3 = std.mem.bytesAsSlice([2]Pos, std.mem.sliceAsBytes(take(all, &at, (@as(usize, 1) << sizes.hash3_bits) * 2))),
                        .hash4 = take(all, &at, @as(usize, 1) << sizes.hash4_bits),
                        .child = take(all, &at, sizes.slots * 2),
                    };
                    tables.window = @intCast(@min(dictionary, sizes.slots) + 1);
                },
                .hc4, .hc3 => {
                    tables = .{
                        .hash2 = take(all, &at, 1 << Tables.hash2_bits),
                        .hash4 = take(all, &at, @as(usize, 1) << sizes.hash4_bits),
                        .hash3 = take(all, &at, @as(usize, 1) << sizes.hash3_bits),
                        .prev = take(all, &at, sizes.slots),
                    };
                    tables.reach = @intCast(@min(dictionary, sizes.slots) + 1);
                },
            }
            return .{ .tables = tables, .sizes = sizes, .nice_len = nice_len, .depth = depth, .dictionary = dictionary };
        }

        /// Start over on a new stream (the dictionary reset).
        pub fn reset(f: *Self) void {
            switch (kind) {
                .bt4 => f.tables.reset(0, f.sizes.hash3_bits, f.sizes.hash4_bits),
                .hc4, .hc3 => f.tables.reset(0, f.sizes.hash4_bits, f.sizes.hash3_bits),
            }
            f.read_pos = 0;
            f.read_ahead = 0;
            f.read_limit = 0;
            f.finishing = false;
        }

        /// Bytes from `read_pos` to the buffer's end.
        pub inline fn avail(f: *const Self) usize {
            return f.buf.len - f.read_pos;
        }

        /// The matches at `read_pos` into `out`, their count into `count`;
        /// the longest one's length (0 for none). Moves on a position.
        pub fn find(f: *Self, out: *[encode.match_len_max + 1]encode.Pair, count: *u32) u32 {
            const left = f.avail();
            f.read_ahead += 1;
            if (left < required) {
                // Too near the end to hash: nothing found, nothing kept.
                f.read_pos += 1;
                count.* = 0;
                return 0;
            }
            const limit: u32 = @intCast(@min(left, f.nice_len));
            const p = f.read_pos;
            const h: match.History = .{ .in = f.buf };
            var found: [encode.match_len_max + 1]Match = undefined;
            const n = switch (kind) {
                .bt4 => f.tables.matches(false, false, h, @intCast(p), limit, limit, f.depth, &found),
                .hc4, .hc3 => f.tables.matches(h, @intCast(p), limit, f.depth, &found),
            };
            f.read_pos += 1;
            count.* = @intCast(n);
            if (n == 0) return 0;
            for (found[0..n], out[0..n]) |m, *o| o.* = .{ .len = m.length, .dist = m.offset - 1 };
            var longest: u32 = out[n - 1].len;
            if (longest == f.nice_len) {
                const max: u32 = @intCast(@min(left, encode.match_len_max));
                longest = match.matchLengthIn(f.buf, p - out[n - 1].dist - 1, p, longest, max);
            }
            return longest;
        }

        /// `n` positions inserted without their matches.
        pub fn skip(f: *Self, n: u32) void {
            f.read_ahead += n;
            const h: match.History = .{ .in = f.buf };
            for (0..n) |_| {
                const left = f.avail();
                if (left >= required) {
                    const limit: u32 = @intCast(@min(left, f.nice_len));
                    switch (kind) {
                        .bt4 => f.tables.skip(false, false, h, @intCast(f.read_pos), limit, f.depth),
                        .hc4, .hc3 => f.tables.skip(false, h, @intCast(f.read_pos), 1),
                    }
                }
                f.read_pos += 1;
            }
        }
    };
}

test "each finder reaches a match exactly the dictionary back, as liblzma's does, and none farther" {
    const dictionary = 4096;
    var prng: std.Random.DefaultPrng = .init(7);
    const r = prng.random();
    // Random bytes; then 200 bytes again a dictionary back, and
    // others a dictionary and one byte back; then a repeat
    // nearer, so the chains and trees serve searches after their edge.
    var in: [3 * dictionary]u8 = undefined;
    r.bytes(&in);
    @memcpy(in[dictionary..][0..200], in[0..200]);
    @memcpy(in[2 * dictionary + 1 ..][0..200], in[dictionary + 1000 ..][0..200]);
    @memcpy(in[2 * dictionary + 2000 ..][0..200], in[2 * dictionary + 500 ..][0..200]);
    inline for (.{ Kind.hc3, Kind.hc4, Kind.bt4 }) |kind| {
        const sizes: Sizes = .of(kind, dictionary, null);
        const memory = try std.testing.allocator.alignedAlloc(u8, .@"4", sizes.memory(kind));
        defer std.testing.allocator.free(memory);
        var f: Finder(kind) = .init(memory, sizes, dictionary, 64, 48);
        f.reset();
        f.buf = &in;
        var out: [encode.match_len_max + 1]encode.Pair = undefined;
        var count: u32 = 0;
        for (0..in.len) |p| {
            const longest = f.find(&out, &count);
            // Every match is real and within the dictionary.
            for (out[0..count]) |m| {
                try std.testing.expect(m.dist < dictionary and m.dist < p);
                try std.testing.expectEqualSlices(u8, in[p - m.dist - 1 ..][0..m.len], in[p..][0..m.len]);
            }
            if (p == dictionary) {
                try std.testing.expectEqual(dictionary - 1, out[count - 1].dist);
                try std.testing.expectEqual(200, longest);
            }
            if (p == 2 * dictionary + 1) for (out[0..count]) |m| try std.testing.expect(m.len < 4 or m.dist < dictionary - 1);
            if (p == 2 * dictionary + 2000) try std.testing.expectEqual(200, longest);
        }
    }
}
