//! Entropy decoding in workers, followed by ordered history execution.
const Decompressor = @This();
const std = @import("std");
const Io = std.Io;
const Native = @import("../Decompressor.zig");
const decode = @import("../decode.zig");
const frame = @import("../frame.zig");
const Dictionary = @import("../Dictionary.zig");
const Diagnostic = @import("../Diagnostic.zig");

pub const Options = struct { concurrency: u16 = 3 };
pub const InitError = std.mem.Allocator.Error || error{InvalidOptions};
pub const Error = Native.Error || Io.Cancelable;

const max_sequences = 0x7f00 + 0xffff;
const Slot = struct {
    prepared: decode.Prepared,
    kind: frame.Block.Kind = .raw,
    bytes: []const u8 = &.{},
    regenerated: usize = 0,
    at: usize = 0,
    last: bool = false,
    failure: ?Native.Error = null,
    reason: Diagnostic.Reason = .truncated,
    offset: usize = 0,

    fn run(slot: *Slot) void {
        slot.prepared.decode() catch |err| {
            slot.failure = err;
            slot.reason = slot.prepared.failure;
            slot.offset = slot.at + 3 + (if (slot.reason == .literals_size) slot.prepared.literal_at else slot.prepared.at);
        };
    }
};

native: Native = .init,
slots: []Slot,
owned: []align(64) u8 = &.{},
gpa: std.mem.Allocator = undefined,

/// Exact worker, entropy, literal and sequence storage.
pub fn memory(options: Options) usize {
    if (options.concurrency == 0) return std.math.maxInt(usize);
    const head_bytes = @as(u64, options.concurrency) * 2 * @sizeOf(Slot);
    if (head_bytes > std.math.maxInt(usize) - 63) return std.math.maxInt(usize);
    const head = std.mem.alignForward(usize, @intCast(head_bytes), 64);
    const stride = std.mem.alignForward(usize, max_sequences * @sizeOf(decode.PreparedSequence) + decode.block_max + decode.margin, 64);
    const size = head +| @as(usize, options.concurrency) *| 2 *| stride;
    if (size > std.math.maxInt(usize) - 63) return std.math.maxInt(usize);
    return std.mem.alignForward(usize, size, 64);
}

pub fn init(gpa: std.mem.Allocator, options: Options) InitError!Decompressor {
    if (options.concurrency == 0) return error.InvalidOptions;
    const size = memory(options);
    if (size == std.math.maxInt(usize)) return error.OutOfMemory;
    const buffer = try gpa.alignedAlloc(u8, .@"64", size);
    var d = initBuffer(buffer, options);
    d.owned = buffer;
    d.gpa = gpa;
    return d;
}

/// Valid options and aligned storage of `memory(options)` bytes.
pub fn initBuffer(buffer: []align(64) u8, options: Options) Decompressor {
    std.debug.assert(buffer.len >= memory(options));
    const slots: []Slot = @alignCast(std.mem.bytesAsSlice(Slot, buffer[0 .. @as(usize, options.concurrency) * 2 * @sizeOf(Slot)])); // safe: caller buffer is 64-byte aligned
    var at = std.mem.alignForward(usize, @sizeOf(Slot) * slots.len, 64);
    const seq_size = max_sequences * @sizeOf(decode.PreparedSequence);
    const stride = std.mem.alignForward(usize, seq_size + decode.block_max + decode.margin, 64);
    for (slots) |*slot| {
        slot.* = .{ .prepared = .{ .tables = undefined, .cursor = undefined, .seqs = @alignCast(std.mem.bytesAsSlice(decode.PreparedSequence, buffer[at..][0..seq_size])), .literals = buffer[at + seq_size ..][0 .. decode.block_max + decode.margin] } }; // safe: each worker starts at a 64-byte boundary
        at += stride;
    }
    return .{ .slots = slots };
}

pub fn deinit(d: *Decompressor) void {
    if (d.owned.len != 0) d.gpa.free(d.owned);
    d.* = undefined;
}

fn fail(options: Native.Options, err: Native.Error, offset: usize, reason: Diagnostic.Reason) Native.Error {
    if (options.diagnostic) |diagnostic| diagnostic.* = .{ .offset = offset, .reason = reason };
    return err;
}

/// Decode frames with entropy jobs in parallel and output in frame order.
/// Partial output uses the core's incremental literal and sequence path.
pub fn decompress(d: *Decompressor, io: Io, in: []const u8, out: []u8, options: Native.Options) Error!Native.Result {
    if (options.partial or in.len < 16 << 10) return d.native.decompress(in, out, options);
    var at: usize = 0;
    var op: usize = 0;
    var frames: usize = 0;
    while (at < in.len) {
        const prefix: usize = if (options.format == .standard) 5 else 1;
        if (in.len - at < prefix) return fail(options, error.Truncated, at, if (frames == 0) .truncated else .trailing_data);
        var fault: frame.Fault = undefined;
        const parsed = frame.parse(in[at..], options.format, &fault) catch |err| return fail(options, err, at + fault.offset, if (frames != 0 and fault.reason == .bad_magic) .trailing_data else fault.reason);
        switch (parsed) {
            .skippable => |skip| {
                if (skip.len > std.math.maxInt(u32) - 8) return fail(options, error.InvalidStream, at, .bad_magic);
                if (skip.len > in.len - at - 8) return fail(options, error.Truncated, at, .truncated);
                at += 8 + skip.len;
            },
            .zstd => |header| {
                if (header.window_size > options.max_window) return fail(options, error.WindowTooLarge, at, .window_too_large);
                const start = at;
                at += header.header_len;
                try d.decodeFrame(io, in, out, &at, &op, header, start, options);
                frames += 1;
                if (options.frames == .one) break;
            },
        }
    }
    if (frames == 0 and options.frames == .one) return fail(options, error.Truncated, at, .truncated);
    return .{ .in_len = at, .out_len = op, .finished = true };
}

fn dictionary(header: frame.Header, options: Native.Options) Native.Error!?*const Dictionary {
    if (header.dictionary_id != 0) {
        for (options.dictionaries) |dict| if (dict.id == header.dictionary_id) return dict;
        return error.DictionaryMismatch;
    }
    return if (options.dictionaries.len == 0) null else options.dictionaries[0];
}

fn decodeFrame(d: *Decompressor, io: Io, in: []const u8, out: []u8, at: *usize, op: *usize, header: frame.Header, start: usize, options: Native.Options) Error!void {
    const dict = dictionary(header, options) catch |err| return fail(options, err, start, .dictionary_mismatch);
    const frame_start = op.*;
    var f: decode.Frame = .{ .tables = &d.native.tables, .entropy = if (dict) |x| x.startEntropy() else .{}, .out = out, .start = frame_start, .dict = if (dict) |x| x.content else &.{}, .block_max = header.blockMax() };
    var hash: std.hash.XxHash64 = .init(0);
    var groups: [2]Io.Group = @splat(.init);
    defer for (&groups) |*group| group.cancel(io);
    const width = d.slots.len / 2;
    var current: usize = 0;
    var batch = queue(io, &f, d.slots[0..width], &groups[0], in, at);
    try groups[0].await(io);
    while (true) {
        const next = 1 - current;
        const following = if (batch.last) Batch{ .count = 0, .last = true } else queue(io, &f, d.slots[next * width ..][0..width], &groups[next], in, at);
        try apply(&f, d.slots[current * width ..][0..batch.count], out, op, &hash, header.checksum and options.verify_checksum, options);
        if (batch.last) break;
        try groups[next].await(io);
        current = next;
        batch = following;
    }
    if (header.content_size) |size| if (op.* - frame_start != size) return fail(options, error.InvalidStream, start, .content_size);
    if (header.checksum) {
        if (in.len - at.* < 4) return fail(options, error.Truncated, at.*, .truncated);
        if (options.verify_checksum and std.mem.readInt(u32, in[at.*..][0..4], .little) != @as(u32, @truncate(hash.final()))) return fail(options, error.ChecksumMismatch, at.*, .checksum);
        at.* += 4;
    }
}

const Batch = struct { count: usize, last: bool };

fn queue(io: Io, f: *decode.Frame, slots: []Slot, group: *Io.Group, in: []const u8, at: *usize) Batch {
    var count: usize = 0;
    var last = false;
    while (count < slots.len and !last) : (count += 1) {
        const slot = &slots[count];
        prepare(f, slot, in, at);
        last = slot.last or slot.failure != null;
        if (slot.failure == null and slot.kind == .compressed) group.async(io, Slot.run, .{slot});
    }
    return .{ .count = count, .last = last };
}

fn apply(f: *decode.Frame, slots: []Slot, out: []u8, op: *usize, hash: *std.hash.XxHash64, verify: bool, options: Native.Options) Native.Error!void {
    for (slots) |*slot| {
        if (slot.kind == .compressed) {
            if (slot.prepared.literal_len > out.len - op.*) return fail(options, error.OutputTooSmall, slot.at + 3, .bad_literals_header);
            if (slot.prepared.count != 0 and op.* == out.len and (slot.failure == null or slot.reason == .bitstream_left)) return fail(options, error.OutputTooSmall, slot.at + 3 + slot.prepared.sequence_at, .bad_sequences_header);
        }
        if (slot.failure) |err| return fail(options, err, slot.offset, slot.reason);
        const before = op.*;
        switch (slot.kind) {
            .raw => {
                if (slot.bytes.len > out.len - op.*) return fail(options, error.OutputTooSmall, slot.at, .truncated);
                @memcpy(out[op.*..][0..slot.bytes.len], slot.bytes);
                op.* += slot.bytes.len;
            },
            .rle => {
                if (slot.regenerated > out.len - op.*) return fail(options, error.OutputTooSmall, slot.at, .truncated);
                @memset(out[op.*..][0..slot.regenerated], slot.bytes[0]);
                op.* += slot.regenerated;
            },
            .compressed => {
                op.* += f.applyBlock(&slot.prepared, op.*) catch |err| return fail(options, err, slot.at + 3 + f.fault.offset, f.fault.reason);
            },
            .reserved => unreachable, // unreachable: prepare refuses reserved blocks
        }
        if (verify) hash.update(out[before..op.*]);
    }
}

fn prepare(f: *decode.Frame, slot: *Slot, in: []const u8, at: *usize) void {
    slot.at = at.*;
    slot.failure = null;
    slot.reason = .truncated;
    slot.offset = at.*;
    slot.last = false;
    slot.kind = .raw;
    slot.prepared.literal_len = 0;
    slot.prepared.count = 0;
    if (in.len - at.* < 3) {
        slot.failure = error.Truncated;
        return;
    }
    const block = frame.blockHeader(in[at.*..][0..3]);
    slot.kind = block.kind;
    slot.last = block.last;
    at.* += 3;
    if (block.kind == .reserved or (block.kind == .compressed and block.size > f.block_max)) {
        slot.failure = error.InvalidStream;
        slot.reason = if (block.kind == .reserved) .bad_block_type else .block_too_large;
        return;
    }
    if (block.size > in.len - at.*) {
        slot.failure = error.Truncated;
        return;
    }
    slot.bytes = in[at.*..][0..block.size];
    slot.regenerated = block.regenerated;
    if (block.kind == .compressed) f.prepareBlock(slot.bytes, &slot.prepared) catch |err| {
        slot.failure = err;
        slot.reason = f.fault.reason;
        slot.offset = slot.at + 3 + f.fault.offset;
        return;
    };
    at.* += block.size;
}
