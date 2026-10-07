//! The reader of zstd's backward bitstreams. A stream is written forward,
//! least significant bit first, and closed with a 1 bit; it is read from
//! that bit back toward its first byte, the last bits written first. The
//! entropy-coded literals, the sequences and the Huffman weights are all
//! read this way.
//!
//! Up to 64 bits sit in a register, the next ones at its top. Reading past
//! the stream's first byte is not stopped here: `consumed` runs past 64 and
//! `reload` says `overflow`, which every caller takes as a broken stream.
//! Bits read past the first byte are zeros (`peek`) or whatever the
//! register holds (`read`), exactly as the format's reference decoder reads
//! them, so a broken stream is refused at the same point.

const std = @import("std");

pub const Reader = struct {
    /// Eight bytes of the stream, little-endian: `stream[at..][0..8]`, or
    /// the whole stream when it is shorter.
    container: u64,
    /// Bits of `container` already read, counted from its top.
    consumed: u32,
    /// Where `container` was loaded from.
    at: usize,
    stream: []const u8,

    pub const Status = enum(u2) {
        /// At least 57 bits are in the register.
        unfinished,
        /// The register holds the stream's first byte; fewer may remain.
        end_of_buffer,
        /// Every bit has been read.
        completed,
        /// More bits were read than the stream has.
        overflow,
    };

    /// A reader at the end of `stream`. Fails on an empty stream or one
    /// whose last byte has no closing bit.
    pub fn init(stream: []const u8) error{InvalidStream}!Reader {
        if (stream.len == 0) return error.InvalidStream;
        const last = stream[stream.len - 1];
        if (last == 0) return error.InvalidStream;
        // The closing bit and the zeros above it.
        const pad: u32 = 1 + @as(u32, @clz(last));
        if (stream.len >= 8) {
            const at = stream.len - 8;
            return .{ .container = std.mem.readInt(u64, stream[at..][0..8], .little), .consumed = pad, .at = at, .stream = stream };
        }
        var container: u64 = 0;
        for (stream, 0..) |b, i| container |= @as(u64, b) << @intCast(8 * i);
        return .{ .container = container, .consumed = pad + @as(u32, @intCast(8 - stream.len)) * 8, .at = 0, .stream = stream };
    }

    /// The next `n` bits (1 to 63) without taking them; zeros past the
    /// stream's start.
    pub inline fn peek(r: *const Reader, n: u6) u64 {
        return (r.container << @intCast(r.consumed & 63)) >> @intCast(@as(u7, 64) - n);
    }

    /// Take `n` bits (`peek` has looked at them).
    pub inline fn skip(r: *Reader, n: u32) void {
        r.consumed += n;
    }

    /// Take the next `n` bits, 1 to 63.
    pub inline fn readFast(r: *Reader, n: u6) u64 {
        const v = r.peek(n);
        r.consumed += n;
        return v;
    }

    /// Take the next `n` bits, 0 to 63.
    pub inline fn read(r: *Reader, n: u6) u64 {
        const start: u32 = 64 -% r.consumed -% n;
        const v = (r.container >> @intCast(start & 63)) & ((@as(u64, 1) << n) - 1);
        r.consumed += n;
        return v;
    }

    /// Refill the register from the stream.
    pub inline fn reload(r: *Reader) Status {
        if (r.consumed > 64) return .overflow;
        if (r.at >= 8) {
            r.at -= r.consumed >> 3;
            r.consumed &= 7;
            r.container = std.mem.readInt(u64, r.stream[r.at..][0..8], .little);
            return .unfinished;
        }
        return r.reloadNearStart();
    }

    fn reloadNearStart(r: *Reader) Status {
        if (r.at == 0) return if (r.consumed < 64) .end_of_buffer else .completed;
        var n: usize = r.consumed >> 3;
        var status: Status = .unfinished;
        if (n > r.at) {
            n = r.at;
            status = .end_of_buffer;
        }
        r.at -= n;
        r.consumed -= @intCast(n * 8);
        r.container = std.mem.readInt(u64, r.stream[r.at..][0..8], .little);
        return status;
    }

    /// Every bit read, and no more.
    pub fn finished(r: *const Reader) bool {
        return r.at == 0 and r.consumed == 64;
    }
};

const testing = std.testing;

test "bits come back last written first, and the end is exact" {
    // Written forward: 0b101 (3 bits), 0b11 (2 bits), 0b0110 (4 bits),
    // then the closing 1: bits 0-9 of 0b1_0110_11_101.
    const value: u16 = 0b1_0110_11_101;
    const stream = [_]u8{ @truncate(value), @truncate(value >> 8) };
    var r: Reader = try .init(&stream);
    try testing.expectEqual(@as(u64, 0b0110), r.read(4));
    try testing.expectEqual(@as(u64, 0b11), r.read(2));
    try testing.expect(!r.finished());
    try testing.expectEqual(@as(u64, 0b101), r.readFast(3));
    try testing.expect(r.finished());
    try testing.expectEqual(Reader.Status.completed, r.reload());
    _ = r.read(1);
    try testing.expectEqual(Reader.Status.overflow, r.reload());
}

test "a long stream reloads across bytes and ends at its first bit" {
    var stream: [40]u8 = undefined;
    for (&stream, 0..) |*b, i| b.* = @truncate(i * 37 + 11);
    stream[39] = 0x01; // the closing bit alone in the last byte
    var r: Reader = try .init(&stream);
    // 39 bytes of payload, read 13 bits at a time, then the remainder.
    var total: u32 = 0;
    while (total + 13 <= 39 * 8) : (total += 13) {
        _ = r.read(13);
        try testing.expect(r.reload() != .overflow);
    }
    _ = r.read(@intCast(39 * 8 - total));
    try testing.expect(r.finished());
}

test "empty streams and streams with no closing bit are refused" {
    try testing.expectError(error.InvalidStream, Reader.init(&.{}));
    try testing.expectError(error.InvalidStream, Reader.init(&.{ 0xff, 0x00 }));
}
