//! warp makes no OS calls but CPU detection, and on a target it cannot
//! detect on it uses what the target guarantees: this object builds for
//! wasm32-freestanding, powerpc64 and x86 (`zig build check-freestanding`,
//! `check-big-endian`, `check-32-bit`), and its exports reach every public
//! call, so the whole package is analysed for each.
const std = @import("std");
const warp = @import("warp");

var memory: [1 << 20]u8 align(64) = undefined;
var pipeline_memory: [3 << 20]u8 align(64) = undefined;

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

/// All zstd strategies, frame options and caller-provided storage.
export fn warpZstdCompress(in: [*]const u8, in_len: usize, out: [*]u8, out_len: usize, level: i32, dict: [*]const u8, dict_len: usize) isize {
    const dictionary = warp.zstd.Dictionary.parse(dict[0..dict_len]) catch return -1;
    const options: warp.zstd.Compressor.Options = .{ .level = level, .max_input = in_len, .dictionary = &dictionary };
    const size = warp.zstd.Compressor.memory(options);
    if (size > memory.len) return -1;
    var c: warp.zstd.Compressor = .initBuffer(memory[0..size], options);
    defer c.deinit();
    if (out_len < warp.zstd.Compressor.bound(in_len)) return -1;
    return @intCast(c.compress(in[0..in_len], out[0..out_len], .{}) catch return -1);
}

/// Dictionary trainers and finalization with caller-provided allocation.
export fn warpZstdTrain(in: [*]const u8, in_len: usize, out: [*]u8, out_len: usize, exact: bool) isize {
    var allocator: std.heap.FixedBufferAllocator = .init(&memory);
    const samples: []const []const u8 = &.{in[0..in_len]};
    const options: warp.zstd.train.Options = .{ .algorithm = if (exact) .cover else .fast_cover, .steps = 1 };
    const n = warp.zstd.train.train(allocator.allocator(), samples, out[0..out_len], options) catch return -1;
    const dictionary = warp.zstd.Dictionary.parse(out[0..n]) catch return -1;
    const finalized = warp.zstd.train.finalize(allocator.allocator(), dictionary.content, samples, out[0..out_len], options) catch return -1;
    return @intCast(finalized);
}

/// Seekable output, table indexing and frame/range reads.
export fn warpZstdSeekable(in: [*]const u8, in_len: usize, out: [*]u8, out_len: usize, decoded: [*]u8, decoded_len: usize) isize {
    const options: warp.zstd.seekable.Writer.Options = .{ .frame_len = 1024, .max_frames = 128 };
    const size = warp.zstd.seekable.Writer.memory(options);
    if (size > memory.len) return -1;
    var sink: std.Io.Writer = .fixed(out[0..out_len]);
    var writer: warp.zstd.seekable.Writer = .initBuffer(memory[0..size], &sink, options);
    defer writer.deinit();
    writer.interface.writeAll(in[0..in_len]) catch return -1;
    writer.finish() catch return -1;
    if (writer.err() != null) return -1;
    _ = warp.zstd.seekable.Index.memory(sink.buffered()) catch return -1;
    var allocator: std.heap.FixedBufferAllocator = .init(&memory);
    var index = warp.zstd.seekable.Index.init(allocator.allocator(), sink.buffered()) catch return -1;
    defer index.deinit();
    var reader: warp.zstd.seekable.Reader = .init(&index, memory[allocator.end_index..], .{});
    _ = reader.readFrame(0, decoded[0..decoded_len]) catch return -1;
    return @intCast(reader.read(0, decoded[0..decoded_len]) catch return -1);
}

/// Zstd decoding, reader decoding, dictionaries and frame inspection.
export fn warpZstdDecompress(in: [*]const u8, in_len: usize, out: [*]u8, out_len: usize, dict: [*]const u8, dict_len: usize, partial: bool) isize {
    var dictionary = warp.zstd.Dictionary.parse(dict[0..dict_len]) catch return -1;
    var d: warp.zstd.Decompressor = .init;
    const options: warp.zstd.Decompressor.Options = .{ .dictionaries = &.{&dictionary}, .partial = partial };
    const whole = d.decompress(in[0..in_len], out[0..out_len], options) catch return -1;
    var r: std.Io.Reader = .fixed(in[0..in_len]);
    const read = d.decompressReader(&r, out[0..out_len], options) catch return -1;
    if (read.out_len != whole.out_len) return -1;
    _ = warp.zstd.frameHeader(in[0..in_len], .standard) catch return -1;
    _ = warp.zstd.frameLength(in[0..in_len], .standard) catch return -1;
    _ = warp.zstd.contentSize(in[0..in_len], .standard) catch return -1;
    _ = warp.zstd.decompressBound(in[0..in_len], .standard) catch return -1;
    _ = warp.zstd.writeSkippable(out[0..out_len], 0, in[0..in_len]) catch return -1;
    return @intCast(whole.out_len);
}

/// The streaming encoder and writer adapter, using the same caller storage.
export fn warpZstdStreamCompress(in: [*]const u8, in_len: usize, out: [*]u8, out_len: usize, level: i32) isize {
    const options: warp.zstd.Compress.Options = .{ .level = level, .target_block_size = 2048, .pledged_size = in_len };
    const size = warp.zstd.Compress.memory(options);
    if (size > memory.len) return -1;
    var s: warp.zstd.Compress = .initBuffer(memory[0..size], options);
    defer s.deinit();
    const step = s.write(in[0..in_len], out[0..out_len]) catch return -1;
    if (step.in_len != in_len) return -1;
    const final = s.finish(out[step.out_len..out_len]) catch return -1;
    if (!final.done) return -1;
    s.reset();
    var sink: std.Io.Writer = .fixed(out[0..out_len]);
    var adapter: warp.zstd.Compress.Writer = .init(&s, &sink, &.{});
    adapter.interface.writeAll(in[0..in_len]) catch return -1;
    adapter.finish() catch return -1;
    if (adapter.err() != null) return -1;
    return @intCast(sink.buffered().len);
}

/// The streaming decoder and its reader adapter.
export fn warpZstdStreamDecompress(in: [*]const u8, in_len: usize, out: [*]u8, out_len: usize) isize {
    var s: warp.zstd.Decompress = .init(&memory, .{ .frames = .one });
    const step = s.decode(in[0..in_len], out[0..out_len]) catch return -1;
    s.finish() catch return -1;
    s.reset();
    var input: std.Io.Reader = .fixed(in[0..in_len]);
    var adapter: warp.zstd.Decompress.Reader = .init(&input, &memory, .{ .frames = .one });
    adapter.interface.readSliceAll(out[0..step.out_len]) catch return -1;
    _ = adapter.interface.takeByte() catch |err| {
        if (err != error.EndOfStream or adapter.err() != null) return -1;
        return @intCast(step.out_len);
    };
    return -1;
}

/// Parallel job storage and both inputs with an Io supplied by the caller.
export fn warpZstdParallel(io: *const std.Io, in: [*]const u8, in_len: usize, out: [*]u8, out_len: usize, rsyncable: bool) isize {
    const options: warp.zstd.parallel.Options = .{ .job_len = 1024, .concurrency = 1, .tuning = .{ .window_log = 10 }, .rsyncable = rsyncable };
    const size = warp.zstd.parallel.Compressor.memory(options);
    if (size > memory.len) return -1;
    var p = warp.zstd.parallel.Compressor.initBuffer(memory[0..size], options);
    defer p.deinit();
    var sink: std.Io.Writer = .fixed(out[0..out_len]);
    p.compress(io.*, in[0..in_len], &sink) catch return -1;
    sink = .fixed(out[0..out_len]);
    var reader: std.Io.Reader = .fixed(in[0..in_len]);
    p.compressReader(io.*, &reader, &sink) catch return -1;
    return @intCast(sink.buffered().len);
}

/// Pipelined block entropy and ordered history execution on every target.
export fn warpZstdPipeline(io: *const std.Io, in: [*]const u8, in_len: usize, out: [*]u8, out_len: usize, partial: bool) isize {
    const options: warp.zstd.parallel.Decompressor.Options = .{ .concurrency = 1 };
    const size = warp.zstd.parallel.Decompressor.memory(options);
    if (size > pipeline_memory.len) return -1;
    var d = warp.zstd.parallel.Decompressor.initBuffer(pipeline_memory[0..size], options);
    defer d.deinit();
    const result = d.decompress(io.*, in[0..in_len], out[0..out_len], .{ .partial = partial }) catch return -1;
    return @intCast(result.out_len);
}
