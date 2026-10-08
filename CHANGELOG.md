# Changelog

All notable changes to warp are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added

- `zstd`: whole-buffer compression at levels −131072 through 22, with all
  nine search strategies, adaptive optimal parsing, and block splitting.
  Decoder support includes dictionaries, checksums, concatenated, skippable
  and magicless frames, reader input, partial output and diagnostics.
  Frame inspection and caller-provided compressor storage are available.
- `zstd.Compress` and `zstd.Decompress`: resumable encoding and decoding,
  flush and end-of-input checks, pledged sizes, and `std.Io` writer and
  reader adapters over the same codec engines.
- Bound raw and formatted dictionaries on both encoders, with immutable match
  indexes and encoding entropy; dictionary IDs can be suppressed for prefixes.
  `zstd.train` selects dictionary content by hashed or exact coverage, searches
  segment parameters and finalizes supplied content into a formatted dictionary.
- Sparse long-distance matching on whole-buffer and streaming encoders,
  with a configurable window and deterministic bucket selection across frames.
- `zstd.Compress.Options.target_block_size`: partitions parsed superblocks by
  encoded cost, cuts long literal runs and preserves match and repeat histories.
- `zstd.parallel.Decompressor`: entropy workers with ordered match execution
  and checksums, caller storage and cancellation.
- `zstd.parallel`: ordered compression jobs in one frame, overlap priming,
  rsyncable cuts, reader input and output independent of concurrency.
- `zstd.seekable`: independent-frame output, seek-table validation, frame
  indexing and range reads, with caller storage and checksum verification.
- `Decompressor`: whole-buffer decoding of raw DEFLATE, zlib and gzip (every
  member, or one), from memory or a `std.Io.Reader`, with dictionaries, partial
  output, and the reason and bit offset of every refusal.
- `Compressor`: whole-buffer compression at levels 0 to 9 (10 to 12 as 9), with
  zlib's strategies, dictionaries and gzip headers, in allocated or given memory.
- CRC-32, CRC-32C and Adler-32, running and combined, on folding, CRC32, UDOT
  and AVX2 kernels chosen at run time.
- `gzip.parseHeader` and `gzip.writeHeader` for every header field.

[Unreleased]: https://github.com/pedronaugusto/warp/commits/main
