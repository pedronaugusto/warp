//! Dictionary training and entropy finalization. Temporary training memory
//! belongs to the allocator; the finished dictionary borrows only `out`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Dictionary = @import("Dictionary.zig");
const Encoder = @import("Encoder.zig");
const cover = @import("cover.zig");
const huffman = @import("huffman.zig");
const fse = @import("fse.zig");
const codes = @import("codes.zig");
const params = @import("params.zig");

pub const Options = struct {
    algorithm: enum { fast_cover, cover } = .fast_cover,
    k: ?u32 = null,
    d: ?u32 = null,
    steps: u32 = 40,
    level: i32 = params.default_level,
    id: ?u32 = null,
};
pub const TrainError = Allocator.Error || error{ InvalidParameters, NotEnoughSamples, OutputTooSmall };
const header_reserve = 512;

fn validate(samples: []const []const u8, out: []u8, options: Options) TrainError!void {
    if (out.len <= header_reserve) return error.OutputTooSmall;
    if (options.steps == 0 or options.steps > 1000) return error.InvalidParameters;
    if (options.d) |d| if (d < 4 or d > 8) return error.InvalidParameters;
    if (options.k) |k| if (k < (options.d orelse 8) or k > out.len) return error.InvalidParameters;
    if (options.id) |id| if (id == 0) return error.InvalidParameters;
    var total: usize = 0;
    for (samples) |sample| total = std.math.add(usize, total, sample.len) catch return error.InvalidParameters;
    if (total < 8 or total > std.math.maxInt(u32) / 2) return error.NotEnoughSamples;
}

/// Train at most `out.len` bytes. Null d/k search d-mers of 6 and 8 bytes
/// and segment sizes from 50 to 2000; held-out samples choose the result.
pub fn train(gpa: Allocator, samples: []const []const u8, out: []u8, options: Options) TrainError!usize {
    try validate(samples, out, options);
    const content = try gpa.alloc(u8, out.len - header_reserve);
    defer gpa.free(content);
    const candidate = try gpa.alloc(u8, out.len);
    defer gpa.free(candidate);
    const split = if (samples.len >= 10) samples.len * 4 / 5 else samples.len;
    const training = samples[0..split];
    const validation = if (split < samples.len) samples[split..] else samples;
    var best_size: usize = std.math.maxInt(usize);
    var best_len: usize = 0;
    const ds = [_]u32{ options.d orelse 6, options.d orelse 8 };
    for (ds, 0..) |d, i| {
        if (i != 0 and ds[0] == ds[1]) break;
        var model = try cover.Model.init(gpa, training, d, options.algorithm == .cover);
        defer model.deinit(gpa);
        const steps = if (options.k != null) 1 else options.steps;
        for (0..steps) |step| {
            const low: usize = @min(50, content.len);
            const high: usize = @min(2000, content.len);
            const k = @max(d, options.k orelse low + (high - low) * step / @max(steps - 1, 1));
            const selected = model.select(content, k);
            if (selected == 0) continue;
            const n = try finalize(gpa, content[0..selected], training, candidate, options);
            const score = try compressedSize(gpa, candidate[0..n], validation, options.level);
            if (score < best_size) {
                best_size = score;
                best_len = n;
                @memcpy(out[0..n], candidate[0..n]);
            }
        }
    }
    if (best_len == 0) return error.NotEnoughSamples;
    return best_len;
}

fn compressedSize(gpa: Allocator, bytes: []const u8, samples: []const []const u8, level: i32) TrainError!usize {
    const dictionary = try gpa.create(Dictionary);
    defer gpa.destroy(dictionary);
    dictionary.* = Dictionary.parse(bytes) catch return error.InvalidParameters;
    var largest: usize = 0;
    for (samples) |sample| largest = @max(largest, sample.len);
    var encoder = try Encoder.init(gpa, .{ .dictionary = dictionary, .level = level, .max_input = largest });
    defer encoder.deinit();
    const out = try gpa.alloc(u8, Encoder.bound(largest));
    defer gpa.free(out);
    var size: usize = 0;
    for (samples) |sample| size += encoder.compress(sample, out, .{ .checksum = false }) catch return error.OutputTooSmall;
    return size;
}

const Stats = struct {
    literals: [256]u32 = @splat(1),
    ll: [codes.max_ll + 1]u32 = @splat(1),
    of: [codes.max_of + 1]u32 = @splat(1),
    ml: [codes.max_ml + 1]u32 = @splat(1),

    fn collect(stats: *Stats, encoder: *Encoder, samples: []const []const u8) void {
        // A slight prior avoids an unrepresentable all-equal weight table.
        stats.literals[0] += 1;
        for (samples) |sample| {
            var at: usize = 0;
            while (at < sample.len) {
                const len = @min(128 << 10, sample.len - at);
                encoder.analyze(sample[at..][0..len]);
                const store = &encoder.store;
                for (store.lits[0..store.lit_len]) |literal| stats.literals[literal] += 1;
                for (store.seqs[0..store.count], 0..) |q, i| {
                    stats.ll[codes.llCode(store.litLen(i))] += 1;
                    stats.ml[codes.mlCode(store.matchLen(i) + 3)] += 1;
                    stats.of[codes.ofCode(q.off)] += 1;
                }
                at += len;
            }
        }
    }
};

/// Add encoding entropy, repeat offsets and an ID to dictionary content.
/// If it does not all fit, the content's tail is retained. `content` and
/// `out` may overlap: the content is moved before the header is written.
pub fn finalize(gpa: Allocator, content: []const u8, samples: []const []const u8, out: []u8, options: Options) TrainError!usize {
    try validate(samples, out, options);
    if (content.len == 0) return error.InvalidParameters;
    const raw = Dictionary.raw(content);
    var encoder = try Encoder.init(gpa, .{ .dictionary = &raw, .level = options.level, .max_input = 128 << 10 });
    defer encoder.deinit();
    var stats: Stats = .{};
    stats.collect(&encoder, samples);
    scale(&stats.literals);
    scale(&stats.ll);
    scale(&stats.ml);
    scale(&stats.of);
    var header: [header_reserve]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], Dictionary.magic, .little);
    var table: huffman.EncodeTable = undefined;
    table.build(&stats.literals, huffman.encode_log);
    var at = 8 + (table.writeDescription(header[8..]) orelse return error.InvalidParameters);
    at += try writeDistribution(header[at..], &stats.of, codes.max_of_log);
    at += try writeDistribution(header[at..], &stats.ml, codes.max_ml_log);
    at += try writeDistribution(header[at..], &stats.ll, codes.max_ll_log);
    const len = @min(content.len, out.len - at - 12);
    if (len == 0) return error.OutputTooSmall;
    const tail = content[content.len - len ..];
    const id = options.id orelse @as(u32, @intCast(32768 + std.hash.XxHash64.hash(0, tail) % (0x7fff_ffff - 32768)));
    std.mem.writeInt(u32, header[4..8], id, .little);
    for ([_]u32{ 1, 4, 8 }) |rep| {
        std.mem.writeInt(u32, header[at..][0..4], @intCast(@min(rep, len)), .little);
        at += 4;
    }
    @memmove(out[at..][0..len], tail);
    @memcpy(out[0..at], header[0..at]);
    return at + len;
}

fn writeDistribution(out: []u8, counts: []const u32, log: u4) TrainError!usize {
    var norm: [64]i16 = undefined;
    var total: usize = 0;
    for (counts) |count| total += count;
    const used = norm[0..counts.len];
    fse.normalize(used, log, counts, total, false) catch return error.InvalidParameters;
    std.debug.assert(out.len >= fse.countsBound(@intCast(counts.len - 1), log));
    return fse.writeCounts(out, used, log);
}

fn scale(counts: []u32) void {
    var total: u64 = 0;
    for (counts) |count| total += count;
    while (total > 1 << 24) {
        total = 0;
        for (counts) |*count| {
            count.* = (count.* >> 1) + 1;
            total += count.*;
        }
    }
}
