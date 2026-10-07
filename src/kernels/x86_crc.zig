//! CRC-32C with x86-64's CRC32 instruction (SSE4.2), eight bytes a step.
//! Built with SSE4.2; run only where the CPU has it.

const std = @import("std");

/// The register `reg` continued over `bytes`.
pub fn crc32c(reg: u32, bytes: []const u8) u32 {
    var c: u64 = reg;
    var rest = bytes;
    while (rest.len >= 8) {
        c = asm ("crc32q %[word], %[c]"
            : [c] "=r" (-> u64),
            : [in] "0" (c),
              [word] "r" (std.mem.readInt(u64, rest[0..8], .little)),
        );
        rest = rest[8..];
    }
    var c32: u32 = @truncate(c);
    for (rest) |b| c32 = asm ("crc32b %[b], %[c]"
        : [c] "=r" (-> u32),
        : [in] "0" (c32),
          [b] "r" (b),
    );
    return c32;
}
