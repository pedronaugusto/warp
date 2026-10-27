//! Snappy and S2: Snappy's block format, and S2's, its extension (repeat
//! offsets, dictionaries, larger blocks). Every Snappy block is an S2 one,
//! so one decoder reads both; `format` says whose rules a block is read
//! by.
const block = @import("snappy/block.zig");
const emit = @import("snappy/emit.zig");

/// Where a block or stream was refused, and why.
pub const Diagnostic = @import("snappy/Diagnostic.zig");
/// Block compression with one parser, owning its tables.
pub const Compressor = @import("snappy/Compressor.zig");
/// The longest block `len` bytes compress to.
pub const blockBound = Compressor.bound;
/// An S2 dictionary: content blocks may copy from, and a repeat value.
pub const Dict = @import("snappy/Dict.zig");
/// Snappy's elements, or S2's.
pub const Format = block.Format;
/// The longest length a block declares.
pub const max_block_len = block.max_len;

pub const Error = block.Error || error{
    /// A dictionary with `format = .snappy`: dictionaries are S2's.
    InvalidOptions,
};

pub const DecompressOptions = struct {
    format: Format = .snappy,
    /// S2's dictionary (with `format = .s2`).
    dictionary: ?Dict = null,
    diagnostic: ?*Diagnostic = null,
};

/// The length the block `in` decodes to, from the varint it starts with.
pub fn decodedLen(in: []const u8, format: Format) error{ InvalidStream, Truncated }!usize {
    return (try block.header(in, format)).len;
}

/// Decode the block `in`, the whole of it, into `out` (at least
/// `decodedLen` bytes); the decoded length. Bytes of `out` past it may have
/// been written.
pub fn decompressBlock(in: []const u8, out: []u8, options: DecompressOptions) Error!usize {
    if (options.dictionary != null and options.format == .snappy) return error.InvalidOptions;
    return block.decode(in, out, .{ .format = options.format, .dictionary = options.dictionary, .diagnostic = options.diagnostic });
}

pub const ConcatError = error{
    /// A block whose length does not read as S2's varint.
    InvalidStream,
    Truncated,
    /// The blocks decode to more than a block's length holds.
    InputTooLarge,
    /// The output is shorter than `concatBound`.
    OutputTooSmall,
};

/// The bytes `concatBlocks` writes for `blocks`: their bodies and one
/// length.
pub fn concatBound(blocks: []const []const u8) ConcatError!usize {
    var total: u64 = 0;
    var bodies: usize = 0;
    for (blocks) |b| {
        const h = try block.header(b, .s2);
        total += h.len;
        bodies += b.len - h.size;
    }
    if (total == 0) return 1;
    if (total > block.max_len) return error.InputTooLarge;
    return 5 + bodies;
}

/// One block decoding to what `blocks` decode to one after another, as
/// S2's `ConcatBlocks` writes it: the sum of their lengths, then their
/// bodies (S2's first copy in a block is never a repeat, so a body reads
/// the same after another). The blocks are not validated; a total of
/// zero is the block `0`. The bytes written.
pub fn concatBlocks(blocks: []const []const u8, out: []u8) ConcatError!usize {
    if (out.len < try concatBound(blocks)) return error.OutputTooSmall;
    var total: u64 = 0;
    for (blocks) |b| total += (try block.header(b, .s2)).len;
    if (total == 0) {
        out[0] = 0;
        return 1;
    }
    var o = emit.length(out, 0, @intCast(total));
    for (blocks) |b| {
        const body = b[(try block.header(b, .s2)).size..];
        @memcpy(out[o..][0..body.len], body);
        o += body.len;
    }
    return o;
}

test {
    _ = block;
    _ = Dict;
    _ = @import("snappy/emit.zig");
    _ = @import("snappy/reference.zig");
    _ = @import("snappy/fast.zig");
    _ = @import("snappy/better.zig");
    _ = @import("snappy/best.zig");
}
