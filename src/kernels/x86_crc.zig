//! CRC-32C with x86-64's CRC32 instruction (SSE4.2), eight bytes a step.
//! Built with SSE4.2; run only where the CPU has it.

const std = @import("std");
const instructions = @import("kernels_instructions");

/// The register `reg` continued over `bytes`.
pub fn crc32c(reg: u32, bytes: []const u8) u32 {
    var c: u64 = reg;
    var rest = bytes;
    while (rest.len >= 8) {
        c = instructions.crc32q(c, std.mem.readInt(u64, rest[0..8], .little));
        rest = rest[8..];
    }
    var c32: u32 = @truncate(c);
    for (rest) |b| c32 = instructions.crc32cByte(c32, b);
    return c32;
}
