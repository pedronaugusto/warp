//! LZ4's fast parser (levels 1 and below): one hash table of the latest
//! position per hash, a step that grows over input that does not match
//! (the acceleration), and a match taken as soon as four bytes agree. The
//! same parse as lz4 1.10's `LZ4_compress_generic`, so a block without
//! history comes out byte for byte as `LZ4_compress_fast` writes it on a
//! 64-bit little-endian machine, on every target.
//!
//! Positions are virtual (`Table.next`): each call's input starts past
//! every position the table holds, so a call clears nothing, and an entry
//! older than the call stands for the call's first byte, as a cleared
//! table's zero does for lz4.

const std = @import("std");
const seq = @import("sequence.zig");

/// The hash table: 2^13 entries for one input below `small_limit` (4-byte
/// hashes, lz4's `byU16` table), 2^12 otherwise (5-byte hashes).
pub const Table = struct {
    entries: [1 << 13]u32,
    /// The virtual position the next call's input starts at.
    next: u32,
    /// Which hash the entries hold.
    kind: Kind,

    pub const empty: Table = .{ .entries = @splat(0), .next = window_gap, .kind = .large };

    /// Start a call of `len` bytes at a fresh position: positions stay
    /// below 2^31 with a window of room before every call.
    pub fn begin(t: *Table, len: usize, kind: Kind, keep: bool) u32 {
        if (kind != t.kind or t.next > rebase_at - @min(len, rebase_at)) {
            if (keep and kind == t.kind) {
                // Keep the last window's positions, moved down.
                const delta = t.next - window_gap;
                for (&t.entries) |*e| e.* = if (e.* < delta) 0 else e.* - delta;
                t.next = window_gap;
            } else {
                t.entries = @splat(0);
                t.next = window_gap;
            }
            t.kind = kind;
        }
        const start = t.next;
        t.next += @intCast(len);
        return start;
    }
};

pub const Kind = enum { small, large };

/// Inputs below this use the 4-byte hash: lz4's `LZ4_64Klimit`.
pub const small_limit = 65536 + seq.mf_limit - 1;
/// Room below every call's first position for a window of history, and
/// more: position 0 is never in reach.
const window_gap = 1 << 17;
const rebase_at = 0x8000_0000;
const skip_trigger = 6;
pub const max_acceleration = 65537;

/// How the history before the input is searched.
pub const History = enum {
    /// None: the input alone.
    none,
    /// The bytes before the input, indexed in the table already (the last
    /// call's input, or bytes loaded with `load`).
    table,
    /// A dictionary indexed in a table of its own (`load` into it), searched
    /// where the input's table has nothing in the window.
    attached,
};

/// What surrounds one call: the input, its first byte's position, and the
/// bytes before it with the table that indexes them when attached.
pub const Call = struct {
    /// The input, after `begin` bytes of history in the same memory (the
    /// last call's input, when it lies just before: lz4's prefix mode).
    src: []const u8,
    begin: usize = 0,
    /// The position of `src[0]`.
    start: u32,
    /// Bytes before `src`, the last at position `start - 1`.
    history: []const u8 = &.{},
    /// The attached dictionary's table (`load`), whose bytes are `history`:
    /// its entries are positions with their last at `dictionary_end - 1`.
    dictionary: ?*const Table = null,
    dictionary_end: u32 = 0,
    acceleration: u32 = 1,
};

pub fn hash(comptime kind: Kind, bytes: []const u8) u32 {
    switch (kind) {
        .small => {
            const v = std.mem.readInt(u32, bytes[0..4], .little);
            return (v *% 2654435761) >> (32 - 13);
        },
        .large => {
            const v = std.mem.readInt(u64, bytes[0..8], .little);
            return @intCast(((v << 24) *% 889523592379) >> (64 - 12));
        },
    }
}

/// Index `dictionary`'s last 64 KiB into a cleared table, as lz4's
/// `LZ4_loadDictSlow` does: every third position, then each position whose
/// bucket holds nothing in the window. Returns the bytes indexed.
pub fn load(t: *Table, dictionary: []const u8) []const u8 {
    t.* = .empty;
    const bytes = dictionary[dictionary.len -| 65536..];
    const end = t.begin(bytes.len, .large, false) + @as(u32, @intCast(bytes.len));
    if (bytes.len < 8) return bytes;
    const first = end - @as(u32, @intCast(bytes.len));
    var p: usize = 0;
    while (p + 8 <= bytes.len) : (p += 3) t.entries[hash(.large, bytes[p..])] = first + @as(u32, @intCast(p));
    const limit = end -| 65536;
    p = 0;
    while (p + 8 <= bytes.len) : (p += 1) {
        const h = hash(.large, bytes[p..]);
        if (t.entries[h] <= limit) t.entries[h] = first + @as(u32, @intCast(p));
    }
    return bytes;
}

/// A dictionary loaded for a call's table (`History.table`): every third
/// position, as lz4's `LZ4_loadDict` does.
pub fn loadFast(t: *Table, start: u32, bytes: []const u8) void {
    if (bytes.len < 8) return;
    const first = start - @as(u32, @intCast(bytes.len));
    var p: usize = 0;
    while (p + 8 <= bytes.len) : (p += 3) t.entries[hash(.large, bytes[p..])] = first + @as(u32, @intCast(p));
}

/// Compress `call.src` into `out`. `.unlimited` needs `out.len >=
/// seq.bound(src.len)`; `.limited` returns null when the block does not
/// fit; `.fill` writes as much of the input as fits and says how much.
pub noinline fn compress(
    comptime kind: Kind,
    comptime history: History,
    comptime directive: seq.Directive,
    t: *Table,
    call_in: Call,
    out: []u8,
) ?seq.Written {
    // A local copy: the caller's may alias the table, and its fields
    // would be loaded again after every store into it.
    var call = call_in;
    _ = &call;
    const src = call.src;
    const start = call.start;
    // A large input without history clears its 2^12 buckets to its first
    // byte, as lz4 clears its table: cheap beside the input, and the search
    // then reads each entry as it stands (`candidate`).
    if (kind == .large and history == .none) {
        const v: @Vector(8, u32) = @splat(start);
        var i: usize = 0;
        while (i < 1 << 12) : (i += 8) t.entries[i..][0..8].* = v;
    }
    const accel: u32 = @max(1, @min(call.acceleration, max_acceleration));
    var o: seq.Out = .{ .buf = out };
    const begin = call.begin;
    var anchor: usize = begin;
    if (directive == .fill and out.len == 0) return .{ .in_len = 0, .out_len = 0 };
    if (src.len - begin < seq.min_length) return o.last(directive, src, anchor, begin);
    const mflimit_plus_one = src.len - seq.mf_limit + 1;
    const match_limit = src.len - seq.last_literals;
    const hist = call.history;
    // The lowest position a match may start at: the history's first.
    const low: u32 = start - @as(u32, @intCast(hist.len));

    var ip: usize = begin;
    t.entries[hash(kind, src[ip..])] = start + @as(u32, @intCast(ip));
    ip += 1;
    var forward_h = hash(kind, src[ip..]);

    while (true) {
        var match: u32 = undefined;
        // Find a match: the step grows by one every 2^6 misses.
        {
            var forward = ip;
            var step: usize = 1;
            var search: u32 = accel << skip_trigger;
            while (true) {
                const h = forward_h;
                const current: u32 = start + @as(u32, @intCast(forward));
                ip = forward;
                forward += step;
                step = search >> skip_trigger;
                search += 1;
                if (forward > mflimit_plus_one) return o.last(directive, src, anchor, begin);
                match = candidate(kind, history, t, call, h);
                forward_h = hash(kind, src[forward..]);
                t.entries[h] = current;
                if (history != .none and match < low) continue;
                if (kind == .large and match + seq.max_offset < current) continue;
                if (read32(history, call, match) == std.mem.readInt(u32, src[ip..][0..4], .little)) break;
            }
        }
        const filled_ip = ip;
        // Catch up: extend the match backwards over equal bytes.
        while (ip > anchor and match > low and byteAt(history, call, match - 1) == src[ip - 1]) {
            ip -= 1;
            match -= 1;
        }
        // The literals.
        const lits = src[anchor..ip];
        switch (directive) {
            .unlimited => {},
            .limited => if (o.pos + 1 + lits.len + 2 + 1 + seq.last_literals + lits.len / 255 > out.len) return null,
            .fill => if (o.pos + 1 + (lits.len + 240) / 255 + lits.len + 2 + 1 + seq.mf_limit - seq.min_match > out.len) return o.last(directive, src, anchor, begin),
        }
        var token = o.literalsBefore(src, anchor, ip);
        while (true) {
            if (directive == .fill and o.pos + 2 + 1 + seq.mf_limit - seq.min_match > out.len) {
                // The match is too near the output's end: drop it.
                o.pos = token;
                return o.last(directive, src, anchor, begin);
            }
            const current: u32 = start + @as(u32, @intCast(ip));
            o.offset(@intCast(current - match));
            var code = matchCode(history, call, ip, match, match_limit);
            ip += code + seq.min_match;
            if (directive != .unlimited and o.pos + 1 + seq.last_literals + (code + 240) / 255 > out.len) {
                if (directive == .limited) return null;
                // Shorten the match to what its length bytes have room for.
                const shorter = 15 - 1 + (out.len - o.pos - 1 - seq.last_literals) * 255;
                ip -= code - shorter;
                code = shorter;
                if (ip <= filled_ip) {
                    // Positions past the shortened match are in the table:
                    // clear them, so a later call does not see them.
                    var p = ip;
                    while (p <= filled_ip) : (p += 1) t.entries[hash(kind, src[p..])] = 0;
                }
            }
            o.matchLength(token, code);
            anchor = ip;
            if (ip >= mflimit_plus_one) return o.last(directive, src, anchor, begin);
            // Fill the table, and try the next position at once.
            t.entries[hash(kind, src[ip - 2 ..])] = start + @as(u32, @intCast(ip - 2));
            const h = hash(kind, src[ip..]);
            const here: u32 = start + @as(u32, @intCast(ip));
            match = candidate(kind, history, t, call, h);
            t.entries[h] = here;
            const valid = history == .none or match >= low;
            const near = (kind == .small and history == .none) or match + seq.max_offset >= here;
            if (!(valid and near and read32(history, call, match) == std.mem.readInt(u32, src[ip..][0..4], .little))) break;
            token = o.pos;
            o.buf[o.pos] = 0;
            o.pos += 1;
        }
        ip += 1;
        forward_h = hash(kind, src[ip..]);
    }
}

/// A match's length past its first four bytes: through the history and on
/// into the input, or from the input alone.
inline fn matchCode(comptime history: History, call: Call, ip: usize, match: u32, match_limit: usize) usize {
    const src = call.src;
    const start = call.start;
    if (history != .none and match < start and start - match > seq.min_match) {
        const hist = call.history;
        const in_history = start - match;
        const limit = @min(ip + in_history, match_limit);
        const code = seq.countMatch(src[ip + seq.min_match .. limit], hist[hist.len - in_history + seq.min_match ..]);
        if (ip + seq.min_match + code == limit) return code + seq.countMatch(src[limit..match_limit], src);
        return code;
    }
    if (history != .none and match < start) {
        // Caught up back into the history: within its first four bytes the
        // match runs on into the input.
        const into = seq.min_match - (start - match);
        return seq.countMatch(src[ip + seq.min_match .. match_limit], src[into..]);
    }
    const m = match - start;
    return seq.countMatch(src[ip + seq.min_match .. match_limit], src[m + seq.min_match ..]);
}

/// The position a bucket names for this call: an entry older than the
/// call stands for its first byte without history (a large input's
/// buckets hold no older one); with an attached dictionary, that
/// dictionary's own entry.
inline fn candidate(comptime kind: Kind, comptime history: History, t: *const Table, call: Call, h: u32) u32 {
    const e = t.entries[h];
    switch (history) {
        .none => return if (kind == .large) e else @max(e, call.start),
        .table => return e,
        .attached => {
            if (e >= call.start) return e;
            // The dictionary's own position, moved to where its bytes
            // stand before the input; an empty bucket is out of reach.
            const d = call.dictionary.?.entries[h];
            const first = call.dictionary_end - @as(u32, @intCast(call.history.len));
            if (d < first) return 0;
            return d - first + (call.start - @as(u32, @intCast(call.history.len)));
        },
    }
}

/// The byte at a position; without history every candidate is in the
/// input (`candidate`), so no test is made.
inline fn byteAt(comptime history: History, call: Call, pos: u32) u8 {
    if (history == .none or pos >= call.start) return call.src[pos - call.start];
    return call.history[call.history.len - (call.start - pos)];
}

inline fn read32(comptime history: History, call: Call, pos: u32) u32 {
    if (history == .none or pos >= call.start) return std.mem.readInt(u32, call.src[pos - call.start ..][0..4], .little);
    const back = call.start - pos;
    return std.mem.readInt(u32, call.history[call.history.len - back ..][0..4], .little);
}
