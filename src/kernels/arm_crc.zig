//! CRC-32 and CRC-32C with AArch64's CRC32 instructions, eight bytes a
//! step. Built with the CRC extension enabled; run only where the CPU has
//! it.

const std = @import("std");

/// The register `reg` continued over `bytes`.
pub fn crc32(reg: u32, bytes: []const u8) u32 {
    var c = reg;
    var rest = bytes;
    while (rest.len >= 32) {
        inline for (0..4) |i| c = crc32x(c, std.mem.readInt(u64, rest[i * 8 ..][0..8], .little));
        rest = rest[32..];
    }
    while (rest.len >= 8) {
        c = crc32x(c, std.mem.readInt(u64, rest[0..8], .little));
        rest = rest[8..];
    }
    for (rest) |b| c = asm ("crc32b %[out:w], %[in:w], %[b:w]"
        : [out] "=r" (-> u32),
        : [in] "r" (c),
          [b] "r" (@as(u32, b)),
    );
    return c;
}

inline fn crc32x(c: u32, word: u64) u32 {
    return asm ("crc32x %[out:w], %[in:w], %[word:x]"
        : [out] "=r" (-> u32),
        : [in] "r" (c),
          [word] "r" (word),
    );
}

/// The CRC-32C register `reg` continued over `bytes`.
pub fn crc32c(reg: u32, bytes: []const u8) u32 {
    var c = reg;
    var rest = bytes;
    while (rest.len >= 8) {
        c = asm ("crc32cx %[out:w], %[in:w], %[word:x]"
            : [out] "=r" (-> u32),
            : [in] "r" (c),
              [word] "r" (std.mem.readInt(u64, rest[0..8], .little)),
        );
        rest = rest[8..];
    }
    for (rest) |b| c = asm ("crc32cb %[out:w], %[in:w], %[b:w]"
        : [out] "=r" (-> u32),
        : [in] "r" (c),
          [b] "r" (@as(u32, b)),
    );
    return c;
}
