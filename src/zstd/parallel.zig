//! Ordered compression jobs in one frame. Each worker owns its match and
//! entropy state; job boundaries and overlap do not depend on concurrency.
const std = @import("std");
const Io = std.Io;
const Encoder = @import("Encoder.zig");
const Dictionary = @import("Dictionary.zig");
const seekable = @import("seekable.zig");

/// Pipelined entropy decoding with ordered history execution.
pub const Decompressor = @import("parallel/Decompressor.zig");

/// Job sizing and the frame written around the ordered blocks.
pub const Options = struct {
    level: i32 = 3,
    tuning: Encoder.Tuning = .{},
    dictionary: ?*const Dictionary = null,
    frame: Encoder.Frame = .{},
    job_len: ?u32 = null,
    overlap_log: u4 = 0,
    rsyncable: bool = false,
    concurrency: u16 = 8,
};

const Config = struct {
    params: Encoder.Params,
    encoder: Encoder.Options,
    job_len: usize,
    overlap: usize,
    output_len: usize,
};

fn config(options: Options) error{InvalidOptions}!Config {
    if (options.concurrency == 0 or options.overlap_log > 9) return error.InvalidOptions;
    const encoder: Encoder.Options = .{ .level = options.level, .tuning = options.tuning, .dictionary = options.dictionary };
    const p = Encoder.resolve(encoder, null);
    const job_log = @max(20, @as(u6, p.window_log) + 2);
    const max_job_log: u6 = if (@bitSizeOf(usize) == 32) 29 else 30;
    const job: usize = options.job_len orelse (@as(u32, 1) << @intCast(@min(job_log, max_job_log)));
    const default_overlap: u4 = switch (p.strategy) {
        .btultra2 => 9,
        .btultra, .btopt => 8,
        .btlazy2, .lazy2 => 7,
        else => 6,
    };
    const log = if (options.overlap_log == 0) default_overlap else options.overlap_log;
    const overlap: usize = if (log == 1) 0 else @as(usize, 1) << (p.window_log -| (9 - log));
    if (job == 0 or job > @as(usize, 1) << max_job_log or @as(u64, job) + overlap > std.math.maxInt(u32) - 3) return error.InvalidOptions;
    const blocks = std.math.divCeil(usize, job, @min(8 << 10, @as(usize, 1) << p.window_log)) catch unreachable; // unreachable: the block size is nonzero
    return .{ .params = p, .encoder = encoder, .job_len = job, .overlap = overlap, .output_len = @max(job + 591 * blocks, Encoder.bound(job)) };
}

const Worker = struct {
    encoder: Encoder,
    input: []u8,
    output: []u8,
    bytes: []const u8 = &.{},
    prefix: usize = 0,
    first: bool = false,
    result: usize = 0,

    fn frame(w: *Worker, options: Encoder.Frame) void {
        w.result = w.encoder.compress(w.bytes, w.output, options) catch unreachable; // unreachable: output holds the whole-buffer bound
    }

    fn run(w: *Worker, params: Encoder.Params) void {
        w.result = w.encoder.job(params, w.bytes, w.prefix, w.first, w.output) catch unreachable; // unreachable: each block reserves raw bytes plus all possible partition headers
    }
};

const Cuts = struct {
    rolling: u64 = 0,
    ring: [64]u8 = @splat(0),
    at: u6 = 0,
    count: usize = 0,

    fn value(byte: u8) u64 {
        var x = @as(u64, byte) + 0x9e3779b97f4a7c15;
        x = (x ^ (x >> 30)) *% 0xbf58476d1ce4e5b9;
        x = (x ^ (x >> 27)) *% 0x94d049bb133111eb;
        return x ^ (x >> 31);
    }

    fn take(c: *Cuts, in: []const u8, cfg: Config, rsyncable: bool) usize {
        const n = @min(in.len, cfg.job_len - c.count);
        if (!rsyncable) {
            c.count += n;
            return n;
        }
        const mask = std.math.ceilPowerOfTwo(usize, @max(2, cfg.job_len / 2)) catch unreachable; // unreachable: job lengths are at most 2^30
        for (in[0..n], 0..) |byte, i| {
            c.rolling = std.math.rotl(u64, c.rolling, 1) ^ value(byte) ^ value(c.ring[c.at]);
            c.ring[c.at] = byte;
            c.at +%= 1;
            c.count += 1;
            if (c.count >= @max(64, cfg.job_len / 2) and c.rolling & (mask - 1) == 0) return i + 1;
        }
        return n;
    }
};

const Source = struct {
    reader: *Io.Reader,
    bytes: [4096]u8 = undefined,
    at: usize = 0,
    end: usize = 0,
    eof: bool = false,

    fn peek(source: *Source) error{ReadFailed}![]const u8 {
        if (source.at == source.end and !source.eof) {
            source.end = try source.reader.readSliceShort(&source.bytes);
            source.at = 0;
            source.eof = source.end < source.bytes.len;
        }
        return source.bytes[source.at..source.end];
    }
};

/// Reusable worker state; one allocation and no codec allocations per call.
pub const Compressor = struct {
    options: Options,
    cfg: Config,
    workers: []Worker,
    history: []u8,
    owned: []align(64) u8 = &.{},
    gpa: std.mem.Allocator = undefined,

    pub const InitError = std.mem.Allocator.Error || error{InvalidOptions};
    pub const Error = Io.Writer.Error || Io.Cancelable || error{InvalidOptions};

    /// Exact worker, overlap, input and output storage; maxInt means it cannot fit.
    pub fn memory(options: Options) usize {
        const cfg = config(options) catch return std.math.maxInt(usize);
        const enc = Encoder.memory(cfg.encoder);
        const head = std.mem.alignForward(usize, @sizeOf(Worker) * @as(usize, options.concurrency), 64);
        const stride = enc +| std.mem.alignForward(usize, cfg.job_len + cfg.overlap + cfg.output_len, 64);
        const size = head +| stride *| @as(usize, options.concurrency) +| cfg.overlap;
        if (size > std.math.maxInt(usize) - 63) return std.math.maxInt(usize);
        return std.mem.alignForward(usize, size, 64);
    }

    pub fn init(gpa: std.mem.Allocator, options: Options) InitError!Compressor {
        _ = try config(options);
        const size = memory(options);
        if (size == std.math.maxInt(usize)) return error.OutOfMemory;
        const buffer = try gpa.alignedAlloc(u8, .@"64", size);
        var p = initBuffer(buffer, options);
        p.owned = buffer;
        p.gpa = gpa;
        return p;
    }

    /// Caller storage must hold `memory(options)` bytes and valid options.
    pub fn initBuffer(buffer: []align(64) u8, options: Options) Compressor {
        std.debug.assert(buffer.len >= memory(options));
        const cfg = config(options) catch unreachable; // unreachable: valid options are a caller precondition
        const workers: []Worker = @alignCast(std.mem.bytesAsSlice(Worker, buffer[0 .. @sizeOf(Worker) * @as(usize, options.concurrency)])); // safe: buffer is 64-byte aligned
        var at = std.mem.alignForward(usize, @sizeOf(Worker) * workers.len, 64);
        const enc_size = Encoder.memory(cfg.encoder);
        for (workers) |*w| {
            w.* = .{ .encoder = .initBuffer(@alignCast(buffer[at..][0..enc_size]), cfg.encoder), .input = buffer[at + enc_size ..][0 .. cfg.job_len + cfg.overlap], .output = buffer[at + enc_size + cfg.job_len + cfg.overlap ..][0..cfg.output_len] }; // safe: each worker starts at a 64-byte boundary
            at += enc_size + std.mem.alignForward(usize, cfg.job_len + cfg.overlap + cfg.output_len, 64);
        }
        return .{ .options = options, .cfg = cfg, .workers = workers, .history = buffer[at..][0..cfg.overlap] };
    }

    pub fn deinit(p: *Compressor) void {
        if (p.owned.len != 0) p.gpa.free(p.owned);
        p.* = undefined;
    }

    fn header(p: *Compressor, out: *Io.Writer, size: ?usize) Error!void {
        var bytes: [18]u8 = undefined;
        var frame = p.options.frame;
        if (size == null) frame.content_size = false;
        const n = p.workers[0].encoder.header(&bytes, p.cfg.params, size orelse 0, frame) catch unreachable; // unreachable: bytes holds the maximum header size
        try out.writeAll(bytes[0..n]);
    }

    fn trailer(p: *Compressor, out: *Io.Writer, hash: *std.hash.XxHash64) Error!void {
        try out.writeAll(&.{ 1, 0, 0 });
        if (p.options.frame.checksum) {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, @truncate(hash.final()), .little);
            try out.writeAll(&bytes);
        }
    }

    fn drain(p: *Compressor, io: Io, group: *Io.Group, count: usize, out: *Io.Writer) Error!void {
        try group.await(io);
        for (p.workers[0..count]) |*w| try out.writeAll(w.output[0..w.result]);
    }

    /// Compress borrowed input into one frame, writing jobs in input order.
    pub fn compress(p: *Compressor, io: Io, in: []const u8, out: *Io.Writer) Error!void {
        try p.header(out, in.len);
        var group: Io.Group = .init;
        defer group.cancel(io);
        var hash: std.hash.XxHash64 = .init(0);
        var cuts: Cuts = .{};
        var at: usize = 0;
        while (at < in.len) {
            var count: usize = 0;
            while (count < p.workers.len and at < in.len) : (count += 1) {
                const w = &p.workers[count];
                const n = cuts.take(in[at..], p.cfg, p.options.rsyncable);
                const prefix = @min(at, p.cfg.overlap);
                w.bytes = in[at - prefix ..][0 .. prefix + n];
                w.prefix = prefix;
                w.first = at == 0;
                if (p.options.frame.checksum) hash.update(in[at..][0..n]);
                if (p.workers.len == 1) w.run(p.cfg.params) else group.async(io, Worker.run, .{ w, p.cfg.params });
                at += n;
                cuts.count = 0;
            }
            try p.drain(io, &group, count, out);
        }
        try p.trailer(out, &hash);
    }

    /// Write independent frames and their seek table, reusing these workers.
    /// `frame_len` is at most the configured job length; `records` holds every
    /// frame (including one empty frame for empty input). Returns their count.
    pub fn writeSeekable(p: *Compressor, io: Io, in: []const u8, out: *Io.Writer, records: []seekable.Record, frame_len: u32, checksum: bool) (Error || error{TooManyFrames})!usize {
        if (frame_len == 0 or frame_len > p.cfg.job_len) return error.InvalidOptions;
        const total = @max(1, std.math.divCeil(usize, in.len, frame_len) catch unreachable); // unreachable: frame_len is nonzero
        if (total > records.len or total > (std.math.maxInt(u32) - 9) / 12) return error.TooManyFrames;
        var group: Io.Group = .init;
        defer group.cancel(io);
        var at: usize = 0;
        var count: usize = 0;
        var frame_options = p.options.frame;
        frame_options.format = .standard;
        frame_options.content_size = true;
        while (count < total) {
            const batch = @min(p.workers.len, total - count);
            for (p.workers[0..batch]) |*w| {
                const n = @min(in.len - at, frame_len);
                w.bytes = in[at..][0..n];
                if (p.workers.len == 1) w.frame(frame_options) else group.async(io, Worker.frame, .{ w, frame_options });
                at += n;
            }
            try group.await(io);
            for (p.workers[0..batch], records[count..][0..batch]) |*w, *record| {
                try out.writeAll(w.output[0..w.result]);
                record.* = .{ .compressed = @intCast(w.result), .decompressed = @intCast(w.bytes.len), .checksum = if (checksum) @truncate(std.hash.XxHash64.hash(0, w.bytes)) else 0 };
            }
            count += batch;
        }
        try seekable.writeTable(out, records[0..count], checksum);
        return count;
    }

    /// Stream independent frames and a seek table into `out`, using bounded
    /// worker input buffers. Returns the number of records written.
    pub fn writeSeekableReader(p: *Compressor, io: Io, in: *Io.Reader, out: *Io.Writer, records: []seekable.Record, frame_len: u32, checksum: bool) (Error || error{ TooManyFrames, ReadFailed })!usize {
        if (frame_len == 0 or frame_len > p.cfg.job_len) return error.InvalidOptions;
        var group: Io.Group = .init;
        defer group.cancel(io);
        var count: usize = 0;
        var eof = false;
        var frame_options = p.options.frame;
        frame_options.format = .standard;
        frame_options.content_size = true;
        while (!eof) {
            var batch: usize = 0;
            while (batch < p.workers.len) {
                const w = &p.workers[batch];
                const n = try in.readSliceShort(w.input[0..frame_len]);
                eof = n < frame_len;
                if (n == 0 and count + batch != 0) break;
                if (count + batch >= records.len or count + batch >= (std.math.maxInt(u32) - 9) / 12) return error.TooManyFrames;
                w.bytes = w.input[0..n];
                if (p.workers.len == 1) w.frame(frame_options) else group.async(io, Worker.frame, .{ w, frame_options });
                batch += 1;
                if (eof) break;
            }
            try group.await(io);
            for (p.workers[0..batch], records[count..][0..batch]) |*w, *record| {
                try out.writeAll(w.output[0..w.result]);
                record.* = .{ .compressed = @intCast(w.result), .decompressed = @intCast(w.bytes.len), .checksum = if (checksum) @truncate(std.hash.XxHash64.hash(0, w.bytes)) else 0 };
            }
            count += batch;
        }
        try seekable.writeTable(out, records[0..count], checksum);
        return count;
    }

    /// Stream jobs from a reader; its frame omits the unknown content size.
    pub fn compressReader(p: *Compressor, io: Io, in: *Io.Reader, out: *Io.Writer) (Error || error{ReadFailed})!void {
        try p.header(out, null);
        var group: Io.Group = .init;
        defer group.cancel(io);
        var hash: std.hash.XxHash64 = .init(0);
        var cuts: Cuts = .{};
        var history: usize = 0;
        var first = true;
        var source: Source = .{ .reader = in };
        var eof = false;
        while (!eof) {
            var count: usize = 0;
            while (count < p.workers.len) : (count += 1) {
                const w = &p.workers[count];
                @memcpy(w.input[0..history], p.history[0..history]);
                const n = try p.fill(&source, w.input[history..], &cuts, &eof);
                if (n == 0) break;
                w.bytes = w.input[0 .. history + n];
                w.prefix = history;
                w.first = first;
                first = false;
                if (p.options.frame.checksum) hash.update(w.bytes[history..]);
                history = @min(w.bytes.len, p.cfg.overlap);
                @memcpy(p.history[0..history], w.bytes[w.bytes.len - history ..]);
                if (p.workers.len == 1) w.run(p.cfg.params) else group.async(io, Worker.run, .{ w, p.cfg.params });
                if (eof) {
                    count += 1;
                    break;
                }
            }
            try p.drain(io, &group, count, out);
        }
        try p.trailer(out, &hash);
    }

    fn fill(p: *Compressor, source: *Source, out: []u8, cuts: *Cuts, eof: *bool) error{ReadFailed}!usize {
        cuts.count = 0;
        while (cuts.count < p.cfg.job_len) {
            const bytes = try source.peek();
            if (bytes.len == 0) {
                eof.* = true;
                return cuts.count;
            }
            const at = cuts.count;
            const n = cuts.take(bytes, p.cfg, p.options.rsyncable);
            @memcpy(out[at..][0..n], bytes[0..n]);
            source.at += n;
            if (p.options.rsyncable and cuts.count >= @max(64, p.cfg.job_len / 2)) {
                const mask = std.math.ceilPowerOfTwo(usize, @max(2, p.cfg.job_len / 2)) catch unreachable; // unreachable: job lengths are at most 2^30
                if (cuts.rolling & (mask - 1) == 0) break;
            }
        }
        return cuts.count;
    }
};
