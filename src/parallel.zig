//! Chunked compression into one standard stream. Workers have disjoint
//! engines and buffers; only the caller writes the chunks, in input order.
const std = @import("std");
const Io = std.Io;
const deflate = @import("deflate.zig");
const bits = @import("bits.zig");
const match = @import("match.zig");
const checksum = @import("checksum.zig");
const container = @import("container.zig");
const gzip = @import("gzip.zig");
const FrameCompressor = @import("Compressor.zig");

pub const Options = struct {
    level: u4 = 6,
    strategy: deflate.Strategy = .default,
    container: container.Container = .gzip,
    gzip: gzip.Header = .{},
    chunk_len: u32 = 128 << 10,
    independent: bool = false,
    concurrency: u16 = 8,
    /// Extra optimization passes at levels 10-12.
    passes: ?u32 = null,
};

const Worker = struct {
    engine: deflate.Engine,
    input: []u8,
    output: []u8,
    dictionary: []u8,
    in_len: usize = 0,
    dict_len: usize = 0,
    out_len: usize = 0,
    check: u32 = 0,
    final: bool = false,
};

pub const Compressor = struct {
    options: Options,
    workers: []Worker,
    history: []u8,
    history_len: usize = 0,
    owned: []align(64) u8,
    gpa: std.mem.Allocator,

    pub fn memory(options: Options) usize {
        std.debug.assert(options.chunk_len > 0);
        std.debug.assert(options.concurrency > 0);
        const sizes = deflate.Sizes.of(options.level, options.strategy, options.chunk_len);
        return stride(options, sizes) * options.concurrency + 32768;
    }

    fn stride(options: Options, sizes: deflate.Sizes) usize {
        return std.mem.alignForward(usize, @sizeOf(Worker), 64) +
            std.mem.alignForward(usize, sizes.memory(), 64) + 32768 +
            std.mem.alignForward(usize, options.chunk_len, 64) +
            std.mem.alignForward(usize, FrameCompressor.bound(options.chunk_len, .{ .container = .raw }) + 8, 64);
    }

    pub fn init(gpa: std.mem.Allocator, options: Options) std.mem.Allocator.Error!Compressor {
        const owned = try gpa.alignedAlloc(u8, .@"64", memory(options));
        var p = initBuffer(owned, options);
        p.owned = owned;
        p.gpa = gpa;
        return p;
    }

    /// Caller memory, aligned to 64 bytes; deinit frees nothing.
    pub fn initBuffer(buffer: []align(64) u8, options: Options) Compressor {
        std.debug.assert(buffer.len >= memory(options));
        const owned = buffer[0..memory(options)];
        const sizes = deflate.Sizes.of(options.level, options.strategy, options.chunk_len);
        const step = stride(options, sizes);
        // Worker records are kept contiguously at the front. All engine
        // regions start after the records, at a 64-byte boundary.
        const record_bytes = std.mem.alignForward(usize, @sizeOf(Worker), 64) * options.concurrency;
        const records: []Worker = @as([*]Worker, @ptrCast(owned.ptr))[0..options.concurrency]; // safe: owned is 64-byte aligned and reserves record_bytes for these workers
        var at = record_bytes;
        for (records) |*worker| {
            const engine_len = std.mem.alignForward(usize, sizes.memory(), 64);
            const engine_buffer: []align(64) u8 = @alignCast(owned[at..][0..engine_len]); // safe: each region is padded to 64 bytes
            at += engine_len;
            const dictionary = owned[at..][0..32768];
            at += 32768;
            const input = owned[at..][0..options.chunk_len];
            at += std.mem.alignForward(usize, options.chunk_len, 64);
            const output_len = std.mem.alignForward(usize, FrameCompressor.bound(options.chunk_len, .{ .container = .raw }) + 8, 64);
            worker.* = .{ .engine = .init(engine_buffer, sizes), .input = input, .dictionary = dictionary, .output = owned[at..][0..output_len] };
            at += output_len;
        }
        std.debug.assert(at == step * options.concurrency);
        return .{ .options = options, .workers = records, .history = owned[at..][0..32768], .owned = &.{}, .gpa = undefined };
    }

    pub fn deinit(p: *Compressor) void {
        if (p.owned.len != 0) p.gpa.free(p.owned);
        p.* = undefined;
    }

    pub const Error = Io.Writer.Error || Io.Cancelable;
    pub const ReadError = Error || error{ReadFailed};

    /// One stream; chunk boundaries and bytes do not depend on concurrency.
    pub fn compress(p: *Compressor, io: Io, in: []const u8, out: *Io.Writer) Error!void {
        var reader: Io.Reader = .fixed(in);
        p.compressReader(io, &reader, out) catch |err| switch (err) {
            error.ReadFailed => unreachable, // unreachable: a fixed reader cannot fail
            else => |e| return e,
        };
    }

    pub fn compressReader(p: *Compressor, io: Io, in: *Io.Reader, out: *Io.Writer) ReadError!void {
        p.history_len = 0;
        try p.header(out);
        var total: u64 = 0;
        var check: u32 = if (p.options.container == .zlib) 1 else 0;
        var final = false;
        while (!final) {
            var group: Io.Group = .init;
            defer group.cancel(io);
            var count: usize = 0;
            for (p.workers) |*worker| {
                worker.in_len = try in.readSliceShort(worker.input);
                final = worker.in_len < worker.input.len;
                if (!final) {
                    _ = in.peekByte() catch |err| switch (err) {
                        error.EndOfStream => final = true,
                        error.ReadFailed => return error.ReadFailed,
                    };
                }
                worker.final = final;
                worker.dict_len = if (p.options.independent) 0 else p.history_len;
                @memcpy(worker.dictionary[0..worker.dict_len], p.history[0..worker.dict_len]);
                p.remember(worker.input[0..worker.in_len]);
                group.async(io, run, .{ worker, p.options });
                count += 1;
                if (final) break;
            }
            try group.await(io);
            for (p.workers[0..count]) |*worker| {
                try out.writeAll(worker.output[0..worker.out_len]);
                check = switch (p.options.container) {
                    .raw => 0,
                    .zlib => checksum.adler32Combine(check, worker.check, worker.in_len),
                    .gzip => checksum.crc32Combine(check, worker.check, worker.in_len),
                };
                total += worker.in_len;
            }
        }
        var trailer: [8]u8 = undefined;
        switch (p.options.container) {
            .raw => {},
            .zlib => {
                std.mem.writeInt(u32, trailer[0..4], check, .big);
                try out.writeAll(trailer[0..4]);
            },
            .gzip => {
                std.mem.writeInt(u32, trailer[0..4], check, .little);
                std.mem.writeInt(u32, trailer[4..8], @truncate(total), .little);
                try out.writeAll(&trailer);
            },
        }
    }

    fn remember(p: *Compressor, bytes: []const u8) void {
        if (bytes.len >= p.history.len) {
            @memcpy(p.history, bytes[bytes.len - p.history.len ..]);
            p.history_len = p.history.len;
        } else {
            const kept = @min(p.history_len, p.history.len - bytes.len);
            @memmove(p.history[0..kept], p.history[p.history_len - kept .. p.history_len]);
            @memcpy(p.history[kept..][0..bytes.len], bytes);
            p.history_len = kept + bytes.len;
        }
    }

    fn header(p: *const Compressor, out: *Io.Writer) Io.Writer.Error!void {
        switch (p.options.container) {
            .raw => {},
            .zlib => {
                var bytes: [6]u8 = undefined;
                const n = container.zlibHeader(15, p.options.level, p.options.strategy == .huffman_only, null, &bytes);
                try out.writeAll(bytes[0..n]);
            },
            .gzip => {
                var header_ = p.options.gzip;
                if (header_.xfl == null) header_.xfl = if (p.options.level >= 9) 2 else if (p.options.level == 1) 4 else 0;
                try gzip.writeHeader(out, header_);
            },
        }
    }
};

fn run(worker: *Worker, options: Options) void {
    const in = worker.input[0..worker.in_len];
    const history: match.History = .{ .in = in, .dict = worker.dictionary[0..worker.dict_len] };
    var writer: bits.Writer = .init(worker.output, 0);
    worker.engine.start(history, 0, in.len + history.dict.len, options.level, options.strategy);
    if (options.passes) |passes| worker.engine.setPasses(passes);
    while (worker.engine.parse(false, history, &writer, if (worker.final) .final else .flush) == .block) {}
    if (!worker.final) {
        // Empty stored block: the next worker starts on a byte boundary.
        writer.add(0, 3);
        writer.alignToByte();
        writer.add(0, 16);
        writer.add(65535, 16);
    }
    writer.alignToByte();
    std.debug.assert(!writer.overflow);
    worker.out_len = writer.at;
    worker.check = switch (options.container) {
        .raw => 0,
        .zlib => checksum.adler32(1, in),
        .gzip => checksum.crc32(0, in),
    };
}

const Inflate = @import("stream/Inflate.zig");
const Index = @import("Index.zig");

/// Decode indexed regions concurrently into disjoint caller slices. An
/// index is built and validated separately; reuse it for repeated reads.
pub const Decompressor = struct {
    workers: []DecodeWorker,
    gpa: std.mem.Allocator,
    owned: bool = false,

    pub const Options = struct { concurrency: u16 = 8 };
    pub const DecodeError = Inflate.DecodeError || Io.Cancelable || error{ OutputTooSmall, InvalidIndex, Truncated };

    pub fn memory(options: Decompressor.Options) usize {
        std.debug.assert(options.concurrency > 0);
        return @as(usize, @sizeOf(DecodeWorker)) * options.concurrency;
    }

    pub fn init(gpa: std.mem.Allocator, options: Decompressor.Options) std.mem.Allocator.Error!Decompressor {
        std.debug.assert(options.concurrency > 0);
        return .{ .workers = try gpa.alloc(DecodeWorker, options.concurrency), .gpa = gpa, .owned = true };
    }

    /// Caller memory, aligned to 64 bytes; deinit frees nothing.
    pub fn initBuffer(buffer: []align(64) u8, options: Decompressor.Options) Decompressor {
        std.debug.assert(buffer.len >= memory(options));
        return .{ .workers = @as([*]DecodeWorker, @ptrCast(buffer.ptr))[0..options.concurrency], .gpa = undefined }; // safe: buffer is aligned and holds memory(options) bytes
    }

    pub fn deinit(p: *Decompressor) void {
        if (p.owned) p.gpa.free(p.workers);
        p.* = undefined;
    }

    /// The index must describe this stream. Every region verifies its
    /// ending checksum against the next checkpoint or the stream trailer.
    pub fn decompress(p: *Decompressor, io: Io, in: []const u8, out: []u8, index: *const Index) DecodeError!usize {
        if (index.in_len > in.len) return error.InvalidIndex;
        if (index.out_len > out.len) return error.OutputTooSmall;
        var region: usize = 0;
        while (region <= index.points.len) {
            const count = @min(p.workers.len, index.points.len + 1 - region);
            var group: Io.Group = .init;
            defer group.cancel(io);
            for (p.workers[0..count], region..) |*worker, k| {
                const start: u64 = if (k == 0) 0 else index.points[k - 1].out_offset;
                const end: u64 = if (k == index.points.len) index.out_len else index.points[k].out_offset;
                if (start > end or end > out.len) return error.InvalidIndex;
                worker.input = in[0..@intCast(index.in_len)];
                worker.output = out[@intCast(start)..@intCast(end)];
                worker.start = if (k == 0) null else &index.points[k - 1];
                worker.end = if (k == index.points.len) null else &index.points[k];
                worker.accept = index.accept;
                worker.failed = null;
                group.async(io, decodeRegion, .{worker});
            }
            try group.await(io);
            for (p.workers[0..count]) |*worker| if (worker.failed) |err| return err;
            region += count;
        }
        return @intCast(index.out_len);
    }
};

const DecodeWorker = struct {
    window: [32768]u8,
    input: []const u8,
    output: []u8,
    start: ?*const Inflate.Checkpoint,
    end: ?*const Inflate.Checkpoint,
    accept: container.Accept,
    failed: ?Decompressor.DecodeError,
};

fn decodeRegion(worker: *DecodeWorker) void {
    decodeRegionInner(worker) catch |err| {
        worker.failed = err;
    };
}

fn decodeRegionInner(worker: *DecodeWorker) Decompressor.DecodeError!void {
    var z: Inflate = .init(&worker.window, .{ .accept = worker.accept });
    var at: usize = 0;
    if (worker.start) |point| {
        if (point.in_offset > worker.input.len) return error.InvalidIndex;
        z.@"resume"(point) catch return error.InvalidIndex;
        at = @intCast(point.in_offset);
    }
    var written: usize = 0;
    while (true) {
        const step = try z.decode(worker.input[at..], worker.output[written..]);
        at += step.in_len;
        written += step.out_len;
        if (worker.end) |point| {
            if (written == worker.output.len) {
                if (z.state.check != point.check or z.state.size != point.size) return error.InvalidIndex;
                return;
            }
        }
        if (step.status == .done or (step.status == .member_end and at == worker.input.len)) {
            if (written != worker.output.len or worker.end != null) return error.InvalidIndex;
            return;
        }
        if (step.status == .need_input and at == worker.input.len) return error.Truncated;
        if (step.status == .output_full and worker.end == null) return error.OutputTooSmall;
    }
}
