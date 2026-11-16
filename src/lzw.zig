//! LZW decoding, GIF's variant only: codes least significant bit first from
//! a minimum code size, with clear and end codes, to at most 12 bits.
//! Acceptance is Wuffs's (`std/lzw`, 0.4.0-alpha.12). TIFF's and
//! compress(1)'s variants (most significant bit first, early change) wait
//! for a consumer.
//!
//! A GIF's image data is its minimum code size, then the LZW stream in
//! sub-blocks of at most 255 bytes; the caller takes the sub-blocks apart
//! and hands their bytes to `Decompress.decode` in any pieces.

/// Where a stream was refused, and why.
pub const Diagnostic = @import("lzw/Diagnostic.zig");
/// Resumable decoding: input and output in pieces of any size.
pub const Decompress = @import("lzw/Decompress.zig");

pub const Options = Decompress.Options;
/// The widest literal width, GIF's largest minimum code size.
pub const max_literal_width = Decompress.max_literal_width;

pub const Error = Decompress.Error || Decompress.InitError || error{
    /// The stream decodes to more than the output holds.
    OutputTooSmall,
};

/// What `decompress` read and wrote.
pub const Result = struct {
    /// The input through the byte holding the end code's last bit.
    in_len: usize,
    out_len: usize,
};

/// Decode the stream at the start of `in`, through its end code, into `out`.
/// Bytes after the end code are not read. A stream that decodes to more
/// than `out` holds is `OutputTooSmall`, with `out` full of its first bytes.
pub fn decompress(in: []const u8, out: []u8, options: Options) Error!Result {
    var d: Decompress = try .init(options);
    const step = try d.decode(in, out);
    switch (step.status) {
        .end => return .{ .in_len = step.in_len, .out_len = step.out_len },
        .output_full => return error.OutputTooSmall,
        .need_input => {
            try d.finish();
            return error.Truncated;
        },
    }
}

test {
    _ = Decompress;
}
