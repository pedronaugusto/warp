//! Resumable `.xz` encoding: one stream from input in pieces of any size,
//! the filters applied forward through a pipe, LZMA2 from the resumable
//! LZMA encoder, the check over the input as it comes.
//!
//! Without `block_size` the stream is one block whose header names no
//! sizes, as `xz` writes alone, and its LZMA2 goes straight to the
//! caller's output. With it, each block of that much input is staged
//! whole, so its header names both sizes (as `xz -T` writes) and the
//! parallel decoders split the stream. `flush` ends a block either way.

const Compress = @This();

const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const format = @import("format.zig");
const filter_ = @import("filter.zig");
const Lzma = @import("../lzma/Compressor.zig");
const LzmaCompress = @import("../lzma/Compress.zig");
const Whole = @import("Compressor.zig");
const Crc32 = @import("../checksum/crc32.zig").Crc32;

pub const Check = format.Check;
pub const Filter = filter_.Filter;

pub const Options = struct {
    lzma: Lzma.Options = .preset(6, false),
    check: Check = .crc64,
    /// At most three filters before LZMA2, applied in order.
    filters: []const Filter = &.{},
    /// Input per block, each staged so its header names its sizes; null:
    /// one block, its header without sizes.
    block_size: ?u64 = null,
    /// The input's size, checked by `finish`.
    pledged_size: ?aegis.units.Bytes(u64) = null,

    fn pledged(o: Options) ?u64 {
        return if (o.pledged_size) |n| n.raw() else null;
    }

    pub fn valid(o: Options) bool {
        const whole: Whole.Options = .{ .lzma = o.lzma, .check = o.check, .filters = o.filters, .block_size = o.block_size };
        return whole.valid();
    }
};

pub const Step = struct { in_len: usize, out_len: usize };
pub const Drain = struct { out_len: usize, done: bool };
pub const InitError = Allocator.Error || error{InvalidOptions};
pub const Error = Allocator.Error || error{
    /// `finish` saw another input size than pledged.
    SizeMismatch,
    /// The stream is finished, or failed.
    Finished,
};

const Phase = enum { header, idle, block, closing, ending, done, failed };
/// `start`: the stream header is out. `open`: a block begins. `close`: its
/// input ends. `closed`: its last bytes are queued. `end`: the input ends
/// between blocks. `out`: the index and footer are out. `fail`: the
/// pledged size was not met. `reset`: another stream begins.
const Event = enum { start, open, close, closed, end, out, fail, reset };
const Machine = aegis.state.Machine(Phase, Event, .{ .initial = .header, .terminal = &.{}, .edges = &.{
    .{ .from = .header, .on = .reset, .to = .header },
    .{ .from = .idle, .on = .reset, .to = .header },
    .{ .from = .block, .on = .reset, .to = .header },
    .{ .from = .closing, .on = .reset, .to = .header },
    .{ .from = .ending, .on = .reset, .to = .header },
    .{ .from = .done, .on = .reset, .to = .header },
    .{ .from = .failed, .on = .reset, .to = .header },
    .{ .from = .header, .on = .start, .to = .idle },
    .{ .from = .idle, .on = .open, .to = .block },
    .{ .from = .block, .on = .close, .to = .closing },
    .{ .from = .closing, .on = .closed, .to = .idle },
    .{ .from = .idle, .on = .end, .to = .ending },
    .{ .from = .ending, .on = .out, .to = .done },
    .{ .from = .header, .on = .fail, .to = .failed },
    .{ .from = .idle, .on = .fail, .to = .failed },
    .{ .from = .block, .on = .fail, .to = .failed },
} });

const pipe_len = 1 << 16;

options: Options,
lzma: LzmaCompress,
gpa: Allocator,
phase: Phase = .header,
hasher: format.Hasher,
/// The filters' pipe: input not yet given to LZMA2, converted by each
/// filter up to its count.
pipe: []u8 = &.{},
fill: usize = 0,
converted: [3]usize = @splat(0),
states: [3]filter_.State = undefined,
/// The current block: input taken, LZMA2 out, its header's length.
block_in: u64 = 0,
block_out: u64 = 0,
header_len: usize = 0,
/// A block's LZMA2, staged for its header (with `block_size`).
staged: []u8 = &.{},
/// The index's records so far, and their count.
records: std.ArrayList(u8) = .empty,
count: u64 = 0,
total: u64 = 0,
/// Bytes queued for the caller: up to three pieces, in order.
pieces: [3][]const u8 = @splat(&.{}),
small: [96]u8 = undefined,
tail: std.ArrayList(u8) = .empty,

pub fn init(gpa: Allocator, options: Options) InitError!Compress {
    if (!options.valid()) return error.InvalidOptions;
    var s: Compress = .{
        .options = options,
        .lzma = try .init(gpa, .{ .lzma = options.lzma }),
        .gpa = gpa,
        .hasher = .init(options.check),
    };
    errdefer s.lzma.deinit();
    if (options.filters.len != 0) s.pipe = try gpa.alloc(u8, pipe_len);
    errdefer gpa.free(s.pipe);
    if (options.block_size) |b| s.staged = try gpa.alloc(u8, Lzma.bound(.lzma2, @intCast(b)));
    return s;
}

pub fn deinit(s: *Compress) void {
    s.lzma.deinit();
    s.gpa.free(s.pipe);
    s.gpa.free(s.staged);
    s.records.deinit(s.gpa);
    s.tail.deinit(s.gpa);
    s.* = undefined;
}

/// Start another stream with the same options, keeping the memory.
pub fn reset(s: *Compress) void {
    s.lzma.reset();
    s.records.clearRetainingCapacity();
    s.count = 0;
    s.total = 0;
    s.pieces = @splat(&.{});
    switch (s.phase) {
        inline else => |p| s.go(p, .reset),
    }
}

fn go(s: *Compress, comptime from: Phase, comptime on: Event) void {
    s.phase = comptime Machine.after(from, on);
}

/// Take input and give output as far as each allows.
pub fn write(s: *Compress, in: []const u8, out: []u8) Error!Step {
    var ip: usize = 0;
    var op: usize = 0;
    while (true) {
        op += s.drain(out[op..]);
        if (s.queued()) break;
        switch (s.phase) {
            .header => s.start(),
            .idle => {
                if (ip == in.len) break;
                s.open();
            },
            .block => {
                if (s.options.block_size) |b| if (s.block_in == b) {
                    s.go(.block, .close);
                    continue;
                };
                const room: u64 = if (s.options.block_size) |b| b - s.block_in else std.math.maxInt(u64);
                const part = in[ip..][0..@intCast(@min(in.len - ip, room))];
                const step = try s.feed(part, out, &op);
                ip += step.in_len;
                if (step.in_len == 0 and step.out_len == 0) break;
            },
            .closing => if (!try s.close(out, &op)) break,
            .ending, .done, .failed => return error.Finished,
        }
    }
    return .{ .in_len = ip, .out_len = op };
}

/// End the current block, so what is out decodes to every byte taken.
/// Call until `done`.
pub fn flush(s: *Compress, out: []u8) Error!Drain {
    var op: usize = 0;
    while (true) {
        op += s.drain(out[op..]);
        if (s.queued()) return .{ .out_len = op, .done = false };
        switch (s.phase) {
            .header => s.start(),
            .idle => return .{ .out_len = op, .done = true },
            .block => s.go(.block, .close),
            .closing => if (!try s.close(out, &op)) return .{ .out_len = op, .done = false },
            .ending, .done, .failed => return error.Finished,
        }
    }
}

/// End the stream, checking the pledged size. Call until `done`.
pub fn finish(s: *Compress, out: []u8) Error!Drain {
    if (s.options.pledged()) |n| if (n != s.total) switch (s.phase) {
        inline .header, .idle, .block => |p| {
            s.go(p, .fail);
            return error.SizeMismatch;
        },
        else => {},
    };
    var op: usize = 0;
    while (true) {
        op += s.drain(out[op..]);
        if (s.queued()) return .{ .out_len = op, .done = false };
        switch (s.phase) {
            .header => s.start(),
            .block => s.go(.block, .close),
            .closing => if (!try s.close(out, &op)) return .{ .out_len = op, .done = false },
            .idle => try s.end(),
            .ending => s.go(.ending, .out),
            .done => return .{ .out_len = op, .done = true },
            .failed => return error.SizeMismatch,
        }
    }
}

fn queued(s: *const Compress) bool {
    for (s.pieces) |p| if (p.len != 0) return true;
    return false;
}

fn drain(s: *Compress, out: []u8) usize {
    var op: usize = 0;
    for (&s.pieces) |*p| {
        const n = @min(out.len - op, p.len);
        @memcpy(out[op..][0..n], p.*[0..n]);
        p.* = p.*[n..];
        op += n;
    }
    return op;
}

fn start(s: *Compress) void {
    format.writeStreamHeader(s.small[0..format.header_len], s.options.check);
    s.pieces[0] = s.small[0..format.header_len];
    s.go(.header, .start);
}

fn spec(s: *const Compress, compressed: ?u64, uncompressed: ?u64) format.BlockSpec {
    return .{ .compressed = compressed, .uncompressed = uncompressed, .filters = s.options.filters, .dictionary = s.options.lzma.dictionary };
}

fn open(s: *Compress) void {
    s.block_in = 0;
    s.block_out = 0;
    s.hasher = .init(s.options.check);
    s.fill = 0;
    s.converted = @splat(0);
    for (s.options.filters, 0..) |f, i| s.states[i] = .init(f);
    if (s.options.block_size == null) {
        const open_spec = s.spec(null, null);
        s.header_len = format.blockHeaderLen(open_spec);
        format.writeBlockHeader(&s.small, open_spec);
        s.pieces[0] = s.small[0..s.header_len];
    }
    s.go(.idle, .open);
}

/// Where LZMA2 goes: the caller's output, or the block's stage.
fn dest(s: *Compress, out: []u8, op: usize) []u8 {
    return if (s.options.block_size == null) out[op..] else s.staged[@intCast(s.block_out)..];
}

/// Input into the block: through the filters' pipe, or straight to LZMA2.
fn feed(s: *Compress, part: []const u8, out: []u8, op: *usize) Error!Step {
    if (s.options.filters.len == 0) {
        const step = s.lzma.write(part, s.dest(out, op.*)) catch unreachable;
        s.hasher.update(part[0..step.in_len]);
        s.taken(step.in_len, step.out_len, op);
        return .{ .in_len = step.in_len, .out_len = step.out_len };
    }
    const n = @min(part.len, s.pipe.len - s.fill);
    @memcpy(s.pipe[s.fill..][0..n], part[0..n]);
    s.hasher.update(part[0..n]);
    s.fill += n;
    s.taken(n, 0, op);
    s.convert(false);
    const out_len = s.pass(out, op);
    return .{ .in_len = n, .out_len = out_len };
}

fn taken(s: *Compress, in_len: usize, out_len: usize, op: *usize) void {
    s.block_in += in_len;
    s.total += in_len;
    s.block_out += out_len;
    if (s.options.block_size == null) op.* += out_len;
}

/// The pipe's bytes every filter is done with, given to LZMA2; its output.
fn pass(s: *Compress, out: []u8, op: *usize) usize {
    const ready = s.converted[s.options.filters.len - 1];
    const step = s.lzma.write(s.pipe[0..ready], s.dest(out, op.*)) catch unreachable;
    s.block_out += step.out_len;
    if (s.options.block_size == null) op.* += step.out_len;
    const n = step.in_len;
    @memmove(s.pipe[0 .. s.fill - n], s.pipe[n..s.fill]);
    s.fill -= n;
    for (s.converted[0..s.options.filters.len]) |*c| c.* -= n;
    return step.out_len;
}

/// Each filter forward over what the one before it is done with; at the
/// block's end, the tails they leave pass as they are.
fn convert(s: *Compress, ended: bool) void {
    for (s.options.filters, 0..) |f, i| {
        const avail = if (i == 0) s.fill else s.converted[i - 1];
        s.converted[i] += filter_.run(f, &s.states[i], s.pipe[s.converted[i]..avail], true);
        const before_done = i == 0 or s.converted[i - 1] == s.fill;
        if (ended and before_done) s.converted[i] = avail;
    }
}

/// The block's end: the pipe given to LZMA2, LZMA2 finished, then its
/// header (staged blocks), padding and check queued and its record kept.
/// Whether it is closed (else `out` is full).
fn close(s: *Compress, out: []u8, op: *usize) Error!bool {
    if (s.fill != 0) {
        s.convert(true);
        const before = s.fill;
        const out_len = s.pass(out, op);
        if (s.fill == before and out_len == 0) return false;
        return true;
    }
    const d = s.lzma.finish(s.dest(out, op.*)) catch unreachable;
    s.block_out += d.out_len;
    if (s.options.block_size == null) op.* += d.out_len;
    if (!d.done) return false;
    const data = s.block_out;
    var at: usize = 0;
    if (s.options.block_size != null) {
        const sized = s.spec(data, s.block_in);
        s.header_len = format.blockHeaderLen(sized);
        format.writeBlockHeader(&s.small, sized);
        at = s.header_len;
        s.pieces[0] = s.small[0..at];
        s.pieces[1] = s.staged[0..@intCast(data)];
    }
    const padding: usize = @intCast((4 - data % 4) % 4);
    const check = s.options.check.size();
    @memset(s.small[at..][0..padding], 0);
    s.hasher.final(s.small[at + padding ..][0..check]);
    s.pieces[2] = s.small[at..][0 .. padding + check];
    var vli: [20]u8 = undefined;
    var pos: usize = 0;
    format.putVli(&vli, &pos, s.header_len + data + check);
    format.putVli(&vli, &pos, s.block_in);
    try s.records.appendSlice(s.gpa, vli[0..pos]);
    s.count += 1;
    s.lzma.reset();
    s.go(.closing, .closed);
    return true;
}

/// The index of the blocks' records and the footer, queued.
fn end(s: *Compress) Error!void {
    s.tail.clearRetainingCapacity();
    var vli: [10]u8 = undefined;
    var pos: usize = 0;
    format.putVli(&vli, &pos, s.count);
    try s.tail.append(s.gpa, 0);
    try s.tail.appendSlice(s.gpa, vli[0..pos]);
    try s.tail.appendSlice(s.gpa, s.records.items);
    while (s.tail.items.len % 4 != 0) try s.tail.append(s.gpa, 0);
    var crc: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc, Crc32.hash(s.tail.items), .little);
    try s.tail.appendSlice(s.gpa, &crc);
    const index_len = s.tail.items.len;
    try s.tail.appendNTimes(s.gpa, 0, format.footer_len);
    format.writeStreamFooter(s.tail.items[index_len..][0..format.footer_len], index_len, s.options.check);
    s.pieces[0] = s.tail.items;
    s.go(.idle, .end);
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
        try w.drainWith(Compress.finish);
    }

    fn drainWith(w: *Writer, comptime f: fn (*Compress, []u8) Error!Drain) Io.Writer.Error!void {
        var buffer: [4096]u8 = undefined;
        while (true) {
            const result = f(w.state, &buffer) catch |failure| {
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

    /// The buffered input written and the block ended.
    fn flushInput(interface: *Io.Writer) Io.Writer.Error!void {
        const w: *Writer = @alignCast(@fieldParentPtr("interface", interface)); // aegis: no-danger: interface is the embedded Writer field
        try w.writeSlice(interface.buffered());
        interface.end = 0;
        try w.drainWith(Compress.flush);
    }
};
