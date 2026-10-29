//! .xz decoding and encoding throughput, measured through shakedown, over
//! the liblzma 5.8.4 streams the differential corpus holds:
//! `xz/<input>/<params>/decode` whole-buffer, `xz-stream/...` the same
//! through the resumable decoder in 64 KiB pieces, and
//! `xz-parallel/.../<k> workers/decode` by worker count, up to the CPUs the
//! machine has (multi-block streams). Encoding, of each input once:
//! `xz/<input>/-<preset>/encode` whole-buffer, `xz-stream/...` through the
//! resumable encoder in 64 KiB pieces, `xz-parallel/.../<k> workers/encode`
//! (blocks of three dictionaries). liblzma, 7-Zip, Go and Rust are timed on
//! the same streams and inputs in trials (warp/xz).
//!
//!   xz-bench [--smoke] [--row <prefix>] [--file <stream>]
//!
//! `--file` measures one stream in place of the corpus's.
const std = @import("std");
const Io = std.Io;
const ensign = @import("ensign");
const warp = @import("warp");
const support = @import("support.zig");

const xz = warp.xz;
const Session = support.Session;
const Error = support.Error || xz.Decompressor.Error || xz.Decompress.Error || xz.parallel.Decompressor.InitError || xz.Compressor.Error || xz.Compress.Error || xz.parallel.Compressor.Error;

/// The presets the encode rows run: liblzma's fast and normal ends, its
/// default, its largest, and its default with `-e`.
const presets = [_]struct { name: []const u8, level: u4, extreme: bool }{
    .{ .name = "-0", .level = 0, .extreme = false },
    .{ .name = "-1", .level = 1, .extreme = false },
    .{ .name = "-6", .level = 6, .extreme = false },
    .{ .name = "-9", .level = 9, .extreme = false },
    .{ .name = "-6e", .level = 6, .extreme = true },
};

const corpus = @embedFile("xz-streams.corpus");

const Arguments = struct {
    smoke: bool = false,
    row: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
    file: ?[]const u8 = null,
    pub const spec: ensign.Spec(@This()) = .{ .name = "xz-bench", .options = .{
        .smoke = .{ .help = "Run each row once, untimed" },
        .row = .{ .help = "Run the rows whose names start with this" },
        .prefix = .{ .positional = true, .help = "The same as --row" },
        .file = .{ .help = "Measure this stream in place of the corpus's", .hint = .file },
    } };
};

/// A stream of the corpus: its fields, as capture wrote them.
const Record = struct { producer: []const u8, format: []const u8, params: []const u8, input: []const u8, stream: []const u8 };

fn records(a: std.mem.Allocator) ![]const Record {
    const body = corpus[(std.mem.find(u8, corpus, "\n\n") orelse return error.BadCorpus) + 2 ..];
    var list: std.ArrayList(Record) = .empty;
    var at: usize = 0;
    while (at < body.len) {
        var fields: [6][]const u8 = undefined;
        for (&fields) |*f| {
            const len = std.mem.readInt(u32, body[at..][0..4], .little);
            f.* = body[at + 4 ..][0..len];
            at += 4 + len;
        }
        try list.append(a, .{ .producer = fields[0], .format = fields[1], .params = fields[2], .input = fields[3], .stream = fields[4] });
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
        // The .xz records of 100 kB or more.
        if (!std.mem.eql(u8, r.format, "xz") or specLen(r.input) < 100_000) continue;
        try streams.append(a, .{ .name = try a.print("{s}/{s}", .{ r.input, r.params }), .stream = r.stream });
    }
    try encodeRows(&session, a, arguments.file != null);
    for (streams.items) |s| for ([_]Kind{ .whole, .pieces, .parallel }) |kind| {
        const counts: []const u16 = if (kind == .parallel) &.{ 2, 4, 8, 16 } else &.{1};
        for (counts) |k| {
            if (k > session.cpus) continue;
            const name = switch (kind) {
                .whole => try session.name("xz/{s}/decode", .{s.name}),
                .pieces => try session.name("xz-stream/{s}/decode", .{s.name}),
                .parallel => try session.name("xz-parallel/{s}/{d} workers/decode", .{ s.name, k }),
            };
            if (!session.wants(name)) continue;
            const ctx = try a.create(Decode);
            ctx.* = .{ .session = &session, .stream = s.stream, .kind = kind, .workers = k };
            try session.measure(Decode, ctx, support.rowOf(Decode, name, "pass"));
        }
    };
    try stdout.interface.flush();
}

/// The encode rows: each corpus input of 100 kB or more, once, at each
/// preset, whole, in pieces and by workers.
fn encodeRows(session: *Session, a: std.mem.Allocator, file: bool) !void {
    if (file) return;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (try records(a)) |r| {
        if (!std.mem.eql(u8, r.format, "xz") or specLen(r.input) < 100_000) continue;
        if ((try seen.getOrPut(a, r.input)).found_existing) continue;
        // A smoke run checks the rows on one input's first 64 KiB.
        if (session.options.smoke and seen.count() > 1) break;
        for (presets) |p| for ([_]Kind{ .whole, .pieces, .parallel }) |kind| {
            const counts: []const u16 = if (kind == .parallel) &.{ 2, 4, 8, 16 } else &.{1};
            for (counts) |k| {
                if (k > session.cpus) continue;
                const name = switch (kind) {
                    .whole => try session.name("xz/{s}/{s}/encode", .{ r.input, p.name }),
                    .pieces => try session.name("xz-stream/{s}/{s}/encode", .{ r.input, p.name }),
                    .parallel => try session.name("xz-parallel/{s}/{s}/{d} workers/encode", .{ r.input, p.name, k }),
                };
                if (!session.wants(name)) continue;
                const ctx = try a.create(Encode);
                ctx.* = .{ .session = session, .stream = r.stream, .kind = kind, .workers = k, .options = .{ .lzma = .preset(p.level, p.extreme) } };
                try session.measure(Encode, ctx, support.rowOf(Encode, name, "pass"));
            }
        };
    }
}

/// One input encoded whole, through the resumable encoder in pieces, or by
/// workers; the input is a corpus stream's output.
pub const Encode = struct {
    session: *Session,
    stream: []const u8,
    kind: Kind,
    workers: u16,
    options: xz.Compressor.Options,
    arena: std.heap.ArenaAllocator = undefined,
    in: []u8 = &.{},
    out: []u8 = &.{},
    c: xz.Compressor = undefined,
    s: xz.Compress = undefined,
    p: xz.parallel.Compressor = undefined,

    pub fn setup(c: *Encode) Error!void {
        c.arena = .init(c.session.gpa);
        errdefer c.arena.deinit();
        const a = c.arena.allocator();
        var d: xz.Decompressor = .init;
        var cap: usize = 1 << 20;
        while (true) : (cap *= 4) {
            c.in = try a.alloc(u8, cap);
            const r = d.decompress(c.stream, c.in, .{}) catch |err| switch (err) {
                error.OutputTooSmall => continue,
                else => return err,
            };
            c.in = c.in[0..r.out_len];
            break;
        }
        if (c.session.options.smoke) c.in = c.in[0..@min(c.in.len, 64 << 10)];
        c.options.max_input = .fromRaw(c.in.len);
        switch (c.kind) {
            .whole => c.c = try .init(a, c.options),
            .pieces => c.s = try .init(a, .{ .lzma = c.options.lzma, .check = c.options.check }),
            .parallel => c.p = try .init(a, .{ .concurrency = c.workers, .xz = c.options }),
        }
        c.out = try a.alloc(u8, xz.parallel.Compressor.bound(.{ .xz = c.options }, c.in.len) + xz.Compressor.bound(c.options, c.in.len));
        const n = try c.encode();
        const back = try a.alloc(u8, c.in.len);
        const r = try d.decompress(c.out[0..n], back, .{});
        if (r.out_len != c.in.len or !std.mem.eql(u8, back, c.in)) return error.WrongOutput;
    }

    fn encode(c: *Encode) Error!usize {
        switch (c.kind) {
            .whole => return c.c.compress(c.in, c.out),
            .parallel => return c.p.compress(c.session.io, c.in, c.out),
            .pieces => {
                var ip: usize = 0;
                var op: usize = 0;
                while (ip < c.in.len) {
                    const step = try c.s.write(c.in[ip..@min(c.in.len, ip + 65536)], c.out[op..]);
                    ip += step.in_len;
                    op += step.out_len;
                }
                while (true) {
                    const d = try c.s.finish(c.out[op..]);
                    op += d.out_len;
                    if (d.done) break;
                }
                c.s.reset();
                return op;
            },
        }
    }

    pub fn teardown(c: *Encode) Error!void {
        if (c.kind == .pieces) c.s.deinit();
        if (c.kind == .parallel) c.p.deinit();
        if (c.kind == .whole) c.c.deinit();
        c.arena.deinit();
    }

    pub fn run(c: *Encode, units: u64) Error!void {
        for (0..units) |_| std.mem.doNotOptimizeAway(try c.encode());
    }
};

/// One stream decoded whole, through the resumable decoder in pieces, or by
/// workers.
pub const Decode = struct {
    session: *Session,
    stream: []const u8,
    kind: Kind,
    workers: u16,
    arena: std.heap.ArenaAllocator = undefined,
    d: xz.Decompressor = .init,
    p: xz.parallel.Decompressor = undefined,
    window: []u8 = &.{},
    out: []u8 = &.{},
    expect: []u8 = &.{},

    pub fn setup(c: *Decode) Error!void {
        c.arena = .init(c.session.gpa);
        errdefer c.arena.deinit();
        const a = c.arena.allocator();
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
            .pieces => c.window = try a.alloc(u8, xz.Decompress.windowLength(64 << 20)),
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
                var z: xz.Decompress = .init(c.window, .{});
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
                        // The window is the stream's whole dictionary.
                        .need_window => return z.refuseWindow(),
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
