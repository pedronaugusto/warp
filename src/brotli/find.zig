//! What the encoder's match finders share: unaligned loads, the
//! reference's multiplicative hash constants, match lengths, the scores
//! that rank matches, and the matches themselves.

const std = @import("std");

pub const hash_mul32: u32 = 0x1E35A7BD;
pub const hash_mul64: u64 = 0x1FE35A7B_D3579BD3;

pub inline fn load64(data: []const u8, at: usize) u64 {
    return std.mem.readInt(u64, data[at..][0..8], .little);
}

pub inline fn load32(data: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, data[at..][0..4], .little);
}

/// How many bytes from `a` and `b` agree, at most `limit`.
pub inline fn matchLength(data: []const u8, a: usize, b: usize, limit: usize) usize {
    return matchLengthIn(data[a..], data[b..], limit);
}

/// `matchLength` between two buffers, each holding `limit` bytes or more.
/// The reference's loop: eight bytes compared at a step, then the rest one
/// at a time (bytes past `limit` are never read).
pub inline fn matchLengthIn(a: []const u8, b: []const u8, limit: usize) usize {
    var n: usize = 0;
    var left = limit;
    while (left >= 8) : (left -= 8) {
        const x = load64(b, n) ^ load64(a, n);
        if (x != 0) return n + (@ctz(x) >> 3);
        n += 8;
    }
    while (left != 0 and a[n] == b[n]) {
        left -= 1;
        n += 1;
    }
    return n;
}

pub const SearchResult = struct {
    len: usize,
    distance: usize,
    score: usize,
    /// The length code's difference from `len` (a dictionary word cut short).
    len_code_delta: i32,
};

pub const literal_byte_score = 135;
pub const distance_bit_penalty = 30;
/// Scores stay positive after the largest penalty.
pub const score_base = distance_bit_penalty * 8 * @sizeOf(usize);

pub inline fn backwardReferenceScore(copy_length: usize, backward: usize) usize {
    return score_base + literal_byte_score * copy_length - distance_bit_penalty * @as(usize, std.math.log2_int(usize, backward));
}

pub inline fn scoreUsingLastDistance(copy_length: usize) usize {
    return literal_byte_score * copy_length + score_base + 15;
}

pub inline fn penaltyUsingLastDistance(short_code: usize) usize {
    return 39 + ((@as(usize, 0x1CA10) >> @intCast(short_code & 0xE)) & 0xE);
}

/// A match: its distance, its length in the high bits and, for a
/// dictionary word cut short, the word's length in the low five.
pub const BackwardMatch = struct {
    distance: u32,
    length_and_code: u32,

    pub fn init(dist: usize, len: usize) BackwardMatch {
        return .{ .distance = @intCast(dist), .length_and_code = @intCast(len << 5) };
    }

    pub fn dictionary(dist: usize, len: usize, len_code: usize) BackwardMatch {
        return .{ .distance = @intCast(dist), .length_and_code = @intCast((len << 5) | (if (len == len_code) 0 else len_code)) };
    }

    pub inline fn length(m: BackwardMatch) usize {
        return m.length_and_code >> 5;
    }

    pub inline fn lengthCode(m: BackwardMatch) usize {
        const code = m.length_and_code & 31;
        return if (code != 0) code else m.length();
    }
};
