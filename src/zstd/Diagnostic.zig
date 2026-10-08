//! Where a zstd frame was refused, and why.

const Diagnostic = @This();

/// The byte of the input at which the refused structure starts (a frame
/// header, a block, a literals or sequences section).
offset: u64 = 0,
reason: Reason = .truncated,

pub const Reason = enum {
    /// The input ended inside a frame.
    truncated,
    /// Not a zstd frame or a skippable one.
    bad_magic,
    /// The frame header's reserved bit is set.
    reserved_bit,
    /// The frame's window is larger than the decoder allows.
    window_too_large,
    /// The frame names a dictionary that was not given.
    dictionary_mismatch,
    /// Block type 3.
    bad_block_type,
    /// A compressed block larger than the frame allows.
    block_too_large,
    /// A literals section header that does not fit its block, or four
    /// streams for fewer than six literals.
    bad_literals_header,
    /// A Huffman tree description that does not form a code.
    bad_huffman_weights,
    /// Literals that reuse a Huffman table when none came before.
    treeless_first,
    /// Huffman-coded literals that do not decode to their declared size.
    literals_size,
    /// A sequences section header that does not fit its block, or with
    /// its reserved bits set.
    bad_sequences_header,
    /// An FSE table description that breaks the format's rules.
    bad_fse_table,
    /// A repeated FSE table when no table came before.
    repeat_first,
    /// An offset before the frame's start and its dictionary, or a repeat
    /// offset of zero.
    bad_offset,
    /// A sequence taking more literals than the section has.
    bad_length,
    /// The sequences' bitstream does not end where the last sequence does.
    bitstream_left,
    /// The frame decodes to another size than its header says.
    content_size,
    /// The content checksum is not the content's.
    checksum,
    /// Bytes after a frame that start no frame.
    trailing_data,
    /// A dictionary that is not one (`Dictionary.parse`).
    bad_dictionary,
};
