# Standard input snapshots

The transport frames preserve the 2026-10-06 captured inputs byte for byte.
`testdata/standard.json` records their decoded lengths, SHA-256 digests and
per-level compressed-size limits. `zig build check-sizes` verifies every digest
before checking each level's total for each corpus. It applies no single-input
size bound. Transport files are test-only and excluded from package paths.

- The tar is the Git project v2.51.0 source archive, including its COPYING file.
- The object batch is the 21,124 sampled Git objects, including each loose
  object's type, length and NUL in the size check. The source project's terms
  accompany the source at https://github.com/git/git.
- The twelve Silesia files retain their published order and full contents:
  https://sun.aei.polsl.pl/~sdeor/index.php?page=silesia.
- Captured generated inputs are regenerated from the specs in sizes.corpus.

Oracle capture and detailed per-input size evidence are maintained privately in
pedronaugusto/trials under warp/w5. These limits are fixed captured evidence,
not measurements made by CI against an installed library.
