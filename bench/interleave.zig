//! Run independent codec processes in alternating paired order.
//! The two previous-main arms use the same executable as a timing control.
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len != 4) return error.ExpectedPreviousMainBeforeCandidate;
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &buffer);
    const operations = [_][]const u8{ "crc32", "crc32c", "adler32", "deflate-encode-L1", "deflate-encode-L6", "deflate-encode-L9", "deflate-decode-std-L6-exact" };
    for ([_][]const u8{ "text", "noise" }) |kind| for (operations) |operation| {
        for (0..21) |sample| for (0..5) |index| {
            const stage = if (sample & 1 == 0) index else 4 - index;
            const executable = args[if (stage < 2) 1 else if (stage == 2) 2 else 3];
            var sample_buffer: [20]u8 = undefined;
            var stage_buffer: [20]u8 = undefined;
            const sample_text = try std.fmt.bufPrint(&sample_buffer, "{d}", .{sample});
            const stage_text = try std.fmt.bufPrint(&stage_buffer, "{d}", .{stage});
            const result = try std.process.run(init.gpa, init.io, .{ .argv = &.{ executable, kind, operation, sample_text, stage_text } });
            defer init.gpa.free(result.stdout);
            defer init.gpa.free(result.stderr);
            if (result.term != .exited or result.term.exited != 0) {
                try stdout.interface.writeAll(result.stderr);
                try stdout.interface.flush();
                return error.MeasurementFailed;
            }
            try stdout.interface.writeAll(result.stdout);
            try stdout.interface.flush();
        };
    };
}
