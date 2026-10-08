//! Indicative hosted measurements. Storage is reserved before timing;
//! every timed output is validated afterward. Seven adjacent samples rotate
//! order, retaining absolute times and paired ratios with their full spread.
const std = @import("std");
const warp = @import("warp");
const previous = @import("previous");
const gen = @import("gen");
const options = @import("options");
const Io = std.Io;
const samples = 7;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const io = init.io;
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(io, &buffer);
    const w = &stdout.interface;
    try w.print("INDICATIVE Zig {s} target {s}-{s}; previous-main e607c194f837fa0a7a8c08914495d4cc0202eb91 enabled={}; 7 rotated adjacent samples; allocations outside timing; std resets per stream, Warp contexts reused; stages current/previous-main/std (zstd current/std)\n", .{ @import("builtin").zig_version_string, @tagName(@import("builtin").cpu.arch), @tagName(@import("builtin").os.tag), options.previous_main });
    const out = try gpa.alloc(u8, 5 << 20);
    const back = try gpa.alloc(u8, 4 << 20);
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    const zwindow = try gpa.alloc(u8, (8 << 20) + std.compress.zstd.block_size_max);
    const d = try gpa.create(warp.Decompressor);
    d.* = .init;
    const old_d = try gpa.create(previous.Decompressor);
    old_d.* = .init;
    const zd = try gpa.create(warp.zstd.Decompressor);
    zd.* = .init;
    for ([_]gen.Kind{ .text, .noise }) |kind| {
        const input = try gen.alloc(gpa, kind, 4, back.len);
        for (0..3) |algorithm| {
            const ctx: Checksum = .{ .input = input, .algorithm = algorithm };
            try measure(io, w, @tagName(kind), switch (algorithm) {
                0 => "crc32",
                1 => "crc32c",
                else => "adler32",
            }, ctx, if (options.previous_main) 3 else 2);
        }
        for ([_]u4{ 1, 6, 9 }) |level| {
            var c = try warp.Compressor.init(gpa, .{ .level = level });
            defer c.deinit();
            var old_c = try previous.Compressor.init(gpa, .{ .level = level });
            defer old_c.deinit();
            const ctx: Encode = .{ .input = input, .out = out, .back = back, .window = window, .c = &c, .old = &old_c, .d = d, .level = switch (level) {
                1 => .level_1,
                6 => .level_6,
                else => .level_9,
            } };
            try measure(io, w, @tagName(kind), try std.fmt.allocPrint(gpa, "deflate-encode-L{d}", .{level}), ctx, if (options.previous_main) 3 else 2);
        }
        var encoded: Io.Writer = .fixed(out);
        var sc = try std.compress.flate.Compress.init(&encoded, window, .zlib, .level_6);
        try sc.writer.writeAll(input);
        try sc.finish();
        const frame = try gpa.dupe(u8, encoded.buffered());
        try measure(io, w, @tagName(kind), "deflate-decode-std-L6-exact", Decode{ .input = input, .frame = frame, .back = back, .window = window, .d = d, .old = old_d }, if (options.previous_main) 3 else 2);
        var zc = try warp.zstd.Compressor.init(gpa, .{ .level = 3, .max_input = input.len });
        defer zc.deinit();
        const zn = try zc.compress(input, out, .{ .checksum = false });
        const zframe = try gpa.dupe(u8, out[0..zn]);
        try measure(io, w, @tagName(kind), "zstd-decode-L3-checksum-off", Zdecode{ .input = input, .frame = zframe, .back = back, .window = zwindow, .d = zd }, 2);
        try measure(io, w, @tagName(kind), "zstd-encode-L3-checksum-off", Zencode{ .input = input, .out = out, .back = back, .c = &zc, .d = zd }, 1);
        try w.writeAll("N/A zstd previous-main: API absent; N/A std zstd encode: API absent\n");
        try w.flush();
    }
}

fn measure(io: Io, w: *Io.Writer, workload: []const u8, name: []const u8, ctx: anytype, count: usize) !void {
    for (0..count) |stage| try ctx.validate(stage, try ctx.run(stage));
    var raw: [3][samples]u64 = undefined;
    for (0..samples) |iteration| {
        for (0..count) |index| {
            const stage = if (iteration & 1 == 0) index else count - 1 - index;
            const start = Io.Clock.awake.now(io).nanoseconds;
            const n = try ctx.run(stage);
            raw[stage][iteration] = @intCast(Io.Clock.awake.now(io).nanoseconds - start);
            try ctx.validate(stage, n);
            try w.print("raw {s} {s} sample {d} stage {d} ns {d} result {d}\n", .{ workload, name, iteration, stage, raw[stage][iteration], n });
        }
    }
    for (0..count) |stage| {
        var ordered = raw[stage];
        std.mem.sort(u64, &ordered, {}, std.sort.asc(u64));
        try w.print("row {s} {s} stage {d} bytes {d} MB/s best/median {d:.3}/{d:.3} ns min/median/max {d}/{d}/{d}\n", .{ workload, name, stage, ctx.input.len, speed(ctx.input.len, ordered[0]), speed(ctx.input.len, ordered[3]), ordered[0], ordered[3], ordered[6] });
        if (stage > 0) {
            var ratios: [samples]f64 = undefined;
            for (0..samples) |i| ratios[i] = @as(f64, @floatFromInt(raw[stage][i])) / @as(f64, @floatFromInt(raw[0][i]));
            std.mem.sort(f64, &ratios, {}, std.sort.asc(f64));
            try w.print("paired {s} {s} current/stage{d} ratio min/median/max {d:.4}/{d:.4}/{d:.4}\n", .{ workload, name, stage, ratios[0], ratios[3], ratios[6] });
        }
    }
    try w.flush();
}
fn speed(bytes: usize, ns: u64) f64 {
    return @as(f64, @floatFromInt(bytes)) * 1e3 / @as(f64, @floatFromInt(@max(1, ns)));
}
fn equal(input: []const u8, output: []const u8) !void {
    if (!std.mem.eql(u8, input, output)) return error.WrongOutput;
}
const Checksum = struct {
    input: []const u8,
    algorithm: usize,
    fn run(c: Checksum, stage: usize) !usize {
        std.mem.doNotOptimizeAway(c.input.ptr);
        return switch (stage) {
            0 => switch (c.algorithm) {
                0 => warp.crc32(0, c.input),
                1 => warp.crc32c(0, c.input),
                else => warp.adler32(1, c.input),
            },
            1 => if (options.previous_main) switch (c.algorithm) {
                0 => previous.crc32(0, c.input),
                1 => previous.crc32c(0, c.input),
                else => previous.adler32(1, c.input),
            } else c.expected(),
            else => c.expected(),
        };
    }
    fn expected(c: Checksum) u32 {
        return switch (c.algorithm) {
            0 => std.hash.Crc32.hash(c.input),
            1 => std.hash.crc.@"CRC-32/ISCSI".hash(c.input),
            else => std.hash.Adler32.hash(c.input),
        };
    }
    fn validate(c: Checksum, _: usize, n: usize) !void {
        if (n != c.expected()) return error.WrongChecksum;
    }
};
const Encode = struct {
    input: []const u8,
    out: []u8,
    back: []u8,
    window: []u8,
    c: *warp.Compressor,
    old: *previous.Compressor,
    d: *warp.Decompressor,
    level: std.compress.flate.Compress.Options,
    fn run(c: Encode, stage: usize) !usize {
        if (stage == 0) return c.c.compress(c.input, c.out, .{});
        if (stage == 1 and options.previous_main) return c.old.compress(c.input, c.out, .{});
        var writer: Io.Writer = .fixed(c.out);
        var encoder = try std.compress.flate.Compress.init(&writer, c.window, .zlib, c.level);
        try encoder.writer.writeAll(c.input);
        try encoder.finish();
        return writer.buffered().len;
    }
    fn validate(c: Encode, _: usize, n: usize) !void {
        const r = try c.d.inflate(c.out[0..n], c.back, .{});
        if (!r.finished or r.out_len != c.input.len or r.in_len != n) return error.WrongFrame;
        try equal(c.input, c.back);
    }
};
const Decode = struct {
    input: []const u8,
    frame: []const u8,
    back: []u8,
    window: []u8,
    d: *warp.Decompressor,
    old: *previous.Decompressor,
    fn run(c: Decode, stage: usize) !usize {
        if (stage == 0) return (try c.d.inflate(c.frame, c.back, .{})).out_len;
        if (stage == 1 and options.previous_main) return (try c.old.inflate(c.frame, c.back, .{})).out_len;
        var source: Io.Reader = .fixed(c.frame);
        var decoder = std.compress.flate.Decompress.init(&source, .zlib, c.window);
        var writer: Io.Writer = .fixed(c.back);
        _ = try decoder.reader.streamRemaining(&writer);
        return writer.buffered().len;
    }
    fn validate(c: Decode, _: usize, n: usize) !void {
        if (n != c.input.len) return error.WrongLength;
        try equal(c.input, c.back);
    }
};
const Zdecode = struct {
    input: []const u8,
    frame: []const u8,
    back: []u8,
    window: []u8,
    d: *warp.zstd.Decompressor,
    fn run(c: Zdecode, stage: usize) !usize {
        if (stage == 0) return (try c.d.decompress(c.frame, c.back, .{})).out_len;
        var source: Io.Reader = .fixed(c.frame);
        var decoder = std.compress.zstd.Decompress.init(&source, c.window, .{ .window_len = 8 << 20, .verify_checksum = false });
        var writer: Io.Writer = .fixed(c.back);
        _ = try decoder.reader.streamRemaining(&writer);
        return writer.buffered().len;
    }
    fn validate(c: Zdecode, _: usize, n: usize) !void {
        if (n != c.input.len) return error.WrongLength;
        try equal(c.input, c.back);
    }
};
const Zencode = struct {
    input: []const u8,
    out: []u8,
    back: []u8,
    c: *warp.zstd.Compressor,
    d: *warp.zstd.Decompressor,
    fn run(c: Zencode, _: usize) !usize {
        return c.c.compress(c.input, c.out, .{ .checksum = false });
    }
    fn validate(c: Zencode, _: usize, n: usize) !void {
        const r = try c.d.decompress(c.out[0..n], c.back, .{});
        if (r.out_len != c.input.len or r.in_len != n) return error.WrongFrame;
        try equal(c.input, c.back);
    }
};
