//! Huffman codes: decoding tables for the decoder, code lengths and
//! codewords for the encoder.

pub const decode = @import("huffman/decode.zig");
pub const encode = @import("huffman/encode.zig");

test {
    _ = decode;
    _ = encode;
}
