//! Raw LZMA or LZMA2 decoded in pieces: input and output of any size, the
//! window a ring in the caller's memory, the engine the whole-buffer
//! decoders' (`decode.zig`), so a stream is decoded or refused the same
//! however it arrives.
//!
//! The coder reads the caller's input in place and takes only the bytes it
//! read; a symbol the input cuts short (`range.symbol_max` bytes at most)
//! waits in a small stage, topped up from the next input until the coder
//! reads past it, so the stream's end is exact. Chunk headers and the range
//! coder's first bytes are gathered a byte at a time.

const Stream = @This();

const std = @import("std");
const aegis = @import("aegis");
const engine = @import("decode.zig");
const range = @import("range.zig");
const Diagnostic = @import("Diagnostic.zig");

pub const Format = union(enum) {
    /// LZMA: the size where known (the stream ends there, with or without
    /// an end marker), else the marker ends it.
    lzma1: struct { properties: engine.Properties, size: ?u64 },
    lzma2,
};

pub const Error = error{
    /// Data that breaks the format as liblzma reads it.
    InvalidStream,
};

pub const Status = enum { need_input, output_full, end };
pub const Step = struct { in_len: usize, out_len: usize, status: Status };

const Phase = enum { control, sizes, properties, start, lzma, copy, done };

/// `read`: a part is read and the next in order follows. `raw`: an LZMA
/// stream, no chunks. `end`: the end chunk, or LZMA's end. `properties`,
/// `lzma`, `copy`: a chunk's kind. `chunk`: a chunk's end.
const Event = enum { read, raw, end, properties, lzma, copy, chunk };

const Machine = aegis.state.Machine(Phase, Event, .{ .initial = .control, .terminal = &.{.done}, .edges = &.{
    .{ .from = .control, .on = .read, .to = .sizes },
    .{ .from = .control, .on = .raw, .to = .start },
    .{ .from = .control, .on = .end, .to = .done },
    .{ .from = .sizes, .on = .properties, .to = .properties },
    .{ .from = .sizes, .on = .lzma, .to = .start },
    .{ .from = .sizes, .on = .copy, .to = .copy },
    .{ .from = .properties, .on = .read, .to = .start },
    .{ .from = .start, .on = .read, .to = .lzma },
    .{ .from = .lzma, .on = .chunk, .to = .control },
    .{ .from = .lzma, .on = .end, .to = .done },
    .{ .from = .copy, .on = .chunk, .to = .control },
} });

const stage_len = 64;

coder: engine.Coder = .{},
ring: engine.Ring,
format: Format,
phase: Phase = .control,
/// The range coder's state between calls.
range_state: u32 = 0,
code: u32 = 0,
/// Bytes of a header being gathered: a chunk's sizes, or the coder's
/// first five bytes.
gather: [6]u8 = undefined,
gathered: u8 = 0,
/// The current chunk: its control byte, sizes, and compressed bytes left.
control: u8 = 0,
chunk_size: u32 = 0,
packed_left: u32 = 0,
need_reset: bool = true,
need_properties: bool = true,
/// A symbol cut short, its bytes taken.
stage: [stage_len]u8 = undefined,
held: usize = 0,
/// Input taken so far, for the diagnostic.
offset: u64 = 0,
fail_at: u64 = 0,
reason: Diagnostic.Reason = .truncated,

/// A stream over `window`, which holds at least `engine.dictionary(dict)`
/// bytes.
pub fn init(window: []u8, dict: u64, format: Format) Stream {
    var s: Stream = .{ .ring = .{ .buf = window, .dict_size = engine.dictionary(dict) }, .format = format };
    switch (format) {
        .lzma1 => |f| {
            s.coder.reset(f.properties);
            s.coder.left = f.size;
            s.coder.allow_marker = true;
            s.go(.control, .raw);
        },
        .lzma2 => {},
    }
    return s;
}

/// The one place the phase changes: along a declared edge.
fn go(s: *Stream, comptime from: Phase, comptime on: Event) void {
    s.phase = comptime Machine.after(from, on);
}

pub fn done(s: *const Stream) bool {
    return s.phase == .done;
}

fn fail(s: *Stream, at: u64, reason: Diagnostic.Reason) Error {
    s.fail_at = at;
    s.reason = reason;
    return error.InvalidStream;
}

/// Take input and give output as far as each allows.
pub fn decode(s: *Stream, in: []const u8, out: []u8) Error!Step {
    var ip: usize = 0;
    var op: usize = 0;
    defer s.offset += ip;
    while (true) switch (s.phase) {
        .done => return .{ .in_len = ip, .out_len = op, .status = .end },
        .control => {
            if (ip == in.len) return .{ .in_len = ip, .out_len = op, .status = .need_input };
            const at = s.offset + ip;
            const control = in[ip];
            ip += 1;
            if (control == 0) {
                s.go(.control, .end);
                continue;
            }
            if (control >= 0xe0 or control == 1) {
                s.need_properties = true;
                s.need_reset = true;
            } else if (s.need_reset) return s.fail(at, .dictionary_reset);
            if (control < 0x80 and control > 2) return s.fail(at, .control);
            if (control >= 0x80 and control < 0xc0 and s.need_properties) return s.fail(at, .properties_needed);
            s.control = control;
            s.gathered = 0;
            s.go(.control, .read);
        },
        .sizes => {
            const want: u8 = if (s.control >= 0x80) 4 else 2;
            while (s.gathered < want) {
                if (ip == in.len) return .{ .in_len = ip, .out_len = op, .status = .need_input };
                s.gather[s.gathered] = in[ip];
                s.gathered += 1;
                ip += 1;
            }
            const g = s.gather;
            if (s.control >= 0x80) {
                s.chunk_size = ((@as(u32, s.control & 0x1f) << 16) | (@as(u32, g[0]) << 8) | g[1]) + 1;
                s.packed_left = ((@as(u32, g[2]) << 8) | g[3]) + 1;
            } else s.chunk_size = ((@as(u32, g[0]) << 8) | g[1]) + 1;
            if (s.need_reset) {
                s.need_reset = false;
                s.ring.reset();
            }
            if (s.control >= 0xc0) {
                s.go(.sizes, .properties);
            } else if (s.control >= 0x80) {
                if (s.control >= 0xa0) s.coder.reset(s.coder.props);
                s.startChunk();
                s.go(.sizes, .lzma);
            } else s.go(.sizes, .copy);
        },
        .properties => {
            if (ip == in.len) return .{ .in_len = ip, .out_len = op, .status = .need_input };
            const props = engine.Properties.parse(in[ip]) orelse return s.fail(s.offset + ip, .properties);
            ip += 1;
            s.need_properties = false;
            s.coder.reset(props);
            s.startChunk();
            s.go(.properties, .read);
        },
        .start => {
            while (s.gathered < 5) {
                if (ip == in.len) return .{ .in_len = ip, .out_len = op, .status = .need_input };
                if (s.format == .lzma2 and s.gathered >= s.packed_left) return s.fail(s.offset + ip, .chunk_size);
                s.gather[s.gathered] = in[ip];
                s.gathered += 1;
                ip += 1;
            }
            if (s.gather[0] != 0) return s.fail(s.offset + ip - 5, .range_start);
            s.range_state = 0xffff_ffff;
            s.code = std.mem.readInt(u32, s.gather[1..5], .big);
            if (s.format == .lzma2) {
                // Each of the five bytes was inside the chunk.
                aegis.assert.invariant(s.packed_left >= 5, "s.packed_left >= 5");
                s.packed_left -= 5;
            }
            s.go(.start, .read);
        },
        .lzma => {
            const status = try s.run(in, &ip, out, &op) orelse return .{ .in_len = ip, .out_len = op, .status = .need_input };
            switch (status) {
                .output_full => return .{ .in_len = ip, .out_len = op, .status = .output_full },
                .end => {
                    switch (s.format) {
                        .lzma1 => s.go(.lzma, .end),
                        .lzma2 => {
                            if (s.packed_left != 0) return s.fail(s.offset + ip, .chunk_size);
                            s.go(.lzma, .chunk);
                        },
                    }
                },
            }
        },
        .copy => {
            if (op == out.len) return .{ .in_len = ip, .out_len = op, .status = .output_full };
            if (ip == in.len) return .{ .in_len = ip, .out_len = op, .status = .need_input };
            const n = @min(s.chunk_size, in.len - ip, out.len - op);
            s.ring.limit = n;
            for (in[ip..][0..n]) |b| s.ring.put(b);
            @memcpy(out[op..][0..n], in[ip..][0..n]);
            ip += n;
            op += n;
            s.chunk_size -= @intCast(n);
            if (s.chunk_size == 0) s.go(.copy, .chunk);
        },
    };
}

fn startChunk(s: *Stream) void {
    s.coder.left = s.chunk_size;
    s.coder.allow_marker = false;
    s.coder.marker_next = false;
    s.gathered = 0;
}

/// The engine from where it stopped; null where it needs input. The
/// output goes to the ring and on to `out`.
fn run(s: *Stream, in: []const u8, ip: *usize, out: []u8, op: *usize) Error!?engine.Status {
    // The input the coder may still take: an LZMA2 chunk's bytes and one
    // more, which liblzma refuses once read.
    const cap: usize = if (s.format == .lzma2) @as(usize, s.packed_left) + 1 else std.math.maxInt(usize);
    const staged = s.held != 0;
    var d: range.Decoder = .{ .in = &.{}, .pos = 0, .range = s.range_state, .code = s.code };
    var n: usize = 0;
    if (staged) {
        n = @min(in.len - ip.*, stage_len - s.held, cap);
        @memcpy(s.stage[s.held..][0..n], in[ip.*..][0..n]);
        d.in = s.stage[0 .. s.held + n];
    } else d.in = in[ip.*..][0..@min(in.len - ip.*, cap)];
    const base = s.offset + ip.* - s.held;
    s.ring.limit = out.len - op.*;
    const before = s.ring.total;
    const result = engine.run(&s.coder, &d, &s.ring, base);
    const produced: usize = @intCast(s.ring.total - before);
    if (produced != 0) {
        const parts = s.ring.last(produced);
        @memcpy(out[op.*..][0..parts[0].len], parts[0]);
        @memcpy(out[op.* + parts[0].len ..][0..parts[1].len], parts[1]);
        op.* += produced;
    }
    s.range_state = d.range;
    s.code = d.code;
    // What the coder took: past the stage it reads in place again, and
    // the stage's bytes after where it stopped are given back.
    var taken: usize = undefined;
    if (staged) {
        if (d.pos >= s.held) {
            taken = d.pos - s.held;
            s.held = 0;
        } else {
            @memmove(s.stage[0 .. s.held + n - d.pos], s.stage[d.pos .. s.held + n]);
            s.held = s.held + n - d.pos;
            taken = n;
        }
    } else taken = d.pos;
    const short = if (result) |_| false else |err| err == error.NeedInput;
    if (short and !staged) {
        // In place and short: the symbol's bytes (fewer than a symbol
        // reads) to the stage.
        const tail = d.in[d.pos..];
        @memcpy(s.stage[0..tail.len], tail);
        s.held = tail.len;
        taken += tail.len;
    }
    if (s.format == .lzma2) {
        if (taken > s.packed_left) return s.fail(base +| s.packed_left, .chunk_size);
        s.packed_left -= @intCast(taken);
    }
    ip.* += taken;
    const status = result catch |err| switch (err) {
        error.InvalidStream => return s.fail(s.coder.fail_at, s.coder.reason),
        error.NeedInput => return if (ip.* < in.len) s.run(in, ip, out, op) else null,
    };
    return status;
}
