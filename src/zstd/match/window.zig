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

/// Temporarily disable a repeat offset that would precede available history.
/// Its original value is restored if the block does not replace it.
pub inline fn disableRep(rep: *u32, available: usize) u32 {
    if (rep.* <= available) return 0;
    const saved = rep.*;
    rep.* = 0;
    return saved;
}

/// Restore disabled repeat offsets while preserving the order after matches.
pub inline fn restoreReps(reps: *[3]u32, first: u32, second: u32, saved_first: u32, saved_second: u32) void {
    const last = if (saved_first != 0 and first != 0) saved_first else saved_second;
    reps[0] = if (first != 0) first else saved_first;
    reps[1] = if (second != 0) second else last;
}

pub const prime3: u32 = 506832829;
pub const prime4: u32 = 2654435761;
pub const prime5: u64 = 889523592379;
pub const prime6: u64 = 227718039650203;
pub const prime7: u64 = 58295818150454627;
pub const prime8: u64 = 0xCF1BBCDCB7A56463;

/// The reference encoder's hash of the `mls` bytes at `p`, to `bits` bits.
pub inline fn hash(comptime mls: u4, in: []const u8, p: usize, bits: u5) u32 {
    switch (mls) {
        3 => {
            const v = std.mem.readInt(u32, in[p..][0..4], .little);
            return ((v << 8) *% prime3) >> @intCast(@as(u6, 32) - bits);
        },
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

/// The input addressed by index: index `i` is the byte at `base + i`. One
/// register serves current positions and candidates alike, as in the
/// reference encoder's loops.
pub const Bytes = struct {
    base: usize,

    pub fn of(w: Window) Bytes {
        // safe: an address, only ever offset by indices of `w.in`
        return .{ .base = @intFromPtr(w.in.ptr) -% w.start }; // safe: an address, dereferenced only with an index into w.in
    }

    pub inline fn ptr(b: Bytes, i: usize) [*]const u8 {
        return @ptrFromInt(b.base +% i);
    }

    pub inline fn byte(b: Bytes, i: usize) u8 {
        return b.ptr(i)[0];
    }

    pub inline fn load32(b: Bytes, i: usize) u32 {
        return std.mem.readInt(u32, b.ptr(i)[0..4], .little);
    }

    pub inline fn load64(b: Bytes, i: usize) u64 {
        return std.mem.readInt(u64, b.ptr(i)[0..8], .little);
    }

    /// `hash` of the bytes at index `i`.
    pub inline fn hash(b: Bytes, comptime mls: u4, i: usize, bits: u5) u32 {
        switch (mls) {
            3 => return ((b.load32(i) << 8) *% prime3) >> @intCast(@as(u6, 32) - bits),
            4 => return (b.load32(i) *% prime4) >> @intCast(@as(u6, 32) - bits),
            5, 6, 7, 8 => {
                const v = b.load64(i);
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

    /// `count` by index: the match between `a` and `b` (`a < b`) up to `end`.
    pub inline fn count(b: Bytes, a: usize, c: usize, end: usize) usize {
        var len: usize = 0;
        const limit = end - c;
        while (len + 8 <= limit) {
            const x = b.load64(a + len) ^ b.load64(c + len);
            if (x != 0) return len + @ctz(x) / 8;
            len += 8;
        }
        while (len < limit and b.byte(a + len) == b.byte(c + len)) len += 1;
        return len;
    }
};

test "hashes are the reference's, and counts stop at the end" {
    const in = "abcdefghabcdefgh-tail--";
    try std.testing.expectEqual((std.mem.readInt(u32, "abcd", .little) *% prime4) >> 18, hash(4, in, 0, 14));
    try std.testing.expectEqual(hash(6, in, 0, 14), hash(6, in, 8, 14));
    try std.testing.expectEqual(@as(usize, 8), count(in, 0, 8, in.len));
    try std.testing.expectEqual(@as(usize, 5), count(in, 0, 8, 13));
}
