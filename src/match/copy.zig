//! Copying an LZ77 match into the output it reads from: 16- and 32-byte
//! stores for distances of 8 and more, and a period shorter than 8 spread
//! across a vector and stored a whole number of periods at a time. The
//! stores may reach past the match's end (see `copyMatch`), so a decoder
//! uses this where it has kept that much spare output. LZ4's and Snappy's
//! decoders share it.

const aegis = @import("aegis");
const instructions = @import("kernels_instructions");

/// `x`, as a value the optimizer cannot rewrite through: a sum built from
/// it stays the sum written, so `chainless(ip + 3) + lit` keeps the `+ 3`
/// off the path from `lit`, where reassociation would put it back.
pub inline fn chainless(x: usize) usize {
    return instructions.barrier(x);
}

/// Copy a match of `len` bytes to `out[at..]` from `offset` back, with
/// stores that may reach 31 bytes past its end.
pub inline fn copyMatch(out: []u8, at: usize, offset: usize, len: usize) void {
    // The caller keeps the match and the stores' reach inside `out`.
    aegis.assert.invariant(at <= out.len, "at <= out.len");
    aegis.assert.invariant(len <= out.len - at, "len <= out.len - at");
    aegis.assert.invariant(out.len - at - len >= 32, "out.len - at - len >= 32");
    // The decoders refuse a match with no distance, or one reaching before the output.
    aegis.assert.invariant(offset != 0 and offset <= at, "0 < offset <= at");
    const from = at - offset;
    if (offset >= 16) {
        // Each 16-byte store reads bytes already written.
        var i: usize = 0;
        while (i < len) : (i += 32) {
            out[at + i ..][0..16].* = out[from + i ..][0..16].*;
            out[at + i + 16 ..][0..16].* = out[from + i + 16 ..][0..16].*;
        }
        return;
    }
    if (offset >= 8) {
        var i: usize = 0;
        while (i < len) : (i += 16) {
            out[at + i ..][0..8].* = out[from + i ..][0..8].*;
            out[at + i + 8 ..][0..8].* = out[from + i + 8 ..][0..8].*;
        }
        return;
    }
    // A period shorter than 8: the period's bytes repeated across 16,
    // stored twice a step, each store a whole number of periods on.
    const v: @Vector(16, u8) = out[from..][0..16].*;
    switch (offset) {
        inline 1...7 => |period| {
            const pattern: @Vector(16, u8) = @shuffle(u8, v, undefined, periodMask(period));
            // A step the optimizer cannot see, or the period of one becomes
            // a call to `memset`, slower for a match's few stores.
            const step = chainless(16 - 16 % period);
            var i: usize = 0;
            while (i < len) : (i += 2 * step) {
                out[at + i ..][0..16].* = pattern;
                out[at + i + step ..][0..16].* = pattern;
            }
        },
        else => unreachable, // offsets of 8 and more returned above, and 0 is refused at the top
    }
}

fn periodMask(comptime period: usize) @Vector(16, i32) {
    var mask: [16]i32 = undefined;
    for (&mask, 0..) |*m, i| m.* = @intCast(i % period);
    return mask;
}
