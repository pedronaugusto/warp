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
            d.copy(back, len);
        }
    }

    fn copy(d: *Decoder, back: usize, len: usize) void {
        var count: usize = 0;
        if (back > d.written) {
            const missing = back - d.written;
            d.required = @max(d.required, missing);
            count = @min(len, missing);
            for (0..count) |i| d.tokens[d.written + i] = @intCast(256 + engine.max_distance - missing + i); // safe: window markers fit u16
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
pub fn plausible(input: []const u8, bit: usize, fixed: bool) bool {
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
    var lengths = std.mem.readInt(u128, input[byte..][0..16], .little) >> @as(u7, @intCast(17 + bit % 8)); // safe: at most 24 bits skipped
    var count: [8]u8 = @splat(0);
    for (0..@intCast(n)) |_| {
        count[@as(usize, @truncate(lengths & 7))] += 1;
        lengths >>= 3;
    }
    var left: i32 = 1;
    for (1..8) |len| {
        left = (left << 1) - count[len];
        if (left < 0) return false;
    }
    return left == 0;
}
