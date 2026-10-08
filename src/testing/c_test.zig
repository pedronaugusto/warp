//! Stream ABI tests with caller allocation, short output and dictionary negotiation.
const std = @import("std");
const testing = std.testing;
const abi = @import("../c.zig");
const Decompressor = @import("../Decompressor.zig");
const shakedown = @import("shakedown");

const Callbacks = struct {
    gpa: std.mem.Allocator,
    bytes: usize = 0,
    allocations: usize = 0,
    frees: usize = 0,
    fn allocate(context: ?*anyopaque, items: c_uint, size: c_uint) callconv(.c) ?*anyopaque {
        const c: *Callbacks = @ptrCast(@alignCast(context.?));
        const n = @as(usize, items) * size;
        const memory = c.gpa.rawAlloc(n, .@"64", @returnAddress()) orelse return null;
        c.bytes = n;
        c.allocations += 1;
        return memory;
    }
    fn release(context: ?*anyopaque, pointer: ?*anyopaque) callconv(.c) void {
        const c: *Callbacks = @ptrCast(@alignCast(context.?));
        const memory: [*]u8 = @ptrCast(pointer.?);
        c.gpa.rawFree(memory[0..c.bytes], .@"64", @returnAddress());
        c.frees += 1;
    }
    fn stream(c: *Callbacks) abi.Stream {
        return .{ .zalloc = allocate, .zfree = release, .@"opaque" = c };
    }
};

test "C ABI streaming with one-byte output and one allocation per stream" {
    const in = "the repeated words the repeated words the repeated words";
    for ([_]c_int{ -15, 15, 31 }) |window_bits| {
        var callbacks: Callbacks = .{ .gpa = testing.allocator };
        var z = callbacks.stream();
        try testing.expectEqual(@as(c_int, 0), abi.deflateInit2(&z, 6, 8, window_bits, 8, 0, abi.zlibVersion(), @sizeOf(abi.Stream)));
        var output: [256]u8 = undefined;
        z.next_in = in;
        z.avail_in = in.len;
        var at: usize = 0;
        while (true) {
            z.next_out = output[at..].ptr;
            z.avail_out = 1;
            const status = abi.deflate(&z, 4);
            at += 1 - z.avail_out;
            if (status == 1) break;
            try testing.expectEqual(@as(c_int, 0), status);
        }
        try testing.expectEqual(@as(usize, 1), callbacks.allocations);
        try testing.expectEqual(@as(c_int, 0), abi.deflateEnd(&z));
        try testing.expectEqual(@as(usize, 1), callbacks.frees);
        var back: [in.len]u8 = undefined;
        var d: Decompressor = .init;
        _ = try d.inflate(output[0..at], &back, .{ .accept = if (window_bits < 0) .raw else if (window_bits == 31) .gzip else .zlib });
        try testing.expectEqualStrings(in, &back);
        var decoded_callbacks: Callbacks = .{ .gpa = testing.allocator };
        var dz = decoded_callbacks.stream();
        try testing.expectEqual(@as(c_int, 0), abi.inflateInit2(&dz, window_bits, abi.zlibVersion(), @sizeOf(abi.Stream)));
        defer _ = abi.inflateEnd(&dz);
        dz.next_in = &output;
        dz.avail_in = @intCast(at);
        var op: usize = 0;
        while (true) {
            dz.next_out = back[op..].ptr;
            dz.avail_out = @intFromBool(op < back.len);
            const status = abi.inflate(&dz, 0);
            op = @intCast(dz.total_out);
            if (status == 1) break;
            try testing.expectEqual(@as(c_int, 0), status);
        }
        try testing.expectEqualStrings(in, &back);
        try testing.expectEqual(@as(usize, 1), decoded_callbacks.allocations);
    }
}

test "C ABI dictionary negotiation, resets and convenience calls" {
    const dictionary = "dictionary words before the stream repeated";
    const in = "dictionary words before the stream repeated repeated";
    var z: abi.Stream = .{};
    try testing.expectEqual(@as(c_int, 0), abi.deflateInit(&z, 6, abi.zlibVersion(), @sizeOf(abi.Stream)));
    defer _ = abi.deflateEnd(&z);
    try testing.expectEqual(@as(c_int, 0), abi.deflateSetDictionary(&z, dictionary, dictionary.len));
    var output: [256]u8 = undefined;
    z.next_in = in;
    z.avail_in = in.len;
    z.next_out = &output;
    z.avail_out = output.len;
    try testing.expectEqual(@as(c_int, 1), abi.deflate(&z, 4));
    var dz: abi.Stream = .{};
    try testing.expectEqual(@as(c_int, 0), abi.inflateInit(&dz, abi.zlibVersion(), @sizeOf(abi.Stream)));
    defer _ = abi.inflateEnd(&dz);
    var back: [256]u8 = undefined;
    dz.next_in = &output;
    dz.avail_in = @intCast(z.total_out);
    dz.next_out = &back;
    dz.avail_out = back.len;
    try testing.expectEqual(@as(c_int, 2), abi.inflate(&dz, 0));
    try testing.expectEqual(abi.adler32(1, dictionary, dictionary.len), dz.adler);
    try testing.expectEqual(@as(c_int, -3), abi.inflateSetDictionary(&dz, "wrong", 5));
    try testing.expectEqual(@as(c_int, 0), abi.inflateSetDictionary(&dz, dictionary, dictionary.len));
    try testing.expectEqual(@as(c_int, 1), abi.inflate(&dz, 0));
    try testing.expectEqualStrings(in, back[0..dz.total_out]);
    try testing.expectEqual(@as(c_int, 0), abi.inflateReset(&dz));
    try testing.expectEqual(@as(c_int, 0), abi.deflateReset(&z));
    var n: c_ulong = output.len;
    try testing.expectEqual(@as(c_int, 0), abi.compress2(&output, &n, in, in.len, 9));
    var bn: c_ulong = back.len;
    try testing.expectEqual(@as(c_int, 0), abi.uncompress(&back, &bn, &output, n));
    try testing.expectEqualStrings(in, back[0..bn]);
    try testing.expectEqual(@as(c_int, -6), abi.inflateInit(&dz, "0", @sizeOf(abi.Stream)));
}

test "C ABI allocation failure leaves no stream state" {
    var no_resize: shakedown.alloc.NoResize = .init(testing.allocator);
    try testing.checkAllAllocationFailures(no_resize.allocator(), struct {
        fn once(gpa: std.mem.Allocator) !void {
            var callbacks: Callbacks = .{ .gpa = gpa };
            var z = callbacks.stream();
            if (abi.deflateInit(&z, 6, abi.zlibVersion(), @sizeOf(abi.Stream)) == -4) {
                try testing.expect(z.state == null);
                return error.OutOfMemory;
            }
            _ = abi.deflateEnd(&z);
        }
    }.once, .{});
}

test "C ABI accepts default gzip and automatic wrapper windows" {
    for ([_]c_int{ 16, 32 }) |bits| {
        var z: abi.Stream = .{};
        try testing.expectEqual(@as(c_int, 0), abi.inflateInit2(&z, bits, abi.zlibVersion(), @sizeOf(abi.Stream)));
        try testing.expectEqual(@as(c_int, 0), abi.inflateEnd(&z));
    }
    var z: abi.Stream = .{};
    try testing.expectEqual(@as(c_int, -2), abi.inflateInit2(&z, std.math.minInt(c_int), abi.zlibVersion(), @sizeOf(abi.Stream)));
    try testing.expectEqual(@as(c_int, -2), abi.deflateInit2(&z, 6, 8, std.math.minInt(c_int), 8, 0, abi.zlibVersion(), @sizeOf(abi.Stream)));
}

test "C ABI custom gzip headers are emitted and captured with one-byte output" {
    var z: abi.Stream = .{};
    try testing.expectEqual(@as(c_int, 0), abi.deflateInit2(&z, 6, 8, 31, 8, 0, abi.zlibVersion(), @sizeOf(abi.Stream)));
    defer _ = abi.deflateEnd(&z);
    var name = [_:0]u8{ 'f', 'o', 'x' };
    var extra = [_]u8{ 1, 2, 3 };
    var h: abi.Header = .{ .name = &name, .extra = &extra, .extra_len = extra.len, .hcrc = 1, .time = 1234, .text = 1, .os = 3 };
    try testing.expectEqual(@as(c_int, 0), abi.deflateSetHeader(&z, &h));
    var compressed: [256]u8 = undefined;
    var at: usize = 0;
    z.next_in = "hello hello hello";
    z.avail_in = 17;
    while (true) {
        z.next_out = compressed[at..].ptr;
        z.avail_out = 1;
        const rc = abi.deflate(&z, 4);
        at += 1 - z.avail_out;
        if (rc == 1) break;
        try testing.expectEqual(@as(c_int, 0), rc);
    }
    var d: abi.Stream = .{};
    try testing.expectEqual(@as(c_int, 0), abi.inflateInit2(&d, 47, abi.zlibVersion(), @sizeOf(abi.Stream)));
    defer _ = abi.inflateEnd(&d);
    var capture_name: [32]u8 = undefined;
    var capture_extra: [32]u8 = undefined;
    var capture: abi.Header = .{ .name = &capture_name, .name_max = capture_name.len, .extra = &capture_extra, .extra_max = capture_extra.len };
    try testing.expectEqual(@as(c_int, 0), abi.inflateGetHeader(&d, &capture));
    var decoded: [32]u8 = undefined;
    d.next_in = &compressed;
    d.avail_in = @intCast(at);
    d.next_out = &decoded;
    d.avail_out = decoded.len;
    try testing.expectEqual(@as(c_int, 1), abi.inflate(&d, 0));
    try testing.expectEqualStrings("hello hello hello", decoded[0..d.total_out]);
    try testing.expectEqual(@as(c_int, 1), capture.done);
    try testing.expectEqual(@as(c_ulong, 1234), capture.time);
    try testing.expectEqualStrings("fox", std.mem.sliceTo(&capture_name, 0));
    try testing.expectEqualSlices(u8, &extra, capture_extra[0..capture.extra_len]);
    try testing.expectEqual(@as(c_int, 0), abi.inflateReset2(&d, -12));
    try testing.expectEqual(@as(c_ulong, 0), d.total_out);
}

test "C ABI copies keep independent encoder and decoder state" {
    const in = "repeated repeated repeated repeated repeated repeated";
    var encoded: [256]u8 = undefined;
    var z: abi.Stream = .{};
    try testing.expectEqual(@as(c_int, 0), abi.deflateInit(&z, 6, abi.zlibVersion(), @sizeOf(abi.Stream)));
    defer _ = abi.deflateEnd(&z);
    z.next_in = in[0..17].ptr;
    z.avail_in = 17;
    z.next_out = &encoded;
    z.avail_out = encoded.len;
    try testing.expectEqual(@as(c_int, 0), abi.deflate(&z, 2));
    const prefix: usize = @intCast(z.total_out);
    var copy: abi.Stream = .{};
    try testing.expectEqual(@as(c_int, 0), abi.deflateCopy(&copy, &z));
    defer _ = abi.deflateEnd(&copy);
    var copied: [256]u8 = undefined;
    @memcpy(copied[0..prefix], encoded[0..prefix]);
    z.next_in = in[17..].ptr;
    z.avail_in = in.len - 17;
    copy.next_in = z.next_in;
    copy.avail_in = z.avail_in;
    copy.next_out = copied[prefix..].ptr;
    copy.avail_out = @intCast(copied.len - prefix);
    try testing.expectEqual(@as(c_int, 1), abi.deflate(&z, 4));
    try testing.expectEqual(@as(c_int, 1), abi.deflate(&copy, 4));
    try testing.expectEqualSlices(u8, encoded[0..z.total_out], copied[0..copy.total_out]);
    var d: abi.Stream = .{};
    try testing.expectEqual(@as(c_int, 0), abi.inflateInit(&d, abi.zlibVersion(), @sizeOf(abi.Stream)));
    defer _ = abi.inflateEnd(&d);
    var back: [128]u8 = undefined;
    d.next_in = &encoded;
    d.avail_in = @intCast(z.total_out);
    d.next_out = &back;
    d.avail_out = 13;
    try testing.expectEqual(@as(c_int, 0), abi.inflate(&d, 0));
    var dc: abi.Stream = .{};
    try testing.expectEqual(@as(c_int, 0), abi.inflateCopy(&dc, &d));
    defer _ = abi.inflateEnd(&dc);
    var cb: [128]u8 = undefined;
    const written: usize = @intCast(d.total_out);
    @memcpy(cb[0..written], back[0..written]);
    dc.next_out = cb[written..].ptr;
    dc.avail_out = @intCast(cb.len - written);
    d.avail_out = @intCast(back.len - written);
    try testing.expectEqual(@as(c_int, 1), abi.inflate(&d, 0));
    try testing.expectEqual(@as(c_int, 1), abi.inflate(&dc, 0));
    try testing.expectEqualStrings(in, back[0..d.total_out]);
    try testing.expectEqualSlices(u8, back[0..d.total_out], cb[0..dc.total_out]);
}

test "C ABI convenience calls report progress on short buffers" {
    const input = "repeated repeated repeated repeated repeated repeated";
    var encoded: [256]u8 = undefined;
    var length: c_ulong = encoded.len;
    try testing.expectEqual(@as(c_int, 0), abi.compress2(&encoded, &length, input, input.len, 6));
    var decoded: [7]u8 = undefined;
    var capacity: c_ulong = decoded.len;
    var consumed: c_ulong = length;
    try testing.expectEqual(@as(c_int, -5), abi.uncompress2(&decoded, &capacity, &encoded, &consumed));
    try testing.expectEqual(@as(c_ulong, decoded.len), capacity);
    try testing.expect(consumed < length);
    try testing.expectEqualStrings(input[0..decoded.len], &decoded);
    capacity = 1;
    try testing.expectEqual(@as(c_int, -5), abi.compress2(&encoded, &capacity, input, input.len, 6));
    try testing.expectEqual(@as(c_ulong, 1), capacity);
}

test "C ABI promotes zlib's eight-bit encode window and rejects it for other wrappers" {
    var z: abi.Stream = .{};
    try testing.expectEqual(@as(c_int, -2), abi.deflateInit2(&z, 6, 8, -8, 8, 0, abi.zlibVersion(), @sizeOf(abi.Stream)));
    try testing.expectEqual(@as(c_int, -2), abi.deflateInit2(&z, 6, 8, 24, 8, 0, abi.zlibVersion(), @sizeOf(abi.Stream)));
    try testing.expectEqual(@as(c_int, 0), abi.deflateInit2(&z, 6, 8, 8, 8, 0, abi.zlibVersion(), @sizeOf(abi.Stream)));
    defer _ = abi.deflateEnd(&z);
    var encoded: [128]u8 = undefined;
    z.next_out = &encoded;
    z.avail_out = encoded.len;
    try testing.expectEqual(@as(c_int, 1), abi.deflate(&z, 4));
    try testing.expectEqual(@as(u8, 1), encoded[0] >> 4);
}

test "C ABI tree flush stops after wrapper and block headers" {
    var encoded: [128]u8 = undefined;
    var length: c_ulong = encoded.len;
    try testing.expectEqual(@as(c_int, 0), abi.compress2(&encoded, &length, "abc", 3, 0));
    var d: abi.Stream = .{};
    try testing.expectEqual(@as(c_int, 0), abi.inflateInit(&d, abi.zlibVersion(), @sizeOf(abi.Stream)));
    defer _ = abi.inflateEnd(&d);
    var out: [16]u8 = undefined;
    d.next_in = &encoded;
    d.avail_in = @intCast(length);
    d.next_out = &out;
    d.avail_out = out.len;
    try testing.expectEqual(@as(c_int, 0), abi.inflate(&d, 6));
    try testing.expectEqual(@as(c_ulong, 0), d.total_out);
    try testing.expect(d.data_type & 128 != 0);
    try testing.expectEqual(@as(c_int, 0), abi.inflate(&d, 6));
    try testing.expectEqual(@as(c_ulong, 0), d.total_out);
    try testing.expect(d.data_type & 256 != 0);
    try testing.expectEqual(@as(c_int, 1), abi.inflate(&d, 4));
    try testing.expectEqualStrings("abc", out[0..d.total_out]);
}

test "C ABI compression bounds include custom gzip headers" {
    var z: abi.Stream = .{};
    try testing.expectEqual(@as(c_int, 0), abi.deflateInit2(&z, 6, 8, 31, 8, 0, abi.zlibVersion(), @sizeOf(abi.Stream)));
    defer _ = abi.deflateEnd(&z);
    var name: [300:0]u8 = @splat('a');
    var header: abi.Header = .{ .name = &name };
    try testing.expectEqual(@as(c_int, 0), abi.deflateSetHeader(&z, &header));
    try testing.expect(abi.deflateBound(&z, 0) >= 10 + name.len + 1 + 8 + 2);
}
