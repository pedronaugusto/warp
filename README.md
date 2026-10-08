# warp

warp compresses and decompresses DEFLATE in Zig, raw or in its zlib and gzip
wrappers, and zstd frames through `warp.zstd`. It computes CRC-32, CRC-32C
and Adler-32. A call
works on whole buffers in memory the caller gives, allocates nothing, and runs
the fastest kernel the CPU has.

## Install

Requires Zig 0.17.0. Fetch with `zig fetch --save
git+https://github.com/pedronaugusto/warp`, then obtain the `warp` module through
`b.dependency` and add it to your executable's imports. warp has no dependencies.
Its only contact with the operating system is reading which instructions the CPU
has; it builds for every target, wasm32-freestanding included.

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
| `Compressor.init(gpa, options)`, `initBuffer(buffer, options)` | A compressor for a level (0 stored, 1-9, 10-12 as 9 for now) and strategy, in allocated or given memory |
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

## Scope

- Whole buffers only for now: no streaming encoder or decoder over chunks, no
  flush modes, no window sizes below 32 KiB.
- Levels 10 to 12 compress as level 9 until their parser exists.
- No parallel compression or Deflate64 yet.
- A gzip header's fields are read by `gzip.parseHeader`; the decoder skips them.

## Zstandard

`warp.zstd.Compressor` writes a complete frame per call at levels −131072
through 22. Level 0 selects the default, 3. `init` takes its tables once;
`initBuffer` uses aligned caller storage of `memory(options)` bytes. Set
`max_input` to size the tables for a workload; larger calls still work with
those tables. `Compressor.bound(len)` reserves enough output for every frame.
`Frame` selects checksums, content sizes and standard or magicless framing.
`Tuning` overrides the level's search strategy and parameters.

`warp.zstd.Decompressor.decompress` and `decompressReader` decode concatenated
frames, skippable frames and dictionary frames. Dictionary bytes are borrowed
by `Dictionary.parse` or `Dictionary.raw`, and dictionaries can be shared
between decoders. Checksums are verified by default; `partial` returns the
output prefix, and `frames = .one` leaves the next frame unread. `max_window`
defaults to 128 MiB. `Diagnostic` records the refusal's byte offset and reason.

`frameHeader`, `frameLength`, `contentSize` and `decompressBound` inspect frames
without decompressing them. `writeSkippable` writes an application payload.
`Compress.write`, `flush` and `finish` accept arbitrary input and output
chunks. `pledged_size` writes and checks a known content size; a mismatch is
`SizeMismatch`. `Compress.Writer` wraps an existing compressor and output
writer. `Decompress.decode` is resumable at every input and output byte;
its window holds the declared history plus one decoded block. Call
`Decompress.finish` at end of input to check truncation. `Decompress.Reader`
uses the same decoder, reserving 4 KiB of its buffer for reader buffering.

Dictionary compression and training, long-distance and parallel compression,
and seekable streams are still being built.

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
also with dictionaries, and no level writes more than zlib does at the same level
on any kind of input. Every checksum kernel the CPU has is checked against a
bitwise reference at every length to 4 KiB and every alignment, and combining to
2^33 bytes. Fuzzing feeds arbitrary bytes to every decoder entry and arbitrary
inputs through every level; compression allocates nothing after `init`, and
`init` survives every allocation failure.

`zig build bench -- [--smoke] [--corpus <dir>]` times decoding, the checksums and
small-stream setup in ReleaseFast, beside the code warp replaces. CI compiles the
benchmarks and never times them.

## Licence

MIT. See [LICENSE](LICENSE).
