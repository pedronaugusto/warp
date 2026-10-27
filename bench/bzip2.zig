//! bzip2 decoding throughput, measured through shakedown, over the libbz2
//! 1.0.8 streams the differential corpus holds: `bzip2/<input>/level
//! N/decode` whole-buffer, `bzip2-stream/...` the same through the
//! resumable decoder in 64 KiB pieces, and `bzip2-parallel/.../<k>
//! workers/decode` by worker count, up to the CPUs the machine has. libbz2
//! and lbzip2 are timed on the same streams in trials (warp/bzip2).
//!
//!   bzip2-bench [--smoke] [--row <prefix>] [--file <stream>]
//!
//! `--file` measures one stream in place of the corpus's.
const std = @import("std");
const Io = std.Io;
const ensign = @import("ensign");
const warp = @import("warp");
const support = @import("support.zig");

const bzip2 = warp.bzip2;
const Session = support.Session;
const Error = support.Error || bzip2.Decompressor.Error || bzip2.parallel.Decompressor.InitError;

const corpus = @embedFile("bzip2-streams.corpus");

const Arguments = struct {
    smoke: bool = false,
    row: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
    file: ?[]const u8 = null,
    pub const spec: ensign.Spec(@This()) = .{ .name = "bzip2-bench", .options = .{
        .smoke = .{ .help = "Run each row once, untimed" },
        .row = .{ .help = "Run the rows whose names start with this" },
        .prefix = .{ .positional = true, .help = "The same as --row" },
        .file = .{ .help = "Measure this stream in place of the corpus's", .hint = .file },
    } };
};

/// A stream of the corpus: its fields, as capture wrote them.
const Record = struct { producer: []const u8, level: []const u8, input: []const u8, stream: []const u8 };

fn records(a: std.mem.Allocator) ![]const Record {
    const body = corpus[(std.mem.find(u8, corpus, "\n\n") orelse return error.BadCorpus) + 2 ..];
    var list: std.ArrayList(Record) = .empty;
    var at: usize = 0;
    while (at < body.len) {
        var fields: [5][]const u8 = undefined;
        for (&fields) |*f| {
            const len = std.mem.readInt(u32, body[at..][0..4], .little);
            f.* = body[at + 4 ..][0..len];
            at += 4 + len;
        }
        try list.append(a, .{ .producer = fields[0], .level = fields[1], .input = fields[2], .stream = fields[3] });
    }
    return list.items;
}

/// The length a generator spec names: its last field.
fn specLen(spec_text: []const u8) usize {
    const at = std.mem.findScalarLast(u8, spec_text, ' ') orelse return 0;
    return std.fmt.parseInt(usize, spec_text[at + 1 ..], 10) catch 0;
}

const Kind = enum { whole, pieces, parallel };

pub fn main(init: std.process.Init) !void {
    const arguments = ensign.parseOrExit(Arguments, init);
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(init.io, &buffer);
    var session: Session = .init(init, &stdout.interface, arguments.smoke, arguments.row orelse arguments.prefix orelse "", null);
    const a = session.arena;

    var streams: std.ArrayList(struct { name: []const u8, stream: []const u8 }) = .empty;
    if (arguments.file) |path| {
        try streams.append(a, .{ .name = path, .stream = try support.readFile(init.io, a, path) });
    } else for (try records(a)) |r| {
        // The single-stream records of 100 kB or more: a block's worth.
        if (!std.mem.eql(u8, r.producer, "libbz2 1.0.8") or specLen(r.input) < 100_000) continue;
        try streams.append(a, .{ .name = try a.print("{s}/level {s}", .{ r.input, r.level }), .stream = r.stream });
    }
    for (streams.items) |s| for ([_]Kind{ .whole, .pieces, .parallel }) |kind| {
        const counts: []const u16 = if (kind == .parallel) &.{ 2, 4, 8, 16 } else &.{1};
        for (counts) |k| {
            if (k > session.cpus) continue;
            const name = switch (kind) {
                .whole => try session.name("bzip2/{s}/decode", .{s.name}),
                .pieces => try session.name("bzip2-stream/{s}/decode", .{s.name}),
                .parallel => try session.name("bzip2-parallel/{s}/{d} workers/decode", .{ s.name, k }),
            };
            if (!session.wants(name)) continue;
            const ctx = try a.create(Decode);
            ctx.* = .{ .session = &session, .stream = s.stream, .kind = kind, .workers = k };
            try session.measure(Decode, ctx, support.rowOf(Decode, name, "pass"));
        }
    };
    try stdout.interface.flush();
}

/// One stream decoded whole, through the resumable decoder in pieces, or by
/// workers.
pub const Decode = struct {
    session: *Session,
    stream: []const u8,
    kind: Kind,
    workers: u16,
    arena: std.heap.ArenaAllocator = undefined,
    d: bzip2.Decompressor = undefined,
    p: bzip2.parallel.Decompressor = undefined,
    memory: []align(4) u8 = &.{},
    out: []u8 = &.{},
    expect: []u8 = &.{},

    pub fn setup(c: *Decode) Error!void {
        c.arena = .init(c.session.gpa);
        errdefer c.arena.deinit();
        const a = c.arena.allocator();
        c.d = try .init(a);
        // The stream's length bounds nothing: grow the output until it fits.
        var cap: usize = 1 << 20;
        while (true) : (cap *= 4) {
            c.out = try a.alloc(u8, cap);
            const r = c.d.decompress(c.stream, c.out, .{}) catch |err| switch (err) {
                error.OutputTooSmall => continue,
                else => return err,
            };
            c.out = c.out[0..r.out_len];
            break;
        }
        c.expect = try a.dupe(u8, c.out);
        switch (c.kind) {
            .whole => {},
            .pieces => c.memory = try a.alignedAlloc(u8, .@"4", bzip2.Decompress.memory),
            .parallel => c.p = try .init(a, .{ .concurrency = c.workers }),
        }
        const n = try c.decode();
        if (n != c.expect.len or !std.mem.eql(u8, c.expect, c.out[0..n])) return error.WrongOutput;
    }

    fn decode(c: *Decode) Error!usize {
        switch (c.kind) {
            .whole => return (try c.d.decompress(c.stream, c.out, .{})).out_len,
            .parallel => return (try c.p.decompress(c.session.io, c.stream, c.out, .{})).out_len,
            .pieces => {
                var z: bzip2.Decompress = .init(c.memory, .{});
                var ip: usize = 0;
                var op: usize = 0;
                while (true) {
                    const step = try z.decode(c.stream[ip..@min(c.stream.len, ip + 65536)], c.out[op..]);
                    ip += step.in_len;
                    op += step.out_len;
                    switch (step.status) {
                        .done => return op,
                        .output_full => return error.WrongLength,
                        .need_input => if (ip == c.stream.len) {
                            try z.finish();
                            return op;
                        },
                    }
                }
            },
        }
    }

    pub fn teardown(c: *Decode) Error!void {
        c.arena.deinit();
    }

    pub fn run(c: *Decode, units: u64) Error!void {
        for (0..units) |_| std.mem.doNotOptimizeAway(try c.decode());
    }
};
