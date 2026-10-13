//! The streaming rows: decoding and compressing in pieces beside the
//! whole-buffer calls (B7), and WebSocket messages under each of RFC
//! 7692's modes (B6).
const std = @import("std");
const Io = std.Io;
const warp = @import("warp");
const gen = @import("gen");
const support = @import("support.zig");

const Session = support.Session;
const Error = support.Error;

pub fn rows(s: *Session) !void {
    try decode(s);
    try compress(s);
    try websocket(s);
}

const Kind = enum { whole, pieces, reader };

const DecodeShape = struct {
    name: []const u8,
    kind: Kind,
    in_piece: usize,
    out_piece: usize,
    /// A byte at a time costs a call per byte: the first megabyte.
    first_mb: bool = false,
};

const decode_shapes = [_]DecodeShape{
    .{ .name = "whole", .kind = .whole, .in_piece = 0, .out_piece = 0 },
    .{ .name = "in 64 B", .kind = .pieces, .in_piece = 64, .out_piece = 64 << 10 },
    .{ .name = "in 4 KiB", .kind = .pieces, .in_piece = 4096, .out_piece = 64 << 10 },
    .{ .name = "in 64 KiB, out 256 KiB", .kind = .pieces, .in_piece = 64 << 10, .out_piece = 256 << 10 },
    .{ .name = "out 4 KiB", .kind = .pieces, .in_piece = std.math.maxInt(usize), .out_piece = 4096 },
    .{ .name = "reader 4 KiB", .kind = .reader, .in_piece = 0, .out_piece = 4096 },
    .{ .name = "in 1 B, first MB", .kind = .pieces, .in_piece = 1, .out_piece = 64 << 10, .first_mb = true },
};

pub const Decode = struct {
    session: *Session,
    index: usize,
    shape: DecodeShape,
    arena: std.heap.ArenaAllocator = undefined,
    streams: []const []const u8 = &.{},
    inputs: []const []const u8 = &.{},
    out: []u8 = &.{},
    window: []u8 = &.{},
    reader_buffer: []u8 = &.{},
    d: *warp.Decompressor = undefined,

    pub fn setup(c: *Decode) Error!void {
        c.arena = .init(c.session.gpa);
        errdefer c.arena.deinit();
        const a = c.arena.allocator();
        const wl = c.session.loaded.?[c.index];
        c.streams = c.session.zlib.get(c.index).?;
        c.inputs = wl.inputs;
        if (c.shape.first_mb) {
            var total: usize = 0;
            var n: usize = 0;
            while (n < wl.inputs.len and total < 1 << 20) : (n += 1) total += wl.inputs[n].len;
            c.streams = c.streams[0..n];
            c.inputs = c.inputs[0..n];
        }
        c.out = try a.alloc(u8, wl.max + warp.inflate_margin);
        c.window = try a.alloc(u8, 1 << 15);
        c.reader_buffer = try a.alloc(u8, (1 << 15) + (64 << 10));
        c.d = try a.create(warp.Decompressor);
        c.d.* = .init;
    }

    pub fn teardown(c: *Decode) Error!void {
        c.arena.deinit();
    }

    pub fn run(c: *Decode, units: u64) Error!void {
        for (0..units) |_| switch (c.shape.kind) {
            .whole => for (c.streams, c.inputs) |s, in| {
                const r = try c.d.inflate(s, c.out[0..in.len], .{});
                if (r.out_len != in.len) return error.WrongLength;
            },
            .pieces => for (c.streams, c.inputs) |s, in| {
                var z: warp.Inflate = .init(c.window, .{});
                var at: usize = 0;
                var written: usize = 0;
                while (true) {
                    const in_len = @min(c.shape.in_piece, s.len - at);
                    const out_len = @min(c.shape.out_piece, c.out.len - written);
                    const step = try z.decode(s[at..][0..in_len], c.out[written..][0..out_len]);
                    at += step.in_len;
                    written += step.out_len;
                    if (step.status == .done) break;
                }
                if (written != in.len) return error.WrongLength;
            },
            .reader => for (c.streams, c.inputs) |s, in| {
                var input: Io.Reader = .fixed(s);
                var r: warp.Inflate.Reader = .init(&input, c.reader_buffer, .{});
                var written: usize = 0;
                while (true) {
                    const n = try r.interface.readSliceShort(c.out[written..][0..@min(c.shape.out_piece, c.out.len - written)]);
                    if (n == 0) break;
                    written += n;
                }
                if (written != in.len) return error.WrongLength;
            },
        };
    }
};

/// B7, decoding: std's zlib streams at level 6 through `Inflate` in pieces
/// and through its reader, beside the whole-buffer decoder.
fn decode(s: *Session) !void {
    if (!s.wants("stream-decode/")) return;
    for (try s.workloads(), 0..) |wl, index| {
        if (!s.wants(try s.name("stream-decode/{s}/", .{wl.name}))) continue;
        _ = try s.streams(index);
        for (decode_shapes) |shape| {
            const ctx = try s.arena.create(Decode);
            ctx.* = .{ .session = s, .index = index, .shape = shape };
            try s.measure(Decode, ctx, support.rowOf(Decode, try s.name("stream-decode/{s}/{s}", .{ wl.name, shape.name }), "pass"));
        }
    }
}

const CompressShape = struct { name: []const u8, whole: bool, in_piece: usize };

const compress_shapes = [_]CompressShape{
    .{ .name = "whole", .whole = true, .in_piece = 0 },
    .{ .name = "write 64 B", .whole = false, .in_piece = 64 },
    .{ .name = "write 4 KiB", .whole = false, .in_piece = 4096 },
    .{ .name = "write whole", .whole = false, .in_piece = std.math.maxInt(usize) },
};

pub const Compress = struct {
    session: *Session,
    index: usize,
    level: u4,
    shape: CompressShape,
    arena: std.heap.ArenaAllocator = undefined,
    inputs: []const []const u8 = &.{},
    out: []u8 = &.{},
    c: *warp.Compressor = undefined,
    d: *warp.Deflate = undefined,

    pub fn setup(c: *Compress) Error!void {
        c.arena = .init(c.session.gpa);
        errdefer c.arena.deinit();
        const a = c.arena.allocator();
        const wl = c.session.loaded.?[c.index];
        c.inputs = wl.inputs;
        c.out = try a.alloc(u8, warp.Compressor.bound(wl.max, .{}));
        c.c = try a.create(warp.Compressor);
        c.c.* = try .init(a, .{ .level = c.level });
        c.d = try a.create(warp.Deflate);
        c.d.* = try .init(a, .{ .level = c.level });
    }

    pub fn teardown(c: *Compress) Error!void {
        c.c.deinit();
        c.arena.deinit();
    }

    pub fn run(c: *Compress, units: u64) Error!void {
        var total: u64 = 0;
        for (0..units) |_| for (c.inputs) |in| {
            if (c.shape.whole) {
                total += try c.c.compress(in, c.out, .{});
                continue;
            }
            var piece: [4096]u8 = undefined;
            c.d.reset(.nothing);
            var at: usize = 0;
            while (at < in.len) {
                const step = c.d.write(in[at..][0..@min(c.shape.in_piece, in.len - at)], &piece);
                at += step.in_len;
                total += step.out_len;
            }
            while (true) {
                const drained = c.d.finish(&piece);
                total += drained.out_len;
                if (drained.done) break;
            }
        };
        std.mem.doNotOptimizeAway(total);
    }
};

/// B7, compressing: `Deflate` with writes of 64 B and 4 KiB and whole
/// inputs, 4 KiB of output at a time, beside the whole-buffer compressor.
fn compress(s: *Session) !void {
    if (!s.wants("stream-compress/")) return;
    for (try s.workloads(), 0..) |wl, index| {
        if (!s.wants(try s.name("stream-compress/{s}/", .{wl.name}))) continue;
        for ([_]u4{ 1, 6, 9 }) |level| for (compress_shapes) |shape| {
            const ctx = try s.arena.create(Compress);
            ctx.* = .{ .session = s, .index = index, .level = level, .shape = shape };
            try s.measure(Compress, ctx, support.rowOf(Compress, try s.name("stream-compress/{s}/level {d}/{s}", .{ wl.name, level, shape.name }), "pass"));
        };
    }
}

/// Messages of a WebSocket conversation: JSON-like, 200 B to 16 KiB.
fn messages(arena: std.mem.Allocator, count: usize) ![]const []const u8 {
    const list = try arena.alloc([]const u8, count);
    var prng: gen.Prng = .init(66);
    for (list, 0..) |*m, i| {
        // Most messages are short.
        const len = 200 + if (prng.below(8) == 0) prng.below(16 << 10) else prng.below(1800);
        m.* = try gen.alloc(arena, .json, 1000 + i, len);
    }
    return list;
}

pub const WebSocket = struct {
    msgs: []const []const u8,
    /// Zero for no context takeover; else the window bits of the stream each way.
    bits: u8,
    next: usize = 0,
    arena: std.heap.ArenaAllocator = undefined,
    gpa: std.mem.Allocator,
    out: []u8 = &.{},
    back: []u8 = &.{},
    c: *warp.Compressor = undefined,
    dc: *warp.Decompressor = undefined,
    d: *warp.Deflate = undefined,
    z: *warp.Inflate = undefined,

    pub fn setup(x: *WebSocket) Error!void {
        x.arena = .init(x.gpa);
        errdefer x.arena.deinit();
        const a = x.arena.allocator();
        x.next = 0;
        x.out = try a.alloc(u8, 32 << 10);
        x.back = try a.alloc(u8, 32 << 10);
        x.c = try a.create(warp.Compressor);
        x.c.* = try .init(a, .{ .level = 1, .max_input = 32 << 10 });
        x.dc = try a.create(warp.Decompressor);
        x.dc.* = .init;
        if (x.bits != 0) {
            x.d = try a.create(warp.Deflate);
            x.d.* = try .init(a, .{ .level = 1, .container = .raw, .window_bits = @intCast(x.bits) });
            const window = try a.alloc(u8, @as(usize, 1) << @intCast(x.bits));
            x.z = try a.create(warp.Inflate);
            x.z.* = .init(window, .{ .accept = .raw, .window_bits = @intCast(x.bits) });
            x.d.reset(.nothing);
            x.z.reset(.nothing);
        }
    }

    pub fn teardown(x: *WebSocket) Error!void {
        x.c.deinit();
        x.arena.deinit();
    }

    pub fn run(x: *WebSocket, units: u64) Error!void {
        var total: u64 = 0;
        for (0..units) |_| {
            const m = x.msgs[x.next];
            x.next = (x.next + 1) % x.msgs.len;
            if (x.bits == 0) {
                // No context takeover: every message a whole raw stream,
                // compressed and decoded whole.
                const n = try x.c.compress(m, x.out, .{ .container = .raw });
                total += n;
                const r = try x.dc.inflate(x.out[0..n], x.back, .{ .accept = .raw });
                if (r.out_len != m.len) return error.WrongLength;
                continue;
            }
            // Context takeover: one stream each way, a sync flush per message,
            // its four last bytes stripped and put back on the other side.
            var n: usize = 0;
            var at: usize = 0;
            while (at < m.len) {
                const step = x.d.write(m[at..], x.out[n..]);
                at += step.in_len;
                n += step.out_len;
            }
            while (true) {
                const drained = x.d.flush(.sync, x.out[n..]);
                n += drained.out_len;
                if (drained.done) break;
            }
            total += n - 4;
            var written: usize = 0;
            var used: usize = 0;
            while (used < n) {
                const step = try x.z.decode(x.out[used..n], x.back[written..]);
                used += step.in_len;
                written += step.out_len;
                if (step.status == .need_input) break;
            }
            if (written != m.len) return error.WrongLength;
        }
        std.mem.doNotOptimizeAway(total);
    }
};

/// B6: a conversation's messages, one both ways per unit, under no context
/// takeover (whole-buffer calls, no state per connection) and context
/// takeover (a stream each way) at windows of 2^9 to 2^15.
fn websocket(s: *Session) !void {
    if (!s.wants("websocket/")) return;
    const count: usize = if (s.options.smoke) 100 else 100_000;
    const msgs = try messages(s.arena, count);
    for ([_]u8{ 0, 9, 10, 11, 12, 13, 14, 15 }) |bits| {
        const ctx = try s.arena.create(WebSocket);
        ctx.* = .{ .msgs = msgs, .bits = bits, .gpa = s.gpa };
        const name = if (bits == 0) try s.name("websocket/no context takeover", .{}) else try s.name("websocket/context takeover/window {d}", .{bits});
        try s.measure(WebSocket, ctx, support.rowOf(WebSocket, name, "message"));
    }
}
