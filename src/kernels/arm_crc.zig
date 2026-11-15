//! CRC-32 and CRC-32C with AArch64's CRC32 instructions, eight bytes a
//! step. Built with the CRC extension enabled; run only where the CPU has
//! it.

const std = @import("std");
const instructions = @import("kernels_instructions");

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
    for (rest) |b| c = instructions.crc32b(c, b);
    return c;
}

inline fn crc32x(c: u32, word: u64) u32 {
    return instructions.crc32x(c, word);
}

/// The CRC-32C register `reg` continued over `bytes`.
pub fn crc32c(reg: u32, bytes: []const u8) u32 {
    var c = reg;
    var rest = bytes;
    while (rest.len >= 8) {
        c = instructions.crc32cx(c, std.mem.readInt(u64, rest[0..8], .little));
        rest = rest[8..];
    }
    for (rest) |b| c = instructions.crc32cb(c, b);
    return c;
}
