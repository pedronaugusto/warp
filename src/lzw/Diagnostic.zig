//! Where an LZW stream was refused, and why.

const aegis = @import("aegis");

/// For `bad_code`, the byte of the input holding the refused code's last
/// bit; for `truncated`, the input through the byte holding the last bit
/// of the last code read whole, as Wuffs counts what it read (the bits
/// after it are short of a code).
offset: aegis.units.Bytes(u64) = .fromRaw(0),
/// The bytes decoded before the refusal: every code before the refused one
/// is decoded and handed out, as the reference hands them out.
output: aegis.units.Bytes(u64) = .fromRaw(0),
reason: Reason = .truncated,

pub const Reason = enum {
    /// A code past the next one the table would add: only a code the
    /// table holds, the one it adds next, a literal, clear or end is read.
    bad_code,
    /// The input ends before the end code.
    truncated,
};
