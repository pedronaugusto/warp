//! Parallel bzip2 decoding: blocks found by their magic, decoded by workers
//! each on its own, and joined in order on the caller's thread, which takes
//! a block only where the one before it ended.
//!
//! A bzip2 block depends on nothing before it but where it starts, and a
//! 48-bit magic marks the start, at any bit. The caller's thread scans for
//! the magic and gives each candidate to a worker, which decodes the block
//! into its own BWT vector and output. Walking the streams from their
//! headers, the caller's thread takes a worker's block where the previous
//! block ended (the bits a serial decode reads next) and copies its output;
//! a magic inside a block's data is never reached, and its work is dropped.
//! Stream headers, stream ends, and any block a worker refused are decoded
//! on the caller's thread by the same engine, so the streams are decoded or
//! refused exactly as `bzip2.Decompressor` decodes or refuses them.

const Decompressor = @This();

const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;
const engine = @import("../decode.zig");
const bits = @import("../bits.zig");
const Native = @import("../Decompressor.zig");
const Diagnostic = @import("../Diagnostic.zig");

pub const Options = struct {
    /// Workers, each decoding one block at a time.
    concurrency: u16 = 4,
    /// A worker's output for one block; a block that decodes to more is
    /// finished on the caller's thread, straight into the output.
    block_out: aegis.units.Bytes(u32) = .literal("4MiB"),
    /// Where the blocks were decoded, counted over a call.
    statistics: ?*Statistics = null,

    fn blockOut(o: Options) usize {
        return o.block_out.raw();
    }
};

pub const Statistics = struct {
    /// Blocks a worker decoded, joined in order.
    joined: usize = 0,
    /// Blocks decoded on the caller's thread: refused by a worker, or
    /// with no candidate in flight where they start.
    serial: usize = 0,
    /// Candidates dropped: magic inside data already read.
    dropped: usize = 0,
};

pub const InitError = std.mem.Allocator.Error || error{InvalidOptions};
pub const Error = Native.Error || Io.Cancelable;

/// A block's magic: the digits of pi in BCD.
const block_magic: u64 = 0x3141_5926_5359;
const magic_bits = 48;

/// The largest block's BWT vector, padded to a cache line.
const tt_bytes = std.mem.alignForward(usize, Native.memory, 64);

const Worker = struct {
    group: Io.Group = .init,
    tt: []u32,
    out: []u8,
    tables: engine.Tables = undefined,
    state: engine.State = .{},
    /// The job: the block whose magic is at bit `start`, where it ended,
    /// the output it made, and how it went.
    start: u64 = 0,
    end: u64 = 0,
    out_len: usize = 0,
    outcome: Outcome = .refused,

    fn work(w: *Worker) engine.Work {
        return .{ .tt = w.tt, .tables = &w.tables };
    }

    /// Decode the block at `start` on its own, as a level 9 stream's: the
    /// caller's thread checks the bounds of the stream's real level.
    fn run(w: *Worker, in: []const u8) void {
        var r = readerAt(in, w.start);
        w.state = .atBlock(9);
        var op: usize = 0;
        const status = engine.runBlock(&w.state, w.work(), &r, w.out, &op) catch {
            w.outcome = .refused;
            return;
        };
        w.out_len = op;
        w.end = r.bitOffset();
        w.outcome = switch (status) {
            .boundary => .whole,
            .output_full => .longer,
            .stream_end => .refused,
        };
    }
};

const Outcome = enum {
    /// The block decoded whole into the worker's output.
    whole,
    /// Its output fills the worker's; the rest waits in its state.
    longer,
    /// The block (or a candidate that is none) breaks the format.
    refused,
};

options: Options,
workers: []Worker,
/// Private: the caller's thread's engine, for headers, ends and refused
/// blocks.
tt: []u32,
tables: engine.Tables = undefined,
state: engine.State = .{},
/// Private: the memory `init` allocated; empty after `initBuffer`.
owned: []align(64) u8 = &.{},
gpa: std.mem.Allocator = undefined,

/// The workers' records, the BWT vectors (the caller's thread's and one a
/// worker) and the workers' outputs.
pub fn memory(options: Options) usize {
    if (options.concurrency == 0 or options.blockOut() == 0) return std.math.maxInt(usize);
    const k: usize = options.concurrency;
    const head = std.mem.alignForward(usize, @sizeOf(Worker) * k, 64);
    const stride = tt_bytes + std.mem.alignForward(usize, options.blockOut(), 64);
    return head +| tt_bytes +| k *| stride;
}

pub fn init(gpa: std.mem.Allocator, options: Options) InitError!Decompressor {
    if (options.concurrency == 0 or options.blockOut() == 0) return error.InvalidOptions;
    const size = memory(options);
    if (size == std.math.maxInt(usize)) return error.OutOfMemory;
    const buffer = try gpa.alignedAlloc(u8, .@"64", size);
    var d = initBuffer(buffer, options) catch unreachable; // unreachable: the options were checked, and buffer is memory(options) bytes
    d.owned = buffer;
    d.gpa = gpa;
    return d;
}

/// Aligned storage, refused when the options are not valid or it is
/// shorter than `memory(options)`.
pub fn initBuffer(buffer: []align(64) u8, options: Options) error{ InvalidOptions, BufferTooSmall }!Decompressor {
    if (options.concurrency == 0 or options.blockOut() == 0) return error.InvalidOptions;
    if (buffer.len < memory(options)) return error.BufferTooSmall;
    var fba: std.heap.FixedBufferAllocator = .init(buffer);
    return carve(fba.allocator(), options) catch error.BufferTooSmall;
}

fn carve(a: std.mem.Allocator, options: Options) std.mem.Allocator.Error!Decompressor {
    const workers = try a.alignedAlloc(Worker, .@"64", options.concurrency);
    const tt = try a.alignedAlloc(u32, .@"64", engine.block_max);
    for (workers) |*w| w.* = .{
        .tt = try a.alignedAlloc(u32, .@"64", engine.block_max),
        .out = try a.alignedAlloc(u8, .@"64", options.blockOut()),
    };
    return .{ .options = options, .workers = workers, .tt = tt };
}

pub fn deinit(d: *Decompressor) void {
    if (d.owned.len != 0) d.gpa.free(d.owned);
    d.* = undefined;
}

/// Decode the streams of `in` into `out`, as `bzip2.Decompressor` does.
pub fn decompress(d: *Decompressor, io: Io, in: []const u8, out: []u8, options: Native.Options) Error!Native.Result {
    var stats: Statistics = .{};
    defer if (d.options.statistics) |s| {
        s.* = stats;
    };
    var jobs: Jobs = .{ .workers = d.workers, .io = io, .in = in, .stats = &stats };
    defer jobs.stop();
    var pos: u64 = 0;
    var op: usize = 0;
    while (true) {
        d.state = .{};
        // The stream's header.
        _ = try d.serial(in, &pos, out, &op, options);
        while (true) {
            try io.checkCancel();
            if (try jobs.take(pos)) |w| if (try d.join(w, &pos, out, &op, options)) {
                stats.joined += 1;
                continue;
            };
            if (try d.serial(in, &pos, out, &op, options) == .stream_end) break;
            stats.serial += 1;
        }
        // A stream ends at a byte boundary.
        const at: usize = @intCast(pos / 8);
        if (options.streams == .one) return .{ .in_len = at, .out_len = op };
        switch (Native.next(in[at..])) {
            .stream => {},
            .end => return .{ .in_len = at, .out_len = op },
            .truncated => return fail(options, error.Truncated, 8 * @as(u64, in.len), .truncated),
        }
    }
}

/// The next block, the stream's header or its end, on the caller's thread.
fn serial(d: *Decompressor, in: []const u8, pos: *u64, out: []u8, op: *usize, options: Native.Options) Native.Error!enum { boundary, stream_end } {
    var r = readerAt(in, pos.*);
    const status = engine.runBlock(&d.state, .{ .tt = d.tt, .tables = &d.tables }, &r, out, op) catch |err| switch (err) {
        error.NeedInput => return fail(options, error.Truncated, r.bitOffset(), .truncated),
        error.InvalidStream, error.ChecksumMismatch => |e| return fail(options, e, d.state.fail_bit, d.state.reason),
    };
    pos.* = r.bitOffset();
    return switch (status) {
        .output_full => error.OutputTooSmall,
        .boundary => .boundary,
        .stream_end => .stream_end,
    };
}

/// A worker's block at `pos` into the stream, when it decoded and fits the
/// stream's level; false leaves the block to the caller's thread.
fn join(d: *Decompressor, w: *Worker, pos: *u64, out: []u8, op: *usize, options: Native.Options) Native.Error!bool {
    if (w.outcome == .refused) return false;
    const limit = 100_000 * d.state.level;
    if (w.state.nblock > limit or w.state.orig_ptr > 10 + limit) return false;
    if (w.out_len > out.len - op.*) return error.OutputTooSmall;
    @memcpy(out[op.*..][0..w.out_len], w.out[0..w.out_len]);
    op.* += w.out_len;
    if (w.outcome == .longer) {
        // The rest of the output reads no input: it goes on from the
        // block's end, straight into the output.
        var r: bits.Reader = .{ .in = &.{}, .base = w.end };
        const status = engine.runBlock(&w.state, w.work(), &r, out, op) catch |err| switch (err) {
            error.NeedInput => return fail(options, error.Truncated, r.bitOffset(), .truncated),
            error.InvalidStream, error.ChecksumMismatch => |e| return fail(options, e, w.state.fail_bit, w.state.reason),
        };
        if (status != .boundary) return error.OutputTooSmall;
    }
    d.state.join(w.state.block_crc);
    pos.* = w.end;
    return true;
}

/// The candidates in flight, in input order, one a worker.
const Jobs = struct {
    workers: []Worker,
    io: Io,
    in: []const u8,
    stats: *Statistics,
    /// The oldest job's worker and the jobs in flight.
    head: usize = 0,
    count: usize = 0,
    /// Where the scan for the next magic goes on.
    scan: u64 = 0,

    /// Every idle worker given the next candidate.
    fn fill(j: *Jobs) void {
        while (j.count < j.workers.len) {
            const start = nextMagic(j.in, j.scan) orelse return;
            j.scan = start + 1;
            const w = &j.workers[(j.head + j.count) % j.workers.len];
            w.start = start;
            w.group.async(j.io, Worker.run, .{ w, j.in });
            j.count += 1;
        }
    }

    /// The worker whose block starts at `pos`, its job done; null when no
    /// candidate is there. Jobs before `pos` (magic inside data already
    /// read) are dropped.
    fn take(j: *Jobs, pos: u64) Io.Cancelable!?*Worker {
        while (true) {
            j.fill();
            if (j.count == 0) return null;
            const w = &j.workers[j.head];
            if (w.start > pos) return null;
            try w.group.await(j.io);
            j.head = (j.head + 1) % j.workers.len;
            j.count -= 1;
            if (w.start == pos) return w;
            j.stats.dropped += 1;
        }
    }

    fn stop(j: *Jobs) void {
        for (j.workers) |*w| w.group.cancel(j.io);
    }
};

/// The bit of the next block magic at or after bit `from`, whole within
/// `in`.
fn nextMagic(in: []const u8, from: u64) ?u64 {
    if (in.len < magic_bits / 8) return null;
    var i: usize = @intCast(from / 8);
    const last = in.len - magic_bits / 8;
    while (i <= last) : (i += 1) {
        // Eight bytes from `i`, zeros past the input: the magic at shift
        // `k` is bits 64-k-48 up of the window.
        var window: u64 = 0;
        const n = @min(8, in.len - i);
        for (in[i..][0..n], 0..) |b, x| window |= @as(u64, b) << @intCast(56 - 8 * x);
        for (0..8) |k| {
            const bit = 8 * @as(u64, i) + k;
            if (bit < from or bit + magic_bits > 8 * @as(u64, in.len)) continue;
            if ((window >> @intCast(16 - k)) & 0xffff_ffff_ffff == block_magic) return bit;
        }
    }
    return null;
}

fn readerAt(in: []const u8, bit: u64) bits.Reader {
    const byte: usize = @intCast(bit / 8);
    return .init(in[byte..], 8 * @as(u64, byte), @intCast(bit % 8));
}

fn fail(options: Native.Options, err: Native.Error, bit: u64, reason: Diagnostic.Reason) Native.Error {
    if (options.diagnostic) |diag| diag.* = .{ .bit_offset = .fromRaw(bit), .reason = reason };
    return err;
}
