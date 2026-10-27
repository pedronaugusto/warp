//! Parallel `.xz` decoding: the blocks whose headers carry both sizes (as
//! `xz -T` and liblzma's multithreaded encoder write them) decoded by
//! workers, each straight into its range of the caller's output, since
//! the sizes place it.
//!
//! The caller's thread walks the streams as the whole-buffer decoder does:
//! headers, block headers, the index against the blocks' records, the
//! footer, padding. A worker decodes a block's LZMA2, undoes its filters and
//! checks its padding and check. Where anything is refused, or a block's
//! header lacks a size, the whole-buffer decoder decodes the input instead,
//! so the output, errors and diagnostics are always its own.

const Decompressor = @This();

const std = @import("std");
const Io = std.Io;
const Native = @import("../Decompressor.zig");
const lzma = @import("../../lzma/Decompressor.zig");
const format = @import("../format.zig");
const filter_ = @import("../filter.zig");

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
pub const Error = Native.Error || Io.Cancelable;

const Job = struct { header: format.BlockHeader, data: usize, out_at: usize, check: format.Check };

const Worker = struct {
    group: Io.Group = .init,
    coder: lzma = .init,
    job: Job = undefined,
    refused: bool = false,

    /// The block decoded into its range: LZMA2 to the header's sizes, the
    /// filters undone, the padding and check read.
    fn run(w: *Worker, in: []const u8, out: []u8) void {
        const j = w.job;
        const c: usize = @intCast(j.header.compressed.?);
        const u: usize = @intCast(j.header.uncompressed.?);
        const dest = out[j.out_at..][0..u];
        const r = w.coder.lzma2(in[j.data..][0..c], j.data, dest, .{ .dictionary = j.header.dictionary }) catch {
            w.refused = true;
            return;
        };
        if (r.in_len != c or r.out_len != u) {
            w.refused = true;
            return;
        }
        var i: usize = j.header.filter_count;
        while (i > 0) {
            i -= 1;
            var s: filter_.State = .init(j.header.filters[i]);
            _ = filter_.run(j.header.filters[i], &s, dest, false);
        }
        const padded = j.data + c + (4 - c % 4) % 4;
        for (in[j.data + c .. padded]) |b| if (b != 0) {
            w.refused = true;
            return;
        };
        if (!Native.verify(j.check, dest, in[padded..][0..j.check.size()])) w.refused = true;
    }
};

options: Options,
workers: []Worker,
serial: Native = .init,
/// Private: the memory `init` allocated.
owned: []Worker = &.{},
gpa: std.mem.Allocator = undefined,

pub fn init(gpa: std.mem.Allocator, options: Options) InitError!Decompressor {
    if (options.concurrency == 0) return error.InvalidOptions;
    const workers = try gpa.alloc(Worker, options.concurrency);
    for (workers) |*w| w.* = .{};
    return .{ .options = options, .workers = workers, .owned = workers, .gpa = gpa };
}

pub fn deinit(d: *Decompressor) void {
    if (d.owned.len != 0) d.gpa.free(d.owned);
    d.* = undefined;
}

/// Decode the streams of `in` into `out`, as the whole-buffer decoder does.
pub fn decompress(d: *Decompressor, io: Io, in: []const u8, out: []u8, options: Native.Options) Error!Native.Result {
    var stats: Statistics = .{};
    defer if (d.options.statistics) |s| {
        s.* = stats;
    };
    defer for (d.workers) |*w| w.group.cancel(io);
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
    return d.serial.decompress(in, out, options);
}

/// Walk the streams, handing each block to the next worker; null where the
/// walk does not reach the end as the whole-buffer decoder would.
fn plan(d: *Decompressor, io: Io, in: []const u8, out: []u8, options: Native.Options, stats: *Statistics) (Io.Cancelable || error{Refused})!Native.Result {
    var at: usize = 0;
    var op: usize = 0;
    var next: usize = 0;
    for (d.workers) |*w| w.refused = false;
    while (true) {
        if (in.len - at < format.header_len) return error.Refused;
        const check = switch (format.streamHeader(in[at..][0..format.header_len])) {
            .check => |c| c,
            .fault => return error.Refused,
        };
        var pos = at + format.header_len;
        var blocks: Native.Records = .{};
        while (true) {
            if (pos == in.len) return error.Refused;
            if (in[pos] == 0) break;
            const header_len = (@as(usize, in[pos]) + 1) * 4;
            if (in.len - pos < header_len) return error.Refused;
            const h = switch (format.blockHeader(in[pos..][0..header_len], check)) {
                .header => |h| h,
                .fault => return error.Refused,
            };
            const c = h.compressed orelse return error.Refused;
            const u = h.uncompressed orelse return error.Refused;
            const data = pos + header_len;
            const padded = c + (4 - c % 4) % 4;
            if (in.len - data < padded + check.size() or out.len - op < u) return error.Refused;
            // The next worker, once its last block is done.
            const w = &d.workers[next];
            next = (next + 1) % d.workers.len;
            try w.group.await(io);
            if (w.refused) return error.Refused;
            w.job = .{ .header = h, .data = data, .out_at = op, .check = check };
            w.group.async(io, Worker.run, .{ w, in, out });
            stats.parallel += 1;
            blocks.add(header_len + c + check.size(), u);
            op += @intCast(u);
            pos = data + @as(usize, @intCast(padded)) + check.size();
        }
        pos = Native.readIndex(in, pos, check, blocks, null) catch return error.Refused;
        at = pos;
        if (options.streams == .one) return .{ .in_len = at, .out_len = op };
        var p = at;
        while (p < in.len and in[p] == 0) p += 1;
        if ((p - at) % 4 != 0) return error.Refused;
        if (p == in.len) return .{ .in_len = p, .out_len = op };
        at = p;
    }
}
