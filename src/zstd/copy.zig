//! zstd's unchecked copies: whole vectors moved past the length asked for, so a short copy, the
//! common one, takes no branch on its length. Each takes the slices it may touch, says how far past
//! `len` it reads and writes, and checks that in safe builds (Debug and ReleaseSafe), so a caller
//! that keeps too little slack traps there; ReleaseFast pays nothing. glint's P007 seam for zstd
//! (glint.json): everything else in the decoder is checked code.
const std = @import("std");
const aegis = @import("aegis");

/// Each copy here reads and writes less than this past the `len` it is given.
pub const slack = 32;

/// A precondition, checked in Debug and ReleaseSafe only.
inline fn require(condition: bool, comptime message: []const u8) void {
    if (std.debug.runtime_safety) aegis.assert.invariant(condition, message);
}

/// The bytes `wild16` reads and writes for `len`: 16, then 32 at a time while below `len`.
pub fn wild16Extent(len: usize) usize {
    if (len <= 16) return 16;
    return 16 + 32 * blocks(len - 16, 32);
}

/// The bytes `wild32` reads and writes for `len`: 32 at a time, at least once.
pub fn wild32Extent(len: usize) usize {
    return 32 * @max(1, blocks(len, 32));
}

/// The bytes `overlap` writes for `len`: 8 at a time, at least once.
pub fn overlapExtent(len: usize) usize {
    return 8 * @max(1, blocks(len, 8));
}

/// How many `size`-byte blocks cover `len` bytes.
fn blocks(len: usize, comptime size: usize) usize {
    return len / size + @intFromBool(len % size != 0);
}

/// Sixteen bytes of `src` to `dst`, read whole before any is written.
pub inline fn copy16(dst: []u8, src: []const u8) void {
    require(dst.len >= 16 and src.len >= 16, "copy16: 16 bytes each side");
    const v: @Vector(16, u8) = src.ptr[0..16].*;
    dst.ptr[0..16].* = v;
}

/// Eight bytes of `src` to `dst`, read whole before any is written.
inline fn copy8(dst: [*]u8, src: [*]const u8) void {
    const v: @Vector(8, u8) = src[0..8].*;
    dst[0..8].* = v;
}

/// `len` bytes of `src` to `dst` 16 at a time, the first 16 whatever `len` is: it reads and writes
/// `wild16Extent(len)` bytes, which `dst` and `src` hold. `src` starts at least 16 before `dst` in
/// one buffer, or anywhere in another.
pub inline fn wild16(dst: []u8, src: []const u8, len: usize) void {
    const extent = wild16Extent(len);
    require(dst.len >= extent and src.len >= extent, "wild16: the extent each side");
    copy16(dst, src);
    var i: usize = 16;
    while (i < len) : (i += 32) {
        copy16(dst[i..], src[i..]);
        copy16(dst[i + 16 ..], src[i + 16 ..]);
    }
}

/// `len` bytes of `src` to `dst` 32 at a time, the first 32 whatever `len` is (a branch on a short
/// length mispredicts): it reads and writes `wild32Extent(len)` bytes, which `dst` and `src` hold.
/// `src` starts at least 16 before `dst` in one buffer, or anywhere in another.
pub inline fn wild32(dst: []u8, src: []const u8, len: usize) void {
    const extent = wild32Extent(len);
    require(dst.len >= extent and src.len >= extent, "wild32: the extent each side");
    const d = dst.ptr;
    const s = src.ptr;
    var i: usize = 0;
    while (true) {
        const lo: @Vector(16, u8) = (s + i)[0..16].*;
        (d + i)[0..16].* = lo;
        const hi: @Vector(16, u8) = (s + i + 16)[0..16].*;
        (d + i + 16)[0..16].* = hi;
        i += 32;
        if (i >= len) break;
    }
}

/// A match closer than 16 bytes, in `buf` at `at`, `offset` back: its first 8 bytes laid down so
/// the distance from source to destination becomes 8 or more (a multiple of the offset), then 8
/// at a time. It writes `overlapExtent(len)` bytes from `at`, which `buf` holds, and reads only
/// before what it writes.
pub inline fn overlap(buf: []u8, at: usize, offset: usize, len: usize) void {
    require(offset >= 1 and offset < 16 and offset <= at, "overlap: an offset from 1 to 15 inside what is written");
    require(at + overlapExtent(len) <= buf.len, "overlap: the extent inside the buffer");
    var dst = buf.ptr + at;
    var src = buf.ptr + (at - offset);
    if (offset < 8) {
        // Bytes 4-7 repeat the pattern from `add` on; after the 8 bytes the source has moved on
        // by `advance`.
        const add = [8]u8{ 0, 1, 2, 1, 4, 4, 4, 4 };
        const advance = [8]u8{ 0, 1, 2, 2, 4, 3, 2, 1 };
        dst[0] = src[0];
        dst[1] = src[1];
        dst[2] = src[2];
        dst[3] = src[3];
        const v: @Vector(4, u8) = (src + add[offset])[0..4].*;
        dst[4..8].* = v;
        src += advance[offset];
    } else {
        copy8(dst, src);
        src += 8;
    }
    dst += 8;
    var i: usize = 8;
    while (i < len) : (i += 8) {
        copy8(dst, src);
        dst += 8;
        src += 8;
    }
}
