//! warp's DEFLATE benchmarks, measured through shakedown: decoding, checksums
//! and compression on generated workloads and, given `--corpus <dir>`, on the
//! book's corpora (the batch files, tar and Silesia files pedronaugusto/trials
//! prepares). Each row times warp beside std, one row each:
//! `family/workload/variant`.
//!
//!   bench [--smoke] [--corpus <dir>] [--row <prefix>]
//!
//! The families are decode, crc32, crc32c, adler32, compress, setup,
//! stream-decode, stream-compress, websocket, parallel and speculative.
//! `zig build bench` runs them all; `--row decode/text` runs the rows whose
//! names start so, as preflight's `bench-ab` asks. Sizes of the compressed
//! output are `check-sizes`' to keep, not a timing's.
const std = @import("std");
const Io = std.Io;
const ensign = @import("ensign");
const warp = @import("warp");
const gen = @import("gen");
const support = @import("support.zig");
const stream = @import("stream.zig");
const parallel = @import("parallel.zig");
const speculative = @import("speculative.zig");

const Session = support.Session;
const Error = support.Error;
const Workload = support.Workload;

/// The bench's own arguments, read by ensign.
const Arguments = struct {
    smoke: bool = false,
    corpus: ?[]const u8 = null,
    row: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
    pub const spec: ensign.Spec(@This()) = .{ .name = "bench", .options = .{
        .smoke = .{ .help = "Run each row once, untimed" },
        .corpus = .{ .help = "Add the book's corpora, from this directory", .hint = .directory },
        .row = .{ .help = "Run the rows whose names start with this" },
        .prefix = .{ .positional = true, .help = "The same as --row" },
    } };
};

pub fn main(init: std.process.Init) !void {
    const arguments = ensign.parseOrExit(Arguments, init);
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(init.io, &buffer);
    var session: Session = .init(init, &stdout.interface, arguments.smoke, arguments.row orelse arguments.prefix orelse "", arguments.corpus);
    try decode(&session);
    try checksums(&session);
    try compress(&session);
    try setup(&session);
    try stream.rows(&session);
    try parallel.rows(&session);
    try speculative.rows(&session);
    try stdout.interface.flush();
}

const Level = std.compress.flate.Compress.Options;

pub const Decode = struct {
    session: *Session,
    index: usize,
    variant: enum { exact, margin, std },
    arena: std.heap.ArenaAllocator = undefined,
    d: *warp.Decompressor = undefined,
    window: []u8 = &.{},
    streams: []const []const u8 = &.{},
    inputs: []const []const u8 = &.{},
    out: []u8 = &.{},

    pub fn setup(c: *Decode) Error!void {
        c.arena = .init(c.session.gpa);
        errdefer c.arena.deinit();
        const a = c.arena.allocator();
        const wl = c.session.loaded.?[c.index];
        c.inputs = wl.inputs;
        c.streams = c.session.zlib.get(c.index).?;
        c.out = try a.alloc(u8, wl.max + warp.inflate_margin);
        c.d = try a.create(warp.Decompressor);
        c.d.* = .init;
        c.window = try a.alloc(u8, std.compress.flate.max_window_len);
        // One untimed pass, checking the output.
        for (c.streams, c.inputs) |s, in| {
            _ = try c.d.inflate(s, c.out[0..in.len], .{});
            if (!std.mem.eql(u8, c.out[0..in.len], in)) return error.WrongOutput;
        }
    }

    pub fn teardown(c: *Decode) Error!void {
        c.arena.deinit();
    }

    pub fn run(c: *Decode, units: u64) Error!void {
        for (0..units) |_| for (c.streams, c.inputs) |s, in| switch (c.variant) {
            .exact, .margin => {
                const len = if (c.variant == .margin) in.len + warp.inflate_margin else in.len;
                const r = try c.d.inflate(s, c.out[0..len], .{});
                if (r.out_len != in.len) return error.WrongLength;
            },
            .std => {
                var r: Io.Reader = .fixed(s);
                var d: std.compress.flate.Decompress = .init(&r, .zlib, c.window);
                try d.reader.readSliceAll(c.out[0..in.len]);
            },
        };
    }
};

/// Decoding std's zlib streams at level 6: warp with the output exact and with
/// the margin, beside std's decoder.
fn decode(s: *Session) !void {
    if (!s.wants("decode/")) return;
    for (try s.workloads(), 0..) |wl, index| {
        if (!s.wants(try s.name("decode/{s}/", .{wl.name}))) continue;
        _ = try s.streams(index);
        for ([_]struct { []const u8, @FieldType(Decode, "variant") }{ .{ "warp exact", .exact }, .{ "warp margin", .margin }, .{ "std", .std } }) |variant| {
            const ctx = try s.arena.create(Decode);
            ctx.* = .{ .session = s, .index = index, .variant = variant[1] };
            try s.measure(Decode, ctx, support.rowOf(Decode, try s.name("decode/{s}/{s}", .{ wl.name, variant[0] }), "pass"));
        }
    }
}

const Checksum = struct {
    data: []const u8,
    sink: u32 = 0,

    fn runner(comptime hash: fn ([]const u8) u32) *const fn (*Checksum, u64) Error!void {
        return struct {
            fn run(c: *Checksum, units: u64) Error!void {
                for (0..units) |_| {
                    // A barrier, so no call is hoisted out of the loop as invariant.
                    asm volatile (""
                        :
                        : [data] "r" (c.data.ptr),
                        : .{ .memory = true });
                    c.sink +%= hash(c.data);
                }
                std.mem.doNotOptimizeAway(c.sink);
            }
        }.run;
    }
};

const Algorithm = struct {
    name: []const u8,
    runs: [2]*const fn (*Checksum, u64) Error!void,
};

const algorithms = [_]Algorithm{
    .{ .name = "crc32", .runs = .{ Checksum.runner(warp.Crc32.hash), Checksum.runner(std.hash.Crc32.hash) } },
    .{ .name = "crc32c", .runs = .{ Checksum.runner(warp.Crc32c.hash), Checksum.runner(std.hash.crc.@"CRC-32/ISCSI".hash) } },
    .{ .name = "adler32", .runs = .{ Checksum.runner(warp.Adler32.hash), Checksum.runner(std.hash.Adler32.hash) } },
};

/// CRC-32, CRC-32C and Adler-32 per call at four sizes and three alignments,
/// beside std.
fn checksums(s: *Session) !void {
    const sizes = [_]struct { usize, []const u8 }{ .{ 64, "64 B" }, .{ 1024, "1 KiB" }, .{ 64 << 10, "64 KiB" }, .{ 64 << 20, "64 MiB" } };
    const big_len: usize = if (s.options.smoke) 70 << 10 else 64 << 20;
    var big: ?[]u8 = null;
    for (algorithms) |algorithm| {
        if (!s.wants(try s.name("{s}/", .{algorithm.name}))) continue;
        if (big == null) big = try gen.alloc(s.arena, .noise, 3, big_len + 8);
        for (sizes) |size| {
            if (size[0] > big_len) continue;
            for ([_]usize{ 0, 1, 7 }) |alignment| {
                for (algorithm.runs, [_][]const u8{ "warp", "std" }) |run, who| {
                    const ctx = try s.arena.create(Checksum);
                    ctx.* = .{ .data = big.?[alignment..][0..size[0]] };
                    try s.measure(Checksum, ctx, .{
                        .name = try s.name("{s}/{s}/align {d}/{s}", .{ algorithm.name, size[1], alignment, who }),
                        .unit = "call",
                        .run = run,
                    });
                }
            }
        }
    }
}

/// Compression, warp at its own levels or std's at the nearest.
pub const Compress = struct {
    session: *Session,
    index: usize,
    level: u4,
    std_level: Level,
    use_std: bool,
    arena: std.heap.ArenaAllocator = undefined,
    c: *warp.Compressor = undefined,
    window: []u8 = &.{},
    out: []u8 = &.{},
    inputs: []const []const u8 = &.{},

    pub fn setup(c: *Compress) Error!void {
        c.arena = .init(c.session.gpa);
        errdefer c.arena.deinit();
        const a = c.arena.allocator();
        const wl = c.session.loaded.?[c.index];
        c.inputs = wl.inputs;
        c.window = try a.alloc(u8, std.compress.flate.max_window_len);
        c.out = try a.alloc(u8, warp.Compressor.bound(wl.max, .{}));
        c.c = try a.create(warp.Compressor);
        c.c.* = try .init(a, .{ .level = c.level });
    }

    pub fn teardown(c: *Compress) Error!void {
        c.c.deinit();
        c.arena.deinit();
    }

    pub fn run(c: *Compress, units: u64) Error!void {
        var total: u64 = 0;
        for (0..units) |_| for (c.inputs) |in| {
            if (c.use_std) {
                var w: Io.Writer = .fixed(c.out);
                var s = try std.compress.flate.Compress.init(&w, c.window, .zlib, c.std_level);
                try s.writer.writeAll(in);
                try s.finish();
                total += w.buffered().len;
            } else total += try c.c.compress(in, c.out, .{});
        };
        std.mem.doNotOptimizeAway(total);
    }
};

/// Compression at levels 1, 6, 9 and warp's 10 to 12 (std has no more than
/// its own 9): input per pass, with the output's share of the input left to
/// `check-sizes`.
fn compress(s: *Session) !void {
    if (!s.wants("compress/")) return;
    const levels = [_]struct { u4, Level }{ .{ 1, .level_1 }, .{ 6, .level_6 }, .{ 9, .level_9 }, .{ 10, .level_9 }, .{ 11, .level_9 }, .{ 12, .level_9 } };
    for (try s.workloads(), 0..) |wl, index| {
        if (!s.wants(try s.name("compress/{s}/", .{wl.name}))) continue;
        for (levels) |level| for ([_]bool{ false, true }) |use_std| {
            // std stops at 9: its rows past that would measure the same code again.
            if (use_std and level[0] > 9) continue;
            const ctx = try s.arena.create(Compress);
            ctx.* = .{ .session = s, .index = index, .level = level[0], .std_level = level[1], .use_std = use_std };
            try s.measure(Compress, ctx, support.rowOf(Compress, try s.name("compress/{s}/level {d}/{s}", .{ wl.name, level[0], if (use_std) "std" else "warp" }), "pass"));
        };
    }
}

const inputs = [_][]const u8{ "", "blob 28\x00tiny file for the setup case\n" };

/// The cost of one tiny stream: decoding it beside std, compressing it
/// beside std, which sets up a whole window per stream.
pub const Setup = struct {
    session: *Session,
    mode: enum { warp_decode, std_decode, warp_compress, std_compress },
    level: u4,
    std_level: Level,
    input: []const u8,
    arena: std.heap.ArenaAllocator = undefined,
    d: *warp.Decompressor = undefined,
    c: *warp.Compressor = undefined,
    window: []u8 = &.{},
    stream: []const u8 = &.{},
    out: [128]u8 = undefined,

    pub fn setup(c: *Setup) Error!void {
        c.arena = .init(c.session.gpa);
        errdefer c.arena.deinit();
        const a = c.arena.allocator();
        c.d = try a.create(warp.Decompressor);
        c.d.* = .init;
        c.window = try a.alloc(u8, std.compress.flate.max_window_len);
        c.c = try a.create(warp.Compressor);
        c.c.* = try .init(a, .{ .level = c.level });
        var w: Io.Writer = .fixed(&c.out);
        var s = try std.compress.flate.Compress.init(&w, c.window, .zlib, .level_6);
        try s.writer.writeAll(c.input);
        try s.finish();
        c.stream = try a.dupe(u8, w.buffered());
    }

    pub fn teardown(c: *Setup) Error!void {
        c.c.deinit();
        c.arena.deinit();
    }

    pub fn run(c: *Setup, units: u64) Error!void {
        for (0..units) |_| switch (c.mode) {
            .warp_decode => std.mem.doNotOptimizeAway(try c.d.inflate(c.stream, c.out[0..c.input.len], .{})),
            .std_decode => {
                var r: Io.Reader = .fixed(c.stream);
                var d: std.compress.flate.Decompress = .init(&r, .zlib, c.window);
                try d.reader.readSliceAll(c.out[0..c.input.len]);
            },
            .warp_compress => std.mem.doNotOptimizeAway(try c.c.compress(c.input, &c.out, .{})),
            .std_compress => {
                var w: Io.Writer = .fixed(&c.out);
                var s = try std.compress.flate.Compress.init(&w, c.window, .zlib, c.std_level);
                try s.writer.writeAll(c.input);
                try s.finish();
                std.mem.doNotOptimizeAway(w.buffered().len);
            },
        };
    }
};

fn setup(s: *Session) !void {
    if (!s.wants("setup/")) return;
    for (inputs) |in| {
        for ([_]struct { []const u8, @FieldType(Setup, "mode") }{ .{ "warp", .warp_decode }, .{ "std", .std_decode } }) |who| {
            const ctx = try s.arena.create(Setup);
            ctx.* = .{ .session = s, .mode = who[1], .level = 1, .std_level = .level_6, .input = in };
            try s.measure(Setup, ctx, support.rowOf(Setup, try s.name("setup/decode/{d} B/{s}", .{ in.len, who[0] }), "stream"));
        }
    }
    const levels = [_]struct { u4, Level }{ .{ 1, .level_1 }, .{ 6, .level_6 }, .{ 12, .level_9 } };
    for (levels) |level| for (inputs) |in| {
        for ([_]struct { []const u8, @FieldType(Setup, "mode") }{ .{ "warp", .warp_compress }, .{ "std", .std_compress } }) |who| {
            const ctx = try s.arena.create(Setup);
            ctx.* = .{ .session = s, .mode = who[1], .level = level[0], .std_level = level[1], .input = in };
            try s.measure(Setup, ctx, support.rowOf(Setup, try s.name("setup/compress/level {d}/{d} B/{s}", .{ level[0], in.len, who[0] }), "stream"));
        }
    };
}
