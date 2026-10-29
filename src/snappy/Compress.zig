//! Resumable stream compression: input and output in pieces of any size,
//! flushes, skippable chunks, and its `std.Io.Writer`. Input is staged a
//! block at a time, so the chunks are the same however it arrives: the
//! whole-buffer stream's, and S2's writer's for input given whole or
//! between flushes (S2's writer cuts a long write's own tail into a short
//! block at once, where warp stages it with what follows).
const Compress = @This();

const std = @import("std");
const Io = std.Io;
const Compressor = @import("Compressor.zig");
const frame = @import("frame.zig");
const Index = @import("Index.zig");

pub const Options = struct {
    compressor: Compressor.Options = .{},
    stream: Compressor.Stream = .{},
};

pub const Step = struct { in_len: usize, out_len: usize };
pub const Drain = struct { out_len: usize, done: bool };
pub const Error = error{
    /// Input after `finish`.
    Finished,
    /// A skippable chunk's type outside 0x80-0xfe, or its data past a
    /// chunk's length.
    InvalidChunk,
};
pub const InitError = std.mem.Allocator.Error || error{InvalidOptions};

const Phase = enum { active, flushing, finishing, done };

options: Options,
compressor: Compressor,
/// Private: the block staged.
input: []u8,
staged: usize = 0,
/// Private: the chunk (or the index) written and not yet handed out, and
/// the padding's zeros before it.
output: []u8,
pending: usize = 0,
pending_end: usize = 0,
zeros: usize = 0,
/// Private: what is staged after the padding's zeros, and where the index
/// lies in `output`.
after: [2]usize = .{ 0, 0 },
index_at: [2]usize = .{ 0, 0 },
/// Private: the stream's bytes and output so far, for the index.
written: u64 = 0,
total: u64 = 0,
started: bool = false,
/// Private: the index's entries (with `index`), as S2's writer gathers
/// them. Past `Index.max_entries` (64 GiB of output at the least) blocks
/// are not recorded, and a seek past the last starts there and skips.
entries: []Index.Entry,
count: usize = 0,
gather: Index.Gather = .{},
phase: Phase = .active,
owned: []align(64) u8 = &.{},
gpa: ?std.mem.Allocator = null,

fn stageLen(options: Options) usize {
    const b = Compressor.blockSize(options.compressor, options.stream);
    const index_len = if (options.stream.index == .none) 0 else Index.bound(Index.max_entries);
    return @max(frame.identifier_len + Compressor.chunkBound(b), index_len);
}

fn entriesLen(options: Options) usize {
    return if (options.stream.index == .none) 0 else Index.max_entries;
}

/// The bytes `initBuffer` needs.
pub fn memory(options: Options) usize {
    const b = Compressor.blockSize(options.compressor, options.stream);
    return std.mem.alignForward(usize, Compressor.memory(options.compressor), 64) + entriesLen(options) * @sizeOf(Index.Entry) + b + stageLen(options);
}

pub fn init(gpa: std.mem.Allocator, options: Options) InitError!Compress {
    if (!options.compressor.valid() or !Compressor.validStream(options.compressor, options.stream)) return error.InvalidOptions;
    const buffer = try gpa.alignedAlloc(u8, .@"64", memory(options));
    var s = initBuffer(buffer, options) catch unreachable; // unreachable: the options were checked, and buffer is memory(options) bytes
    s.owned = buffer;
    s.gpa = gpa;
    return s;
}

/// A compressor in caller memory, refused when shorter than
/// `memory(options)`.
pub fn initBuffer(buffer: []align(64) u8, options: Options) error{ InvalidOptions, BufferTooSmall }!Compress {
    if (!options.compressor.valid() or !Compressor.validStream(options.compressor, options.stream)) return error.InvalidOptions;
    if (buffer.len < memory(options)) return error.BufferTooSmall;
    const b = Compressor.blockSize(options.compressor, options.stream);
    const c_len = std.mem.alignForward(usize, Compressor.memory(options.compressor), 64);
    const e_len = entriesLen(options) * @sizeOf(Index.Entry);
    const rest = buffer[c_len + e_len ..];
    return .{
        .options = options,
        .compressor = try Compressor.initBuffer(buffer[0..c_len], options.compressor),

        .entries = std.mem.bytesAsSlice(Index.Entry, std.mem.alignInBytes(buffer[c_len..][0..e_len], @alignOf(Index.Entry)).?),
        .input = rest[0..b],
        .output = rest[b..][0..stageLen(options)],
    };
}

pub fn deinit(s: *Compress) void {
    if (s.gpa) |gpa| gpa.free(s.owned);
    s.* = undefined;
}

/// Start a new stream with the same options.
pub fn reset(s: *Compress) void {
    s.staged = 0;
    s.pending = 0;
    s.pending_end = 0;
    s.zeros = 0;
    s.after = .{ 0, 0 };
    s.index_at = .{ 0, 0 };
    s.written = 0;
    s.total = 0;
    s.started = false;
    s.count = 0;
    s.gather = .{};
    s.phase = .active;
}

/// Take input, writing what complete blocks it makes. Returns how much
/// was taken and written; call again with what was not.
pub fn write(s: *Compress, in: []const u8, out: []u8) Error!Step {
    if (s.phase != .active) return error.Finished;
    var op = s.drain(out);
    var ip: usize = 0;
    while (s.pending == s.pending_end and ip < in.len) {
        const n = @min(in.len - ip, s.input.len - s.staged);
        @memcpy(s.input[s.staged..][0..n], in[ip..][0..n]);
        s.staged += n;
        ip += n;
        if (s.staged == s.input.len) s.block();
        op += s.drain(out[op..]);
    }
    return .{ .in_len = ip, .out_len = op };
}

/// End the block staged, so the output so far decodes to every byte given
/// (S2's `Flush`); call until `done`.
pub fn flush(s: *Compress, out: []u8) Error!Drain {
    if (s.phase == .done or s.phase == .finishing) return error.Finished;
    if (s.phase == .active) {
        if (s.pending != s.pending_end) return .{ .out_len = s.drain(out), .done = false };
        if (s.staged != 0) s.block();
        s.phase = .flushing;
    }
    const n = s.drain(out);
    if (s.pending == s.pending_end) s.phase = .active;
    return .{ .out_len = n, .done = s.phase == .active };
}

/// A skippable chunk of type `id` (0x80-0xfe) holding `data`, written
/// whole once what is pending is out and `out` has room for it, before the
/// block staged, as S2's `AddSkippableBlock`; call until `done`. Empty
/// data writes nothing.
pub fn skippable(s: *Compress, id: u8, data: []const u8, out: []u8) Error!Drain {
    if (s.phase != .active) return error.Finished;
    if (id < 0x80 or id == frame.Type.identifier or data.len > frame.max_chunk_len) return error.InvalidChunk;
    if (data.len == 0) return .{ .out_len = 0, .done = true };
    var op = s.drain(out);
    if (s.pending == s.pending_end and !s.started) {
        s.start();
        op += s.drain(out[op..]);
    }
    if (s.pending != s.pending_end or out.len - op < frame.header_len + data.len) return .{ .out_len = op, .done = false };
    s.record(s.written);
    frame.writeHeader(out[op..][0..frame.header_len], id, data.len);
    @memcpy(out[op + frame.header_len ..][0..data.len], data);
    s.written += frame.header_len + data.len;
    return .{ .out_len = op + frame.header_len + data.len, .done = true };
}

/// End the stream: the block staged, then the padding and index S2's
/// writer's `Close` writes; call until `done`.
pub fn finish(s: *Compress, out: []u8) Error!Drain {
    if (s.phase == .done) return .{ .out_len = 0, .done = true };
    var op: usize = 0;
    if (s.phase != .finishing) {
        op = s.drain(out);
        if (s.pending != s.pending_end) return .{ .out_len = op, .done = false };
        if (s.staged != 0) {
            s.block();
            op += s.drain(out[op..]);
            if (s.pending != s.pending_end) return .{ .out_len = op, .done = false };
        }
        s.end();
        s.phase = .finishing;
    }
    op += s.drain(out[op..]);
    if (s.pending == s.pending_end and s.zeros == 0) s.phase = .done;
    return .{ .out_len = op, .done = s.phase == .done };
}

/// The index and padding, staged: the padding's zeros first, its header
/// staged before the index.
fn end(s: *Compress) void {
    const stream = s.options.stream;
    const padding = stream.padding.raw();
    const padded = padding > 1;
    var index_len: usize = 0;
    var at: usize = 0;
    if (stream.index != .none) {
        var source: Index.Slice = .{ .entries = s.entries[0..s.count] };
        const b = Compressor.blockSize(s.options.compressor, stream);
        // Room for the padding's header before it.
        index_len = Index.write(s.output[frame.header_len..], &source, s.count, b, if (padded) null else s.written, s.total);
        at = frame.header_len;
    }
    const appended = if (stream.index == .append) index_len else 0;
    const pad: usize = if (padded) @intCast(frame.paddingLen(s.written + appended, padding)) else 0;
    if (pad > 0) {
        frame.writeHeader(s.output[0..frame.header_len], frame.Type.padding, pad - frame.header_len);
        s.zeros = pad - frame.header_len;
        // The header goes out, then the zeros, then the index.
        s.pending = 0;
        s.pending_end = frame.header_len;
        s.after = .{ at, at + appended };
    } else {
        s.pending = at;
        s.pending_end = at + appended;
    }
    // An index kept apart is `index()`'s.
    s.index_at = .{ at, at + index_len };
}

/// The index kept apart (`index = .apart`), once `finish` is done.
pub fn index(s: *const Compress) []const u8 {
    std.debug.assert(s.phase == .done);
    std.debug.assert(s.options.stream.index == .apart);
    return s.output[s.index_at[0]..s.index_at[1]];
}

/// The identifier, once, before the first chunk.
fn start(s: *Compress) void {
    if (s.started) return;
    s.started = true;
    @memcpy(s.output[s.pending_end..][0..frame.identifier_len], frame.identifier(s.options.compressor.format));
    s.record(s.written);
    s.pending_end += frame.identifier_len;
    s.written += frame.identifier_len;
}

/// The staged block as a chunk, staged for output.
fn block(s: *Compress) void {
    s.start();
    s.record(s.written);
    const n = s.compressor.chunk(s.input[0..s.staged], s.output[s.pending_end..], s.options.stream.store);
    s.pending_end += n;
    s.written += n;
    s.total += s.staged;
    s.staged = 0;
}

/// A chunk starting at `at` of the stream, for the index.
fn record(s: *Compress, at: u64) void {
    if (s.options.stream.index == .none) return;
    const e: Index.Entry = .{ .compressed = at, .uncompressed = s.total };
    switch (s.gather.add(e)) {
        .new => if (s.count < s.entries.len) {
            s.entries[s.count] = e;
            s.count += 1;
        },
        .moved => if (s.count > 0 and s.entries[s.count - 1].uncompressed == e.uncompressed) {
            s.entries[s.count - 1] = e;
        },
        .dropped => {},
    }
}

fn drain(s: *Compress, out: []u8) usize {
    var op: usize = 0;
    while (true) {
        const n = @min(out.len - op, s.pending_end - s.pending);
        @memcpy(out[op..][0..n], s.output[s.pending..][0..n]);
        s.pending += n;
        op += n;
        if (s.pending != s.pending_end) return op;
        if (s.zeros > 0) {
            const z = @min(out.len - op, s.zeros);
            @memset(out[op..][0..z], 0);
            s.zeros -= z;
            op += z;
            if (s.zeros > 0) return op;
            s.pending, s.pending_end = s.after;
            s.after = .{ 0, 0 };
            continue;
        }
        s.pending = 0;
        s.pending_end = 0;
        return op;
    }
}

/// A `std.Io.Writer` that compresses into `output`; `finish` ends the
/// stream, `flush` ends the block staged.
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
        try w.drainStream(true);
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
        const w: *Writer = @alignCast(@fieldParentPtr("interface", interface));
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

    fn drainStream(w: *Writer, finish_stream: bool) Io.Writer.Error!void {
        var buffer: [4096]u8 = undefined;
        while (true) {
            const result = (if (finish_stream) w.state.finish(&buffer) else w.state.flush(&buffer)) catch |failure| {
                w.failure = failure;
                return error.WriteFailed;
            };
            try w.output.writeAll(buffer[0..result.out_len]);
            if (result.done) return;
        }
    }

    fn flushInput(interface: *Io.Writer) Io.Writer.Error!void {
        const w: *Writer = @alignCast(@fieldParentPtr("interface", interface));
        try w.writeSlice(interface.buffered());
        interface.end = 0;
        try w.drainStream(false);
    }
};
