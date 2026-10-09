# Changelog

All notable changes to warp are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Changed

- Keep whole-input DEFLATE parsing in its cursor across block boundaries and
  specialize full-window search and decoding bounds. Keep whole-input counts
  and one input bound local to dispatch, and group lazy lookahead. Streaming
  retains its resumable boundaries and smaller-window validation. Decode
  header progress stays local within a call and is saved on every return.
  Optimal-parser scratch stays outside lower-level dispatch; byte and marker
  outputs share the fast loop’s existing stream argument.

### Added

- A deterministic per-level size gate over fixed, hashed standard input snapshots.
- Shared fast Huffman decoding for symbolic history and branchless history resolution.

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
  segment parameters and finalizes supplied content into a formatted dictionary
  with entropy tables and repeat offsets learned from the samples.
- Sparse long-distance matching on whole-buffer and streaming encoders,
  with a configurable window and deterministic bucket selection across frames.
- `zstd.Compress.Options.target_block_size`: partitions parsed superblocks by
  encoded cost, cuts long literal runs and preserves match and repeat histories.
- `zstd.parallel.Decompressor`: entropy workers with ordered match execution
  and checksums, caller storage and cancellation.
- `zstd.parallel`: ordered compression jobs in one frame, overlap priming,
  rsyncable cuts, reader input and output independent of concurrency;
  parallel independent-frame writers with a bounded seek table.
- `zstd.seekable`: independent-frame output, seek-table validation, frame
  indexing and range reads, with caller storage and checksum verification.
- `Decompressor`: whole-buffer decoding of raw DEFLATE, zlib and gzip (every
  member, or one), from memory or a `std.Io.Reader`, with dictionaries, partial
  output, and the reason and bit offset of every refusal.
- `Compressor`: whole-buffer compression at levels 0 to 12, with
  literal-only, run-length, filtered and fixed-code strategies, dictionaries and gzip headers, in allocated or given memory.
- CRC-32, CRC-32C and Adler-32, running and combined, on folding, CRC32, UDOT
  and AVX2 kernels chosen at run time.
- `gzip.parseHeader` and `gzip.writeHeader` for every header field.

- Near-optimal parsing at levels 10-12, with a configurable pass budget.
- Streaming `Inflate` and `Deflate`, Reader/Writer adapters, every flush mode,
  8-15 bit windows, level changes and retained-history resets.
- Deterministic parallel compression, validated portable seek indexes and
  parallel indexed decompression.
- Unindexed parallel decoding by speculative block discovery and symbolic
  history, with bounded caller storage and wrapper checksum validation.
- Raw Deflate64 decoding and the BGZF writer with virtual offsets.
- Optional zlib C stream ABI, a host build helper for compressed assets,
  and a compression CLI example.
- C retained-history resets, sync points, validation control, decode marks,
  table-use introspection and reusable CRC combine operators.

- Streaming zstd command example under `bench/cli/`.

### Fixed

- Streaming close parses accepted buffered input before the final or flush tail,
  keeping block boundaries stable when pending output fills the caller buffer.

- DEFLATE compressors keep optimal-parser state in their initialization buffer
  only when the configured levels can use it, reducing low-level value size.
- Captured header verdicts retain static reason storage across later calls.
- Explicitly disabling CRC in the target CPU no longer prevents checksum
  kernel modules from assembling; an AArch64 cross-build checks this.
- Near-optimal streaming blocks retain their source bytes across small-window
  slides, and changing level preserves the requested optimization passes.
- Short near-optimal flushes verify prefixes again when more input follows;
  Huffman-only and RLE streams at high levels need no optimal-parser storage.
- C compression bounds include custom gzip headers and small windows, and
  convenience calls report the bytes consumed on short output buffers.
- The parallel compressor refills completed slots while later chunks run.
- C decoding reports progress before an error and supports full-flush recovery.
- Refined dynamic headers use their final item count when choosing a block's code.

- Level 10 considers a fixed-code parse for short blocks.
- C block flushes stop before the final wrapper trailer; C ABI exports are
  compiled for 32-bit targets and CPUs with CRC disabled.
- Bound zstd long-distance warm-up state, avoiding counter overflow on long
  streams, and size its match storage to the physical block capacity.
- Refill parallel zstd compression workers as their ordered output is written,
  retaining the shared wait for input that fits in one batch.


- Zstd compressed block targets prepare entropy once and reuse it across
  partitions. Repeat history is replayed only when a raw partition or a literal
  cut requires it.
- Zstd handles whole-buffer inputs beyond the virtual index range and preserves
  match history and lazy-tree markers when streaming indices normalize.

[Unreleased]: https://github.com/pedronaugusto/warp/commits/main
