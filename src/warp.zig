//! DEFLATE, zlib, gzip, zstd, LZ4 and Brotli: compression and decompression;
//! bzip2 decompression; GDeflate compression and decompression on the CPU;
//! CRC-32, CRC-32C, Adler-32 and bzip2's CRC-32.

const checksum = @import("checksum.zig");
const flate = @import("flate.zig");

/// Zstandard frames, dictionaries, compression and decompression.
pub const zstd = @import("zstd.zig");

/// LZ4 blocks and frames, compression at lz4's levels and decompression.
pub const lz4 = @import("lz4.zig");
/// Brotli streams, compression and decompression.
pub const brotli = @import("brotli.zig");
/// bzip2 streams, decompression.
pub const bzip2 = @import("bzip2.zig");
/// LZMA and LZMA2 raw streams and `.lzma` files.
pub const lzma = @import("lzma.zig");
/// `.xz` streams.
pub const xz = @import("xz.zig");
/// Snappy and S2 blocks.
pub const snappy = @import("snappy.zig");
/// GDeflate pages and DirectStorage tile streams, compressed at DEFLATE's levels
/// and decoded on the CPU.
pub const gdeflate = @import("gdeflate.zig");

/// The wrapper a compressor writes: raw DEFLATE, zlib or gzip.
pub const Container = flate.Container;
/// What a decoder accepts, detection of zlib-or-raw and gzip-or-zlib included.
pub const Accept = flate.Accept;
/// How many gzip members a decoder reads.
pub const Members = flate.Members;
/// Where a stream was refused, and why.
pub const Diagnostic = flate.Diagnostic;

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
/// bzip2's CRC-32 (MSB first), the check of its blocks.
pub const Crc32Bzip2 = checksum.Crc32Bzip2;
/// `crc` continued over the bytes; 0 starts one.
pub const crc32Bzip2 = checksum.crc32Bzip2;
/// xz's CRC-64 (ECMA-182, reflected), the check its streams name 0x04.
pub const Crc64Xz = checksum.Crc64Xz;
/// `crc` continued over the bytes; 0 starts one.
pub const crc64Xz = checksum.crc64Xz;
/// Which kernel each checksum runs on this CPU.
pub const kernels = checksum.kernels;
/// The kernel of each checksum.
pub const Kernels = checksum.Kernels;
/// A checksum kernel.
pub const Kernel = checksum.Kernel;

/// Whole-buffer decoding of raw DEFLATE, zlib and gzip.
pub const Decompressor = flate.Decompressor;
/// Whole-buffer compression to raw DEFLATE, zlib or gzip.
pub const Compressor = flate.Compressor;
/// Streaming decoding of raw DEFLATE, zlib and gzip, and its
/// `std.Io.Reader`.
pub const Inflate = flate.Inflate;
/// Streaming compression to raw DEFLATE, zlib or gzip, with flushes, and
/// its `std.Io.Writer`.
pub const Deflate = flate.Deflate;
/// How a streaming compressor's flush ends what is written so far.
pub const Flush = flate.Flush;
/// How matches are chosen, beside the level: zlib's strategies.
pub const Strategy = flate.Strategy;
/// Spare output room past the expected length that lets the decoder's fast
/// loop run to the end of a stream: the longest match plus one vector store.
pub const inflate_margin = flate.inflate_margin;

/// gzip member headers.
pub const gzip = flate.gzip;

/// Compression and decompression over ordered chunks.
pub const parallel = flate.parallel;

/// Zip method 9 decoding with the extended alphabet and 64 KiB window.
pub const deflate64 = flate.deflate64;
