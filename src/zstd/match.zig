//! Match strategies and their shared indexed window.
/// One hash table, with accelerated scanning.
pub const fast = @import("match/fast.zig");
/// Long and short hash tables.
pub const dfast = @import("match/dfast.zig");
/// Greedy and lazy parsing over rows, chains and binary trees.
pub const lazy = @import("match/lazy.zig");
/// Binary-tree candidates and optimal parsing.
pub const opt = @import("match/opt.zig");
/// Byte positions in a continued index space.
pub const window = @import("match/window.zig");
