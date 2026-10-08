//! A streaming zstd command example, built but never installed.
//! zstd-cli compress [level] < input > output.zst
//! zstd-cli decompress [window-log] < input.zst > output
const std = @import("std");
const zstd = @import("warp").zstd;

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 2 or args.len > 3) return error.InvalidArguments;
    var input_buffer: [64 << 10]u8 = undefined;
    var output_buffer: [64 << 10]u8 = undefined;
    var input = std.Io.File.stdin().readerStreaming(init.io, &input_buffer);
    var output = std.Io.File.stdout().writerStreaming(init.io, &output_buffer);
    if (std.mem.eql(u8, args[1], "compress")) {
        const level = if (args.len == 3) try std.fmt.parseInt(i32, args[2], 10) else 3;
        if (level < -131072 or level > 22) return error.InvalidArguments;
        var state = try zstd.Compress.init(init.gpa, .{ .level = level });
        defer state.deinit();
        var staging: [64 << 10]u8 = undefined;
        var adapter: zstd.Compress.Writer = .init(&state, &output.interface, &staging);
        _ = input.interface.streamRemaining(&adapter.interface) catch |err| {
            if (adapter.err()) |failure| return failure;
            return err;
        };
        adapter.finish() catch |err| {
            if (adapter.err()) |failure| return failure;
            return err;
        };
    } else if (std.mem.eql(u8, args[1], "decompress")) {
        const log = if (args.len == 3) try std.fmt.parseInt(u6, args[2], 10) else 27;
        if (log < 10 or log > 31) return error.InvalidArguments;
        const window: usize = @as(usize, 1) << @intCast(log);
        const buffer = try init.gpa.alloc(u8, window + (128 << 10) + 4096);
        defer init.gpa.free(buffer);
        const adapter = try init.gpa.create(zstd.Decompress.Reader);
        defer init.gpa.destroy(adapter);
        adapter.* = .init(&input.interface, buffer, .{});
        _ = adapter.interface.streamRemaining(&output.interface) catch |err| {
            if (adapter.err()) |failure| return failure;
            return err;
        };
    } else return error.InvalidArguments;
    try output.interface.flush();
}
