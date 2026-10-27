//! xz's filters before LZMA2: Delta and the branch converters (BCJ) for
//! x86, PowerPC, IA-64, ARM, ARM-Thumb, SPARC, ARM64 and RISC-V, each
//! liblzma 5.8.4's, both ways. A converter runs over a buffer from a start
//! position and returns where it stopped; the bytes after (fewer than one
//! instruction) are left as they are, as liblzma leaves a stream's tail.
//! Decoding runs over a block's whole output in place; the streaming
//! decoders keep the tail and the converter's state between calls.

const std = @import("std");

pub const Id = enum(u64) {
    delta = 0x03,
    x86 = 0x04,
    powerpc = 0x05,
    ia64 = 0x06,
    arm = 0x07,
    armthumb = 0x08,
    sparc = 0x09,
    arm64 = 0x0a,
    riscv = 0x0b,
    lzma2 = 0x21,
    _,
};

/// A filter of a chain before LZMA2, with its properties.
pub const Filter = union(enum) {
    delta: u16,
    bcj: struct { kind: Bcj, start: u32 },
};

pub const Bcj = enum {
    x86,
    powerpc,
    ia64,
    arm,
    armthumb,
    sparc,
    arm64,
    riscv,

    /// The start offset's alignment.
    pub fn alignment(b: Bcj) u32 {
        return switch (b) {
            .x86 => 1,
            .armthumb, .riscv => 2,
            .ia64 => 16,
            else => 4,
        };
    }

    /// The most bytes a converter may leave at a buffer's end.
    pub fn tail(b: Bcj) u32 {
        return switch (b) {
            .x86 => 5,
            .ia64 => 16,
            .riscv => 8,
            else => 4,
        };
    }
};

/// A filter from its id and properties as a block header holds them; null
/// where liblzma refuses them (`LZMA_OPTIONS_ERROR`).
pub fn parse(id: Id, props: []const u8) ?Filter {
    const kind: Bcj = switch (id) {
        .delta => {
            if (props.len != 1) return null;
            return .{ .delta = @as(u16, props[0]) + 1 };
        },
        .x86 => .x86,
        .powerpc => .powerpc,
        .ia64 => .ia64,
        .arm => .arm,
        .armthumb => .armthumb,
        .sparc => .sparc,
        .arm64 => .arm64,
        .riscv => .riscv,
        else => return null,
    };
    if (props.len != 0 and props.len != 4) return null;
    const start = if (props.len == 4) std.mem.readInt(u32, props[0..4], .little) else 0;
    if (start & (kind.alignment() - 1) != 0) return null;
    return .{ .bcj = .{ .kind = kind, .start = start } };
}

/// A converter's state between calls: x86 keeps the last opcodes' mask.
pub const State = struct {
    /// The position of `buf[0]` in the stream, from the start offset.
    pos: u32 = 0,
    prev_mask: u32 = 0,
    prev_pos: u32 = 0 -% @as(u32, 5),
    /// Delta's last 256 bytes, and where the next goes.
    history: [256]u8 = @splat(0),
    at: u8 = 0,

    pub fn init(f: Filter) State {
        return switch (f) {
            .delta => .{},
            .bcj => |b| .{ .pos = b.start },
        };
    }
};

/// Convert `buf` back (`encode` false) or forward; returns the bytes done,
/// all of them for Delta, and moves the state past them.
pub fn run(f: Filter, s: *State, buf: []u8, comptime encode: bool) usize {
    const n = switch (f) {
        .delta => |dist| blk: {
            delta(s, dist, buf, encode);
            break :blk buf.len;
        },
        .bcj => |b| switch (b.kind) {
            .x86 => x86(s, buf, encode),
            .powerpc => powerpc(s.pos, buf, encode),
            .ia64 => ia64(s.pos, buf, encode),
            .arm => arm(s.pos, buf, encode),
            .armthumb => armthumb(s.pos, buf, encode),
            .sparc => sparc(s.pos, buf, encode),
            .arm64 => arm64(s.pos, buf, encode),
            .riscv => if (encode) riscvEncode(s.pos, buf) else riscvDecode(s.pos, buf),
        },
    };
    s.pos +%= @truncate(n);
    return n;
}

fn delta(s: *State, dist: u16, buf: []u8, comptime encode: bool) void {
    for (buf) |*b| {
        const before = s.history[s.at +% @as(u8, @truncate(dist))];
        const plain = b.*;
        b.* = if (encode) plain -% before else plain +% before;
        s.history[s.at] = if (encode) plain else b.*;
        s.at -%= 1;
    }
}

fn isMsByte(b: u8) bool {
    return b == 0 or b == 0xff;
}

fn x86(s: *State, buf: []u8, comptime encode: bool) usize {
    const bit_of_mask = [5]u32{ 0, 1, 2, 2, 3 };
    if (buf.len < 5) return 0;
    const now = s.pos;
    var prev_mask = s.prev_mask;
    var prev_pos = s.prev_pos;
    if (now -% prev_pos > 5) prev_pos = now -% 5;
    const limit = buf.len - 5;
    var i: usize = 0;
    while (i <= limit) {
        var b = buf[i];
        if (b != 0xe8 and b != 0xe9) {
            i += 1;
            continue;
        }
        const offset = now +% @as(u32, @truncate(i)) -% prev_pos;
        prev_pos = now +% @as(u32, @truncate(i));
        if (offset > 5) {
            prev_mask = 0;
        } else for (0..offset) |_| {
            prev_mask &= 0x77;
            prev_mask <<= 1;
        }
        b = buf[i + 4];
        if (isMsByte(b) and prev_mask >> 1 <= 4 and prev_mask >> 1 != 3) {
            var src = std.mem.readInt(u32, buf[i + 1 ..][0..4], .little);
            var dest: u32 = undefined;
            const at = now +% @as(u32, @truncate(i)) +% 5;
            while (true) {
                dest = if (encode) src +% at else src -% at;
                if (prev_mask == 0) break;
                const k = bit_of_mask[prev_mask >> 1];
                b = @truncate(dest >> @intCast(24 - k * 8));
                if (!isMsByte(b)) break;
                src = dest ^ ((@as(u32, 1) << @intCast(32 - k * 8)) - 1);
            }
            dest &= 0x01ff_ffff;
            dest |= 0 -% (dest & 0x0100_0000);
            std.mem.writeInt(u32, buf[i + 1 ..][0..4], dest, .little);
            i += 5;
            prev_mask = 0;
        } else {
            i += 1;
            prev_mask |= 1;
            if (isMsByte(b)) prev_mask |= 0x10;
        }
    }
    s.prev_mask = prev_mask;
    s.prev_pos = prev_pos;
    return i;
}

fn arm(now: u32, buf: []u8, comptime encode: bool) usize {
    const size = buf.len & ~@as(usize, 3);
    var i: usize = 0;
    while (i < size) : (i += 4) {
        if (buf[i + 3] != 0xeb) continue;
        const src = (@as(u32, buf[i + 2]) << 16 | @as(u32, buf[i + 1]) << 8 | buf[i]) << 2;
        const at = now +% @as(u32, @truncate(i)) +% 8;
        const dest = (if (encode) at +% src else src -% at) >> 2;
        buf[i + 2] = @truncate(dest >> 16);
        buf[i + 1] = @truncate(dest >> 8);
        buf[i] = @truncate(dest);
    }
    return i;
}

fn armthumb(now: u32, buf: []u8, comptime encode: bool) usize {
    if (buf.len < 4) return 0;
    const size = buf.len - 4;
    var i: usize = 0;
    while (i <= size) : (i += 2) {
        if (buf[i + 1] & 0xf8 != 0xf0 or buf[i + 3] & 0xf8 != 0xf8) continue;
        const src = ((@as(u32, buf[i + 1]) & 7) << 19 | @as(u32, buf[i]) << 11 | (@as(u32, buf[i + 3]) & 7) << 8 | buf[i + 2]) << 1;
        const at = now +% @as(u32, @truncate(i)) +% 4;
        const dest = (if (encode) at +% src else src -% at) >> 1;
        buf[i + 1] = @truncate(0xf0 | ((dest >> 19) & 7));
        buf[i] = @truncate(dest >> 11);
        buf[i + 3] = @truncate(0xf8 | ((dest >> 8) & 7));
        buf[i + 2] = @truncate(dest);
        i += 2;
    }
    return i;
}

fn powerpc(now: u32, buf: []u8, comptime encode: bool) usize {
    const size = buf.len & ~@as(usize, 3);
    var i: usize = 0;
    while (i < size) : (i += 4) {
        if (buf[i] >> 2 != 0x12 or buf[i + 3] & 3 != 1) continue;
        const src = (@as(u32, buf[i]) & 3) << 24 | @as(u32, buf[i + 1]) << 16 | @as(u32, buf[i + 2]) << 8 | (@as(u32, buf[i + 3]) & ~@as(u32, 3));
        const at = now +% @as(u32, @truncate(i));
        const dest = if (encode) at +% src else src -% at;
        buf[i] = @truncate(0x48 | ((dest >> 24) & 3));
        buf[i + 1] = @truncate(dest >> 16);
        buf[i + 2] = @truncate(dest >> 8);
        buf[i + 3] = (buf[i + 3] & 3) | @as(u8, @truncate(dest));
    }
    return i;
}

fn sparc(now: u32, buf: []u8, comptime encode: bool) usize {
    const size = buf.len & ~@as(usize, 3);
    var i: usize = 0;
    while (i < size) : (i += 4) {
        if (!((buf[i] == 0x40 and buf[i + 1] & 0xc0 == 0) or (buf[i] == 0x7f and buf[i + 1] & 0xc0 == 0xc0))) continue;
        const src = std.mem.readInt(u32, buf[i..][0..4], .big) << 2;
        const at = now +% @as(u32, @truncate(i));
        var dest = (if (encode) at +% src else src -% at) >> 2;
        dest = ((0 -% ((dest >> 22) & 1)) << 22 & 0x3fff_ffff) | (dest & 0x3f_ffff) | 0x4000_0000;
        std.mem.writeInt(u32, buf[i..][0..4], dest, .big);
    }
    return i;
}

fn ia64(now: u32, buf: []u8, comptime encode: bool) usize {
    const branch = [32]u32{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 4, 4, 6, 6, 0, 0, 7, 7, 4, 4, 0, 0, 4, 4, 0, 0 };
    const size = buf.len & ~@as(usize, 15);
    var i: usize = 0;
    while (i < size) : (i += 16) {
        const mask = branch[buf[i] & 0x1f];
        var bit_pos: u32 = 5;
        for (0..3) |slot| {
            defer bit_pos += 41;
            if ((mask >> @intCast(slot)) & 1 == 0) continue;
            const byte_pos = bit_pos >> 3;
            const bit_res: u6 = @intCast(bit_pos & 7);
            var instruction: u64 = 0;
            for (0..6) |j| instruction += @as(u64, buf[i + j + byte_pos]) << @intCast(8 * j);
            var norm = instruction >> bit_res;
            if ((norm >> 37) & 0xf != 0x5 or (norm >> 9) & 7 != 0) continue;
            var src: u32 = @truncate((norm >> 13) & 0xf_ffff);
            src |= @as(u32, @truncate((norm >> 36) & 1)) << 20;
            src <<= 4;
            const at = now +% @as(u32, @truncate(i));
            const dest = (if (encode) at +% src else src -% at) >> 4;
            norm &= ~(@as(u64, 0x8f_ffff) << 13);
            norm |= @as(u64, dest & 0xf_ffff) << 13;
            norm |= @as(u64, dest & 0x10_0000) << (36 - 20);
            instruction &= (@as(u64, 1) << bit_res) - 1;
            instruction |= norm << bit_res;
            for (0..6) |j| buf[i + j + byte_pos] = @truncate(instruction >> @intCast(8 * j));
        }
    }
    return i;
}

fn arm64(now: u32, buf: []u8, comptime encode: bool) usize {
    const size = buf.len & ~@as(usize, 3);
    var i: usize = 0;
    while (i < size) : (i += 4) {
        var pc = now +% @as(u32, @truncate(i));
        var instr = std.mem.readInt(u32, buf[i..][0..4], .little);
        if (instr >> 26 == 0x25) {
            const src = instr;
            pc >>= 2;
            if (!encode) pc = 0 -% pc;
            instr = 0x9400_0000 | ((src +% pc) & 0x03ff_ffff);
            std.mem.writeInt(u32, buf[i..][0..4], instr, .little);
        } else if (instr & 0x9f00_0000 == 0x9000_0000) {
            const src = ((instr >> 29) & 3) | ((instr >> 3) & 0x001f_fffc);
            if ((src +% 0x0002_0000) & 0x001c_0000 != 0) continue;
            instr &= 0x9000_001f;
            pc >>= 12;
            if (!encode) pc = 0 -% pc;
            const dest = src +% pc;
            instr |= (dest & 3) << 29;
            instr |= (dest & 0x0003_fffc) << 3;
            instr |= (0 -% (dest & 0x0002_0000)) & 0x00e0_0000;
            std.mem.writeInt(u32, buf[i..][0..4], instr, .little);
        }
    }
    return i;
}

fn notAuipcPair(auipc: u32, inst2: u32) bool {
    return ((auipc << 8) ^ (inst2 -% 3)) & 0xf_8003 != 0;
}

fn notSpecialAuipc(auipc: u32, rs1: u32) bool {
    return (auipc -% 0x3117) << 18 >= rs1 & 0x1d;
}

fn riscvDecode(now: u32, buf: []u8) usize {
    if (buf.len < 8) return 0;
    const size = buf.len - 8;
    var i: usize = 0;
    while (i <= size) : (i += 2) {
        var inst: u32 = buf[i];
        if (inst == 0xef) {
            const b1: u32 = buf[i + 1];
            if (b1 & 0x0d != 0) continue;
            const b2: u32 = buf[i + 2];
            const b3: u32 = buf[i + 3];
            const pc = now +% @as(u32, @truncate(i));
            var addr = ((b1 & 0xf0) << 13) | (b2 << 9) | (b3 << 1);
            addr -%= pc;
            buf[i + 1] = @truncate((b1 & 0x0f) | ((addr >> 8) & 0xf0));
            buf[i + 2] = @truncate(((addr >> 16) & 0x0f) | ((addr >> 7) & 0x10) | ((addr << 4) & 0xe0));
            buf[i + 3] = @truncate(((addr >> 4) & 0x7f) | ((addr >> 13) & 0x80));
            i += 4 - 2;
        } else if (inst & 0x7f == 0x17) {
            inst |= @as(u32, buf[i + 1]) << 8 | @as(u32, buf[i + 2]) << 16 | @as(u32, buf[i + 3]) << 24;
            var inst2: u32 = undefined;
            if (inst & 0xe80 != 0) {
                inst2 = std.mem.readInt(u32, buf[i + 4 ..][0..4], .little);
                if (notAuipcPair(inst, inst2)) {
                    i += 6 - 2;
                    continue;
                }
                var addr = inst & 0xffff_f000;
                addr +%= inst2 >> 20;
                inst = 0x17 | (2 << 7) | (inst2 << 12);
                inst2 = addr;
            } else {
                const rs1 = inst >> 27;
                if (notSpecialAuipc(inst, rs1)) {
                    i += 4 - 2;
                    continue;
                }
                var addr = std.mem.readInt(u32, buf[i + 4 ..][0..4], .big);
                addr -%= now +% @as(u32, @truncate(i));
                inst2 = (inst >> 12) | (addr << 20);
                inst = 0x17 | (rs1 << 7) | ((addr +% 0x800) & 0xffff_f000);
            }
            std.mem.writeInt(u32, buf[i..][0..4], inst, .little);
            std.mem.writeInt(u32, buf[i + 4 ..][0..4], inst2, .little);
            i += 8 - 2;
        }
    }
    return i;
}

fn riscvEncode(now: u32, buf: []u8) usize {
    if (buf.len < 8) return 0;
    const size = buf.len - 8;
    var i: usize = 0;
    while (i <= size) : (i += 2) {
        var inst: u32 = buf[i];
        if (inst == 0xef) {
            const b1: u32 = buf[i + 1];
            if (b1 & 0x0d != 0) continue;
            const b2: u32 = buf[i + 2];
            const b3: u32 = buf[i + 3];
            const pc = now +% @as(u32, @truncate(i));
            var addr = ((b1 & 0xf0) << 8) | ((b2 & 0x0f) << 16) | ((b2 & 0x10) << 7) | ((b2 & 0xe0) >> 4) | ((b3 & 0x7f) << 4) | ((b3 & 0x80) << 13);
            addr +%= pc;
            buf[i + 1] = @truncate((b1 & 0x0f) | ((addr >> 13) & 0xf0));
            buf[i + 2] = @truncate(addr >> 9);
            buf[i + 3] = @truncate(addr >> 1);
            i += 4 - 2;
        } else if (inst & 0x7f == 0x17) {
            inst |= @as(u32, buf[i + 1]) << 8 | @as(u32, buf[i + 2]) << 16 | @as(u32, buf[i + 3]) << 24;
            if (inst & 0xe80 != 0) {
                const inst2 = std.mem.readInt(u32, buf[i + 4 ..][0..4], .little);
                if (notAuipcPair(inst, inst2)) {
                    i += 6 - 2;
                    continue;
                }
                var addr = inst & 0xffff_f000;
                addr +%= (inst2 >> 20) -% ((inst2 >> 19) & 0x1000);
                addr +%= now +% @as(u32, @truncate(i));
                inst = 0x17 | (2 << 7) | (inst2 << 12);
                std.mem.writeInt(u32, buf[i..][0..4], inst, .little);
                std.mem.writeInt(u32, buf[i + 4 ..][0..4], addr, .big);
            } else {
                const rs1 = inst >> 27;
                if (notSpecialAuipc(inst, rs1)) {
                    i += 4 - 2;
                    continue;
                }
                const fake_addr = std.mem.readInt(u32, buf[i + 4 ..][0..4], .little);
                const fake_inst2 = (inst >> 12) | (fake_addr << 20);
                inst = 0x17 | (rs1 << 7) | (fake_addr & 0xffff_f000);
                std.mem.writeInt(u32, buf[i..][0..4], inst, .little);
                std.mem.writeInt(u32, buf[i + 4 ..][0..4], fake_inst2, .little);
            }
            i += 8 - 2;
        }
    }
    return i;
}

test "every converter undoes itself, from any start" {
    var prng: std.Random.DefaultPrng = .init(9);
    const r = prng.random();
    var buf: [4096]u8 = undefined;
    var copy: [4096]u8 = undefined;
    for (std.enums.values(Bcj)) |kind| for ([_]u32{ 0, 4096, 0xffff_fff0 }) |start| {
        // Bytes rich in each converter's opcodes.
        for (&buf) |*b| b.* = switch (r.uintLessThan(u8, 8)) {
            0 => 0xe8,
            1 => 0xeb,
            2 => 0x94,
            3 => 0x17,
            4 => 0xef,
            5 => 0x48,
            else => r.int(u8),
        };
        copy = buf;
        const f: Filter = .{ .bcj = .{ .kind = kind, .start = start & ~(kind.alignment() - 1) } };
        var e = State.init(f);
        const n = run(f, &e, &buf, true);
        var d = State.init(f);
        errdefer std.debug.print("{s} from {d}\n", .{ @tagName(kind), start });
        try std.testing.expectEqual(n, run(f, &d, &buf, false));
        try std.testing.expectEqualSlices(u8, &copy, &buf);
    };
    var dbuf: [300]u8 = undefined;
    r.bytes(&dbuf);
    const plain = dbuf;
    var e: State = .{};
    _ = run(.{ .delta = 7 }, &e, &dbuf, true);
    var d: State = .{};
    _ = run(.{ .delta = 7 }, &d, &dbuf, false);
    try std.testing.expectEqualSlices(u8, &plain, &dbuf);
}
