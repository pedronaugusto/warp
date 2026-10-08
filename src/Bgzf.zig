//! BGZF gzip members: at most 64 KiB on disk and decoded, with the BC
//! extra field and the canonical empty EOF member. No allocation per block.
const Bgzf = @This();
const std = @import("std");
const Io = std.Io;
const Compressor = @import("Compressor.zig");

compressor: Compressor,
input: []u8,
output: []u8,
filled: usize = 0,
owned: []align(64) u8,
gpa: std.mem.Allocator,
finished: bool = false,
compressed_offset: u64 = 0,

pub const Options = struct { level: u4 = 6, passes: ?u32 = null };
pub const eof = [_]u8{ 31, 139, 8, 4, 0, 0, 0, 0, 0, 255, 6, 0, 66, 67, 2, 0, 27, 0, 3, 0, 0, 0, 0, 0, 0, 0, 0, 0 };

pub fn memory(options: Options) usize {
    return std.mem.alignForward(usize, Compressor.memory(.{ .level = options.level, .max_input = 65536, .passes = options.passes }), 64) + 65536 + Compressor.bound(65536, .{ .container = .gzip, .gzip = .{ .extra = "BC\x02\x00\x00\x00" } });
}

pub fn init(gpa: std.mem.Allocator, options: Options) std.mem.Allocator.Error!Bgzf {
    const owned = try gpa.alignedAlloc(u8, .@"64", memory(options));
    var b = initBuffer(owned, options);
    b.owned = owned;
    b.gpa = gpa;
    return b;
}

/// Caller memory, aligned to 64 bytes; deinit frees nothing.
pub fn initBuffer(buffer: []align(64) u8, options: Options) Bgzf {
    std.debug.assert(buffer.len >= memory(options));
    const owned = buffer[0..memory(options)];
    const compressor_options: Compressor.Options = .{ .level = options.level, .max_input = 65536, .passes = options.passes };
    const n = std.mem.alignForward(usize, Compressor.memory(compressor_options), 64);
    return .{
        .compressor = .initBuffer(owned[0..n], compressor_options),
        .input = owned[n..][0..65536],
        .output = owned[n + 65536 ..],
        .owned = &.{},
        .gpa = undefined,
    };
}

pub fn deinit(b: *Bgzf) void {
    b.compressor.deinit();
    if (b.owned.len != 0) b.gpa.free(b.owned);
    b.* = undefined;
}

pub const WriteError = Io.Writer.Error;

pub fn write(b: *Bgzf, in: []const u8, out: *Io.Writer) WriteError!void {
    std.debug.assert(!b.finished);
    var at: usize = 0;
    while (at < in.len) {
        const n = @min(in.len - at, b.input.len - b.filled);
        @memcpy(b.input[b.filled..][0..n], in[at..][0..n]);
        at += n;
        b.filled += n;
        if (b.filled == b.input.len) try b.emit(out);
    }
}

/// Flush a restart point. Writing can continue afterwards.
pub fn flush(b: *Bgzf, out: *Io.Writer) WriteError!void {
    while (b.filled != 0) try b.emit(out);
}

pub fn finish(b: *Bgzf, out: *Io.Writer) WriteError!void {
    if (b.finished) return;
    try b.flush(out);
    try out.writeAll(&eof);
    b.compressed_offset += eof.len;
    b.finished = true;
}

/// BGZF's virtual position: member byte offset above its 16-bit decoded
/// offset. Flush before recording a position that must be on disk.
pub fn virtualOffset(b: *const Bgzf) u64 {
    std.debug.assert(b.compressed_offset < 1 << 48);
    std.debug.assert(b.filled < 65536);
    return b.compressed_offset << 16 | @as(u64, @intCast(b.filled));
}

fn emit(b: *Bgzf, out: *Io.Writer) WriteError!void {
    var extra = [_]u8{ 'B', 'C', 2, 0, 0, 0 };
    const frame: Compressor.Frame = .{ .container = .gzip, .gzip = .{ .extra = &extra } };
    var take = b.filled;
    var n = b.compressor.compress(b.input[0..take], b.output, frame) catch unreachable; // unreachable: output has the whole-buffer bound
    if (n > 65536) {
        // 65,280 bytes fit even as stored blocks. Keep the rest for the
        // next member; this is determined by bytes, never write chunking.
        take = @min(take, 65280);
        n = b.compressor.compress(b.input[0..take], b.output, frame) catch unreachable; // unreachable: output has the whole-buffer bound
    }
    std.debug.assert(n <= 65536);
    std.mem.writeInt(u16, b.output[16..18], @intCast(n - 1), .little);
    try out.writeAll(b.output[0..n]);
    b.compressed_offset += n;
    @memmove(b.input[0 .. b.filled - take], b.input[take..b.filled]);
    b.filled -= take;
}
