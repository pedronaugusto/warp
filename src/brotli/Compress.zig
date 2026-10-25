//! Resumable Brotli compression: the reference's streaming encoder, the
//! same stream for the same options, input and flushes. Input gathers into
//! blocks of the quality's size before any is encoded; `flush` ends the
//! block at a byte boundary, `finish` ends the stream, and `metadata`
//! writes bytes a decoder skips.

const Compress = @This();

const std = @import("std");
const Io = std.Io;
const encode = @import("encode.zig");
const settings = @import("settings.zig");

pub const Options = settings.Options;
pub const Step = struct { in_len: usize, out_len: usize };
pub const Drain = struct { out_len: usize, done: bool };
pub const MetadataStep = struct { in_len: usize, out_len: usize, done: bool };
pub const Error = std.mem.Allocator.Error || error{
    /// Input or a flush after `finish`.
    Finished,
    /// A metadata block holds at most 16 MiB.
    MetadataTooLong,
    /// Other input while a metadata block is being written, or its bytes
    /// changed between calls.
    MetadataPending,
};

encoder: encode.Encoder,

pub fn init(gpa: std.mem.Allocator, options: Options) std.mem.Allocator.Error!Compress {
    return .{ .encoder = try .init(gpa, options.params(options.size_hint), options.dictionary) };
}

pub fn deinit(s: *Compress) void {
    s.encoder.deinit();
    s.* = undefined;
}

fn run(s: *Compress, op: encode.Operation, in: *[]const u8, out: *[]u8) Error!void {
    s.encoder.compressStream(op, in, out) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        // The states below are checked first; what is left is metadata
        // misuse.
        error.InvalidOperation => return error.MetadataPending,
    };
}

fn check(s: *const Compress) Error!void {
    if (s.encoder.stream_state == .finished) return error.Finished;
    if (s.encoder.remaining_metadata_bytes != std.math.maxInt(u32)) return error.MetadataPending;
}

/// Accept input and drain ready bytes. Output an earlier flush left
/// waiting goes first.
pub fn write(s: *Compress, in: []const u8, out: []u8) Error!Step {
    try s.check();
    var rest = in;
    var room = out;
    if (s.encoder.stream_state != .processing) {
        var none: []const u8 = &.{};
        try s.run(.process, &none, &room);
        if (s.encoder.stream_state != .processing) return .{ .in_len = 0, .out_len = out.len - room.len };
    }
    try s.run(.process, &rest, &room);
    return .{ .in_len = in.len - rest.len, .out_len = out.len - room.len };
}

/// Encode what has been accepted, ending at a byte boundary, and drain it.
/// Call until `done`, then resume `write`.
pub fn flush(s: *Compress, out: []u8) Error!Drain {
    try s.check();
    var none: []const u8 = &.{};
    var room = out;
    try s.run(.flush, &none, &room);
    return .{ .out_len = out.len - room.len, .done = s.encoder.stream_state == .processing and !s.encoder.hasMoreOutput() };
}

/// End the stream. Call until `done`.
pub fn finish(s: *Compress, out: []u8) Error!Drain {
    if (s.encoder.remaining_metadata_bytes != std.math.maxInt(u32)) return error.MetadataPending;
    var none: []const u8 = &.{};
    var room = out;
    try s.run(.finish, &none, &room);
    return .{ .out_len = out.len - room.len, .done = s.encoder.isFinished() };
}

/// Write `data` as a metadata block, after flushing what has been
/// accepted. Call with `data[in_len..]` of the same bytes until `done`.
pub fn metadata(s: *Compress, data: []const u8, out: []u8) Error!MetadataStep {
    if (s.encoder.stream_state == .finished) return error.Finished;
    if (data.len > 1 << 24) return error.MetadataTooLong;
    var rest = data;
    var room = out;
    try s.run(.emit_metadata, &rest, &room);
    return .{ .in_len = data.len - rest.len, .out_len = out.len - room.len, .done = s.encoder.remaining_metadata_bytes == std.math.maxInt(u32) and !s.encoder.hasMoreOutput() };
}

/// An `Io.Writer` over an existing compressor. `buffer` stages input;
/// the compressor is deinitialized separately.
pub const Writer = struct {
    interface: Io.Writer,
    state: *Compress,
    output: *Io.Writer,
    failure: ?Error = null,

    pub fn init(state: *Compress, output: *Io.Writer, buffer: []u8) Writer {
        return .{ .state = state, .output = output, .interface = .{ .vtable = &.{ .drain = writeData, .flush = flushInput }, .buffer = buffer, .end = 0 } };
    }

    pub fn err(w: *const Writer) ?Error {
        return w.failure;
    }

    /// End the stream: what is buffered, then the last meta-block.
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
        const w: *Writer = @alignCast(@fieldParentPtr("interface", interface)); // aegis: no-danger: interface is the embedded Writer field
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

    fn drainStream(w: *Writer, end: bool) Io.Writer.Error!void {
        var buffer: [4096]u8 = undefined;
        while (true) {
            const result = (if (end) w.state.finish(&buffer) else w.state.flush(&buffer)) catch |failure| {
                w.failure = failure;
                return error.WriteFailed;
            };
            try w.output.writeAll(buffer[0..result.out_len]);
            if (result.done) return;
        }
    }

    fn flushInput(interface: *Io.Writer) Io.Writer.Error!void {
        const w: *Writer = @alignCast(@fieldParentPtr("interface", interface)); // aegis: no-danger: interface is the embedded Writer field
        try w.writeSlice(interface.buffered());
        interface.end = 0;
        try w.drainStream(false);
    }
};
