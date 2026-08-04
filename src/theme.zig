//! Color theme selection for the generated site.

const std = @import("std");

pub const Theme = enum {
    default,
    monokai,
    vscode_light,
    vscode_dark,

    pub fn fromStr(s: []const u8) ?Theme {
        if (std.mem.eql(u8, s, "default")) return .default;
        if (std.mem.eql(u8, s, "monokai")) return .monokai;
        if (std.mem.eql(u8, s, "vscode-light")) return .vscode_light;
        if (std.mem.eql(u8, s, "vscode-dark")) return .vscode_dark;
        return null;
    }

    /// Returns the `data-theme` attribute value, or null for the default theme.
    pub fn toAttr(self: Theme) ?[]const u8 {
        return switch (self) {
            .default => null,
            .monokai => "monokai",
            .vscode_light => "vscode-light",
            .vscode_dark => "vscode-dark",
        };
    }
};
