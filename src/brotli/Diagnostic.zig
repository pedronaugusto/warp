//! Where a Brotli stream was refused, and why. Each reason is one of the
//! format reference's (google/brotli 1.2.1) `BROTLI_DECODER_ERROR_FORMAT_*`
//! refusals, named after what it refuses.

const aegis = @import("aegis");

/// The bit of the input at which the refused structure starts.
bit_offset: aegis.units.Bits(u64) = .fromRaw(0),
reason: Reason = .truncated,

pub const Reason = enum {
    /// The input ended inside the stream.
    truncated,
    /// A window size the format reserves, or a large-window stream without
    /// `large_window` (`WINDOW_BITS`).
    window_bits,
    /// A meta-block length's last nibble is zero where a shorter length
    /// would say the same (`EXUBERANT_NIBBLE`).
    exuberant_nibble,
    /// A metadata meta-block's reserved bit is set (`RESERVED`).
    reserved,
    /// A metadata length's last byte is zero (`EXUBERANT_META_NIBBLE`).
    exuberant_metadata,
    /// Bits skipped to a byte boundary are not zero, after an uncompressed
    /// or metadata header (`PADDING_1`) or at the stream's end
    /// (`PADDING_2`).
    padding,
    /// A simple prefix code names a symbol past its alphabet
    /// (`SIMPLE_HUFFMAN_ALPHABET`).
    simple_code_symbol,
    /// A simple prefix code names a symbol twice (`SIMPLE_HUFFMAN_SAME`).
    simple_code_repeat,
    /// The code length code's lengths do not form a complete code
    /// (`CL_SPACE`).
    code_length_space,
    /// A prefix code's lengths do not form a complete code, or a repeat
    /// runs past its alphabet (`HUFFMAN_SPACE`).
    code_space,
    /// A context map's run of zeros runs past its end
    /// (`CONTEXT_MAP_REPEAT`).
    context_map_repeat,
    /// A block count runs out where a category has only one block type
    /// (`BLOCK_SWITCH`).
    block_switch,
    /// A command's insert or copy runs past its meta-block
    /// (`BLOCK_LENGTH_1`, `BLOCK_LENGTH_2`).
    block_length,
    /// A distance past every reference, or a distance from the last ones
    /// that is not positive (`DISTANCE`).
    distance,
    /// A static dictionary reference of a length with no words
    /// (`DICTIONARY`).
    dictionary_word,
    /// A static dictionary reference past the transforms, or a transformed
    /// word that is empty (`TRANSFORM`).
    transform,
    /// A copy from the prefix dictionary that runs past its end
    /// (`COMPOUND_DICTIONARY`).
    prefix_dictionary,
};
