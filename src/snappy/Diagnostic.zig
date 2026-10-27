//! Where a Snappy or S2 block or stream was refused, and why.

const aegis = @import("aegis");

/// The byte of the input at which the refused structure starts: the
/// block's length, an element (a literal or a copy), a chunk, or a
/// checksum.
offset: aegis.units.Bytes(u64) = .fromRaw(0),
reason: Reason = .truncated,

pub const Reason = enum {
    /// The input ended inside the block's length, an element or a chunk,
    /// or before the block's output was all there.
    truncated,
    /// The block's length is not a varint of at most five bytes, or passes
    /// 2^32 - 1.
    bad_length,
    /// An element writes past the length the block declares.
    too_long,
    /// A copy of offset 0 in Snappy, or by copy-2 or copy-4 in S2.
    zero_offset,
    /// An S2 repeat before any copy has set an offset (and with no
    /// dictionary to give one).
    no_repeat_offset,
    /// A copy reaching before the output (and the dictionary).
    offset_too_far,
    /// A copy from the dictionary after the first 64 KiB of output, or
    /// running from it into the output.
    dictionary_copy,
    /// Bytes after the block's last element.
    trailing_data,
    /// A stream's first chunk is not its identifier.
    no_identifier,
    /// An identifier chunk of another length or name.
    bad_identifier,
    /// A data chunk shorter than its checksum, or longer than a block of
    /// the largest size and its bound.
    bad_chunk_length,
    /// A block past the stream's largest: 64 KiB after a Snappy
    /// identifier, `max_block_size` in any.
    block_too_large,
    /// A chunk type the format reserves and does not let a reader skip.
    reserved_chunk,
    /// A data chunk's checksum is not its data's.
    checksum,
};
