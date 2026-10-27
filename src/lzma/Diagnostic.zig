//! Where a stream was refused, and why: the byte offset of the part that
//! breaks it (of the coder's symbol for LZMA data) and the check, one per
//! check liblzma 5.8.4 makes.

const aegis = @import("aegis");

pub const Reason = enum {
    /// The input ends inside a stream.
    truncated,

    // LZMA data.
    /// The properties byte: past 224, or lc + lp past 4.
    properties,
    /// The range coder's first byte is not zero.
    range_start,
    /// A distance past the bytes decoded since the dictionary's reset, or
    /// past the dictionary.
    distance,
    /// The known size is reached and the coder is not done, with no end
    /// marker allowed; or a symbol other than the marker follows.
    size_without_end,
    /// An end marker where none may be: in LZMA2, or before the known size.
    marker_not_allowed,
    /// The coder is not done after the end marker.
    end_not_finished,
    /// A match runs past the known size.
    past_size,

    // LZMA2 chunks.
    /// A control byte 0x03-0x7f.
    control,
    /// The first chunk, or the one after a dictionary reset, does not
    /// reset the dictionary.
    dictionary_reset,
    /// An LZMA chunk without new properties where they are needed.
    properties_needed,
    /// An LZMA chunk's data is not its declared compressed size.
    chunk_size,

    // .lzma.
    /// The size is past 2^38 (picky reading only; liblzma's
    /// `lzma_alone_decoder` takes any).
    alone_header,

    // .xz.
    /// The stream header's magic.
    stream_magic,
    /// Stream flags with reserved bits set.
    stream_flags,
    /// The stream header's CRC.
    stream_header_crc,
    /// A block header's CRC.
    block_header_crc,
    /// A block header with reserved bits, padding not zero, or sizes or
    /// filters out of range.
    block_header,
    /// A filter warp does not read.
    unsupported_filter,
    /// A filter chain out of order or a filter's properties out of range.
    filter_options,
    /// A block's sizes against its header's or its index record's.
    block_size,
    /// A block's padding not zero.
    block_padding,
    /// A block's check.
    check,
    /// The index: its indicator, records, padding or sizes.
    index,
    /// The index's CRC.
    index_crc,
    /// The stream footer's CRC.
    footer_crc,
    /// The footer's backward size against the index's.
    backward_size,
    /// The footer's flags against the header's.
    footer_flags,
    /// The footer's magic.
    footer_magic,
    /// Stream padding not a multiple of four, or bytes after the streams.
    stream_padding,
    /// A dictionary past the memory limit.
    memory_limit,
};

/// The byte the refused part starts at.
offset: aegis.units.Bytes(u64) = .fromRaw(0),
reason: Reason = .truncated,
