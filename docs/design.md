# Design

warp owns DEFLATE, zlib, gzip, Zstandard, LZ4, Brotli, GDeflate, bzip2 decoding and their checksums. Production depends
only on the standard library. Callers provide memory and, for parallel calls,
`std.Io`. Initialization reserves bounded storage; codec calls allocate nothing.

## Ownership and layers

`ci/layers.zig` declares the production graph from lowest layer to public root.
The build exports `checksums`, `deflate` and `zstd` independently, and `warp`
aggregates the same module instances. DEFLATE and Zstandard share one bit writer;
DEFLATE and the aggregate share one checksum module and CPU dispatch. Private
CRC polynomial operations serve that module and the optional C ABI.
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

Brotli has its own bit reader, prefix-code tables, static dictionary and
transforms, and context modes beneath `warp.brotli`; it imports no other codec.
One engine decodes a meta-block's header and commands, generic at comptime over
its reader (unchecked while a 32-byte margin of input remains, checked byte by
byte after it) and its history (the caller's output, or the caller's window
copied out). Units are small enough to restart: one that runs out of input
rolls back to its start with its bytes kept in a 64-byte carry, so streaming
resumes at any byte with no second decoder. The command loop keeps its state in
locals and copies 16 bytes at a time; a long literal block's trees are looked
up by the two bytes before each literal in one table.

Brotli's encoder is the reference's (google/brotli 1.2.1), stage for stage, so
its streams are the reference's byte for byte: the fragment coders of
qualities 0-1, the hashers and lazy parsing of 2-9, the binary-tree finder,
Zopfli parsing and block splitting and clustering of 10-11, each stage a file
beneath `warp.brotli` and layered in `ci/layers.zig`. The static dictionary's
lookup for 10-11 is static data (`dictionary_lut.bin`, pinned against the
reference's and rebuilt in the tests), so no encoder builds it at run time.
Unlike warp's other codecs, an encoder allocates its ring buffer, hashers
and block storage per stream, as the reference does; moving them into memory
taken once is open.

Each whole-buffer decoder owns its tables; its output supplies history. Each
streaming decoder owns progress and borrows its caller window. Encoders own
match tables, sequences, entropy and virtual positions in initialization memory.
DEFLATE optimal-parser state occupies that memory only when the configured levels
can use it; lower levels retain no unused optimal costs or observations.
Whole-input parsers retain their cursor across block boundaries, keep counts
in a local builder, and use one input bound; the greedy and lazy parsers hold
the sequence count, the literal run and the check counter in locals between
checks. The block splitter's observations are read from the counts when a check
is due, not made symbol by symbol. After 128 literals in a row without a match a
parser searches every second position, and so on to every eighth, and takes the
positions between as literals; the run belongs to the builder, so a stream
comes out the same however its input arrives. Dispatch stays beside the builder
so its stores do not alias matchfinder tables. Lazy
lookahead stays in one loop; streaming alone retains a held match between calls
and yields at block boundaries to drain output. Both use the same match
selection and block writer. The optimal parser stays out of ordinary dispatch
so its larger scratch lifetime does not extend into lower-level hot loops.
Whole-input level-1 search also keeps its table descriptors and relative base
local beside the builder, and copies back the base when parsing returns.
Full-window chain searches compile the window bound as a constant.
The decoder selects full-window or bounded-window match checks before entering
the fast loop; ordinary DEFLATE distances are already bounded to 32 KiB by
the alphabet. The register-heavy loop stays out of its resumable phase caller. Header
length decoding keeps its index local and saves progress on every return,
including a truncated unit. Source commits independently preserve input bits.
The fast loop makes no call: a refused stream or a match into the history ends
it with what is left to do, which follows with the state written back, so
nothing the loop holds is kept alive across a call (on x86-64 it would be spilled
to the stack every round). The output adapter says whether a match reaches the
output, copies it, or copies it from the history out of line. Smaller streaming
windows retain explicit distance checks.
Parallel values own worker storage and ordered job state. CPU detection owns the
single cached feature choice. There is no shared mutable codec state.

Each resumable decoder's phase is an `aegis.state.Machine`: the edges are
declared beside the phases, and one function per decoder changes the phase,
along an edge named by its phase and event, checked as it compiles and a plain
store at run time. LZ4's and zstd's frame decoders keep a refusal apart from
the phase, and answer it to every later call.

GDeflate is DEFLATE's engine with another bit layout beneath `warp.gdeflate`.
The engine is generic over its window (`deflate.EngineFor`): DEFLATE's 32 KiB
keeps its matchfinders' positions in 16 bits, and GDeflate's compressor owns
the 64 KiB instance, whose positions are 32 bits, so its matches reach across
a whole page. Both share one distance alphabet, Deflate64's 32 codes, and one
block writer; DEFLATE never counts codes 30 and 31, so its codes, costs and
bytes are what they were.
The parsers hand each finished block to a writer: DEFLATE's bit writer, or
GDeflate's lane writer, which serializes the block the engine chose
(`deflate/block.zig`'s `choose`: kind, code and header, with the format's own
stored cost) into 32 lanes, playing the decoder's reader to reserve each lane's
next word. The page decoder uses DEFLATE's table builder at Deflate64's sizes;
its round loop, with a pending match per lane, is GDeflate's own. A pending
match's source always lies before its place, and every other pending match's
place after it, so a copy reads only written output. The tile stream and its
offsets are checked before any page is decoded.

bzip2 has its own MSB-first bit reader, code tables and engine beneath
`warp.bzip2`, and imports only its CRC from the checksum layer. The code
tables are libbz2 1.0.8's limits, bases and permutation, built as it builds
them, with a 10-bit root table that replays its decode loop, so a code
decodes or is refused as there whatever its lengths. The engine is an
`aegis.state.Machine` of small units (a header field, a selector, a step of
a code length, one symbol); a unit that runs out of input rolls back, so the
whole-buffer, resumable and parallel decoders run one engine. The resumable
decoder reads its input in place and stages only a unit cut short (at most
57 bits), so it never takes a byte past the streams. A block depends on
nothing before it but where it starts, so the parallel decoder's workers
decode candidates found by the block magic, and the caller's thread joins a
block only where the previous one ended, checking the bounds of the stream's
level the worker could not know; headers, ends and refused blocks are
decoded there by the same engine. The block's CRC is a slicing-by-8 pass
over its output, not folded per byte.

LZ4 has its own block engine, parsers and frame owners beneath `warp.lz4`, and
no entropy stage: it imports neither the bit layer nor the Huffman builders.
The block decoder holds no state, so the whole-buffer frame decoder is a
function over the caller's output. One `Compressor` owns the match state of its
level band (the fast table, LZ4MID's two tables, the hash chains and the
optimal parser's costs share one `Chains`), a bound dictionary's tables, and
the last block's input for linked blocks. Positions are virtual and continue
across calls: an entry older than the call stands for its first byte, as a
cleared table's zero does for lz4, so the parses are lz4's and a call clears
nothing. The fast loop of the block decoder takes a sequence whole only while
its 16- and 32-byte stores stay inside both buffers, and otherwise leaves it
to a careful loop that checks every bound, one sequence at a time.

## Invariants

- Fast loops run only with checked input and output margins. Tail loops check
  each access. Spare caller output improves speed without changing acceptance.
- Headers, dictionaries, checksum trailers, offsets and declared lengths are
  validated. Diagnostics identify the failed structure and its position, in bits
  for DEFLATE and in bytes for zstd, each an aegis unit so the two never mix.
- Sizes and limits a caller sets are aegis sizes at the API; the engines keep
  their lengths as `usize` inside, where a typed value would cost the measured
  loops and buy nothing a slice bound does not already check.
- Output depends on input, options, dictionary and flush boundaries. Chunking,
  CPU dispatch and configured worker counts do not change its bytes.
- Search depth, windows, blocks, descriptors and queues are bounded. Jobs are
  joined on cancellation and failures before the value can be reused.
- `memory(options)` describes caller-storage requirements. Values initialized
  in a supplied buffer free nothing; allocated values retain their allocator.
- Kernel modules enable their required instructions independently of the
  consumer baseline. Dispatch selects them only when runtime detection permits;
  portable CRC and Adler kernels remain available. They are the only modules
  beside `warp`, which is one module for every codec: Zig sets CPU features per
  module, not per function, so code built with extra instructions needs a module
  of its own. They fold into `warp` when Zig can enable features per function.

## Extended operations

Checkpoints capture owned history, bit position and wrapper progress. Index
construction validates the stream; indexed parallel decoding checks each region
against its next checkpoint. Unindexed parallel decoding discovers candidate
block boundaries and emits symbolic history references. Marker and byte output
share the fast Huffman loop and match copies. Bounded batches retain cancellation
points. The coordinator accepts only boundaries
connected to the actual stream, resolves literals and history markers through
one byte table, and checks trailers. Exhausted search bounds and partial output use the core decoder.

Deflate64 parameterizes the shared decoder's alphabet and window, whole-buffer
and streamed: the streaming value holds the tables of its format's alphabet and
runs the same wrapper machine. BGZF writes
bounded complete gzip members with virtual offsets. Additional optimal parsing
passes reuse discovered matches. Compressed build assets use a host executable
and return a build `LazyPath`.

Zstandard sequence tables keep each cell as one 8-byte word. The sequence loop
holds the three cells of a sequence whole in registers and takes their fields
apart by shifts, reads the tables' addresses once per block, resolves repeat
offsets in its decode step, and copies the literals and the match of a short
sequence in two 16-byte moves whatever their length. FSE tables are built in a
single pass over their states. Single-symbol Huffman tables are filled weight by
weight from symbols sorted by weight, so that every weight's cells take one kind
of store. Long-distance anchors choose their bucket from the whole window's hash,
not its last bytes, and the ends of long matches are indexed in the `fast` and
`dfast` tables, which index only what they scan.

DEFLATE writes a block with nothing in it as the fixed code's end of block. A
dynamic header is refined only where it could still win the block, and its run
items are priced in one pass with a sliding window over the zeros an item may
cover.

Tiny optimal whole-buffer Zstandard inputs without a dictionary first receive
a bounded exact repeat check. When no three-byte sequence repeats, no match is
possible: the same entropy and block writer consume a literal-only sequence
store without preparing search tables or prices. Hash collisions only cause
exact comparisons; the proof includes overlapping repeats and the final triple.

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

A package cannot pin itself as a baseline: bay builds every revision of the package
under development from its working tree. A candidate is measured against an earlier commit
with preflight's `bench-ab`, which builds the base from its own checkout; the programs
are `shakedown.bench` rows declared through `.bench`, one row per measured thing, so
`bay bench` and `bay bench-ab` run them. Output sizes are `check-sizes`', not rows.
