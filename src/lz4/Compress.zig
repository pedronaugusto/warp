//! Resumable LZ4 frame compression: input and output in pieces of any
//! size, flushes, and its `std.Io.Writer`. Input is staged a block at a
//! time behind the 64 KiB a linked block refers back into, so the blocks
//! and their bytes are the same however the input arrives.
const Compress = @This();

const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;
const Compressor = @import("Compressor.zig");
const frame = @import("frame.zig");

pub const Options = struct {
    compressor: Compressor.Options = .{},
    frame: Compressor.Frame = .{},
    /// The content's length: written to the descriptor when the frame
    /// carries one, and checked at `finish`.
    pledged_size: ?aegis.units.Bytes(u64) = null,

    /// `pledged_size`, as the descriptor and the check count it.
    fn pledged(o: Options) ?u64 {
        return if (o.pledged_size) |n| n.raw() else null;
    }
};

pub const Step = struct { in_len: usize, out_len: usize };
pub const Drain = struct { out_len: usize, done: bool };
pub const Error = error{
    /// The content was not `pledged_size` long.
    SizeMismatch,
    /// Input after `finish`.
    Finished,
};

const history_len = 65536;

const Phase = enum { active, flushing, finishing, done };

options: Options,
compressor: Compressor,
/// Private: the history linked blocks reach into, then the block staged.
input: []u8,
staged: usize = 0,
/// Private: the frame written and not yet handed out.
output: []u8,
pending: usize = 0,
pending_end: usize = 0,
/// Private: whether the descriptor and a first block were written.
started: bool = false,
first: bool = true,
total: u64 = 0,
hash: std.hash.XxHash32 = .init(0),
phase: Phase = .active,
owned: []align(64) u8 = &.{},
gpa: ?std.mem.Allocator = null,

fn blockLen(options: Options) usize {
    return if (options.frame.format == .legacy) frame.legacy_block_len else options.frame.block_size.bytes();
}

/// The bytes `initBuffer` needs.
pub fn memory(options: Options) usize {
    const b = blockLen(options);
    return std.mem.alignForward(usize, Compressor.memory(options.compressor), 64) + history_len + b + Compressor.bound(b, options.frame) + frame.max_header_len;
}

pub fn init(gpa: std.mem.Allocator, options: Options) std.mem.Allocator.Error!Compress {
    const buffer = try gpa.alignedAlloc(u8, .@"64", memory(options));
    var s = initBuffer(buffer, options);
    s.owned = buffer;
    s.gpa = gpa;
    return s;
}

/// A compressor in caller memory: `buffer.len >= memory(options)`.
pub fn initBuffer(buffer: []align(64) u8, options: Options) Compress {
    std.debug.assert(buffer.len >= memory(options));
    const b = blockLen(options);
    const c_len = std.mem.alignForward(usize, Compressor.memory(options.compressor), 64);
    const rest = buffer[c_len..];
    return .{
        .options = options,
        .compressor = Compressor.initBuffer(buffer[0..c_len], options.compressor),
        .input = rest[0 .. history_len + b],
        .output = rest[history_len + b ..],
    };
}

pub fn deinit(s: *Compress) void {
    if (s.gpa) |gpa| gpa.free(s.owned);
    s.* = undefined;
}

/// Start a new frame with the same options; the next frame refers into
/// none of this one.
pub fn reset(s: *Compress) void {
    s.staged = 0;
    s.pending = 0;
    s.pending_end = 0;
    s.started = false;
    s.first = true;
    s.total = 0;
    s.hash = .init(0);
    s.phase = .active;
}

/// Take input, writing what complete blocks it makes. Returns how much
/// was taken and written; call again with what was not.
pub fn write(s: *Compress, in: []const u8, out: []u8) Error!Step {
    if (s.phase != .active) return error.Finished;
    var op = s.drain(out);
    var ip: usize = 0;
    const b = blockLen(s.options);
    while (s.pending == s.pending_end) {
        s.start();
        if (ip == in.len) break;
        const n = @min(in.len - ip, b - s.staged);
        @memcpy(s.input[history_len + s.staged ..][0..n], in[ip..][0..n]);
        s.staged += n;
        ip += n;
        if (s.staged == b) try s.block();
        op += s.drain(out[op..]);
    }
    return .{ .in_len = ip, .out_len = op };
}

/// End the block staged, so the output so far decodes to every byte given;
/// call until `done`. A legacy frame's blocks are whole: there, only what
/// is written already is handed out.
pub fn flush(s: *Compress, out: []u8) Error!Drain {
    if (s.phase == .done) return error.Finished;
    if (s.phase == .active) {
        if (s.pending != s.pending_end) return .{ .out_len = s.drain(out), .done = false };
        s.start();
        if (s.staged != 0 and s.options.frame.format == .standard) try s.block();
        s.phase = .flushing;
    }
    const n = s.drain(out);
    if (s.pending == s.pending_end) s.phase = .active;
    return .{ .out_len = n, .done = s.phase == .active };
}

/// End the frame; call until `done`.
pub fn finish(s: *Compress, out: []u8) Error!Drain {
    if (s.phase == .done) return .{ .out_len = 0, .done = true };
    if (s.phase != .finishing) {
        var op = s.drain(out);
        if (s.pending != s.pending_end) return .{ .out_len = op, .done = false };
        s.start();
        if (s.staged != 0) try s.block();
        if (s.pending != s.pending_end) {
            op += s.drain(out[op..]);
            if (s.pending != s.pending_end) return .{ .out_len = op, .done = false };
        }
        if (s.options.pledged()) |want| if (want != s.total) return error.SizeMismatch;
        if (s.options.frame.format == .standard) {
            std.mem.writeInt(u32, s.output[0..4], 0, .little);
            var len: usize = 4;
            if (s.options.frame.content_checksum) {
                std.mem.writeInt(u32, s.output[4..8], s.hash.final(), .little);
                len += 4;
            }
            s.pending = 0;
            s.pending_end = len;
        }
        s.phase = .finishing;
        const n = s.drain(out[op..]);
        if (s.pending == s.pending_end) s.phase = .done;
        return .{ .out_len = op + n, .done = s.phase == .done };
    }
    const n = s.drain(out);
    if (s.pending == s.pending_end) s.phase = .done;
    return .{ .out_len = n, .done = s.phase == .done };
}

/// The descriptor, once, before the first block.
fn start(s: *Compress) void {
    if (s.started) return;
    s.started = true;
    const f = s.options.frame;
    if (f.format == .legacy) {
        std.mem.writeInt(u32, s.output[0..4], frame.legacy_magic, .little);
        s.pending = 0;
        s.pending_end = 4;
        return;
    }
    const header: frame.Header = .{
        .block_size = f.block_size,
        .independent = f.independent,
        .block_checksum = f.block_checksum,
        .content_checksum = f.content_checksum,
        .content_size = if (f.content_size) s.options.pledged() else null,
        .dictionary_id = f.dictionary_id,
    };
    s.pending = 0;
    s.pending_end = header.write(s.output);
}

/// Compress the staged block into the output, then keep the window's last
/// 64 KiB before the next block's place.
fn block(s: *Compress) Error!void {
    const f = s.options.frame;
    const src = s.input[history_len..][0..s.staged];
    s.total += src.len;
    if (f.content_checksum) s.hash.update(src);
    const at = s.pending_end;
    if (f.format == .legacy) {
        const level = s.compressor.level;
        defer s.compressor.level = level;
        if (level < 3) s.compressor.level = @min(level, 1);
        const n = s.compressor.compressBlock(src, s.output[at + 4 ..], .{}) catch unreachable; // unreachable: the output holds a block's bound
        std.mem.writeInt(u32, s.output[at..][0..4], @intCast(n), .little);
        s.pending_end = at + 4 + n;
    } else {
        s.pending_end = at + (s.compressor.frameBlock(src, s.output[at..], f, s.first) catch unreachable); // unreachable: the output holds a block's bound
    }
    s.first = false;
    if (!f.independent and f.format == .standard) {
        // The last 64 KiB, the previous block's tail included, just before
        // the next block, which then continues from it.
        const keep = @min(history_len, s.compressor.previous.len + src.len);
        const end = history_len + src.len;
        @memmove(s.input[history_len - keep .. history_len], s.input[end - keep .. end]);
        s.compressor.previous = s.input[history_len - keep .. history_len];
    }
    s.staged = 0;
}

fn drain(s: *Compress, out: []u8) usize {
    const n = @min(out.len, s.pending_end - s.pending);
    @memcpy(out[0..n], s.output[s.pending..][0..n]);
    s.pending += n;
    if (s.pending == s.pending_end) {
        s.pending = 0;
        s.pending_end = 0;
    }
    return n;
}

/// A `std.Io.Writer` that compresses into `output`; `finish` ends the
/// frame, `flush` ends the block staged.
pub const Writer = struct {
    interface: Io.Writer,
    state: *Compress,
    output: *Io.Writer,
    failure: ?Error = null,

    pub fn init(state: *Compress, output: *Io.Writer, buffer: []u8) Writer {
        return .{ .state = state, .output = output, .interface = .{ .vtable = &.{ .drain = writeData, .flush = flushInput }, .buffer = buffer, .end = 0 } };
    }

    /// The error behind an `error.WriteFailed`, when it was the codec's.
    pub fn err(w: *const Writer) ?Error {
        return w.failure;
    }

    pub fn finish(w: *Writer) Io.Writer.Error!void {
        try w.writeSlice(w.interface.buffered());
        w.interface.end = 0;
        try w.drainFrame(true);
    }

    fn writeSlice(w: *Writer, in: []const u8) Io.Writer.Error!void {
        var at: usize = 0;
        var buffer: [4096]u8 = undefined;
        while (at < in.len) {
            const step = w.state.write(in[at..], &buffer) catch |failure| {
                w.failure = failure;
                return error.WriteFailed;
            };
            at += step.in_len;
            try w.output.writeAll(buffer[0..step.out_len]);
        }
    }

    fn writeData(interface: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const w: *Writer = @alignCast(@fieldParentPtr("interface", interface)); // safe: interface is the embedded Writer field
        try w.writeSlice(interface.buffered());
        interface.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |part| {
            try w.writeSlice(part);
            n += part.len;
        }
        const tail = data[data.len - 1];
        for (0..splat) |_| try w.writeSlice(tail);
        return n + tail.len * splat;
    }

    fn drainFrame(w: *Writer, finish_frame: bool) Io.Writer.Error!void {
        var buffer: [4096]u8 = undefined;
        while (true) {
            const result = (if (finish_frame) w.state.finish(&buffer) else w.state.flush(&buffer)) catch |failure| {
                w.failure = failure;
                return error.WriteFailed;
            };
            try w.output.writeAll(buffer[0..result.out_len]);
            if (result.done) return;
        }
    }

    fn flushInput(interface: *Io.Writer) Io.Writer.Error!void {
        const w: *Writer = @alignCast(@fieldParentPtr("interface", interface)); // safe: interface is the embedded Writer field
        try w.writeSlice(interface.buffered());
        interface.end = 0;
        try w.drainFrame(false);
    }
};
