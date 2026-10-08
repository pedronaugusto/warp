# warp

warp compresses and decompresses DEFLATE in Zig, raw or in its zlib and gzip
wrappers, and computes their checksums: CRC-32, CRC-32C and Adler-32. A call
works on whole buffers or streaming pieces in caller memory, allocates nothing
after initialization, and runs
the fastest kernel the CPU has.

## Install

Requires Zig 0.17.0. Fetch with `zig fetch --save
git+https://github.com/pedronaugusto/warp`, then obtain the `warp` module through
`b.dependency` and add it to your executable's imports. warp has no dependencies.
The codecs build for every target, wasm32-freestanding included. CPU detection
reads the instructions available; parallel calls take `std.Io` for their workers.

## Usage

A gzip member, compressed and decompressed:

<!-- BEGIN GENERATED zig build docs -- usage -->
```zig
const warp = @import("warp");

// Tables sized once; every call after `init` allocates nothing.
var compressor: warp.Compressor = try .init(gpa, .{ .level = 6 });
defer compressor.deinit();
const frame: warp.Compressor.Frame = .{ .container = .gzip, .gzip = .{ .name = "fox.txt" } };
// An output of `bound` bytes holds the longest stream compress writes.
const stream = try gpa.alloc(u8, warp.Compressor.bound(data.len, frame));
defer gpa.free(stream);
const n = try compressor.compress(data, stream, frame);

// About 11 KiB of tables and no stream state: one serves any number of
// calls. Room for `inflate_margin` more bytes lets the fast loop run to
// the end; the exact size works too.
var decompressor: warp.Decompressor = .init;
const out = try gpa.alloc(u8, data.len + warp.inflate_margin);
defer gpa.free(out);
const result = try decompressor.inflate(stream[0..n], out, .{ .accept = .gzip });
std.debug.assert(std.mem.eql(u8, out[0..result.out_len], data));
```
<!-- END GENERATED -->

A stream read from a `std.Io.Reader`, the container told apart by its header:

<!-- BEGIN GENERATED zig build docs -- reader -->
```zig
const warp = @import("warp");

// From a std.Io.Reader: what follows the stream stays in the reader.
var input: std.Io.Reader = .fixed(stream);
var decompressor: warp.Decompressor = .init;
const out = try gpa.alloc(u8, data.len);
defer gpa.free(out);
var diagnostic: warp.Diagnostic = undefined;
const result = decompressor.inflateReader(&input, out, .{ .accept = .gzip_or_zlib, .diagnostic = &diagnostic }) catch |err| {
    std.log.err("{t} at bit {d}: {t}", .{ err, diagnostic.bit_offset, diagnostic.reason });
    return err;
};
std.debug.assert(result.finished);
std.debug.assert(result.out_len == data.len);
```
<!-- END GENERATED -->

The checksums, alone:

<!-- BEGIN GENERATED zig build docs -- checksums -->
```zig
const warp = @import("warp");

// Continued over pieces, or joined from the pieces' values.
const half = data.len / 2;
var crc: warp.Crc32 = .init;
crc.update(data[0..half]);
crc.update(data[half..]);
std.debug.assert(crc.final() == warp.crc32Combine(warp.Crc32.hash(data[0..half]), warp.Crc32.hash(data[half..]), data.len - half));
std.debug.assert(warp.Crc32c.hash("123456789") == 0xe3069283);
std.debug.assert(warp.adler32(1, data) == warp.Adler32.hash(data));
```
<!-- END GENERATED -->

## Design

**Decoding.** A `Decompressor` is the decoding tables of the current block,
11,488 bytes, and nothing else: it holds no stream, so one per thread serves every
call and every container. The output buffer is the history. Each table entry is
one `u32` holding a literal, a length or distance base with its extra bits, or a
pointer to a subtable, and the count of bits it consumes, so a symbol is one load
and one shift. The main table indexes as many bits as the block's longest code
needs, up to 11 for literals and lengths and 8 for distances; the fixed code's
tables are built at compile time.

The fast loop decodes three literals per refill of a 64-bit bit buffer, preloads
the next entry before it finishes the current one, and copies matches 16 bytes
at a time, writing up to 16 bytes past a match's end. It runs while the input
has 16 bytes left and the output `inflate_margin` (274: the longest match and one
more store); a careful loop with every bound checked takes the rest, so an output
of exactly the decoded size works, and `inflate_margin` more bytes only lets the
fast loop run to the end.
Near the end of the input the bit buffer is filled with zero bytes that are not
there; a stream that consumes one of them is `error.Truncated`, the same answer
for every cut of a valid stream.

What a decoder accepts follows zlib's inflate exactly: incomplete and
oversubscribed codes, a code of one symbol, the code-length code's quirks,
header checks, dictionary IDs, and the order in which a gzip trailer's CRC and
size are checked. Every refusal names its reason and the bit where decoding
stopped, through `Options.diagnostic`.

**Encoding.** A `Compressor` takes its memory once, sized for the level and the
largest input it will see, and each call clears only the part its input uses.
Level 1 keeps the two latest positions per hash of four bytes, and the latest
position per hash of three for short matches near by. Levels 2 to 9 use hash
chains over a 32 KiB window, positions stored as 16-bit offsets that move with
the window; 2 and 3 take the longest match found, 4 to 9 look one position ahead
and take a literal when the match there is better by length and distance. Each
level follows its chains as little as keeps its output no larger than zlib's at
the same level on every kind of input in the test corpus.

Levels 10-12 use binary trees and iterate a minimum-cost path over cached
matches, updating symbol costs from each chosen path. Additional passes trade
time for size without another match search.

Level 1 ends a block every 64 KiB or 8,192 matches; the other levels end one
where the symbol statistics change, tested every 512 symbols. Each block is
written as whichever of stored, fixed-code or dynamic-code costs the fewest bits,
counted exactly; dynamic codes are built length-limited from the
block's counts, and the writer packs a literal or a match with its extra bits in
one table load and one add to the bit buffer. The same input, options and
dictionary always give the same bytes.

**Checksums.** Each checksum has kernels for the instructions it can use and picks
one per process, on first use, from what the CPU reports (`warp.kernels()` says
which). CRC-32 and CRC-32C fold 16-byte lanes forward with carry-less multiplies,
twelve lanes at a time with PMULL on AArch64 (joined with EOR3 where the CPU has
SHA3) and with PCLMULQDQ or VPCLMULQDQ on x86-64, then finish with the CRC32
instructions or slicing-by-8. Adler-32 sums 32 bytes a step with UDOT on AArch64
or AVX2 on x86-64, and on the target's vectors otherwise. Zig sets CPU features
per module, so each kernel is a module of its own built with its instructions,
and a build for the baseline CPU still reaches them. `crc32Combine`,
`crc32cCombine` and `adler32Combine` join two checksums in time logarithmic in
the second length.

## API

| Call | Does |
|---|---|
| `Decompressor.inflate(in, out, options)` | Decodes one raw, zlib or gzip stream (or every gzip member) into `out` |
| `Decompressor.inflateReader(reader, out, options)` | The same from a `std.Io.Reader`, refilling it; what follows the stream stays in the reader |
| `Options.accept` | `raw`, `zlib`, `gzip`, `zlib_or_raw` (HTTP's "deflate"), `gzip_or_zlib` |
| `Options.partial` | Stops when `out` is full instead of failing; `Result.finished` says which |
| `Options.dictionary` | History before the output: what a raw stream refers into, or the bytes a zlib stream names |
| `Compressor.init(gpa, options)`, `initBuffer(buffer, options)` | A compressor for a level (0 stored, 1-9, 10-12 near-optimal) and strategy, in allocated or given memory |
| `Compressor.memory(options)` | The bytes `initBuffer` needs |
| `compressor.compress(in, out, frame)` | One complete stream of `in`; `frame` picks the container, dictionary and gzip header |
| `Compressor.bound(len, frame)` | The longest stream `compress` writes for `len` bytes: an `out` this long never fails |
| `Strategy` | `default`, `filtered`, `huffman_only`, `rle`, `fixed` |
| `Crc32`, `Crc32c`, `Adler32` | Running checksums: `update`, `final`, `hash` |
| `crc32`, `crc32c`, `adler32` | A checksum continued over bytes |
| `crc32Combine`, `crc32cCombine`, `adler32Combine` | The checksum of two pieces from theirs |
| `kernels()` | The kernel each checksum runs on this CPU |
| `gzip.parseHeader(in)`, `gzip.writeHeader(writer, header)` | A gzip member header, every field |

Errors are named sets: `InvalidStream`, `ChecksumMismatch`, `DictionaryMismatch`,
`Truncated` and `OutputTooSmall` for decoding, `OutputTooSmall` for encoding, and
`ReadFailed` from a reader.

## Streaming and parallel calls

`Inflate.decode` and `Deflate.write`, `flush`, and `finish` resume at any input
or output byte. `Inflate.Reader` and `Deflate.Writer` adapt them to `std.Io`.
Window sizes are 8-15 bits; resets may keep history for context takeover.
`Deflate.Options.max_level = 12` reserves the storage needed to change from a
lower level to a near-optimal one. `Compressor.Options.passes` and
`Deflate.Options.passes` set the cost-model pass budget at levels 10-12.

`parallel.Compressor.compress(io, input, writer)` and `compressReader` write one
standard stream. `parallel.Options` chooses the container, level, 128 KiB chunk
size, worker count, and whether chunks refer to the preceding 32 KiB. The bytes
are identical for every worker count. `memory` and `initBuffer` support caller
storage for the parallel codecs and BGZF writer.

`gzip.Index.build(gpa, input, accept, spacing)` validates a compressed stream
and saves block boundaries, checksums, and history. `write` and `read` persist
it in a versioned little-endian format; `find` locates a restart point.
`Inflate.checkpoint` and `@"resume"` expose those points directly.
`Inflate.Reader.seek(point)` restores the decoder after the caller repositions
its compressed reader to `point.in_offset`. `parallel.Decompressor.decompress`
uses an index to decode disjoint output regions concurrently. Building the
index is a separate sequential pass.

For streams without an index, reserve marker buffers with
`parallel.Decompressor.init(gpa, .{ .concurrency = 8, .speculative = .{} })`, then
call `inflate(io, input, output, .{ .accept = .gzip })`. This searches bit offsets
and decodes blocks concurrently before their history is known. The coordinator
accepts only boundaries reached from the real header, resolves unknown-window
references, and validates the original wrapper checksums. Raw DEFLATE, zlib,
dictionaries and concatenated gzip members use the same call. No index pass is
required. `speculative.chunk_len`, `search_len`, `max_blocks` and `work_limit`
bound retained output, search partitions, descriptors and failed-candidate work.
Large single blocks, exhausted searches and partial requests use the native
engine. `speculative = null` keeps the compact indexed allocation; `inflate`
then uses the native decoder. All worker storage is reserved at initialization,
and cancellation or an error joins workers before returning.

`gzip.Bgzf` writes members with the BC extra field, bounds both compressed and
decoded blocks to 64 KiB, and finishes with the canonical empty EOF member.
`virtualOffset` gives the member offset and buffered decoded offset.
`deflate64.Decompressor` decodes raw zip method 9 with a 64 KiB window.

## C and build integration

`zig build -Dc-abi=true` also builds `libz.a`. The stream ABI supports raw,
zlib, gzip and automatic decoding, caller allocation callbacks, dictionaries,
flushes, level changes, resets, state copies, gzip headers, full-flush recovery,
convenience calls, state introspection, retained-history resets and checksums. Use an existing zlib header when compiling C callers. File APIs,
callback decoding, bit priming and fine-grained tuning are outside this surface.

A consumer build can call `@import("warp").addCompressedAsset(b, dependency,
.{ .source = b.path("asset.txt"), .name = "asset.gz" })`. The returned `LazyPath`
is generated by a host executable and can be embedded or installed even when the
consumer targets another architecture. `container` selects raw, zlib or gzip;
`level` defaults to 12. `zig build cli -- [-d] [-l level] [-j workers] input output`
runs the gzip example; `--raw` and `--zlib` select the other containers.

## Platforms

Every target Zig supports. The CRC and Adler-32 kernels run on AArch64 (macOS,
Linux and Windows) and x86-64; elsewhere, and where the CPU lacks them, the
portable kernels give the same values. Big-endian and 32-bit targets build and
behave the same.

## Built with

- [Zig](https://ziglang.org) 0.17.0 and its standard library; nothing is linked.
- [preflight](https://github.com/pedronaugusto/preflight) runs the source checks,
  the tests and CI.
- [shakedown](https://github.com/pedronaugusto/shakedown) generates and shrinks the
  property and fuzz cases.

## Testing

`zig build test` runs the suite and the usage example. The test data is a corpus
of streams other implementations wrote from seeded inputs: every one decodes to
its input. Invalid streams carry the verdict zlib's inflate gave them, and each
gets the same error for the same reason. Every prefix of a valid stream is
`Truncated` at the right bit, and every output length gives the prefix with
`partial`. The standard library is the oracle in both directions: warp decodes
what it writes at every level, and it decodes what warp writes at every level and
strategy. Every level, strategy and container round-trips every kind of input,
also with dictionaries, and each level's aggregate size stays below its captured zlib reference per kind
of input (levels 10-12 compare with zlib level 9). Every checksum kernel the CPU has is checked against a
bitwise reference at every length to 4 KiB and every alignment, and combining to
2^33 bytes. Fuzzing feeds arbitrary bytes to every decoder entry and arbitrary
inputs through every level; compression allocates nothing after `init`, and
`init` survives every allocation failure.

`zig build bench` times the default rows in ReleaseFast, beside the code warp
replaces. Run `zig-out/bench/bench --runs 3 parallel` to select rows, or add
`--smoke` or `--corpus <dir>`. The `speculative` rows include discovery and
marker resolution for whole streams, alongside native decoding. CI compiles the benchmarks and never times them.

## Licence

MIT. See [LICENSE](LICENSE).
