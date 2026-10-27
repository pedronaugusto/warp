//! Parallel `.xz` encoding: the input cut into blocks (three dictionaries
//! by default, at least 1 MiB, as `xz -T` cuts them), each encoded by a
//! worker into its own buffer, the blocks written out in order and the
//! index read back from their headers. The stream is the bytes the
//! whole-buffer encoder writes with the same options and block size.

const Compressor = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Serial = @import("../Compressor.zig");
const Lzma = @import("../../lzma/Compressor.zig");
const format = @import("../format.zig");

pub const Options = struct {
    /// Workers, each encoding one block at a time.
    concurrency: u16 = 4,
    /// The encoder's options; a null block size is three dictionaries, at
    /// least 1 MiB.
    xz: Serial.Options = .{},

    /// The serial options with the block size the workers cut.
    pub fn blocks(o: Options) Serial.Options {
        var x = o.xz;
        if (x.block_size == null) x.block_size = @max(@as(u64, x.lzma.dictionary) * 3, 1 << 20);
        return x;
    }
};

pub const InitError = Serial.InitError;
pub const Error = Serial.Error || Io.Cancelable;

const Worker = struct {
    group: Io.Group = .init,
    encoder: Serial,
    /// The block encoded, and its length.
    out: []u8,
    len: usize = 0,
    failure: ?Serial.Error = null,

    fn run(w: *Worker, in: []const u8) void {
        w.len = w.encoder.block(in, w.out) catch |err| {
            w.failure = err;
            return;
        };
    }
};

options: Options,
workers: []Worker,
gpa: Allocator,

pub fn init(gpa: Allocator, options: Options) InitError!Compressor {
    if (options.concurrency == 0) return error.InvalidOptions;
    const o = options.blocks();
    if (!o.valid()) return error.InvalidOptions;
    const block: usize = @intCast(o.block_size.?);
    const workers = try gpa.alloc(Worker, options.concurrency);
    var made: usize = 0;
    errdefer {
        for (workers[0..made]) |*w| {
            w.encoder.deinit();
            gpa.free(w.out);
        }
        gpa.free(workers);
    }
    // Each worker's tables for a block, or `max_input` where shorter.
    var one = o;
    one.max_input = .fromRaw(if (o.max_input) |m| @min(block, m.raw()) else block);
    for (workers) |*w| {
        var encoder: Serial = try .init(gpa, one);
        errdefer encoder.deinit();
        w.* = .{ .encoder = encoder, .out = try gpa.alloc(u8, blockBound(o, block)) };
        made += 1;
    }
    return .{ .options = options, .workers = workers, .gpa = gpa };
}

pub fn deinit(c: *Compressor) void {
    for (c.workers) |*w| {
        w.encoder.deinit();
        c.gpa.free(w.out);
    }
    c.gpa.free(c.workers);
    c.* = undefined;
}

/// One block's largest encoding: header, LZMA2, padding, check.
fn blockBound(o: Serial.Options, len: usize) usize {
    const data = Lzma.bound(.lzma2, len);
    const header = format.blockHeaderLen(.{ .compressed = data, .uncompressed = len, .filters = o.filters, .dictionary = o.lzma.dictionary });
    return header + std.mem.alignForward(usize, data, 4) + o.check.size();
}

/// The largest stream an input of `len` bytes encodes to.
pub fn bound(options: Options, len: usize) usize {
    return Serial.bound(options.blocks(), len);
}

/// One stream of `in` into `out`; its length.
pub fn compress(c: *Compressor, io: Io, in: []const u8, out: []u8) Error!usize {
    const o = c.options.blocks();
    defer for (c.workers) |*w| w.group.cancel(io);
    if (out.len < format.header_len) return error.OutputTooSmall;
    format.writeStreamHeader(out[0..format.header_len], o.check);
    var pos: usize = format.header_len;
    const block: usize = @intCast(o.block_size.?);
    var at: usize = 0;
    var next: usize = 0;
    var busy: usize = 0;
    while (at < in.len) {
        // The oldest block out first, when its worker is wanted again.
        const w = &c.workers[next];
        if (busy == c.workers.len) {
            try w.group.await(io);
            pos = try place(w, out, pos);
            busy -= 1;
        }
        const n = @min(block, in.len - at);
        w.failure = null;
        w.group.async(io, Worker.run, .{ w, in[at..][0..n] });
        busy += 1;
        at += n;
        next = (next + 1) % c.workers.len;
    }
    // The rest, oldest first.
    var i = (next + c.workers.len - busy) % c.workers.len;
    while (busy != 0) : (busy -= 1) {
        const w = &c.workers[i];
        try w.group.await(io);
        pos = try place(w, out, pos);
        i = (i + 1) % c.workers.len;
    }
    pos += try Serial.writeIndex(out, format.header_len, pos, o.check);
    return pos;
}

/// A worker's block after the ones before it.
fn place(w: *Worker, out: []u8, pos: usize) Serial.Error!usize {
    if (w.failure) |err| return err;
    if (out.len - pos < w.len) return error.OutputTooSmall;
    @memcpy(out[pos..][0..w.len], w.out[0..w.len]);
    return pos + w.len;
}
