//! The code warp replaces in the family, copied as it was so that warp's
//! benchmarks can time it beside warp: relic's inflate (src/odb/inflate.zig)
//! and CRC-32 (src/crc32.zig) at relic 90300de, and chronicle's CRC-32C
//! (src/journal/crc32c.zig) at chronicle bbdfd34. Each is deleted once its
//! package checksums or decodes with warp.

pub const inflate = @import("inflate.zig");
pub const crc32 = @import("crc32.zig");
pub const crc32c = @import("crc32c.zig");

test {
    _ = inflate;
    _ = crc32;
    _ = crc32c;
}
