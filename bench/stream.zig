//! The streaming rows: decoding and compressing in pieces beside the
//! whole-buffer calls (B7), and WebSocket messages under each of RFC
//! 7692's modes (B6).

const std = @import("std");
const Io = std.Io;
const warp = @import("warp");
const gen = @import("gen");

/// What every row needs from the driver.
pub const Run = struct {
    arena: std.mem.Allocator,
    io: Io,
    w: *Io.Writer,
    runs: usize,
    smoke: bool,
};

/// One function to time, and where its best time goes.
const Timed = struct {
    ctx: *anyopaque,
    run: *const fn (*anyopaque) anyerror!void,
    best: *u64,
};

/// Time each of `timed` `r.runs` times, interleaved: one run of each in
/// turn, so drift in the machine falls on all of them alike.
fn timeAll(r: Run, timed: []const Timed) !void {
    for (timed) |t| t.best.* = std.math.maxInt(u64);
    for (0..r.runs) |_| for (timed) |t| {
        const t0 = Io.Clock.awake.now(r.io).nanoseconds;
        try t.run(t.ctx);
        const ns: u64 = @intCast(Io.Clock.awake.now(r.io).nanoseconds - t0);
        t.best.* = @min(t.best.*, ns);
    };
}

fn mbps(bytes: u64, ns: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / 1e6 / (@as(f64, @floatFromInt(@max(ns, 1))) / 1e9);
}

/// A workload as the driver loads it: the inputs, as whole streams.
pub const Workload = struct {
    name: []const u8,
    inputs: []const []const u8,
    total: u64,
    max: usize,
};

const DecodeCtx = struct {
    streams: []const []const u8,
    inputs: []const []const u8,
    out: []u8,
    window: []u8,
    reader_buffer: []u8,
    d: *warp.Decompressor,
    in_piece: usize,
    out_piece: usize,

    fn whole(p: *anyopaque) anyerror!void {
        const c: *DecodeCtx = @ptrCast(@alignCast(p)); // safe: the context the row made
        for (c.streams, c.inputs) |s, in| {
            const r = try c.d.inflate(s, c.out[0..in.len], .{});
            if (r.out_len != in.len) return error.WrongLength;
        }
    }

    fn pieces(p: *anyopaque) anyerror!void {
        const c: *DecodeCtx = @ptrCast(@alignCast(p)); // safe: the context the row made
        for (c.streams, c.inputs) |s, in| {
            var z: warp.Inflate = .init(c.window, .{});
            var at: usize = 0;
            var written: usize = 0;
            while (true) {
                const in_len = @min(c.in_piece, s.len - at);
                const out_len = @min(c.out_piece, c.out.len - written);
                const step = try z.decode(s[at..][0..in_len], c.out[written..][0..out_len]);
                at += step.in_len;
                written += step.out_len;
                if (step.status == .done) break;
            }
            if (written != in.len) return error.WrongLength;
        }
    }

    fn reader(p: *anyopaque) anyerror!void {
        const c: *DecodeCtx = @ptrCast(@alignCast(p)); // safe: the context the row made
        for (c.streams, c.inputs) |s, in| {
            var input: Io.Reader = .fixed(s);
            var r: warp.Inflate.Reader = .init(&input, c.reader_buffer, .{});
            var written: usize = 0;
            while (true) {
                const n = try r.interface.readSliceShort(c.out[written..][0..@min(c.out_piece, c.out.len - written)]);
                if (n == 0) break;
                written += n;
            }
            if (written != in.len) return error.WrongLength;
        }
    }
};

/// B7, decoding: std's zlib streams at level 6 through `Inflate` in pieces
/// and through its reader, beside the whole-buffer decoder.
pub fn decode(r: Run, workloads: []const Workload, streams_of: []const []const []const u8) !void {
    try r.w.print("\nstream decode (std's zlib streams, level 6) | workload | MB out | whole MB/s | in 64 B | in 4 KiB | in 64 KiB, out 256 KiB | out 4 KiB | reader 4 KiB | in 1 B (first MB)\n", .{});
    const d = try r.arena.create(warp.Decompressor);
    d.* = .init;
    const window = try r.arena.alloc(u8, 1 << 15);
    const reader_buffer = try r.arena.alloc(u8, (1 << 15) + (64 << 10));
    for (workloads, streams_of) |wl, streams| {
        const out = try r.arena.alloc(u8, wl.max + warp.inflate_margin);
        var ctxs: [6]DecodeCtx = undefined;
        const shapes = [_][2]usize{ .{ 0, 0 }, .{ 64, 64 << 10 }, .{ 4096, 64 << 10 }, .{ 64 << 10, 256 << 10 }, .{ std.math.maxInt(usize), 4096 }, .{ 0, 4096 } };
        for (&ctxs, shapes) |*c, shape| c.* = .{ .streams = streams, .inputs = wl.inputs, .out = out, .window = window, .reader_buffer = reader_buffer, .d = d, .in_piece = shape[0], .out_piece = shape[1] };
        var best: [6]u64 = undefined;
        const fns = [_]*const fn (*anyopaque) anyerror!void{ DecodeCtx.whole, DecodeCtx.pieces, DecodeCtx.pieces, DecodeCtx.pieces, DecodeCtx.pieces, DecodeCtx.reader };
        var timed: [6]Timed = undefined;
        for (&timed, &ctxs, fns, &best) |*t, *c, f, *b| t.* = .{ .ctx = c, .run = f, .best = b };
        try timeAll(r, &timed);
        // A byte at a time costs a call per byte: the first megabyte.
        const first_mb = try firstMegabyte(r.arena, wl, streams);
        var one: DecodeCtx = .{ .streams = first_mb.streams, .inputs = first_mb.inputs, .out = out, .window = window, .reader_buffer = reader_buffer, .d = d, .in_piece = 1, .out_piece = 64 << 10 };
        var one_best: u64 = undefined;
        try timeAll(r, &.{.{ .ctx = &one, .run = DecodeCtx.pieces, .best = &one_best }});
        var one_total: u64 = 0;
        for (first_mb.inputs) |in| one_total += in.len;
        try r.w.print("stream decode | {s} | {d:.1} | {d:.0} | {d:.0} | {d:.0} | {d:.0} | {d:.0} | {d:.0} | {d:.0}\n", .{
            wl.name,                 @as(f64, @floatFromInt(wl.total)) / 1e6, mbps(wl.total, best[0]),   mbps(wl.total, best[1]), mbps(wl.total, best[2]), mbps(wl.total, best[3]),
            mbps(wl.total, best[4]), mbps(wl.total, best[5]),                 mbps(one_total, one_best),
        });
        try r.w.flush();
    }
}

const Subset = struct { streams: []const []const u8, inputs: []const []const u8 };

/// The streams whose inputs make up the first megabyte of a workload.
fn firstMegabyte(arena: std.mem.Allocator, wl: Workload, streams: []const []const u8) !Subset {
    var total: usize = 0;
    var n: usize = 0;
    while (n < wl.inputs.len and total < 1 << 20) : (n += 1) total += wl.inputs[n].len;
    // One large input: its own stream decoded whole is the megabyte's cost
    // and more; keep it as it is.
    _ = arena;
    return .{ .streams = streams[0..n], .inputs = wl.inputs[0..n] };
}

const CompressCtx = struct {
    inputs: []const []const u8,
    out: []u8,
    c: *warp.Compressor,
    d: *warp.Deflate,
    in_piece: usize,
    size: *u64,

    fn whole(p: *anyopaque) anyerror!void {
        const c: *CompressCtx = @ptrCast(@alignCast(p)); // safe: the context the row made
        var total: u64 = 0;
        for (c.inputs) |in| total += try c.c.compress(in, c.out, .{});
        c.size.* = total;
    }

    fn pieces(p: *anyopaque) anyerror!void {
        const c: *CompressCtx = @ptrCast(@alignCast(p)); // safe: the context the row made
        var total: u64 = 0;
        var piece: [4096]u8 = undefined;
        for (c.inputs) |in| {
            c.d.reset(.nothing);
            var at: usize = 0;
            while (at < in.len) {
                const step = c.d.write(in[at..][0..@min(c.in_piece, in.len - at)], &piece);
                at += step.in_len;
                total += step.out_len;
            }
            while (true) {
                const drained = c.d.finish(&piece);
                total += drained.out_len;
                if (drained.done) break;
            }
        }
        c.size.* = total;
    }
};

/// B7, compressing: `Deflate` with writes of 64 B and 4 KiB and whole
/// inputs, 4 KiB of output at a time, beside the whole-buffer compressor.
pub fn compress(r: Run, workloads: []const Workload) !void {
    try r.w.print("\nstream compress (zlib) | workload | level | MB in | whole MB/s | write 64 B | write 4 KiB | write whole | whole size | stream size\n", .{});
    for (workloads) |wl| for ([_]u4{ 1, 6, 9 }) |level| {
        const c = try r.arena.create(warp.Compressor);
        c.* = try .init(r.arena, .{ .level = level });
        const d = try r.arena.create(warp.Deflate);
        d.* = try .init(r.arena, .{ .level = level });
        const out = try r.arena.alloc(u8, warp.Compressor.bound(wl.max, .{}));
        var sizes: [4]u64 = undefined;
        var ctxs: [4]CompressCtx = undefined;
        for (&ctxs, [_]usize{ 0, 64, 4096, std.math.maxInt(usize) }, &sizes) |*x, piece, *size| x.* = .{ .inputs = wl.inputs, .out = out, .c = c, .d = d, .in_piece = piece, .size = size };
        var best: [4]u64 = undefined;
        var timed: [4]Timed = undefined;
        for (&timed, &ctxs, [_]*const fn (*anyopaque) anyerror!void{ CompressCtx.whole, CompressCtx.pieces, CompressCtx.pieces, CompressCtx.pieces }, &best) |*t, *x, f, *b| t.* = .{ .ctx = x, .run = f, .best = b };
        try timeAll(r, &timed);
        try r.w.print("stream compress | {s} | {d} | {d:.1} | {d:.0} | {d:.0} | {d:.0} | {d:.0} | {d} | {d}\n", .{ wl.name, level, @as(f64, @floatFromInt(wl.total)) / 1e6, mbps(wl.total, best[0]), mbps(wl.total, best[1]), mbps(wl.total, best[2]), mbps(wl.total, best[3]), sizes[0], sizes[3] });
        try r.w.flush();
    };
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

const WsCtx = struct {
    msgs: []const []const u8,
    out: []u8,
    back: []u8,
    c: *warp.Compressor,
    dc: *warp.Decompressor,
    d: *warp.Deflate,
    z: *warp.Inflate,
    size: *u64,

    /// No context takeover: every message a whole raw stream, compressed
    /// and decoded whole.
    fn whole(p: *anyopaque) anyerror!void {
        const x: *WsCtx = @ptrCast(@alignCast(p)); // safe: the context the row made
        var total: u64 = 0;
        for (x.msgs) |m| {
            const n = try x.c.compress(m, x.out, .{ .container = .raw });
            total += n;
            const r = try x.dc.inflate(x.out[0..n], x.back, .{ .accept = .raw });
            if (r.out_len != m.len) return error.WrongLength;
        }
        x.size.* = total;
    }

    /// Context takeover: one stream each way, a sync flush per message,
    /// its four last bytes stripped and put back on the other side.
    fn takeover(p: *anyopaque) anyerror!void {
        const x: *WsCtx = @ptrCast(@alignCast(p)); // safe: the context the row made
        x.d.reset(.nothing);
        x.z.reset(.nothing);
        var total: u64 = 0;
        for (x.msgs) |m| {
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
        x.size.* = total;
    }
};

/// B6: a conversation's messages under no context takeover (whole-buffer
/// calls, no state per connection) and context takeover (a stream each
/// way) at windows of 2^9 to 2^15.
pub fn websocket(r: Run) !void {
    const count: usize = if (r.smoke) 100 else 100_000;
    const msgs = try messages(r.arena, count);
    var total: u64 = 0;
    for (msgs) |m| total += m.len;
    try r.w.print("\nwebsocket (B6, {d} messages, {d:.1} MB, level 1) | mode | window | state per connection | compressed | ns per message (both ways)\n", .{ count, @as(f64, @floatFromInt(total)) / 1e6 });
    const out = try r.arena.alloc(u8, 32 << 10);
    const back = try r.arena.alloc(u8, 32 << 10);
    const c = try r.arena.create(warp.Compressor);
    c.* = try .init(r.arena, .{ .level = 1, .max_input = 32 << 10 });
    const dc = try r.arena.create(warp.Decompressor);
    dc.* = .init;
    var size: u64 = 0;
    {
        var x: WsCtx = .{ .msgs = msgs, .out = out, .back = back, .c = c, .dc = dc, .d = undefined, .z = undefined, .size = &size };
        var best: u64 = undefined;
        try timeAll(r, &.{.{ .ctx = &x, .run = WsCtx.whole, .best = &best }});
        try r.w.print("websocket | no context takeover | - | 0 | {d} | {d:.0}\n", .{ size, @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(count)) });
    }
    for (9..16) |bits| {
        const options: warp.Deflate.Options = .{ .level = 1, .container = .raw, .window_bits = @intCast(bits) };
        const d = try r.arena.create(warp.Deflate);
        d.* = try .init(r.arena, options);
        const window = try r.arena.alloc(u8, @as(usize, 1) << @intCast(bits));
        const z = try r.arena.create(warp.Inflate);
        z.* = .init(window, .{ .accept = .raw, .window_bits = @intCast(bits) });
        var x: WsCtx = .{ .msgs = msgs, .out = out, .back = back, .c = c, .dc = dc, .d = d, .z = z, .size = &size };
        var best: u64 = undefined;
        try timeAll(r, &.{.{ .ctx = &x, .run = WsCtx.takeover, .best = &best }});
        const state = warp.Deflate.memory(options) + @sizeOf(warp.Inflate) + window.len;
        try r.w.print("websocket | context takeover | {d} | {d} | {d} | {d:.0}\n", .{ bits, state, size, @as(f64, @floatFromInt(best)) / @as(f64, @floatFromInt(count)) });
        try r.w.flush();
    }
}
