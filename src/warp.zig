//! DEFLATE, zlib, gzip and zstd: compression and decompression; CRC-32, CRC-32C
//! and Adler-32.

const checksum = @import("checksum.zig");
const container = @import("container.zig");
const inflate = @import("inflate.zig");
const gzip_ = @import("gzip.zig");
const stream = @import("stream.zig");
const IndexType = @import("Index.zig");
const BgzfType = @import("Bgzf.zig");

/// Zstandard frames, dictionaries, compression and decompression.
pub const zstd = @import("zstd.zig");

/// The wrapper a compressor writes: raw DEFLATE, zlib or gzip.
pub const Container = container.Container;
/// What a decoder accepts, detection of zlib-or-raw and gzip-or-zlib included.
pub const Accept = container.Accept;
/// How many gzip members a decoder reads.
pub const Members = container.Members;
/// Where a stream was refused, and why.
pub const Diagnostic = @import("Diagnostic.zig");

/// A running CRC-32 (gzip's, zip's and PNG's).
pub const Crc32 = checksum.Crc32;
/// zlib's `crc32(crc, buf, len)`: `crc` continued over the bytes.
pub const crc32 = checksum.crc32;
/// The CRC-32 of A ++ B from those of A and B and B's length.
pub const crc32Combine = checksum.crc32Combine;
/// A running CRC-32C (iSCSI's, ext4's and many storage formats').
pub const Crc32c = checksum.Crc32c;
/// `crc` continued over the bytes, as `crc32` continues a CRC-32.
pub const crc32c = checksum.crc32c;
/// The CRC-32C of A ++ B from those of A and B and B's length.
pub const crc32cCombine = checksum.crc32cCombine;
/// A running Adler-32 (zlib's).
pub const Adler32 = checksum.Adler32;
/// zlib's `adler32(adler, buf, len)`: `adler` continued over the bytes.
pub const adler32 = checksum.adler32;
/// The Adler-32 of A ++ B from those of A and B and B's length.
pub const adler32Combine = checksum.adler32Combine;
/// Which kernel each checksum runs on this CPU.
pub const kernels = checksum.kernels;
/// The kernel of each checksum.
pub const Kernels = checksum.Kernels;
/// A checksum kernel.
pub const Kernel = checksum.Kernel;

/// Whole-buffer decoding of raw DEFLATE, zlib and gzip.
pub const Decompressor = @import("Decompressor.zig");
/// Whole-buffer compression to raw DEFLATE, zlib or gzip.
pub const Compressor = @import("Compressor.zig");
/// Streaming decoding of raw DEFLATE, zlib and gzip, and its
/// `std.Io.Reader`.
pub const Inflate = stream.Inflate;
/// Streaming compression to raw DEFLATE, zlib or gzip, with flushes, and
/// its `std.Io.Writer`.
pub const Deflate = stream.Deflate;
/// How a streaming compressor's flush ends what is written so far.
pub const Flush = Deflate.Flush;
/// How matches are chosen, beside the level: zlib's strategies.
pub const Strategy = Compressor.Strategy;
/// Spare output room past the expected length that lets the decoder's fast
/// loop run to the end of a stream: the longest match plus one vector store.
pub const inflate_margin = inflate.margin;

/// gzip member headers.
pub const gzip = struct {
    /// A member header's fields.
    pub const Header = gzip_.Header;
    /// Validated restart points for seeking and parallel decoding.
    pub const Index = IndexType;
    /// The blocked gzip writer and its virtual offsets.
    pub const Bgzf = BgzfType;
    /// Why a header was not read.
    pub const ParseError = gzip_.ParseError;
    /// A header and its length.
    pub const Parsed = gzip_.Parsed;
    /// The member header at the start of the input.
    pub const parseHeader = gzip_.parseHeader;
    /// Write a member header.
    pub const writeHeader = gzip_.writeHeader;
    /// Where a streaming decoder copies a member header's fields.
    pub const Fields = gzip_.Fields;
};

/// Compression and decompression over ordered chunks.
pub const parallel = @import("parallel.zig");

/// Zip method 9 decoding with the extended alphabet and 64 KiB window.
pub const deflate64 = @import("deflate64.zig");
