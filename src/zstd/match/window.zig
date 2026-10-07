//! What every matchfinder shares: the bytes searched, positions as
//! indices, the window's low end, hashing, and match lengths.
//!
//! Tables hold u32 indices. A call's input starts at index `start`, which
//! continues from the call before, so entries a previous call left are
//! below the window's low end and never match: a call clears nothing.

const std = @import("std");

/// The input of one call, and where its indices start.
pub const Window = struct {
    /// Everything the call compresses; matches reach anywhere before the
    /// position searched, down to `low`.
    in: []const u8,
    /// The index of `in[0]`.
    start: u32,
    /// The lowest index a match may start at.
    low: u32,

    pub inline fn index(w: Window, p: usize) u32 {
        return @intCast(p + w.start);
    }

    /// The position in `in` of index `idx`.
    pub inline fn at(w: Window, idx: u32) usize {
        return idx - w.start;
    }

    /// The low end for a block ending at `end`: a window of `window_log`
    /// bits back from it, not before the input.
    pub fn lowFor(w: Window, end: usize, window_log: u5) u32 {
        const end_idx: u64 = w.index(end);
        const window = @as(u64, 1) << window_log;
        return @intCast(@max(@as(u64, w.start), end_idx -| window));
    }
};

pub const prime4: u32 = 2654435761;
pub const prime5: u64 = 889523592379;
pub const prime6: u64 = 227718039650203;
pub const prime7: u64 = 58295818150454627;
pub const prime8: u64 = 0xCF1BBCDCB7A56463;

/// The reference encoder's hash of the `mls` bytes at `p`, to `bits` bits.
pub inline fn hash(in: []const u8, p: usize, bits: u5, comptime mls: u4) u32 {
    switch (mls) {
        4 => {
            const v = std.mem.readInt(u32, in[p..][0..4], .little);
            return (v *% prime4) >> @intCast(@as(u6, 32) - bits);
        },
        5, 6, 7, 8 => {
            const v = std.mem.readInt(u64, in[p..][0..8], .little);
            const prime = switch (mls) {
                5 => prime5,
                6 => prime6,
                7 => prime7,
                else => prime8,
            };
            const shifted = if (mls == 8) v else v << (64 - 8 * @as(u7, mls));
            return @intCast((shifted *% prime) >> @intCast(@as(u7, 64) - bits));
        },
        else => @compileError("hash of 4 to 8 bytes"),
    }
}

/// The length of the match between `in[a..]` and `in[b..]` (`a < b`),
/// counted up to `end`.
pub inline fn count(in: []const u8, a: usize, b: usize, end: usize) usize {
    var len: usize = 0;
    const limit = end - b;
    while (len + 8 <= limit) {
        const x = std.mem.readInt(u64, in[a + len ..][0..8], .little) ^ std.mem.readInt(u64, in[b + len ..][0..8], .little);
        if (x != 0) return len + @ctz(x) / 8;
        len += 8;
    }
    while (len < limit and in[a + len] == in[b + len]) len += 1;
    return len;
}

pub inline fn read32(in: []const u8, p: usize) u32 {
    return std.mem.readInt(u32, in[p..][0..4], .little);
}

test "hashes are the reference's, and counts stop at the end" {
    const in = "abcdefghabcdefgh-tail--";
    try std.testing.expectEqual((std.mem.readInt(u32, "abcd", .little) *% prime4) >> 18, hash(in, 0, 14, 4));
    try std.testing.expectEqual(hash(in, 0, 14, 6), hash(in, 8, 14, 6));
    try std.testing.expectEqual(@as(usize, 8), count(in, 0, 8, in.len));
    try std.testing.expectEqual(@as(usize, 5), count(in, 0, 8, 13));
}
