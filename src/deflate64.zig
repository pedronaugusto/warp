//! Zip method 9's extended DEFLATE alphabet: a 64 KiB history and
//! three-to-65,538-byte matches. It uses the shared table builder and engine.
const engine = @import("inflate.zig");
const Diagnostic = @import("Diagnostic.zig");

pub const Decompressor = struct {
    tables: engine.TablesFor(true) = .{},
    pub const init: Decompressor = .{};
    pub const Options = struct {
        dictionary: []const u8 = &.{},
        partial: bool = false,
        diagnostic: ?*Diagnostic = null,
    };
    pub const Result = struct { in_len: usize, out_len: usize, finished: bool };
    pub const InflateError = engine.Error;

    pub fn inflate(d: *Decompressor, in: []const u8, out: []u8, options: Options) InflateError!Result {
        var stream: engine.Stream = .{
            .in = in,
            .ip = 0,
            .out = out,
            .op = 0,
            .start = 0,
            .window = 65536,
            .partial = options.partial,
            .history = .{ .newer = options.dictionary[options.dictionary.len -| 65536..] },
            .diagnostic = options.diagnostic,
        };
        var state: engine.State = .{};
        while (true) switch (try engine.decode(&d.tables, &stream, engine.no_more, &state)) {
            .block_end => {},
            .done => return .{ .in_len = stream.ip - stream.bitsleft / 8, .out_len = stream.op, .finished = true },
            .output_full => return .{ .in_len = stream.ip - stream.bitsleft / 8, .out_len = stream.op, .finished = false },
        };
    }
};
