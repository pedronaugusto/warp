//! Ordered compression jobs in one frame. Each worker owns its match and
//! entropy state; job boundaries and overlap do not depend on concurrency.
const std = @import("std");
const aegis = @import("aegis");
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
    /// One job's input; null sizes it from the window.
    job_len: ?aegis.units.Bytes(u32) = null,
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
    /// An rsyncable cut falls where the rolling hash has these low bits
    /// clear: half a job, rounded up to a power of two.
    rsync_mask: usize,
};

fn config(options: Options) error{InvalidOptions}!Config {
    if (options.concurrency == 0 or options.overlap_log > 9) return error.InvalidOptions;
    const encoder: Encoder.Options = .{ .level = options.level, .tuning = options.tuning, .dictionary = options.dictionary };
    const p = Encoder.resolve(encoder, null);
    const job_log = @max(20, @as(u6, p.window_log) + 2);
    const max_job_log: u6 = if (@bitSizeOf(usize) == 32) 29 else 30;
    const job_len: aegis.units.Bytes(u32) = options.job_len orelse .fromRaw(@as(u32, 1) << @intCast(@min(job_log, max_job_log)));
    const default_overlap: u4 = switch (p.strategy) {
        .btultra2 => 9,
        .btultra, .btopt => 8,
        .btlazy2, .lazy2 => 7,
        else => 6,
    };
    const log = if (options.overlap_log == 0) default_overlap else options.overlap_log;
    const overlap: usize = if (log == 1) 0 else @as(usize, 1) << (p.window_log -| (9 - log));
    if (job_len.eql(.fromRaw(0)) or job_len.compare(.fromRaw(@as(u32, 1) << max_job_log)) == .gt) return error.InvalidOptions;
    const span = aegis.units.Bytes(u64).fromRaw(job_len.raw()).add(.fromRaw(overlap)) catch return error.InvalidOptions;
    if (span.compare(.fromRaw(std.math.maxInt(u32) - 3)) == .gt) return error.InvalidOptions;
    const job: usize = job_len.raw();
    const blocks = std.math.divCeil(usize, job, @min(8 << 10, @as(usize, 1) << p.window_log)) catch unreachable; // unreachable: the block size is nonzero
    const coded = aegis.units.Bytes(usize).fromRaw(job).add(.fromRaw(591 * blocks)) catch return error.InvalidOptions;
    const bound: aegis.units.Bytes(usize) = .fromRaw(Encoder.bound(job));
    // At most 2^29 (job_len is at most 2^30), within any usize.
    const rsync_mask: usize = @intCast(std.math.ceilPowerOfTwoPromote(u32, @max(2, job_len.raw() / 2)));
    return .{ .params = p, .encoder = encoder, .job_len = job, .overlap = overlap, .output_len = (if (coded.compare(bound) == .lt) bound else coded).raw(), .rsync_mask = rsync_mask };
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
        w.result = w.encoder.compress(w.bytes, w.output, options) catch aegis.assert.never("output is config's output_len, at least Encoder.bound(job_len), and bytes are at most job_len");
    }

    fn run(w: *Worker, params: Encoder.Params) void {
        w.result = w.encoder.job(params, w.bytes, w.prefix, w.first, w.output) catch aegis.assert.never("output is config's output_len, at least job_len + 591 per block: the raw bytes and 197 partition headers of 3");
    }
};

const Job = struct { group: Io.Group align(64) = .init };

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
        const mask = cfg.rsync_mask;
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
    jobs: []Job,
    history: []u8,
    owned: []align(64) u8 = &.{},
    gpa: std.mem.Allocator = undefined,

    pub const InitError = std.mem.Allocator.Error || error{InvalidOptions};
    pub const Error = Io.Writer.Error || Io.Cancelable || error{InvalidOptions};

    /// The workers' records, each worker's encoder, input and output, the
    /// overlap's history and the jobs, one block.
    const Parts = struct { workers: []align(64) Worker, buffers: aegis.parts.Repeat(WorkerParts), history: []u8, jobs: []align(64) Job };
    const WorkerParts = struct { encoder: Encoder.Parts, input: []u8, output: []u8 };
    const Block = aegis.parts.Block(Parts);

    fn plan(options: Options, cfg: Config) Block.Plan {
        const each: aegis.parts.Counts(WorkerParts) = .{ .encoder = Encoder.counts(cfg.encoder), .input = cfg.job_len + cfg.overlap, .output = cfg.output_len };
        return Block.plan(.{ .workers = options.concurrency, .buffers = .{ .len = options.concurrency, .each = each }, .history = cfg.overlap, .jobs = options.concurrency });
    }

    /// Exact worker, overlap, input and output storage; maxInt means it cannot fit.
    pub fn memory(options: Options) usize {
        const cfg = config(options) catch return std.math.maxInt(usize);
        return (plan(options, cfg).size() catch return std.math.maxInt(usize)).raw();
    }

    pub fn init(gpa: std.mem.Allocator, options: Options) InitError!Compressor {
        const cfg = try config(options);
        const held = try plan(options, cfg).alloc(gpa);
        var p = assemble(held, options, cfg);
        p.owned = held.bytes();
        p.gpa = gpa;
        return p;
    }

    /// Caller storage, refused when the options are not valid or it is
    /// shorter than `memory(options)`.
    pub fn initBuffer(buffer: []align(64) u8, options: Options) error{ InvalidOptions, BufferTooSmall }!Compressor {
        const cfg = try config(options);
        return assemble(try plan(options, cfg).fit(buffer), options, cfg);
    }

    /// The one core of `init` and `initBuffer`: a block holds its parts.
    fn assemble(held: Block, options: Options, cfg: Config) Compressor {
        const p = held.parts();
        for (p.workers, 0..) |*w, i| {
            const b = p.buffers.at(i);
            w.* = .{ .encoder = .fromParts(b.encoder, cfg.encoder), .input = b.input, .output = b.output };
        }
        for (p.jobs) |*job| job.* = .{};
        return .{ .options = options, .cfg = cfg, .workers = p.workers, .jobs = p.jobs, .history = p.history };
    }

    pub fn deinit(p: *Compressor) void {
        if (p.owned.len != 0) p.gpa.free(p.owned);
        p.* = undefined;
    }

    fn header(p: *Compressor, out: *Io.Writer, size: ?usize) Error!void {
        var bytes: [18]u8 = undefined;
        var frame = p.options.frame;
        if (size == null) frame.content_size = false;
        const n = p.workers[0].encoder.header(&bytes, p.cfg.params, size orelse 0, frame) catch aegis.assert.never("bytes holds the maximum header size");
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

    fn queue(p: *Compressor, io: Io, w: *Worker, group: *Io.Group) void {
        if (p.workers.len == 1) w.run(p.cfg.params) else group.async(io, Worker.run, .{ w, p.cfg.params });
    }

    fn borrow(p: *Compressor, io: Io, w: *Worker, in: []const u8, at: *usize, cuts: *Cuts, hash: *std.hash.XxHash64, group: *Io.Group) void {
        const n = cuts.take(in[at.*..], p.cfg, p.options.rsyncable);
        const prefix = @min(at.*, p.cfg.overlap);
        w.bytes = in[at.* - prefix ..][0 .. prefix + n];
        w.prefix = prefix;
        w.first = at.* == 0;
        if (p.options.frame.checksum) hash.update(in[at.*..][0..n]);
        p.queue(io, w, group);
        at.* += n;
        cuts.count = 0;
    }

    fn drain(p: *Compressor, io: Io, group: *Io.Group, count: usize, out: *Io.Writer) Error!void {
        try group.await(io);
        for (p.workers[0..count]) |*w| try out.writeAll(w.output[0..w.result]);
    }

    fn compressBatch(p: *Compressor, io: Io, in: []const u8, out: *Io.Writer) Error!void {
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

    /// Compress borrowed input into one frame, writing jobs in input order.
    pub fn compress(p: *Compressor, io: Io, in: []const u8, out: *Io.Writer) Error!void {
        if (!p.options.rsyncable and in.len <= p.cfg.job_len *| p.workers.len) return p.compressBatch(io, in, out);
        try p.header(out, in.len);
        defer for (p.jobs) |*job| job.group.cancel(io);
        var hash: std.hash.XxHash64 = .init(0);
        var cuts: Cuts = .{};
        var at: usize = 0;
        var pending: usize = 0;
        for (p.workers, p.jobs) |*w, *job| {
            if (at == in.len) break;
            p.borrow(io, w, in, &at, &cuts, &hash, &job.group);
            pending += 1;
        }
        var current: usize = 0;
        while (pending != 0) {
            const w = &p.workers[current];
            try p.jobs[current].group.await(io);
            try out.writeAll(w.output[0..w.result]);
            if (at < in.len) p.borrow(io, w, in, &at, &cuts, &hash, &p.jobs[current].group) else pending -= 1;
            current = (current + 1) % p.workers.len;
        }
        try p.trailer(out, &hash);
    }

    /// A seekable frame's input length: at least a byte, at most the configured job.
    fn seekableFrame(p: *const Compressor, frame_size: aegis.units.Bytes(u32)) error{InvalidOptions}!aegis.units.Bytes(usize) {
        const frame_bytes: aegis.units.Bytes(usize) = .fromRaw(frame_size.raw());
        if (frame_bytes.eql(.fromRaw(0)) or frame_bytes.compare(.fromRaw(p.cfg.job_len)) == .gt) return error.InvalidOptions;
        return frame_bytes;
    }

    /// Write independent frames and their seek table, reusing these workers.
    /// `frame_size` is at most the configured job length; `records` holds every
    /// frame (including one empty frame for empty input). Returns their count.
    pub fn writeSeekable(p: *Compressor, io: Io, in: []const u8, out: *Io.Writer, records: []seekable.Record, frame_size: aegis.units.Bytes(u32), checksum: bool) (Error || error{TooManyFrames})!usize {
        const frame_bytes = try p.seekableFrame(frame_size);
        const frame_len = frame_bytes.raw();
        const total = @max(1, std.math.divCeil(usize, in.len, frame_len) catch unreachable); // unreachable: frame_len is nonzero
        if (total > records.len or total > (std.math.maxInt(u32) - 9) / 12) return error.TooManyFrames;
        var group: Io.Group = .init;
        defer group.cancel(io);
        const whole: aegis.units.Bytes(usize) = .fromRaw(in.len);
        var at: aegis.units.Bytes(usize) = .fromRaw(0);
        var count: usize = 0;
        var frame_options = p.options.frame;
        frame_options.format = .standard;
        frame_options.content_size = true;
        while (count < total) {
            const batch = @min(p.workers.len, total - count);
            for (p.workers[0..batch]) |*w| {
                const left = whole.sub(at) catch aegis.assert.never("the frames cut lie within the input");
                const n = if (left.compare(frame_bytes) == .lt) left else frame_bytes;
                w.bytes = in[at.raw()..][0..n.raw()];
                if (p.workers.len == 1) w.frame(frame_options) else group.async(io, Worker.frame, .{ w, frame_options });
                at = at.add(n) catch aegis.assert.never("the frames cut lie within the input");
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
    pub fn writeSeekableReader(p: *Compressor, io: Io, in: *Io.Reader, out: *Io.Writer, records: []seekable.Record, frame_size: aegis.units.Bytes(u32), checksum: bool) (Error || error{ TooManyFrames, ReadFailed })!usize {
        const frame_bytes = try p.seekableFrame(frame_size);
        const frame_len = frame_bytes.raw();
        // A batch is one frame per worker: the pool, not the input, bounds it.
        const workers = p.workers;
        var group: Io.Group = .init;
        defer group.cancel(io);
        var count: usize = 0;
        var eof = false;
        var frame_options = p.options.frame;
        frame_options.format = .standard;
        frame_options.content_size = true;
        while (!eof) {
            var batch: usize = 0;
            while (batch < workers.len) {
                const w = &workers[batch];
                const n = try in.readSliceShort(w.input[0..frame_len]);
                eof = frame_bytes.compare(.fromRaw(n)) == .gt;
                if (n == 0 and count + batch != 0) break;
                if (count + batch >= records.len or count + batch >= (std.math.maxInt(u32) - 9) / 12) return error.TooManyFrames;
                w.bytes = w.input[0..n];
                if (workers.len == 1) w.frame(frame_options) else group.async(io, Worker.frame, .{ w, frame_options });
                batch += 1;
                if (eof) break;
            }
            try group.await(io);
            for (workers[0..batch], records[count..][0..batch]) |*w, *record| {
                try out.writeAll(w.output[0..w.result]);
                record.* = .{ .compressed = @intCast(w.result), .decompressed = @intCast(w.bytes.len), .checksum = if (checksum) @truncate(std.hash.XxHash64.hash(0, w.bytes)) else 0 };
            }
            count += batch;
        }
        try seekable.writeTable(out, records[0..count], checksum);
        return count;
    }

    fn readJob(p: *Compressor, io: Io, w: *Worker, source: *Source, cuts: *Cuts, history: *usize, first: *bool, eof: *bool, hash: *std.hash.XxHash64, group: *Io.Group) error{ReadFailed}!bool {
        @memcpy(w.input[0..history.*], p.history[0..history.*]);
        const n = try p.fill(source, w.input[history.*..], cuts, eof);
        if (n == 0) return false;
        w.bytes = w.input[0 .. history.* + n];
        w.prefix = history.*;
        w.first = first.*;
        first.* = false;
        if (p.options.frame.checksum) hash.update(w.bytes[history.*..]);
        history.* = @min(w.bytes.len, p.cfg.overlap);
        @memcpy(p.history[0..history.*], w.bytes[w.bytes.len - history.* ..]);
        p.queue(io, w, group);
        return true;
    }

    /// Stream jobs from a reader; its frame omits the unknown content size.
    pub fn compressReader(p: *Compressor, io: Io, in: *Io.Reader, out: *Io.Writer) (Error || error{ReadFailed})!void {
        try p.header(out, null);
        defer for (p.jobs) |*job| job.group.cancel(io);
        var hash: std.hash.XxHash64 = .init(0);
        var cuts: Cuts = .{};
        var history: usize = 0;
        var first = true;
        var source: Source = .{ .reader = in };
        var eof = false;
        var pending: usize = 0;
        for (p.workers, p.jobs) |*w, *job| {
            if (eof or !try p.readJob(io, w, &source, &cuts, &history, &first, &eof, &hash, &job.group)) break;
            pending += 1;
        }
        var current: usize = 0;
        while (pending != 0) {
            const w = &p.workers[current];
            try p.jobs[current].group.await(io);
            try out.writeAll(w.output[0..w.result]);
            if (eof or !try p.readJob(io, w, &source, &cuts, &history, &first, &eof, &hash, &p.jobs[current].group)) pending -= 1;
            current = (current + 1) % p.workers.len;
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
                const mask = p.cfg.rsync_mask;
                if (cuts.rolling & (mask - 1) == 0) break;
            }
        }
        return cuts.count;
    }
};
