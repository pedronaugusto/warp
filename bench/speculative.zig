//! One-stream decoding without an index, including discovery and resolution.
const std = @import("std");
const warp = @import("warp");
const Workload = @import("parallel.zig").Workload;

pub fn run(a: std.mem.Allocator, io: std.Io, out: *std.Io.Writer, workloads: []const Workload, runs: usize) !void {
    try out.writeAll("\nspeculative | workload | workers | native MB/s | parallel MB/s | joined bytes | output bytes | chunks | memory\n");
    var compressor = try warp.Compressor.init(a, .{ .level = 6 });
    defer compressor.deinit();
    var native: warp.Decompressor = .init;
    for (workloads) |wl| for ([_]u16{ 1, 2, 4, 8 }) |workers| {
        var stats: warp.parallel.Decompressor.Statistics = .{};
        const options: warp.parallel.Decompressor.Options = .{ .concurrency = workers, .speculative = .{ .statistics = &stats } };
        var decoder = try warp.parallel.Decompressor.init(a, options);
        defer decoder.deinit();
        var ns: [2]i96 = .{ 0, 0 };
        var total: usize = 0;
        var joined: usize = 0;
        var chunks: usize = 0;
        for (wl.inputs) |input| {
            const encoded = try a.alloc(u8, warp.Compressor.bound(input.len, .{ .container = .gzip }));
            defer a.free(encoded);
            const n = try compressor.compress(input, encoded, .{ .container = .gzip });
            const back = try a.alloc(u8, input.len);
            defer a.free(back);
            const result = try decoder.inflate(io, encoded[0..n], back, .{ .accept = .gzip });
            if (result.out_len != input.len or !std.mem.eql(u8, input, back)) return error.WrongOutput;
            joined += stats.speculative_bytes;
            chunks += stats.chunks;
            total += input.len;
            var best: [2]i96 = @splat(std.math.maxInt(i96));
            for (0..runs) |_| {
                var start = std.Io.Clock.awake.now(io).nanoseconds;
                _ = try native.inflate(encoded[0..n], back, .{ .accept = .gzip });
                best[0] = @min(best[0], std.Io.Clock.awake.now(io).nanoseconds - start);
                start = std.Io.Clock.awake.now(io).nanoseconds;
                _ = try decoder.inflate(io, encoded[0..n], back, .{ .accept = .gzip });
                best[1] = @min(best[1], std.Io.Clock.awake.now(io).nanoseconds - start);
            }
            if (!std.mem.eql(u8, input, back)) return error.WrongOutput;
            for (&ns, best) |*sum, b| sum.* += b;
        }
        try out.print("speculative | {s} | {d} | {d:.1} | {d:.1} | {d} | {d} | {d} | {d}\n", .{ wl.name, workers, @as(f64, @floatFromInt(total)) * 1e3 / @as(f64, @floatFromInt(@max(ns[0], 1))), @as(f64, @floatFromInt(total)) * 1e3 / @as(f64, @floatFromInt(@max(ns[1], 1))), joined, total, chunks, warp.parallel.Decompressor.memory(options) });
        try out.flush();
    };
}
