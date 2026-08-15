//! Site-wide render context shared by every page renderer: conf-derived
//! settings, extracted modules and configured pages, the cross-module type
//! index, and the shared cache/progress reporter. Built once per
//! `renderSite` call and passed around by pointer instead of threading a
//! dozen-plus individual parameters through every helper.
//!
//! Also home to `Buf` (the per-page output buffer) and `htmlEscape`, since
//! nearly every renderer needs both alongside the context itself.

const std = @import("std");
const symbols = @import("./symbols.zig");
const emoji = @import("./emoji.zig");
const cache_mod = @import("./cache.zig");
const theme_mod = @import("./theme.zig");
const pages = @import("./pages.zig");
const progress_mod = @import("./progress.zig");

pub const Theme = theme_mod.Theme;
pub const Progress = progress_mod.Progress;

// ---------------------------------------------------------------------------
// Type index (cross-module type linking)
// ---------------------------------------------------------------------------

/// Points to where a named type is defined.
pub const TypeRef = struct {
    module_name: []const u8, // e.g. "math" → api/math.html
    anchor_name: []const u8, // the `sym-<name>` id on that page
};

/// Maps a bare type name (e.g. "Vec2") to its definition location.
pub const TypeIndex = std.StringHashMap(TypeRef);

/// Build a TypeIndex from all extracted modules.
/// Keys and values borrow slices from `mods`; no allocation of strings needed.
pub fn buildTypeIndex(allocator: std.mem.Allocator, mods: []const symbols.Module) !TypeIndex {
    var idx = TypeIndex.init(allocator);
    for (mods) |mod| {
        for (mod.symbols.items) |sym| {
            switch (sym) {
                .container => |c| {
                    if (c.is_pub) try idx.put(c.name, .{
                        .module_name = mod.name,
                        .anchor_name = c.name,
                    });
                },
                .function => |f| {
                    if (f.is_pub and f.generic_return != null) try idx.put(f.name, .{
                        .module_name = mod.name,
                        .anchor_name = f.name,
                    });
                },
                .error_set => |e| {
                    if (e.is_pub) try idx.put(e.name, .{
                        .module_name = mod.name,
                        .anchor_name = e.name,
                    });
                },
                .variable, .comptime_block, .@"test", .other => {},
            }
        }
    }
    return idx;
}

// ---------------------------------------------------------------------------
// Site-wide render context
// ---------------------------------------------------------------------------

pub const SiteContext = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    project_name: []const u8,
    mods: []const symbols.Module,
    pages: []const pages.PageNavItem,
    emoji_provider: emoji.Provider,
    theme: Theme,
    /// Directory of the conf file; used to resolve relative image paths in pages.
    /// Null when running without a conf file.
    conf_dir: ?[]const u8,
    /// Slug of the page rendered as `index.html`, if any.
    home_slug: ?[]const u8,
    /// When false (default), pub consts whose value is an @import are hidden.
    show_imports: bool,
    /// Repository URL from the `"repo"` config key, or null if absent.
    repo_url: ?[]const u8,
    cache: *cache_mod.Cache,
    type_index: TypeIndex,
    progress: *Progress,
};

// ---------------------------------------------------------------------------
// Internal write buffer
// ---------------------------------------------------------------------------

/// A page's output buffer. Deliberately just bytes plus an allocator — page
/// content and site-wide settings live on `SiteContext`, not here.
pub const Buf = struct {
    list: std.ArrayList(u8),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Buf {
        return .{ .list = .empty, .alloc = alloc };
    }
    pub fn deinit(self: *Buf) void {
        self.list.deinit(self.alloc);
    }
    pub fn writeAll(self: *Buf, s: []const u8) !void {
        try self.list.appendSlice(self.alloc, s);
    }
    pub fn print(self: *Buf, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.alloc, fmt, args);
        defer self.alloc.free(s);
        try self.list.appendSlice(self.alloc, s);
    }
    pub fn flush(self: *const Buf, io: std.Io, file: std.Io.File) !void {
        try file.writeStreamingAll(io, self.list.items);
    }
};

// ---------------------------------------------------------------------------
// HTML helpers
// ---------------------------------------------------------------------------

pub fn htmlEscape(buf: *Buf, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '<' => try buf.writeAll("&lt;"),
            '>' => try buf.writeAll("&gt;"),
            '&' => try buf.writeAll("&amp;"),
            '"' => try buf.writeAll("&quot;"),
            else => try buf.list.append(buf.alloc, c),
        }
    }
}
