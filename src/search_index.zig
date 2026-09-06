//! Client-side search index generation (`assets/search-data.js`).

const std = @import("std");
const pages = @import("./pages.zig");
const site_context = @import("./site_context.zig");

const SiteContext = site_context.SiteContext;
const PageEntry = pages.PageEntry;

fn jsonEscapeStr(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            // remaining control chars (excludes \t=0x09, \n=0x0a, \r=0x0d)
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => {
                const hex = "0123456789abcdef";
                try buf.appendSlice(allocator, "\\u00");
                try buf.append(allocator, hex[c >> 4]);
                try buf.append(allocator, hex[c & 0xf]);
            },
            else => try buf.append(allocator, c),
        }
    }
    try buf.append(allocator, '"');
}

fn appendSearchDoc(
    buf: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    id: usize,
    title: []const u8,
    content: []const u8,
    url: []const u8,
    doc_type: []const u8,
) !void {
    const max_content = 3000;
    const trunc = if (content.len > max_content) content[0..max_content] else content;
    const prefix = try std.fmt.allocPrint(allocator, "{{\"id\":{d},\"title\":", .{id});
    defer allocator.free(prefix);
    try buf.appendSlice(allocator, prefix);
    try jsonEscapeStr(buf, allocator, title);
    try buf.appendSlice(allocator, ",\"content\":");
    try jsonEscapeStr(buf, allocator, trunc);
    try buf.appendSlice(allocator, ",\"url\":");
    try jsonEscapeStr(buf, allocator, url);
    try buf.appendSlice(allocator, ",\"type\":");
    try jsonEscapeStr(buf, allocator, doc_type);
    try buf.append(allocator, '}');
}

pub fn writeSearchIndex(ctx: *const SiteContext, out_dir: *std.Io.Dir) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ctx.allocator);

    // Assign to a global so the index works on file:// URLs (fetch() is blocked there).
    try buf.appendSlice(ctx.allocator, "window.ZKDOCS_SEARCH_INDEX=[");
    var id: usize = 0;

    // Page entries (guides and examples unified)
    const SearchVisitCtx = struct {
        buf: *std.ArrayList(u8),
        allocator: std.mem.Allocator,
        home_slug: ?[]const u8,
        id: *usize,
    };
    try pages.visitPageEntries(ctx.pages, SearchVisitCtx{
        .buf = &buf,
        .allocator = ctx.allocator,
        .home_slug = ctx.home_slug,
        .id = &id,
    }, struct {
        fn visit(sctx: SearchVisitCtx, e: PageEntry) !void {
            const is_home = if (sctx.home_slug) |hs| std.mem.eql(u8, hs, e.slug) else false;
            const url = if (is_home)
                try sctx.allocator.dupe(u8, "index.html")
            else
                try std.fmt.allocPrint(sctx.allocator, "page/{s}.html", .{e.slug});
            defer sctx.allocator.free(url);
            const doc_type: []const u8 = switch (e.mode) {
                .markdown => "guide",
                .zig_prose, .zig_raw => "example",
            };
            if (sctx.id.* > 0) try sctx.buf.append(sctx.allocator, ',');
            try appendSearchDoc(sctx.buf, sctx.allocator, sctx.id.*, e.title, e.content, url, doc_type);
            sctx.id.* += 1;
        }
    }.visit);

    // API symbols
    for (ctx.mods) |mod| {
        for (mod.symbols.items) |sym| {
            switch (sym) {
                .function => |f| {
                    if (f.is_pub) {
                        const url = try std.fmt.allocPrint(ctx.allocator, "api/{s}.html#sym-{s}", .{ mod.slug, f.name });
                        defer ctx.allocator.free(url);
                        if (id > 0) try buf.append(ctx.allocator, ',');
                        try appendSearchDoc(&buf, ctx.allocator, id, f.name, f.doc orelse "", url, "api");
                        id += 1;
                    }
                },
                .container => |c| {
                    if (c.is_pub) {
                        const url = try std.fmt.allocPrint(ctx.allocator, "api/{s}.html#sym-{s}", .{ mod.slug, c.name });
                        defer ctx.allocator.free(url);
                        if (id > 0) try buf.append(ctx.allocator, ',');
                        try appendSearchDoc(&buf, ctx.allocator, id, c.name, c.doc orelse "", url, "api");
                        id += 1;
                    }
                },
                .variable => |v| {
                    if (v.is_pub) {
                        const url = try std.fmt.allocPrint(ctx.allocator, "api/{s}.html#sym-{s}", .{ mod.slug, v.name });
                        defer ctx.allocator.free(url);
                        if (id > 0) try buf.append(ctx.allocator, ',');
                        try appendSearchDoc(&buf, ctx.allocator, id, v.name, v.doc orelse "", url, "api");
                        id += 1;
                    }
                },
                .error_set => |e| {
                    if (e.is_pub) {
                        const url = try std.fmt.allocPrint(ctx.allocator, "api/{s}.html#sym-{s}", .{ mod.slug, e.name });
                        defer ctx.allocator.free(url);
                        if (id > 0) try buf.append(ctx.allocator, ',');
                        try appendSearchDoc(&buf, ctx.allocator, id, e.name, e.doc orelse "", url, "api");
                        id += 1;
                    }
                },
                .comptime_block, .@"test", .other => {},
            }
        }
    }

    try buf.appendSlice(ctx.allocator, "];");

    const file = try out_dir.createFile(ctx.io, "assets/search-data.js", .{});
    defer file.close(ctx.io);
    try file.writeStreamingAll(ctx.io, buf.items);
}
