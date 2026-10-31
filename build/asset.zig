//! The host tool behind addCompressedAsset.
const std = @import("std");
const aegis = @import("aegis");
const warp = @import("warp");

/// The most a source may hold: an asset is embedded in a program.
const max_source: aegis.units.Bytes(u64) = .literal("1GiB");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 5) return error.InvalidArguments;
    const kind = std.meta.stringToEnum(warp.Container, args[3]) orelse return error.InvalidArguments;
    const level = try std.fmt.parseInt(u4, args[4], 10);
    const in = try aegis.own.readFile(init.io, std.Io.Dir.cwd(), args[1], init.gpa, max_source);
    defer init.gpa.free(in);
    var c = try warp.Compressor.init(init.gpa, .{ .level = level, .max_input = .fromRaw(in.len) });
    defer c.deinit();
    const out = try init.gpa.alloc(u8, warp.Compressor.bound(in.len, .{ .container = kind }));
    defer init.gpa.free(out);
    const n = try c.compress(in, out, .{ .container = kind });
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = args[2], .data = out[0..n] });
}
