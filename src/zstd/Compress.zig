//! Resumable compression over the whole-buffer encoder's match and
//! entropy engines. Input chunk boundaries do not choose block boundaries.
const Compress = @This();
const std = @import("std");
const Io = std.Io;
const Encoder = @import("Encoder.zig");
const window_ = @import("match/window.zig");
const encode = @import("encode.zig");
const params_ = @import("params.zig");
const Dictionary = @import("Dictionary.zig");

pub const Options = struct {
    level: i32 = params_.default_level,
    tuning: Encoder.Tuning = .{},
    frame: Encoder.Frame = .{},
    pledged_size: ?u64 = null,
    dictionary: ?*const Dictionary = null,
};
pub const Step = struct { in_len: usize, out_len: usize };
pub const Drain = struct { out_len: usize, done: bool };
pub const Error = error{ SizeMismatch, Finished };

const Phase = enum { active, flushing, finishing, done, failed };
options: Options,
encoder: Encoder,
params: Encoder.Params,
window: []u8,
output: []u8,
pending: usize = 0,
pending_end: usize = 0,
history: usize = 0,
have: usize = 0,
base: u32 = 2,
block_max: usize,
reps: [3]u32 = .{ 1, 4, 8 },
prev: usize = 0,
first: bool = true,
savings: i64 = 0,
total: u64 = 0,
hash: std.hash.XxHash64 = .init(0),
phase: Phase = .active,
last_emitted: bool = false,
checksum_emitted: bool = false,
owned: []align(64) u8 = &.{},
gpa: std.mem.Allocator = undefined,

fn encoderOptions(options: Options) Encoder.Options {
    return .{ .level = options.level, .tuning = options.tuning, .dictionary = options.dictionary, .max_input = if (options.pledged_size) |n| if (n <= std.math.maxInt(usize)) @intCast(n) else null else null };
}

fn blockMax(p: Encoder.Params) usize {
    return @min(encode.block_max, @as(usize, 1) << p.window_log);
}

/// Exact storage for tables, the retained history, input and pending output.
pub fn memory(options: Options) usize {
    const p = Encoder.resolve(encoderOptions(options), options.pledged_size);
    const block = blockMax(p);
    return std.mem.alignForward(usize, Encoder.memory(encoderOptions(options)) + (@as(usize, 1) << p.window_log) + 2 * block + 3 * 197 + 22, 64);
}

pub fn init(gpa: std.mem.Allocator, options: Options) std.mem.Allocator.Error!Compress {
    const buffer = try gpa.alignedAlloc(u8, .@"64", memory(options));
    var s = initBuffer(buffer, options);
    s.owned = buffer;
    s.gpa = gpa;
    return s;
}

/// Tables and staging in aligned caller storage of `memory(options)` bytes.
pub fn initBuffer(buffer: []align(64) u8, options: Options) Compress {
    std.debug.assert(buffer.len >= memory(options));
    const enc_options = encoderOptions(options);
    const enc_size = Encoder.memory(enc_options);
    const p = Encoder.resolve(enc_options, options.pledged_size);
    const block = blockMax(p);
    const window_size = (@as(usize, 1) << p.window_log) + block;
    var s: Compress = .{ .options = options, .encoder = Encoder.initBuffer(buffer[0..enc_size], enc_options), .params = p, .block_max = block, .window = buffer[enc_size..][0..window_size], .output = buffer[enc_size + window_size ..][0 .. block + 3 * 197 + 22] };
    s.startFrame();
    return s;
}

pub fn deinit(s: *Compress) void {
    if (s.owned.len != 0) s.gpa.free(s.owned);
    s.* = undefined;
}

/// Start another frame, retaining the tables' allocation.
pub fn reset(s: *Compress) void {
    s.base += @intCast(s.history + s.have + 1);
    if (s.base > 1 << 29) {
        s.encoder.reduceIndices(s.base - 2);
        s.base = 2;
    }
    s.pending = 0;
    s.history = 0;
    s.have = 0;
    s.total = 0;
    s.reps = .{ 1, 4, 8 };
    s.prev = 0;
    s.first = true;
    s.savings = 0;
    s.hash = .init(0);
    s.phase = .active;
    s.last_emitted = false;
    s.checksum_emitted = false;
    s.startFrame();
}

fn startFrame(s: *Compress) void {
    s.reps = s.encoder.initialReps();
    s.encoder.prepare(s.params, s.base);
    var frame = s.options.frame;
    frame.content_size = frame.content_size and s.options.pledged_size != null;
    s.pending_end = s.encoder.header(s.output, s.params, s.options.pledged_size orelse 0, frame) catch unreachable; // unreachable: output reserves the maximum 18-byte frame header
}

/// Accept input and drain ready bytes. A full final block stays staged
/// until more input arrives or `finish` declares it final.
pub fn write(s: *Compress, in: []const u8, out: []u8) Error!Step {
    if (s.phase != .active) return error.Finished;
    var ip: usize = 0;
    var op: usize = 0;
    while (true) {
        op += s.drain(out[op..]);
        if (s.pending != s.pending_end) break;
        if (ip == in.len) break;
        if (s.have == s.block_max) {
            s.emit(false);
            continue;
        }
        const n = @min(in.len - ip, s.block_max - s.have);
        @memcpy(s.window[s.history + s.have ..][0..n], in[ip..][0..n]);
        if (s.options.frame.checksum) s.hash.update(in[ip..][0..n]);
        s.have += n;
        ip += n;
        s.total += n;
    }
    return .{ .in_len = ip, .out_len = op };
}

/// End the current block and drain every byte accepted so far. Call until
/// `done`, then resume `write`. Repeated empty flushes emit no blocks.
pub fn flush(s: *Compress, out: []u8) Error!Drain {
    if (s.phase != .active and s.phase != .flushing) return error.Finished;
    s.phase = .flushing;
    var op: usize = 0;
    while (true) {
        op += s.drain(out[op..]);
        if (s.pending != s.pending_end) return .{ .out_len = op, .done = false };
        if (s.have == 0) {
            s.phase = .active;
            return .{ .out_len = op, .done = true };
        }
        s.emit(false);
    }
}

/// End the frame, checking its pledged size. Call until `done`.
pub fn finish(s: *Compress, out: []u8) Error!Drain {
    if (s.phase == .failed) return error.SizeMismatch;
    if (s.options.pledged_size) |pledge| if (pledge != s.total) {
        s.phase = .failed;
        return error.SizeMismatch;
    };
    s.phase = .finishing;
    var op: usize = 0;
    while (true) {
        op += s.drain(out[op..]);
        if (s.pending != s.pending_end) return .{ .out_len = op, .done = false };
        if (!s.last_emitted) {
            s.emit(true);
            continue;
        }
        if (s.options.frame.checksum and !s.checksum_emitted) {
            std.mem.writeInt(u32, s.output[0..4], @truncate(s.hash.final()), .little);
            s.pending = 0;
            s.pending_end = 4;
            s.checksum_emitted = true;
            continue;
        }
        s.phase = .done;
        return .{ .out_len = op, .done = true };
    }
}

fn drain(s: *Compress, out: []u8) usize {
    const n = @min(out.len, s.pending_end - s.pending);
    @memcpy(out[0..n], s.output[s.pending..][0..n]);
    s.pending += n;
    return n;
}

fn emit(s: *Compress, finishing: bool) void {
    const len = Encoder.blockSize(s.window[s.history..][0..s.have], s.block_max, s.params.strategy, s.savings);
    const last = finishing and len == s.have;
    const end = s.history + len;
    s.encoder.store.reset();
    var next_reps = s.reps;
    if (len >= 7) {
        if (s.first and s.params.strategy == .btultra2 and len > 8) s.prime(end);
        var window: window_.Window = .{ .in = s.window[0 .. s.history + s.have], .start = s.base, .low = 0 };
        window.low = window.lowFor(end, s.params.window_log);
        const tail = s.encoder.search(s.params, window, &next_reps, s.history, end);
        s.encoder.store.storeLast(s.window[end - tail .. end]);
    } else s.encoder.store.storeLast(s.window[s.history..end]);
    s.encoder.mergeDictionary(s.window[0 .. s.history + s.have], s.history, end, s.total - s.have, s.params, s.reps, &next_reps);
    const raw = s.params.strategy == .fast and s.params.target_length > 0;
    const n = s.encoder.writeBlocks(s.params, s.window[s.history..end], s.output, raw, &s.reps, next_reps, &s.prev, s.first, last) catch unreachable; // unreachable: output holds raw input plus headers for all 197 possible partitions
    s.savings += @as(i64, @intCast(len)) - @as(i64, @intCast(n));
    s.pending = 0;
    s.pending_end = n;
    s.first = false;
    s.last_emitted = last;
    const keep = @min(end, @as(usize, 1) << s.params.window_log);
    const discard = end - keep;
    const buffered = s.history + s.have;
    if (discard != 0) @memmove(s.window[0 .. buffered - discard], s.window[discard..buffered]);
    s.history = keep;
    s.have -= len;
    s.base += @intCast(discard);
    if (s.base > 1 << 29) {
        const amount = s.base - 2;
        s.encoder.reduceIndices(amount);
        s.base = 2;
    }
}

fn prime(s: *Compress, end: usize) void {
    var reps = s.reps;
    _ = s.encoder.searchPrefix(s.params, .{ .in = s.window[0 .. s.history + s.have], .start = s.base, .low = s.base }, &reps, s.history, end);
    s.encoder.store.reset();
    s.base += @intCast(end);
    s.encoder.optimal.next = s.base;
    s.encoder.optimal.next3 = s.base;
}

/// An `Io.Writer` over an existing compressor. `buffer` stages input;
/// the compressor still owns its tables and is deinitialized separately.
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
