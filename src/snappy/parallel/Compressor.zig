//! Parallel stream encoding: the input cut into blocks of the stream's
//! block size, each made a chunk by a worker into its own buffer, the
//! chunks written out in order, then the padding and index. The stream is
//! the bytes the whole-buffer encoder writes with the same options: S2's
//! writer's, whatever its concurrency.

const Compressor = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Serial = @import("../Compressor.zig");
const frame = @import("../frame.zig");

pub const Options = struct {
    /// Workers, each encoding one block at a time.
    concurrency: u16 = 4,
    compressor: Serial.Options = .{},
    stream: Serial.Stream = .{},
};

pub const InitError = Serial.InitError;
pub const Error = Serial.StreamError || Io.Cancelable;

const Worker = struct {
    group: Io.Group = .init,
    compressor: Serial,
    /// The chunk made, and its length.
    out: []u8,
    len: usize = 0,

    fn run(w: *Worker, in: []const u8, store: bool) void {
        w.len = w.compressor.chunk(in, w.out, store);
    }
};

options: Options,
workers: []Worker,
gpa: Allocator,

pub fn init(gpa: Allocator, options: Options) InitError!Compressor {
    if (options.concurrency == 0 or !options.compressor.valid() or !Serial.validStream(options.compressor, options.stream)) return error.InvalidOptions;
    const b = Serial.blockSize(options.compressor, options.stream);
    const workers = try gpa.alloc(Worker, options.concurrency);
    var made: usize = 0;
    errdefer {
        for (workers[0..made]) |*w| {
            w.compressor.deinit();
            gpa.free(w.out);
        }
        gpa.free(workers);
    }
    for (workers) |*w| {
        var c: Serial = try .init(gpa, options.compressor);
        errdefer c.deinit();
        w.* = .{ .compressor = c, .out = try gpa.alloc(u8, Serial.chunkBound(b)) };
        made += 1;
    }
    return .{ .options = options, .workers = workers, .gpa = gpa };
}

pub fn deinit(c: *Compressor) void {
    for (c.workers) |*w| {
        w.compressor.deinit();
        c.gpa.free(w.out);
    }
    c.gpa.free(c.workers);
    c.* = undefined;
}

/// The longest stream of `len` bytes, with its index apart.
pub fn bound(options: Options, len: usize) usize {
    return Serial.streamBound(options.compressor, len, options.stream);
}

/// One stream of `in` into `out` (at least `bound` bytes).
pub fn compress(c: *Compressor, io: Io, in: []const u8, out: []u8) Error!Serial.StreamResult {
    const stream = c.options.stream;
    if (out.len < bound(c.options, in.len)) return error.OutputTooSmall;
    defer for (c.workers) |*w| w.group.cancel(io);
    const b = Serial.blockSize(c.options.compressor, stream);
    var pos: usize = 0;
    if (in.len > 0) {
        @memcpy(out[0..frame.identifier_len], frame.identifier(c.options.compressor.format));
        pos = frame.identifier_len;
    }
    var at: usize = 0;
    var next: usize = 0;
    var busy: usize = 0;
    while (at < in.len) {
        // The oldest chunk out first, when its worker is wanted again.
        const w = &c.workers[next];
        if (busy == c.workers.len) {
            try w.group.await(io);
            pos = place(w, out, pos);
            busy -= 1;
        }
        const n = @min(b, in.len - at);
        w.group.async(io, Worker.run, .{ w, in[at..][0..n], stream.store });
        busy += 1;
        at += n;
        next = (next + 1) % c.workers.len;
    }
    // The rest, oldest first.
    var i = (next + c.workers.len - busy) % c.workers.len;
    while (busy != 0) : (busy -= 1) {
        const w = &c.workers[i];
        try w.group.await(io);
        pos = place(w, out, pos);
        i = (i + 1) % c.workers.len;
    }
    return Serial.finish(out, pos, in.len, b, stream);
}

/// A worker's chunk after the ones before it.
fn place(w: *Worker, out: []u8, pos: usize) usize {
    @memcpy(out[pos..][0..w.len], w.out[0..w.len]);
    return pos + w.len;
}
