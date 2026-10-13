//! Whole-buffer zstd throughput and setup on generated or caller-provided
//! inputs, measured through shakedown: `family/workload/level N/encode` and
//! `.../decode`, one row each.
//!
//!   zstd-bench [--smoke] [--row <prefix>] [--file <path>] [--levels <list>]
//!              [--long] [--no-checksum] [--decode-threads <n>] [--parallel <n>]
//!              [--target <bytes>] [--dictionary <path>]
//!
//! With none of the modes the rows are `zstd`, and `zstd-setup`. `--long` is the
//! long-distance matcher (`zstd-long`), `--dictionary` a trained dictionary
//! (`zstd-dict`), `--decode-threads` the pipelined decoder (`zstd-pipeline`),
//! `--parallel` the parallel encoder at that many workers (`zstd-parallel`) and
//! `--target` a target block size (`zstd-target`). `--file` measures one file
//! in place of the generated inputs. The sizes of the compressed output are
//! `check-sizes`' to keep, not a timing's.
const std = @import("std");
const Io = std.Io;
const ensign = @import("ensign");
const warp = @import("warp");
const gen = @import("gen");
const support = @import("support.zig");

const zstd = warp.zstd;
const Session = support.Session;
const Error = support.Error;

const Arguments = struct {
    smoke: bool = false,
    row: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
    file: ?[]const u8 = null,
    levels: []const u8 = "-5,1,3,6,9,19",
    long: bool = false,
    checksum: bool = true,
    decode_threads: u16 = 0,
    parallel: ?u16 = null,
    target: ?u32 = null,
    dictionary: ?[]const u8 = null,
    pub const spec: ensign.Spec(@This()) = .{ .name = "zstd-bench", .options = .{
        .smoke = .{ .help = "Run each row once, untimed" },
        .row = .{ .help = "Run the rows whose names start with this" },
        .prefix = .{ .positional = true, .help = "The same as --row" },
        .file = .{ .help = "Measure this file in place of the generated inputs", .hint = .file },
        .levels = .{ .help = "The levels, separated by commas" },
        .long = .{ .help = "The long-distance matcher" },
        .checksum = .{ .help = "Write the frame's content checksum" },
        .decode_threads = .{ .help = "Decode with the pipelined decoder at this many workers" },
        .parallel = .{ .help = "Encode with the parallel encoder at this many workers" },
        .target = .{ .help = "Encode with this target block size" },
        .dictionary = .{ .help = "Use the dictionary in this file", .hint = .file },
    } };
};

/// What every row of a run shares.
const Setting = struct {
    session: *Session,
    long: bool,
    checksum: bool,
    decode_threads: u16,
    dictionary: ?*const zstd.Dictionary,

    fn dictionaries(setting: Setting) []const *const zstd.Dictionary {
        return if (setting.dictionary) |dict| @as(*const [1]*const zstd.Dictionary, &dict) else &.{};
    }
};

pub fn main(init: std.process.Init) !void {
    const arguments = ensign.parseOrExit(Arguments, init);
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writerStreaming(init.io, &buffer);
    var session: Session = .init(init, &stdout.interface, arguments.smoke, arguments.row orelse arguments.prefix orelse "", null);
    const a = session.arena;
    var dictionary: ?*zstd.Dictionary = null;
    if (arguments.dictionary) |path| {
        dictionary = try a.create(zstd.Dictionary);
        dictionary.?.* = try zstd.Dictionary.parse(try Io.Dir.cwd().readFileAlloc(init.io, path, a, .unlimited));
    }
    const setting: Setting = .{ .session = &session, .long = arguments.long, .checksum = arguments.checksum, .decode_threads = arguments.decode_threads, .dictionary = dictionary };

    var inputs: std.ArrayList(struct { []const u8, []const u8 }) = .empty;
    if (arguments.file) |path| {
        try inputs.append(a, .{ path, try Io.Dir.cwd().readFileAlloc(init.io, path, a, .unlimited) });
    } else {
        const len: usize = if (arguments.smoke) 20_000 else 4 << 20;
        for ([_]gen.Kind{ .text, .binary, .json, .noise, .runs, .png }) |kind| {
            if (!session.wants(try session.name("{s}/{t}/", .{ family(arguments), kind }))) continue;
            try inputs.append(a, .{ @tagName(kind), try gen.alloc(a, kind, 4, len) });
        }
    }
    var levels: std.ArrayList(i32) = .empty;
    var it = std.mem.splitScalar(u8, arguments.levels, ',');
    while (it.next()) |text| try levels.append(a, try std.fmt.parseInt(i32, text, 10));

    for (inputs.items) |input| for (levels.items) |level| {
        if (arguments.target) |target| {
            const ctx = try a.create(Target);
            ctx.* = .{ .setting = setting, .input = input[1], .level = level, .target = target };
            try session.measure(Target, ctx, support.rowOf(Target, try session.name("zstd-target/{s}/level {d}/target {d}", .{ input[0], level, target }), "pass"));
        } else if (arguments.parallel) |workers| {
            const ctx = try a.create(Parallel);
            ctx.* = .{ .setting = setting, .input = input[1], .level = level, .workers = workers };
            try session.measure(Parallel, ctx, support.rowOf(Parallel, try session.name("zstd-parallel/{s}/level {d}/workers {d}", .{ input[0], level, workers }), "pass"));
        } else for ([_]bool{ true, false }) |encode| {
            const ctx = try a.create(Whole);
            ctx.* = .{ .setting = setting, .input = input[1], .level = level, .encode = encode };
            try session.measure(Whole, ctx, support.rowOf(Whole, try session.name("{s}/{s}/level {d}/{s}", .{ family(arguments), input[0], level, if (encode) "encode" else "decode" }), "pass"));
        }
    };
    try setup(&session);
    try stdout.interface.flush();
}

/// The row family the whole-buffer modes are measured as.
fn family(arguments: Arguments) []const u8 {
    if (arguments.target != null) return "zstd-target";
    if (arguments.parallel != null) return "zstd-parallel";
    if (arguments.decode_threads != 0) return "zstd-pipeline";
    if (arguments.dictionary != null) return "zstd-dict";
    if (arguments.long) return "zstd-long";
    return "zstd";
}

fn decodeFrame(io: Io, d: *zstd.Decompressor, pipeline: ?*zstd.parallel.Decompressor, input: []const u8, output: []u8, dictionaries: []const *const zstd.Dictionary) Error!zstd.Decompressor.Result {
    const options: zstd.Decompressor.Options = .{ .max_window = std.math.maxInt(u64), .dictionaries = dictionaries };
    if (pipeline) |p| return p.decompress(io, input, output, options);
    return d.decompress(input, output, options);
}

/// One frame, compressed or decompressed whole.
pub const Whole = struct {
    setting: Setting,
    input: []const u8,
    level: i32,
    encode: bool,
    arena: std.heap.ArenaAllocator = undefined,
    c: zstd.Compressor = undefined,
    d: *zstd.Decompressor = undefined,
    pipeline: ?zstd.parallel.Decompressor = null,
    out: []u8 = &.{},
    back: []u8 = &.{},
    n: usize = 0,

    pub fn setup(c: *Whole) Error!void {
        const s = c.setting;
        c.arena = .init(s.session.gpa);
        errdefer c.arena.deinit();
        const a = c.arena.allocator();
        c.out = try a.alloc(u8, zstd.Compressor.bound(c.input.len));
        c.back = try a.alloc(u8, c.input.len);
        c.d = try a.create(zstd.Decompressor);
        c.d.* = .init;
        if (s.decode_threads != 0) c.pipeline = try .init(s.session.gpa, .{ .concurrency = s.decode_threads });
        errdefer if (c.pipeline) |*p| p.deinit();
        c.c = try .init(s.session.gpa, .{ .level = c.level, .max_input = c.input.len, .tuning = .{ .long_distance = s.long }, .dictionary = s.dictionary });
        errdefer c.c.deinit();
        c.n = try c.c.compress(c.input, c.out, .{ .checksum = s.checksum });
        _ = try c.decode();
        if (!std.mem.eql(u8, c.input, c.back)) return error.WrongOutput;
    }

    fn decode(c: *Whole) Error!zstd.Decompressor.Result {
        const s = c.setting;
        return decodeFrame(s.session.io, c.d, if (c.pipeline) |*p| p else null, c.out[0..c.n], c.back, s.dictionaries());
    }

    pub fn teardown(c: *Whole) Error!void {
        if (c.pipeline) |*p| p.deinit();
        c.pipeline = null;
        c.c.deinit();
        c.arena.deinit();
    }

    pub fn run(c: *Whole, units: u64) Error!void {
        for (0..units) |_| {
            if (c.encode) {
                std.mem.doNotOptimizeAway(try c.c.compress(c.input, c.out, .{ .checksum = c.setting.checksum }));
            } else std.mem.doNotOptimizeAway(try c.decode());
        }
    }
};

/// The parallel encoder: input per pass, the frame decoded once to check it.
pub const Parallel = struct {
    setting: Setting,
    input: []const u8,
    level: i32,
    workers: u16,
    arena: std.heap.ArenaAllocator = undefined,
    p: zstd.parallel.Compressor = undefined,
    out: []u8 = &.{},

    pub fn setup(c: *Parallel) Error!void {
        const s = c.setting;
        c.arena = .init(s.session.gpa);
        errdefer c.arena.deinit();
        const a = c.arena.allocator();
        c.out = try a.alloc(u8, c.input.len + c.input.len / 32 + 4096);
        c.p = try .init(s.session.gpa, c.options());
        errdefer c.p.deinit();
        var sink: Io.Writer = .fixed(c.out);
        try c.p.compress(s.session.io, c.input, &sink);
        const back = try a.alloc(u8, c.input.len);
        const d = try a.create(zstd.Decompressor);
        d.* = .init;
        _ = try d.decompress(sink.buffered(), back, .{ .max_window = std.math.maxInt(u64), .dictionaries = s.dictionaries() });
        if (!std.mem.eql(u8, c.input, back)) return error.WrongOutput;
    }

    fn options(c: *const Parallel) zstd.parallel.Options {
        return .{ .level = c.level, .concurrency = c.workers, .dictionary = c.setting.dictionary, .frame = .{ .checksum = c.setting.checksum } };
    }

    pub fn teardown(c: *Parallel) Error!void {
        c.p.deinit();
        c.arena.deinit();
    }

    pub fn run(c: *Parallel, units: u64) Error!void {
        for (0..units) |_| {
            var sink: Io.Writer = .fixed(c.out);
            try c.p.compress(c.setting.session.io, c.input, &sink);
            std.mem.doNotOptimizeAway(sink.buffered().len);
        }
    }
};

/// The streaming encoder at a target block size, the frame decoded once to
/// check it.
pub const Target = struct {
    setting: Setting,
    input: []const u8,
    level: i32,
    target: u32,
    arena: std.heap.ArenaAllocator = undefined,
    s: zstd.Compress = undefined,
    out: []u8 = &.{},

    pub fn setup(c: *Target) Error!void {
        const s = c.setting;
        c.arena = .init(s.session.gpa);
        errdefer c.arena.deinit();
        const a = c.arena.allocator();
        c.out = try a.alloc(u8, c.input.len + c.input.len / 32 + 4096);
        c.s = try .init(s.session.gpa, .{ .level = c.level, .pledged_size = c.input.len, .dictionary = s.dictionary, .frame = .{ .checksum = s.checksum }, .target_block_size = c.target });
        errdefer c.s.deinit();
        const n = try c.pass();
        const back = try a.alloc(u8, c.input.len);
        const d = try a.create(zstd.Decompressor);
        d.* = .init;
        _ = try d.decompress(c.out[0..n], back, .{ .max_window = std.math.maxInt(u64), .dictionaries = s.dictionaries() });
        if (!std.mem.eql(u8, c.input, back)) return error.WrongOutput;
    }

    fn pass(c: *Target) Error!usize {
        var sink: Io.Writer = .fixed(c.out);
        var adapter: zstd.Compress.Writer = .init(&c.s, &sink, &.{});
        try adapter.interface.writeAll(c.input);
        try adapter.finish();
        c.s.reset();
        return sink.buffered().len;
    }

    pub fn teardown(c: *Target) Error!void {
        c.s.deinit();
        c.arena.deinit();
    }

    pub fn run(c: *Target, units: u64) Error!void {
        for (0..units) |_| std.mem.doNotOptimizeAway(try c.pass());
    }
};

/// The cost of one tiny frame, encoded or decoded.
pub const Frame = struct {
    session: *Session,
    level: i32,
    input: []const u8,
    encode: bool,
    c: zstd.Compressor = undefined,
    d: *zstd.Decompressor = undefined,
    arena: std.heap.ArenaAllocator = undefined,
    out: [128]u8 = undefined,
    back: [128]u8 = undefined,
    n: usize = 0,

    pub fn setup(c: *Frame) Error!void {
        c.arena = .init(c.session.gpa);
        errdefer c.arena.deinit();
        c.d = try c.arena.allocator().create(zstd.Decompressor);
        c.d.* = .init;
        c.c = try .init(c.session.gpa, .{ .level = c.level, .max_input = c.input.len });
        errdefer c.c.deinit();
        c.n = try c.c.compress(c.input, &c.out, .{});
    }

    pub fn teardown(c: *Frame) Error!void {
        c.c.deinit();
        c.arena.deinit();
    }

    pub fn run(c: *Frame, units: u64) Error!void {
        for (0..units) |_| {
            if (c.encode) {
                std.mem.doNotOptimizeAway(try c.c.compress(c.input, &c.out, .{}));
            } else std.mem.doNotOptimizeAway(try c.d.decompress(c.out[0..c.n], c.back[0..c.input.len], .{}));
        }
    }
};

fn setup(s: *Session) !void {
    if (!s.wants("zstd-setup/")) return;
    for ([_]i32{ 1, 3 }) |level| for ([_][]const u8{ "", "blob 28\x00tiny file for the setup case\n" }) |input| for ([_]bool{ true, false }) |encode| {
        const ctx = try s.arena.create(Frame);
        ctx.* = .{ .session = s, .level = level, .input = input, .encode = encode };
        try s.measure(Frame, ctx, support.rowOf(Frame, try s.name("zstd-setup/level {d}/{d} B/{s}", .{ level, input.len, if (encode) "encode" else "decode" }), "frame"));
    };
}
