//! Brotli decoding throughput and setup, measured through shakedown, over
//! the streams the differential corpus holds (warp writes none of its own
//! yet): `brotli/<input>/q<quality> w<window>/decode` whole-buffer,
//! `brotli-stream/...` the same through the resumable decoder in 64 KiB
//! pieces, and `brotli-setup/q<quality>/<n> B/decode` the cost of a tiny
//! stream.
//!
//!   brotli-bench [--smoke] [--row <prefix>] [--file <stream>]
//!
//! `--file` measures one stream in place of the corpus's.
const std = @import("std");
const Io = std.Io;
const ensign = @import("ensign");
const warp = @import("warp");
const support = @import("support.zig");

const brotli = warp.brotli;
const Session = support.Session;
const Error = support.Error;

const corpus = @embedFile("brotli-streams.corpus");

const Arguments = struct {
    smoke: bool = false,
    row: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
    file: ?[]const u8 = null,
    pub const spec: ensign.Spec(@This()) = .{ .name = "brotli-bench", .options = .{
        .smoke = .{ .help = "Run each row once, untimed" },
        .row = .{ .help = "Run the rows whose names start with this" },
        .prefix = .{ .positional = true, .help = "The same as --row" },
        .file = .{ .help = "Measure this stream in place of the corpus's", .hint = .file },
    } };
};

/// A stream of the corpus: its fields, as capture wrote them.
const Record = struct { params: []const u8, input: []const u8, dictionary: []const u8, stream: []const u8 };

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
        try list.append(a, .{ .params = fields[1], .input = fields[2], .dictionary = fields[3], .stream = fields[4] });
    }
    return list.items;
}

/// A parameter's value in a record's params.
fn param(params: []const u8, comptime key: []const u8) []const u8 {
    const at = (std.mem.find(u8, params, key ++ "=") orelse return "") + key.len + 1;
    const end = std.mem.findScalarPos(u8, params, at, ' ') orelse params.len;
    return params[at..end];
}

/// The length a generator spec names: its last field.
fn specLen(spec_text: []const u8) usize {
    const at = std.mem.findScalarLast(u8, spec_text, ' ') orelse return 0;
    return std.fmt.parseInt(usize, spec_text[at + 1 ..], 10) catch 0;
}

pub fn main(init: std.process.Init) !void {
    const arguments = ensign.parseOrExit(Arguments, init);
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(init.io, &buffer);
    var session: Session = .init(init, &stdout.interface, arguments.smoke, arguments.row orelse arguments.prefix orelse "", null);
    const a = session.arena;

    if (arguments.file) |path| {
        const stream = try Io.Dir.cwd().readFileAlloc(init.io, path, a, .unlimited);
        for ([_]bool{ false, true }) |pieces| {
            const ctx = try a.create(Whole);
            ctx.* = .{ .session = &session, .stream = stream, .pieces = pieces };
            try session.measure(Whole, ctx, support.rowOf(Whole, try session.name("{s}/{s}/decode", .{ if (pieces) "brotli-stream" else "brotli", path }), "pass"));
        }
        try stdout.interface.flush();
        return;
    }
    for (try records(a)) |r| {
        if (r.dictionary.len != 0 or std.mem.eql(u8, param(r.params, "large_window"), "true")) continue;
        if (!std.mem.eql(u8, param(r.params, "flush_every"), "0") or !std.mem.eql(u8, param(r.params, "metadata"), "0")) continue;
        const len = specLen(r.input);
        if (len >= 20_000) {
            for ([_]bool{ false, true }) |pieces| {
                const ctx = try a.create(Whole);
                ctx.* = .{ .session = &session, .stream = r.stream, .pieces = pieces };
                try session.measure(Whole, ctx, support.rowOf(Whole, try session.name("{s}/{s}/q{s} w{s} {s}/decode", .{ if (pieces) "brotli-stream" else "brotli", r.input, param(r.params, "quality"), param(r.params, "window"), param(r.params, "mode") }), "pass"));
            }
        } else if (len <= 37 and std.mem.startsWith(u8, r.input, "text")) {
            const ctx = try a.create(Whole);
            ctx.* = .{ .session = &session, .stream = r.stream, .pieces = false };
            try session.measure(Whole, ctx, support.rowOf(Whole, try session.name("brotli-setup/q{s}/{d} B/decode", .{ param(r.params, "quality"), len }), "stream"));
        }
    }
    try stdout.interface.flush();
}

/// One stream decoded whole, or through the resumable decoder in pieces.
pub const Whole = struct {
    session: *Session,
    stream: []const u8,
    pieces: bool,
    arena: std.heap.ArenaAllocator = undefined,
    d: *brotli.Decompressor = undefined,
    z: *brotli.Decompress = undefined,
    window: []u8 = &.{},
    out: []u8 = &.{},

    pub fn setup(c: *Whole) Error!void {
        c.arena = .init(c.session.gpa);
        errdefer c.arena.deinit();
        const a = c.arena.allocator();
        c.d = try a.create(brotli.Decompressor);
        c.d.* = .init;
        c.z = try a.create(brotli.Decompress);
        c.window = try a.alloc(u8, brotli.Decompress.windowLength(24));
        // The stream's length bounds nothing: grow the output until it fits.
        var cap: usize = 4096;
        while (true) : (cap *= 4) {
            c.out = try a.alloc(u8, cap);
            const r = c.d.decompress(c.stream, c.out, .{}) catch |err| switch (err) {
                error.OutputTooSmall => continue,
                else => return err,
            };
            c.out = c.out[0..r.out_len];
            break;
        }
        const n = try c.decode();
        if (n != c.out.len) return error.WrongLength;
    }

    pub fn teardown(c: *Whole) Error!void {
        c.arena.deinit();
    }

    fn decode(c: *Whole) Error!usize {
        if (!c.pieces) return (try c.d.decompress(c.stream, c.out, .{})).out_len;
        c.z.* = .init(c.window, .{});
        var ip: usize = 0;
        var op: usize = 0;
        while (true) {
            const step = try c.z.decode(c.stream[ip..@min(ip + (64 << 10), c.stream.len)], c.out[op..@min(op + (64 << 10), c.out.len)]);
            ip += step.in_len;
            op += step.out_len;
            if (step.status == .stream_end) return op;
        }
    }

    pub fn run(c: *Whole, units: u64) Error!void {
        for (0..units) |_| std.mem.doNotOptimizeAway(try c.decode());
    }
};
