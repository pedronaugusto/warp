//! A portable index of validated block boundaries and their history windows.
//! Offsets address the original compressed and decoded streams. Build an
//! index once, then reuse it for seeks and parallel decoding.
const Index = @This();
const std = @import("std");
const Inflate = @import("stream/Inflate.zig");
const container = @import("container.zig");
const Io = std.Io;

points: []Inflate.Checkpoint,
in_len: u64,
out_len: u64,
accept: container.Accept,
gpa: std.mem.Allocator,

pub const BuildError = std.mem.Allocator.Error || Inflate.DecodeError || error{Truncated};

/// Record a boundary at least `spacing` decoded bytes after the previous
/// one. Small blocks are coalesced; an index never invents a boundary.
pub fn build(gpa: std.mem.Allocator, in: []const u8, accept: container.Accept, spacing: usize) BuildError!Index {
    var points: std.ArrayList(Inflate.Checkpoint) = .empty;
    errdefer points.deinit(gpa);
    const window = try gpa.alloc(u8, 32768);
    defer gpa.free(window);
    const output = try gpa.alloc(u8, 65536);
    defer gpa.free(output);
    var z: Inflate = .init(window, .{ .accept = accept });
    var at: usize = 0;
    var last: u64 = 0;
    while (true) {
        const step = try z.decode(in[at..], output);
        at += step.in_len;
        if (step.status == .block_end and z.out_total - last >= @max(spacing, 1)) {
            try points.append(gpa, z.checkpoint() catch unreachable); // unreachable: decode just returned block_end
            last = z.out_total;
        }
        if (step.status == .done or (step.status == .member_end and at == in.len)) break;
        if (step.status == .need_input and at == in.len) return error.Truncated;
    }
    return .{ .points = try points.toOwnedSlice(gpa), .in_len = at, .out_len = z.out_total, .accept = accept, .gpa = gpa };
}

pub fn deinit(index: *Index) void {
    index.gpa.free(index.points);
    index.* = undefined;
}

/// The latest boundary at or before the desired decoded offset.
pub fn find(index: *const Index, offset: u64) ?*const Inflate.Checkpoint {
    var low: usize = 0;
    var high = index.points.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        if (index.points[mid].out_offset <= offset) low = mid + 1 else high = mid;
    }
    return if (low == 0) null else &index.points[low - 1];
}

const magic = "WIDX\x01\x00\x00\x00";
pub const WriteError = Io.Writer.Error;

pub fn write(index: *const Index, out: *Io.Writer) WriteError!void {
    try out.writeAll(magic);
    var header: [25]u8 = undefined;
    std.mem.writeInt(u64, header[0..8], index.in_len, .little);
    std.mem.writeInt(u64, header[8..16], index.out_len, .little);
    std.mem.writeInt(u64, header[16..24], index.points.len, .little);
    header[24] = @backingInt(index.accept);
    try out.writeAll(&header);
    for (index.points) |*point| {
        var record: [33]u8 = undefined;
        std.mem.writeInt(u64, record[0..8], point.in_offset, .little);
        std.mem.writeInt(u64, record[8..16], point.out_offset, .little);
        std.mem.writeInt(u32, record[16..20], point.check, .little);
        std.mem.writeInt(u32, record[20..24], point.size, .little);
        std.mem.writeInt(u32, record[24..28], point.members, .little);
        std.mem.writeInt(u16, record[28..30], point.history_len, .little);
        record[30] = @as(u8, point.window_bits) | @as(u8, point.bits) << 4;
        record[31] = point.pending;
        record[32] = @backingInt(point.wrapper);
        try out.writeAll(&record);
        try out.writeAll(point.history[0..point.history_len]);
    }
}

pub const ReadError = std.mem.Allocator.Error || error{InvalidIndex};

pub fn read(gpa: std.mem.Allocator, bytes: []const u8) ReadError!Index {
    if (bytes.len < magic.len + 25 or !std.mem.eql(u8, bytes[0..8], magic)) return error.InvalidIndex;
    const in_len = std.mem.readInt(u64, bytes[8..16], .little);
    const out_len = std.mem.readInt(u64, bytes[16..24], .little);
    const count = std.mem.readInt(u64, bytes[24..32], .little);
    const accept = std.enums.fromInt(container.Accept, bytes[32]) orelse return error.InvalidIndex;
    if (count > (bytes.len - 33) / 33) return error.InvalidIndex;
    const points = try gpa.alloc(Inflate.Checkpoint, @intCast(count));
    errdefer gpa.free(points);
    var at: usize = 33;
    var previous_in: u64 = 0;
    var previous_out: u64 = 0;
    for (points) |*point| {
        if (bytes.len - at < 33) return error.InvalidIndex;
        const record = bytes[at..][0..33];
        const window_bits = record[30] & 15;
        const bit_count = record[30] >> 4;
        const n = std.mem.readInt(u16, record[28..30], .little);
        if (window_bits < 8 or window_bits > 15 or bit_count > 7 or n > 32768 or
            n > @as(u32, 1) << @intCast(window_bits) or
            (@as(u16, record[31]) >> @intCast(bit_count)) != 0) return error.InvalidIndex;
        point.* = .{
            .in_offset = std.mem.readInt(u64, record[0..8], .little),
            .out_offset = std.mem.readInt(u64, record[8..16], .little),
            .check = std.mem.readInt(u32, record[16..20], .little),
            .size = std.mem.readInt(u32, record[20..24], .little),
            .members = std.mem.readInt(u32, record[24..28], .little),
            .history_len = n,
            .window_bits = @intCast(window_bits),
            .bits = @intCast(bit_count),
            .pending = record[31],
            .wrapper = std.enums.fromInt(container.Container, record[32]) orelse return error.InvalidIndex,
        };
        if (point.in_offset < previous_in or point.in_offset >= in_len or
            point.out_offset <= previous_out or point.out_offset > out_len) return error.InvalidIndex;
        previous_in = point.in_offset;
        previous_out = point.out_offset;
        at += 33;
        if (n > bytes.len - at) return error.InvalidIndex;
        @memcpy(point.history[0..n], bytes[at..][0..n]);
        at += n;
    }
    if (at != bytes.len) return error.InvalidIndex;
    return .{ .points = points, .in_len = in_len, .out_len = out_len, .accept = accept, .gpa = gpa };
}
