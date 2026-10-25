//! Matchfinders: where earlier bytes repeat the bytes at a position, within
//! DEFLATE's 32 KiB window, or GDeflate's 64 KiB.

const history = @import("match/history.zig");

pub const window = history.window;
pub const min_match = history.min_match;
pub const max_match = history.max_match;
pub const max_matches = history.max_matches;
pub const Match = history.Match;
pub const Position = history.Position;
pub const History = history.History;
pub const matchLengthIn = history.matchLengthIn;
pub const hash = history.hash;
pub const HashChainsFor = @import("match/HashChains.zig").HashChainsFor;
pub const HashTableFor = @import("match/HashTable.zig").HashTableFor;
pub const BinaryTreesFor = @import("match/BinaryTrees.zig").BinaryTreesFor;
pub const HashChains = HashChainsFor(window);
pub const HashTable = HashTableFor(window);
pub const BinaryTrees = BinaryTreesFor(window);

test {
    _ = history;
    _ = @import("match/HashTable.zig");
    _ = @import("match/BinaryTrees.zig");
}
