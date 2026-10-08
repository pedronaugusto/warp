//! Matchfinders: where earlier bytes repeat the bytes at a position, within
//! DEFLATE's 32 KiB window.

const history = @import("match/history.zig");

pub const window = history.window;
pub const min_match = history.min_match;
pub const max_match = history.max_match;
pub const none = history.none;
pub const History = history.History;
pub const matchLengthIn = history.matchLengthIn;
pub const hash = history.hash;
pub const rebase = history.rebase;
pub const HashChains = @import("match/HashChains.zig");
pub const HashTable = @import("match/HashTable.zig");
pub const BinaryTrees = @import("match/BinaryTrees.zig");

test {
    _ = history;
    _ = HashTable;
    _ = BinaryTrees;
}
