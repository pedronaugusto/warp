//! Resumable `.xz` decoding: input and output in pieces of any size, the
//! window the caller's, the parts the whole-buffer decoder's (`format.zig`,
//! `filter.zig`, LZMA2's engine), so a stream is decoded or refused the
//! same however it arrives.
//!
//! A window is sized from the block header that names its dictionary, not
//! before: a block whose dictionary does not fit the window stops the
//! decoder at its header (`need_window`), and the caller gives one large
//! enough (`setWindow`) or refuses it (`refuseWindow`). Each block starts
//! its dictionary afresh, so nothing carries from one window to the next.
//! `Reader` allocates its window so, up to a limit.
//!
//! Headers, checks and the footer are gathered; the index is read a field
//! at a time and its records hashed as the blocks' are. A block's LZMA2
//! runs through `lzma/Stream.zig`, straight into the caller's output when
//! the block has no filters; with filters, through a pipe where each
//! converter holds back the tail it cannot convert yet, as liblzma's do.

const Decompress = @This();

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const aegis = @import("aegis");
const format = @import("format.zig");
const filter_ = @import("filter.zig");
const Stream = @import("../lzma/Stream.zig");
const engine = @import("../lzma/decode.zig");
const Diagnostic = @import("../lzma/Diagnostic.zig");
const Decompressor = @import("Decompressor.zig");
const Crc32 = @import("../checksum/crc32.zig").Crc32;

pub const Options = struct {
    streams: Decompressor.Streams = .all,
    diagnostic: ?*Diagnostic = null,
};

pub const Status = enum {
    /// Every input byte given is taken; more is needed (or `finish`).
    need_input,
    /// `out` is full.
    output_full,
    /// A block's header names a dictionary larger than the window: give a
    /// window of `windowNeeded()` bytes or more with `setWindow`, or refuse
    /// it with `refuseWindow`, before decoding on.
    need_window,
    /// The stream ended (`streams = .one`); input after it is not taken.
    done,
};

pub const Step = struct { in_len: usize, out_len: usize, status: Status };

pub const Error = error{
    /// Not an .xz stream, or one that breaks the format as liblzma reads it.
    InvalidStream,
    /// A block's check does not match its output.
    ChecksumMismatch,
    /// The input ends inside a stream (`finish`).
    Truncated,
    /// A block's dictionary is larger than the caller allows
    /// (`refuseWindow`).
    WindowTooLarge,
};

/// The window a stream whose blocks' dictionaries are at most `dictionary`
/// bytes needs.
pub fn windowLength(dictionary: u64) usize {
    return @intCast(engine.dictionary(dictionary));
}

const Phase = enum { stream_header, block_start, block_header, block_data, block_padding, check, index_field, index_padding, index_crc, footer, stream_padding, done };

/// `read`: a part is read and the next follows. `index`: the index
/// indicator where a block would start. `more`: another index field.
/// `next`: another stream. `last`: the stream ended (`.one`).
const Event = enum { read, index, more, next, last };

const Machine = aegis.state.Machine(Phase, Event, .{ .initial = .stream_header, .terminal = &.{.done}, .edges = &.{
    .{ .from = .stream_header, .on = .read, .to = .block_start },
    .{ .from = .block_start, .on = .read, .to = .block_header },
    .{ .from = .block_start, .on = .index, .to = .index_field },
    .{ .from = .block_header, .on = .read, .to = .block_data },
    .{ .from = .block_data, .on = .read, .to = .block_padding },
    .{ .from = .block_padding, .on = .read, .to = .check },
    .{ .from = .check, .on = .read, .to = .block_start },
    .{ .from = .index_field, .on = .more, .to = .index_field },
    .{ .from = .index_field, .on = .read, .to = .index_padding },
    .{ .from = .index_padding, .on = .read, .to = .index_crc },
    .{ .from = .index_crc, .on = .read, .to = .footer },
    .{ .from = .footer, .on = .read, .to = .stream_padding },
    .{ .from = .footer, .on = .last, .to = .done },
    .{ .from = .stream_padding, .on = .next, .to = .stream_header },
} });

/// A running check over a block's output.
const Hasher = format.Hasher;

options: Options,
window: []u8,
phase: Phase = .stream_header,
/// The stream's check, and the input taken so far.
check: format.Check = .none,
offset: u64 = 0,
/// A part being gathered.
gather: [1024]u8 = undefined,
gathered: usize = 0,
/// The current block, and where its header starts.
header: format.BlockHeader = undefined,
block_at: u64 = 0,
/// The window the current block's header asks for and the window does not
/// give; zero when none is asked.
window_needed: usize = 0,
lzma2: Stream = undefined,
hasher: Hasher = .none,
block_in: u64 = 0,
block_out: u64 = 0,
pad: u64 = 0,
/// The pipe of a block with filters: bytes from LZMA2 not yet given out,
/// and the converters over them.
pipe: filter_.Pipe = .{},
/// The blocks' records and the index's, hashed; the index's fields.
blocks: Decompressor.Records = .{},
records: Decompressor.Records = .{},
index_at: u64 = 0,
index_len: u64 = 0,
index_crc: Crc32 = .init,
fields_left: u64 = 0,
/// Nine bytes of seven bits at most.
field: u63 = 0,
field_bytes: u6 = 0,
unpadded: u64 = 0,
count_read: bool = false,
padding: u64 = 0,
failure: ?Error = null,

/// A decoder over `window`, which may be empty: a block whose dictionary
/// does not fit it asks for another (`need_window`).
pub fn init(window: []u8, options: Options) Decompress {
    return .{ .options = options, .window = window };
}

/// The window the block whose header stopped the decoder needs
/// (`need_window`): `windowLength` of the history it keeps (`held`).
pub fn windowNeeded(z: *const Decompress) usize {
    return z.window_needed;
}

/// Gives the decoder `window` in place of its own, after `need_window`. The
/// window it had is the caller's again: the block asking starts its
/// dictionary afresh in the new one.
pub fn setWindow(z: *Decompress, window: []u8) void {
    aegis.assert.invariant(z.phase == .block_header, "z.phase == .block_header");
    aegis.assert.invariant(z.window_needed != 0, "z.window_needed != 0");
    z.window = window;
}

/// Refuses the window the block whose header stopped the decoder asks for
/// (`need_window`): `error.WindowTooLarge`, at its header, from now on.
pub fn refuseWindow(z: *Decompress) Error {
    aegis.assert.invariant(z.phase == .block_header, "z.phase == .block_header");
    aegis.assert.invariant(z.window_needed != 0, "z.window_needed != 0");
    return z.fail(error.WindowTooLarge, z.block_at, .memory_limit);
}

fn go(z: *Decompress, comptime from: Phase, comptime on: Event) void {
    z.phase = comptime Machine.after(from, on);
}

fn fail(z: *Decompress, err: Error, at: u64, reason: Diagnostic.Reason) Error {
    z.failure = err;
    if (z.options.diagnostic) |d| d.* = .{ .offset = .fromRaw(at), .reason = reason };
    return err;
}

/// Gather `want` bytes of a part into `gather`; false where the input ends
/// first.
fn take(z: *Decompress, in: []const u8, ip: *usize, want: usize) bool {
    const n = @min(want - z.gathered, in.len - ip.*);
    @memcpy(z.gather[z.gathered..][0..n], in[ip.*..][0..n]);
    z.gathered += n;
    ip.* += n;
    return z.gathered == want;
}

/// Take input and give output as far as each allows.
pub fn decode(z: *Decompress, in: []const u8, out: []u8) Error!Step {
    if (z.failure) |err| return err;
    var ip: usize = 0;
    var op: usize = 0;
    defer z.offset += ip;
    while (true) {
        const at = z.offset + ip;
        switch (z.phase) {
            .done => return .{ .in_len = ip, .out_len = op, .status = .done },
            .stream_header => {
                if (!z.take(in, &ip, format.header_len)) return .{ .in_len = ip, .out_len = op, .status = .need_input };
                z.check = switch (format.streamHeader(z.gather[0..format.header_len])) {
                    .check => |c| c,
                    .fault => |reason| return z.fail(error.InvalidStream, at + ip - format.header_len, reason),
                };
                z.blocks = .{};
                z.gathered = 0;
                z.go(.stream_header, .read);
            },
            .block_start => {
                if (ip == in.len) return .{ .in_len = ip, .out_len = op, .status = .need_input };
                if (in[ip] == 0) {
                    z.index_at = at;
                    z.index_crc = .init;
                    z.index_crc.update(in[ip..][0..1]);
                    ip += 1;
                    z.records = .{};
                    z.count_read = false;
                    z.field = 0;
                    z.field_bytes = 0;
                    z.go(.block_start, .index);
                    continue;
                }
                z.go(.block_start, .read);
            },
            .block_header => {
                if (z.window_needed == 0 and !try z.blockHeader(in, &ip)) return .{ .in_len = ip, .out_len = op, .status = .need_input };
                const needed = windowLength(held(z.header));
                if (needed > z.window.len) {
                    z.window_needed = needed;
                    return .{ .in_len = ip, .out_len = op, .status = .need_window };
                }
                z.window_needed = 0;
                z.beginBlock(z.offset + ip);
                z.go(.block_header, .read);
            },
            .block_data => {
                const status = try z.blockData(in, &ip, out, &op);
                switch (status) {
                    .need_input, .output_full => return .{ .in_len = ip, .out_len = op, .status = status },
                    .done => z.go(.block_data, .read),
                    .need_window => unreachable, // unreachable: a block's data asks for no window; its header did
                }
            },
            .block_padding => {
                while ((z.block_in + z.pad) % 4 != 0) {
                    if (ip == in.len) return .{ .in_len = ip, .out_len = op, .status = .need_input };
                    if (in[ip] != 0) return z.fail(error.InvalidStream, at, .block_padding);
                    ip += 1;
                    z.pad += 1;
                }
                z.go(.block_padding, .read);
            },
            .check => {
                const n = z.check.size();
                if (!z.take(in, &ip, n)) return .{ .in_len = ip, .out_len = op, .status = .need_input };
                if (!z.hasher.matches(z.gather[0..n])) return z.fail(error.ChecksumMismatch, z.offset + ip - n, .check);
                z.blocks.add(z.header.len + z.block_in + n, z.block_out);
                z.gathered = 0;
                z.go(.check, .read);
            },
            .index_field => {
                if (!try z.indexField(in, &ip)) return .{ .in_len = ip, .out_len = op, .status = .need_input };
                if (z.fields_left != 0) {
                    z.go(.index_field, .more);
                    continue;
                }
                if (!std.meta.eql(z.records, z.blocks)) return z.fail(error.InvalidStream, z.index_at, .index);
                z.go(.index_field, .read);
            },
            .index_padding => {
                while ((z.offset + ip - z.index_at) % 4 != 0) {
                    if (ip == in.len) return .{ .in_len = ip, .out_len = op, .status = .need_input };
                    if (in[ip] != 0) return z.fail(error.InvalidStream, z.offset + ip, .index);
                    z.index_crc.update(in[ip..][0..1]);
                    ip += 1;
                }
                z.gathered = 0;
                z.go(.index_padding, .read);
            },
            .index_crc => {
                if (!z.take(in, &ip, 4)) return .{ .in_len = ip, .out_len = op, .status = .need_input };
                if (z.index_crc.final() != std.mem.readInt(u32, z.gather[0..4], .little)) return z.fail(error.InvalidStream, z.offset + ip - 4, .index_crc);
                z.index_len = z.offset + ip - z.index_at;
                z.gathered = 0;
                z.go(.index_crc, .read);
            },
            .footer => {
                if (!try z.footer(in, &ip)) return .{ .in_len = ip, .out_len = op, .status = .need_input };
                if (z.options.streams == .one) {
                    z.go(.footer, .last);
                    continue;
                }
                z.go(.footer, .read);
            },
            .stream_padding => {
                while (ip < in.len and in[ip] == 0) {
                    ip += 1;
                    z.padding += 1;
                }
                if (ip == in.len) return .{ .in_len = ip, .out_len = op, .status = .need_input };
                if (z.padding % 4 != 0) return z.fail(error.InvalidStream, at, .stream_padding);
                z.go(.stream_padding, .next);
            },
        }
    }
}

/// A block's header, gathered and read; false where the input ends first.
fn blockHeader(z: *Decompress, in: []const u8, ip: *usize) Error!bool {
    const len = (@as(usize, if (z.gathered == 0) in[ip.*] else z.gather[0]) + 1) * 4;
    if (!z.take(in, ip, len)) return false;
    // Where the header starts, for the diagnostic.
    z.block_at = z.offset +| ip.* -| len;
    var fault: format.Fault = undefined;
    z.header = aegis.input.Untrusted([]const u8).init(z.gather[0..len]).parse(format.HeaderContext{ .check = z.check, .fault = &fault }, format.blockHeader) catch
        return z.fail(error.InvalidStream, z.block_at + fault.at, fault.reason);
    z.gathered = 0;
    return true;
}

/// The block whose header was read begun, its data from input offset `at`,
/// its dictionary in the window.
/// The history a block keeps: its dictionary, or the uncompressed size its
/// header declares where that is less. Each block starts its dictionary
/// afresh and ends at its declared size, so no distance reaches further.
fn held(h: format.BlockHeader) u64 {
    return @min(h.dictionary, h.uncompressed orelse h.dictionary);
}

fn beginBlock(z: *Decompress, at: u64) void {
    z.lzma2 = Stream.init(z.window, held(z.header), .lzma2);
    z.lzma2.offset = at;
    z.hasher = .init(z.check);
    z.block_in = 0;
    z.block_out = 0;
    z.pad = 0;
    if (z.header.filter_count != 0) z.pipe.reset(z.header.filters[0..z.header.filter_count]);
}

/// One field of the index, the count or a record's half; false where the
/// input ends first.
fn indexField(z: *Decompress, in: []const u8, ip: *usize) Error!bool {
    while (true) {
        if (ip.* == in.len) return false;
        const b = in[ip.*];
        z.index_crc.update(in[ip.*..][0..1]);
        ip.* += 1;
        z.field |= @as(u63, b & 0x7f) << (z.field_bytes * 7);
        z.field_bytes += 1;
        if (b & 0x80 == 0) {
            if (b == 0 and z.field_bytes > 1) return z.fail(error.InvalidStream, z.index_at, .index);
            break;
        }
        if (z.field_bytes == 9) return z.fail(error.InvalidStream, z.index_at, .index);
    }
    const v = z.field;
    z.field = 0;
    z.field_bytes = 0;
    if (!z.count_read) {
        z.count_read = true;
        if (v != z.blocks.count) return z.fail(error.InvalidStream, z.index_at, .index);
        z.fields_left = 2 * @as(u64, v);
        return true;
    }
    // A record's field is read only while one is left.
    if (z.fields_left == 0) return z.fail(error.InvalidStream, z.index_at, .index);
    if (z.fields_left % 2 == 0) {
        if (v < 5 or v > format.vli_max & ~@as(u64, 3)) return z.fail(error.InvalidStream, z.index_at, .index);
        z.unpadded = v;
    } else {
        z.records.add(z.unpadded, v);
    }
    z.fields_left -= 1;
    return true;
}

/// The stream footer against the header and the index; false where the
/// input ends first.
fn footer(z: *Decompress, in: []const u8, ip: *usize) Error!bool {
    if (!z.take(in, ip, format.footer_len)) return false;
    const start = z.offset + ip.* - format.footer_len;
    const f = switch (format.streamFooter(z.gather[0..format.footer_len])) {
        .footer => |f| f,
        .fault => |reason| return z.fail(error.InvalidStream, start, reason),
    };
    if (f.check != z.check) return z.fail(error.InvalidStream, start, .footer_flags);
    if (f.backward_size != z.index_len) return z.fail(error.InvalidStream, start, .backward_size);
    z.gathered = 0;
    z.padding = 0;
    return true;
}

/// A block's data: LZMA2 to its end, through the filters, into `out`.
fn blockData(z: *Decompress, in: []const u8, ip: *usize, out: []u8, op: *usize) Error!Status {
    const h = &z.header;
    while (true) {
        // The input the block may still take, and the output it may make.
        // The block takes no more than its sizes, so neither count passes them.
        const in_cap: usize = if (h.compressed) |c| cap: {
            if (z.block_in > c) return z.fail(error.InvalidStream, z.offset +| ip.*, .block_size);
            break :cap @intCast(@min(in.len - ip.*, c - z.block_in));
        } else in.len - ip.*;
        const filtered = h.filter_count != 0;
        const dest = if (filtered) z.pipe.room() else out[op.*..];
        const out_cap: usize = if (h.uncompressed) |u| cap: {
            if (z.block_out > u) return z.fail(error.InvalidStream, z.offset +| ip.*, .block_size);
            break :cap @intCast(@min(dest.len, u - z.block_out));
        } else dest.len;
        const ended = z.lzma2.done();
        var produced: usize = 0;
        var short = false;
        if (!ended) {
            const step = z.lzma2.decode(in[ip.*..][0..in_cap], dest[0..out_cap]) catch return z.fail(error.InvalidStream, z.lzma2.fail_at, z.lzma2.reason);
            ip.* += step.in_len;
            z.block_in += step.in_len;
            produced = step.out_len;
            z.block_out += produced;
            switch (step.status) {
                .end => {},
                .need_input => {
                    if (h.compressed != null and z.block_in == h.compressed.?) return z.fail(error.InvalidStream, z.offset + ip.*, .block_size);
                    short = true;
                },
                .output_full => if (h.uncompressed != null and z.block_out == h.uncompressed.? and out_cap < dest.len)
                    return z.fail(error.InvalidStream, z.offset + ip.*, .block_size),
            }
        }
        if (filtered) {
            z.pipe.added(produced);
            z.pipe.convert(z.lzma2.done());
            // Give out what every converter has done.
            const ready = z.pipe.ready();
            const n = @min(ready.len, out.len - op.*);
            @memcpy(out[op.*..][0..n], ready[0..n]);
            z.hasher.update(ready[0..n]);
            op.* += n;
            z.pipe.take(n);
        } else {
            z.hasher.update(dest[0..produced]);
            op.* += produced;
        }
        if (z.lzma2.done() and (!filtered or z.pipe.empty())) {
            if (h.compressed) |c| if (z.block_in != c) return z.fail(error.InvalidStream, z.offset + ip.*, .block_size);
            if (h.uncompressed) |u| if (z.block_out != u) return z.fail(error.InvalidStream, z.offset + ip.*, .block_size);
            return .done;
        }
        if (op.* == out.len) return .output_full;
        if (short) return .need_input;
    }
}

/// Declare the end of input after the output is drained: refuses a stream
/// cut short.
pub fn finish(z: *Decompress) Error!void {
    if (z.failure) |err| return err;
    switch (z.phase) {
        .done => return,
        .stream_padding => if (z.padding % 4 == 0) return else return z.fail(error.InvalidStream, z.offset, .stream_padding),
        else => return z.fail(error.Truncated, z.offset, .truncated),
    }
}

/// A `std.Io.Reader` over the same resumable decoder, whose window it
/// allocates as the blocks' headers ask: `buffer` is the reader's own
/// buffering, and a block asking for more than `max_window` bytes
/// (`windowLength` of the largest dictionary to accept) is refused with
/// `error.WindowTooLarge`. A window grows when a later block asks more and
/// is kept when it asks less; `deinit` frees it.
pub const Reader = struct {
    interface: Io.Reader,
    input: *Io.Reader,
    state: Decompress,
    gpa: Allocator,
    max_window: usize,
    failure: ?ReadError = null,

    pub const ReadError = Error || error{OutOfMemory};

    pub fn init(gpa: Allocator, input: *Io.Reader, buffer: []u8, max_window: usize, options: Options) Reader {
        return .{ .interface = .{ .vtable = &.{ .stream = stream, .readVec = readVec }, .buffer = buffer, .seek = 0, .end = 0 }, .input = input, .state = .init(&.{}, options), .gpa = gpa, .max_window = max_window };
    }

    pub fn deinit(r: *Reader) void {
        r.gpa.free(r.state.window);
        r.* = undefined;
    }

    /// The error behind an `error.ReadFailed`, when it was the stream's or
    /// its window's.
    pub fn err(r: *const Reader) ?ReadError {
        return r.failure;
    }

    /// The window a block's header asks for, or its refusal.
    fn grow(r: *Reader) ReadError!void {
        const needed = r.state.windowNeeded();
        if (needed > r.max_window) return r.state.refuseWindow();
        const window = try r.gpa.alloc(u8, needed);
        r.gpa.free(r.state.window);
        r.state.setWindow(window);
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
            if (step.status == .need_window) {
                r.grow() catch |failure| {
                    r.failure = failure;
                    return error.ReadFailed;
                };
                input = &.{};
                continue;
            }
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
