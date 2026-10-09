//! Raw blocks decoded without their preceding window. Values below 256
//! are bytes; larger values name a byte in the unknown 32 KiB window.
//! Header parsing, tables and symbol validation belong to the ordinary engine.
const std = @import("std");
const engine = @import("inflate.zig");
const huffman = @import("huffman.zig").decode;

pub const Decoder = struct {
    tables: engine.Tables = .{},
    state: engine.State = .{},
    stream: engine.Stream,
    tokens: []u16,
    written: usize = 0,
    required: usize = 0,
    max_distance: u32 = 0,

    pub fn init(input: []const u8, bit: usize, tokens: []u16) Decoder {
        var stream: engine.Stream = .{ .in = input, .ip = bit / 8, .out = &.{}, .op = 0, .start = 0, .stop_header = true };
        if (bit % 8 != 0) {
            stream.bitbuf = input[stream.ip] >> @as(u3, @intCast(bit % 8)); // safe: the bit position is inside input
            stream.bitsleft = @intCast(8 - bit % 8); // safe: 1-7 pending bits
            stream.ip += 1;
        }
        return .{ .stream = stream, .tokens = tokens };
    }

    pub fn block(d: *Decoder, io: std.Io) (engine.Error || std.Io.Cancelable)!engine.Status {
        std.debug.assert(d.state.phase == .header);
        _ = try engine.decode(&d.tables, &d.stream, engine.no_more, &d.state);
        if (d.state.phase == .stored) {
            const len = d.state.stored_left;
            if (len > d.tokens.len - d.written) return error.OutputTooSmall;
            if (len > d.stream.in.len - d.stream.ip) return error.Truncated;
            for (d.stream.in[d.stream.ip..][0..len], d.tokens[d.written..][0..len]) |byte, *token| token.* = byte;
            d.written += len;
            d.stream.ip += len;
        } else {
            const ll: []const u32 = if (d.state.fixed) &huffman.Fixed(.litlen).table else &d.tables.litlen;
            const dd: []const u32 = if (d.state.fixed) &huffman.Fixed(.dist).table else &d.tables.dist;
            const lb = if (d.state.fixed) huffman.Fixed(.litlen).bits else d.state.lbits;
            const db = if (d.state.fixed) huffman.Fixed(.dist).bits else d.state.dbits;
            try d.codes(io, ll, lb, dd, db);
        }
        d.state.phase = if (d.state.final) .done else .header;
        return if (d.state.final) .done else .block_end;
    }

    fn codes(d: *Decoder, io: std.Io, ll: []const u32, lb: u5, dd: []const u32, db: u5) (engine.Error || std.Io.Cancelable)!void {
        var units: usize = 0;
        while (true) : (units += 1) {
            if (units & 4095 == 0) try io.checkCancel();
            if (d.stream.virtual == 0 and d.stream.ip + 16 <= d.stream.in.len and d.written + 274 <= d.tokens.len) {
                if (try engine.fast(4096, &d.stream, Tokens{ .decoder = d }, ll, lb, dd, db)) return;
                // A bounded fast batch keeps cancellation responsive even
                // when the entire block has real input and output room.
                try io.checkCancel();
            }
            const lit = try engine.symbol(&d.stream, engine.no_more, ll, lb);
            d.stream.consume(lit.bits);
            if (lit.entry & huffman.end_flag != 0) return;
            if (lit.entry & huffman.literal_flag != 0) {
                if (d.written == d.tokens.len) return error.OutputTooSmall;
                d.tokens[d.written] = @as(u8, @truncate(lit.entry >> 16)); // safe: the low byte of the value is the literal; the high bit is its tag
                d.written += 1;
                continue;
            }
            const len = huffman.value(lit.entry) + try d.stream.take(engine.no_more, lit.extra);
            const dist = try engine.symbol(&d.stream, engine.no_more, dd, db);
            d.stream.consume(dist.bits);
            const back = huffman.value(dist.entry) + try d.stream.take(engine.no_more, dist.extra);
            if (back > engine.max_distance) return error.InvalidStream;
            d.max_distance = @max(d.max_distance, back);
            if (len > d.tokens.len - d.written) return error.OutputTooSmall;
            d.copy(false, back, len);
        }
    }

    /// Marker output shares symbol decoding with ordinary byte output.
    const Tokens = struct {
        decoder: *Decoder,

        pub inline fn position(t: Tokens, _: *const engine.Stream) usize {
            return t.decoder.written;
        }

        pub inline fn capacity(t: Tokens) usize {
            return t.decoder.tokens.len;
        }

        pub inline fn buffer(t: Tokens) []u16 {
            return t.decoder.tokens;
        }

        pub inline fn match(t: Tokens, _: *engine.Stream, op: usize, distance: usize, length: usize, _: usize, _: u32) engine.Error!void {
            if (distance > engine.max_distance) return error.InvalidStream;
            const d = t.decoder;
            d.max_distance = @max(d.max_distance, @as(u32, @intCast(distance))); // safe: validated DEFLATE window
            d.written = op;
            d.copy(true, distance, length);
        }

        pub inline fn finish(t: Tokens, _: *engine.Stream, op: usize) void {
            t.decoder.written = op;
        }
    };

    fn copy(d: *Decoder, comptime wild: bool, back: usize, len: usize) void {
        var count: usize = 0;
        if (back > d.written) {
            const missing = back - d.written;
            d.required = @max(d.required, missing);
            count = @min(len, missing);
            for (0..count) |i| d.tokens[d.written + i] = @intCast(256 + engine.max_distance - missing + i); // safe: window markers fit u16
        }
        if (wild and count < len) {
            engine.copyMatch(u16, d.tokens, d.written + count, back, len - count);
            d.written += len;
            return;
        }
        if (back >= 16) {
            while (count + 16 <= len) : (count += 16) d.tokens[d.written + count ..][0..16].* = d.tokens[d.written + count - back ..][0..16].*;
        }
        for (count..len) |i| d.tokens[d.written + i] = d.tokens[d.written + i - back];
        d.written += len;
    }
};

/// Cheap rejection before constructing tables. Fixed codes are searched in
/// a second pass, so the plentiful false fixed headers do not delay dynamic ones.
pub inline fn plausible(input: []const u8, bit: usize, fixed: bool) bool {
    if (bit / 8 + 16 > input.len) return true;
    const byte = bit / 8;
    const shift: u3 = @intCast(bit % 8); // safe: bit position within one byte
    const field = std.mem.readInt(u64, input[byte..][0..8], .little) >> shift;
    const kind = (field >> 1) & 3;
    if (kind == 1) return fixed;
    if (fixed or kind == 3) return false;
    if (kind == 0) {
        const at = (bit + 3 + 7) / 8;
        if (at + 4 > input.len) return false;
        const lens = std.mem.readInt(u32, input[at..][0..4], .little);
        return @as(u16, @truncate(lens)) == ~@as(u16, @truncate(lens >> 16));
    }
    if ((field >> 3) & 31 > 29 or (field >> 8) & 31 > 29) return false;
    const n = ((field >> 13) & 15) + 4;
    const pre_bits = std.mem.readInt(u128, input[byte..][0..16], .little) >> @as(u7, @intCast(17 + bit % 8)); // safe: at most 24 bits skipped
    const mask = (@as(u64, 1) << @as(u6, @intCast(n * 3))) - 1; // safe: 4-19 lengths occupy at most 57 bits
    const lengths: u64 = @as(u64, @truncate(pre_bits)) & mask;
    const sum = precode_weights[lengths & 4095] + precode_weights[(lengths >> 12) & 4095] +
        precode_weights[(lengths >> 24) & 4095] + precode_weights[(lengths >> 36) & 4095] + precode_weights[(lengths >> 48) & 4095];
    return sum == 128;
}

// Kraft weights at depth seven: zero-length symbols contribute nothing.
// Four lengths at once keep candidate screening independent of table builds.
const precode_weights: [4096]u16 = blk: {
    @setEvalBranchQuota(100000);
    const weights = [_]u16{ 0, 64, 32, 16, 8, 4, 2, 1 };
    var sums: [4096]u16 = undefined;
    for (&sums, 0..) |*sum, i| {
        sum.* = weights[i & 7] + weights[(i >> 3) & 7] + weights[(i >> 6) & 7] + weights[(i >> 9) & 7];
    }
    break :blk sums;
};
