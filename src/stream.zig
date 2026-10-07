//! Streaming: input and output in pieces of any size, each stream
//! resumable at any byte, on memory the caller gives.

pub const Inflate = @import("stream/Inflate.zig");

test {
    _ = Inflate;
}
