//! Snappy and S2 block throughput and setup on generated or caller-provided
//! inputs, measured through shakedown: `snappy/<input>/<format> <level>/
//! encode` and `.../decode` for each parser in each format it writes,
//! `snappy-dict/<input>/<level>/...` for S2's parsers over a dictionary of
//! the same kind of input, and `snappy-setup/...` for a tiny block. One row
//! each. google/snappy and klauspost/compress s2 are timed on the same
//! inputs in trials (warp/snappy).
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
    try setup(&session);
    try stdout.interface.flush();
}

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
