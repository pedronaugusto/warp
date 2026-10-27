//! Resumable stream decoding: input and output in pieces of any size. A
//! chunk is read once its bytes are all in hand, straight from the input
//! when one call holds them, and its block lands in the caller's window
//! before it is handed out; skippable chunks are read past as they come.
//! Acceptance is the whole-buffer decoder's, S2's reader's, at any cut.
const Decompress = @This();

const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;
const frame = @import("frame.zig");
const streams = @import("streams.zig");

pub const Options = streams.Options;
pub const Error = streams.Error;

pub const Status = enum {
    /// Every input byte is taken: more input, or `finish` if the stream
    /// ends here.
    need_input,
    /// The output is full and output is pending.
    output_full,
};

pub const Step = struct { in_len: usize, out_len: usize, status: Status };

/// The bytes of window `init` needs for blocks of at most
/// `max_block_size`: one decoded block, and one chunk staged.
pub fn memory(max_block_size: aegis.units.Bytes(usize)) usize {
    const b = max_block_size.raw();
    return b + @as(usize, @intCast(frame.maxChunk(b)));
}

const Phase = enum { header, body, skip, drain };

/// What a unit read says comes next: a chunk read whole, one to read past,
/// or a block handed out.
const Event = enum { chunk, skippable, read, drained };

const Machine = aegis.state.Machine(Phase, Event, .{ .initial = .header, .terminal = &.{}, .edges = &.{
    .{ .from = .header, .on = .chunk, .to = .body },
    .{ .from = .header, .on = .skippable, .to = .skip },
    .{ .from = .body, .on = .read, .to = .header },
    .{ .from = .body, .on = .chunk, .to = .drain },
    .{ .from = .skip, .on = .read, .to = .header },
    .{ .from = .drain, .on = .drained, .to = .header },
} });

options: Options,
/// Private: the decoded block, then the chunk's staging.
window: []u8,
stage: []u8,
phase: Phase = .header,
/// Private: bytes gathered for the current unit, and how many it needs.
have: usize = 0,
wanted: usize = frame.header_len,
header: frame.Header = .{ .type = 0, .len = 0 },
/// Private: the input taken so far, and where the chunk started.
offset: u64 = 0,
chunk_at: u64 = 0,
/// Private: the chunk read past, still to go.
skipping: u64 = 0,
/// Private: output to drop (`skip`).
dropping: u64 = 0,
first: bool,
snappy: bool = false,
/// Private: the decoded bytes still to hand out.
pending: usize = 0,
pending_end: usize = 0,
failure: ?Error = null,

/// `buffer.len >= memory(options.max_block_size)`.
pub fn init(buffer: []u8, options: Options) Decompress {
    const b = options.max_block_size.raw();
    std.debug.assert(b <= frame.max_block_size);
    std.debug.assert(buffer.len >= memory(options.max_block_size));
    return .{ .options = options, .window = buffer[0..b], .stage = buffer[b..memory(options.max_block_size)], .first = !options.from_chunk };
}

pub fn reset(s: *Decompress) void {
    s.* = init(s.window.ptr[0 .. s.window.len + s.stage.len], s.options);
}

/// Drop the next `n` bytes of output: blocks wholly inside are read past
/// without decoding or checking their checksums, as S2's `Skip` does.
/// With an index, a reader starts at `Index.find`'s entry (`from_chunk`)
/// and skips the rest of the way.
pub fn skip(s: *Decompress, n: u64) void {
    const held: u64 = s.pending_end - s.pending;
    const now = @min(held, n);
    s.pending += @intCast(now);
    s.dropping += n - now;
}

/// Take input and give output as far as each allows.
pub fn decode(s: *Decompress, in: []const u8, out: []u8) Error!Step {
    if (s.failure) |err| return err;
    var ip: usize = 0;
    var op: usize = 0;
    while (true) switch (s.phase) {
        .drain => {
            const n = @min(out.len - op, s.pending_end - s.pending);
            @memcpy(out[op..][0..n], s.window[s.pending..][0..n]);
            s.pending += n;
            op += n;
            if (s.pending != s.pending_end) return .{ .in_len = ip, .out_len = op, .status = .output_full };
            s.next(.drain, .drained, frame.header_len);
        },
        .skip => {
            const n: usize = @intCast(@min(in.len - ip, s.skipping));
            ip += n;
            s.offset += n;
            s.skipping -= n;
            if (s.skipping != 0) return .{ .in_len = ip, .out_len = op, .status = .need_input };
            s.next(.skip, .read, frame.header_len);
        },
        .header => {
            const n = @min(in.len - ip, s.wanted - s.have);
            @memcpy(s.stage[s.have..][0..n], in[ip..][0..n]);
            s.have += n;
            ip += n;
            s.offset += n;
            if (s.have != s.wanted) return .{ .in_len = ip, .out_len = op, .status = .need_input };
            try s.readHeader();
        },
        .body => {
            // The whole chunk in this call's input: read from it.
            if (s.have == 0 and in.len - ip >= s.wanted) {
                const body = in[ip..][0..s.wanted];
                ip += s.wanted;
                s.offset += s.wanted;
                try s.readBody(body);
                continue;
            }
            const n = @min(in.len - ip, s.wanted - s.have);
            @memcpy(s.stage[s.have..][0..n], in[ip..][0..n]);
            s.have += n;
            ip += n;
            s.offset += n;
            if (s.have != s.wanted) return .{ .in_len = ip, .out_len = op, .status = .need_input };
            try s.readBody(s.stage[0..s.have]);
        },
    };
}

/// Declare the end of input after the output is drained: refuses a chunk
/// cut short. A stream ends at any chunk's end.
pub fn finish(s: *Decompress) Error!void {
    if (s.failure) |err| return err;
    if (s.phase == .header and s.have == 0) return;
    if (s.phase == .drain) return;
    return s.fail(error.Truncated, s.chunk_at, .truncated);
}

/// The one place the phase changes: along a declared edge.
fn go(s: *Decompress, comptime from: Phase, comptime on: Event) void {
    s.phase = comptime Machine.after(from, on);
}

/// Take the edge, and start a unit of `wanted` bytes.
fn next(s: *Decompress, comptime from: Phase, comptime on: Event, wanted: usize) void {
    s.go(from, on);
    s.have = 0;
    s.wanted = wanted;
}

/// Refuse the stream: every later call returns `err`.
fn fail(s: *Decompress, err: Error, at: u64, reason: @import("Diagnostic.zig").Reason) Error {
    s.failure = err;
    return streams.fail(s.options, at, reason, err);
}

fn failed(s: *Decompress, err: Error) Error {
    s.failure = err;
    return err;
}

fn readHeader(s: *Decompress) Error!void {
    s.chunk_at = s.offset - frame.header_len;
    s.header = frame.readHeader(s.stage[0..frame.header_len]);
    streams.checkHeader(s.header, s.chunk_at, s.first, s.options) catch |err| return s.failed(err);
    s.first = false;
    if (frame.Type.skippable(s.header.type) and s.header.type != frame.Type.identifier) {
        s.skipping = s.header.len;
        s.go(.header, .skippable);
        return;
    }
    s.next(.header, .chunk, s.header.len);
}

fn readBody(s: *Decompress, body: []const u8) Error!void {
    const body_at = s.chunk_at + frame.header_len;
    const chunk = streams.readBody(s.header, body, body_at, s.snappy, s.options) catch |err| return s.failed(err);
    switch (chunk) {
        .identifier => |format| {
            s.snappy = format == .snappy;
            s.next(.body, .read, frame.header_len);
        },
        .skipped => unreachable,
        .data => |data| {
            // A block wholly inside the output dropped is read past.
            if (s.dropping > 0 and s.dropping >= data.len) {
                s.dropping -= data.len;
                s.next(.body, .read, frame.header_len);
                return;
            }
            streams.readData(data, body_at, s.window, s.options) catch |err| return s.failed(err);
            s.pending = @intCast(s.dropping);
            s.dropping = 0;
            s.pending_end = data.len;
            s.go(.body, .chunk);
        },
    }
}

/// A `std.Io.Reader` of a stream's output from `input`; the end of
/// `input` ends the stream (a chunk cut short is refused). Up to 4 KiB of
/// `buffer` serve the reader, the rest is the window
/// (`memory(options.max_block_size)` bytes).
pub const Reader = struct {
    interface: Io.Reader,
    input: *Io.Reader,
    state: Decompress,
    failure: ?Error = null,

    pub fn init(input: *Io.Reader, buffer: []u8, options: Options) Reader {
        const n = @min(buffer.len, 4096);
        return .{ .interface = .{ .vtable = &.{ .stream = stream, .readVec = readVec }, .buffer = buffer[0..n], .seek = 0, .end = 0 }, .input = input, .state = Decompress.init(buffer[n..], options) };
    }

    /// The error behind an `error.ReadFailed`, when it was the stream's.
    pub fn err(r: *const Reader) ?Error {
        return r.failure;
    }

    fn readInto(r: *Reader, out: []u8) Io.Reader.Error!usize {
        var input: []const u8 = &.{};
        while (true) {
            const step = r.state.decode(input, out) catch |failure| {
                r.failure = failure;
                return error.ReadFailed;
            };
            r.input.toss(step.in_len);
            if (step.out_len != 0) return step.out_len;
            input = r.input.peekGreedy(1) catch |failure| {
                if (failure == error.ReadFailed) return failure;
                r.state.finish() catch |codec_error| {
                    r.failure = codec_error;
                    return error.ReadFailed;
                };
                return error.EndOfStream;
            };
        }
    }

    fn stream(interface: *Io.Reader, writer: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        const r: *Reader = @alignCast(@fieldParentPtr("interface", interface));
        _ = writer;
        if (limit == .nothing) return 0;
        const n = try r.readInto(limit.slice(interface.buffer));
        interface.seek = 0;
        interface.end = n;
        return 0;
    }

    fn readVec(interface: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        const r: *Reader = @alignCast(@fieldParentPtr("interface", interface));
        if (data[0].len != 0) return r.readInto(data[0]);
        const n = try r.readInto(interface.buffer[interface.end..]);
        interface.end += n;
        return 0;
    }
};
