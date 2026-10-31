//! Parallel stream decoding: the caller's thread reads the chunks as the
//! whole-buffer decoder does, and each data chunk's block is decoded and
//! checked by a worker straight into its range of the caller's output,
//! since each block's length places it. Where anything is refused, the
//! whole-buffer decoder decodes the input instead, so the output, errors
//! and diagnostics are always its own.

const Decompressor = @This();

const std = @import("std");
const Io = std.Io;
const frame = @import("../frame.zig");
const streams = @import("../streams.zig");

pub const Options = struct {
    /// Workers, each decoding one block at a time.
    concurrency: u16 = 4,
    /// Where the blocks were decoded, over a call.
    statistics: ?*Statistics = null,
};

pub const Statistics = struct {
    /// Blocks a worker decoded.
    parallel: usize = 0,
    /// Whether the whole-buffer decoder decoded the input instead.
    serial: bool = false,
};

pub const InitError = std.mem.Allocator.Error || error{InvalidOptions};
pub const Error = streams.DecompressError || Io.Cancelable;

const Worker = struct {
    group: Io.Group = .init,
    refused: bool = false,

    fn run(w: *Worker, data: @FieldType(streams.Chunk, "data"), body_at: u64, out: []u8, options: streams.Options) void {
        streams.readData(data, body_at, out, options) catch {
            w.refused = true;
        };
    }
};

options: Options,
workers: []Worker,
gpa: std.mem.Allocator,

pub fn init(gpa: std.mem.Allocator, options: Options) InitError!Decompressor {
    if (options.concurrency == 0) return error.InvalidOptions;
    const workers = try gpa.alloc(Worker, options.concurrency);
    for (workers) |*w| w.* = .{};
    return .{ .options = options, .workers = workers, .gpa = gpa };
}

pub fn deinit(d: *Decompressor) void {
    d.gpa.free(d.workers);
    d.* = undefined;
}

/// Decode the whole stream `in` into `out`, as the whole-buffer decoder
/// does; the output's length.
pub fn decompress(d: *Decompressor, io: Io, in: []const u8, out: []u8, options: streams.Options) Error!usize {
    var stats: Statistics = .{};
    defer if (d.options.statistics) |s| {
        s.* = stats;
    };
    defer for (d.workers) |*w| w.group.cancel(io);
    if (options.max_block_size.compare(.fromRaw(frame.max_block_size)) == .gt) return error.InvalidOptions;
    const planned = d.plan(io, in, out, options, &stats) catch |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.Refused => null,
    };
    for (d.workers) |*w| try w.group.await(io);
    var refused = planned == null;
    for (d.workers) |w| refused = refused or w.refused;
    if (!refused) return planned.?;
    // The whole-buffer decoder's answer, exactly.
    stats = .{ .serial = true };
    return streams.decompress(in, out, options);
}

/// Read the chunks, handing each block to the next worker; null where the
/// reading does not reach the end as the whole-buffer decoder would.
fn plan(d: *Decompressor, io: Io, in: []const u8, out: []u8, options: streams.Options, stats: *Statistics) (Io.Cancelable || error{Refused})!usize {
    // The workers report a refusal; the whole-buffer decoder names it.
    var quiet = options;
    quiet.diagnostic = null;
    for (d.workers) |*w| w.refused = false;
    var at: usize = 0;
    var op: usize = 0;
    var next: usize = 0;
    var first = !options.from_chunk;
    var snappy = false;
    while (at < in.len) {
        const chunk, const end = streams.readChunk(in, at, first, snappy, quiet) catch return error.Refused;
        first = false;
        switch (chunk) {
            .data => |data| {
                if (out.len - op < data.len) return error.Refused;
                // The next worker, once its last block is done.
                const w = &d.workers[next];
                next = (next + 1) % d.workers.len;
                try w.group.await(io);
                if (w.refused) return error.Refused;
                w.group.async(io, Worker.run, .{ w, data, at + frame.header_len, out[op..][0..data.len], quiet });
                stats.parallel += 1;
                op += data.len;
            },
            .identifier => |format| snappy = format == .snappy,
            .skipped => {},
        }
        at = end;
    }
    return op;
}
