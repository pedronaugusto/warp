//! CRC-32, CRC-32C and Adler-32, with the kernels each runs on.

pub const Crc32 = crc32_.Crc32;
pub const crc32 = crc32_.crc32;
pub const crc32Combine = crc32_.crc32Combine;
pub const Crc32c = crc32c_.Crc32c;
pub const crc32c = crc32c_.crc32c;
pub const crc32cCombine = crc32c_.crc32cCombine;
pub const Adler32 = adler32_.Adler32;
pub const adler32 = adler32_.adler32;
pub const adler32Combine = adler32_.adler32Combine;
pub const Kernel = @import("checksum/kernel.zig").Kernel;

const crc_ = @import("crc");
const crc32_ = @import("checksum/crc32.zig");
const crc32c_ = @import("checksum/crc32c.zig");
const adler32_ = @import("checksum/adler32.zig");

/// The kernel each checksum runs on.
pub const Kernels = struct { crc32: Kernel, crc32c: Kernel, adler32: Kernel };

/// Which kernel each checksum runs on this CPU.
pub fn kernels() Kernels {
    return .{ .crc32 = crc32_.kernel(), .crc32c = crc32c_.kernel(), .adler32 = adler32_.kernel() };
}

test {
    _ = @import("cpu.zig");
    _ = crc_;
    _ = crc32_;
    _ = crc32c_;
    _ = adler32_;
}
