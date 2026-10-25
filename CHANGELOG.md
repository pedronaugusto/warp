# Changelog

All notable changes to warp are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

## [0.4.4] - 2026-10-25

### Added

- Streaming Deflate64 (zip method 9) decoding: `Inflate.Options.format = .deflate64` decodes the extended length and distance codes with a 64 KiB window, through `Inflate.decode` and `Inflate.Reader` on the same engine and state machine as DEFLATE, so a zip entry need not fit in memory. Raw streams only; checkpoints stay DEFLATE's. `Options.windowLen()` gives the window (and, for `Reader`, the buffer less 4096) either format needs. Tested on 48 streams 7-Zip 26.05 writes (`testdata/deflate64.corpus`, captured in trials), whole, streamed at every cut and through the reader, and by a property that the streaming decoder answers as the whole-buffer one on arbitrary and mutated input.
- LZ4 (`warp.lz4`): the block and frame formats both ways at lz4's levels, -65536 to 12 on lz4frame's scale (the fast parser with acceleration, LZ4MID, hash chains with pattern analysis, optimal parsing, `favor_decompression_speed`); the parses are lz4 1.10's, so a block without history is byte for byte `LZ4_compress_fast`'s or `LZ4_compress_HC`'s on every target. Blocks with a bound dictionary, the previous block (as a prefix when contiguous) or given history, and `destSize` filling. Frames with 64 KiB to 4 MiB linked or independent blocks, block and content checksums, content size, dictionary ID, skippable and concatenated frames, and legacy frames both ways. Stateless decoding (`decompressBlock`, `decompress`), resumable `Compress` and `Decompress` with `std.Io` adapters, frame inspection. Tested on lz4 1.10's own blocks (byte identity at every level and budget), frames (every decoder entry) and verdicts on mutated input (`testdata/lz4-*.corpus`, captured in trials), and fuzzed against a plain decoder.

### Fixed

- The zstd decoder places a block's trailing literals that overrun the output (`error.OutputTooSmall`) at its sequence bitstream, as its other faults while executing sequences and the parallel decoder do; it named the sequences header, so the two decoders' diagnostics disagreed (`zstd_parallel_test`'s mutations, found by the release gate's fuzzing).
- The zstd encoder writes a frame into exactly the room the same frame took before. A block of one repeated byte, given less room than a Huffman literals header needs, was stored raw and refused (`error.OutputTooSmall`) where its run of one byte fits: the literals now settle a run before asking for that header (`zstd_encode_test`'s generated round trips, found by the release gate's fuzzing).
- The same in a split block's literals: a sub-block carrying a new Huffman description longer than its literals, given the room its raw literals took, refused the block where the raw section fits; it is stored raw, as when the Huffman body does not fit.
- Development: two tests that ran past the 120 s watchdog on a loaded machine (the 0.4.4 release gate, and on f60f33d alike) do the same checks in bounded pieces: the speculative decoder's truncation test decodes every cut of a 5,000-byte input, not a 20,000-byte one (its work grows with the square of the input), and the zstd encoder's captured size bounds are five tests, a band of levels each, not one over all 29 levels.
- Development: every test runs once. `concurrent`'s root of its own (`src/concurrent_test.zig`, 0.4.3) compiled in the tests of every source file its tests import, as Zig does for each file of a root's module, so `test` ran the codecs' tests twice, and the riscv64 leg's shards, splitting the two roots apart, ran the copies on different shards (the profile's `TestOnTwoShards`, the 2026-10-23 nightly). `src/tests.zig` is the one root; `concurrent`, what ThreadSanitizer runs, builds it with only the tests of the five files whose work is shared between threads.

## [0.4.3] - 2026-10-21

### Fixed

- zstd's parallel decoder refused a block wrong in both its literals and its sequences header for its sequences, where the core refuses it for its literals, which come first: the parallel side read the sequences header before its worker decoded the literals. It now decodes them first where that header is refused, with the table the core decodes them with. Found by the release tier's fuzzing (the 2026-10-21 nightly's campaign, run to its end); both inputs are regressions of the property.

### Changed

- The release tier's ThreadSanitizer run takes `concurrent`, the tests whose work is shared between threads (a root of their own, `src/concurrent_test.zig`; `test` runs both roots), and its fuzz campaign 3,000 inputs a target: with the whole suite and 10,000 they ran past the hosted job's twenty minutes every night since 2026-10-18. The riscv64 leg runs in four shards. The 64 KiB stack test skips under ThreadSanitizer, whose frames are larger.

## [0.4.2] - 2026-10-20

### Changed

- Development: the suite runs under the release tier's hardened profile (`bay hardened`, `bay hardened-fuzz`, `bay hardened-tsan`). shakedown 0.4.12 for development: 0.4.1's simulation watchdog asked for a 64 KiB thread stack, below what libc takes on aarch64 Linux under ThreadSanitizer (`pthread_attr_setstacksize` refused it, an assertion in std), which aborted the parallel zstd tests there.
- Pins aegis 0.1.12, the line's version shakedown 0.4.12 takes.
- Development: the speculative and parallel zstd properties start their decoders' work on the case's own `Io` (shakedown 0.4.13's `Case.io`). Under the fuzzer, `std.testing.io` outlives each input's `std.testing.allocator`, and a group's task freed after its group's await reached the next input's allocator ("corrupted footer metadata"); the decoders were right.

## [0.4.1] - 2026-10-17

### Fixed

- The AVX2 checksum kernels (Adler-32, and CRC-32 and CRC-32C folded with VPCLMULQDQ) faulted in a Debug build on x86-64 Linux: Zig's own x86-64 backend, Debug's default there, keeps 32-byte vectors on a stack it assumes 32-byte aligned and does not realign it, and a kernel picked at run time is entered from code built for the baseline, which aligns it to 16. Under that backend the kernels run only where the target guarantees AVX2; under LLVM, as before, wherever the CPU has it.

## [0.4.0] - 2026-10-14

### Breaking

- Sizes and limits in options are aegis sizes: `Compressor.Options.max_input`, `parallel.Options.chunk_len`, the speculative decoder's `chunk_len` and `search_len`, `zstd.Compressor.Options.max_input`, `zstd.Compress.Options.pledged_size` and `target_block_size`, `zstd.Decompressor.Options.max_window`, `zstd.seekable.Writer.Options.frame_len`, `zstd.parallel.Options.job_len` and `writeSeekable`'s frame length. Defaults read as text (`.literal("128KiB")`).
- `Diagnostic.bit_offset` is an aegis count of bits and `zstd.Diagnostic.offset` one of bytes.
- aegis is a dependency every build fetches, no longer lazy.

### Changed

- glint's aegis rules A001-A005 gated. Pins preflight 0.5.5 for development.

## [0.3.1] - 2026-10-14

### Changed

- Pins aegis 0.1.6.

## [0.3.0] - 2026-10-13

### Breaking

- warp is one module, `warp`: the separate `checksums`, `deflate` and `zstd` modules are gone, and what they held is in `warp` (`warp.Crc32`, `warp.Compressor`, `warp.zstd`). A program compiles only what it calls, so one that only checksums carries no codec. The CPU-feature checksum kernels stay modules of their own inside, since Zig sets CPU features per module.

### Changed

- The benchmarks compare warp with std only: the copies of relic's inflate and CRC-32 and chronicle's CRC-32C they measured against are gone, since both now use warp.

## [0.2.4] - 2026-10-13

### Changed

- The benchmarks run the parallel and speculative rows at 1, 2, 4 and 8 workers on every machine. A test runs the parallel codecs with sixteen workers on an `Io` with no thread, one and two, and checks the same bytes: the tasks the `Io` has no thread for run in place, and no worker waits for another to be scheduled.

## [0.2.3] - 2026-10-13

### Changed

- The benchmarks are `shakedown.bench` programs declared through preflight's `.bench`: `bay bench` and `bay bench-ab` run them, and every measured thing is a row (`family/workload/variant`) in JSONL instead of a printed table. `--runs` is gone (shakedown takes the samples); `--row <prefix>` selects rows. The zstd program keeps its modes as options. Output sizes and the per-connection memory figures are no longer printed; `check-sizes` keeps the sizes.
- Pins aegis 0.1.4, preflight 0.4.3 and shakedown 0.4.0; ensign 0.1.1 reads the benchmarks' arguments.

## [0.2.2] - 2026-10-13

### Removed

- The hosted indicative measurements (`hosted-bench`, `hosted-single-build`, `-Dhosted-*`, the `Indicative x86 measurements` workflow) and the `previous_main` and `integrated_main` pins of warp itself. Under bay every revision of warp builds from the working tree, so the previous-main arm measured the candidate against itself; `bench/main.zig` measures the same rows against std and the code warp replaced.

### Changed

- Pins aegis 0.1.2 and shakedown 0.3.1.

## [0.2.1] - 2026-10-12

### Changed

- Pins aegis 0.1.1, preflight 0.3.4, shakedown 0.2.6 and previous_main 0.1.0.

## [0.2.0] - 2026-10-12

### Breaking

- warp is developed with [bay](https://github.com/pedronaugusto/bay): preflight and shakedown are dev dependencies, and the tests, checks, examples and benchmarks are the development build's (`bay test`, `bay bench`, `bay check-sizes`), and the two pinned earlier revisions of warp that the manual measurements compare against are dev dependencies too. What a project that depends on warp builds is unchanged: the modules, the library, `-Dc-abi` and `addCompressedAsset`.

### Changed

- Level 1 inserts the positions inside a match four at a time, hashing all four before the
  first store; 1 to 2% faster, the bytes unchanged.
- Levels 1 to 9 search every second position after 128 literals in a row without a
  match, every third after 256, and so on to every eighth, and take the positions between
  as literals; a match ends it. The literal run is the builder's, so a stream comes out
  the same however its input arrives. Random bytes are encoded 7 to 9 times as fast (100
  to 110 MB/s become 740 to 960 at levels 1, 3, 6 and 9); the git source tar, Silesia and the captured corpus come out 0.01 to 0.04%
  larger, the tar and Silesia 1 to 3% faster at levels 2 to 9, and the captured corpus,
  which has random and already compressed kinds, 25 to 40% faster at levels 1 to 3.
- The Zstandard row matchfinder (levels 5 to 12 over windows of 2^17 bytes or more) is
  built for each row length it uses, as it is for each minimum match, instead of
  branching on the row length in the search of every position. The output is unchanged;
  levels 6, 7 and 9 encode 4 to 5% faster on Silesia.
- The inflate fast loop makes no call: where a stream is refused, or a match reaches
  into the history, it leaves, and that is dealt with after it with the state written
  back. On x86-64 the state it held across those calls was spilled to the stack in every
  round; the loop's two instances now have 42 and 39 stack operands, from 47 and 62, and
  decode 3% faster. AArch64 is unchanged.
- Level 1 finds no match of three bytes and keeps no table for them: the lookup at every
  position without a longer match cost 5 to 8% of the level's speed (more on data that
  mostly has no matches) for 0.45% of Silesia's output, 0.37% of the captured corpus's
  and 0.002% of the git source tar's. The size gate is unchanged.
- Read the block splitter's observations from the symbol counts the parse keeps, when
  a check is due, instead of making them one literal and match at a time. The blocks,
  and so the bytes, are unchanged at every level; levels 2 to 9 run 1 to 3% faster.
- The greedy and lazy parsers hold the sequence count, the literal run and the check
  counter in locals between checks, and the matchfinder's descriptors beside them.
  The bytes are unchanged.
- Prime the overlap of a parallel Zstandard job at levels 1 to 4 by indexing every third
  position, as a dictionary is indexed, instead of searching it. A few
  hundredths of a percent more output, and about 3% more speed.
- Find the cheapest run items of a dynamic header in one pass, with a sliding window
  over the 11 to 138 zeros an item may cover, rather than trying every count at
  every position, and end empty input at levels 10 to 12 without a path search. The
  bytes are unchanged; small blocks at those levels take a third of the time.
- `zig build check-sizes` reports, per level, the median, 99th percentile and worst
  of each captured input's size over the size recorded for it. The gate is unchanged.
- Choose a long-distance anchor's bucket from the whole 64-byte window, not its
  last bytes, and index the end of every long match in the `fast` and `dfast`
  tables. On Silesia at level 3 with a 128 MiB window the
  output is 0.18% smaller.
- Write an empty DEFLATE block without weighing dynamic codes, and refine a
  dynamic header only when it could still win the block. The bytes are unchanged.
- Select row candidates in 16-entry Zstandard rows with a narrowed compare
  on AArch64; the candidates and their order are unchanged.
- Fill Zstandard Huffman decoding tables weight by weight from symbols sorted by
  weight, and count a description's weights in four histograms.
- Decode Zstandard sequences from whole 8-byte table cells held in registers
  instead of field by field, load the code tables' addresses once per block,
  copy short literal runs and matches in two 16-byte moves whatever their length,
  and build each FSE table in one pass over its states. Decoded bytes are unchanged.
- Prove tiny optimal Zstandard inputs without repeated three-byte sequences
  before preparing match and price tables. The existing entropy and block
  writer still decide their encoded form; dictionaries keep normal search.
- Keep whole-input level-1 matchfinder descriptors local across probes; table
  stores do not reload their hash sizes or pointers. Match selection is unchanged.
- Keep whole-input DEFLATE parsing in its cursor across block boundaries and
  specialize full-window search and decoding bounds. Keep whole-input counts
  and one input bound local to dispatch, and group lazy lookahead. Streaming
  retains its resumable boundaries and smaller-window validation. Decode
  header progress stays local within a call and is saved on every return.
  Optimal-parser scratch stays outside lower-level dispatch; byte and marker
  outputs share the fast loop’s existing stream argument.
- Pins aegis 0.1.0.

### Added

- Independently selectable `checksums`, `deflate` and `zstd` build modules.
  Aggregate and standalone imports share public types and checksum dispatch.
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
