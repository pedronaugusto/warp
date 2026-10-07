//! warp's own benchmarks: decoding, checksums and compression on generated
//! workloads and, given `--corpus <dir>`, on the book's corpora (the
//! batch files, tar and Silesia files pedronaugusto/trials prepares). Each
//! row times warp beside the code it replaces in the family
//! (bench/baseline/), interleaved, best and median of the runs.
//!
//!   bench [--smoke] [--corpus <dir>] [--runs <n>] [decode|crc32|crc32c|adler32|compress|setup]...
//!
//! `--smoke` runs every row once on tiny inputs; `zig build test` does that.

const std = @import("std");
const Io = std.Io;
const warp = @import("warp");
const gen = @import("gen");
const baseline = @import("baseline");

const Options = struct {
    smoke: bool = false,
    corpus: ?[]const u8 = null,
    runs: usize = 7,
};

/// One workload: the inputs, as whole streams.
const Workload = struct {
    name: []const u8,
    inputs: []const []const u8,
    total: u64,
    max: usize,
};

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);
    var options: Options = .{};
    var what: std.ArrayList([]const u8) = .empty;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--smoke")) {
            options.smoke = true;
        } else if (std.mem.eql(u8, args[i], "--corpus")) {
            i += 1;
            options.corpus = args[i];
        } else if (std.mem.eql(u8, args[i], "--runs")) {
            i += 1;
            options.runs = try std.fmt.parseInt(usize, args[i], 10);
        } else try what.append(arena, args[i]);
    }
    if (what.items.len == 0) try what.appendSlice(arena, &.{ "decode", "compress", "crc32", "crc32c", "adler32", "setup" });
    if (options.smoke) options.runs = 1;

    var out_buf: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &out_buf);
    const w = &stdout.interface;
    const k = warp.kernels();
    try w.print("warp bench: crc32 kernel {t}, crc32c kernel {t}, adler32 kernel {t}, {d} runs\n", .{ k.crc32, k.crc32c, k.adler32, options.runs });
    try w.flush();

    const workloads = try loadWorkloads(arena, io, options);
    for (what.items) |name| {
        if (std.mem.eql(u8, name, "decode")) {
            try decode(arena, io, w, options, workloads);
        } else if (std.mem.eql(u8, name, "crc32") or std.mem.eql(u8, name, "crc32c") or std.mem.eql(u8, name, "adler32")) {
            try checksums(arena, io, w, options, name);
        } else if (std.mem.eql(u8, name, "compress")) {
            try compress(arena, io, w, options, workloads);
        } else if (std.mem.eql(u8, name, "setup")) {
            try setup(arena, io, w, options);
        } else return error.UnknownBenchmark;
        try w.flush();
    }
}

fn loadWorkloads(arena: std.mem.Allocator, io: Io, options: Options) ![]Workload {
    var list: std.ArrayList(Workload) = .empty;
    const size: usize = if (options.smoke) 20_000 else 4 << 20;
    for ([_]gen.Kind{ .text, .binary, .png, .json, .runs }) |kind| {
        const one = try gen.alloc(arena, kind, 1, size);
        try list.append(arena, .{ .name = @tagName(kind), .inputs = try arena.dupe([]const u8, &.{one}), .total = one.len, .max = one.len });
    }
    // Small objects: many short texts, as git's loose objects are.
    {
        const count: usize = if (options.smoke) 10 else 4000;
        const inputs = try arena.alloc([]const u8, count);
        var total: u64 = 0;
        var prng: gen.Prng = .init(7);
        for (inputs, 0..) |*in, n| {
            in.* = try gen.alloc(arena, .text, n, 200 + prng.below(2000));
            total += in.len;
        }
        try list.append(arena, .{ .name = "small-text", .inputs = inputs, .total = total, .max = 2200 });
    }
    if (options.corpus) |dir| {
        try list.append(arena, try objects(arena, io, dir, "loose-git", "objects-git.batch", std.math.maxInt(usize)));
        try list.append(arena, try objects(arena, io, dir, "loose-git-small", "objects-git.batch", 4096));
        try list.append(arena, try files(arena, io, dir, "tar", &.{"git-v2.51.0.tar"}));
        try list.append(arena, try files(arena, io, dir, "silesia", &.{ "silesia/dickens", "silesia/mozilla", "silesia/mr", "silesia/nci", "silesia/ooffice", "silesia/osdb", "silesia/reymont", "silesia/samba", "silesia/sao", "silesia/webster", "silesia/x-ray", "silesia/xml" }));
    }
    return list.items;
}

/// `git cat-file --batch` output, each object as a loose object deflates it.
fn objects(arena: std.mem.Allocator, io: Io, dir: []const u8, name: []const u8, file: []const u8, max_size: usize) !Workload {
    const path = try std.fs.path.join(arena, &.{ dir, file });
    const data = try Io.Dir.cwd().readFileAlloc(io, path, arena, .unlimited);
    var inputs: std.ArrayList([]const u8) = .empty;
    var total: u64 = 0;
    var max: usize = 0;
    var pos: usize = 0;
    while (pos < data.len) {
        const nl = std.mem.findScalarPos(u8, data, pos, '\n') orelse return error.BadBatch;
        var it = std.mem.splitScalar(u8, data[pos..nl], ' ');
        _ = it.next();
        const kind = it.next() orelse return error.BadBatch;
        const size = try std.fmt.parseInt(usize, it.next() orelse return error.BadBatch, 10);
        const body = data[nl + 1 ..][0..size];
        pos = nl + 1 + size + 1;
        if (size > max_size) continue;
        const object = try std.fmt.allocPrint(arena, "{s} {d}\x00{s}", .{ kind, size, body });
        try inputs.append(arena, object);
        total += object.len;
        max = @max(max, object.len);
    }
    return .{ .name = name, .inputs = inputs.items, .total = total, .max = max };
}

fn files(arena: std.mem.Allocator, io: Io, dir: []const u8, name: []const u8, names: []const []const u8) !Workload {
    var inputs: std.ArrayList([]const u8) = .empty;
    var total: u64 = 0;
    var max: usize = 0;
    for (names) |n| {
        const data = try Io.Dir.cwd().readFileAlloc(io, try std.fs.path.join(arena, &.{ dir, n }), arena, .unlimited);
        try inputs.append(arena, data);
        total += data.len;
        max = @max(max, data.len);
    }
    return .{ .name = name, .inputs = inputs.items, .total = total, .max = max };
}

/// zlib streams of each input at `level`, written by std's compressor (the
/// same streams for every decoder).
fn zlibStreams(arena: std.mem.Allocator, workload: Workload, level: std.compress.flate.Compress.Options) ![]const []const u8 {
    const window = try arena.alloc(u8, std.compress.flate.max_window_len);
    const streams = try arena.alloc([]const u8, workload.inputs.len);
    const out = try arena.alloc(u8, workload.max + workload.max / 8 + 1024);
    for (workload.inputs, streams) |in, *s| {
        var w: Io.Writer = .fixed(out);
        var c = try std.compress.flate.Compress.init(&w, window, .zlib, level);
        try c.writer.writeAll(in);
        try c.finish();
        s.* = try arena.dupe(u8, w.buffered());
    }
    return streams;
}

const Timing = struct { best: u64, median: u64 };

fn now(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

/// Time each of `fns` on `ctx` `runs` times, interleaved: one run of each
/// in turn, so drift in the machine falls on all of them alike.
fn timeAll(io: Io, runs: usize, comptime n: usize, ctx: anytype, comptime fns: [n]fn (@TypeOf(ctx)) anyerror!void) ![n]Timing {
    var samples: [n][64]u64 = undefined;
    for (0..runs) |r| {
        inline for (fns, 0..) |f, j| {
            const t0 = now(io);
            try f(ctx);
            samples[j][r] = @intCast(now(io) - t0);
        }
    }
    var out: [n]Timing = undefined;
    for (&out, 0..) |*t, j| {
        const s = samples[j][0..runs];
        std.sort.pdq(u64, s, {}, std.sort.asc(u64));
        t.* = .{ .best = s[0], .median = s[runs / 2] };
    }
    return out;
}

fn mbps(bytes: u64, ns: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) / 1e6 / (@as(f64, @floatFromInt(@max(ns, 1))) / 1e9);
}

const DecodeCtx = struct {
    d: *warp.Decompressor,
    relic: *baseline.inflate.Decoder,
    streams: []const []const u8,
    inputs: []const []const u8,
    out: []u8,
    margin: bool,

    fn warpRun(c: DecodeCtx) anyerror!void {
        for (c.streams, c.inputs) |s, in| {
            const len = if (c.margin) in.len + warp.inflate_margin else in.len;
            const r = try c.d.inflate(s, c.out[0..len], .{});
            if (r.out_len != in.len) return error.WrongLength;
        }
    }

    fn warpMargin(c: DecodeCtx) anyerror!void {
        var m = c;
        m.margin = true;
        return warpRun(m);
    }

    fn warpExact(c: DecodeCtx) anyerror!void {
        var m = c;
        m.margin = false;
        return warpRun(m);
    }

    fn relicRun(c: DecodeCtx) anyerror!void {
        for (c.streams, c.inputs) |s, in| {
            var r: Io.Reader = .fixed(s);
            const n = try c.relic.zlib(&r, c.out[0..in.len]);
            if (n != in.len) return error.WrongLength;
        }
    }
};

fn decode(arena: std.mem.Allocator, io: Io, w: *Io.Writer, options: Options, workloads: []const Workload) !void {
    const d = try arena.create(warp.Decompressor);
    d.* = .init;
    const relic = try arena.create(baseline.inflate.Decoder);
    relic.* = .{};
    try w.print("\ndecode (std's zlib streams, level 6) | workload | MB out | warp exact MB/s | warp +margin MB/s | relic MB/s | warp/relic\n", .{});
    for (workloads) |wl| {
        const streams = try zlibStreams(arena, wl, .level_6);
        const out = try arena.alloc(u8, wl.max + warp.inflate_margin);
        const ctx: DecodeCtx = .{ .d = d, .relic = relic, .streams = streams, .inputs = wl.inputs, .out = out, .margin = false };
        // One untimed pass of each, checking the output.
        try DecodeCtx.warpExact(ctx);
        for (streams, wl.inputs) |s, in| {
            _ = try d.inflate(s, out[0..in.len], .{});
            if (!std.mem.eql(u8, out[0..in.len], in)) return error.WrongOutput;
        }
        try DecodeCtx.relicRun(ctx);
        const t = try timeAll(io, options.runs, 3, ctx, .{ DecodeCtx.warpExact, DecodeCtx.warpMargin, DecodeCtx.relicRun });
        try w.print("decode | {s} | {d:.1} | {d:.0} | {d:.0} | {d:.0} | {d:.2}x\n", .{
            wl.name,                                                                          @as(f64, @floatFromInt(wl.total)) / 1e6, mbps(wl.total, t[0].best), mbps(wl.total, t[1].best), mbps(wl.total, t[2].best),
            @as(f64, @floatFromInt(t[2].best)) / @as(f64, @floatFromInt(@max(t[0].best, 1))),
        });
        try w.flush();
    }
}

const ChecksumCtx = struct {
    data: []const u8,
    reps: usize,
    sink: *u32,

    fn each(c: ChecksumCtx, comptime f: fn ([]const u8) u32) void {
        for (0..c.reps) |_| {
            // A barrier, so no call is hoisted out of the loop as invariant.
            asm volatile (""
                :
                : [data] "r" (c.data.ptr),
                : .{ .memory = true });
            c.sink.* +%= f(c.data);
        }
    }
    fn warpCrc(c: ChecksumCtx) anyerror!void {
        c.each(warp.Crc32.hash);
    }
    fn relicCrc(c: ChecksumCtx) anyerror!void {
        c.each(baseline.crc32.Crc32.hash);
    }
    fn stdCrc(c: ChecksumCtx) anyerror!void {
        c.each(std.hash.Crc32.hash);
    }
    fn warpCrcC(c: ChecksumCtx) anyerror!void {
        c.each(warp.Crc32c.hash);
    }
    fn chronicleCrcC(c: ChecksumCtx) anyerror!void {
        c.each(baseline.crc32c.hash);
    }
    fn stdCrcC(c: ChecksumCtx) anyerror!void {
        c.each(std.hash.crc.@"CRC-32/ISCSI".hash);
    }
    fn warpAdler(c: ChecksumCtx) anyerror!void {
        c.each(warp.Adler32.hash);
    }
    fn relicAdler(c: ChecksumCtx) anyerror!void {
        c.each(baseline.inflate.adler32);
    }
    fn stdAdler(c: ChecksumCtx) anyerror!void {
        c.each(std.hash.Adler32.hash);
    }
};

fn checksums(arena: std.mem.Allocator, io: Io, w: *Io.Writer, options: Options, which: []const u8) !void {
    const sizes = [_]usize{ 64, 1024, 64 << 10, 64 << 20 };
    const big_len: usize = if (options.smoke) 70 << 10 else 64 << 20;
    const big = try gen.alloc(arena, .noise, 3, big_len + 8);
    var sink: u32 = 0;
    const crc32c = std.mem.eql(u8, which, "crc32c");
    try w.print("\n{s} | size | alignment | warp GB/s | {s} GB/s | std GB/s\n", .{ which, if (crc32c) "chronicle" else "relic" });
    for (sizes) |size| {
        if (size > big.len - 8) continue;
        for ([_]usize{ 0, 1, 7 }) |alignment| {
            // Enough repetitions of small sizes to time.
            const budget: usize = if (options.smoke) 1 << 16 else 64 << 20;
            const reps = @max(1, budget / size);
            const data = big[alignment..][0..size];
            const ctx: ChecksumCtx = .{ .data = data, .reps = reps, .sink = &sink };
            const t = if (std.mem.eql(u8, which, "crc32"))
                try timeAll(io, options.runs, 3, ctx, .{ ChecksumCtx.warpCrc, ChecksumCtx.relicCrc, ChecksumCtx.stdCrc })
            else if (crc32c)
                try timeAll(io, options.runs, 3, ctx, .{ ChecksumCtx.warpCrcC, ChecksumCtx.chronicleCrcC, ChecksumCtx.stdCrcC })
            else
                try timeAll(io, options.runs, 3, ctx, .{ ChecksumCtx.warpAdler, ChecksumCtx.relicAdler, ChecksumCtx.stdAdler });
            const bytes: u64 = @intCast(size * reps);
            try w.print("{s} | {d} | {d} | {d:.2} | {d:.2} | {d:.2}\n", .{ which, size, alignment, mbps(bytes, t[0].best) / 1000, mbps(bytes, t[1].best) / 1000, mbps(bytes, t[2].best) / 1000 });
        }
    }
    std.mem.doNotOptimizeAway(sink);
}

/// Per-stream cost of tiny streams: an empty one and a 37-byte object.
fn setup(arena: std.mem.Allocator, io: Io, w: *Io.Writer, options: Options) !void {
    const d = try arena.create(warp.Decompressor);
    d.* = .init;
    const relic = try arena.create(baseline.inflate.Decoder);
    relic.* = .{};
    const rounds: usize = if (options.smoke) 10 else 200_000;
    const inputs = [_][]const u8{ "", "blob 28\x00tiny file for the setup case\n" };
    try w.print("\nsetup | input | warp ns/stream | relic ns/stream\n", .{});
    for (inputs) |in| {
        const wl: Workload = .{ .name = "setup", .inputs = &.{in}, .total = in.len, .max = in.len };
        const streams = try zlibStreams(arena, wl, .level_6);
        var out: [64]u8 = undefined;
        const Ctx = struct {
            d: *warp.Decompressor,
            relic: *baseline.inflate.Decoder,
            stream: []const u8,
            out: []u8,
            rounds: usize,
            fn warpRun(c: @This()) anyerror!void {
                for (0..c.rounds) |_| _ = try c.d.inflate(c.stream, c.out, .{});
            }
            fn relicRun(c: @This()) anyerror!void {
                for (0..c.rounds) |_| {
                    var r: Io.Reader = .fixed(c.stream);
                    _ = try c.relic.zlib(&r, c.out);
                }
            }
        };
        const t = try timeAll(io, options.runs, 2, Ctx{ .d = d, .relic = relic, .stream = streams[0], .out = out[0..in.len], .rounds = rounds }, .{ Ctx.warpRun, Ctx.relicRun });
        try w.print("setup | {d} B | {d:.1} | {d:.1}\n", .{ in.len, @as(f64, @floatFromInt(t[0].best)) / @as(f64, @floatFromInt(rounds)), @as(f64, @floatFromInt(t[1].best)) / @as(f64, @floatFromInt(rounds)) });
    }
    // A compression costs microseconds: a tenth of the rounds.
    try setupCompress(arena, io, w, options, @max(1, rounds / 10), &inputs);
}

/// Per-stream cost of compressing tiny inputs, beside std's, which sets up
/// a whole window per stream.
fn setupCompress(arena: std.mem.Allocator, io: Io, w: *Io.Writer, options: Options, rounds: usize, inputs: []const []const u8) !void {
    _ = options;
    const window = try arena.alloc(u8, std.compress.flate.max_window_len);
    var out: [128]u8 = undefined;
    try w.print("\nsetup compress | level | input | warp ns/stream | std ns/stream\n", .{});
    const levels = [_]struct { u4, std.compress.flate.Compress.Options }{ .{ 1, .level_1 }, .{ 6, .level_6 } };
    for (levels) |level| for (inputs) |in| {
        const c = try arena.create(warp.Compressor);
        c.* = try .init(arena, .{ .level = level[0] });
        defer c.deinit();
        var sizes: [2]u64 = undefined;
        const Ctx = struct {
            inner: CompressCtx,
            rounds: usize,
            fn warpRun(x: @This()) anyerror!void {
                for (0..x.rounds) |_| try x.inner.warpRun();
            }
            fn stdRun(x: @This()) anyerror!void {
                for (0..x.rounds) |_| try x.inner.stdRun();
            }
        };
        const inner: CompressCtx = .{ .c = c, .std_level = level[1], .window = window, .inputs = &.{in}, .out = &out, .sizes = &sizes };
        const t = try timeAll(io, 7, 2, Ctx{ .inner = inner, .rounds = rounds }, .{ Ctx.warpRun, Ctx.stdRun });
        try w.print("setup compress | {d} | {d} B | {d:.0} | {d:.0}\n", .{ level[0], in.len, @as(f64, @floatFromInt(t[0].best)) / @as(f64, @floatFromInt(rounds)), @as(f64, @floatFromInt(t[1].best)) / @as(f64, @floatFromInt(rounds)) });
    };
}

const CompressCtx = struct {
    c: *warp.Compressor,
    std_level: std.compress.flate.Compress.Options,
    window: []u8,
    inputs: []const []const u8,
    out: []u8,
    sizes: *[2]u64,

    fn warpRun(c: CompressCtx) anyerror!void {
        var total: u64 = 0;
        for (c.inputs) |in| total += try c.c.compress(in, c.out, .{});
        c.sizes[0] = total;
    }

    fn stdRun(c: CompressCtx) anyerror!void {
        var total: u64 = 0;
        for (c.inputs) |in| {
            var w: Io.Writer = .fixed(c.out);
            var s = try std.compress.flate.Compress.init(&w, c.window, .zlib, c.std_level);
            try s.writer.writeAll(in);
            try s.finish();
            total += w.buffered().len;
        }
        c.sizes[1] = total;
    }
};

/// Compression at levels 1, 6 and 9 beside std's at the same levels (relic
/// compresses with std): input MB/s and the output's share of the input.
fn compress(arena: std.mem.Allocator, io: Io, w: *Io.Writer, options: Options, workloads: []const Workload) !void {
    const window = try arena.alloc(u8, std.compress.flate.max_window_len);
    try w.print("\ncompress (zlib) | workload | level | MB in | warp MB/s | std MB/s | warp/std | warp size | std size\n", .{});
    const levels = [_]struct { u4, std.compress.flate.Compress.Options }{ .{ 1, .level_1 }, .{ 6, .level_6 }, .{ 9, .level_9 } };
    for (workloads) |wl| for (levels) |level| {
        const c = try arena.create(warp.Compressor);
        c.* = try .init(arena, .{ .level = level[0] });
        defer c.deinit();
        const out = try arena.alloc(u8, warp.Compressor.bound(wl.max, .{}));
        var sizes: [2]u64 = undefined;
        const ctx: CompressCtx = .{ .c = c, .std_level = level[1], .window = window, .inputs = wl.inputs, .out = out, .sizes = &sizes };
        const t = try timeAll(io, options.runs, 2, ctx, .{ CompressCtx.warpRun, CompressCtx.stdRun });
        const total: f64 = @floatFromInt(wl.total);
        try w.print("compress | {s} | {d} | {d:.1} | {d:.0} | {d:.0} | {d:.2}x | {d:.2}% | {d:.2}%\n", .{
            wl.name,                                                                          level[0],                                        total / 1e6,                                     mbps(wl.total, t[0].best), mbps(wl.total, t[1].best),
            @as(f64, @floatFromInt(t[1].best)) / @as(f64, @floatFromInt(@max(t[0].best, 1))), 100 * @as(f64, @floatFromInt(sizes[0])) / total, 100 * @as(f64, @floatFromInt(sizes[1])) / total,
        });
        try w.flush();
    };
}
