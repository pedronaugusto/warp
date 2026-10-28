//! The LZ4 block format decoded: sequences of literals and a match, into
//! the caller's output, which is its own history, after an optional
//! history slice (a dictionary, or the blocks before this one).
//!
//! The fast loop decodes whole sequences while each one's literals and
//! match, copied in 16- and 32-byte stores, stay inside both buffers; any
//! sequence it cannot take so is decoded by the careful loop, one at a
//! time with every bound checked, after which the fast loop goes on. So an
//! output of exactly the decoded size works, and `margin` more bytes only
//! let the fast loop run to the end. What a block decodes to, and whether
//! it is refused, never depends on the spare output.

const std = @import("std");
const Diagnostic = @import("Diagnostic.zig");
const copy = @import("../match/copy.zig");
const chainless = copy.chainless;
const copyMatch = copy.copyMatch;

/// The shortest match.
pub const min_match = 4;
/// Spare output past a block's decoded size that lets the fast loop run to
/// its last sequence: the farthest a literal's 32-byte stores reach.
pub const margin = 32;
/// The farthest a match reaches back.
pub const max_offset = 65535;

pub const Error = error{
    /// A sequence the format does not define, or a match before the history.
    InvalidStream,
    /// The input ends inside a sequence, or before the last one.
    Truncated,
    /// The block decodes to more than the output holds.
    OutputTooSmall,
};

pub const Result = struct {
    /// What this call wrote: `out` from `start` to where the output ends.
    written: []u8,
    /// The whole block was decoded (always, unless `partial` stopped it at a
    /// full output).
    finished: bool,
};

pub const Options = struct {
    /// Bytes before `out[0]` that matches may reach into.
    history: []const u8 = &.{},
    /// Stop without error when the output is full.
    partial: bool = false,
    diagnostic: ?*Diagnostic = null,
    /// Where `in` starts in the caller's input, for the diagnostic.
    in_base: u64 = 0,
};

/// Decode the block `in` into `out[start..]`; matches reach back through
/// `out[0..start]` and then into `options.history`. Bytes of `out` past
/// `Result.op` may have been written.
pub noinline fn decode(in: []const u8, out: []u8, start: usize, options: Options) Error!Result {
    var d: Decoder = .{ .in = in, .out = out, .op = start, .history = options.history, .options = options };
    while (true) {
        d.fast();
        switch (try d.careful()) {
            .more => {},
            .done => return .{ .written = d.out[start..d.op], .finished = true },
            .full => return .{ .written = d.out[start..d.op], .finished = false },
        }
    }
}

const Decoder = struct {
    in: []const u8,
    out: []u8,
    ip: usize = 0,
    op: usize,
    history: []const u8,
    options: Options,

    const Next = enum { more, done, full };

    /// Decode whole sequences while each fits with the fast loop's stores
    /// inside both buffers; return at the first that does not, before it.
    inline fn fast(d: *Decoder) void {
        const in = d.in;
        const out = d.out;
        if (in.len < 32 or out.len < 64) return;
        // A sequence starts with `ip <= in_end` and `op <= out_end`, so its
        // token, up to 14 literals in one 16-byte store and its offset are
        // inside `in`, and the literals and a short match's 18 bytes inside
        // `out`; each match keeps `op <= out_end` for the next.
        const in_end = in.len - 32;
        const out_end = out.len - 64;
        var ip = d.ip;
        var op = d.op;
        defer {
            d.ip = ip;
            d.op = op;
        }
        if (op > out_end) return;
        while (ip <= in_end) {
            const seq_ip = ip;
            const token = in[ip];
            if (token < 0xf0) {
                // The common sequence, whole: up to 14 literals, then up to
                // 18 bytes from 8 or more back. The next token is `ip + 3`
                // plus the literals, the `+ 3` added off the token-to-token
                // chain, which then holds a load, a shift and one add; the
                // literals and offset are found from that sum too, so that no
                // address shared with the token's load lengthens it.
                const past_offset = chainless(ip + 3);
                const lit: usize = token >> 4;
                out[op..][0..16].* = in[past_offset - 2 ..][0..16].*;
                const offset: usize = read16(in.ptr + past_offset - 2 + lit);
                const at = op + lit;
                const len = (token & 15) + min_match;
                // `at` may be past `out_end` by the literals: compared as a
                // sum. An offset from 1 to `at`, as one wrapping comparison.
                if (token & 15 != 15 and offset -% 1 < at and at + len <= out_end) {
                    if (offset >= 8) {
                        // Three stores, each from bytes already written.
                        const from = at - offset;
                        out[at..][0..8].* = out[from..][0..8].*;
                        out[at + 8 ..][0..8].* = out[from + 8 ..][0..8].*;
                        out[at + 16 ..][0..2].* = out[from + 16 ..][0..2].*;
                    } else copyMatch(out, at, offset, len);
                    op = at + len;
                    ip = past_offset + lit;
                    continue;
                }
            }
            // Any other sequence: long literals or match, a short period,
            // the fast region's end or the history.
            ip += 1;
            var lit: usize = token >> 4;
            if (lit != 15) {
                out[op..][0..16].* = in[ip..][0..16].*;
            } else {
                lit += extra(in, &ip, in_end) orelse {
                    ip = seq_ip;
                    return;
                };
                if (lit > in_end - ip or lit > out_end - op) {
                    ip = seq_ip;
                    return;
                }
                var i: usize = 0;
                while (i < lit) : (i += 32) out[op + i ..][0..32].* = in[ip + i ..][0..32].*;
            }
            ip += lit;
            op += lit;
            const offset: usize = read16(in.ptr + ip);
            ip += 2;
            const code: usize = token & 15;
            if (!d.longMatch(&ip, &op, seq_ip, lit, offset, code)) return;
        }
    }

    /// The fast loop's other matches: long, short-period, near the end of
    /// the fast region or into the history. False, with the sequence undone,
    /// where the careful loop is to take it.
    inline fn longMatch(d: *Decoder, ip: *usize, op: *usize, seq_ip: usize, lit: usize, offset: usize, code: usize) bool {
        const in = d.in;
        const out = d.out;
        var len = code + min_match;
        if (code == 15) {
            len += extra(in, ip, in.len - 16) orelse {
                ip.* = seq_ip;
                op.* -= lit;
                return false;
            };
        }
        if (offset == 0 or offset > op.* or op.* + len > out.len - 64) {
            ip.* = seq_ip;
            op.* -= lit;
            return false;
        }
        copyMatch(out, op.*, offset, len);
        op.* += len;
        return true;
    }

    /// Decode one sequence with every bound checked.
    fn careful(d: *Decoder) Error!Next {
        const in = d.in;
        const out = d.out;
        const seq_ip = d.ip;
        if (seq_ip >= in.len) return d.fail(seq_ip, .truncated, error.Truncated);
        const token = in[d.ip];
        var ip = d.ip + 1;
        var lit: usize = token >> 4;
        if (lit == 15) lit = try d.long(seq_ip, &ip, lit);
        if (lit > in.len - ip) return d.fail(seq_ip, .truncated, error.Truncated);
        if (lit > out.len - d.op) {
            if (!d.options.partial) return error.OutputTooSmall;
            const n = out.len - d.op;
            @memcpy(out[d.op..][0..n], in[ip..][0..n]);
            d.op += n;
            return .full;
        }
        @memcpy(out[d.op..][0..lit], in[ip..][0..lit]);
        d.op += lit;
        ip += lit;
        d.ip = ip;
        // The last sequence ends the block after its literals.
        if (ip == in.len) return .done;
        if (in.len - ip < 2) return d.fail(seq_ip, .truncated, error.Truncated);
        const offset: usize = std.mem.readInt(u16, in[ip..][0..2], .little);
        ip += 2;
        var len: usize = token & 15;
        if (len == 15) len = try d.long(seq_ip, &ip, len);
        len = std.math.add(usize, len, min_match) catch return d.fail(seq_ip, .length_overflow, error.InvalidStream);
        if (offset == 0) return d.fail(seq_ip, .zero_offset, error.InvalidStream);
        if (offset > d.op + d.history.len) return d.fail(seq_ip, .offset_too_far, error.InvalidStream);
        var n = len;
        if (len > out.len - d.op) {
            if (!d.options.partial) return error.OutputTooSmall;
            n = out.len - d.op;
        }
        if (offset > d.op) {
            // The match starts in the history and may run on into the output.
            const back = offset - d.op;
            const from_history = @min(n, back);
            const at = d.history.len - back;
            @memcpy(out[d.op..][0..from_history], d.history[at..][0..from_history]);
            for (out[d.op + from_history ..][0 .. n - from_history], 0..) |*byte, i| byte.* = out[i];
        } else for (out[d.op..][0..n], d.op - offset..) |*byte, from| byte.* = out[from];
        d.op += n;
        d.ip = ip;
        return if (n < len) .full else .more;
    }

    /// A length's bytes after its token field's 15, added to `base`.
    fn long(d: *Decoder, seq_ip: usize, ip: *usize, base: usize) Error!usize {
        var total = base;
        while (true) {
            if (ip.* >= d.in.len) return d.fail(seq_ip, .truncated, error.Truncated);
            const byte = d.in[ip.*];
            ip.* += 1;
            total = std.math.add(usize, total, byte) catch return d.fail(seq_ip, .length_overflow, error.InvalidStream);
            if (byte != 255) return total;
        }
    }

    fn fail(d: *Decoder, at: usize, reason: Diagnostic.Reason, err: Error) Error {
        if (d.options.diagnostic) |diag| diag.* = .{ .offset = .fromRaw(d.options.in_base + at), .reason = reason };
        return err;
    }
};

/// The little-endian offset at `p`, in one load.
inline fn read16(p: [*]const u8) u16 {
    return std.mem.littleToNative(u16, @as(*align(1) const u16, @ptrCast(p)).*); // aegis: no-danger: an unaligned read of two bytes the caller has bounded
}

/// A length's bytes after its token field's 15, read while `ip` stays
/// below `limit`; null where it would not, or where the sum would not fit
/// a `usize` (the careful loop then refuses it).
inline fn extra(in: []const u8, ip: *usize, limit: usize) ?usize {
    var total: usize = 0;
    while (true) {
        if (ip.* >= limit) return null;
        const byte = in[ip.*];
        ip.* += 1;
        total = std.math.add(usize, total, byte) catch return null;
        if (byte != 255) return total;
    }
}

test "a block's literals, an overlapping match and its last literals" {
    // "abcabcabcabc" + "xyzzy": three literals, a match of 9 at offset 3,
    // then five literals.
    const block = [_]u8{ 0x35, 'a', 'b', 'c', 3, 0, 0x50, 'x', 'y', 'z', 'z', 'y' };
    var out: [64]u8 = undefined;
    const r = try decode(&block, &out, 0, .{});
    try std.testing.expect(r.finished);
    try std.testing.expectEqualStrings("abcabcabcabcxyzzy", r.written);
    var exact: [17]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 17), (try decode(&block, &exact, 0, .{})).written.len);
    var short: [16]u8 = undefined;
    try std.testing.expectError(error.OutputTooSmall, decode(&block, &short, 0, .{}));
    const partial = try decode(&block, &short, 0, .{ .partial = true });
    try std.testing.expect(!partial.finished);
    try std.testing.expectEqualStrings("abcabcabcabcxyzz", partial.written);
    // Every prefix is cut inside a sequence, but the one that ends after
    // the first literals: a block whose last sequence is "abc".
    for (0..block.len) |n| {
        if (n == 4) {
            try std.testing.expectEqualStrings("abc", (try decode(block[0..n], &out, 0, .{})).written);
        } else try std.testing.expectError(error.Truncated, decode(block[0..n], &out, 0, .{}));
    }
}

test "an offset of zero and one before the history are refused, one into the history decoded" {
    var out: [32]u8 = undefined;
    var diagnostic: Diagnostic = .{};
    const zero = [_]u8{ 0x10, 'a', 0, 0, 0x00 };
    try std.testing.expectError(error.InvalidStream, decode(&zero, &out, 0, .{ .diagnostic = &diagnostic }));
    try std.testing.expectEqual(Diagnostic.Reason.zero_offset, diagnostic.reason);
    const far = [_]u8{ 0x10, 'a', 2, 0, 0x00 };
    try std.testing.expectError(error.InvalidStream, decode(&far, &out, 0, .{ .diagnostic = &diagnostic }));
    try std.testing.expectEqual(Diagnostic.Reason.offset_too_far, diagnostic.reason);
    const r = try decode(&far, &out, 0, .{ .history = "xy" });
    try std.testing.expectEqualStrings("ayaya", r.written);
}

test "every period from one to fifteen repeats as a byte loop would" {
    var out: [512]u8 = undefined;
    var expect: [512]u8 = undefined;
    for (1..16) |period| for ([_]usize{ 4, 17, 64, 200 }) |len| {
        for (out[0..period], 0..) |*b, i| b.* = @intCast('a' + i);
        @memcpy(expect[0..period], out[0..period]);
        for (period..period + len) |i| expect[i] = expect[i - period];
        copyMatch(&out, period, period, len);
        try std.testing.expectEqualSlices(u8, expect[0 .. period + len], out[0 .. period + len]);
    };
}
