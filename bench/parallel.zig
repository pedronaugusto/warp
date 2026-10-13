//! Ordered chunk compression and indexed decompression, by worker count.
const std = @import("std");
const Io = std.Io;
const warp = @import("warp");
const support = @import("support.zig");

const Session = support.Session;
const Error = support.Error;

const Operation = enum { encode, decode, index };

pub const Parallel = struct {
    session: *Session,
    workload: usize,
    level: u4,
    workers: u16,
    operation: Operation,
    arena: std.heap.ArenaAllocator = undefined,
    encoder: ?warp.parallel.Compressor = null,
    decoder: ?warp.parallel.Decompressor = null,
    inputs: []const []const u8 = &.{},
    storage: [][]u8 = &.{},
    streams: [][]const u8 = &.{},
    indexes: []warp.gzip.Index = &.{},
    built: usize = 0,
    decoded: [][]u8 = &.{},

    pub fn setup(c: *Parallel) Error!void {
        const gpa = c.session.gpa;
        c.arena = .init(gpa);
        errdefer c.arena.deinit();
        const a = c.arena.allocator();
        c.inputs = c.session.loaded.?[c.workload].inputs;
        const options: warp.parallel.Options = .{ .level = c.level, .concurrency = c.workers };
        c.encoder = try .init(gpa, options);
        errdefer c.encoder.?.deinit();
        c.storage = try a.alloc([]u8, c.inputs.len);
        for (c.storage, c.inputs) |*slot, input| slot.* = try a.alloc(u8, input.len + input.len / 8 + 1024);
        if (c.operation == .encode) return;
        c.decoder = try .init(gpa, .{ .concurrency = c.workers });
        errdefer c.decoder.?.deinit();
        c.streams = try a.alloc([]const u8, c.inputs.len);
        c.indexes = try a.alloc(warp.gzip.Index, c.inputs.len);
        c.decoded = try a.alloc([]u8, c.inputs.len);
        errdefer c.release();
        for (c.inputs, c.storage, 0..) |input, storage, i| {
            var sink: Io.Writer = .fixed(storage);
            try c.encoder.?.compress(c.session.io, input, &sink);
            c.streams[i] = try a.dupe(u8, sink.buffered());
            c.indexes[i] = try .build(gpa, c.streams[i], .gzip, 128 << 10);
            c.built += 1;
            c.decoded[i] = try a.alloc(u8, input.len);
            _ = try c.decoder.?.decompress(c.session.io, c.streams[i], c.decoded[i], &c.indexes[i]);
            if (!std.mem.eql(u8, input, c.decoded[i])) return error.WrongOutput;
        }
    }

    fn release(c: *Parallel) void {
        for (c.indexes[0..c.built]) |*index| index.deinit();
        c.built = 0;
    }

    pub fn teardown(c: *Parallel) Error!void {
        c.release();
        if (c.decoder) |*d| d.deinit();
        c.decoder = null;
        c.encoder.?.deinit();
        c.encoder = null;
        c.arena.deinit();
    }

    pub fn run(c: *Parallel, units: u64) Error!void {
        const io = c.session.io;
        for (0..units) |_| for (c.inputs, 0..) |input, i| switch (c.operation) {
            .encode => {
                var sink: Io.Writer = .fixed(c.storage[i]);
                try c.encoder.?.compress(io, input, &sink);
            },
            .decode => _ = try c.decoder.?.decompress(io, c.streams[i], c.decoded[i], &c.indexes[i]),
            .index => {
                var rebuilt: warp.gzip.Index = try .build(c.session.gpa, c.streams[i], .gzip, 128 << 10);
                rebuilt.deinit();
            },
        };
    }
};

pub fn rows(s: *Session) !void {
    if (!s.wants("parallel/")) return;
    for (try s.workloads(), 0..) |wl, index| {
        if (!s.wants(try s.name("parallel/{s}/", .{wl.name}))) continue;
        for ([_]u4{ 1, 6, 12 }) |level| for ([_]u16{ 1, 2, 4, 8 }) |workers| for ([_]Operation{ .encode, .decode, .index }) |operation| {
            const ctx = try s.arena.create(Parallel);
            ctx.* = .{ .session = s, .workload = index, .level = level, .workers = workers, .operation = operation };
            try s.measure(Parallel, ctx, support.rowOf(Parallel, try s.name("parallel/{s}/level {d}/workers {d}/{t}", .{ wl.name, level, workers, operation }), "pass"));
        };
    }
}
