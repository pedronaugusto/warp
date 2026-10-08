//! Streaming compression to raw DEFLATE, zlib or gzip: input taken in
//! pieces of any size, output handed out in pieces of any size, flushes
//! wherever the caller wants a restart or a boundary.
//!
//! The input goes into a window of 2^(w+1) bytes and a look-ahead, which
//! slides by 2^w when it fills; the engine parses positions whose bytes are
//! all at hand, keeps each block's literals apart (the window moves on
//! before the block is written), and writes each block into a pending
//! buffer the calls drain. The bytes out depend only on the bytes in, the
//! options and where the flushes and level changes fall: never on how the
//! input or the output was cut.

const Deflate = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const bits = @import("../bits.zig");
const deflate = @import("../deflate.zig");
const block = @import("../deflate/block.zig");
const container = @import("../container.zig");
const checksum = @import("../checksum.zig");
const gzip = @import("../gzip.zig");
const match = @import("../match.zig");

/// Private: the engine's tables and the parse.
engine: deflate.Engine,
/// Private: the options given to `init`.
options: Options,
/// Private: the window and the look-ahead, and how much of it holds
/// bytes.
window: []u8,
filled: usize = 0,
/// Private: bytes slid out of the window since the stream started.
slid: u64 = 0,
/// Private: output written and not yet handed out.
pending: []u8,
pending_start: usize = 0,
pending_end: usize = 0,
/// Private: the bits of the last output byte, not yet whole.
bitbuf: u64 = 0,
bitcount: u6 = 0,
/// Private: the checksum of the input taken, and its length.
check: u32 = 0,
size: u32 = 0,
/// Private: a flush or the finish under way.
closing: ?Closing = null,
finished: bool = false,
/// Private: the level and strategy a `setLevel` under way changes to.
change: ?Change = null,
/// Private: the memory `init` allocated, freed by `deinit`; empty after
/// `initBuffer`.
owned: []align(64) u8 = &.{},
gpa: Allocator = undefined,

pub const Strategy = deflate.Strategy;

/// How a flush ends what is written so far.
pub const Flush = enum {
    /// The current block, then an empty fixed-code block (ten bits, not
    /// byte-aligned): OpenSSH's `zlib@openssh.com`.
    partial,
    /// The current block, then an empty stored block (`00 00 ff ff`),
    /// byte-aligned: RFC 7692 strips the four bytes.
    sync,
    /// As `sync`, and no later match reaches before this point: a restart
    /// point.
    full,
    /// The current block only.
    block,
};

pub const Options = struct {
    /// 0 stored, 1-9 zlib's scale, 10-12 near-optimal. 13-15 mean 12.
    level: u4 = 6,
    /// Reserve the iterative parser for later level changes. The initial
    /// level is always supported; 9 keeps low-level streams small.
    max_level: u4 = 9,
    /// Cost-model passes at levels 10-12.
    passes: ?u32 = null,
    strategy: Strategy = .default,
    container: container.Container = .zlib,
    /// 8-15: the farthest distance written, and the history kept.
    window_bits: u4 = 15,
    /// The hash tables' size in bits, 8-16 (zlib's memLevel + 7); null: one
    /// more than the window's, from 10 to 15.
    hash_bits: ?u5 = null,
    /// Bytes that precede the input as history: a zlib stream names them
    /// (FDICT). Only the last 2^window_bits count.
    dictionary: []const u8 = &.{},
    /// The gzip member header; its slices are read by `init` and `reset`.
    gzip: gzip.Header = .{},
};

const Closing = struct { mode: Mode, step: enum { parse, mark, done } };
const Mode = enum { partial, sync, full, block, finish };
const Change = struct { level: u4, strategy: Strategy };

/// The engine's sizes, the window's and the pending buffer's.
const Layout = struct {
    sizes: deflate.Sizes,
    window: usize,
    pending: usize,
    /// The longest stored block: one fits in the pending buffer.
    stored_max: usize,

    fn of(options: Options) Layout {
        std.debug.assert(options.window_bits >= 8);
        const hash_bits = options.hash_bits orelse std.math.clamp(@as(u5, options.window_bits) + 1, 10, 15);
        std.debug.assert(hash_bits >= 8);
        std.debug.assert(hash_bits <= 16);
        const sizes = deflate.Sizes.stream(options.window_bits, hash_bits, @max(options.level, options.max_level) >= 10);
        // The longest block: its literals, and matches of three bytes at most
        // for the near-optimal parser's, whose sequences are made from them.
        const matches = if (sizes.nodes != 0) sizes.literals / 3 else sizes.sequences;
        const block_bytes = block.bound(sizes.literals, matches) / 8 + 1;
        return .{
            .sizes = sizes,
            .window = 2 * sizes.window + deflate.lookahead,
            // A block, a flush's marks, the header and the trailer, and the
            // bit writer's room.
            .pending = block_bytes + 16 + gzip.headerLen(options.gzip) + 8 + 8,
            .stored_max = @min(65535, block_bytes - 8),
        };
    }

    fn memory(l: Layout) usize {
        return std.mem.alignForward(usize, l.sizes.memory(), 64) + l.window + l.pending;
    }
};

/// The bytes `initBuffer` needs for `options`.
pub fn memory(options: Options) usize {
    return Layout.of(options).memory();
}

pub fn init(gpa: Allocator, options: Options) Allocator.Error!Deflate {
    const buffer = try gpa.alignedAlloc(u8, .@"64", memory(options));
    var d = initBuffer(buffer, options);
    d.owned = buffer;
    d.gpa = gpa;
    return d;
}

/// A stream in caller memory: `buffer.len >= memory(options)`; `deinit`
/// then frees nothing.
pub fn initBuffer(buffer: []align(64) u8, options: Options) Deflate {
    const layout = Layout.of(options);
    std.debug.assert(buffer.len >= layout.memory());
    const engine_len = std.mem.alignForward(usize, layout.sizes.memory(), 64);
    var d: Deflate = .{
        .engine = .init(buffer[0..engine_len], layout.sizes),
        .options = options,
        .window = buffer[engine_len..][0..layout.window],
        .pending = buffer[engine_len + layout.window ..][0..layout.pending],
    };
    d.engine.b.stored_max = layout.stored_max;
    d.begin(.nothing);
    return d;
}

pub fn deinit(d: *Deflate) void {
    if (d.owned.len != 0) d.gpa.free(d.owned);
    d.* = undefined;
}

/// What a call did: the input it took and the output it wrote.
pub const Step = struct { in_len: usize, out_len: usize };

/// Take input and write what output is ready. Never fails; takes no input
/// while output it has ready does not fit in `out`.
pub fn write(d: *Deflate, in: []const u8, out: []u8) Step {
    std.debug.assert(!d.finished);
    std.debug.assert(d.closing == null);
    var step: Step = .{ .in_len = 0, .out_len = d.drain(out) };
    while (d.pending_start == d.pending_end) {
        if (d.pump(.more) == .block) {
            step.out_len += d.drain(out[step.out_len..]);
            continue;
        }
        // Nothing more to parse with the bytes at hand: take more.
        if (step.in_len == in.len) break;
        if (d.filled == d.window.len) {
            if (d.slide()) {
                step.out_len += d.drain(out[step.out_len..]);
                continue;
            }
        }
        const n = @min(in.len - step.in_len, d.window.len - d.filled);
        const piece = in[step.in_len..][0..n];
        @memcpy(d.window[d.filled..][0..n], piece);
        d.sum(piece);
        d.filled += n;
        step.in_len += n;
    }
    return step;
}

/// What a flush or the finish did: the output it wrote, and whether it
/// is done (else call again with more room).
pub const Drain = struct { out_len: usize, done: bool };

/// Make every byte taken so far decodable from the output, as `mode`
/// says. Call until `done`.
pub fn flush(d: *Deflate, mode: Flush, out: []u8) Drain {
    std.debug.assert(!d.finished);
    return d.close(switch (mode) {
        .partial => .partial,
        .sync => .sync,
        .full => .full,
        .block => .block,
    }, out);
}

/// End the stream: the last block and the trailer. Call until `done`.
pub fn finish(d: *Deflate, out: []u8) Drain {
    if (d.finished) {
        const n = d.drain(out);
        return .{ .out_len = n, .done = d.pending_start == d.pending_end };
    }
    return d.close(.finish, out);
}

/// What the next stream starts with.
pub const Keep = enum {
    /// The dictionary, if the options give one.
    nothing,
    /// The window as this stream left it: the next stream's matches reach
    /// into it (RFC 7692's context takeover, between raw streams).
    history,
};

/// Start a new stream with the same options. Output not yet handed out is
/// dropped.
pub fn reset(d: *Deflate, keep: Keep) void {
    d.begin(keep);
}

/// Compress every byte taken so far with the current level and strategy,
/// ending a block there as `flush(.block, ...)` does, then change them
/// (zlib's `deflateParams`). Call until `done`.
pub fn setLevel(d: *Deflate, level: u4, strategy: Strategy, out: []u8) Drain {
    std.debug.assert(!d.finished);
    std.debug.assert(level < 10 or d.engine.sizes.nodes != 0);
    if (d.closing == null) d.change = .{ .level = level, .strategy = strategy };
    return d.close(.block, out);
}

/// A new stream: the header in the pending buffer, the window empty or
/// kept, the engine at its start.
fn begin(d: *Deflate, keep: Keep) void {
    d.pending_start = 0;
    d.pending_end = 0;
    d.bitbuf = 0;
    d.bitcount = 0;
    d.closing = null;
    d.finished = false;
    d.change = null;
    d.size = 0;
    d.check = if (d.options.container == .zlib) 1 else 0;
    const window = @as(usize, 1) << d.options.window_bits;
    var first: usize = undefined;
    if (keep == .history) {
        // The window as it is: the new stream starts after its bytes.
        first = d.filled;
    } else {
        const dictionary = d.options.dictionary[d.options.dictionary.len -| window..];
        @memcpy(d.window[0..dictionary.len], dictionary);
        d.filled = dictionary.len;
        d.slid = 0;
        first = dictionary.len;
    }
    const h: match.History = .{ .in = d.window[0..d.filled] };
    if (keep == .history) {
        d.engine.b.restart(first);
        if (d.engine.sizes.nodes != 0) d.engine.opt.restart(first);
        d.engine.first = first;
        d.engine.primed = @intCast(first);
    } else d.engine.start(h, first, std.math.maxInt(usize), d.options.level, d.options.strategy);
    if (d.options.passes) |passes| d.engine.setPasses(passes);
    d.writeHeader();
}

fn writeHeader(d: *Deflate) void {
    const options = d.options;
    switch (options.container) {
        .raw => {},
        .zlib => {
            const id: ?u32 = if (options.dictionary.len != 0) checksum.adler32(1, options.dictionary) else null;
            d.pending_end = container.zlibHeader(options.window_bits, options.level, options.strategy == .huffman_only, id, d.pending);
        },
        .gzip => {
            var header = options.gzip;
            if (header.xfl == null) header.xfl = if (options.level >= 9) 2 else if (options.level == 1) 4 else 0;
            var w: Io.Writer = .fixed(d.pending);
            // unreachable: the pending buffer has room for the header
            gzip.writeHeader(&w, header) catch unreachable;
            d.pending_end = w.end;
        },
    }
}

/// The checksum the trailer carries, over input taken.
fn sum(d: *Deflate, bytes: []const u8) void {
    switch (d.options.container) {
        .raw => {},
        .zlib => d.check = checksum.adler32(d.check, bytes),
        .gzip => {
            d.check = checksum.crc32(d.check, bytes);
            // safe: ISIZE is the length modulo 2^32
            d.size +%= @truncate(bytes.len);
        },
    }
}

/// Hand out pending output; how much.
fn drain(d: *Deflate, out: []u8) usize {
    const n = @min(out.len, d.pending_end - d.pending_start);
    @memcpy(out[0..n], d.pending[d.pending_start..][0..n]);
    d.pending_start += n;
    if (d.pending_start == d.pending_end) {
        d.pending_start = 0;
        d.pending_end = 0;
    }
    return n;
}

/// A bit writer over the pending buffer, after the bits left over.
fn writer(d: *Deflate) bits.Writer {
    return .{ .out = d.pending, .at = d.pending_end, .bitbuf = d.bitbuf, .count = d.bitcount };
}

fn keepWriter(d: *Deflate, w: *const bits.Writer) void {
    std.debug.assert(!w.overflow);
    d.pending_end = w.at;
    d.bitbuf = w.bitbuf;
    d.bitcount = w.count;
}

/// Parse with the pending buffer empty, into it.
fn pump(d: *Deflate, end: deflate.End) deflate.Progress {
    std.debug.assert(d.pending_start == d.pending_end);
    var w = d.writer();
    const progress = d.engine.parse(true, .{ .in = d.window[0..d.filled] }, &w, end);
    d.keepWriter(&w);
    return progress;
}

/// The change a `setLevel` asked for, its block flushed.
fn applyChange(d: *Deflate) void {
    const change = d.change orelse return;
    d.change = null;
    const before = d.engine.finder;
    d.engine.setLevel(change.level, change.strategy);
    if (d.engine.finder != before) {
        // The new matchfinder learns the window's positions before `p`.
        const p = d.engine.b.p;
        const first = d.engine.first;
        d.engine.start(.{ .in = d.window[0..d.filled] }, p, std.math.maxInt(usize), change.level, change.strategy);
        d.engine.first = first;
    }
    if (d.options.passes) |passes| d.engine.setPasses(passes);
    d.options.level = change.level;
    d.options.strategy = change.strategy;
}

/// Make room in a full window: move it back 2^w bytes. Stored blocks and
/// near-optimal parse caches need their original bytes, so end them before
/// those bytes expire; drain any output before sliding.
fn slide(d: *Deflate) bool {
    const window = @as(usize, 1) << d.options.window_bits;
    const b = &d.engine.b;
    const cached = d.engine.level.parser == .optimal and d.engine.strategy != .huffman_only and d.engine.strategy != .rle;
    if ((b.kinds == .stored_only or cached) and b.start < window) {
        var w = d.writer();
        d.engine.endBlock(&w, .{ .in = d.window[0..d.filled] });
        d.keepWriter(&w);
        if (d.pending_end != 0) return true;
    }
    @memmove(d.window[0 .. d.filled - window], d.window[window..d.filled]);
    d.filled -= window;
    d.slid += window;
    d.engine.slide(window);
    return false;
}

/// A flush or the finish: parse everything to the end, then the mark the
/// mode writes; one step at a time while the output drains.
fn close(d: *Deflate, mode: Mode, out: []u8) Drain {
    var out_len = d.drain(out);
    if (d.closing == null) d.closing = .{ .mode = mode, .step = .parse };
    const c = &d.closing.?;
    std.debug.assert(c.mode == mode);
    while (d.pending_start == d.pending_end) {
        switch (c.step) {
            .parse => if (d.pump(if (mode == .finish) .final else .flush) == .done) {
                c.step = .mark;
            },
            .mark => {
                d.mark(mode);
                c.step = .done;
            },
            .done => {
                d.closing = null;
                if (mode == .finish) d.finished = true;
                d.applyChange();
                return .{ .out_len = out_len, .done = true };
            },
        }
        out_len += d.drain(out[out_len..]);
    }
    return .{ .out_len = out_len, .done = false };
}

/// What a flush writes after its block, or the finish after the last.
fn mark(d: *Deflate, mode: Mode) void {
    var w = d.writer();
    switch (mode) {
        .block => {},
        .partial => {
            // An empty fixed-code block: its header and the end code.
            w.add(2, 3);
            w.add(0, 7);
            w.flush();
        },
        .sync, .full => {
            // An empty stored block.
            w.add(0, 3);
            w.alignToByte();
            w.add(0xffff_0000, 32);
            w.flush();
            if (mode == .full) d.engine.forget();
        },
        .finish => {
            w.alignToByte();
            var trailer: [8]u8 = undefined;
            switch (d.options.container) {
                .raw => {},
                .zlib => {
                    std.mem.writeInt(u32, trailer[0..4], d.check, .big);
                    w.writeBytes(trailer[0..4]);
                },
                .gzip => {
                    std.mem.writeInt(u32, trailer[0..4], d.check, .little);
                    std.mem.writeInt(u32, trailer[4..8], d.size, .little);
                    w.writeBytes(&trailer);
                },
            }
        },
    }
    d.keepWriter(&w);
}

/// A `std.Io.Writer` that compresses into `output`. Its buffer stages the
/// input; `flush` is a sync flush.
pub const Writer = struct {
    interface: Io.Writer,
    state: *Deflate,
    output: *Io.Writer,

    /// `buffer.len >= 4096`: the input staged before it is compressed.
    pub fn init(state: *Deflate, output: *Io.Writer, buffer: []u8) Writer {
        std.debug.assert(buffer.len >= 4096);
        return .{
            .interface = .{ .vtable = &vtable, .buffer = buffer },
            .state = state,
            .output = output,
        };
    }

    const vtable: Io.Writer.VTable = .{ .drain = drainVtable, .flush = flushVtable };

    /// Compress everything staged and given, then flush as `mode` says.
    pub fn flushMode(w: *Writer, mode: Flush) Io.Writer.Error!void {
        try w.take(w.interface.buffered());
        w.interface.end = 0;
        while (true) {
            const out = try w.output.writableSliceGreedy(1);
            const drained = w.state.flush(mode, out);
            w.output.advance(drained.out_len);
            if (drained.done) return;
        }
    }

    /// Compress everything staged and end the stream. The `Deflate` stays
    /// valid; `deinit` is still owed.
    pub fn finish(w: *Writer) Io.Writer.Error!void {
        try w.take(w.interface.buffered());
        w.interface.end = 0;
        while (true) {
            const out = try w.output.writableSliceGreedy(1);
            const drained = w.state.finish(out);
            w.output.advance(drained.out_len);
            if (drained.done) return;
        }
    }

    /// Compress `bytes`, all of them.
    fn take(w: *Writer, bytes: []const u8) Io.Writer.Error!void {
        var at: usize = 0;
        while (at < bytes.len) {
            const out = try w.output.writableSliceGreedy(1);
            const step = w.state.write(bytes[at..], out);
            w.output.advance(step.out_len);
            at += step.in_len;
        }
    }

    fn drainVtable(io_w: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const w: *Writer = @fieldParentPtr("interface", io_w);
        try w.take(io_w.buffered());
        io_w.end = 0;
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |bytes| {
            try w.take(bytes);
            n += bytes.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            try w.take(last);
            n += last.len;
        }
        return n;
    }

    fn flushVtable(io_w: *Io.Writer) Io.Writer.Error!void {
        const w: *Writer = @fieldParentPtr("interface", io_w);
        return w.flushMode(.sync);
    }
};
