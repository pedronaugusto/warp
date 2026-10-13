//! One-stream decoding without an index, including discovery and resolution.
const std = @import("std");
const warp = @import("warp");
const support = @import("support.zig");

const Session = support.Session;
const Error = support.Error;

/// Native decoding of a gzip stream, or the speculative parallel decoder at
/// `workers`.
pub const Speculative = struct {
    session: *Session,
    workload: usize,
    workers: u16,
    native: bool,
    arena: std.heap.ArenaAllocator = undefined,
    decoder: ?warp.parallel.Decompressor = null,
    d: *warp.Decompressor = undefined,
    inputs: []const []const u8 = &.{},
    encoded: [][]u8 = &.{},
    back: [][]u8 = &.{},

    pub fn setup(c: *Speculative) Error!void {
        const gpa = c.session.gpa;
        c.arena = .init(gpa);
        errdefer c.arena.deinit();
        const a = c.arena.allocator();
        c.inputs = c.session.loaded.?[c.workload].inputs;
        c.d = try a.create(warp.Decompressor);
        c.d.* = .init;
        if (!c.native) c.decoder = try .init(gpa, .{ .concurrency = c.workers, .speculative = .{} });
        errdefer if (c.decoder) |*d| d.deinit();
        var compressor = try warp.Compressor.init(a, .{ .level = 6 });
        defer compressor.deinit();
        c.encoded = try a.alloc([]u8, c.inputs.len);
        c.back = try a.alloc([]u8, c.inputs.len);
        for (c.inputs, c.encoded, c.back) |input, *encoded, *back| {
            const storage = try a.alloc(u8, warp.Compressor.bound(input.len, .{ .container = .gzip }));
            encoded.* = storage[0..try compressor.compress(input, storage, .{ .container = .gzip })];
            back.* = try a.alloc(u8, input.len);
            const result = if (c.decoder) |*d|
                try d.inflate(c.session.io, encoded.*, back.*, .{ .accept = .gzip })
            else
                try c.d.inflate(encoded.*, back.*, .{ .accept = .gzip });
            if (result.out_len != input.len or !std.mem.eql(u8, input, back.*)) return error.WrongOutput;
        }
    }

    pub fn teardown(c: *Speculative) Error!void {
        if (c.decoder) |*d| d.deinit();
        c.decoder = null;
        c.arena.deinit();
    }

    pub fn run(c: *Speculative, units: u64) Error!void {
        for (0..units) |_| for (c.encoded, c.back) |encoded, back| {
            if (c.decoder) |*d| {
                _ = try d.inflate(c.session.io, encoded, back, .{ .accept = .gzip });
            } else _ = try c.d.inflate(encoded, back, .{ .accept = .gzip });
        };
    }
};

pub fn rows(s: *Session) !void {
    if (!s.wants("speculative/")) return;
    for (try s.workloads(), 0..) |wl, index| {
        if (!s.wants(try s.name("speculative/{s}/", .{wl.name}))) continue;
        const native = try s.arena.create(Speculative);
        native.* = .{ .session = s, .workload = index, .workers = 1, .native = true };
        try s.measure(Speculative, native, support.rowOf(Speculative, try s.name("speculative/{s}/native", .{wl.name}), "pass"));
        for ([_]u16{ 1, 2, 4, 8 }) |workers| {
            if (workers > s.cpus) continue;
            const ctx = try s.arena.create(Speculative);
            ctx.* = .{ .session = s, .workload = index, .workers = workers, .native = false };
            try s.measure(Speculative, ctx, support.rowOf(Speculative, try s.name("speculative/{s}/workers {d}", .{ wl.name, workers }), "pass"));
        }
    }
}
