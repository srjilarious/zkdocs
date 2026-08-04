//! Terminal progress reporting for the `renderSite` build pipeline.

const std = @import("std");

pub const Progress = struct {
    step: usize = 0,
    total: usize,

    pub fn init(total: usize) Progress {
        return .{ .total = total };
    }

    /// Print a numbered step header and advance the step counter.
    pub fn begin(self: *Progress, label: []const u8) void {
        self.step += 1;
        std.debug.print("  [{d}/{d}] {s}\n", .{ self.step, self.total, label });
    }

    /// Overwrite the progress line with the current filename (no newline).
    /// Uses ANSI erase-to-EOL so shorter names don't leave trailing chars.
    pub fn setCurrent(name: []const u8) void {
        std.debug.print("        {s}\x1b[K\r", .{name});
    }

    /// Advance past the progress line (call after a file-level loop).
    pub fn endFiles() void {
        std.debug.print("\n", .{});
    }
};
