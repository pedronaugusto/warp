//! GDeflate throughput on generated or caller-provided inputs, measured
//! through shakedown: `gdeflate/workload/level N/encode` and `.../decode`
//! for tile streams (a page a 64 KiB tile, one thread), and
//! `gdeflate-page/...` for one page. One row each. Microsoft's reference
//! is timed on the same inputs in trials (warp/gdeflate).
//!
//!   gdeflate-bench [--smoke] [--row <prefix>] [--file <path>] [--levels <list>]
const std = @import("std");
const Io = std.Io;
const ensign = @import("ensign");
const warp = @import("warp");
const gen = @import("gen");
const support = @import("support.zig");

const gdeflate = warp.gdeflate;
const Session = support.Session;
const Error = support.Error;

const Arguments = struct {
    smoke: bool = false,
    row: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
    file: ?[]const u8 = null,
    levels: []const u8 = "1,6,9,12",
    pub const spec: ensign.Spec(@This()) = .{ .name = "gdeflate-bench", .options = .{
        .smoke = .{ .help = "Run each row once, untimed" },
        .row = .{ .help = "Run the rows whose names start with this" },
        .prefix = .{ .positional = true, .help = "The same as --row" },
        .file = .{ .help = "Measure this file in place of the generated inputs", .hint = .file },
        .levels = .{ .help = "The levels, separated by commas" },
    } };
};

const Kind = enum { stream, page };

pub fn main(init: std.process.Init) !void {
    const arguments = ensign.parseOrExit(Arguments, init);
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(init.io, &buffer);
    var session: Session = .init(init, &stdout.interface, arguments.smoke, arguments.row orelse arguments.prefix orelse "", null);
    const a = session.arena;

    var inputs: std.ArrayList(struct { []const u8, []const u8 }) = .empty;
    if (arguments.file) |path| {
        try inputs.append(a, .{ path, try support.readFile(init.io, a, path) });
    } else {
        const len: usize = if (arguments.smoke) 20_000 else 4 << 20;
        for ([_]gen.Kind{ .text, .binary, .json, .noise, .runs, .png }) |kind| {
            try inputs.append(a, .{ @tagName(kind), try gen.alloc(a, kind, 4, len) });
        }
    }
    var levels: std.ArrayList(u4) = .empty;
    var it = std.mem.splitScalar(u8, arguments.levels, ',');
    while (it.next()) |text| try levels.append(a, try std.fmt.parseInt(u4, text, 10));

    for (std.enums.values(Kind)) |kind| for (inputs.items) |input| for (levels.items) |level| for ([_]bool{ true, false }) |encode| {
        const family = switch (kind) {
            .stream => "gdeflate",
            .page => "gdeflate-page",
        };
        const name = try session.name("{s}/{s}/level {d}/{s}", .{ family, input[0], level, if (encode) "encode" else "decode" });
        if (!session.wants(name)) continue;
        const ctx = try a.create(Whole);
        // A page is the input's first tile.
        const bytes = if (kind == .page) input[1][0..@min(input[1].len, gdeflate.tile_size)] else input[1];
        ctx.* = .{ .session = &session, .kind = kind, .input = bytes, .level = level, .encode = encode };
        try session.measure(Whole, ctx, support.rowOf(Whole, name, "pass"));
    };
    try stdout.interface.flush();
}

/// One tile stream or page of the input, compressed or decompressed.
pub const Whole = struct {
    session: *Session,
    kind: Kind,
    input: []const u8,
    level: u4,
    encode: bool,
    arena: std.heap.ArenaAllocator = undefined,
    c: gdeflate.Compressor = undefined,
    d: gdeflate.Decompressor = .init,
    out: []u8 = &.{},
    back: []u8 = &.{},
    n: usize = 0,

    pub fn setup(c: *Whole) Error!void {
        c.arena = .init(c.session.gpa);
        errdefer c.arena.deinit();
        const a = c.arena.allocator();
        c.out = try a.alloc(u8, gdeflate.bound(c.input.len));
        c.back = try a.alloc(u8, c.input.len);
        c.c = try .init(c.session.gpa, .{ .level = c.level });
        errdefer c.c.deinit();
        c.n = try c.compress();
        const r = try c.decompress();
        if (r != c.input.len or !std.mem.eql(u8, c.input, c.back[0..r])) return error.WrongOutput;
    }

    fn compress(c: *Whole) Error!usize {
        return switch (c.kind) {
            .stream => c.c.compress(c.input, c.out),
            .page => c.c.compressPage(c.input, c.out),
        };
    }

    fn decompress(c: *Whole) Error!usize {
        return switch (c.kind) {
            .stream => c.d.decompress(c.out[0..c.n], c.back, .{}),
            .page => c.d.decompressPage(c.out[0..c.n], c.back, .{}),
        };
    }

    pub fn teardown(c: *Whole) Error!void {
        c.c.deinit();
        c.arena.deinit();
    }

    pub fn run(c: *Whole, units: u64) Error!void {
        for (0..units) |_| {
            if (c.encode) std.mem.doNotOptimizeAway(try c.compress()) else std.mem.doNotOptimizeAway(try c.decompress());
        }
    }
};
