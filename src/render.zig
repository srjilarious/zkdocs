const std = @import("std");
const symbols = @import("symbols");
const markdown = @import("markdown");

const CSS = @embedFile("assets/style.css");

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const GuideEntry = struct {
    stem: []const u8,     // filename without .md, used in URL
    title: []const u8,    // extracted from first H1 or falls back to stem
    content: []const u8,  // raw markdown source
};

pub fn freeGuides(allocator: std.mem.Allocator, guides: []const GuideEntry) void {
    for (guides) |g| {
        allocator.free(g.stem);
        allocator.free(g.title);
        allocator.free(g.content);
    }
    allocator.free(guides);
}

// ---------------------------------------------------------------------------
// Internal write buffer
// ---------------------------------------------------------------------------

const Buf = struct {
    list: std.ArrayList(u8),
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) Buf {
        return .{ .list = .{}, .alloc = alloc };
    }
    fn deinit(self: *Buf) void {
        self.list.deinit(self.alloc);
    }
    fn writeAll(self: *Buf, s: []const u8) !void {
        try self.list.appendSlice(self.alloc, s);
    }
    fn print(self: *Buf, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.alloc, fmt, args);
        defer self.alloc.free(s);
        try self.list.appendSlice(self.alloc, s);
    }
    fn flush(self: *const Buf, file: std.fs.File) !void {
        try file.writeAll(self.list.items);
    }
};

// ---------------------------------------------------------------------------
// HTML helpers
// ---------------------------------------------------------------------------

fn htmlEscape(buf: *Buf, text: []const u8) !void {
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

fn firstSentence(text: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, text, '.')) |pos| return text[0 .. pos + 1];
    return text;
}

fn writeDoc(buf: *Buf, doc: []const u8) !void {
    const html = try markdown.toHtml(buf.alloc, doc);
    defer buf.alloc.free(html);
    try buf.writeAll("<div class=\"symbol-doc\">");
    try buf.writeAll(html);
    try buf.writeAll("</div>\n");
}

// ---------------------------------------------------------------------------
// Page header / footer
// ---------------------------------------------------------------------------

fn writeHeader(
    buf: *Buf,
    title: []const u8,
    project_name: []const u8,
    mods: []const symbols.Module,
    guides: []const GuideEntry,
    active_module: ?[]const u8,
    active_guide: ?[]const u8,
    prefix: []const u8,
) !void {
    try buf.print(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="UTF-8">
        \\<meta name="viewport" content="width=device-width,initial-scale=1">
        \\<title>
    , .{});
    try htmlEscape(buf, title);
    try buf.print(
        \\</title>
        \\<style>
        \\{s}
        \\</style>
        \\</head>
        \\<body>
        \\<nav class="sidebar">
        \\<a class="logo" href="{s}/index.html">
    , .{ CSS, prefix });
    try htmlEscape(buf, project_name);
    try buf.writeAll("</a>\n");

    if (mods.len > 0) {
        try buf.writeAll("<h4>Modules</h4>\n<ul>\n");
        for (mods) |mod| {
            const active = if (active_module) |am| std.mem.eql(u8, am, mod.name) else false;
            const cls: []const u8 = if (active) " class=\"active\"" else "";
            try buf.print("<li><a href=\"{s}/api/{s}.html\"{s}>", .{ prefix, mod.name, cls });
            try htmlEscape(buf, mod.name);
            try buf.writeAll("</a></li>\n");
        }
        try buf.writeAll("</ul>\n");
    }

    if (guides.len > 0) {
        try buf.writeAll("<h4>Guides</h4>\n<ul>\n");
        for (guides) |guide| {
            const active = if (active_guide) |ag| std.mem.eql(u8, ag, guide.stem) else false;
            const cls: []const u8 = if (active) " class=\"active\"" else "";
            try buf.print("<li><a href=\"{s}/guide/{s}.html\"{s}>", .{ prefix, guide.stem, cls });
            try htmlEscape(buf, guide.title);
            try buf.writeAll("</a></li>\n");
        }
        try buf.writeAll("</ul>\n");
    }

    try buf.writeAll("</nav>\n<main>\n");
}

fn writeFooter(buf: *Buf) !void {
    try buf.writeAll("\n</main>\n</body>\n</html>\n");
}

// ---------------------------------------------------------------------------
// Symbol renderers
// ---------------------------------------------------------------------------

fn renderFn(buf: *Buf, f: symbols.Function) !void {
    try buf.writeAll("<div class=\"symbol\">\n<div class=\"symbol-sig\"><code>");
    if (f.is_pub) try buf.writeAll("<span class=\"kw\">pub </span>");
    try buf.writeAll("<span class=\"kw\">fn </span>");
    try buf.print("<span class=\"fn-name\">{s}</span>(", .{f.name});
    for (f.params, 0..) |p, i| {
        if (i > 0) try buf.writeAll(", ");
        if (p.name) |n| try buf.print("<span class=\"param-name\">{s}</span>: ", .{n});
        try buf.writeAll("<span class=\"type-name\">");
        try htmlEscape(buf, p.type_src);
        try buf.writeAll("</span>");
    }
    try buf.writeAll(")");
    if (f.return_type_src) |r| {
        try buf.writeAll(" <span class=\"type-name\">");
        try htmlEscape(buf, r);
        try buf.writeAll("</span>");
    }
    try buf.writeAll("</code></div>\n");
    if (f.doc) |doc| try writeDoc(buf, doc);
    try buf.writeAll("</div>\n");
}

fn renderContainer(buf: *Buf, c: symbols.Container) !void {
    try buf.writeAll("<div class=\"symbol\">\n<div class=\"symbol-sig\"><code>");
    if (c.is_pub) try buf.writeAll("<span class=\"kw\">pub </span>");
    try buf.print(
        "<span class=\"kw\">{s}</span> <span class=\"fn-name\">{s}</span>",
        .{ @tagName(c.kind), c.name },
    );
    try buf.writeAll("</code></div>\n");
    if (c.doc) |doc| try writeDoc(buf, doc);

    if (c.fields.len > 0) {
        try buf.writeAll(
            \\<table class="fields-table">
            \\<tr><th>Field</th><th>Type</th><th>Description</th></tr>
            \\
        );
        for (c.fields) |f| {
            try buf.writeAll("<tr><td>");
            try htmlEscape(buf, f.name);
            try buf.writeAll("</td><td>");
            if (f.type_src) |t| try htmlEscape(buf, t);
            try buf.writeAll("</td><td class=\"field-doc\">");
            if (f.doc) |d| try htmlEscape(buf, d);
            try buf.writeAll("</td></tr>\n");
        }
        try buf.writeAll("</table>\n");
    }

    var has_pub_decls = false;
    for (c.decls.items) |d| {
        if (d.kind == .function) if (d.function) |f| { if (f.is_pub) { has_pub_decls = true; break; } };
    }
    if (has_pub_decls) {
        try buf.writeAll("<div class=\"symbol-decls\">\n<h4>Methods</h4>\n");
        for (c.decls.items) |d| {
            if (d.kind == .function) if (d.function) |f| {
                if (f.is_pub) try renderFn(buf, f);
            };
        }
        try buf.writeAll("</div>\n");
    }

    try buf.writeAll("</div>\n");
}

fn renderVar(buf: *Buf, v: symbols.Variable) !void {
    try buf.writeAll("<div class=\"symbol\">\n<div class=\"symbol-sig\"><code>");
    if (v.is_pub) try buf.writeAll("<span class=\"kw\">pub </span>");
    try buf.writeAll("<span class=\"kw\">const </span>");
    try buf.print("<span class=\"fn-name\">{s}</span>", .{v.name});
    if (v.type_src) |t| {
        try buf.writeAll(": <span class=\"type-name\">");
        try htmlEscape(buf, t);
        try buf.writeAll("</span>");
    }
    try buf.writeAll("</code></div>\n");
    if (v.doc) |doc| try writeDoc(buf, doc);
    try buf.writeAll("</div>\n");
}

// ---------------------------------------------------------------------------
// Guide page loading
// ---------------------------------------------------------------------------

fn extractTitle(content: []const u8, fallback: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.startsWith(u8, trimmed, "# ")) {
            return std.mem.trim(u8, trimmed[2..], " \t");
        }
    }
    return fallback;
}

fn loadGuides(allocator: std.mem.Allocator, docs_dir_path: []const u8) ![]GuideEntry {
    var dir = std.fs.cwd().openDir(docs_dir_path, .{ .iterate = true }) catch |err| {
        std.log.warn("Cannot open docs dir '{s}': {}", .{ docs_dir_path, err });
        return &.{};
    };
    defer dir.close();

    var list = std.ArrayList(GuideEntry){};
    errdefer {
        for (list.items) |g| {
            allocator.free(g.stem);
            allocator.free(g.title);
            allocator.free(g.content);
        }
        list.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".md")) continue;

        const raw_content = dir.readFileAlloc(allocator, entry.name, 4 * 1024 * 1024) catch |err| {
            std.log.warn("Cannot read '{s}': {}", .{ entry.name, err });
            continue;
        };
        errdefer allocator.free(raw_content);

        const stem_slice = entry.name[0 .. entry.name.len - 3];
        const stem = try allocator.dupe(u8, stem_slice);
        errdefer allocator.free(stem);

        const title_slice = extractTitle(raw_content, stem_slice);
        const title = try allocator.dupe(u8, title_slice);
        errdefer allocator.free(title);

        try list.append(allocator, .{
            .stem = stem,
            .title = title,
            .content = raw_content,
        });
    }

    // Sort guides by stem name for a stable nav order.
    const items = list.items;
    std.mem.sort(GuideEntry, items, {}, struct {
        fn lt(_: void, a: GuideEntry, b: GuideEntry) bool {
            return std.mem.lessThan(u8, a.stem, b.stem);
        }
    }.lt);

    return list.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/// Generate the full HTML site under `out_path`.
///
/// Output layout:
///   out_path/
///     index.html
///     api/<module>.html     (one per module, pub symbols only)
///     guide/<stem>.html     (one per .md file in docs_dir, if provided)
pub fn renderSite(
    allocator: std.mem.Allocator,
    out_path: []const u8,
    project_name: []const u8,
    mods: []const symbols.Module,
    docs_dir: ?[]const u8,
) !void {
    var out_dir = try std.fs.cwd().makeOpenPath(out_path, .{});
    defer out_dir.close();

    try out_dir.makePath("api");

    // Load guide pages if a docs directory was specified.
    const guides: []GuideEntry = if (docs_dir) |dd| try loadGuides(allocator, dd) else &.{};
    defer if (docs_dir != null) freeGuides(allocator, guides);

    if (guides.len > 0) try out_dir.makePath("guide");

    // ── index.html ──────────────────────────────────────────────────────────
    {
        var buf = Buf.init(allocator);
        defer buf.deinit();

        try writeHeader(&buf, project_name, project_name, mods, guides, null, null, ".");
        try buf.writeAll("<h1>");
        try htmlEscape(&buf, project_name);
        try buf.writeAll("</h1>\n");

        if (mods.len > 0) {
            try buf.writeAll("<h2>Modules</h2>\n<ul class=\"module-list\">\n");
            for (mods) |mod| {
                try buf.print("<li><a href=\"./api/{s}.html\">", .{mod.name});
                try htmlEscape(&buf, mod.name);
                try buf.writeAll("</a>");

                var found_doc = false;
                for (mod.symbols.items) |sym| {
                    const doc: ?[]const u8 = switch (sym.kind) {
                        .function  => if (sym.function)  |f| f.doc else null,
                        .variable  => if (sym.variable)  |v| v.doc else null,
                        .container => if (sym.container) |c| c.doc else null,
                        else => null,
                    };
                    if (doc) |d| {
                        try buf.writeAll("<div class=\"mod-doc\">");
                        try htmlEscape(&buf, firstSentence(d));
                        try buf.writeAll("</div>");
                        found_doc = true;
                        break;
                    }
                }
                if (!found_doc) {
                    try buf.writeAll("<div class=\"mod-doc\">");
                    try htmlEscape(&buf, mod.path);
                    try buf.writeAll("</div>");
                }
                try buf.writeAll("</li>\n");
            }
            try buf.writeAll("</ul>\n");
        }

        if (guides.len > 0) {
            try buf.writeAll("<h2>Guides</h2>\n<ul class=\"module-list\">\n");
            for (guides) |guide| {
                try buf.print("<li><a href=\"./guide/{s}.html\">", .{guide.stem});
                try htmlEscape(&buf, guide.title);
                try buf.writeAll("</a></li>\n");
            }
            try buf.writeAll("</ul>\n");
        }

        try writeFooter(&buf);

        const file = try out_dir.createFile("index.html", .{});
        defer file.close();
        try buf.flush(file);
    }

    // ── api/<module>.html ────────────────────────────────────────────────────
    for (mods) |mod| {
        var buf = Buf.init(allocator);
        defer buf.deinit();

        const title = try std.fmt.allocPrint(allocator, "{s} — {s}", .{ mod.name, project_name });
        defer allocator.free(title);

        try writeHeader(&buf, title, project_name, mods, guides, mod.name, null, "..");

        try buf.writeAll("<h1>");
        try htmlEscape(&buf, mod.name);
        try buf.writeAll("</h1>\n<div class=\"mod-path\">");
        try htmlEscape(&buf, mod.path);
        try buf.writeAll("</div>\n");

        var has_types  = false;
        var has_fns    = false;
        var has_consts = false;
        for (mod.symbols.items) |sym| {
            switch (sym.kind) {
                .container => if (sym.container) |c| { if (c.is_pub) has_types  = true; },
                .function  => if (sym.function)  |f| { if (f.is_pub) has_fns    = true; },
                .variable  => if (sym.variable)  |v| { if (v.is_pub) has_consts = true; },
                else => {},
            }
        }

        if (has_types) {
            try buf.writeAll("<h2>Types</h2>\n");
            for (mod.symbols.items) |sym| {
                if (sym.kind == .container) if (sym.container) |c| {
                    if (c.is_pub) try renderContainer(&buf, c);
                };
            }
        }
        if (has_fns) {
            try buf.writeAll("<h2>Functions</h2>\n");
            for (mod.symbols.items) |sym| {
                if (sym.kind == .function) if (sym.function) |f| {
                    if (f.is_pub) try renderFn(&buf, f);
                };
            }
        }
        if (has_consts) {
            try buf.writeAll("<h2>Constants</h2>\n");
            for (mod.symbols.items) |sym| {
                if (sym.kind == .variable) if (sym.variable) |v| {
                    if (v.is_pub) try renderVar(&buf, v);
                };
            }
        }

        try writeFooter(&buf);

        const filename = try std.fmt.allocPrint(allocator, "api/{s}.html", .{mod.name});
        defer allocator.free(filename);
        const file = try out_dir.createFile(filename, .{});
        defer file.close();
        try buf.flush(file);
    }

    // ── guide/<stem>.html ────────────────────────────────────────────────────
    for (guides) |guide| {
        var buf = Buf.init(allocator);
        defer buf.deinit();

        const title = try std.fmt.allocPrint(allocator, "{s} — {s}", .{ guide.title, project_name });
        defer allocator.free(title);

        try writeHeader(&buf, title, project_name, mods, guides, null, guide.stem, "..");

        const html = try markdown.toHtml(allocator, guide.content);
        defer allocator.free(html);

        try buf.writeAll("<div class=\"guide-content\">\n");
        try buf.writeAll(html);
        try buf.writeAll("</div>\n");

        try writeFooter(&buf);

        const filename = try std.fmt.allocPrint(allocator, "guide/{s}.html", .{guide.stem});
        defer allocator.free(filename);
        const file = try out_dir.createFile(filename, .{});
        defer file.close();
        try buf.flush(file);
    }
}
