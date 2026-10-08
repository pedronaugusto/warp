//! Ordered chunk compression and indexed decompression, by worker count.
const std = @import("std");
const warp = @import("warp");
const Io = std.Io;

pub const Workload = struct { name: []const u8, inputs: []const []const u8 };

pub fn run(gpa: std.mem.Allocator, io: Io, out: *Io.Writer, workloads: []const Workload, runs: usize) !void {
    try out.writeAll("\nparallel | workload | level | workers | encode MB/s | decode MB/s | bytes | memory\n");
    for (workloads) |wl| {
        for ([_]u4{ 1, 6, 12 }) |level| for ([_]u16{ 1, 2, 4, 8 }) |workers| {
            const options: warp.parallel.Options = .{ .level = level, .concurrency = workers };
            var encoder = try warp.parallel.Compressor.init(gpa, options);
            defer encoder.deinit();
            var decoder = try warp.parallel.Decompressor.init(gpa, .{ .concurrency = workers });
            defer decoder.deinit();
            var ns: [2]u64 = @splat(std.math.maxInt(u64));
            var total: usize = 0;
            var compressed: usize = 0;
            for (wl.inputs) |input| {
                const storage = try gpa.alloc(u8, input.len + input.len / 8 + 1024);
                defer gpa.free(storage);
                var sink: Io.Writer = .fixed(storage);
                try encoder.compress(io, input, &sink);
                const stream = sink.buffered();
                var index = try warp.gzip.Index.build(gpa, stream, .gzip, 128 << 10);
                defer index.deinit();
                const decoded = try gpa.alloc(u8, input.len);
                defer gpa.free(decoded);
                _ = try decoder.decompress(io, stream, decoded, &index);
                if (!std.mem.eql(u8, input, decoded)) return error.WrongOutput;
                total += input.len;
                compressed += stream.len;
                var best: [2]u64 = @splat(std.math.maxInt(u64));
                for (0..runs) |_| {
                    sink = .fixed(storage);
                    var start = Io.Clock.awake.now(io).nanoseconds;
                    try encoder.compress(io, input, &sink);
                    best[0] = @min(best[0], @as(u64, @intCast(Io.Clock.awake.now(io).nanoseconds - start)));
                    start = Io.Clock.awake.now(io).nanoseconds;
                    _ = try decoder.decompress(io, sink.buffered(), decoded, &index);
                    best[1] = @min(best[1], @as(u64, @intCast(Io.Clock.awake.now(io).nanoseconds - start)));
                }
                if (ns[0] == std.math.maxInt(u64)) ns = .{ 0, 0 };
                ns[0] += best[0];
                ns[1] += best[1];
            }
            try out.print("parallel | {s} | {d} | {d} | {d:.1} | {d:.1} | {d} | {d}\n", .{ wl.name, level, workers, @as(f64, @floatFromInt(total)) * 1e3 / @as(f64, @floatFromInt(@max(ns[0], 1))), @as(f64, @floatFromInt(total)) * 1e3 / @as(f64, @floatFromInt(@max(ns[1], 1))), compressed, warp.parallel.Compressor.memory(options) });
            try out.flush();
        };
    }
}
