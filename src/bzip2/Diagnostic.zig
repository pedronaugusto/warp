//! Where a bzip2 stream was refused, and why. Each reason is one of the
//! format reference's (libbz2 1.0.8) refusals, named after what it refuses.

const aegis = @import("aegis");

/// The bit of the input at which the refused structure starts.
bit_offset: aegis.units.Bits(u64) = .fromRaw(0),
reason: Reason = .truncated,

pub const Reason = enum {
    /// The input ended inside the stream.
    truncated,
    /// The stream does not start with `BZh` (`BZ_DATA_ERROR_MAGIC`).
    bad_magic,
    /// The block size is not 1-9 (`BZ_DATA_ERROR_MAGIC`).
    bad_level,
    /// A block starts with neither the block nor the end magic.
    bad_block_magic,
    /// The BWT's start lies past the block.
    orig_ptr,
    /// No byte value is in use.
    no_symbols,
    /// Fewer than 2 or more than 6 code tables.
    groups,
    /// No selectors.
    no_selectors,
    /// A selector names a table past the last.
    selector,
    /// A code length leaves 1-20.
    code_length,
    /// A codeword longer than 20 bits, or one past the alphabet.
    bad_code,
    /// More code groups than selectors.
    selectors_exhausted,
    /// A run longer than the format allows.
    run_too_long,
    /// The block holds more than its size.
    block_too_large,
    /// The block ends where a run's count should be.
    corrupt,
    /// The block's output fails its CRC.
    block_crc,
    /// The stream's combined CRC fails.
    stream_crc,
};
