//! BGZF gzip members: at most 64 KiB on disk and decoded, with the BC
//! extra field and the canonical empty EOF member. No allocation per block.
const Bgzf = @This();
const std = @import("std");
const aegis = @import("aegis");
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

/// The compressor's tables, a member's input and its output, one block.
const Parts = struct { compressor: Compressor.Parts, input: []u8, output: []u8 };
const Block = aegis.parts.Block(Parts);

fn compressorOptions(options: Options) Compressor.Options {
    return .{ .level = options.level, .max_input = .literal("64KiB"), .passes = options.passes };
}

fn plan(options: Options) Block.Plan {
    return Block.plan(.{
        .compressor = Compressor.counts(compressorOptions(options)),
        .input = 65536,
        .output = Compressor.bound(65536, .{ .container = .gzip, .gzip = .{ .extra = "BC\x02\x00\x00\x00" } }),
    });
}

pub fn memory(options: Options) usize {
    return (plan(options).size() catch return std.math.maxInt(usize)).raw();
}

pub fn init(gpa: std.mem.Allocator, options: Options) std.mem.Allocator.Error!Bgzf {
    const block = try plan(options).alloc(gpa);
    var b = assemble(block, options);
    b.owned = block.bytes();
    b.gpa = gpa;
    return b;
}

/// Caller memory, aligned to 64 bytes, refused when shorter than
/// `memory(options)`; deinit frees nothing.
pub fn initBuffer(buffer: []align(64) u8, options: Options) error{BufferTooSmall}!Bgzf {
    return assemble(try plan(options).fit(buffer), options);
}

/// The one core of `init` and `initBuffer`: a block holds its parts.
fn assemble(block: Block, options: Options) Bgzf {
    const p = block.parts();
    return .{ .compressor = .fromParts(p.compressor, compressorOptions(options)), .input = p.input, .output = p.output, .owned = &.{}, .gpa = undefined };
}

pub fn deinit(b: *Bgzf) void {
    b.compressor.deinit();
    if (b.owned.len != 0) b.gpa.free(b.owned);
    b.* = undefined;
}

pub const WriteError = Io.Writer.Error;

pub fn write(b: *Bgzf, in: []const u8, out: *Io.Writer) WriteError!void {
    aegis.assert.invariant(!b.finished, "!b.finished");
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
    aegis.assert.invariant(b.compressed_offset < 1 << 48, "b.compressed_offset < 1 << 48");
    aegis.assert.invariant(b.filled < 65536, "b.filled < 65536");
    return (b.compressed_offset << 16) | @as(u64, @intCast(b.filled));
}

fn emit(b: *Bgzf, out: *Io.Writer) WriteError!void {
    var extra = [_]u8{ 'B', 'C', 2, 0, 0, 0 };
    const frame: Compressor.Frame = .{ .container = .gzip, .gzip = .{ .extra = &extra } };
    var take = b.filled;
    var n = b.compressor.compress(b.input[0..take], b.output, frame) catch aegis.assert.never("output is Compressor.bound(65536, this frame) bytes (memory), and take is at most 65536");
    if (n > 65536) {
        // 65,280 bytes fit even as stored blocks. Keep the rest for the
        // next member; this is determined by bytes, never write chunking.
        take = @min(take, 65280);
        n = b.compressor.compress(b.input[0..take], b.output, frame) catch aegis.assert.never("output is Compressor.bound(65536, this frame) bytes (memory), and take is at most 65280");
    }
    aegis.assert.invariant(n <= 65536, "n <= 65536");
    std.mem.writeInt(u16, b.output[16..18], @intCast(n - 1), .little);
    try out.writeAll(b.output[0..n]);
    b.compressed_offset += n;
    @memmove(b.input[0 .. b.filled - take], b.input[take..b.filled]);
    b.filled -= take;
}
