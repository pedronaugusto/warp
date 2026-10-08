//! Independent frames followed by a seek table in a skippable frame.
//! The index borrows compressed bytes; readers decode frames by index or
//! uncompressed offset without allocating per read.
const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const Compressor = @import("Compressor.zig");
const Decompressor = @import("Decompressor.zig");
const Dictionary = @import("Dictionary.zig");
const frame = @import("frame.zig");

pub const magic: u32 = 0x8f92eab1;
const skippable_magic: u32 = 0x184d2a5e;
pub const Error = error{ InvalidSeekTable, Truncated, OutputTooSmall, FrameOutOfRange };

pub const Entry = struct {
    compressed_offset: u64,
    decompressed_offset: u64,
    compressed_len: u32,
    decompressed_len: u32,
    checksum: ?u32,
};

pub const Index = struct {
    input: []const u8,
    entries: []Entry,
    content_size: u64,
    owned: bool = false,
    gpa: Allocator = undefined,

    const Footer = struct { count: u32, stride: usize, start: usize, records: []const u8 };

    fn footer(in: []const u8) Error!Footer {
        if (in.len < 17) return error.Truncated;
        const end = in[in.len - 9 ..];
        if (std.mem.readInt(u32, end[5..9], .little) != magic or end[4] & 0x7c != 0) return error.InvalidSeekTable;
        const count = std.mem.readInt(u32, end[0..4], .little);
        const stride: usize = if (end[4] & 0x80 != 0) 12 else 8;
        const size = std.math.mul(usize, count, stride) catch return error.InvalidSeekTable;
        if (size > in.len - 17 or size > std.math.maxInt(u32) - 9) return error.Truncated;
        const start = in.len - 17 - size;
        if (std.mem.readInt(u32, in[start..][0..4], .little) != skippable_magic or std.mem.readInt(u32, in[start + 4 ..][0..4], .little) != size + 9) return error.InvalidSeekTable;
        return .{ .count = count, .stride = stride, .start = start, .records = in[start + 8 ..][0..size] };
    }

    /// Exact number of Entry bytes required by `initBuffer`.
    pub fn memory(in: []const u8) Error!usize {
        const f = try footer(in);
        return std.math.mul(usize, f.count, @sizeOf(Entry)) catch error.InvalidSeekTable;
    }

    pub fn init(gpa: Allocator, in: []const u8) (Error || Allocator.Error)!Index {
        const f = try footer(in);
        const entries = try gpa.alloc(Entry, f.count);
        errdefer gpa.free(entries);
        var index = try initBuffer(entries, in);
        index.owned = true;
        index.gpa = gpa;
        return index;
    }

    /// Caller entries hold the index; compressed bytes remain borrowed.
    pub fn initBuffer(entries: []Entry, in: []const u8) Error!Index {
        const f = try footer(in);
        if (entries.len < f.count) return error.OutputTooSmall;
        var compressed: u64 = 0;
        var decompressed: u64 = 0;
        for (entries[0..f.count], 0..) |*entry, i| {
            const bytes = f.records[i * f.stride ..][0..f.stride];
            const clen = std.mem.readInt(u32, bytes[0..4], .little);
            const dlen = std.mem.readInt(u32, bytes[4..8], .little);
            if (clen == 0 or compressed + clen > f.start) return error.InvalidSeekTable;
            const offset: usize = @intCast(compressed);
            const encoded = in[offset..][0..clen];
            const actual = frame.frameLength(encoded, .standard) catch return error.InvalidSeekTable;
            if (actual != clen) return error.InvalidSeekTable;
            const header = frame.frameHeader(encoded, .standard) catch return error.InvalidSeekTable;
            switch (header) {
                .skippable => if (dlen != 0) return error.InvalidSeekTable,
                .zstd => |h| if (h.content_size) |size| if (size != dlen) return error.InvalidSeekTable,
            }
            entry.* = .{ .compressed_offset = compressed, .decompressed_offset = decompressed, .compressed_len = clen, .decompressed_len = dlen, .checksum = if (f.stride == 12) std.mem.readInt(u32, bytes[8..12], .little) else null };
            compressed += clen;
            decompressed = std.math.add(u64, decompressed, dlen) catch return error.InvalidSeekTable;
        }
        if (compressed != f.start) return error.InvalidSeekTable;
        return .{ .input = in[0..f.start], .entries = entries[0..f.count], .content_size = decompressed };
    }

    pub fn deinit(index: *Index) void {
        if (index.owned) index.gpa.free(index.entries);
        index.* = undefined;
    }

    /// Frame containing an uncompressed byte. Empty frames are skipped.
    pub fn find(index: *const Index, offset: u64) ?usize {
        if (offset >= index.content_size) return null;
        var lo: usize = 0;
        var hi = index.entries.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (index.entries[mid].decompressed_offset <= offset) lo = mid + 1 else hi = mid;
        }
        return lo - 1;
    }
};

pub const Reader = struct {
    index: *const Index,
    decoder: Decompressor = .init,
    options: Decompressor.Options,
    buffer: []u8,

    /// The buffer holds the largest decoded frame for offset reads.
    /// `readFrame` can instead decode directly into a caller's output.
    pub fn init(index: *const Index, buffer: []u8, options: Decompressor.Options) Reader {
        return .{ .index = index, .buffer = buffer, .options = options };
    }

    pub fn readFrame(r: *Reader, number: usize, out: []u8) (Error || Decompressor.Error)!usize {
        if (number >= r.index.entries.len) return error.FrameOutOfRange;
        const entry = r.index.entries[number];
        if (out.len < entry.decompressed_len) return error.OutputTooSmall;
        const start: usize = @intCast(entry.compressed_offset);
        var options = r.options;
        options.partial = false;
        options.frames = .all;
        options.format = .standard;
        const result = try r.decoder.decompress(r.index.input[start..][0..entry.compressed_len], out[0..entry.decompressed_len], options);
        if (result.out_len != entry.decompressed_len or result.in_len != entry.compressed_len) return error.InvalidSeekTable;
        if (options.verify_checksum) if (entry.checksum) |checksum| {
            if (checksum != @as(u32, @truncate(std.hash.XxHash64.hash(0, out[0..result.out_len])))) return error.ChecksumMismatch;
        };
        return result.out_len;
    }

    /// Copy a range, decoding only the frames it intersects.
    pub fn read(r: *Reader, offset: u64, out: []u8) (Error || Decompressor.Error)!usize {
        var pos = offset;
        var at: usize = 0;
        while (at < out.len) {
            const number = r.index.find(pos) orelse break;
            const entry = r.index.entries[number];
            const len = try r.readFrame(number, r.buffer);
            const skip: usize = @intCast(pos - entry.decompressed_offset);
            const n = @min(len - skip, out.len - at);
            @memcpy(out[at..][0..n], r.buffer[skip..][0..n]);
            pos += n;
            at += n;
        }
        return at;
    }
};

/// Streaming input into independent frames, with one bounded seek table.
/// The output writer and dictionary are borrowed; staging and entries are
/// allocated once or taken from caller storage.
pub const Writer = struct {
    interface: Io.Writer,
    output: *Io.Writer,
    compressor: Compressor,
    input: []u8,
    encoded: []u8,
    entries: []Record,
    have: usize = 0,
    count: usize = 0,
    checksum: bool,
    frame_checksum: bool,
    finished: bool = false,
    failure: ?WriteError = null,
    owned: []align(64) u8 = &.{},
    gpa: Allocator = undefined,

    pub const Options = struct {
        level: i32 = 3,
        tuning: Compressor.Tuning = .{},
        dictionary: ?*const Dictionary = null,
        frame_len: u32 = 1 << 20,
        max_frames: u32 = 65536,
        checksum: bool = true,
        frame_checksum: bool = true,
    };
    pub const WriteError = error{ TooManyFrames, Finished, OutputFailed };
    const Record = struct { compressed: u32, decompressed: u32, checksum: u32 };

    fn encoderOptions(options: Options) Compressor.Options {
        return .{ .level = options.level, .tuning = options.tuning, .dictionary = options.dictionary, .max_input = @max(1, options.frame_len) };
    }

    pub fn memory(options: Options) usize {
        const len: usize = @max(1, options.frame_len);
        return std.mem.alignForward(usize, Compressor.memory(encoderOptions(options)) + @as(usize, options.max_frames) * @sizeOf(Record) + len + Compressor.bound(len), 64);
    }

    pub fn init(gpa: Allocator, output: *Io.Writer, options: Options) (Allocator.Error || error{InvalidOptions})!Writer {
        if (options.frame_len == 0 or options.frame_len > 1 << 30 or options.max_frames > (std.math.maxInt(u32) - 9) / 12) return error.InvalidOptions;
        const buffer = try gpa.alignedAlloc(u8, .@"64", memory(options));
        var w = initBuffer(buffer, output, options);
        w.owned = buffer;
        w.gpa = gpa;
        return w;
    }

    pub fn initBuffer(buffer: []align(64) u8, output: *Io.Writer, options: Options) Writer {
        std.debug.assert(buffer.len >= memory(options));
        const size = Compressor.memory(encoderOptions(options));
        const records_size = @as(usize, options.max_frames) * @sizeOf(Record);
        const len: usize = @max(1, options.frame_len);
        return .{ .interface = .{ .vtable = &.{ .drain = writeData, .flush = flushInput }, .buffer = &.{}, .end = 0 }, .output = output, .compressor = .initBuffer(buffer[0..size], encoderOptions(options)), .entries = @alignCast(std.mem.bytesAsSlice(Record, buffer[size..][0..records_size])), .input = buffer[size + records_size ..][0..len], .encoded = buffer[size + records_size + len ..][0..Compressor.bound(len)], .checksum = options.checksum, .frame_checksum = options.frame_checksum }; // safe: Record has four-byte alignment and compressor storage is a multiple of 64
    }

    pub fn deinit(w: *Writer) void {
        if (w.owned.len != 0) w.gpa.free(w.owned);
        w.* = undefined;
    }

    pub fn err(w: *const Writer) ?WriteError {
        return w.failure;
    }

    fn emit(w: *Writer) Io.Writer.Error!void {
        if (w.failure != null) return error.WriteFailed;
        errdefer if (w.failure == null) {
            w.failure = error.OutputFailed;
        };
        if (w.count == w.entries.len) {
            w.failure = error.TooManyFrames;
            return error.WriteFailed;
        }
        const n = w.compressor.compress(w.input[0..w.have], w.encoded, .{ .checksum = w.frame_checksum }) catch unreachable; // unreachable: encoded has the codec's full bound
        try w.output.writeAll(w.encoded[0..n]);
        w.entries[w.count] = .{ .compressed = @intCast(n), .decompressed = @intCast(w.have), .checksum = @truncate(std.hash.XxHash64.hash(0, w.input[0..w.have])) };
        w.count += 1;
        w.have = 0;
    }

    fn writeSlice(w: *Writer, in: []const u8) Io.Writer.Error!void {
        if (w.finished or w.failure != null) {
            if (w.finished) w.failure = error.Finished;
            return error.WriteFailed;
        }
        var at: usize = 0;
        while (at < in.len) {
            if (w.have == w.input.len) try w.emit();
            const n = @min(in.len - at, w.input.len - w.have);
            @memcpy(w.input[w.have..][0..n], in[at..][0..n]);
            w.have += n;
            at += n;
        }
    }

    fn writeData(interface: *Io.Writer, data: []const []const u8, splat: usize) Io.Writer.Error!usize {
        const w: *Writer = @alignCast(@fieldParentPtr("interface", interface)); // safe: the embedded interface belongs to Writer
        var n: usize = 0;
        for (data[0 .. data.len - 1]) |part| {
            try w.writeSlice(part);
            n += part.len;
        }
        const tail = data[data.len - 1];
        for (0..splat) |_| try w.writeSlice(tail);
        return n + tail.len * splat;
    }

    fn flushInput(interface: *Io.Writer) Io.Writer.Error!void {
        const w: *Writer = @alignCast(@fieldParentPtr("interface", interface)); // safe: the embedded interface belongs to Writer
        if (w.have != 0) try w.emit();
    }

    /// End the final frame and write the seek table once.
    pub fn finish(w: *Writer) Io.Writer.Error!void {
        if (w.failure != null) return error.WriteFailed;
        if (w.finished) return;
        errdefer if (w.failure == null) {
            w.failure = error.OutputFailed;
        };
        if (w.have != 0 or w.count == 0) try w.emit();
        const stride: usize = if (w.checksum) 12 else 8;
        var header: [8]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], skippable_magic, .little);
        std.mem.writeInt(u32, header[4..8], @intCast(w.count * stride + 9), .little);
        try w.output.writeAll(&header);
        var bytes: [12]u8 = undefined;
        for (w.entries[0..w.count]) |entry| {
            std.mem.writeInt(u32, bytes[0..4], entry.compressed, .little);
            std.mem.writeInt(u32, bytes[4..8], entry.decompressed, .little);
            std.mem.writeInt(u32, bytes[8..12], entry.checksum, .little);
            try w.output.writeAll(bytes[0..stride]);
        }
        var end: [9]u8 = undefined;
        std.mem.writeInt(u32, end[0..4], @intCast(w.count), .little);
        end[4] = if (w.checksum) 0x80 else 0;
        std.mem.writeInt(u32, end[5..9], magic, .little);
        try w.output.writeAll(&end);
        w.finished = true;
    }
};
