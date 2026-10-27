//! Resumable LZMA encoding: raw LZMA, raw LZMA2 or a `.lzma` file from
//! input in pieces of any size, the engine the whole-buffer encoder's, so
//! the stream is the same bytes however the input arrives (up to `flush`,
//! which ends an LZMA2 chunk where it is called).
//!
//! Input goes to a window of the dictionary and a stage after it; the
//! parser runs while its lookahead is in the window, and the window
//! slides when the stage is full. LZMA2 chunks, and raw LZMA as it
//! comes, are coded into a staging buffer the caller drains.

const Compress = @This();

const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;
const Lzma = @import("Compressor.zig");
const encode = @import("encode.zig");
const optimum = @import("optimum.zig");
const finders = @import("Finder.zig");

pub const Format = Lzma.Format;

pub const Options = struct {
    lzma: Lzma.Options = .preset(6, false),
    format: Format = .lzma2,
    /// The input's size, checked by `finish`; a `.lzma` header with
    /// `size_known` names it.
    pledged_size: ?aegis.units.Bytes(u64) = null,

    fn pledged(o: Options) ?u64 {
        return if (o.pledged_size) |n| n.raw() else null;
    }

    pub fn valid(o: Options) bool {
        if (!o.lzma.valid()) return false;
        return switch (o.format) {
            .alone => |a| !a.size_known or o.pledged() != null,
            else => true,
        };
    }
};

pub const Step = struct { in_len: usize, out_len: usize };
pub const Drain = struct { out_len: usize, done: bool };
pub const InitError = std.mem.Allocator.Error || error{InvalidOptions};
pub const Error = error{
    /// `finish` saw another input size than pledged.
    SizeMismatch,
    /// The stream is finished, or failed.
    Finished,
    /// `flush` of raw LZMA or `.lzma`: only LZMA2 ends a chunk mid-stream.
    Unsupported,
};

const Phase = enum { active, finishing, done, failed };
/// `finish`: the input ends. `end`: the stream's last bytes are out.
/// `fail`: the pledged size was not met. `reset`: another stream begins.
const Event = enum { finish, end, fail, reset };
const Machine = aegis.state.Machine(Phase, Event, .{ .initial = .active, .terminal = &.{}, .edges = &.{
    .{ .from = .active, .on = .finish, .to = .finishing },
    .{ .from = .finishing, .on = .end, .to = .done },
    .{ .from = .active, .on = .fail, .to = .failed },
    .{ .from = .active, .on = .reset, .to = .active },
    .{ .from = .finishing, .on = .reset, .to = .active },
    .{ .from = .done, .on = .reset, .to = .active },
    .{ .from = .failed, .on = .reset, .to = .active },
} });

/// How far the parser reads ahead of its position: a run's input and the
/// longest match.
const lookahead = encode.loop_input_max + encode.match_len_max;
const output_len = 1 << 17;
const coder_bytes = std.mem.alignForward(usize, @sizeOf(encode.Coder), 64);

/// The bytes kept before the coding position: the dictionary, and an
/// LZMA2 chunk that may yet be stored (one stored is shorter than 64 KiB
/// and what the parser read ahead).
fn keep(o: Options) usize {
    return @max(o.lzma.dictionary, Lzma.chunk_max + 2 * lookahead);
}

/// The window: what is kept, and a stage for new input, half the
/// dictionary or 1 MiB, so a slide moves the window at most twice per
/// dictionary of input.
fn windowLen(o: Options) usize {
    return keep(o) + @max(o.lzma.dictionary / 2, 1 << 20);
}

fn sizes(o: Options) finders.Sizes {
    return .of(o.lzma.match_finder, o.lzma.dictionary, null);
}

options: Options,
coder: *encode.Coder,
finder: Lzma.Finders,
chunks: Lzma.Chunks,
window: []u8,
filled: usize = 0,
output: []u8,
pending: usize = 0,
pending_end: usize = 0,
total: u64 = 0,
phase: Phase = .active,
/// An LZMA2 chunk is begun and not ended.
in_chunk: bool = false,
/// Raw LZMA: the coder writes into `output` (after a `.lzma` header).
started: bool = false,
/// The stream's last bytes are queued.
ended: bool = false,
owned: []align(64) u8 = &.{},
gpa: std.mem.Allocator = undefined,

/// The bytes `initBuffer` needs: the coder, the finder's tables, the
/// window and the staging buffer.
pub fn memory(options: Options) usize {
    return coder_bytes + sizes(options).memory(options.lzma.match_finder) + windowLen(options) + output_len;
}

pub fn init(gpa: std.mem.Allocator, options: Options) InitError!Compress {
    if (!options.valid()) return error.InvalidOptions;
    const buffer = try gpa.alignedAlloc(u8, .@"64", memory(options));
    var s = initBuffer(buffer, options) catch unreachable;
    s.owned = buffer;
    s.gpa = gpa;
    return s;
}

/// A compressor in caller memory (`buffer.len >= memory(options)`).
pub fn initBuffer(buffer: []align(64) u8, options: Options) error{InvalidOptions}!Compress {
    if (!options.valid()) return error.InvalidOptions;
    std.debug.assert(buffer.len >= memory(options));
    const o = options.lzma;
    const coder = std.mem.bytesAsValue(encode.Coder, buffer[0..@sizeOf(encode.Coder)]);
    coder.* = .{};
    coder.init(o.properties, o.tuning());
    const z = sizes(options);
    const tables_len = z.memory(o.match_finder);
    const tables: []align(64) u8 = buffer[coder_bytes..][0..tables_len];
    var finder: Lzma.Finders = switch (o.match_finder) {
        inline else => |k| @unionInit(Lzma.Finders, @tagName(k), .init(tables, z, o.dictionary, o.niceLen(), o.searchDepth())),
    };
    switch (finder) {
        inline else => |*f| f.reset(),
    }
    const window = buffer[coder_bytes + tables_len ..][0..windowLen(options)];
    return .{
        .options = options,
        .coder = coder,
        .finder = finder,
        .chunks = .{ .props = o.properties },
        .window = window,
        .output = buffer[coder_bytes + tables_len + window.len ..][0..output_len],
    };
}

pub fn deinit(s: *Compress) void {
    if (s.owned.len != 0) s.gpa.free(s.owned);
    s.* = undefined;
}

/// Start another stream with the same options, keeping the memory.
pub fn reset(s: *Compress) void {
    const o = s.options.lzma;
    s.coder.init(o.properties, o.tuning());
    switch (s.finder) {
        inline else => |*f| f.reset(),
    }
    s.chunks = .{ .props = o.properties };
    s.filled = 0;
    s.pending = 0;
    s.pending_end = 0;
    s.total = 0;
    s.in_chunk = false;
    s.started = false;
    s.ended = false;
    switch (s.phase) {
        inline else => |p| s.go(p, .reset),
    }
}

fn go(s: *Compress, comptime from: Phase, comptime on: Event) void {
    s.phase = comptime Machine.after(from, on);
}

/// Take input and give output as far as each allows.
pub fn write(s: *Compress, in: []const u8, out: []u8) Error!Step {
    if (s.phase != .active) return error.Finished;
    var ip: usize = 0;
    var op: usize = 0;
    while (true) {
        op += s.drain(out[op..]);
        if (s.pending != s.pending_end) break;
        if (s.produce(false)) continue;
        if (ip == in.len) break;
        if (s.filled == s.window.len) s.slide();
        const n = @min(in.len - ip, s.window.len - s.filled);
        @memcpy(s.window[s.filled..][0..n], in[ip..][0..n]);
        s.filled += n;
        s.total += n;
        ip += n;
    }
    return .{ .in_len = ip, .out_len = op };
}

/// LZMA2: code every byte taken and end the chunk, so a decoder given the
/// output so far gives that input back. Call until `done`.
pub fn flush(s: *Compress, out: []u8) Error!Drain {
    if (s.phase != .active) return error.Finished;
    if (s.options.format != .lzma2) return error.Unsupported;
    var op: usize = 0;
    while (true) {
        op += s.drain(out[op..]);
        if (s.pending != s.pending_end) return .{ .out_len = op, .done = false };
        if (!s.produce(true)) return .{ .out_len = op, .done = true };
    }
}

/// End the stream, checking the pledged size. Call until `done`.
pub fn finish(s: *Compress, out: []u8) Error!Drain {
    switch (s.phase) {
        .failed => return error.SizeMismatch,
        .done => return .{ .out_len = 0, .done = true },
        .active => {
            if (s.options.pledged()) |n| if (n != s.total) {
                s.go(.active, .fail);
                return error.SizeMismatch;
            };
            s.go(.active, .finish);
        },
        .finishing => {},
    }
    var op: usize = 0;
    while (true) {
        op += s.drain(out[op..]);
        if (s.pending != s.pending_end) return .{ .out_len = op, .done = false };
        if (s.produce(true)) continue;
        if (!s.ended) {
            s.end();
            continue;
        }
        s.go(.finishing, .end);
        return .{ .out_len = op, .done = true };
    }
}

fn drain(s: *Compress, out: []u8) usize {
    const n = @min(out.len, s.pending_end - s.pending);
    @memcpy(out[0..n], s.output[s.pending..][0..n]);
    s.pending += n;
    return n;
}

/// The finder over the window: searching stops a lookahead short of its
/// end until the input is finishing.
fn feed(s: *const Compress, f: anytype, finishing: bool) void {
    f.buf = s.window[0..s.filled];
    f.finishing = finishing;
    f.read_limit = if (finishing) s.filled else s.filled -| lookahead;
}

/// Code what the window allows into `output` (drained); whether any
/// output is queued.
fn produce(s: *Compress, finishing: bool) bool {
    switch (s.finder) {
        inline else => |*f| {
            s.feed(f, finishing);
            return if (s.options.format == .lzma2) s.produceChunk(f) else s.produceRaw(f);
        },
    }
}

fn produceChunk(s: *Compress, f: anytype) bool {
    if (!s.in_chunk) {
        if (f.read_pos - f.read_ahead == s.filled) return false;
        s.chunks.begin(s.coder, s.output);
        s.in_chunk = true;
    }
    if (s.chunks.code(s.coder, f) == .need_input) return false;
    const n = s.chunks.end(s.coder, f, s.output) catch unreachable; // aegis: no-danger: output holds a chunk's header, 64 KiB and what may be stored
    s.queue(n);
    s.in_chunk = false;
    return true;
}

fn produceRaw(s: *Compress, f: anytype) bool {
    if (s.started) s.coder.rc.restart(s.output) else s.startRaw();
    _ = optimum.run(s.coder, f, .{ .limit = std.math.maxInt(usize), .budget = output_len - 4096 });
    if (s.coder.rc.pos == 0) return false;
    s.queue(s.coder.rc.pos);
    return true;
}

/// Raw LZMA's coder on `output`, after a `.lzma` header.
fn startRaw(s: *Compress) void {
    s.coder.rc = .init(s.output);
    if (s.options.format == .alone) {
        const a = s.options.format.alone;
        s.output[0] = s.options.lzma.properties.encode();
        std.mem.writeInt(u32, s.output[1..5], s.options.lzma.dictionary, .little);
        std.mem.writeInt(u64, s.output[5..13], if (a.size_known) s.options.pledged().? else std.math.maxInt(u64), .little);
        s.coder.rc.pos = Lzma.alone_header_len;
    }
    s.started = true;
}

fn queue(s: *Compress, n: usize) void {
    s.pending = 0;
    s.pending_end = n;
}

/// The stream's last bytes: LZMA2's end byte, or raw LZMA's end marker
/// (where the format has one) and the coder's flush.
fn end(s: *Compress) void {
    s.ended = true;
    switch (s.options.format) {
        .lzma2 => {
            s.output[0] = 0;
            s.queue(1);
        },
        .lzma1, .alone => {
            if (s.started) s.coder.rc.restart(s.output) else s.startRaw();
            const marker = switch (s.options.format) {
                .lzma1 => |o| o.end_marker,
                .alone => |o| !o.size_known,
                .lzma2 => false,
            };
            if (marker) s.coder.marker();
            s.coder.rc.flush();
            s.queue(s.coder.rc.pos);
        },
    }
}

/// Room for new input: the window moved back to what is kept.
fn slide(s: *Compress) void {
    switch (s.finder) {
        inline else => |*f| {
            const from = (f.read_pos - f.read_ahead) -| keep(s.options);
            std.debug.assert(from != 0);
            @memmove(s.window[0 .. s.filled - from], s.window[from..s.filled]);
            s.filled -= from;
            f.read_pos -= from;
            f.read_limit -|= from;
            f.tables.slide(from);
        },
    }
}

/// An `Io.Writer` over an existing compressor. `buffer` stages input;
/// the compressor still owns its memory and is deinitialized separately.
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

    /// The buffered input written and the stream ended.
    pub fn finish(w: *Writer) Io.Writer.Error!void {
        try w.writeSlice(w.interface.buffered());
        w.interface.end = 0;
        var buffer: [4096]u8 = undefined;
        while (true) {
            const result = w.state.finish(&buffer) catch |failure| {
                w.failure = failure;
                return error.WriteFailed;
            };
            try w.output.writeAll(buffer[0..result.out_len]);
            if (result.done) return;
        }
    }

    fn writeSlice(w: *Writer, in: []const u8) Io.Writer.Error!void {
        var at: usize = 0;
        var buffer: [4096]u8 = undefined;
        while (true) {
            const step = w.state.write(in[at..], &buffer) catch |failure| {
                w.failure = failure;
                return error.WriteFailed;
            };
            at += step.in_len;
            try w.output.writeAll(buffer[0..step.out_len]);
            if (at == in.len and step.out_len < buffer.len) return;
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

    /// The buffered input written; LZMA2 also ends its chunk, so what is
    /// out decodes to everything written (raw LZMA only writes).
    fn flushInput(interface: *Io.Writer) Io.Writer.Error!void {
        const w: *Writer = @alignCast(@fieldParentPtr("interface", interface)); // aegis: no-danger: interface is the embedded Writer field
        try w.writeSlice(interface.buffered());
        interface.end = 0;
        if (w.state.options.format != .lzma2) return;
        var buffer: [4096]u8 = undefined;
        while (true) {
            const result = w.state.flush(&buffer) catch |failure| {
                w.failure = failure;
                return error.WriteFailed;
            };
            try w.output.writeAll(buffer[0..result.out_len]);
            if (result.done) return;
        }
    }
};
