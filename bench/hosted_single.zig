//! One codec per executable, for matched interleaved hosted processes.
//! Storage and input generation are outside timing. The final batch output
//! is checked in full; its fingerprint is retained beside its elapsed time.
const std = @import("std");
const warp = @import("warp");
const gen = @import("gen");
const options = @import("options");
const bench = @import("shakedown").bench;
const Io = std.Io;
const traversals = 2;

pub fn main(init: std.process.Init) !void {
    const gpa = init.arena.allocator();
    const args = try init.minimal.args.toSlice(gpa);
    if (args.len != 5) return error.ExpectedKindOperationSampleStage;
    const kind = std.meta.stringToEnum(gen.Kind, args[1]) orelse return error.InvalidKind;
    const name = args[2];
    const sample = try std.fmt.parseInt(usize, args[3], 10);
    const stage = try std.fmt.parseInt(usize, args[4], 10);
    const op: Operation = if (std.mem.startsWith(u8, name, "deflate-encode")) .encode else if (std.mem.startsWith(u8, name, "deflate-decode")) .decode else std.meta.stringToEnum(Operation, name) orelse return error.InvalidOperation;
    const level: u4 = if (op == .encode) try std.fmt.parseInt(u4, name[name.len - 1 ..], 10) else 6;
    const input = try gen.alloc(gpa, kind, 4, 4 << 20);
    const out = try gpa.alloc(u8, 5 << 20);
    const back = try gpa.alloc(u8, input.len);
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    const flate_level: std.compress.flate.Compress.Options = switch (level) {
        1 => .level_1,
        6 => .level_6,
        9 => .level_9,
        else => return error.InvalidLevel,
    };
    var fixed: Io.Writer = .fixed(out);
    if (op == .decode) {
        var encoder = try std.compress.flate.Compress.init(&fixed, window, .zlib, .level_6);
        try encoder.writer.writeAll(input);
        try encoder.finish();
    }
    const frame = try gpa.dupe(u8, fixed.buffered());
    var compressor = try warp.Compressor.init(gpa, .{ .level = level });
    defer compressor.deinit();
    const decoder = try gpa.create(warp.Decompressor);
    decoder.* = .init;
    var ctx: Context = .{ .input = input, .out = out, .back = back, .window = window, .frame = frame, .c = &compressor, .d = decoder, .op = op, .level = flate_level, .use_std = stage == 4 };
    var json_buffer: [4096]u8 = undefined;
    var json: Io.Writer = .fixed(&json_buffer);
    try bench.run(@typeInfo(@typeInfo(@TypeOf(Context.run)).@"fn".return_type.?).error_union.error_set, gpa, init.io, &json, &ctx, &.{.{ .name = name, .unit = "traversal", .run = Context.run }}, .{ .commit = options.commit }, .{ .samples = 1, .warmup = 1, .minimum = .fromNanoseconds(0), .resolution_multiple = 1, .max_batch = 1 });
    try ctx.validate();
    var parsed = try bench.parse(gpa, json.buffered());
    defer parsed.deinit();
    const ns: u64 = @intFromFloat(parsed.rows.items[0].value.samples[0] / traversals);
    var buffer: [4096]u8 = undefined;
    var stdout = Io.File.stdout().writer(init.io, &buffer);
    try stdout.interface.print("raw {s} {s} sample {d} stage {d} ns {d} result {d} fingerprint {d} source {s}\n", .{ args[1], name, sample, stage, ns, ctx.n, ctx.fingerprint(), options.commit });
    try stdout.interface.flush();
}

const Operation = enum { crc32, crc32c, adler32, encode, decode };
const Context = struct {
    const Self = @This();
    input: []const u8,
    out: []u8,
    back: []u8,
    window: []u8,
    frame: []const u8,
    c: *warp.Compressor,
    d: *warp.Decompressor,
    op: Operation,
    level: std.compress.flate.Compress.Options,
    use_std: bool,
    n: usize = 0,

    fn run(c: *Self, units: u64) !void {
        if (units != 1) return error.InvalidBatch;
        for (0..traversals) |_| c.n = switch (c.op) {
            .crc32 => if (c.use_std) std.hash.Crc32.hash(c.input) else warp.crc32(0, c.input),
            .crc32c => if (c.use_std) std.hash.crc.@"CRC-32/ISCSI".hash(c.input) else warp.crc32c(0, c.input),
            .adler32 => if (c.use_std) std.hash.Adler32.hash(c.input) else warp.adler32(1, c.input),
            .encode => if (c.use_std) try c.stdEncode() else try c.c.compress(c.input, c.out, .{}),
            .decode => if (c.use_std) try c.stdDecode() else (try c.d.inflate(c.frame, c.back, .{})).out_len,
        };
    }
    fn stdEncode(c: *Self) !usize {
        var writer: Io.Writer = .fixed(c.out);
        var encoder = try std.compress.flate.Compress.init(&writer, c.window, .zlib, c.level);
        try encoder.writer.writeAll(c.input);
        try encoder.finish();
        return writer.buffered().len;
    }
    fn stdDecode(c: *Self) !usize {
        var source: Io.Reader = .fixed(c.frame);
        var decoder = std.compress.flate.Decompress.init(&source, .zlib, c.window);
        var writer: Io.Writer = .fixed(c.back);
        _ = try decoder.reader.streamRemaining(&writer);
        return writer.buffered().len;
    }
    fn validate(c: *Self) !void {
        switch (c.op) {
            .encode => {
                const r = try c.d.inflate(c.out[0..c.n], c.back, .{});
                if (!r.finished or r.in_len != c.n or r.out_len != c.input.len) return error.WrongFrame;
                if (!std.mem.eql(u8, c.input, c.back)) return error.WrongOutput;
            },
            .decode => if (c.n != c.input.len or !std.mem.eql(u8, c.input, c.back)) return error.WrongOutput,
            .crc32 => if (c.n != std.hash.Crc32.hash(c.input)) return error.WrongChecksum,
            .crc32c => if (c.n != std.hash.crc.@"CRC-32/ISCSI".hash(c.input)) return error.WrongChecksum,
            .adler32 => if (c.n != std.hash.Adler32.hash(c.input)) return error.WrongChecksum,
        }
    }
    fn fingerprint(c: *const Self) u64 {
        return std.hash.Wyhash.hash(0, switch (c.op) {
            .encode => c.out[0..c.n],
            .decode => c.back[0..c.n],
            else => c.input,
        });
    }
};
