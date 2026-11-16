//! Resumable LZW decoding, GIF's variant: input and output in pieces of any
//! size, in a fixed state of about 28 KiB and no allocation. Acceptance is
//! Wuffs's `std/lzw` decoder's (0.4.0-alpha.12): codes least significant
//! bit first, from
//! `literal_width + 1` bits, one wider each time the next code reaches a
//! power of two, to at most 12; a full table adds nothing until a clear
//! code; a code past the next one the table would add is refused.
//!
//! Input is taken a byte at a time as codes need it, so after the end code
//! the input is taken exactly through the byte that holds its last bit, and
//! the bytes after it (a GIF's remaining sub-block bytes) are the caller's.
const Decompress = @This();

const aegis = @import("aegis");
const Diagnostic = @import("Diagnostic.zig");

/// The widest literal: 8 bits, GIF's largest minimum code size.
pub const max_literal_width = 8;
/// The widest code, 12 bits; the table holds 4096 codes.
pub const max_width = 12;
const table_len = 1 << max_width;

pub const Options = struct {
    /// GIF's minimum code size: the bits of a literal, 0 to 8. Wuffs reads
    /// any of them (a GIF names 2 to 8; 0 and 1 are read as the same rules
    /// give them).
    literal_width: u4 = 8,
    diagnostic: ?*Diagnostic = null,
};

pub const InitError = error{
    /// A `literal_width` past 8.
    InvalidOptions,
};

pub const Error = error{
    /// A code past the next one the table would add.
    InvalidStream,
    /// The input ends before the end code (`finish`).
    Truncated,
};

pub const Status = enum {
    /// Every input byte is taken and the end code is not yet read: more
    /// input, or `finish` if the input ends here.
    need_input,
    /// The output is full and a code's bytes are still to hand out.
    output_full,
    /// The end code is read and every byte before it handed out. Later
    /// calls take no input and give no output.
    end,
};

pub const Step = struct { in_len: usize, out_len: usize, status: Status };

/// Private: a code's entry, the code before it (its prefix), its last
/// byte, its first byte and its length. Literals are their own byte, of
/// length 1.
pub const Entry = struct {
    prefix: u16 = 0,
    last: u8 = 0,
    first: u8 = 0,
    len: u16 = 1,
};

options: Options,
clear_code: u16,
end_code: u16,
/// Private: the code the table adds next (`table_len` when full).
next_code: u16,
/// Private: the code before this one, or `end_code` at the start and
/// after a clear (no entry is added then; `next_code` still moves).
prev_code: u16,
width: u4,
/// Private: input bits taken and not yet read as a code, least
/// significant first; fewer than 8 between codes.
bits: u32 = 0,
n_bits: u5 = 0,
table: [table_len]Entry,
/// Private: a code's bytes past what the caller's output held,
/// `pending[pending_start..pending_end]`.
pending: [table_len]u8 = undefined,
pending_start: u16 = 0,
pending_end: u16 = 0,
/// Private: the input taken and the output given, for the diagnostic.
taken: u64 = 0,
given: u64 = 0,
phase: Phase = .codes,

/// Private: reading codes, past the end code, or refused.
pub const Phase = enum { codes, ended, failed };

/// A decoder for `options.literal_width`.
pub fn init(options: Options) InitError!Decompress {
    if (options.literal_width > max_literal_width) return error.InvalidOptions;
    const clear: u16 = @as(u16, 1) << options.literal_width;
    var d: Decompress = .{
        .options = options,
        .clear_code = clear,
        .end_code = clear + 1,
        .next_code = clear + 1,
        .prev_code = clear + 1,
        .width = @as(u4, options.literal_width) + 1,
        .table = undefined,
    };
    for (d.table[0..clear], 0..) |*e, i| {
        const byte: u8 = @truncate(i);
        e.* = .{ .last = byte, .first = byte };
    }
    return d;
}

/// Start a new stream with the same options.
pub fn reset(d: *Decompress) void {
    d.* = init(d.options) catch aegis.assert.never("init took these options before");
}

/// Take input and give output as far as each allows. A refused code fails
/// the call after the bytes of every code before it are written to `out`;
/// the diagnostic's `output` counts every byte the decoder gave, this
/// call's included. Every later call fails the same way.
pub fn decode(d: *Decompress, in: []const u8, out: []u8) Error!Step {
    var o = d.drain(out);
    if (d.pending_start != d.pending_end or d.phase != .codes) {
        d.given += o;
        return switch (d.phase) {
            .failed => error.InvalidStream,
            // The end code is read only once nothing is pending.
            .ended => .{ .in_len = 0, .out_len = o, .status = .end },
            .codes => .{ .in_len = 0, .out_len = o, .status = .output_full },
        };
    }
    var i: usize = 0;
    while (true) {
        while (d.n_bits < d.width) {
            if (i == in.len) {
                d.taken += i;
                d.given += o;
                return .{ .in_len = i, .out_len = o, .status = .need_input };
            }
            d.bits |= @as(u32, in[i]) << d.n_bits;
            d.n_bits += 8;
            i += 1;
        }
        const code: u16 = @truncate(d.bits & ((@as(u32, 1) << d.width) - 1));
        d.bits >>= d.width;
        d.n_bits -= d.width;

        if (code < d.clear_code) {
            const byte: u8 = @truncate(code);
            if (o < out.len) {
                out[o] = byte;
                o += 1;
            } else {
                d.pending[0] = byte;
                d.pending_start = 0;
                d.pending_end = 1;
            }
            d.add(byte, code);
        } else if (code == d.end_code) {
            d.phase = .ended;
            d.taken += i;
            d.given += o;
            return .{ .in_len = i, .out_len = o, .status = .end };
        } else if (code == d.clear_code) {
            d.next_code = d.end_code;
            d.prev_code = d.end_code;
            d.width = @as(u4, d.options.literal_width) + 1;
        } else if (code <= d.next_code and code < table_len) {
            // The code the table adds next is its prefix's bytes and their
            // first byte again (the KwKwK case).
            const repeat = code == d.next_code;
            const from = if (repeat) d.prev_code else code;
            const entry = d.table[from];
            const len: usize = @as(usize, entry.len) + @intFromBool(repeat);
            if (out.len - o >= len) {
                d.spell(from, out[o..][0..entry.len]);
                if (repeat) out[o + entry.len] = entry.first;
                o += len;
            } else {
                d.spell(from, d.pending[0..entry.len]);
                if (repeat) d.pending[entry.len] = entry.first;
                d.pending_start = 0;
                d.pending_end = @intCast(len);
                o += d.drain(out[o..]);
            }
            d.add(entry.first, code);
        } else {
            d.phase = .failed;
            d.taken += i;
            d.given += o;
            if (d.options.diagnostic) |diag| diag.* = .{
                .offset = .fromRaw(d.taken - 1),
                .output = .fromRaw(d.given),
                .reason = .bad_code,
            };
            return error.InvalidStream;
        }
        if (d.pending_start != d.pending_end) {
            d.taken += i;
            d.given += o;
            return .{ .in_len = i, .out_len = o, .status = .output_full };
        }
    }
}

/// Declare the end of input after the output is drained: refuses a
/// stream whose end code is not read.
pub fn finish(d: *Decompress) Error!void {
    switch (d.phase) {
        .ended => return,
        .failed => return error.InvalidStream,
        .codes => {},
    }
    // The bits held are short of a code; whole bytes among them are
    // given back, as Wuffs gives them back.
    if (d.options.diagnostic) |diag| diag.* = .{
        .offset = .fromRaw(d.taken - d.n_bits / 8),
        .output = .fromRaw(d.given),
        .reason = .truncated,
    };
    return error.Truncated;
}

/// Whether the end code is read and every byte before it handed out.
pub fn ended(d: *const Decompress) bool {
    return d.phase == .ended and d.pending_start == d.pending_end;
}

/// Add the entry after `prev_code` ending in `first` (the current code's
/// first byte), unless the table is full or this is the first code since
/// a clear; then `code` is the one before the next.
fn add(d: *Decompress, first: u8, code: u16) void {
    if (d.next_code >= table_len) return;
    if (d.prev_code != d.end_code) {
        const prev = d.table[d.prev_code];
        d.table[d.next_code] = .{ .prefix = d.prev_code, .last = first, .first = prev.first, .len = prev.len + 1 };
    }
    d.next_code += 1;
    // Wuffs's rule, which a literal width of 0 or 1 tells apart from
    // "the next code reaches 1 << width": the bit at `width` of the next
    // code is set.
    if (d.width < max_width) d.width += @intCast((d.next_code >> d.width) & 1);
    d.prev_code = code;
}

/// Write `code`'s bytes into `dst`, exactly its length, back to front.
fn spell(d: *const Decompress, code: u16, dst: []u8) void {
    var c = code;
    var at = dst.len;
    while (at > 0) {
        at -= 1;
        const e = d.table[c];
        dst[at] = e.last;
        c = e.prefix;
    }
}

/// Hand out pending bytes into `out`; how many.
fn drain(d: *Decompress, out: []u8) usize {
    const n = @min(out.len, d.pending_end - d.pending_start);
    @memcpy(out[0..n], d.pending[d.pending_start..][0..n]);
    d.pending_start += @intCast(n);
    if (d.pending_start == d.pending_end) {
        d.pending_start = 0;
        d.pending_end = 0;
    }
    return n;
}
