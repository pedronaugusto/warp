//! warp makes no OS calls but CPU detection, and on a target it cannot
//! detect on it uses what the target guarantees: this object builds for
//! wasm32-freestanding, powerpc64 and x86 (`zig build check-freestanding`,
//! `check-big-endian`, `check-32-bit`), and its exports reach every public
//! call, so the whole package is analysed for each.
const std = @import("std");
const warp = @import("warp");

var memory: [1 << 20]u8 align(64) = undefined;

/// Every checksum, continued, combined, and the kernels chosen.
export fn warpChecksums(bytes: [*]const u8, len: usize) u32 {
    const b = bytes[0..len];
    var crc: warp.Crc32 = .init;
    crc.update(b);
    var crc_c: warp.Crc32c = .init;
    crc_c.update(b);
    var adler: warp.Adler32 = .init;
    adler.update(b);
    const k = warp.kernels();
    return crc.final() ^ crc_c.final() ^ adler.final() ^
        warp.crc32Combine(warp.crc32(0, b), warp.Crc32.hash(b), len) ^
        warp.crc32cCombine(warp.crc32c(0, b), warp.Crc32c.hash(b), len) ^
        warp.adler32Combine(warp.adler32(1, b), warp.Adler32.hash(b), len) ^
        @backingInt(k.crc32) ^ @backingInt(k.crc32c) ^ @backingInt(k.adler32);
}

/// One stream of `in` into `out` at `level`, in `container` (0 raw, 1 zlib,
/// 2 gzip) with a named gzip member; its length, or -1.
export fn warpCompress(in: [*]const u8, in_len: usize, out: [*]u8, out_len: usize, level: u8, container: u8) isize {
    const options: warp.Compressor.Options = .{ .level = @truncate(level), .max_input = in_len };
    const size = warp.Compressor.memory(options);
    if (size > memory.len) return -1;
    var c: warp.Compressor = .initBuffer(memory[0..size], options);
    defer c.deinit();
    const frame: warp.Compressor.Frame = .{
        .container = std.enums.fromInt(warp.Container, container) orelse return -1,
        .gzip = .{ .name = "in" },
    };
    if (out_len < warp.Compressor.bound(in_len, frame)) return -1;
    return @intCast(c.compress(in[0..in_len], out[0..out_len], frame) catch return -1);
}

/// `in` decoded into `out`, from memory and through a reader, as `accept`
/// (an `Accept` by number); the bytes written, or -1.
export fn warpDecompress(in: [*]const u8, in_len: usize, out: [*]u8, out_len: usize, accept: u8) isize {
    var d: warp.Decompressor = .init;
    const options: warp.Decompressor.Options = .{ .accept = std.enums.fromInt(warp.Accept, accept) orelse return -1, .partial = out_len < warp.inflate_margin };
    const whole = d.inflate(in[0..in_len], out[0..out_len], options) catch return -1;
    var r: std.Io.Reader = .fixed(in[0..in_len]);
    const read = d.inflateReader(&r, out[0..out_len], options) catch return -1;
    if (read.out_len != whole.out_len) return -1;
    return @intCast(whole.out_len);
}

/// A gzip member header read and written back; its length, or -1.
export fn warpGzipHeader(in: [*]const u8, in_len: usize, out: [*]u8, out_len: usize) isize {
    const parsed = warp.gzip.parseHeader(in[0..in_len]) catch return -1;
    var w: std.Io.Writer = .fixed(out[0..out_len]);
    warp.gzip.writeHeader(&w, parsed.header) catch return -1;
    return @intCast(w.buffered().len);
}

/// Extended decoding and an owned checkpoint in caller memory.
export fn warpExtended(in: [*]const u8, in_len: usize, out: [*]u8, out_len: usize) isize {
    var d: warp.deflate64.Decompressor = .init;
    const r = d.inflate(in[0..in_len], out[0..out_len], .{ .partial = true }) catch return -1;
    var window: [32768]u8 = undefined;
    var z: warp.Inflate = .init(&window, .{ .accept = .raw });
    var checkpoint: warp.Inflate.Checkpoint = .{ .in_offset = 0, .out_offset = 0, .window_bits = 15, .bits = 0, .pending = 0, .wrapper = .raw, .check = 0, .size = 0, .members = 0, .history_len = 0 };
    z.@"resume"(&checkpoint) catch return -1;
    _ = z.decode(in[0..in_len], out[0..out_len]) catch return -1;
    checkpoint = z.checkpoint() catch checkpoint;
    return @intCast(r.out_len);
}

/// BGZF's caller-owned writer on a fixed sink.
export fn warpBlockedGzip(in: [*]const u8, in_len: usize, out: [*]u8, out_len: usize) isize {
    const options: warp.gzip.Bgzf.Options = .{ .level = 1 };
    const n = warp.gzip.Bgzf.memory(options);
    if (n > memory.len) return -1;
    var b = warp.gzip.Bgzf.initBuffer(memory[0..n], options);
    defer b.deinit();
    var sink: std.Io.Writer = .fixed(out[0..out_len]);
    b.write(in[0..in_len], &sink) catch return -1;
    b.finish(&sink) catch return -1;
    return @intCast(sink.buffered().len);
}
