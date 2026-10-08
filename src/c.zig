//! The zlib stream ABI. A stream owns one allocation through the caller's
//! callbacks; all subsequent encode and decode calls use that memory.
const std = @import("std");
const Deflate = @import("stream/Deflate.zig");
const Inflate = @import("stream/Inflate.zig");
const Compressor = @import("Compressor.zig");
const Decompressor = @import("Decompressor.zig");
const checksum = @import("checksum.zig");
const container = @import("container.zig");
const Diagnostic = @import("Diagnostic.zig");
const gzip = @import("gzip.zig");

pub const Stream = extern struct {
    next_in: [*c]const u8 = null,
    avail_in: c_uint = 0,
    total_in: c_ulong = 0,
    next_out: [*c]u8 = null,
    avail_out: c_uint = 0,
    total_out: c_ulong = 0,
    msg: [*c]const u8 = null,
    state: ?*anyopaque = null,
    zalloc: ?*const fn (?*anyopaque, c_uint, c_uint) callconv(.c) ?*anyopaque = null,
    zfree: ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void = null,
    @"opaque": ?*anyopaque = null,
    data_type: c_int = 2,
    adler: c_ulong = 1,
    reserved: c_ulong = 0,
};

const ok = 0;
const stream_end = 1;
const need_dict = 2;
const stream_error = -2;
const data_error = -3;
const mem_error = -4;
const buf_error = -5;
const version_error = -6;
const signature: u64 = 0x574152505354524d;

const State = struct {
    magic: u64 = signature,
    original: [*]u8,
    allocation_len: usize,
    free: ?*const fn (?*anyopaque, ?*anyopaque) callconv(.c) void,
    @"opaque": ?*anyopaque,
    direction: enum { encode, decode },
    encoder: Deflate = undefined,
    decoder: Inflate = undefined,
    window: [32768]u8 = undefined,
    dictionary: [32768]u8 = undefined,
    diagnostic: Diagnostic = .{},
    header: [6]u8 = undefined,
    header_len: usize = 0,
    header_ready: bool = false,
    dictionary_id: ?u32 = null,
    accept: container.Accept = .zlib,
    engine_bytes: usize = 0,
    gzip_header: ?*Header = null,
    header_at: usize = 0,
    header_check: u32 = 0,
    header_length: usize = 0,
    name_length: usize = 0,
    comment_length: usize = 0,
    gzip_fields: gzip.Fields = .{},
};

fn state(z: *Stream, direction: @TypeOf(@as(State, undefined).direction)) ?*State {
    const pointer = z.state orelse return null;
    const s: *State = @ptrCast(@alignCast(pointer)); // safe: only initialization assigns a state pointer
    if (s.magic != signature or s.direction != direction) return null;
    return s;
}

fn create(z: *Stream, bytes: usize) ?*State {
    if ((z.zalloc == null) != (z.zfree == null)) return null;
    const n = std.mem.alignForward(usize, @sizeOf(State), 64) + bytes + 63;
    if (n > std.math.maxInt(c_uint)) return null;
    const original: [*]u8 = if (z.zalloc) |allocate|
        @ptrCast(allocate(z.@"opaque", 1, @intCast(n)) orelse return null) // safe: allocation callbacks return at least n writable bytes
    else
        std.heap.page_allocator.rawAlloc(n, .@"64", @returnAddress()) orelse return null;
    const address = std.mem.alignForward(usize, @intFromPtr(original), 64); // safe: 63 padding bytes permit aligning within this allocation
    const s: *State = @ptrFromInt(address);
    s.* = .{ .original = original, .allocation_len = n, .free = z.zfree, .@"opaque" = z.@"opaque", .direction = .encode };
    z.state = s;
    z.total_in = 0;
    z.total_out = 0;
    z.msg = null;
    z.data_type = 2;
    z.adler = 1;
    return s;
}

fn destroy(z: *Stream, s: *State) void {
    const original = s.original;
    const n = s.allocation_len;
    const release = s.free;
    const userdata = s.@"opaque";
    s.magic = 0;
    z.state = null;
    if (release) |free| free(userdata, original) else std.heap.page_allocator.rawFree(original[0..n], .@"64", @returnAddress());
}

fn compatible(version: [*c]const u8, size: c_int) bool {
    return version != null and version[0] == '1' and size == @sizeOf(Stream);
}

fn strategy(value: c_int) ?Deflate.Strategy {
    return switch (value) {
        0 => .default,
        1 => .filtered,
        2 => .huffman_only,
        3 => .rle,
        4 => .fixed,
        else => null,
    };
}

fn level(value: c_int) ?u4 {
    if (value == -1) return 6;
    if (value < 0 or value > 9) return null;
    return @intCast(value);
}

fn advance(z: *Stream, in_len: usize, out_len: usize) void {
    if (in_len != 0) z.next_in += in_len;
    if (out_len != 0) z.next_out += out_len;
    z.avail_in -= @intCast(in_len);
    z.avail_out -= @intCast(out_len);
    z.total_in +%= @intCast(in_len);
    z.total_out +%= @intCast(out_len);
}

pub export fn zlibVersion() [*:0]const u8 {
    return "1.3.1";
}

pub fn deflateInit(z: ?*Stream, value: c_int, version: [*c]const u8, size: c_int) callconv(.c) c_int {
    return deflateInit2(z, value, 8, 15, 8, 0, version, size);
}

pub fn deflateInit2(stream: ?*Stream, value: c_int, method: c_int, window_bits: c_int, mem_level: c_int, strategy_value: c_int, version: [*c]const u8, size: c_int) callconv(.c) c_int {
    const z = stream orelse return stream_error;
    if (!compatible(version, size)) return version_error;
    const lv = level(value) orelse return stream_error;
    const st = strategy(strategy_value) orelse return stream_error;
    if (window_bits < -15 or window_bits > 31) return stream_error;
    const kind: container.Container = if (window_bits < 0) .raw else if (window_bits > 15) .gzip else .zlib;
    const bits = if (window_bits < 0) -window_bits else if (kind == .gzip) window_bits - 16 else window_bits;
    if (method != 8 or bits < 8 or bits > 15 or mem_level < 1 or mem_level > 9) return stream_error;
    const options: Deflate.Options = .{ .level = lv, .strategy = st, .container = kind, .window_bits = @intCast(bits), .hash_bits = @intCast(mem_level + 7) };
    const n = Deflate.memory(options);
    const s = create(z, n) orelse return mem_error;
    const buffer: [*]align(64) u8 = @ptrFromInt(@intFromPtr(s) + std.mem.alignForward(usize, @sizeOf(State), 64)); // safe: create reserved the aligned engine region after State
    s.encoder = .initBuffer(buffer[0..n], options);
    s.engine_bytes = n;
    z.adler = if (kind == .gzip) 0 else 1;
    return ok;
}

pub export fn deflate(stream: ?*Stream, flush: c_int) c_int {
    const z = stream orelse return stream_error;
    const s = state(z, .encode) orelse return stream_error;
    if (flush < 0 or flush > 5 or z.next_out == null or (z.avail_in != 0 and z.next_in == null)) return stream_error;
    if (z.avail_out == 0) return buf_error;
    if (s.encoder.finished) return if (flush == 4) stream_end else stream_error;
    const before_in = z.total_in;
    const before_out = z.total_out;
    if (s.gzip_header) |header| {
        const n = emitHeader(s, header, z.next_out[0..z.avail_out]);
        advance(z, 0, n);
        if (s.header_at < s.header_length or z.avail_out == 0) return ok;
    }
    if (s.encoder.closing == null) {
        const step = s.encoder.write(if (z.avail_in == 0) &.{} else z.next_in[0..z.avail_in], z.next_out[0..z.avail_out]);
        advance(z, step.in_len, step.out_len);
    }
    if (z.avail_in == 0 and flush != 0 and z.avail_out != 0) {
        const drained = if (flush == 4) s.encoder.finish(z.next_out[0..z.avail_out]) else s.encoder.flush(switch (flush) {
            1 => .partial,
            2 => .sync,
            3 => .full,
            else => .block,
        }, z.next_out[0..z.avail_out]);
        advance(z, 0, drained.out_len);
        z.adler = s.encoder.check;
        if (flush == 4 and drained.done) return stream_end;
    }
    z.adler = s.encoder.check;
    return if (z.total_in == before_in and z.total_out == before_out) buf_error else ok;
}

pub export fn deflateEnd(stream: ?*Stream) c_int {
    const z = stream orelse return stream_error;
    const s = state(z, .encode) orelse return stream_error;
    const incomplete = !s.encoder.finished and z.total_in != 0;
    s.encoder.deinit();
    destroy(z, s);
    return if (incomplete) data_error else ok;
}

pub export fn deflateReset(stream: ?*Stream) c_int {
    const z = stream orelse return stream_error;
    const s = state(z, .encode) orelse return stream_error;
    s.encoder.options.dictionary = &.{};
    s.encoder.reset(.nothing);
    if (s.gzip_header != null) {
        s.encoder.pending_start = 0;
        s.encoder.pending_end = 0;
        s.header_at = 0;
        s.header_check = 0;
    }
    z.total_in = 0;
    z.total_out = 0;
    z.adler = s.encoder.check;
    return ok;
}

pub export fn deflateParams(stream: ?*Stream, value: c_int, strategy_value: c_int) c_int {
    const z = stream orelse return stream_error;
    const s = state(z, .encode) orelse return stream_error;
    const lv = level(value) orelse return stream_error;
    const st = strategy(strategy_value) orelse return stream_error;
    if (s.encoder.finished or z.next_out == null) return stream_error;
    const drained = s.encoder.setLevel(lv, st, z.next_out[0..z.avail_out]);
    advance(z, 0, drained.out_len);
    if (!drained.done) return buf_error;
    s.encoder.options.level = lv;
    s.encoder.options.strategy = st;
    return ok;
}

pub export fn deflateSetDictionary(stream: ?*Stream, dictionary: [*c]const u8, len: c_uint) c_int {
    const z = stream orelse return stream_error;
    const s = state(z, .encode) orelse return stream_error;
    if ((dictionary == null and len != 0) or z.total_in != 0 or z.total_out != 0 or s.encoder.options.container == .gzip) return stream_error;
    const bytes = if (len == 0) &.{} else dictionary[0..len];
    const n = @min(bytes.len, s.dictionary.len);
    @memcpy(s.dictionary[0..n], bytes[bytes.len - n ..]);
    s.encoder.options.dictionary = s.dictionary[0..n];
    s.encoder.reset(.nothing);
    const id = checksum.adler32(1, bytes);
    if (n != 0 and s.encoder.options.container == .zlib) std.mem.writeInt(u32, s.encoder.pending[2..6], id, .big);
    z.adler = id;
    return ok;
}

pub export fn deflateBound(stream: ?*Stream, len: c_ulong) c_ulong {
    const z = stream orelse return @intCast(Compressor.bound(len, .{}));
    const s = state(z, .encode) orelse return @intCast(Compressor.bound(len, .{}));
    return @intCast(Compressor.bound(len, .{ .container = s.encoder.options.container, .dictionary = s.encoder.options.dictionary, .gzip = s.encoder.options.gzip }));
}

pub fn inflateInit(z: ?*Stream, version: [*c]const u8, size: c_int) callconv(.c) c_int {
    return inflateInit2(z, 15, version, size);
}

pub fn inflateInit2(stream: ?*Stream, window_bits: c_int, version: [*c]const u8, size: c_int) callconv(.c) c_int {
    const z = stream orelse return stream_error;
    if (!compatible(version, size)) return version_error;
    if (window_bits < -15 or window_bits > 47) return stream_error;
    const accept: container.Accept = if (window_bits < 0) .raw else if (window_bits >= 32) .gzip_or_zlib else if (window_bits >= 16) .gzip else .zlib;
    const n = if (window_bits >= 0 and window_bits & 15 == 0) 15 else if (window_bits < 0) -window_bits else window_bits & 15;
    if (n < 8 or n > 15 or window_bits > 47) return stream_error;
    const s = create(z, 0) orelse return mem_error;
    s.direction = .decode;
    s.accept = accept;
    s.header_ready = accept == .raw or accept == .gzip;
    s.decoder = .init(&s.window, .{ .accept = accept, .window_bits = @intCast(n), .members = .one, .diagnostic = &s.diagnostic });
    z.adler = if (accept == .gzip) 0 else 1;
    return ok;
}

fn decodeHeader(z: *Stream, s: *State) c_int {
    if (s.dictionary_id != null) return need_dict;
    while (s.header_len < 2 and z.avail_in != 0) {
        s.header[s.header_len] = z.next_in[0];
        s.header_len += 1;
        advance(z, 1, 0);
    }
    if (s.header_len < 2) return ok;
    if (s.accept == .gzip_or_zlib and s.header[0] == 31 and s.header[1] == 139) {
        _ = s.decoder.decode(s.header[0..2], &.{}) catch return data_error;
        s.header_ready = true;
        return ok;
    }
    const cmf = s.header[0];
    const flg = s.header[1];
    if (cmf & 15 != 8 or cmf >> 4 > 7 or (cmf >> 4) + 8 > s.decoder.options.window_bits or (@as(u16, cmf) * 256 + flg) % 31 != 0) return data_error;
    if (flg & 32 != 0) {
        while (s.header_len < 6 and z.avail_in != 0) {
            s.header[s.header_len] = z.next_in[0];
            s.header_len += 1;
            advance(z, 1, 0);
        }
        if (s.header_len < 6) return ok;
        s.dictionary_id = std.mem.readInt(u32, s.header[2..6], .big);
        z.adler = s.dictionary_id.?;
        return need_dict;
    }
    _ = s.decoder.decode(s.header[0..2], &.{}) catch return data_error;
    s.header_ready = true;
    return ok;
}

pub export fn inflate(stream: ?*Stream, flush: c_int) c_int {
    const z = stream orelse return stream_error;
    const s = state(z, .decode) orelse return stream_error;
    if (flush < 0 or flush > 6 or z.next_out == null or (z.avail_in != 0 and z.next_in == null)) return stream_error;
    const before_in = z.total_in;
    const before_out = z.total_out;
    if (!s.header_ready) {
        const status = decodeHeader(z, s);
        if (status != ok) return status;
        if (!s.header_ready) return if (before_in == z.total_in) buf_error else ok;
    }
    while (true) {
        const step = s.decoder.decode(if (z.avail_in == 0) &.{} else z.next_in[0..z.avail_in], z.next_out[0..z.avail_out]) catch |err| {
            z.msg = @errorName(err).ptr;
            return data_error;
        };
        advance(z, step.in_len, step.out_len);
        z.adler = s.decoder.state.check;
        updateHeader(s);
        switch (step.status) {
            .done, .member_end => return stream_end,
            .block_end => if (flush == 5 or flush == 6) return ok,
            .output_full, .need_input => break,
        }
    }
    if (before_in == z.total_in and before_out == z.total_out) return buf_error;
    return if (flush == 4) buf_error else ok;
}

pub export fn inflateSetDictionary(stream: ?*Stream, dictionary: [*c]const u8, len: c_uint) c_int {
    const z = stream orelse return stream_error;
    const s = state(z, .decode) orelse return stream_error;
    if (dictionary == null and len != 0) return stream_error;
    const bytes = if (len == 0) &.{} else dictionary[0..len];
    if (s.dictionary_id) |id| {
        if (checksum.adler32(1, bytes) != id) return data_error;
        s.decoder.state = .{ .phase = .body, .wrapper = .zlib, .check = 1 };
        s.decoder.in_total = s.header_len;
        s.header_ready = true;
        s.dictionary_id = null;
    } else if (s.accept != .raw) return stream_error;
    const n = @min(bytes.len, s.decoder.window.len);
    @memcpy(s.decoder.window[0..n], bytes[bytes.len - n ..]);
    s.decoder.head = n & (s.decoder.window.len - 1);
    s.decoder.filled = n;
    if (s.accept == .raw) s.decoder.keep_history = true;
    z.adler = 1;
    return ok;
}

pub export fn inflateReset(stream: ?*Stream) c_int {
    const z = stream orelse return stream_error;
    const s = state(z, .decode) orelse return stream_error;
    s.decoder.reset(.nothing);
    s.gzip_header = null;
    s.decoder.options.gzip_fields = null;
    s.header_len = 0;
    s.header_ready = s.accept == .raw or s.accept == .gzip;
    s.dictionary_id = null;
    z.total_in = 0;
    z.total_out = 0;
    z.msg = null;
    z.adler = if (s.accept == .gzip) 0 else 1;
    return ok;
}

pub export fn inflateEnd(stream: ?*Stream) c_int {
    const z = stream orelse return stream_error;
    const s = state(z, .decode) orelse return stream_error;
    destroy(z, s);
    return ok;
}

/// zlib's gzip header layout; variable fields borrow the caller's buffers.
pub const Header = extern struct {
    text: c_int = 0,
    time: c_ulong = 0,
    xflags: c_int = 0,
    os: c_int = 255,
    extra: [*c]u8 = null,
    extra_len: c_uint = 0,
    extra_max: c_uint = 0,
    name: [*c]u8 = null,
    name_max: c_uint = 0,
    comment: [*c]u8 = null,
    comm_max: c_uint = 0,
    hcrc: c_int = 0,
    done: c_int = 0,
};

fn headerLength(h: *const Header) usize {
    return 10 + (if (h.extra != null) 2 + @as(usize, h.extra_len) else @as(usize, 0)) +
        (if (h.name != null) std.mem.span(h.name).len + 1 else @as(usize, 0)) +
        (if (h.comment != null) std.mem.span(h.comment).len + 1 else @as(usize, 0)) +
        (if (h.hcrc != 0) @as(usize, 2) else 0);
}

fn headerByte(s: *const State, h: *const Header, offset: usize) u8 {
    const level_ = s.encoder.options.level;
    var fixed = [_]u8{ 31, 139, 8, 0, 0, 0, 0, 0, 0, @truncate(@as(c_uint, @bitCast(h.os))) };
    fixed[3] = @as(u8, @intFromBool(h.text != 0)) | @as(u8, @intFromBool(h.hcrc != 0)) << 1 |
        @as(u8, @intFromBool(h.extra != null)) << 2 | @as(u8, @intFromBool(h.name != null)) << 3 | @as(u8, @intFromBool(h.comment != null)) << 4;
    std.mem.writeInt(u32, fixed[4..8], @truncate(h.time), .little);
    fixed[8] = if (level_ >= 9) 2 else if (level_ == 1) 4 else 0;
    if (offset < 10) return fixed[offset];
    var at = offset - 10;
    if (h.extra != null) {
        if (at < 2) return @truncate(h.extra_len >> @intCast(at * 8));
        at -= 2;
        if (at < h.extra_len) return h.extra[at];
        at -= h.extra_len;
    }
    for ([_][*c]const u8{ h.name, h.comment }, [_]usize{ s.name_length, s.comment_length }) |field, length| if (field != null) {
        const n = length + 1;
        if (at < n) return field[at];
        at -= n;
    };
    unreachable; // unreachable: emitHeader handles the final header CRC separately
}

fn emitHeader(s: *State, h: *const Header, out: []u8) usize {
    const length = s.header_length;
    const data_end = length - @as(usize, if (h.hcrc != 0) 2 else 0);
    const n = @min(out.len, length - s.header_at);
    for (out[0..n]) |*byte| {
        byte.* = if (s.header_at < data_end) headerByte(s, h, s.header_at) else @truncate(s.header_check >> @intCast((s.header_at - data_end) * 8));
        if (h.hcrc != 0 and s.header_at < data_end) s.header_check = checksum.crc32(s.header_check, byte[0..1]);
        s.header_at += 1;
    }
    return n;
}

pub export fn deflateSetHeader(stream: ?*Stream, header: ?*Header) c_int {
    const z = stream orelse return stream_error;
    const s = state(z, .encode) orelse return stream_error;
    const h = header orelse return stream_error;
    if (s.encoder.options.container != .gzip or z.total_in != 0 or z.total_out != 0 or h.extra_len > 65535) return stream_error;
    s.gzip_header = h;
    s.header_length = headerLength(h);
    s.name_length = if (h.name != null) std.mem.span(h.name).len else 0;
    s.comment_length = if (h.comment != null) std.mem.span(h.comment).len else 0;
    s.header_at = 0;
    s.header_check = 0;
    s.encoder.pending_start = 0;
    s.encoder.pending_end = 0;
    return ok;
}

pub export fn inflateGetHeader(stream: ?*Stream, header: ?*Header) c_int {
    const z = stream orelse return stream_error;
    const s = state(z, .decode) orelse return stream_error;
    const h = header orelse return stream_error;
    if (s.accept != .gzip and s.accept != .gzip_or_zlib) return stream_error;
    h.done = 0;
    s.gzip_header = h;
    s.gzip_fields = .{
        .extra_buffer = if (h.extra == null) &.{} else h.extra[0..h.extra_max],
        .name_buffer = if (h.name == null) &.{} else h.name[0..h.name_max],
        .comment_buffer = if (h.comment == null) &.{} else h.comment[0..h.comm_max],
    };
    s.decoder.options.gzip_fields = &s.gzip_fields;
    return ok;
}

fn updateHeader(s: *State) void {
    const h = s.gzip_header orelse return;
    if (h.done != 0 or s.decoder.state.phase == .detect or s.decoder.state.phase == .gzip_header) return;
    if (s.decoder.state.wrapper != .gzip) {
        h.done = -1;
        return;
    }
    const fields = s.gzip_fields.header;
    h.text = @intFromBool(fields.text);
    h.time = fields.mtime;
    h.xflags = fields.xfl orelse 0;
    h.os = fields.os;
    h.hcrc = @intFromBool(fields.header_crc);
    h.extra_len = s.decoder.state.header.extra_len;
    for ([_]struct { bytes: ?[]const u8, buffer: []u8 }{
        .{ .bytes = fields.name, .buffer = s.gzip_fields.name_buffer },
        .{ .bytes = fields.comment, .buffer = s.gzip_fields.comment_buffer },
    }) |field| if (field.bytes) |bytes| {
        if (bytes.len < field.buffer.len) field.buffer[bytes.len] = 0;
    };
    h.done = 1;
}

pub export fn inflateReset2(stream: ?*Stream, bits: c_int) c_int {
    const z = stream orelse return stream_error;
    const s = state(z, .decode) orelse return stream_error;
    if (bits < -15 or bits > 47) return stream_error;
    const accept: container.Accept = if (bits < 0) .raw else if (bits >= 32) .gzip_or_zlib else if (bits >= 16) .gzip else .zlib;
    const n = if (bits >= 0 and bits & 15 == 0) 15 else if (bits < 0) -bits else bits & 15;
    if (n < 8 or n > 15) return stream_error;
    s.accept = accept;
    s.decoder.options.accept = accept;
    s.decoder.options.window_bits = @intCast(n);
    s.decoder.window = s.window[0 .. @as(usize, 1) << @intCast(n)];
    return inflateReset(z);
}

pub export fn inflateGetDictionary(stream: ?*Stream, dictionary: [*c]u8, len: ?*c_uint) c_int {
    const z = stream orelse return stream_error;
    const s = state(z, .decode) orelse return stream_error;
    const n = s.decoder.filled;
    if (len) |p| p.* = @intCast(n);
    if (dictionary != null) {
        const start = (s.decoder.head + s.decoder.window.len - n) & (s.decoder.window.len - 1);
        const first = @min(n, s.decoder.window.len - start);
        @memcpy(dictionary[0..first], s.decoder.window[start..][0..first]);
        @memcpy(dictionary[first..][0 .. n - first], s.decoder.window[0 .. n - first]);
    }
    return ok;
}

pub export fn deflateGetDictionary(stream: ?*Stream, dictionary: [*c]u8, len: ?*c_uint) c_int {
    const z = stream orelse return stream_error;
    const s = state(z, .encode) orelse return stream_error;
    const n = @min(s.encoder.filled, @as(usize, 1) << s.encoder.options.window_bits);
    if (len) |p| p.* = @intCast(n);
    if (dictionary != null) @memcpy(dictionary[0..n], s.encoder.window[s.encoder.filled - n .. s.encoder.filled]);
    return ok;
}

pub export fn deflatePending(stream: ?*Stream, pending: ?*c_uint, bit_count: ?*c_int) c_int {
    const z = stream orelse return stream_error;
    const s = state(z, .encode) orelse return stream_error;
    if (pending) |p| p.* = @intCast(s.encoder.pending_end - s.encoder.pending_start);
    if (bit_count) |p| p.* = @intCast(s.encoder.bitcount);
    return ok;
}

fn copiedState(dest: *Stream, source: *const Stream, old: *const State) ?*State {
    dest.* = source.*;
    dest.state = null;
    const fresh = create(dest, old.engine_bytes) orelse return null;
    const original = fresh.original;
    const allocation_len = fresh.allocation_len;
    const release = fresh.free;
    const userdata = fresh.@"opaque";
    fresh.* = old.*;
    fresh.original = original;
    fresh.allocation_len = allocation_len;
    fresh.free = release;
    fresh.@"opaque" = userdata;
    dest.* = source.*;
    dest.state = fresh;
    return fresh;
}

fn moved(slice: anytype, old: *const State, fresh: *State) @TypeOf(slice) {
    if (slice.len == 0) return slice;
    const offset = @intFromPtr(slice.ptr) - @intFromPtr(old); // safe: this slice lies within the old state's allocation
    const pointer: @TypeOf(slice.ptr) = @ptrFromInt(@intFromPtr(fresh) + offset); // safe: the identical copied layout preserves the slice's alignment and length
    return pointer[0..slice.len];
}

pub export fn inflateCopy(destination: ?*Stream, source: ?*Stream) c_int {
    const dest = destination orelse return stream_error;
    const src = source orelse return stream_error;
    if (dest == src) return stream_error;
    const old = state(src, .decode) orelse return stream_error;
    const fresh = copiedState(dest, src, old) orelse return mem_error;
    fresh.decoder.window = moved(old.decoder.window, old, fresh);
    fresh.decoder.options.diagnostic = &fresh.diagnostic;
    if (old.decoder.options.gzip_fields != null) fresh.decoder.options.gzip_fields = &fresh.gzip_fields;
    return ok;
}

pub export fn deflateCopy(destination: ?*Stream, source: ?*Stream) c_int {
    const dest = destination orelse return stream_error;
    const src = source orelse return stream_error;
    if (dest == src) return stream_error;
    const old = state(src, .encode) orelse return stream_error;
    const fresh = copiedState(dest, src, old) orelse return mem_error;
    const padding = std.mem.alignForward(usize, @sizeOf(State), 64);
    const from: [*]const u8 = @ptrCast(old); // safe: the engine allocation follows State at padding
    const to: [*]u8 = @ptrCast(fresh); // safe: copiedState reserved the same engine bytes
    @memcpy(to[padding..][0..old.engine_bytes], from[padding..][0..old.engine_bytes]);
    fresh.encoder.window = moved(old.encoder.window, old, fresh);
    fresh.encoder.pending = moved(old.encoder.pending, old, fresh);
    fresh.encoder.options.dictionary = moved(old.encoder.options.dictionary, old, fresh);
    fresh.encoder.engine.b.seqs = moved(old.encoder.engine.b.seqs, old, fresh);
    fresh.encoder.engine.b.lits = moved(old.encoder.engine.b.lits, old, fresh);
    fresh.encoder.engine.hc.hash3 = moved(old.encoder.engine.hc.hash3, old, fresh);
    fresh.encoder.engine.hc.hash4 = moved(old.encoder.engine.hc.hash4, old, fresh);
    fresh.encoder.engine.hc.prev = moved(old.encoder.engine.hc.prev, old, fresh);
    fresh.encoder.engine.ht.table = moved(old.encoder.engine.ht.table, old, fresh);
    fresh.encoder.engine.ht.short = moved(old.encoder.engine.ht.short, old, fresh);
    return ok;
}

pub export fn zError(code: c_int) [*:0]const u8 {
    return switch (code) {
        0 => "",
        1 => "stream end",
        2 => "need dictionary",
        -1 => "file error",
        -2 => "stream error",
        -3 => "data error",
        -4 => "insufficient memory",
        -5 => "buffer error",
        -6 => "incompatible version",
        else => "",
    };
}

pub export fn zlibCompileFlags() c_ulong {
    return (if (@sizeOf(c_uint) == 4) @as(c_ulong, 1) else 2) | (if (@sizeOf(c_ulong) == 4) @as(c_ulong, 1) else 2) << 2 |
        (if (@sizeOf(usize) == 4) @as(c_ulong, 1) else 2) << 4 | @as(c_ulong, 2) << 6 | @as(c_ulong, 1) << 16;
}

pub export fn compressBound(len: c_ulong) c_ulong {
    return @intCast(Compressor.bound(len, .{}));
}

pub export fn compress2(out: [*c]u8, out_len: ?*c_ulong, in: [*c]const u8, in_len: c_ulong, value: c_int) c_int {
    const n = out_len orelse return stream_error;
    const lv = level(value) orelse return stream_error;
    if (out == null or (in == null and in_len != 0)) return stream_error;
    var c = Compressor.init(std.heap.page_allocator, .{ .level = lv, .max_input = in_len }) catch return mem_error;
    defer c.deinit();
    n.* = c.compress(if (in_len == 0) &.{} else in[0..in_len], out[0..n.*], .{}) catch return buf_error;
    return ok;
}

pub export fn compress(out: [*c]u8, out_len: ?*c_ulong, in: [*c]const u8, in_len: c_ulong) c_int {
    return compress2(out, out_len, in, in_len, -1);
}

pub export fn uncompress2(out: [*c]u8, out_len: ?*c_ulong, in: [*c]const u8, in_len: ?*c_ulong) c_int {
    const n = out_len orelse return stream_error;
    const count = in_len orelse return stream_error;
    if (out == null or (in == null and count.* != 0)) return stream_error;
    var d: Decompressor = .init;
    const result = d.inflate(if (count.* == 0) &.{} else in[0..count.*], out[0..n.*], .{}) catch |err| return if (err == error.OutputTooSmall) buf_error else data_error;
    n.* = result.out_len;
    count.* = result.in_len;
    return ok;
}

pub export fn uncompress(out: [*c]u8, out_len: ?*c_ulong, in: [*c]const u8, in_len: c_ulong) c_int {
    var n = in_len;
    return uncompress2(out, out_len, in, &n);
}

pub export fn crc32(value: c_ulong, in: [*c]const u8, len: c_uint) c_ulong {
    return if (in == null) 0 else checksum.crc32(@truncate(value), in[0..len]);
}
pub fn crc32Z(value: c_ulong, in: [*c]const u8, len: usize) callconv(.c) c_ulong {
    return if (in == null) 0 else checksum.crc32(@truncate(value), in[0..len]);
}
pub export fn adler32(value: c_ulong, in: [*c]const u8, len: c_uint) c_ulong {
    return if (in == null) 1 else checksum.adler32(@truncate(value), in[0..len]);
}
pub fn adler32Z(value: c_ulong, in: [*c]const u8, len: usize) callconv(.c) c_ulong {
    return if (in == null) 1 else checksum.adler32(@truncate(value), in[0..len]);
}
pub fn crc32Combine(a: c_ulong, b: c_ulong, len: c_long) callconv(.c) c_ulong {
    return if (len < 0) 0 else checksum.crc32Combine(@truncate(a), @truncate(b), @intCast(len));
}
pub fn crc32Combine64(a: c_ulong, b: c_ulong, len: i64) callconv(.c) c_ulong {
    return if (len < 0) 0 else checksum.crc32Combine(@truncate(a), @truncate(b), @intCast(len));
}
pub fn adler32Combine(a: c_ulong, b: c_ulong, len: c_long) callconv(.c) c_ulong {
    return if (len < 0) 0xffffffff else checksum.adler32Combine(@truncate(a), @truncate(b), @intCast(len));
}
pub fn adler32Combine64(a: c_ulong, b: c_ulong, len: i64) callconv(.c) c_ulong {
    return if (len < 0) 0xffffffff else checksum.adler32Combine(@truncate(a), @truncate(b), @intCast(len));
}

comptime {
    @export(&deflateInit, .{ .name = "deflateInit_" });
    @export(&deflateInit2, .{ .name = "deflateInit2_" });
    @export(&inflateInit, .{ .name = "inflateInit_" });
    @export(&inflateInit2, .{ .name = "inflateInit2_" });
    @export(&crc32Z, .{ .name = "crc32_z" });
    @export(&adler32Z, .{ .name = "adler32_z" });
    @export(&crc32Combine, .{ .name = "crc32_combine" });
    @export(&crc32Combine64, .{ .name = "crc32_combine64" });
    @export(&adler32Combine, .{ .name = "adler32_combine" });
    @export(&adler32Combine64, .{ .name = "adler32_combine64" });
}
