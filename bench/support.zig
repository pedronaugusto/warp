//! What the benchmark programs share: the session that runs a row through
//! shakedown, the error set rows declare, the generated workloads and the
//! books' corpora, and the zlib streams the decoding rows read.
//!
//! A row is one named thing at one parameter point: `family/workload/variant`.
//! Each family builds its rows at run time, one context per row, and hands them
//! to `Session.measure`; shakedown picks the batch, takes the samples and writes
//! the JSONL, so a program prints no table of its own.
const std = @import("std");
const Io = std.Io;
const aegis = @import("aegis");
const warp = @import("warp");
const gen = @import("gen");
const shakedown = @import("shakedown");
const provenance = @import("preflight_bench_options");

/// What a row's hooks and run can fail with: the codecs' failures, the
/// allocator's, and the two checks a fixture makes of its own work.
pub const Error = std.mem.Allocator.Error || Io.Writer.Error || Io.Reader.Error || Io.Cancelable ||
    warp.Decompressor.InflateError || warp.Compressor.CompressError || warp.Inflate.DecodeError ||
    warp.Inflate.Reader.ReadError || warp.parallel.Decompressor.DecodeError || warp.parallel.Compressor.Error ||
    warp.gzip.Index.BuildError || warp.zstd.Decompressor.Error || warp.zstd.Compressor.CompressError ||
    warp.zstd.parallel.Compressor.Error || warp.zstd.parallel.Compressor.InitError || warp.zstd.Compress.Error ||
    warp.brotli.Decompressor.Error || warp.brotli.Decompress.Error || warp.brotli.Compressor.Error ||
    warp.gdeflate.Error || warp.gdeflate.Compressor.CompressError ||
    warp.snappy.Error || warp.snappy.Compressor.Error || warp.snappy.Compressor.InitError || warp.snappy.Compressor.StreamError ||
    warp.snappy.StreamError || warp.snappy.Compress.Error || warp.snappy.Compress.InitError || warp.snappy.parallel.Decompressor.Error ||
    warp.snappy.Decompress.InitError || warp.lz4.Decompress.InitError ||
    std.compress.flate.Decompress.Error || error{ WrongLength, WrongOutput, InvalidOptions };

pub const Row = shakedown.bench.Row;

/// The most a program reads of one file: a corpus, a stream or a dictionary.
const file_limit: aegis.units.Bytes(u64) = .fromRaw(4 << 30);

/// The bytes of the file at `path`, allocated with `gpa`.
pub fn readFile(io: Io, gpa: std.mem.Allocator, path: []const u8) aegis.own.ReadFileError![]u8 {
    return aegis.own.readFile(io, Io.Dir.cwd(), path, gpa, file_limit);
}

/// One workload: the inputs, as whole streams.
pub const Workload = struct {
    name: []const u8,
    inputs: []const []const u8,
    total: u64,
    max: usize,
};

/// One run of a program: where its rows go, how they are measured, and
/// the inputs they share.
pub const Session = struct {
    gpa: std.mem.Allocator,
    /// Lives as long as the session: names, inputs, streams.
    arena: std.mem.Allocator,
    io: Io,
    out: *Io.Writer,
    options: shakedown.bench.Options,
    corpus: ?[]const u8 = null,
    /// The CPUs the machine has: a row of more workers than these measures the
    /// scheduler, so the parallel families leave it out.
    cpus: usize,
    loaded: ?[]const Workload = null,
    zlib: std.AutoHashMapUnmanaged(usize, []const []const u8) = .empty,

    pub fn init(init_: std.process.Init, out: *Io.Writer, smoke: bool, prefix: []const u8, corpus: ?[]const u8) Session {
        return .{
            .gpa = init_.gpa,
            .arena = init_.arena.allocator(),
            .io = init_.io,
            .out = out,
            // Seven samples a row, as the programs took best of seven before: the
            // slowest rows (levels 10 to 12 over megabytes) take a second a sample.
            .options = .{ .smoke = smoke, .prefix = prefix, .samples = 7 },
            .corpus = corpus,
            .cpus = std.Thread.getCpuCount() catch 1,
        };
    }

    /// Whether any row of `family` can match the rows asked for, so a family
    /// that is not asked for builds none of its inputs.
    pub fn wants(s: *const Session, family: []const u8) bool {
        return std.mem.startsWith(u8, family, s.options.prefix) or std.mem.startsWith(u8, s.options.prefix, family);
    }

    pub fn name(s: *Session, comptime format: []const u8, args: anytype) std.mem.Allocator.Error![]const u8 {
        return s.arena.print(format, args);
    }

    /// Measures one row over its context.
    pub fn measure(s: *Session, comptime Context: type, context: *Context, row: Row(Context, Error)) shakedown.bench.RunError(Error)!void {
        const rows = [_]Row(Context, Error){row};
        try shakedown.bench.run(Error, s.gpa, s.io, s.out, context, &rows, .{
            .commit = provenance.commit,
            .cpu = provenance.cpu,
            .os = provenance.os,
        }, s.options);
    }

    /// The generated workloads, and the books' corpora given `--corpus`.
    pub fn workloads(s: *Session) ![]const Workload {
        if (s.loaded) |list| return list;
        const arena = s.arena;
        var list: std.ArrayList(Workload) = .empty;
        const size: usize = if (s.options.smoke) 20_000 else 4 << 20;
        for ([_]gen.Kind{ .text, .binary, .png, .json, .runs }) |kind| {
            const one = try gen.alloc(arena, kind, 1, size);
            try list.append(arena, .{ .name = @tagName(kind), .inputs = try arena.dupe([]const u8, &.{one}), .total = one.len, .max = one.len });
        }
        // Small objects: many short texts, as git's loose objects are.
        {
            const count: usize = if (s.options.smoke) 10 else 4000;
            const inputs = try arena.alloc([]const u8, count);
            var total: u64 = 0;
            var prng: gen.Prng = .init(7);
            for (inputs, 0..) |*in, n| {
                in.* = try gen.alloc(arena, .text, n, 200 + prng.below(2000));
                total += in.len;
            }
            try list.append(arena, .{ .name = "small-text", .inputs = inputs, .total = total, .max = 2200 });
        }
        if (s.corpus) |dir| {
            try list.append(arena, try s.objects(dir, "loose-git", "objects-git.batch", std.math.maxInt(usize)));
            try list.append(arena, try s.objects(dir, "loose-git-small", "objects-git.batch", 4096));
            try list.append(arena, try s.files(dir, "tar", &.{"git-v2.51.0.tar"}));
            try list.append(arena, try s.files(dir, "silesia", &.{ "silesia/dickens", "silesia/mozilla", "silesia/mr", "silesia/nci", "silesia/ooffice", "silesia/osdb", "silesia/reymont", "silesia/samba", "silesia/sao", "silesia/webster", "silesia/x-ray", "silesia/xml" }));
        }
        s.loaded = list.items;
        return list.items;
    }

    /// `git cat-file --batch` output, each object as a loose object deflates it.
    fn objects(s: *Session, dir: []const u8, name_: []const u8, file: []const u8, max_size: usize) !Workload {
        const path = try std.fs.path.join(s.arena, &.{ dir, file });
        const data = try readFile(s.io, s.arena, path);
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
            const object = try s.arena.print("{s} {d}\x00{s}", .{ kind, size, body });
            try inputs.append(s.arena, object);
            total += object.len;
            max = @max(max, object.len);
        }
        return .{ .name = name_, .inputs = inputs.items, .total = total, .max = max };
    }

    fn files(s: *Session, dir: []const u8, name_: []const u8, names: []const []const u8) !Workload {
        var inputs: std.ArrayList([]const u8) = .empty;
        var total: u64 = 0;
        var max: usize = 0;
        for (names) |n| {
            const data = try readFile(s.io, s.arena, try std.fs.path.join(s.arena, &.{ dir, n }));
            try inputs.append(s.arena, data);
            total += data.len;
            max = @max(max, data.len);
        }
        return .{ .name = name_, .inputs = inputs.items, .total = total, .max = max };
    }

    /// std's zlib streams of a workload at level 6, written once: the same
    /// streams for every decoder.
    pub fn streams(s: *Session, index: usize) ![]const []const u8 {
        if (s.zlib.get(index)) |found| return found;
        const wl = (try s.workloads())[index];
        const window = try s.arena.alloc(u8, std.compress.flate.max_window_len);
        const list = try s.arena.alloc([]const u8, wl.inputs.len);
        const out = try s.arena.alloc(u8, wl.max + wl.max / 8 + 1024);
        for (wl.inputs, list) |in, *slot| {
            var w: Io.Writer = .fixed(out);
            var c = try std.compress.flate.Compress.init(&w, window, .zlib, .level_6);
            try c.writer.writeAll(in);
            try c.finish();
            slot.* = try s.arena.dupe(u8, w.buffered());
        }
        try s.zlib.put(s.arena, index, list);
        return list;
    }
};

/// A row over a context with the hooks the context declares: `setup` and
/// `teardown` once per row, `run` of `units`.
pub fn rowOf(comptime Context: type, name: []const u8, unit: []const u8) Row(Context, Error) {
    return .{
        .name = name,
        .unit = unit,
        .run = Context.run,
        .fixture = .{ .lifetime = .row, .setup = Context.setup, .teardown = Context.teardown },
    };
}
