//! The codecs' memory contract: a decoder given any bytes reads nothing outside its input and
//! writes nothing outside its output, and what each encoder writes its decoder gives back. Each
//! buffer lies against a page mapped with no access, after its last byte and then before its
//! first, so a read or a write past either end faults in every build; the input is held where
//! nothing may write it. The unchecked primitives under the decoders (glint.json's seams) keep
//! their slack inside the buffers they are given: a slack one short makes these properties fail
//! (the mutation checks).
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const shakedown = @import("shakedown");
const gen = @import("gen");
const warp = @import("../warp.zig");

/// `len` bytes against a page no access is allowed to: after them, or before them.
const Guarded = struct {
    mapping: []align(std.heap.page_size_min) u8,
    bytes: []u8,

    const Side = enum { after, before };

    fn init(len: usize, side: Side) !Guarded {
        const page = std.heap.pageSize();
        const room = std.mem.alignForward(usize, @max(len, 1), page);
        const mapping = try std.posix.mmap(null, room + page, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
        errdefer std.posix.munmap(mapping);
        switch (side) {
            .after => {
                try std.process.protectMemory(@alignCast(mapping[room..]), .{});
                return .{ .mapping = mapping, .bytes = mapping[room - len .. room] };
            },
            .before => {
                try std.process.protectMemory(@alignCast(mapping[0..page]), .{});
                return .{ .mapping = mapping, .bytes = mapping[page..][0..len] };
            },
        }
    }

    /// `data` in a guarded buffer of its own length, readable only.
    fn holding(data: []const u8, side: Side) !Guarded {
        const g = try init(data.len, side);
        @memcpy(g.bytes, data);
        const page = std.heap.pageSize();
        const first = std.mem.alignBackward(usize, @intFromPtr(g.bytes.ptr), page) - @intFromPtr(g.mapping.ptr);
        const last = std.mem.alignForward(usize, @intFromPtr(g.bytes.ptr) + g.bytes.len, page) - @intFromPtr(g.mapping.ptr);
        if (last > first) try std.process.protectMemory(@alignCast(g.mapping[first..last]), .{ .read = true });
        return g;
    }

    fn deinit(g: Guarded) void {
        std.posix.munmap(g.mapping);
    }
};

/// A codec as the contract sees it: its encoder, and its one-shot decoder into an output of a
/// given length, whose answer is how many bytes it wrote, or a refusal.
const Codec = struct {
    name: []const u8,
    encode: ?*const fn (gpa: std.mem.Allocator, in: []const u8) anyerror![]u8,
    decode: *const fn (gpa: std.mem.Allocator, in: []const u8, out: []u8) anyerror!usize,
    /// Streams made by hand, where the encoder seldom writes what the decoder's fast path takes
    /// at its edge: each decodes.
    craft: ?*const fn (gpa: std.mem.Allocator, s: *shakedown.Source) anyerror![]u8 = null,
};

fn flateEncode(comptime kind: warp.Container) fn (std.mem.Allocator, []const u8) anyerror![]u8 {
    return struct {
        fn f(gpa: std.mem.Allocator, in: []const u8) anyerror![]u8 {
            var c = try warp.Compressor.init(gpa, .{ .level = 6, .max_input = .fromRaw(in.len) });
            defer c.deinit();
            const out = try gpa.alloc(u8, warp.Compressor.bound(in.len, .{ .container = kind }));
            return out[0..try c.compress(in, out, .{ .container = kind })];
        }
    }.f;
}

fn flateDecode(comptime accept: warp.Accept) fn (std.mem.Allocator, []const u8, []u8) anyerror!usize {
    return struct {
        fn f(_: std.mem.Allocator, in: []const u8, out: []u8) anyerror!usize {
            var d: warp.Decompressor = .init;
            return (try d.inflate(in, out, .{ .accept = accept })).out_len;
        }
    }.f;
}

fn zstdEncode(gpa: std.mem.Allocator, in: []const u8) anyerror![]u8 {
    var c = try warp.zstd.Compressor.init(gpa, .{});
    defer c.deinit();
    const out = try gpa.alloc(u8, warp.zstd.Compressor.bound(in.len));
    return out[0..try c.compress(in, out, .{})];
}

fn zstdDecode(_: std.mem.Allocator, in: []const u8, out: []u8) anyerror!usize {
    var d: warp.zstd.Decompressor = .init;
    return (try d.decompress(in, out, .{})).out_len;
}

fn brotliEncode(gpa: std.mem.Allocator, in: []const u8) anyerror![]u8 {
    var c = warp.brotli.Compressor.init(gpa, .{});
    defer c.deinit();
    const out = try gpa.alloc(u8, warp.brotli.Compressor.bound(in.len));
    return out[0..try c.compress(in, out)];
}

fn brotliDecode(_: std.mem.Allocator, in: []const u8, out: []u8) anyerror!usize {
    var d: warp.brotli.Decompressor = .init;
    return (try d.decompress(in, out, .{})).out_len;
}

fn lz4Encode(gpa: std.mem.Allocator, in: []const u8) anyerror![]u8 {
    var c = try warp.lz4.Compressor.init(gpa, .{});
    defer c.deinit();
    const out = try gpa.alloc(u8, warp.lz4.blockBound(in.len));
    return out[0..try c.compressBlock(in, out, .{})];
}

fn lz4Decode(_: std.mem.Allocator, in: []const u8, out: []u8) anyerror!usize {
    return (try warp.lz4.decompressBlock(in, out, .{})).out_len;
}

/// An LZ4 block of the sequences the fast loop takes whole (up to 14 literals, a match of 4 to
/// 18 from up to 64 back, short periods among them), then its last literals.
fn lz4Craft(gpa: std.mem.Allocator, s: *shakedown.Source) anyerror![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var made: usize = 0;
    for (0..shakedown.gen.intRange(s, usize, 1, 24)) |i| {
        const lit = if (i == 0) shakedown.gen.intRange(s, usize, 8, 14) else shakedown.gen.intRange(s, usize, 0, 14);
        const len = shakedown.gen.intRange(s, usize, 4, 18);
        try out.append(gpa, @intCast((lit << 4) | (len - 4)));
        for (0..lit) |_| try out.append(gpa, shakedown.gen.int(s, u8));
        made += lit;
        const offset = shakedown.gen.intRange(s, usize, 1, @min(made, 64));
        try out.appendSlice(gpa, &std.mem.toBytes(std.mem.nativeToLittle(u16, @intCast(offset))));
        made += len;
    }
    const last = shakedown.gen.intRange(s, usize, 5, 14);
    try out.append(gpa, @intCast(last << 4));
    for (0..last) |_| try out.append(gpa, shakedown.gen.int(s, u8));
    return out.items;
}

fn snappyEncode(gpa: std.mem.Allocator, in: []const u8) anyerror![]u8 {
    var c = try warp.snappy.Compressor.init(gpa, .{});
    defer c.deinit();
    const out = try gpa.alloc(u8, warp.snappy.Compressor.bound(in.len));
    return out[0..try c.compressBlock(in, out)];
}

fn snappyDecode(_: std.mem.Allocator, in: []const u8, out: []u8) anyerror!usize {
    return try warp.snappy.decompressBlock(in, out, .{});
}

fn xzEncode(gpa: std.mem.Allocator, in: []const u8) anyerror![]u8 {
    var c = try warp.xz.Compressor.init(gpa, .{});
    defer c.deinit();
    const out = try gpa.alloc(u8, warp.xz.Compressor.bound(.{}, in.len));
    return out[0..try c.compress(in, out)];
}

fn xzDecode(_: std.mem.Allocator, in: []const u8, out: []u8) anyerror!usize {
    var d: warp.xz.Decompressor = .init;
    return (try d.decompress(in, out, .{})).out_len;
}

fn bzip2Decode(gpa: std.mem.Allocator, in: []const u8, out: []u8) anyerror!usize {
    var d = try warp.bzip2.Decompressor.init(gpa);
    defer d.deinit();
    return (try d.decompress(in, out, .{})).out_len;
}

fn gdeflateEncode(gpa: std.mem.Allocator, in: []const u8) anyerror![]u8 {
    var c = try warp.gdeflate.Compressor.init(gpa, .{});
    defer c.deinit();
    const out = try gpa.alloc(u8, warp.gdeflate.bound(in.len));
    return out[0..try c.compress(in, out)];
}

fn gdeflateDecode(_: std.mem.Allocator, in: []const u8, out: []u8) anyerror!usize {
    var d: warp.gdeflate.Decompressor = .init;
    return try d.decompress(in, out, .{});
}

fn deflate64Decode(_: std.mem.Allocator, in: []const u8, out: []u8) anyerror!usize {
    var d: warp.deflate64.Decompressor = .init;
    return (try d.inflate(in, out, .{})).out_len;
}

const codecs = [_]Codec{
    .{ .name = "deflate", .encode = flateEncode(.raw), .decode = flateDecode(.raw) },
    .{ .name = "zlib", .encode = flateEncode(.zlib), .decode = flateDecode(.zlib) },
    .{ .name = "gzip", .encode = flateEncode(.gzip), .decode = flateDecode(.gzip) },
    .{ .name = "zstd", .encode = zstdEncode, .decode = zstdDecode },
    .{ .name = "brotli", .encode = brotliEncode, .decode = brotliDecode },
    .{ .name = "lz4", .encode = lz4Encode, .decode = lz4Decode, .craft = lz4Craft },
    .{ .name = "snappy", .encode = snappyEncode, .decode = snappyDecode },
    .{ .name = "xz", .encode = xzEncode, .decode = xzDecode },
    .{ .name = "gdeflate", .encode = gdeflateEncode, .decode = gdeflateDecode },
    // Decoders only: bzip2 has no encoder here; deflate64's streams are deflate's and more.
    .{ .name = "bzip2", .encode = null, .decode = bzip2Decode },
    .{ .name = "deflate64", .encode = null, .decode = deflate64Decode },
};

/// The output lengths a round trip tries past the input's: past every fast path's slack (32
/// bytes; inflate's is longer, but its last copies end within the same 32).
const spare = 40;

/// An input whose last match ends near the output's end with the longest overshoot a wild copy
/// has: random bytes, a match back into them of a length one past a multiple of 32 (a 32-byte
/// copy's last vector carries 31 bytes past it), then a short random tail. The round trip's
/// sweep of output lengths puts that match each distance from the end, the slack's included.
fn edge(gpa: std.mem.Allocator, s: *shakedown.Source) ![]u8 {
    const head_len = shakedown.gen.intRange(s, usize, 300, 900);
    // One match, or two back to back: the second takes no literals, so its literal copy starts
    // where the first's literals end.
    const matches = shakedown.gen.intRange(s, usize, 1, 2);
    var lens: [2]usize = undefined;
    // Up to DEFLATE's longest, 258.
    for (lens[0..matches]) |*l| l.* = @min(258, 32 * shakedown.gen.intRange(s, usize, 0, 8) + shakedown.gen.intRange(s, usize, 4, 32));
    const tail_len = shakedown.gen.intRange(s, usize, 0, spare);
    var total = head_len + tail_len;
    for (lens[0..matches]) |l| total += l;
    const out = try gpa.alloc(u8, total);
    for (out[0..head_len]) |*b| b.* = shakedown.gen.int(s, u8);
    var at = head_len;
    for (lens[0..matches]) |l| {
        const from = shakedown.gen.intRange(s, usize, 0, head_len - @min(head_len, l));
        for (out[at..][0..l], 0..) |*b, i| b.* = out[from + i];
        at += l;
    }
    for (out[at..]) |*b| b.* = shakedown.gen.int(s, u8);
    return out;
}

/// One case for `codec`: an input made of a kind gen knows or of `edge`'s shape, encoded (or a
/// stream made by hand) and decoded back between guarded buffers (`sweep`); then the encoding changed (bits flipped, cut, or bytes of no stream) and
/// decoded into a guarded output of any length, its input and output guarded on either side.
fn contract(codec: *const Codec, case: *shakedown.Case) anyerror!void {
    const s = case.source;
    const gpa = case.gpa;
    var plain: []const u8 = &.{};
    var stream: []u8 = undefined;
    if (codec.craft != null and shakedown.gen.boolean(s)) {
        // A stream made by hand, and what it decodes to.
        stream = try codec.craft.?(gpa, s);
        const whole = try gpa.alloc(u8, 1 << 16);
        plain = whole[0..try codec.decode(gpa, stream, whole)];
        try sweep(codec, gpa, stream, plain);
    } else if (codec.encode) |encode| {
        plain = if (shakedown.gen.boolean(s)) try gen.alloc(gpa, shakedown.gen.enumValue(s, gen.Kind), shakedown.gen.int(s, u16), shakedown.gen.intRange(s, usize, 0, 20_000)) else try edge(gpa, s);
        stream = try encode(gpa, plain);
        try sweep(codec, gpa, stream, plain);
    } else {
        stream = try shakedown.gen.string(s, gpa, .{ .kind = .bytes, .max_len = 4096, .average = 256 });
    }
    stream = try gpa.dupe(u8, stream);
    for (0..shakedown.gen.intRange(s, usize, 0, 4)) |_| {
        if (stream.len == 0) break;
        stream[shakedown.gen.intRange(s, usize, 0, stream.len - 1)] ^= @as(u8, 1) << shakedown.gen.intRange(s, u3, 0, 7);
    }
    if (shakedown.gen.boolean(s)) stream = stream[0..shakedown.gen.intRange(s, usize, 0, stream.len)];
    // Any bytes, into an output of any length: an answer or a refusal, never a fault.
    const room = shakedown.gen.intRange(s, usize, 0, plain.len + 64);
    case.note("{s}: {d} bytes into {d}", .{ codec.name, stream.len, room });
    for ([_]Guarded.Side{ .after, .before }) |side| {
        const in = try Guarded.holding(stream, side);
        defer in.deinit();
        const out = try Guarded.init(room, side);
        defer out.deinit();
        if (codec.decode(gpa, in.bytes, out.bytes)) |n| try testing.expect(n <= room) else |_| {}
    }
}

/// `stream` decodes to `plain` between guarded buffers: into the plain's length and each length
/// up to `spare` past it, the page after the output's end unmapped (a fast path keeps its slack
/// from that end, so each length puts the last copies another byte from it, one short of the
/// slack included); into a roomy output; and against the page before each buffer.
fn sweep(codec: *const Codec, gpa: std.mem.Allocator, stream: []const u8, plain: []const u8) !void {
    for (0..spare + 1) |extra| {
        const in = try Guarded.holding(stream, .after);
        defer in.deinit();
        const out = try Guarded.init(plain.len + extra, .after);
        defer out.deinit();
        const n = try codec.decode(gpa, in.bytes, out.bytes);
        try testing.expectEqual(plain.len, n);
        try testing.expectEqualSlices(u8, plain, out.bytes[0..n]);
    }
    {
        // Past a block and its margins: a decoder may then keep its literals at the output's
        // end (zstd does), against the guard page after it.
        const in = try Guarded.holding(stream, .after);
        defer in.deinit();
        const out = try Guarded.init(plain.len + (1 << 17) + 4 * spare, .after);
        defer out.deinit();
        const n = try codec.decode(gpa, in.bytes, out.bytes);
        try testing.expectEqualSlices(u8, plain, out.bytes[0..n]);
    }
    const in = try Guarded.holding(stream, .before);
    defer in.deinit();
    const out = try Guarded.init(plain.len, .before);
    defer out.deinit();
    try testing.expectEqual(plain.len, try codec.decode(gpa, in.bytes, out.bytes));
}

test "every codec decodes any bytes inside its buffers, and gives back what its encoder wrote" {
    if (builtin.os.tag == .windows or builtin.os.tag == .wasi) return error.SkipZigTest;
    inline for (&codecs) |*codec| {
        try shakedown.check(testing.allocator, codec, contract, .{ .cases = 100, .seed = 0xc0de_c0de });
    }
}
