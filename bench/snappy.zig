//! Snappy and S2 block throughput and setup on generated or caller-provided
//! inputs, measured through shakedown: `snappy/<input>/<format> <level>/
//! encode` and `.../decode` for each parser in each format it writes,
//! `snappy-dict/<input>/<level>/...` for S2's parsers over a dictionary of
//! the same kind of input, and `snappy-setup/...` for a tiny block.
//! Streams at S2's writer's defaults: `snappy-stream/<input>/<format>
//! <level>/...` whole-buffer, `snappy-resumable/...` through `Compress` and
//! `Decompress` in 64 KiB pieces, `snappy-parallel/<input>/<k> workers/...`
//! by worker count up to the CPUs the machine has (blocks of 64 KiB), and
//! `snappy-seek/<input>/...` a 4 KiB read at an offset found by the index.
//! One row each. google/snappy and klauspost/compress s2 are timed on the
//! same inputs in trials (warp/snappy).
//!
//!   snappy-bench [--smoke] [--row <prefix>] [--file <path>]
const std = @import("std");
const Io = std.Io;
const ensign = @import("ensign");
const warp = @import("warp");
const gen = @import("gen");
const support = @import("support.zig");

const snappy = warp.snappy;
const Level = snappy.Compressor.Level;
const Session = support.Session;
const Error = support.Error;

const Arguments = struct {
    smoke: bool = false,
    row: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
    file: ?[]const u8 = null,
    pub const spec: ensign.Spec(@This()) = .{ .name = "snappy-bench", .options = .{
        .smoke = .{ .help = "Run each row once, untimed" },
        .row = .{ .help = "Run the rows whose names start with this" },
        .prefix = .{ .positional = true, .help = "The same as --row" },
        .file = .{ .help = "Measure this file in place of the generated inputs", .hint = .file },
    } };
};

/// Each parser in each format it writes.
const points = [_]struct { format: snappy.Format, level: Level }{
    .{ .format = .snappy, .level = .snappy_1 },
    .{ .format = .snappy, .level = .snappy_2 },
    .{ .format = .snappy, .level = .fast },
    .{ .format = .snappy, .level = .better },
    .{ .format = .snappy, .level = .best },
    .{ .format = .s2, .level = .fast },
    .{ .format = .s2, .level = .better },
    .{ .format = .s2, .level = .best },
};

pub fn main(init: std.process.Init) !void {
    const arguments = ensign.parseOrExit(Arguments, init);
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(init.io, &buffer);
    var session: Session = .init(init, &stdout.interface, arguments.smoke, arguments.row orelse arguments.prefix orelse "", null);
    const a = session.arena;

    // Each input with a dictionary from another input of its kind.
    var inputs: std.ArrayList(struct { []const u8, []const u8, ?snappy.Dict }) = .empty;
    if (arguments.file) |path| {
        try inputs.append(a, .{ path, try support.readFile(init.io, a, path), null });
    } else {
        const len: usize = if (arguments.smoke) 20_000 else 4 << 20;
        for ([_]gen.Kind{ .text, .binary, .json, .noise, .runs, .png }) |kind| {
            const input = try gen.alloc(a, kind, 4, len);
            const source = try gen.alloc(a, kind, 5, snappy.Dict.max_len);
            try inputs.append(a, .{ @tagName(kind), input, snappy.Dict.make(source, input) });
        }
    }

    for (inputs.items) |input| for (points) |point| for ([_]bool{ true, false }) |encode| {
        const name = try session.name("snappy/{s}/{t} {t}/{s}", .{ input[0], point.format, point.level, if (encode) "encode" else "decode" });
        if (!session.wants(name)) continue;
        const ctx = try a.create(Whole);
        ctx.* = .{ .session = &session, .input = input[1], .options = .{ .format = point.format, .level = point.level }, .encode = encode };
        try session.measure(Whole, ctx, support.rowOf(Whole, name, "block"));
    };
    for (inputs.items) |input| for ([_]Level{ .fast, .better, .best }) |level| for ([_]bool{ true, false }) |encode| {
        const dict = input[2] orelse continue;
        const name = try session.name("snappy-dict/{s}/{t}/{s}", .{ input[0], level, if (encode) "encode" else "decode" });
        if (!session.wants(name)) continue;
        const ctx = try a.create(Whole);
        ctx.* = .{ .session = &session, .input = input[1], .options = .{ .format = .s2, .level = level, .dictionary = dict }, .encode = encode };
        try session.measure(Whole, ctx, support.rowOf(Whole, name, "block"));
    };
    for (inputs.items) |input| for ([_]Kind{ .stream, .resumable }) |kind| for (points) |point| for ([_]bool{ true, false }) |encode| {
        const name = try session.name("snappy-{t}/{s}/{t} {t}/{s}", .{ kind, input[0], point.format, point.level, if (encode) "encode" else "decode" });
        if (!session.wants(name)) continue;
        const ctx = try a.create(Stream);
        ctx.* = .{ .session = &session, .kind = kind, .input = input[1], .options = .{ .format = point.format, .level = point.level }, .encode = encode };
        try session.measure(Stream, ctx, support.rowOf(Stream, name, "pass"));
    };
    var workers: u16 = 1;
    while (workers <= session.cpus) : (workers *= 2) for (inputs.items) |input| for ([_]bool{ true, false }) |encode| {
        const name = try session.name("snappy-parallel/{s}/{d} workers/{s}", .{ input[0], workers, if (encode) "encode" else "decode" });
        if (!session.wants(name)) continue;
        const ctx = try a.create(Stream);
        ctx.* = .{ .session = &session, .kind = .parallel, .input = input[1], .options = .{ .format = .s2 }, .encode = encode, .workers = workers };
        try session.measure(Stream, ctx, support.rowOf(Stream, name, "pass"));
    };
    for (inputs.items) |input| {
        const name = try session.name("snappy-seek/{s}/4 KiB at an offset", .{input[0]});
        if (!session.wants(name)) continue;
        const ctx = try a.create(Seek);
        ctx.* = .{ .session = &session, .input = input[1] };
        try session.measure(Seek, ctx, support.rowOf(Seek, name, "read"));
    }
    try setup(&session);
    try stdout.interface.flush();
}

const Kind = enum { stream, resumable, parallel };

/// One stream of the whole input, compressed or decompressed: whole, in
/// 64 KiB pieces, or by workers.
pub const Stream = struct {
    session: *Session,
    kind: Kind,
    input: []const u8,
    options: snappy.Compressor.Options,
    encode: bool,
    workers: u16 = 1,
    arena: std.heap.ArenaAllocator = undefined,
    c: snappy.Compressor = undefined,
    pc: snappy.parallel.Compressor = undefined,
    pd: snappy.parallel.Decompressor = undefined,
    settings: snappy.Stream = .{},
    out: []u8 = &.{},
    back: []u8 = &.{},
    window: []u8 = &.{},
    n: usize = 0,

    pub fn setup(c: *Stream) Error!void {
        c.arena = .init(c.session.gpa);
        errdefer c.arena.deinit();
        const a = c.arena.allocator();
        if (c.kind == .parallel) c.settings.block_size = .literal("64KiB");
        c.out = try a.alloc(u8, snappy.streamBound(c.options, c.input.len, c.settings));
        c.back = try a.alloc(u8, c.input.len);
        c.window = try a.alloc(u8, snappy.Decompress.memory(.literal("4MiB")));
        c.c = try .init(c.session.gpa, c.options);
        errdefer c.c.deinit();
        c.pc = try .init(c.session.gpa, .{ .concurrency = c.workers, .compressor = c.options, .stream = c.settings });
        errdefer c.pc.deinit();
        c.pd = try .init(c.session.gpa, .{ .concurrency = c.workers });
        errdefer c.pd.deinit();
        c.n = try c.compress();
        const r = try c.decompress();
        if (r != c.input.len or !std.mem.eql(u8, c.input, c.back[0..r])) return error.WrongOutput;
    }

    fn compress(c: *Stream) Error!usize {
        return switch (c.kind) {
            .stream => (try c.c.compress(c.input, c.out, c.settings)).len,
            .parallel => (try c.pc.compress(c.session.io, c.input, c.out)).len,
            .resumable => blk: {
                var s: snappy.Compress = try .init(c.arena.allocator(), .{ .compressor = c.options, .stream = c.settings });
                defer s.deinit();
                var ip: usize = 0;
                var op: usize = 0;
                while (ip < c.input.len) {
                    const w = try s.write(c.input[ip..@min(c.input.len, ip + 65536)], c.out[op..]);
                    ip += w.in_len;
                    op += w.out_len;
                }
                while (true) {
                    const f = try s.finish(c.out[op..]);
                    op += f.out_len;
                    if (f.done) break :blk op;
                }
            },
        };
    }

    fn decompress(c: *Stream) Error!usize {
        switch (c.kind) {
            .stream => return snappy.decompress(c.out[0..c.n], c.back, .{}),
            .parallel => return c.pd.decompress(c.session.io, c.out[0..c.n], c.back, .{}),
            .resumable => {
                var d: snappy.Decompress = .init(c.window, .{});
                var op: usize = 0;
                var ip: usize = 0;
                while (true) {
                    const step = try d.decode(c.out[ip..@min(c.n, ip + 65536)], c.back[op..]);
                    ip += step.in_len;
                    op += step.out_len;
                    if (step.status == .need_input and ip == c.n) break;
                }
                try d.finish();
                return op;
            },
        }
    }

    pub fn teardown(c: *Stream) Error!void {
        c.pd.deinit();
        c.pc.deinit();
        c.c.deinit();
        c.arena.deinit();
    }

    pub fn run(c: *Stream, units: u64) Error!void {
        for (0..units) |_| {
            if (c.encode) std.mem.doNotOptimizeAway(try c.compress()) else std.mem.doNotOptimizeAway(try c.decompress());
        }
    }
};

/// A 4 KiB read at an offset of an indexed stream: the entry found, the
/// reader started there, and the rest of the way skipped.
pub const Seek = struct {
    session: *Session,
    input: []const u8,
    arena: std.heap.ArenaAllocator = undefined,
    stream: []u8 = &.{},
    index: snappy.Index = undefined,
    window: []u8 = &.{},
    back: [4096]u8 = undefined,
    at: u64 = 0,

    pub fn setup(c: *Seek) Error!void {
        c.arena = .init(c.session.gpa);
        errdefer c.arena.deinit();
        const a = c.arena.allocator();
        const options: snappy.Compressor.Options = .{ .format = .s2 };
        const settings: snappy.Stream = .{ .block_size = .literal("64KiB"), .index = .append };
        var co: snappy.Compressor = try .init(c.session.gpa, options);
        defer co.deinit();
        const out = try a.alloc(u8, snappy.streamBound(options, c.input.len, settings));
        c.stream = out[0..(try co.compress(c.input, out, settings)).len];
        c.index = snappy.Index.loadFromEnd(c.stream, try a.alloc(snappy.Index.Entry, snappy.Index.max_entries)) catch return error.WrongOutput;
        c.window = try a.alloc(u8, snappy.Decompress.memory(.literal("4MiB")));
        c.at = c.input.len / 3;
        const n = try c.read();
        if (!std.mem.eql(u8, c.input[@intCast(c.at)..][0..n], c.back[0..n])) return error.WrongOutput;
    }

    fn read(c: *Seek) Error!usize {
        const e = c.index.find(@intCast(c.at)) catch return error.WrongOutput;
        var d: snappy.Decompress = .init(c.window, .{ .from_chunk = true });
        d.skip(c.at - e.uncompressed);
        const want = @min(c.back.len, c.input.len - @as(usize, @intCast(c.at)));
        var ip: usize = @intCast(e.compressed);
        var op: usize = 0;
        while (op < want) {
            const step = try d.decode(c.stream[ip..], c.back[op..want]);
            ip += step.in_len;
            op += step.out_len;
            if (step.status == .need_input) return error.WrongOutput;
        }
        return op;
    }

    pub fn teardown(c: *Seek) Error!void {
        c.arena.deinit();
    }

    pub fn run(c: *Seek, units: u64) Error!void {
        for (0..units) |_| std.mem.doNotOptimizeAway(try c.read());
    }
};

/// One block of the whole input, compressed or decompressed.
pub const Whole = struct {
    session: *Session,
    input: []const u8,
    options: snappy.Compressor.Options,
    encode: bool,
    c: snappy.Compressor = undefined,
    out: []u8 = &.{},
    back: []u8 = &.{},
    n: usize = 0,

    pub fn setup(c: *Whole) Error!void {
        const gpa = c.session.gpa;
        c.out = try gpa.alloc(u8, snappy.blockBound(c.input.len));
        errdefer gpa.free(c.out);
        c.back = try gpa.alloc(u8, c.input.len);
        errdefer gpa.free(c.back);
        c.c = try .init(gpa, c.options);
        errdefer c.c.deinit();
        c.n = try c.c.compressBlock(c.input, c.out);
        const r = try c.decompress();
        if (r != c.input.len or !std.mem.eql(u8, c.input, c.back[0..r])) return error.WrongOutput;
    }

    fn decompress(c: *Whole) Error!usize {
        return snappy.decompressBlock(c.out[0..c.n], c.back, .{ .format = c.options.format, .dictionary = c.options.dictionary });
    }

    pub fn teardown(c: *Whole) Error!void {
        c.c.deinit();
        c.session.gpa.free(c.back);
        c.session.gpa.free(c.out);
    }

    pub fn run(c: *Whole, units: u64) Error!void {
        for (0..units) |_| {
            if (c.encode) std.mem.doNotOptimizeAway(try c.c.compressBlock(c.input, c.out)) else std.mem.doNotOptimizeAway(try c.decompress());
        }
    }
};

/// The cost of one tiny block, encoded or decoded: the parser's tables
/// cleared for it, the decoder's setup.
pub const Tiny = struct {
    session: *Session,
    options: snappy.Compressor.Options,
    input: []const u8,
    encode: bool,
    c: snappy.Compressor = undefined,
    out: [128]u8 = undefined,
    back: [128]u8 = undefined,
    n: usize = 0,

    pub fn setup(c: *Tiny) Error!void {
        c.c = try .init(c.session.gpa, c.options);
        errdefer c.c.deinit();
        c.n = try c.c.compressBlock(c.input, &c.out);
    }

    pub fn teardown(c: *Tiny) Error!void {
        c.c.deinit();
    }

    pub fn run(c: *Tiny, units: u64) Error!void {
        for (0..units) |_| {
            if (c.encode) {
                std.mem.doNotOptimizeAway(try c.c.compressBlock(c.input, &c.out));
            } else std.mem.doNotOptimizeAway(try snappy.decompressBlock(c.out[0..c.n], c.back[0..c.input.len], .{ .format = c.options.format }));
        }
    }
};

fn setup(s: *Session) !void {
    if (!s.wants("snappy-setup/")) return;
    for (points) |point| for ([_][]const u8{ "", "blob 28\x00tiny file for the setup case\n", "a tiny file long enough for the S2 parsers to parse\n" }) |input| for ([_]bool{ true, false }) |encode| {
        const ctx = try s.arena.create(Tiny);
        ctx.* = .{ .session = s, .options = .{ .format = point.format, .level = point.level }, .input = input, .encode = encode };
        try s.measure(Tiny, ctx, support.rowOf(Tiny, try s.name("snappy-setup/{t} {t}/{d} B/{s}", .{ point.format, point.level, input.len, if (encode) "encode" else "decode" }), "block"));
    };
}
