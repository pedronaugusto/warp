//! Whole-buffer zstd throughput and setup on generated or caller-provided
//! inputs. Timings are reported by hand; CI only compiles these rows.
const std = @import("std");
const warp = @import("warp");
const gen = @import("gen");
const Io = std.Io;
const zstd = warp.zstd;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(gpa);
    var smoke = false;
    var file: ?[]const u8 = null;
    var levels: []const u8 = "-5,1,3,6,9,19";
    var long_distance = false;
    var checksum = true;
    var concurrency: ?u16 = null;
    var decode_concurrency: u16 = 0;
    var target_block_size: ?u32 = null;
    var dictionary_path: ?[]const u8 = null;
    var runs: usize = 7;
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--smoke")) {
            smoke = true;
        } else if (std.mem.eql(u8, args[i], "--long")) {
            long_distance = true;
        } else if (std.mem.eql(u8, args[i], "--decode-threads") and i + 1 < args.len) {
            i += 1;
            decode_concurrency = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--target") and i + 1 < args.len) {
            i += 1;
            target_block_size = try std.fmt.parseInt(u32, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--parallel") and i + 1 < args.len) {
            i += 1;
            concurrency = try std.fmt.parseInt(u16, args[i], 10);
        } else if (std.mem.eql(u8, args[i], "--dictionary") and i + 1 < args.len) {
            i += 1;
            dictionary_path = args[i];
        } else if (std.mem.eql(u8, args[i], "--no-checksum")) {
            checksum = false;
        } else if (std.mem.eql(u8, args[i], "--file") and i + 1 < args.len) {
            i += 1;
            file = args[i];
        } else if (std.mem.eql(u8, args[i], "--levels") and i + 1 < args.len) {
            i += 1;
            levels = args[i];
        } else if (std.mem.eql(u8, args[i], "--runs") and i + 1 < args.len) {
            i += 1;
            runs = try std.fmt.parseInt(usize, args[i], 10);
        } else return error.UnknownArgument;
    }
    if (smoke) runs = 1;
    if (runs == 0) return error.InvalidRuns;
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buffer);
    const writer = &stdout.interface;
    try writer.print("zstd | workload | level | input | compressed | encode MB/s | decode MB/s | memory\n", .{});
    var dictionary: ?zstd.Dictionary = null;
    if (dictionary_path) |path| dictionary = try zstd.Dictionary.parse(try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited));
    const dict: ?*const zstd.Dictionary = if (dictionary) |*d| d else null;
    if (file) |path| {
        const in = try Io.Dir.cwd().readFileAlloc(io, path, gpa, .unlimited);
        try workload(gpa, io, writer, path, in, levels, runs, long_distance, checksum, dict, concurrency, target_block_size, decode_concurrency);
    } else {
        const len: usize = if (smoke) 20_000 else 4 << 20;
        for ([_]gen.Kind{ .text, .binary, .json, .noise, .runs, .png }) |kind| {
            const in = try gen.alloc(gpa, kind, 4, len);
            try workload(gpa, io, writer, @tagName(kind), in, levels, runs, long_distance, checksum, dict, concurrency, target_block_size, decode_concurrency);
        }
    }
    try setup(gpa, io, writer, if (smoke) 10 else 200_000, runs);
    try writer.flush();
}

fn now(io: Io) i96 {
    return Io.Clock.awake.now(io).nanoseconds;
}

fn throughput(bytes: usize, ns: u64) f64 {
    return 1000 * @as(f64, @floatFromInt(bytes)) / @as(f64, @floatFromInt(@max(1, ns)));
}

fn workload(gpa: std.mem.Allocator, io: Io, writer: *Io.Writer, name: []const u8, in: []const u8, levels: []const u8, runs: usize, long_distance: bool, checksum: bool, dictionary: ?*const zstd.Dictionary, concurrency: ?u16, target_block_size: ?u32, decode_concurrency: u16) !void {
    if (target_block_size) |target| return targetWorkload(gpa, io, writer, name, in, levels, runs, checksum, dictionary, target);
    if (concurrency) |count| return parallelWorkload(gpa, io, writer, name, in, levels, runs, checksum, dictionary, count);
    const out = try gpa.alloc(u8, zstd.Compressor.bound(in.len));
    defer gpa.free(out);
    const back = try gpa.alloc(u8, in.len);
    defer gpa.free(back);
    const d = try gpa.create(zstd.Decompressor);
    defer gpa.destroy(d);
    d.* = .init;
    var pipeline: ?zstd.parallel.Decompressor = if (decode_concurrency == 0) null else try zstd.parallel.Decompressor.init(gpa, .{ .concurrency = decode_concurrency });
    defer if (pipeline) |*p| p.deinit();
    var it = std.mem.splitScalar(u8, levels, ',');
    while (it.next()) |text| {
        const level = try std.fmt.parseInt(i32, text, 10);
        const options: zstd.Compressor.Options = .{ .level = level, .max_input = in.len, .tuning = .{ .long_distance = long_distance }, .dictionary = dictionary };
        var c = try zstd.Compressor.init(gpa, options);
        defer c.deinit();
        const n = try c.compress(in, out, .{ .checksum = checksum });
        _ = try decodeFrame(io, d, if (pipeline) |*p| p else null, out[0..n], back, dictionary);
        if (!std.mem.eql(u8, in, back)) return error.WrongOutput;
        var encode_ns: u64 = std.math.maxInt(u64);
        var decode_ns: u64 = std.math.maxInt(u64);
        for (0..runs) |_| {
            const start = now(io);
            std.mem.doNotOptimizeAway(try c.compress(in, out, .{ .checksum = checksum }));
            const encoded = now(io);
            std.mem.doNotOptimizeAway(try decodeFrame(io, d, if (pipeline) |*p| p else null, out[0..n], back, dictionary));
            const decoded = now(io);
            encode_ns = @min(encode_ns, @as(u64, @intCast(encoded - start)));
            decode_ns = @min(decode_ns, @as(u64, @intCast(decoded - encoded)));
        }
        try writer.print("{s} | {s} | {d} | {d} | {d} | {d:.1} | {d:.1} | {d}\n", .{ if (pipeline != null) "zstd-pipeline" else if (dictionary != null) "zstd-dict" else if (long_distance) "zstd-long" else "zstd", name, level, in.len, n, throughput(in.len, encode_ns), throughput(in.len, decode_ns), zstd.Compressor.memory(options) });
        try writer.flush();
    }
}

fn decodeFrame(io: Io, d: *zstd.Decompressor, pipeline: ?*zstd.parallel.Decompressor, input: []const u8, output: []u8, dictionary: ?*const zstd.Dictionary) !zstd.Decompressor.Result {
    const options: zstd.Decompressor.Options = .{ .max_window = std.math.maxInt(u64), .dictionaries = if (dictionary) |dict| &.{dict} else &.{} };
    if (pipeline) |p| return p.decompress(io, input, output, options);
    return d.decompress(input, output, options);
}

fn setup(gpa: std.mem.Allocator, io: Io, writer: *Io.Writer, rounds: usize, runs: usize) !void {
    const d = try gpa.create(zstd.Decompressor);
    defer gpa.destroy(d);
    d.* = .init;
    try writer.print("zstd-setup | level | input | compressed | encode ns/frame | decode ns/frame\n", .{});
    for ([_]i32{ 1, 3 }) |level| for ([_][]const u8{ "", "blob 28\x00tiny file for the setup case\n" }) |in| {
        var c = try zstd.Compressor.init(gpa, .{ .level = level, .max_input = in.len });
        defer c.deinit();
        var out: [128]u8 = undefined;
        var back: [128]u8 = undefined;
        const n = try c.compress(in, &out, .{});
        var encode_ns: u64 = std.math.maxInt(u64);
        var decode_ns: u64 = std.math.maxInt(u64);
        for (0..runs) |_| {
            const start = now(io);
            for (0..rounds) |_| std.mem.doNotOptimizeAway(try c.compress(in, &out, .{}));
            const encoded = now(io);
            for (0..rounds) |_| std.mem.doNotOptimizeAway(try d.decompress(out[0..n], back[0..in.len], .{}));
            const decoded = now(io);
            encode_ns = @min(encode_ns, @as(u64, @intCast(encoded - start)));
            decode_ns = @min(decode_ns, @as(u64, @intCast(decoded - encoded)));
        }
        try writer.print("zstd-setup | {d} | {d} | {d} | {d:.1} | {d:.1}\n", .{ level, in.len, n, @as(f64, @floatFromInt(encode_ns)) / @as(f64, @floatFromInt(rounds)), @as(f64, @floatFromInt(decode_ns)) / @as(f64, @floatFromInt(rounds)) });
    };
}

fn parallelWorkload(gpa: std.mem.Allocator, io: Io, writer: *Io.Writer, name: []const u8, in: []const u8, levels: []const u8, runs: usize, checksum: bool, dictionary: ?*const zstd.Dictionary, concurrency: u16) !void {
    const out = try gpa.alloc(u8, in.len + in.len / 32 + 4096);
    defer gpa.free(out);
    const back = try gpa.alloc(u8, in.len);
    defer gpa.free(back);
    const d = try gpa.create(zstd.Decompressor);
    defer gpa.destroy(d);
    d.* = .init;
    var it = std.mem.splitScalar(u8, levels, ',');
    while (it.next()) |text| {
        const options: zstd.parallel.Options = .{ .level = try std.fmt.parseInt(i32, text, 10), .concurrency = concurrency, .dictionary = dictionary, .frame = .{ .checksum = checksum } };
        var p = try zstd.parallel.Compressor.init(gpa, options);
        defer p.deinit();
        var best: u64 = std.math.maxInt(u64);
        var n: usize = 0;
        for (0..runs) |_| {
            var sink: Io.Writer = .fixed(out);
            const start = now(io);
            try p.compress(io, in, &sink);
            best = @min(best, @as(u64, @intCast(now(io) - start)));
            n = sink.buffered().len;
        }
        _ = try d.decompress(out[0..n], back, .{ .max_window = std.math.maxInt(u64), .dictionaries = if (dictionary) |dict| &.{dict} else &.{} });
        if (!std.mem.eql(u8, in, back)) return error.WrongOutput;
        try writer.print("zstd-parallel | {s} | {d} | {d} | {d} | {d:.1} | threads {d} | memory {d}\n", .{ name, options.level, in.len, n, throughput(in.len, best), concurrency, zstd.parallel.Compressor.memory(options) });
        try writer.flush();
    }
}

fn targetWorkload(gpa: std.mem.Allocator, io: Io, writer: *Io.Writer, name: []const u8, in: []const u8, levels: []const u8, runs: usize, checksum: bool, dictionary: ?*const zstd.Dictionary, target: u32) !void {
    const out = try gpa.alloc(u8, in.len + in.len / 32 + 4096);
    defer gpa.free(out);
    const back = try gpa.alloc(u8, in.len);
    defer gpa.free(back);
    const d = try gpa.create(zstd.Decompressor);
    defer gpa.destroy(d);
    d.* = .init;
    var it = std.mem.splitScalar(u8, levels, ',');
    while (it.next()) |text| {
        const options: zstd.Compress.Options = .{ .level = try std.fmt.parseInt(i32, text, 10), .pledged_size = in.len, .dictionary = dictionary, .frame = .{ .checksum = checksum }, .target_block_size = target };
        var s = try zstd.Compress.init(gpa, options);
        defer s.deinit();
        var best: u64 = std.math.maxInt(u64);
        var n: usize = 0;
        for (0..runs) |_| {
            var sink: Io.Writer = .fixed(out);
            var adapter: zstd.Compress.Writer = .init(&s, &sink, &.{});
            const start = now(io);
            try adapter.interface.writeAll(in);
            try adapter.finish();
            best = @min(best, @as(u64, @intCast(now(io) - start)));
            n = sink.buffered().len;
            s.reset();
        }
        _ = try d.decompress(out[0..n], back, .{ .max_window = std.math.maxInt(u64), .dictionaries = if (dictionary) |dict| &.{dict} else &.{} });
        if (!std.mem.eql(u8, in, back)) return error.WrongOutput;
        try writer.print("zstd-target | {s} | {d} | {d} | {d} | {d:.1} | target {d} | memory {d}\n", .{ name, options.level, in.len, n, throughput(in.len, best), target, zstd.Compress.memory(options) });
        try writer.flush();
    }
}
