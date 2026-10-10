//! One deterministic size gate: totals per level and standard corpus, each at
//! or below its captured limit. The captured inputs also say, per level, how
//! each input compares with the size recorded for it: the median, the 99th
//! percentile and the worst.
const std = @import("std");
const warp = @import("warp");
const captured = @import("captured");

const File = struct { parts: []const []const u8, length: usize, sha256: []const u8 };
const Corpus = struct { name: []const u8, files: []const File, limits: [13]u64 };

pub fn main(init: std.process.Init) !void {
    const manifest = try std.Io.Dir.cwd().readFileAlloc(init.io, "testdata/standard.json", init.arena.allocator(), .unlimited);
    const parsed = try std.json.parseFromSlice([]const Corpus, init.arena.allocator(), manifest, .{});
    var progress_buffer: [4096]u8 = undefined;
    var progress = std.Io.File.stderr().writerStreaming(init.io, &progress_buffer);
    var failed = false;
    for (parsed.value) |definition| {
        var arena: std.heap.ArenaAllocator = .init(init.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        var inputs: std.ArrayList([]const u8) = .empty;
        var reference: std.ArrayList([levels]u64) = .empty;
        var specs: std.ArrayList([]const u8) = .empty;
        if (std.mem.eql(u8, definition.name, "captured")) {
            var records = (try captured.Corpus.parse(captured.sizes)).records();
            while (records.next()) |record| {
                try inputs.append(a, try captured.input(a, record.fields[0]));
                try specs.append(a, record.fields[0]);
                try reference.append(a, try recordedSizes(record.fields[1]));
            }
        } else for (definition.files) |file| {
            const bytes = try read(a, init.io, file);
            if (std.mem.eql(u8, definition.name, "loose-git")) {
                try objects(a, bytes, &inputs);
            } else try inputs.append(a, bytes);
        }
        var largest: usize = 0;
        for (inputs.items) |input| largest = @max(largest, input.len);
        const output = try a.alloc(u8, warp.Compressor.bound(largest, .{}));
        for (definition.limits, 0..) |limit, level| {
            var encoder = try warp.Compressor.init(a, .{ .level = @intCast(level) });
            defer encoder.deinit();
            var total: u64 = 0;
            const ratios = try a.alloc(f64, reference.items.len);
            for (inputs.items, 0..) |input, i| {
                const size = try encoder.compress(input, output, .{});
                total += size;
                if (level != 0 and ratios.len != 0) ratios[i] = @as(f64, @floatFromInt(size)) / @as(f64, @floatFromInt(reference.items[i][level - 1]));
            }
            try progress.interface.print("size {s} L{d}: {d} <= {d} {s}\n", .{ definition.name, level, total, limit, if (total <= limit) "pass" else "FAIL" });
            if (level != 0 and ratios.len != 0) try report(&progress.interface, ratios, specs.items);
            try progress.interface.flush();
            failed = failed or total > limit;
        }
    }
    try progress.interface.flush();
    if (failed) return error.SizeRegression;
}

/// The levels the recorded sizes cover: 1 through 12.
const levels = 12;

fn recordedSizes(text: []const u8) ![levels]u64 {
    var sizes: [levels]u64 = undefined;
    var fields = std.mem.tokenizeScalar(u8, text, ' ');
    for (&sizes) |*size| size.* = try std.fmt.parseInt(u64, fields.next() orelse return error.BadCorpus, 10);
    return sizes;
}

/// Each input's size over the recorded one, in the median, the 99th
/// percentile and the worst case, and which input that is.
fn report(w: *std.Io.Writer, ratios: []const f64, specs: []const []const u8) !void {
    var order: [4096]u16 = undefined;
    const sorted = order[0..ratios.len];
    for (sorted, 0..) |*o, i| o.* = @intCast(i);
    std.mem.sort(u16, sorted, ratios, struct {
        fn less(r: []const f64, a: u16, b: u16) bool {
            return r[a] < r[b];
        }
    }.less);
    const worst = sorted[sorted.len - 1];
    try w.print("  per input against the recorded size: median {d:.4} p99 {d:.4} worst {d:.4} ({s})\n", .{ ratios[sorted[sorted.len / 2]], ratios[sorted[sorted.len * 99 / 100]], ratios[worst], specs[worst] });
}

/// Transport compression changes no input: every decoded byte is hashed.
fn read(a: std.mem.Allocator, io: std.Io, file: File) ![]u8 {
    var compressed: std.ArrayList(u8) = .empty;
    for (file.parts) |part| {
        const piece = try std.Io.Dir.cwd().readFileAlloc(io, part, a, .unlimited);
        try compressed.appendSlice(a, piece);
    }
    const output = try a.alloc(u8, file.length);
    const decoder = try a.create(warp.zstd.Decompressor);
    decoder.* = .init;
    const result = try decoder.decompress(compressed.items, output, .{});
    if (result.in_len != compressed.items.len or result.out_len != output.len) return error.BadCorpus;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(output, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &hex, file.sha256)) return error.CorpusMismatch;
    return output;
}

/// The snapshot's objects retain their loose-object header and NUL.
fn objects(a: std.mem.Allocator, bytes: []const u8, inputs: *std.ArrayList([]const u8)) !void {
    var at: usize = 0;
    while (at < bytes.len) {
        const end = std.mem.findScalarPos(u8, bytes, at, '\n') orelse return error.BadCorpus;
        var fields = std.mem.splitScalar(u8, bytes[at..end], ' ');
        _ = fields.next() orelse return error.BadCorpus;
        const kind = fields.next() orelse return error.BadCorpus;
        const length = try std.fmt.parseInt(usize, fields.next() orelse return error.BadCorpus, 10);
        at = end + 1;
        if (length >= bytes.len - at or bytes[at + length] != '\n') return error.BadCorpus;
        try inputs.append(a, try a.print("{s} {d}\x00{s}", .{ kind, length, bytes[at..][0..length] }));
        at += length + 1;
    }
}
