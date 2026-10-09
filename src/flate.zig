//! Raw DEFLATE, RFC 1950 and gzip, whole-buffer, streaming and parallel codecs.

const container = @import("container.zig");
const inflate = @import("inflate.zig");
const gzip_ = @import("gzip.zig");
const stream = @import("stream.zig");
const IndexType = @import("Index.zig");
const BgzfType = @import("Bgzf.zig");

/// The wrapper a compressor writes: raw DEFLATE, zlib or gzip.
pub const Container = container.Container;
/// What a decoder accepts, detection of zlib-or-raw and gzip-or-zlib included.
pub const Accept = container.Accept;
/// How many gzip members a decoder reads.
pub const Members = container.Members;
/// Where a stream was refused, and why.
pub const Diagnostic = @import("Diagnostic.zig");

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
