//! LZ4 throughput and setup on generated or caller-provided inputs,
//! measured through shakedown: `lz4/workload/level N/encode` and
//! `.../decode` for blocks, `lz4-frame/...` for frames at the `lz4`
//! command's defaults, `lz4-stream/...` through `Compress` and `Decompress`,
//! and `lz4-setup/...` for a tiny block. One row each.
//!
//!   lz4-bench [--smoke] [--row <prefix>] [--file <path>] [--levels <list>]
const std = @import("std");
const Io = std.Io;
const ensign = @import("ensign");
const warp = @import("warp");
const gen = @import("gen");
const support = @import("support.zig");

const lz4 = warp.lz4;
const Session = support.Session;
const Error = support.Error;

const Arguments = struct {
    smoke: bool = false,
    row: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
    file: ?[]const u8 = null,
    levels: []const u8 = "-8,1,2,3,6,9,10,12",
    pub const spec: ensign.Spec(@This()) = .{ .name = "lz4-bench", .options = .{
        .smoke = .{ .help = "Run each row once, untimed" },
        .row = .{ .help = "Run the rows whose names start with this" },
        .prefix = .{ .positional = true, .help = "The same as --row" },
        .file = .{ .help = "Measure this file in place of the generated inputs", .hint = .file },
        .levels = .{ .help = "The levels, separated by commas" },
    } };
};

const Kind = enum { block, frame, stream };

pub fn main(init: std.process.Init) !void {
    const arguments = ensign.parseOrExit(Arguments, init);
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(init.io, &buffer);
    var session: Session = .init(init, &stdout.interface, arguments.smoke, arguments.row orelse arguments.prefix orelse "", null);
    const a = session.arena;

    var inputs: std.ArrayList(struct { []const u8, []const u8 }) = .empty;
    if (arguments.file) |path| {
        try inputs.append(a, .{ path, try Io.Dir.cwd().readFileAlloc(init.io, path, a, .unlimited) });
    } else {
        const len: usize = if (arguments.smoke) 20_000 else 4 << 20;
        for ([_]gen.Kind{ .text, .binary, .json, .noise, .runs, .png }) |kind| {
            try inputs.append(a, .{ @tagName(kind), try gen.alloc(a, kind, 4, len) });
        }
    }
    var levels: std.ArrayList(i32) = .empty;
    var it = std.mem.splitScalar(u8, arguments.levels, ',');
    while (it.next()) |text| try levels.append(a, try std.fmt.parseInt(i32, text, 10));

    for (std.enums.values(Kind)) |kind| for (inputs.items) |input| for (levels.items) |level| for ([_]bool{ true, false }) |encode| {
        const family = switch (kind) {
            .block => "lz4",
            .frame => "lz4-frame",
            .stream => "lz4-stream",
        };
        const name = try session.name("{s}/{s}/level {d}/{s}", .{ family, input[0], level, if (encode) "encode" else "decode" });
        if (!session.wants(name)) continue;
        const ctx = try a.create(Whole);
        ctx.* = .{ .session = &session, .kind = kind, .input = input[1], .level = level, .encode = encode };
        try session.measure(Whole, ctx, support.rowOf(Whole, name, "pass"));
    };
    try setup(&session);
    try stdout.interface.flush();
}

/// One block, frame or stream of the input, compressed or decompressed.
pub const Whole = struct {
    session: *Session,
    kind: Kind,
    input: []const u8,
    level: i32,
    encode: bool,
    arena: std.heap.ArenaAllocator = undefined,
    c: lz4.Compressor = undefined,
    out: []u8 = &.{},
    back: []u8 = &.{},
    window: []u8 = &.{},
    n: usize = 0,

    pub fn setup(c: *Whole) Error!void {
        c.arena = .init(c.session.gpa);
        errdefer c.arena.deinit();
        const a = c.arena.allocator();
        c.out = try a.alloc(u8, lz4.Compressor.bound(c.input.len, .{}) + lz4.blockBound(c.input.len));
        c.back = try a.alloc(u8, c.input.len + lz4.decompress_margin);
        c.window = try a.alloc(u8, lz4.Decompress.memory(.literal("4MiB")));
        c.c = try .init(c.session.gpa, .{ .level = c.level });
        errdefer c.c.deinit();
        c.n = try c.compress();
        const r = try c.decompress();
        if (r != c.input.len or !std.mem.eql(u8, c.input, c.back[0..r])) return error.WrongOutput;
    }

    fn compress(c: *Whole) Error!usize {
        return switch (c.kind) {
            .block => c.c.compressBlock(c.input, c.out, .{}),
            .frame => c.c.compress(c.input, c.out, .{}),
            .stream => blk: {
                var s: lz4.Compress = try .init(c.arena.allocator(), .{ .compressor = .{ .level = c.level } });
                defer s.deinit();
                const w = try s.write(c.input, c.out);
                const f = try s.finish(c.out[w.out_len..]);
                break :blk w.out_len + f.out_len;
            },
        };
    }

    fn decompress(c: *Whole) Error!usize {
        switch (c.kind) {
            .block => return (try lz4.decompressBlock(c.out[0..c.n], c.back, .{})).out_len,
            .frame => return (try lz4.decompress(c.out[0..c.n], c.back, .{})).out_len,
            .stream => {
                var d: lz4.Decompress = .init(c.window, .{});
                var op: usize = 0;
                var ip: usize = 0;
                while (true) {
                    const step = try d.decode(c.out[ip..c.n], c.back[op..]);
                    ip += step.in_len;
                    op += step.out_len;
                    if (step.status != .output_full) break;
                }
                try d.finish();
                return op;
            },
        }
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

/// The cost of one tiny block, encoded or decoded.
pub const Tiny = struct {
    session: *Session,
    level: i32,
    input: []const u8,
    encode: bool,
    c: lz4.Compressor = undefined,
    out: [128]u8 = undefined,
    back: [128]u8 = undefined,
    n: usize = 0,

    pub fn setup(c: *Tiny) Error!void {
        c.c = try .init(c.session.gpa, .{ .level = c.level });
        errdefer c.c.deinit();
        c.n = try c.c.compressBlock(c.input, &c.out, .{});
    }

    pub fn teardown(c: *Tiny) Error!void {
        c.c.deinit();
    }

    pub fn run(c: *Tiny, units: u64) Error!void {
        for (0..units) |_| {
            if (c.encode) {
                std.mem.doNotOptimizeAway(try c.c.compressBlock(c.input, &c.out, .{}));
            } else std.mem.doNotOptimizeAway(try lz4.decompressBlock(c.out[0..c.n], c.back[0..c.input.len], .{}));
        }
    }
};

fn setup(s: *Session) !void {
    if (!s.wants("lz4-setup/")) return;
    for ([_]i32{ 1, 2, 9, 12 }) |level| for ([_][]const u8{ "", "blob 28\x00tiny file for the setup case\n" }) |input| for ([_]bool{ true, false }) |encode| {
        const ctx = try s.arena.create(Tiny);
        ctx.* = .{ .session = s, .level = level, .input = input, .encode = encode };
        try s.measure(Tiny, ctx, support.rowOf(Tiny, try s.name("lz4-setup/level {d}/{d} B/{s}", .{ level, input.len, if (encode) "encode" else "decode" }), "block"));
    };
}
