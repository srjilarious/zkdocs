//! Page navigation tree: the unified guide/example page list parsed from
//! `zkdocs.conf` and rendered into the sidebar nav, index page, and search index.

const std = @import("std");

pub const PageMode = enum {
    markdown, // .md file — always rendered as markdown HTML
    zig_prose, // .zig file — prose+code segments view (default), with Raw view toggle
    zig_raw, // .zig file — raw syntax-highlighted source only, no prose toggle
};

pub const PageEntry = struct {
    slug: []const u8,
    title: []const u8,
    content: []const u8, // markdown text or zig source
    src_path: []const u8,
    mode: PageMode,
};

pub const PageSection = struct {
    title: []const u8,
    items: []PageNavItem, // recursive — sections can contain sub-sections
};

pub const PageNavItem = union(enum) {
    entry: PageEntry,
    section: PageSection,
};

pub fn freePageEntry(allocator: std.mem.Allocator, e: *PageEntry) void {
    allocator.free(e.slug);
    allocator.free(e.title);
    allocator.free(e.content);
    if (e.src_path.len > 0) allocator.free(e.src_path);
}

pub fn freePageNavItem(allocator: std.mem.Allocator, item: *PageNavItem) void {
    switch (item.*) {
        .entry => |*e| freePageEntry(allocator, e),
        .section => |*s| {
            allocator.free(s.title);
            for (s.items) |*it| freePageNavItem(allocator, it);
            allocator.free(s.items);
        },
    }
}

pub fn freePages(allocator: std.mem.Allocator, pages: []PageNavItem) void {
    for (pages) |*item| freePageNavItem(allocator, item);
    allocator.free(pages);
}

pub fn pagesHaveEntries(pages: []const PageNavItem) bool {
    for (pages) |item| switch (item) {
        .entry => return true,
        .section => |s| if (pagesHaveEntries(s.items)) return true,
    };
    return false;
}

/// Recurse through `items`, invoking `visit` for every leaf `.entry`
/// regardless of how many `.section` levels it is nested under.
/// Use this instead of hand-rolling a walk over `[]PageNavItem` — a
/// one-level-only walk silently drops entries nested two or more
/// sections deep.
pub fn visitPageEntries(
    items: []const PageNavItem,
    ctx: anytype,
    comptime visit: fn (@TypeOf(ctx), PageEntry) anyerror!void,
) anyerror!void {
    for (items) |item| {
        switch (item) {
            .entry => |e| try visit(ctx, e),
            .section => |s| try visitPageEntries(s.items, ctx, visit),
        }
    }
}
