# Design

warp owns DEFLATE, zlib, gzip, Zstandard and their checksums. Production depends
only on the standard library. Callers provide memory and, for parallel calls,
`std.Io`. Initialization reserves bounded storage; codec calls allocate nothing.

## Ownership and layers

`ci/layers.zig` declares the production graph from lowest layer to public root.
Bits, checksum kernels and CPU detection support entropy and match search.
DEFLATE encoding and decoding are independent engines. Container owners wrap
those engines; whole-buffer and streaming values share them. Adapters handle
`std.Io.Reader` and `std.Io.Writer`. Indexes, BGZF and parallel jobs sit above the
codec values. The optional C interface translates stream operations at that
boundary. `src/warp.zig` exposes supported calls, rather than engine namespaces.

Zstandard has independent bits, entropy, match search, block engines and frame
owners beneath `warp.zstd`. It imports no DEFLATE engine. Dictionaries own parsed
entropy tables and borrow their content bytes; compressors index that content
once. Training is an allocation-taking operation outside codec calls.

Each whole-buffer decoder owns its tables; its output supplies history. Each
streaming decoder owns progress and borrows its caller window. Encoders own
match tables, sequences, entropy and virtual positions in initialization memory.
DEFLATE optimal-parser state occupies that memory only when the configured levels
can use it; lower levels retain no unused optimal costs or observations.
Whole-input parsers retain their cursor across block boundaries, keep counts
and split observations in a local builder, and use one input bound. Dispatch
stays beside that builder so its stores do not alias matchfinder tables. Lazy
lookahead stays in one loop; streaming alone retains a held match between calls
and yields at block boundaries to drain output. Both use the same match
selection and block writer. Full-window chain searches compile the window bound as a constant.
The decoder selects full-window or bounded-window match checks before entering
the fast loop; ordinary DEFLATE distances are already bounded to 32 KiB by
the alphabet. The register-heavy loop stays out of its resumable phase caller. Header
length decoding keeps its index local and saves progress on every return,
including a truncated unit. Source commits independently preserve input bits. Smaller streaming windows retain explicit distance checks.
Parallel values own worker storage and ordered job state. CPU detection owns the
single cached feature choice. There is no shared mutable codec state.

## Invariants

- Fast loops run only with checked input and output margins. Tail loops check
  each access. Spare caller output improves speed without changing acceptance.
- Headers, dictionaries, checksum trailers, offsets and declared lengths are
  validated. Diagnostics identify the failed structure and its position.
- Output depends on input, options, dictionary and flush boundaries. Chunking,
  CPU dispatch and configured worker counts do not change its bytes.
- Search depth, windows, blocks, descriptors and queues are bounded. Jobs are
  joined on cancellation and failures before the value can be reused.
- `memory(options)` describes caller-storage requirements. Values initialized
  in a supplied buffer free nothing; allocated values retain their allocator.
- Kernel modules enable their required instructions independently of the
  consumer baseline. Dispatch selects them only when runtime detection permits;
  portable CRC and Adler kernels remain available.

## Extended operations

Checkpoints capture owned history, bit position and wrapper progress. Index
construction validates the stream; indexed parallel decoding checks each region
against its next checkpoint. Unindexed parallel decoding discovers candidate
block boundaries and emits symbolic history references. Marker and byte output
share the fast Huffman loop and match copies. Bounded batches retain cancellation
points. The coordinator accepts only boundaries
connected to the actual stream, resolves literals and history markers through
one byte table, and checks trailers. Exhausted search bounds and partial output use the core decoder.

Deflate64 parameterizes the shared decoder's alphabet and window. BGZF writes
bounded complete gzip members with virtual offsets. Additional optimal parsing
passes reuse discovered matches. Compressed build assets use a host executable
and return a build `LazyPath`.

Zstandard long matching samples a bounded retained window. Parallel compression
writes ordered overlapping jobs in one frame; rsyncable mode chooses stable job
cuts. Seekable output writes independent frames and a validated seek table.
Pipelined decoding prepares block entropy in workers and executes history in
order. Superblock targets partition encoded cost with shared entropy tables.

## Validation

Captured frames and malformed inputs provide differential format checks.
The standard library supplies independent decoding and DEFLATE encoding oracles.
Properties cover round trips, chunk boundaries, dictionaries, resets, concurrency,
partial output, determinism and allocation failures using shakedown. Cross-build
fixtures exercise freestanding, big-endian, 32-bit, CRC-disabled and C-interface
calls. Size gates compare aggregate totals; single-input tails are reported.
Benchmarks compile in CI; timing evidence is measured separately.

Manual x86 measurements use `zig build hosted-bench -Dhosted-previous-main=true`
and the `Indicative x86 measurements` workflow on Linux and Windows (dispatch
`ci.yml` with `indicative=true` on a candidate branch). Its lazy
benchmark dependency pins the previous main; consumers fetch no benchmark code.
The workflow builds one-codec executables from the previous main, integrated
pre-repair source and candidate, using the same driver and compiler settings.
It alternates their processes across 21 adjacent samples of two traversals,
with two invocations of the previous-main executable as a control. This
separates codec throughput from caller position in a combined executable.
Generated inputs, ReleaseFast baseline targets and reused storage are identical
across adjacent, alternating samples. Each batch’s final output is checked outside the
timer. Raw times, absolute throughput and paired ratio spread are reported as
indicative: runner contention and ordering effects remain possible. DEFLATE uses
zlib frames at matching levels; Zstandard uses checksum-off frames for both
Warp and std. Missing historical or std APIs are explicitly unmeasured.
