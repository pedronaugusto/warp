//! Searches and marker decodes happen before the predecessor's history is
//! known. Only the coordinator may accept a candidate, at an exact boundary
//! reached from the real stream header. No index or checksum guess establishes it.
const Speculative = @This();
const std = @import("std");
const Io = std.Io;
const engine = @import("../inflate.zig");
const marked = @import("../marked.zig");
const unwrap = @import("../unwrap.zig");
const Native = @import("../Decompressor.zig");

workers: []Worker,
options: Options,

pub const Statistics = struct {
    searched_bits: usize = 0,
    candidates: usize = 0,
    rejected: usize = 0,
    speculative_bytes: usize = 0,
    serial_bytes: usize = 0,
    chunks: usize = 0,
    limited: usize = 0,
};

pub const Options = struct {
    /// Maximum decoded bytes retained per worker, in two-byte marker form.
    chunk_len: u32 = 1 << 20,
    /// Compressed bytes per search partition. Large ratios may need a
    /// larger chunk_len or smaller search_len; exhausted jobs fall back.
    search_len: u32 = 32 << 10,
    /// Work on false candidates is bounded by this multiple of chunk_len.
    work_limit: u8 = 4,
    /// Maximum block descriptors per worker, including empty blocks.
    max_blocks: u16 = 1024,
    statistics: ?*Statistics = null,
};

const Candidate = struct { count: usize };
const Block = struct {
    start: usize,
    end: usize,
    token: usize,
    len: usize,
    final: bool,
    required: usize,
    max_distance: u32,
};

const Worker = struct {
    group: Io.Group = .init,
    tokens: []u16,
    blocks: []Block,
    input: []const u8 = &.{},
    from: usize = 0,
    until: usize = 0,
    candidate: ?Candidate = null,
    stats: Statistics = .{},
    fixed_first: bool = false,
};

pub fn memory(concurrency: u16, options: Options) usize {
    std.debug.assert(concurrency > 0);
    std.debug.assert(options.chunk_len > 0);
    std.debug.assert(options.search_len > 0);
    std.debug.assert(options.work_limit > 0);
    std.debug.assert(options.max_blocks > 0);
    return std.mem.alignForward(usize, @as(usize, @sizeOf(Worker)) * concurrency, 64) +
        (std.mem.alignForward(usize, @as(usize, options.chunk_len) * @sizeOf(u16), 64) +
            std.mem.alignForward(usize, @as(usize, options.max_blocks) * @sizeOf(Block), 64)) * concurrency;
}

pub fn initBuffer(buffer: []align(64) u8, concurrency: u16, options: Options) Speculative {
    std.debug.assert(buffer.len >= memory(concurrency, options));
    const workers = @as([*]Worker, @ptrCast(buffer.ptr))[0..concurrency]; // safe: aligned memory reserves all worker records
    var at = std.mem.alignForward(usize, @as(usize, @sizeOf(Worker)) * concurrency, 64);
    for (workers) |*w| {
        const tokens = @as([*]u16, @ptrCast(@alignCast(buffer[at..].ptr)))[0..options.chunk_len]; // safe: padded, aligned token regions are reserved by memory
        at += std.mem.alignForward(usize, @as(usize, options.chunk_len) * @sizeOf(u16), 64);
        const blocks = @as([*]Block, @ptrCast(@alignCast(buffer[at..].ptr)))[0..options.max_blocks]; // safe: padded, aligned descriptor regions are reserved by memory
        at += std.mem.alignForward(usize, @as(usize, options.max_blocks) * @sizeOf(Block), 64);
        w.* = .{ .tokens = tokens, .blocks = blocks };
    }
    return .{ .workers = workers, .options = options };
}

pub fn inflate(p: *Speculative, io: Io, input: []const u8, output: []u8, options: Native.Options) (Native.InflateError || Io.Cancelable)!Native.Result {
    if (p.options.statistics) |stats| stats.* = .{};
    // Partial requests and small inputs retain the native decoder's exact
    // progress and diagnostics without launching speculative work.
    if (options.partial or input.len <= p.options.search_len or input.len > std.math.maxInt(usize) / 8) {
        var native: Native = .init;
        return native.inflate(input, output, options);
    }
    var tables: engine.Tables = .{};
    var state: unwrap.State = .{};
    var stream: engine.Stream = .{ .in = input, .ip = 0, .out = output, .op = 0, .start = 0, .diagnostic = options.diagnostic };
    const machine: unwrap.Options = .{ .accept = options.accept, .dictionary = options.dictionary, .members = options.members };
    // Decode the first real block, then favor its coding kind during
    // discovery. This is the required prefix, not an index pass.
    const first_done = try advance(&tables, &state, &stream, machine);
    if (p.options.statistics) |stats| stats.serial_bytes += stream.op;
    if (first_done) return finish(&stream);
    var next: usize = p.options.search_len;
    for (p.workers) |*w| {
        w.fixed_first = state.engine.fixed;
        p.submit(io, w, input, &next);
    }
    defer for (p.workers) |*w| w.group.cancel(io);
    var slot: usize = 0;
    var active = @min(p.workers.len, (input.len - 1) / p.options.search_len);
    while (true) {
        try io.checkCancel();
        const bit: usize = @intCast(stream.bitOffset()); // safe: consumed bits are within this addressable input
        if (active > 0 and state.phase == .body and state.engine.phase == .header) {
            const w = &p.workers[slot];
            if (bit >= w.from) {
                try w.group.await(io);
                if (w.candidate) |candidate| {
                    var first: usize = 0;
                    while (first < candidate.count and w.blocks[first].start < bit) : (first += 1) {}
                    if (first < candidate.count and w.blocks[first].start > bit) {
                        // A true predecessor may reach a later boundary in
                        // this candidate after its false prefix is discarded.
                        const before = stream.op;
                        const ended = try advance(&tables, &state, &stream, machine);
                        if (p.options.statistics) |stats| stats.serial_bytes += stream.op - before;
                        if (ended) return finish(&stream);
                        continue;
                    }
                    if (first < candidate.count) {
                        for (w.blocks[first..candidate.count]) |block| {
                            if (block.required > stream.op - stream.start + stream.history.len() or
                                block.max_distance > stream.window or block.len > output.len - stream.op) break;
                            resolve(w.tokens[block.token..][0..block.len], &stream, block.required);
                            state.checked = stream.op - block.len;
                            state.sum(&stream);
                            setBit(&stream, block.end);
                            state.engine = .{ .phase = if (block.final) .done else .header, .final = block.final };
                            w.stats.speculative_bytes += block.len;
                        }
                        if (w.stats.speculative_bytes > 0) w.stats.chunks += 1;
                    } else w.stats.rejected += 1;
                }
                p.collect(w);
                p.submit(io, w, input, &next);
                if (w.input.len == 0) active -= 1;
                slot = (slot + 1) % p.workers.len;
                continue;
            }
        }
        const before = stream.op;
        const ended = try advance(&tables, &state, &stream, machine);
        if (p.options.statistics) |stats| stats.serial_bytes += stream.op - before;
        if (ended) return finish(&stream);
    }
}

fn advance(t: *engine.Tables, state: *unwrap.State, s: *engine.Stream, options: unwrap.Options) Native.InflateError!bool {
    switch (try unwrap.run(t, state, s, engine.no_more, options)) {
        .done => return true,
        .output_full => unreachable, // unreachable: non-partial whole-buffer decoding returns OutputTooSmall instead
        .block_end => return false,
        .member_end => {
            s.need(engine.no_more, 8);
            return s.bitsleft < 8 * (s.virtual + 1);
        },
    }
}

fn finish(s: *const engine.Stream) Native.Result {
    return .{ .in_len = s.ip - s.bitsleft / 8, .out_len = s.op, .finished = true };
}

fn setBit(s: *engine.Stream, bit: usize) void {
    s.ip = bit / 8;
    s.bitbuf = 0;
    s.bitsleft = 0;
    s.virtual = 0;
    if (bit % 8 != 0) {
        s.bitbuf = s.in[s.ip] >> @as(u3, @intCast(bit % 8)); // safe: pending bits belong to this byte
        s.bitsleft = @intCast(8 - bit % 8); // safe: 1-7 pending bits
        s.ip += 1;
    }
}

fn resolve(tokens: []const u16, s: *engine.Stream, required: usize) void {
    var history: [engine.max_distance]u8 = undefined;
    const n = @min(engine.max_distance, s.op - s.start);
    const dict = @min(engine.max_distance - n, s.history.len());
    if (required > 0) {
        if (dict > 0) s.history.copyOut(dict, history[engine.max_distance - n - dict ..][0..dict]);
        @memcpy(history[engine.max_distance - n ..], s.out[s.op - n .. s.op]);
    }
    for (tokens, s.out[s.op..][0..tokens.len]) |token, *byte| {
        byte.* = if (token < 256) @intCast(token) else history[token - 256]; // safe: byte symbols are 0-255; markers reference the validated history
    }
    s.op += tokens.len;
}

fn submit(p: *Speculative, io: Io, w: *Worker, input: []const u8, next: *usize) void {
    w.candidate = null;
    w.stats = .{};
    if (next.* >= input.len) {
        w.input = &.{};
        return;
    }
    w.input = input;
    w.from = next.* * 8;
    next.* += @min(p.options.search_len, input.len - next.*);
    w.until = next.* * 8;
    w.group.async(io, search, .{ w, io, p.options });
}

fn collect(p: *Speculative, w: *const Worker) void {
    if (p.options.statistics) |s| {
        s.searched_bits += w.stats.searched_bits;
        s.candidates += w.stats.candidates;
        s.rejected += w.stats.rejected;
        s.speculative_bytes += w.stats.speculative_bytes;
        s.chunks += w.stats.chunks;
        s.limited += w.stats.limited;
    }
}

fn search(w: *Worker, io: Io, options: Options) void {
    searchInner(w, io, options) catch return;
}

fn searchInner(w: *Worker, io: Io, options: Options) Io.Cancelable!void {
    var budget: usize = @as(usize, options.chunk_len) * options.work_limit;
    for ([_]bool{ w.fixed_first, !w.fixed_first }) |fixed| {
        var bit = w.from;
        while (bit < w.until and budget > 0) : (bit += 1) {
            if (bit & 4095 == 0) try io.checkCancel();
            w.stats.searched_bits += 1;
            if (!marked.plausible(w.input, bit, fixed)) continue;
            w.stats.candidates += 1;
            var decoder = marked.Decoder.init(w.input, bit, w.tokens);
            var count: usize = 0;
            var written: usize = 0;
            while (count < w.blocks.len) {
                const begin: usize = @intCast(decoder.stream.bitOffset()); // safe: block starts are real bits within input
                const status = decoder.block(io) catch |err| {
                    if (err == error.Canceled) return error.Canceled;
                    if (err == error.OutputTooSmall) w.stats.limited += 1;
                    break;
                };
                const end: usize = @intCast(decoder.stream.bitOffset()); // safe: successful decode consumed real bits from input
                w.blocks[count] = .{ .start = begin, .end = end, .token = written, .len = decoder.written, .final = status == .done, .required = decoder.required, .max_distance = decoder.max_distance };
                written += decoder.written;
                count += 1;
                if (end >= w.until or status == .done) {
                    if (status == .done and end < w.until and w.until < w.input.len * 8) break;
                    w.candidate = .{ .count = count };
                    return;
                }
                // Each block has its own symbolic predecessor window. That
                // lets a validated suffix survive a falsely decoded prefix.
                decoder.tokens = w.tokens[written..];
                decoder.written = 0;
                decoder.required = 0;
                decoder.max_distance = 0;
            }
            budget -|= @max(written + decoder.written, 1);
            w.stats.rejected += 1;
        }
    }
    if (budget == 0) w.stats.limited += 1;
}
