//! Resumable Brotli decoding: input and output in pieces of any size, the
//! stream resumable at any byte of either.
//!
//! A `Decompress` holds the tables (as a `Decompressor` does) and where the
//! stream is; the caller gives the window, 2^WBITS bytes for the largest
//! window it accepts (`windowLength`: 16 MiB takes any RFC 7932 stream).
//! Output is decoded into the window and copied out. A unit the input ends
//! inside is kept, at most a few bytes of it, and read again with the next
//! input. Nothing is allocated.

const Decompress = @This();

const std = @import("std");
const aegis = @import("aegis");
const Io = std.Io;
const engine = @import("decode.zig");
const bits = @import("bits.zig");
const Decompressor = @import("Decompressor.zig");
const Diagnostic = @import("Diagnostic.zig");

/// Private: the tables of the meta-block being decoded.
tables: engine.Tables,
/// Private: where the stream is.
state: engine.State,
/// Private: the window and what of it is handed out.
ring: engine.Ring,
options: Options,
/// Private: bytes of a unit the input ended inside, and the bits loaded
/// from before them.
carry: [64]u8 = undefined,
carry_len: usize = 0,
bit_buf: u64 = 0,
bit_count: u6 = 0,
/// Private: input bytes taken since the stream started (carried ones
/// included).
taken: u64 = 0,
streams: u64 = 0,
failure: ?Error = null,

pub const Options = struct {
    /// As `Decompressor.Options.dictionary`.
    dictionary: []const u8 = &.{},
    /// As `Decompressor.Options.large_window`.
    large_window: bool = false,
    streams: Decompressor.Streams = .all,
    diagnostic: ?*Diagnostic = null,
};

/// Why a call returned.
pub const Status = enum {
    /// Every input byte is taken and the stream goes on: more input.
    need_input,
    /// The output is full and more is decoded: more room.
    output_full,
    /// A stream ended and another may follow (`streams = .all`): the input
    /// is complete here if it ends here.
    stream_end,
    /// The stream ended (`streams = .one`); input after it is not taken.
    done,
};

pub const Step = struct { in_len: usize, out_len: usize, status: Status };

pub const Error = error{
    /// As `Decompressor.Error.InvalidStream`.
    InvalidStream,
    /// `finish` was called inside a stream.
    Truncated,
    /// The stream's window is larger than the window given.
    WindowTooLarge,
};

/// The window that holds a stream of `window_bits` (10-24, to 30 with
/// `large_window`), and every smaller one.
pub fn windowLength(window_bits: u5) usize {
    return @as(usize, 1) << window_bits;
}

/// `window` holds `windowLength` of the largest window to accept. The
/// value is large (the tables): place it where it will live.
pub fn init(window: []u8, options: Options) Decompress {
    return .{
        .tables = undefined,
        .state = .{ .large_window = options.large_window },
        .ring = .{ .buf = window, .limit = 0, .dict = options.dictionary },
        .options = options,
    };
}

/// Start again at a new stream, with the same window and options.
pub fn reset(z: *Decompress) void {
    z.state = .{ .large_window = z.options.large_window };
    z.ring = .{ .buf = z.ring.buf, .limit = 0, .dict = z.options.dictionary };
    z.carry_len = 0;
    z.bit_buf = 0;
    z.bit_count = 0;
    z.taken = 0;
    z.streams = 0;
    z.failure = null;
}

/// Consume and produce as much as possible. Call again with the input
/// after `in_len`; an empty input drains pending output.
pub fn decode(z: *Decompress, in: []const u8, out: []u8) Error!Step {
    if (z.failure) |err| return err;
    var ip: usize = 0;
    var op: usize = 0;
    while (true) {
        op += z.drain(out[op..]);
        if (z.ring.pending().len != 0) return .{ .in_len = ip, .out_len = op, .status = .output_full };
        z.ring.wrap();
        if (z.state.phase == .done) {
            if (z.options.streams == .one) return .{ .in_len = ip, .out_len = op, .status = .done };
            z.streams += 1;
            z.state = .{ .large_window = z.options.large_window };
            z.ring = .{ .buf = z.ring.buf, .limit = 0, .dict = z.options.dictionary };
            return .{ .in_len = ip, .out_len = op, .status = .stream_end };
        }
        const status = try z.feed(in, &ip);
        if (status == .need_input) {
            op += z.drain(out[op..]);
            const full = z.ring.pending().len != 0;
            return .{ .in_len = ip, .out_len = op, .status = if (full) .output_full else .need_input };
        }
    }
}

/// Declare the end of input, after draining the output: refused inside a
/// stream.
pub fn finish(z: *Decompress) Error!void {
    if (z.failure) |err| return err;
    if (z.state.phase == .done) return;
    const between = z.state.phase == .stream_header and z.carry_len == 0 and z.bit_count == 0;
    if (between and z.streams != 0) return;
    if (z.options.diagnostic) |d| d.* = .{ .bit_offset = .fromRaw(z.taken *| 8), .reason = .truncated };
    z.failure = error.Truncated;
    return error.Truncated;
}

fn drain(z: *Decompress, out: []u8) usize {
    const pending = z.ring.pending();
    const n = @min(out.len, pending.len);
    @memcpy(out[0..n], pending[0..n]);
    z.ring.drained += n;
    return n;
}

/// Run the engine over the carried bytes (topped up from `in`), then over
/// `in` from `ip`, until it stops.
fn feed(z: *Decompress, in: []const u8, ip: *usize) Error!engine.Status {
    // The input after `ip`, cut as it is taken; `ip` follows it.
    var rest = in[ip.*..];
    if (z.carry_len != 0) {
        const old = z.carry_len;
        const fresh = rest[0..@min(z.carry.len - old, rest.len)];
        @memcpy(z.carry[old..][0..fresh.len], fresh);
        rest = rest[fresh.len..];
        ip.* = in.len - rest.len;
        z.carry_len += fresh.len;
        z.taken +|= fresh.len;
        const start = z.taken -| z.carry_len;
        var r: bits.Reader = .{ .in = z.carry[0..z.carry_len], .base = start *| 8, .buf = z.bit_buf, .count = z.bit_count };
        const status = try z.run(&r);
        z.bit_buf = r.buf;
        z.bit_count = r.count;
        aegis.assert.invariant(r.pos <= r.in.len, "r.pos <= r.in.len");
        const unread = r.in[r.pos..];
        // The next bit is past the old bytes where no more bits are left
        // than the fresh bytes hold.
        // (`count` is under 64: eight fresh bytes hold more than it.)
        if (unread.len <= fresh.len and r.count <= @as(usize, @min(fresh.len - unread.len, 8)) * 8) {
            // The next bit is in bytes taken from `in`: read them there.
            rest = in[in.len - rest.len - unread.len ..];
            ip.* = in.len - rest.len;
            z.taken -|= unread.len;
            z.carry_len = 0;
            if (status != .need_input or rest.len == 0) return status;
        } else {
            @memmove(z.carry[0..unread.len], unread);
            z.carry_len = unread.len;
            return status;
        }
    }
    var r: bits.Reader = .{ .in = rest, .base = z.taken *| 8, .buf = z.bit_buf, .count = z.bit_count };
    const status = try z.run(&r);
    aegis.assert.invariant(r.pos <= rest.len, "r.pos <= rest.len");
    rest = rest[r.pos..];
    ip.* = in.len - rest.len;
    z.taken +|= r.pos;
    z.bit_buf = r.buf;
    z.bit_count = r.count;
    if (status == .need_input) {
        std.debug.assert(rest.len <= z.carry.len);
        @memcpy(z.carry[0..rest.len], rest);
        z.carry_len = rest.len;
        ip.* = in.len;
        z.taken +|= rest.len;
    }
    return status;
}

fn run(z: *Decompress, r: *bits.Reader) Error!engine.Status {
    return engine.run(&z.state, &z.tables, r, &z.ring) catch |err| {
        const e: Error = switch (err) {
            error.InvalidStream => error.InvalidStream,
            error.WindowTooLarge => error.WindowTooLarge,
            error.OutputTooSmall => unreachable,
        };
        if (z.options.diagnostic) |d| d.* = .{ .bit_offset = .fromRaw(if (e == error.InvalidStream) z.state.fail_bit else r.bitOffset()), .reason = if (e == error.InvalidStream) z.state.reason else .window_bits };
        z.failure = e;
        return e;
    };
}

/// A reader over the same resumable decoder. `buffer` reserves 4 KiB for
/// reader buffering, then the window.
pub const Reader = struct {
    interface: Io.Reader,
    input: *Io.Reader,
    state: Decompress,
    failure: ?Error = null,

    pub fn init(input: *Io.Reader, buffer: []u8, options: Options) Reader {
        const n = @min(buffer.len, 4096);
        return .{ .interface = .{ .vtable = &.{ .stream = stream, .readVec = readVec }, .buffer = buffer[0..n], .seek = 0, .end = 0 }, .input = input, .state = Decompress.init(buffer[n..], options) };
    }

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
            if (step.status == .done) return error.EndOfStream;
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
