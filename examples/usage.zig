const std = @import("std");
const warp = @import("warp");

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const data =
        \\the quick brown fox jumps over the lazy dog; the quick brown fox
        \\jumps over the lazy dog; the quick brown fox jumps over the lazy
        \\dog; the quick brown fox jumps over the lazy dog; and once more.
    ;
    // --- README:usage ---
    // Tables sized once; every call after `init` allocates nothing.
    var compressor: warp.Compressor = try .init(gpa, .{ .level = 6 });
    defer compressor.deinit();
    const frame: warp.Compressor.Frame = .{ .container = .gzip, .gzip = .{ .name = "fox.txt" } };
    // An output of `bound` bytes holds the longest stream compress writes.
    const stream = try gpa.alloc(u8, warp.Compressor.bound(data.len, frame));
    defer gpa.free(stream);
    const n = try compressor.compress(data, stream, frame);

    // About 12 KiB of tables and no stream state: one serves any number of
    // calls. Room for `inflate_margin` more bytes lets the fast loop run to
    // the end; the exact size works too.
    var decompressor: warp.Decompressor = .init;
    const out = try gpa.alloc(u8, data.len + warp.inflate_margin);
    defer gpa.free(out);
    const result = try decompressor.inflate(stream[0..n], out, .{ .accept = .gzip });
    std.debug.assert(std.mem.eql(u8, out[0..result.out_len], data));
    // --- README:usage ---
    try reader(gpa, stream[0..n], data);
    checksums(data);
}

fn reader(gpa: std.mem.Allocator, stream: []const u8, data: []const u8) !void {
    // --- README:reader ---
    // From a std.Io.Reader: what follows the stream stays in the reader.
    var input: std.Io.Reader = .fixed(stream);
    var decompressor: warp.Decompressor = .init;
    const out = try gpa.alloc(u8, data.len);
    defer gpa.free(out);
    var diagnostic: warp.Diagnostic = undefined;
    const result = decompressor.inflateReader(&input, out, .{ .accept = .gzip, .diagnostic = &diagnostic }) catch |err| {
        std.log.err("{t} at bit {d}: {t}", .{ err, diagnostic.bit_offset, diagnostic.reason });
        return err;
    };
    std.debug.assert(result.finished);
    std.debug.assert(result.out_len == data.len);
    // --- README:reader ---
}

fn checksums(data: []const u8) void {
    // --- README:checksums ---
    // Continued over pieces, or joined from the pieces' values.
    const half = data.len / 2;
    var crc: warp.Crc32 = .init;
    crc.update(data[0..half]);
    crc.update(data[half..]);
    std.debug.assert(crc.final() == warp.crc32Combine(warp.Crc32.hash(data[0..half]), warp.Crc32.hash(data[half..]), data.len - half));
    std.debug.assert(warp.Crc32c.hash("123456789") == 0xe3069283);
    std.debug.assert(warp.adler32(1, data) == warp.Adler32.hash(data));
    // --- README:checksums ---
}
