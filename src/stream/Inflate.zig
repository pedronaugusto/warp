//! Streaming decoding of raw DEFLATE, zlib and gzip: input and output in
//! pieces of any size, the stream resumable at any byte of either.
//!
//! An `Inflate` holds the decoding tables (about 11 KiB) and where the
//! stream is; the caller gives the window, 2^`window_bits` bytes, which
//! keeps the last bytes written for the matches that reach back into
//! them. Each call decodes straight into the caller's output, and copies
//! into the window only the last bytes it wrote. Nothing is allocated.
//!
//! `Reader` is a `std.Io.Reader` whose own buffer is the history: it
//! decodes into the buffer in place, and never copies a byte twice.

const Inflate = @This();

const std = @import("std");
const Io = std.Io;
const inflate_ = @import("../inflate.zig");
const unwrap = @import("../unwrap.zig");
const container = @import("../container.zig");
const gzip = @import("../gzip.zig");
const Diagnostic = @import("../Diagnostic.zig");

/// Private: the current block's tables.
tables: inflate_.Tables = .{},
/// Private: where the stream is.
state: unwrap.State = .{},
/// Private: the options given to `init`.
options: Options,
/// Private: bits of a unit begun in an earlier call, and how many.
bitbuf: u64 = 0,
bitsleft: u32 = 0,
/// Private: input bytes taken so far, for the diagnostic's offset.
in_total: u64 = 0,
/// Private: the last bytes written, as a ring of 2^window_bits, its next
/// write position and how much of it holds history.
window: []u8,
head: usize = 0,
filled: usize = 0,
/// Private: the next stream reaches into the last one's window (`reset`).
keep_history: bool = false,
/// Private: the error the stream was refused with; every later call
/// returns it.
failed: ?DecodeError = null,
out_total: u64 = 0,
at_boundary: bool = false,
/// Private: the C stream ABI's block and tree flush boundaries.
stop: enum { none, block, trees } = .none,
/// Private: progress made by a failing decode, for the C stream ABI.
error_in_len: usize = 0,
error_out_len: usize = 0,

pub const Options = struct {
    accept: container.Accept = .zlib,
    /// 8-15: the history kept, 2^window_bits bytes. A distance past it is
    /// refused (`window_exceeded`), as is a zlib header that names a
    /// larger window.
    window_bits: u4 = 15,
    /// Bytes that precede a raw stream's output as history, and what a
    /// zlib stream with FDICT must name; only the last 2^window_bits count.
    dictionary: []const u8 = &.{},
    members: container.Members = .all,
    /// Where the first gzip member's header fields are copied, if wanted.
    gzip_fields: ?*gzip.Fields = null,
    diagnostic: ?*Diagnostic = null,
};

pub const DecodeError = error{
    /// Not a stream of the container accepted, or one that breaks
    /// DEFLATE's rules as zlib 1.3.1 reads them, or that reaches past the
    /// window.
    InvalidStream,
    /// The Adler-32, CRC-32 or length in a trailer, or a gzip header CRC,
    /// is not the data's.
    ChecksumMismatch,
    /// A zlib stream names a dictionary other than the one given.
    DictionaryMismatch,
};

/// `window.len >= 1 << options.window_bits`: the caller's memory for the
/// history.
pub fn init(window: []u8, options: Options) Inflate {
    std.debug.assert(options.window_bits >= 8);
    std.debug.assert(window.len >= @as(usize, 1) << options.window_bits);
    return .{ .options = options, .window = window[0 .. @as(usize, 1) << options.window_bits] };
}

/// Why a call returned.
pub const Status = enum {
    /// Every input byte is taken and the stream goes on: more input.
    need_input,
    /// The output is full and the stream goes on.
    output_full,
    /// A block ended: the output so far is every byte the input so far
    /// encodes (after a flush, for instance).
    block_end,
    /// A gzip member ended and another may follow: the stream is complete
    /// here if the input ends here.
    member_end,
    /// The stream ended; input after it is not taken.
    done,
};

pub const Step = struct { in_len: usize, out_len: usize, status: Status };

/// Decode from `in` into `out`. Call again with the input after
/// `in_len` until `done` (or `member_end` at the end of the input). Bytes
/// of `out` past `out_len` may have been written.
pub fn decode(z: *Inflate, in: []const u8, out: []u8) DecodeError!Step {
    const stepped = try z.step(in, out, 0, 0, z.ringHistory());
    z.out_total += stepped.op;
    z.at_boundary = stepped.status == .block_end and z.state.engine.phase == .header;
    if (stepped.replaced) {
        // A dictionary, or a new member's empty history, replaced the window.
        z.head = 0;
        z.filled = 0;
        z.ringAppend(stepped.history.newer);
        z.ringAppend(out[stepped.start..stepped.op]);
    } else z.ringAppend(out[0..stepped.op]);
    return .{ .in_len = stepped.in_len, .out_len = stepped.op, .status = stepped.status };
}

/// What history the next stream starts with.
pub const Keep = enum {
    /// None, or the dictionary for a raw stream.
    nothing,
    /// The window as the last stream left it: RFC 7692's context takeover.
    history,
};

/// Start a new stream, with the same options.
pub fn reset(z: *Inflate, keep: Keep) void {
    z.state = .{};
    z.bitbuf = 0;
    z.bitsleft = 0;
    z.in_total = 0;
    z.failed = null;
    z.error_in_len = 0;
    z.error_out_len = 0;
    z.out_total = 0;
    z.at_boundary = false;
    z.keep_history = keep == .history;
    if (keep == .nothing) {
        z.head = 0;
        z.filled = 0;
    }
}

/// A restart at a non-final block boundary. The history is owned by this
/// value, so it remains valid after the decoder moves on.
pub const Checkpoint = struct {
    in_offset: u64,
    out_offset: u64,
    window_bits: u4,
    bits: u3,
    pending: u8,
    wrapper: container.Container,
    check: u32,
    size: u32,
    members: u32,
    history_len: u16,
    history: [32768]u8 = undefined,
};

pub const CheckpointError = error{NotAtBoundary};
pub const ResumeError = error{InvalidCheckpoint};

pub fn checkpoint(z: *const Inflate) CheckpointError!Checkpoint {
    if (!z.at_boundary or z.failed != null) return error.NotAtBoundary;
    var point: Checkpoint = .{
        .in_offset = z.in_total,
        .out_offset = z.out_total,
        .window_bits = z.options.window_bits,
        .bits = @intCast(z.bitsleft),
        .pending = @truncate(z.bitbuf),
        .wrapper = z.state.wrapper,
        .check = z.state.check,
        .size = z.state.size,
        .members = z.state.members,
        .history_len = @intCast(z.filled),
    };
    const history = z.ringHistory();
    history.copyOut(z.filled, point.history[0..z.filled]);
    return point;
}

/// The next input starts at `point.in_offset`; use the checkpoint's window
/// size and a compatible container. A resumed wrapped stream
/// continues its original checksum, including the bytes before the point.
pub fn @"resume"(z: *Inflate, point: *const Checkpoint) ResumeError!void {
    try z.restore(point);
    z.head = 0;
    z.filled = 0;
    z.ringAppend(point.history[0..point.history_len]);
}

fn restore(z: *Inflate, point: *const Checkpoint) ResumeError!void {
    const compatible = switch (z.options.accept) {
        .raw => point.wrapper == .raw,
        .zlib => point.wrapper == .zlib,
        .gzip => point.wrapper == .gzip,
        .zlib_or_raw => point.wrapper != .gzip,
        .gzip_or_zlib => point.wrapper != .raw,
    };
    if (!compatible or point.window_bits != z.options.window_bits or
        point.history_len > (@as(usize, 1) << point.window_bits) or
        (@as(u16, point.pending) >> point.bits) != 0) return error.InvalidCheckpoint;
    z.reset(.nothing);
    z.state = .{ .phase = .body, .wrapper = point.wrapper, .check = point.check, .size = point.size, .members = point.members };
    z.bitbuf = point.pending;
    z.bitsleft = point.bits;
    z.in_total = point.in_offset;
    z.out_total = point.out_offset;
    z.at_boundary = true;
}

/// One call's result: where the stream stopped and how.
const Stepped = struct {
    in_len: usize,
    op: usize,
    status: Status,
    /// The history was replaced in this call; `history` is the new one,
    /// and the output from `start` follows it.
    replaced: bool,
    history: inflate_.History,
    start: usize,
};

/// Decode from `in` into `out[op..]`, the output from `start` following
/// `history`. A unit cut short by the end of the input is kept in hand
/// for the next call.
fn step(z: *Inflate, in: []const u8, out: []u8, op: usize, start: usize, history: inflate_.History) DecodeError!Stepped {
    if (z.failed) |err| return err;
    const status: Status = switch (z.state.phase) {
        .done => .done,
        .member_end => if (in.len == 0) .member_end else .need_input,
        else => .need_input,
    };
    if (status != .need_input) return .{ .in_len = 0, .op = op, .status = status, .replaced = false, .history = history, .start = start };

    var diagnostic: Diagnostic = .{};
    var source: Resume = .{};
    var s: inflate_.Stream = .{
        .in = in,
        .ip = 0,
        .bitbuf = z.bitbuf,
        .bitsleft = z.bitsleft,
        .in_base = z.in_total,
        .out = out,
        .op = op,
        .start = start,
        .history = history,
        .window = @as(u32, 1) << z.options.window_bits,
        .partial = true,
        .stop_header = z.stop == .trees,
        .diagnostic = &diagnostic,
    };
    source.commit(&s);
    const machine: unwrap.Options = .{
        .accept = z.options.accept,
        .dictionary = z.options.dictionary,
        .members = z.options.members,
        .window_bits = z.options.window_bits,
        .keep_history = z.keep_history,
        .fields = z.options.gzip_fields,
        .stop_wrapper = z.stop != .none,
    };
    const run = unwrap.run(&z.tables, &z.state, &s, &source, machine) catch |err| switch (err) {
        error.Truncated => {
            source.restore(&s);
            z.state.sum(&s);
            z.absorb(&s);
            z.in_total += in.len;
            return .{ .in_len = in.len, .op = s.op, .status = .need_input, .replaced = z.state.history_replaced, .history = s.history, .start = s.start };
        },
        error.OutputTooSmall => unreachable, // unreachable: a partial decode stops at a full output
        error.InvalidStream, error.ChecksumMismatch, error.DictionaryMismatch => |e| {
            if (z.options.diagnostic) |d| d.* = diagnostic;
            z.state.sum(&s);
            z.error_in_len = @min(in.len, s.ip -| (s.bitsleft / 8));
            z.error_out_len = s.op - op;
            z.failed = e;
            return e;
        },
    };
    // Whole bytes read ahead go back to the caller.
    const in_len = s.ip - s.bitsleft / 8;
    z.bitsleft = s.bitsleft & 7;
    z.bitbuf = s.bitbuf & ((@as(u64, 1) << @intCast(z.bitsleft)) - 1);
    z.in_total += in_len;
    return .{
        .in_len = in_len,
        .op = s.op,
        .status = switch (run) {
            .done => .done,
            .block_end => .block_end,
            .member_end => .member_end,
            .output_full => .output_full,
        },
        .replaced = z.state.history_replaced,
        .history = s.history,
        .start = s.start,
    };
}

/// Keep what the cut-short unit has read, and every input byte after it,
/// in hand: fewer bits than the unit needs, so fewer than 64.
fn absorb(z: *Inflate, s: *inflate_.Stream) void {
    // Zero bytes loaded past the end are not the input's.
    s.bitsleft -= 8 * s.virtual;
    s.ip -= s.virtual;
    var bits = s.bitbuf & ((@as(u64, 1) << @intCast(s.bitsleft)) - 1);
    var n = s.bitsleft;
    for (s.in[s.ip..]) |byte| {
        std.debug.assert(n + 8 <= 64);
        bits |= @as(u64, byte) << @intCast(n);
        n += 8;
    }
    z.bitbuf = bits;
    z.bitsleft = n;
}

/// The ring's bytes in order: the older part after the write position,
/// then the newer part before it.
fn ringHistory(z: *const Inflate) inflate_.History {
    if (z.filled < z.window.len) return .{ .newer = z.window[0..z.filled] };
    return .{ .older = z.window[z.head..], .newer = z.window[0..z.head] };
}

fn ringAppend(z: *Inflate, bytes_in: []const u8) void {
    const size = z.window.len;
    const bytes = bytes_in[bytes_in.len -| size..];
    const first = @min(bytes.len, size - z.head);
    @memcpy(z.window[z.head..][0..first], bytes[0..first]);
    @memcpy(z.window[0 .. bytes.len - first], bytes[first..]);
    z.head = (z.head + bytes.len) & (size - 1);
    z.filled = @min(size, z.filled + bytes.len);
}

/// The engine's source for a streaming call: no more input than given,
/// and the position after the last whole unit, to go back to when the
/// input ends inside one.
const Resume = struct {
    ip: usize = 0,
    bitbuf: u64 = 0,
    bitsleft: u32 = 0,
    virtual: u32 = 0,
    op: usize = 0,

    pub fn more(_: *Resume, _: *inflate_.Stream) bool {
        return false;
    }

    pub fn commit(r: *Resume, s: *inflate_.Stream) void {
        r.* = .{ .ip = s.ip, .bitbuf = s.bitbuf, .bitsleft = s.bitsleft, .virtual = s.virtual, .op = s.op };
    }

    fn restore(r: *const Resume, s: *inflate_.Stream) void {
        s.ip = r.ip;
        s.bitbuf = r.bitbuf;
        s.bitsleft = r.bitsleft;
        s.virtual = r.virtual;
        s.op = r.op;
    }
};

/// A `std.Io.Reader` of the decoded bytes of the stream `input` gives. Its
/// buffer is the history: decoded in place, never copied twice. What
/// follows the stream stays in `input`.
pub const Reader = struct {
    interface: Io.Reader,
    input: *Io.Reader,
    /// Private: the stream's state; its window is the buffer.
    inflate: Inflate,
    /// Private: where the current member's output starts in the buffer,
    /// and the history before the buffer's first byte (a dictionary,
    /// until a rebase moves the buffer past it).
    start: usize = 0,
    history: inflate_.History = .{},
    /// Private: why the last read failed, when it was the stream.
    err_: ?ReadError = null,

    pub const ReadError = DecodeError || error{
        /// The input ended inside the stream.
        Truncated,
    };

    /// `buffer.len >= (1 << options.window_bits) + 4096`.
    pub fn init(input: *Io.Reader, buffer: []u8, options: Options) Reader {
        std.debug.assert(options.window_bits >= 8);
        std.debug.assert(buffer.len >= (@as(usize, 1) << options.window_bits) + 4096);
        return .{
            .interface = .{ .vtable = &vtable, .buffer = buffer, .seek = 0, .end = 0 },
            .input = input,
            .inflate = .{ .options = options, .window = &.{} },
        };
    }

    /// The error behind an `error.ReadFailed`, when it was the stream's
    /// and not the input's.
    pub fn err(r: *const Reader) ?ReadError {
        return r.err_;
    }

    /// Reposition after the caller has positioned `input` at the point's
    /// compressed offset. Previously buffered decoded bytes are discarded.
    pub fn seek(r: *Reader, point: *const Checkpoint) ResumeError!void {
        try r.inflate.restore(point);
        @memcpy(r.interface.buffer[0..point.history_len], point.history[0..point.history_len]);
        r.interface.seek = point.history_len;
        r.interface.end = point.history_len;
        r.start = 0;
        r.history = .{};
        r.err_ = null;
    }

    const vtable: Io.Reader.VTable = .{
        .stream = stream,
        .discard = discard,
        .readVec = readVec,
        .rebase = rebase,
    };

    fn stream(io_r: *Io.Reader, w: *Io.Writer, limit: Io.Limit) Io.Reader.StreamError!usize {
        _ = w;
        _ = limit;
        try fill(@fieldParentPtr("interface", io_r));
        return 0;
    }

    fn readVec(io_r: *Io.Reader, data: [][]u8) Io.Reader.Error!usize {
        _ = data;
        try fill(@fieldParentPtr("interface", io_r));
        return 0;
    }

    fn discard(io_r: *Io.Reader, limit: Io.Limit) Io.Reader.Error!usize {
        try fill(@fieldParentPtr("interface", io_r));
        const n = limit.minInt(io_r.end - io_r.seek);
        io_r.seek += n;
        return n;
    }

    /// Keep the window's bytes before `end` and every unread byte.
    fn rebase(io_r: *Io.Reader, capacity: usize) Io.Reader.RebaseError!void {
        const r: *Reader = @fieldParentPtr("interface", io_r);
        _ = capacity;
        r.slide();
    }

    fn slide(r: *Reader) void {
        const io_r = &r.interface;
        const window = @as(usize, 1) << r.inflate.options.window_bits;
        const drop = @min(io_r.seek, io_r.end -| window);
        if (drop == 0) return;
        @memmove(io_r.buffer[0 .. io_r.end - drop], io_r.buffer[drop..io_r.end]);
        io_r.end -= drop;
        io_r.seek -= drop;
        r.start -|= drop;
        // The buffer now holds a whole window: nothing before it is reached.
        r.history = .{};
    }

    /// Decode until some bytes are in the buffer, or the stream ends.
    fn fill(r: *Reader) Io.Reader.Error!void {
        const io_r = &r.interface;
        if (io_r.buffer.len - io_r.end < 4096) r.slide();
        const before = io_r.end;
        while (io_r.end == before) {
            const in = r.input.buffered();
            const stepped = r.inflate.step(in, io_r.buffer, io_r.end, r.start, r.history) catch |e| {
                r.err_ = e;
                return error.ReadFailed;
            };
            r.input.toss(stepped.in_len);
            io_r.end = stepped.op;
            if (stepped.replaced) {
                r.history = stepped.history;
                r.start = stepped.start;
            }
            switch (stepped.status) {
                .output_full => return,
                .block_end => {},
                .done => if (io_r.end == before) return error.EndOfStream,
                .need_input, .member_end => {
                    if (r.input.bufferedLen() != 0) continue;
                    r.input.fillMore() catch |e| switch (e) {
                        error.ReadFailed => return error.ReadFailed,
                        error.EndOfStream => {
                            if (stepped.status == .member_end) {
                                if (io_r.end == before) return error.EndOfStream;
                                return;
                            }
                            r.err_ = error.Truncated;
                            if (r.inflate.options.diagnostic) |d| d.* = .{ .bit_offset = r.inflate.in_total * 8, .reason = .truncated };
                            return error.ReadFailed;
                        },
                    };
                },
            }
        }
    }
};
