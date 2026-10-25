//! Where a GDeflate page or tile stream was refused, and why.

const aegis = @import("aegis");

/// The tile whose page was refused (0 for a page decoded alone, or for the
/// tile stream's header).
tile: u32 = 0,
/// The byte of the input at which it was refused: a header field, or the
/// end of the last word a lane of the page loaded.
offset: aegis.units.Bytes(u64) = .fromRaw(0),
reason: Reason = .truncated,

pub const Reason = enum {
    /// The input ended inside the tile stream's header, its offsets or a
    /// page: a lane needed a word past the page's end.
    truncated,
    /// A tile stream whose first byte is not GDeflate's codec ID (4), or
    /// whose second is not its complement.
    bad_magic,
    /// A tile size other than 64 KiB (`tileSizeIdx` other than 1), or a
    /// last tile's size past it.
    bad_tile_size,
    /// Tile offsets out of order, or a tile past the input's end.
    bad_tile_offsets,
    /// A tile's page that decodes to another length than the tile's: 64
    /// KiB, or the last tile's size.
    tile_length,
    /// Block type 3.
    bad_block_type,
    /// More than 286 litlen codes.
    too_many_codes,
    /// A code-length repeat with nothing to repeat, or past the last length.
    bad_code_lengths,
    /// A code with fewer codes than its lengths allow (other than a single
    /// one-bit code, which zlib accepts).
    incomplete_code,
    /// A code with more codes than its lengths allow.
    oversubscribed_code,
    /// No code for the end of a block.
    no_end_code,
    /// A codeword with no symbol, or a litlen symbol the format does not use
    /// in data (286-287).
    bad_symbol,
    /// A distance reaching before the page's first byte.
    distance_too_far,
};
