//! The tests whose work is shared between threads: parallel compression and
//! decoding, speculative decoding, and decoding on a thread of its own. What
//! ThreadSanitizer runs (`concurrent`), and the `test` step with the rest.

test {
    _ = @import("testing/parallel_test.zig");
    _ = @import("testing/speculative_test.zig");
    _ = @import("testing/zstd_parallel_test.zig");
    _ = @import("testing/index_test.zig");
    _ = @import("testing/api_test.zig");
}
