//! Where an LZ4 block or frame was refused, and why.

const aegis = @import("aegis");

/// The byte of the input at which the refused structure starts: a
/// sequence, a frame header, a block header or a checksum.
offset: aegis.units.Bytes(u64) = .fromRaw(0),
reason: Reason = .truncated,

pub const Reason = enum {
    /// The input ended inside a sequence, before a block's last sequence,
    /// or inside a frame.
    truncated,
    /// A match offset of zero, which the format does not define.
    zero_offset,
    /// A match reaching before the output and its history.
    offset_too_far,
    /// A literal or match length past what the target's lengths hold.
    length_overflow,
    /// Not an LZ4 frame, a legacy frame or a skippable frame.
    bad_magic,
    /// A frame descriptor whose version is not 01.
    bad_version,
    /// A frame descriptor with a reserved bit set.
    reserved_bits,
    /// A block maximum size the format does not define.
    bad_block_size,
    /// The descriptor's checksum byte is not its contents'.
    header_checksum,
    /// A block larger than the frame's maximum block size.
    block_too_large,
    /// A block checksum that is not the block's.
    block_checksum,
    /// The content checksum is not the content's.
    content_checksum,
    /// The frame decodes to another size than its descriptor says.
    content_size,
    /// The frame names a dictionary other than the one given, or one when
    /// none was given.
    dictionary_mismatch,
    /// Bytes after a frame that start no frame.
    trailing_data,
};
