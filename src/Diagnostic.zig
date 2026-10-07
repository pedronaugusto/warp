//! Where a stream was refused, and why.

const Diagnostic = @This();

/// The bit of the input at which the stream was refused, counted from the
/// first bit of the input given (least significant bit first in each byte).
bit_offset: u64 = 0,
reason: Reason = .truncated,

pub const Reason = enum {
    /// The input ended inside the stream.
    truncated,
    /// A zlib header that is not one: method other than 8, window over
    /// 32 KiB, or a check that fails.
    bad_zlib_header,
    /// Not a gzip member: magic or method.
    bad_gzip_header,
    /// gzip flag bits 5-7 set.
    reserved_flags,
    /// The gzip header's CRC-16 is not its bytes'.
    header_crc,
    /// A zlib stream names a dictionary and none was given.
    dictionary_required,
    /// A zlib stream names a dictionary other than the one given.
    dictionary_mismatch,
    /// Block type 3.
    bad_block_type,
    /// A stored block's length and its complement disagree.
    stored_length,
    /// More than 286 litlen or 30 distance codes.
    too_many_codes,
    /// A code-length repeat with nothing to repeat, or past the last length.
    bad_code_lengths,
    /// A code with fewer codes than its lengths allow (other than the one
    /// zlib accepts: a single one-bit literal/length or distance code).
    incomplete_code,
    /// A code with more codes than its lengths allow.
    oversubscribed_code,
    /// No code for the end of a block.
    no_end_code,
    /// A codeword with no symbol, or a symbol the format does not use in
    /// data (litlen 286-287, distance 30-31).
    bad_symbol,
    /// A distance reaching before the output and the dictionary.
    distance_too_far,
    /// A distance past the window a streaming decoder keeps.
    window_exceeded,
    /// The zlib trailer is not the output's Adler-32.
    adler32,
    /// The gzip trailer is not the output's CRC-32.
    crc32,
    /// The gzip trailer is not the output's length modulo 2^32.
    size,
    /// Bytes after a gzip member that do not start another.
    trailing_data,
};
