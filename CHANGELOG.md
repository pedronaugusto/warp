# Changelog

All notable changes to warp are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `Decompressor`: whole-buffer decoding of raw DEFLATE, zlib and gzip (every
  member, or one), from memory or a `std.Io.Reader`, with dictionaries, partial
  output, and the reason and bit offset of every refusal.
- `Compressor`: whole-buffer compression at levels 0 to 12, with
  zlib's strategies, dictionaries and gzip headers, in allocated or given memory.
- CRC-32, CRC-32C and Adler-32, running and combined, on folding, CRC32, UDOT
  and AVX2 kernels chosen at run time.
- `gzip.parseHeader` and `gzip.writeHeader` for every header field.

- Near-optimal parsing at levels 10-12, with a configurable pass budget.
- Streaming `Inflate` and `Deflate`, Reader/Writer adapters, every flush mode,
  8-15 bit windows, level changes and retained-history resets.
- Deterministic parallel compression, validated portable seek indexes and
  parallel indexed decompression.
- Raw Deflate64 decoding and the BGZF writer with virtual offsets.
- Optional zlib C stream ABI, a host build helper for compressed assets,
  and a compression CLI example.

### Fixed

- Explicitly disabling CRC in the target CPU no longer prevents checksum
  kernel modules from assembling; an AArch64 cross-build checks this.
- Near-optimal streaming blocks retain their source bytes across small-window
  slides, and changing level preserves the requested optimization passes.
- Short near-optimal flushes verify prefixes again when more input follows;
  Huffman-only and RLE streams at high levels need no optimal-parser storage.
- C compression bounds include custom gzip headers and small windows, and
  convenience calls report the bytes consumed on short output buffers.

[Unreleased]: https://github.com/pedronaugusto/warp/commits/main
