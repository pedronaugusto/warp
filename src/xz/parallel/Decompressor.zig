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
const aegis = @import("aegis");
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

/// A block: its compressed data and where it starts in the input, its
/// padding and stored check, and the output it fills.
const Job = struct { header: format.BlockHeader, data: []const u8, base: u64, padding: []const u8, stored: []const u8, dest: []u8, check: format.Check };

const Worker = struct {
    group: Io.Group = .init,
    coder: lzma = .init,
    job: Job = undefined,
    refused: bool = false,

    /// The block decoded into its range: LZMA2 to the header's sizes, the
    /// filters undone, the padding and check read.
    fn run(w: *Worker) void {
        const j = w.job;
        const r = w.coder.lzma2(j.data, j.base, j.dest, .{ .dictionary = j.header.dictionary }) catch {
            w.refused = true;
            return;
        };
        if (r.in_len != j.data.len or r.out_len != j.dest.len) {
            w.refused = true;
            return;
        }
        var i: usize = j.header.filter_count;
        while (i > 0) {
            i -= 1;
            var s: filter_.State = .init(j.header.filters[i]);
            _ = filter_.run(j.header.filters[i], &s, j.dest, false);
        }
        for (j.padding) |b| if (b != 0) {
            w.refused = true;
            return;
        };
        if (!Native.verify(j.check, j.dest, j.stored)) w.refused = true;
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
    // What is left of each, ends cut as they are taken.
    var rest = in;
    var room = out;
    var next: usize = 0;
    for (d.workers) |*w| w.refused = false;
    while (true) {
        if (rest.len < format.header_len) return error.Refused;
        const check = switch (format.streamHeader(rest[0..format.header_len])) {
            .check => |c| c,
            .fault => return error.Refused,
        };
        rest = rest[format.header_len..];
        var blocks: Native.Records = .{};
        while (true) {
            if (rest.len == 0) return error.Refused;
            if (rest[0] == 0) break;
            const header_len = (@as(usize, rest[0]) + 1) * 4;
            if (rest.len < header_len) return error.Refused;
            var fault: format.Fault = undefined;
            const h = aegis.input.Untrusted([]const u8).init(rest[0..header_len]).parse(format.HeaderContext{ .check = check, .fault = &fault }, format.blockHeader) catch
                return error.Refused;
            const c = h.compressed orelse return error.Refused;
            const u = h.uncompressed orelse return error.Refused;
            const block = rest[header_len..];
            if (block.len < c or room.len < u) return error.Refused;
            const data = block[0..@min(block.len, c)];
            const after = block[data.len..];
            const padding: u2 = @truncate(0 -% data.len);
            if (after.len < @as(usize, padding) + check.size()) return error.Refused;
            const dest = room[0..@min(room.len, u)];
            // The next worker, once its last block is done.
            const w = &d.workers[next];
            next = (next + 1) % d.workers.len;
            try w.group.await(io);
            if (w.refused) return error.Refused;
            w.job = .{ .header = h, .data = data, .base = in.len - block.len, .padding = after[0..padding], .stored = after[padding..][0..check.size()], .dest = dest, .check = check };
            w.group.async(io, Worker.run, .{w});
            stats.parallel += 1;
            blocks.add(rest.len - after.len + check.size(), dest.len);
            room = room[dest.len..];
            rest = after[@as(usize, padding) + check.size() ..];
        }
        rest = Native.readIndex(in, rest, check, blocks, null) catch return error.Refused;
        if (options.streams == .one) return .{ .in_len = in.len - rest.len, .out_len = out.len - room.len };
        const zeros = std.mem.findNone(u8, rest, &.{0}) orelse rest.len;
        if (zeros % 4 != 0) return error.Refused;
        rest = rest[zeros..];
        if (rest.len == 0) return .{ .in_len = in.len, .out_len = out.len - room.len };
    }
}
