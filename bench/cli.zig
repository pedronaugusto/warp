//! A file codec example: warp [-d] [-l level] [-j workers] [--raw|--zlib] input output.
const std = @import("std");
const warp = @import("warp");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    var level: u4 = 6;
    var concurrency: u16 = 8;
    var kind: warp.Container = .gzip;
    var decode = false;
    var at: usize = 1;
    while (at < args.len and std.mem.startsWith(u8, args[at], "-")) : (at += 1) {
        const arg = args[at];
        if (std.mem.eql(u8, arg, "-d")) decode = true else if (std.mem.eql(u8, arg, "--raw")) kind = .raw else if (std.mem.eql(u8, arg, "--zlib")) kind = .zlib else if (std.mem.eql(u8, arg, "-l") or std.mem.eql(u8, arg, "-j")) {
            at += 1;
            if (at == args.len) return error.InvalidArguments;
            if (std.mem.eql(u8, arg, "-l")) level = try std.fmt.parseInt(u4, args[at], 10) else concurrency = try std.fmt.parseInt(u16, args[at], 10);
        } else return error.InvalidArguments;
    }
    if (args.len - at != 2 or concurrency == 0) return error.InvalidArguments;
    const input = try std.Io.Dir.cwd().openFile(init.io, args[at], .{});
    defer input.close(init.io);
    const output = try std.Io.Dir.cwd().createFile(init.io, args[at + 1], .{});
    defer output.close(init.io);
    var in_buffer: [16384]u8 = undefined;
    var out_buffer: [16384]u8 = undefined;
    var reader = input.reader(init.io, &in_buffer);
    var writer = output.writer(init.io, &out_buffer);
    if (decode) {
        var buffer: [32768 + 4096]u8 = undefined;
        var decoded: warp.Inflate.Reader = .init(&reader.interface, &buffer, .{
            .accept = switch (kind) {
                .raw => .raw,
                .zlib => .zlib,
                .gzip => .gzip,
            },
        });
        _ = try decoded.interface.streamRemaining(&writer.interface);
    } else {
        var compressor = try warp.parallel.Compressor.init(init.gpa, .{ .level = level, .concurrency = concurrency, .container = kind });
        defer compressor.deinit();
        try compressor.compressReader(init.io, &reader.interface, &writer.interface);
    }
    try writer.interface.flush();
}
