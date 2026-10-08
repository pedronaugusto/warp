//! The host tool behind addCompressedAsset.
const std = @import("std");
const warp = @import("warp");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 5) return error.InvalidArguments;
    const kind = std.meta.stringToEnum(warp.Container, args[3]) orelse return error.InvalidArguments;
    const level = try std.fmt.parseInt(u4, args[4], 10);
    const in = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], init.gpa, .unlimited);
    defer init.gpa.free(in);
    var c = try warp.Compressor.init(init.gpa, .{ .level = level, .max_input = in.len });
    defer c.deinit();
    const out = try init.gpa.alloc(u8, warp.Compressor.bound(in.len, .{ .container = kind }));
    defer init.gpa.free(out);
    const n = try c.compress(in, out, .{ .container = kind });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = out[0..n] });
}
