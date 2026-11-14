//! A match finder's raw probe: the input addressed by index on the axis its tables store, so one
//! register serves current positions and candidates alike, as in the reference encoder's loops.
//! Index `i` is the byte at the input's address plus `i - start`. Each read says how many bytes it
//! takes and checks in safe builds (Debug and ReleaseSafe) that they lie in the input; ReleaseFast
//! pays nothing. glint's P007 seam for zstd's match finders (glint.json).
const std = @import("std");
const aegis = @import("aegis");

pub const Probe = struct {
    /// The input's address less `start`, wrapping: the address of index 0.
    base: usize,
    /// The indices that address the input, kept where safe builds check them.
    bounds: if (std.debug.runtime_safety) struct { start: usize, end: usize } else void,

    /// The probe of `in`, whose first byte is at index `start`.
    pub fn init(in: []const u8, start: usize) Probe {
        return .{
            .base = @intFromPtr(in.ptr) -% start,
            .bounds = if (std.debug.runtime_safety) .{ .start = start, .end = start + in.len } else {},
        };
    }

    /// The `n` bytes from index `i`, which lie in the input.
    pub inline fn at(p: Probe, i: usize, comptime n: usize) *const [n]u8 {
        if (std.debug.runtime_safety) aegis.assert.invariant(p.bounds.start <= i and i + n <= p.bounds.end, "a probe inside the input");
        return @ptrFromInt(p.base +% i);
    }

    /// Asks the cache for the line holding index `i`, which may lie past the input: a prefetch
    /// never faults and reads nothing.
    pub inline fn prefetch(p: Probe, i: usize) void {
        @prefetch(@as([*]const u8, @ptrFromInt(p.base +% i)), .{});
    }
};
