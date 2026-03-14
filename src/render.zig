const std = @import("std");
const symbols = @import("symbols");
const markdown = @import("markdown");
const emoji = @import("emoji");

const CSS = @embedFile("assets/style.css");

// ---------------------------------------------------------------------------
// Progress reporting
// ---------------------------------------------------------------------------

pub const Progress = struct {
    step:  usize = 0,
    total: usize,

    pub fn init(total: usize) Progress { return .{ .total = total }; }

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

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const GuideEntry = struct {
    slug: []const u8,     // URL path, e.g. "getting-started" or "reference/cli"
    title: []const u8,
    content: []const u8,
};

pub const GuideSection = struct {
    title: []const u8,
    entries: []GuideEntry,
};

/// A top-level navigation item: either a standalone guide or a titled section.
pub const GuideNavItem = union(enum) {
    entry: GuideEntry,
    section: GuideSection,
};

fn freeGuideEntry(allocator: std.mem.Allocator, e: *GuideEntry) void {
    allocator.free(e.slug);
    allocator.free(e.title);
    allocator.free(e.content);
}

fn freeNavItem(allocator: std.mem.Allocator, item: *GuideNavItem) void {
    switch (item.*) {
        .entry => |*e| freeGuideEntry(allocator, e),
        .section => |*s| {
            allocator.free(s.title);
            for (s.entries) |*e| freeGuideEntry(allocator, e);
            allocator.free(s.entries);
        },
    }
}

pub fn freeGuides(allocator: std.mem.Allocator, guides: []GuideNavItem) void {
    for (guides) |*item| freeNavItem(allocator, item);
    allocator.free(guides);
}

fn guidesHaveEntries(guides: []const GuideNavItem) bool {
    for (guides) |item| switch (item) {
        .entry => return true,
        .section => |s| if (s.entries.len > 0) return true,
    };
    return false;
}

// ---------------------------------------------------------------------------
// Internal write buffer
// ---------------------------------------------------------------------------

const Buf = struct {
    list: std.ArrayList(u8),
    alloc: std.mem.Allocator,
    emoji_provider: emoji.Provider,

    fn init(alloc: std.mem.Allocator, provider: emoji.Provider) Buf {
        return .{ .list = .{}, .alloc = alloc, .emoji_provider = provider };
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
    const raw = try markdown.toHtml(buf.alloc, doc);
    defer buf.alloc.free(raw);
    const html = try emoji.replaceInHtml(buf.alloc, raw, buf.emoji_provider);
    defer buf.alloc.free(html);
    try buf.writeAll("<div class=\"symbol-doc\">");
    try buf.writeAll(html);
    try buf.writeAll("</div>\n");
}

// ---------------------------------------------------------------------------
// Page header / nav / footer
// ---------------------------------------------------------------------------

/// Write the page <head>, <body>, and the left nav sidebar.
/// NOTE: does NOT close </nav> or open <main> — call writeNavClose after
/// appending any per-page TOC content into the nav.
fn writeHeader(
    buf: *Buf,
    title: []const u8,
    project_name: []const u8,
    mods: []const symbols.Module,
    guides: []const GuideNavItem,
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
        try buf.writeAll("<details class=\"nav-section\" open>\n<summary>Modules</summary>\n<ul>\n");
        for (mods) |mod| {
            const active = if (active_module) |am| std.mem.eql(u8, am, mod.name) else false;
            const cls: []const u8 = if (active) " class=\"active\"" else "";
            try buf.print("<li><a href=\"{s}/api/{s}.html\"{s}>", .{ prefix, mod.name, cls });
            try htmlEscape(buf, mod.name);
            try buf.writeAll("</a></li>\n");
        }
        try buf.writeAll("</ul>\n</details>\n");
    }

    if (guidesHaveEntries(guides)) {
        try buf.writeAll("<details class=\"nav-section\" open>\n<summary>Guides</summary>\n<ul>\n");
        for (guides) |item| {
            switch (item) {
                .entry => |e| {
                    const active = if (active_guide) |ag| std.mem.eql(u8, ag, e.slug) else false;
                    const cls: []const u8 = if (active) " class=\"active\"" else "";
                    try buf.print("<li><a href=\"{s}/guide/{s}.html\"{s}>", .{ prefix, e.slug, cls });
                    try htmlEscape(buf, e.title);
                    try buf.writeAll("</a></li>\n");
                },
                .section => |s| {
                    var section_open = false;
                    if (active_guide) |ag| {
                        for (s.entries) |e| {
                            if (std.mem.eql(u8, ag, e.slug)) { section_open = true; break; }
                        }
                    }
                    if (section_open) {
                        try buf.writeAll("<details class=\"nav-subsection\" open>\n<summary>");
                    } else {
                        try buf.writeAll("<details class=\"nav-subsection\">\n<summary>");
                    }
                    try htmlEscape(buf, s.title);
                    try buf.writeAll("</summary>\n<ul>\n");
                    for (s.entries) |e| {
                        const active = if (active_guide) |ag| std.mem.eql(u8, ag, e.slug) else false;
                        const cls: []const u8 = if (active) " class=\"active\"" else "";
                        try buf.print("<li><a href=\"{s}/guide/{s}.html\"{s}>", .{ prefix, e.slug, cls });
                        try htmlEscape(buf, e.title);
                        try buf.writeAll("</a></li>\n");
                    }
                    try buf.writeAll("</ul>\n</details>\n");
                },
            }
        }
        try buf.writeAll("</ul>\n</details>\n");
    }
    // Caller writes per-page TOC here, then calls writeNavClose.
}

/// Close the nav sidebar and open <main>.
fn writeNavClose(buf: *Buf) !void {
    try buf.writeAll("</nav>\n<main>\n");
}

fn writeFooter(buf: *Buf) !void {
    try buf.writeAll("\n</main>\n</body>\n</html>\n");
}

// ---------------------------------------------------------------------------
// Per-page TOC writers
// ---------------------------------------------------------------------------

/// Emit a collapsible "On this page" TOC for an API module page.
/// Shows Types → container names (with indented methods), Functions, Constants.
fn writeApiToc(buf: *Buf, mod: symbols.Module) !void {
    var has_types  = false;
    var has_fns    = false;
    var has_consts = false;
    for (mod.symbols.items) |sym| {
        switch (sym.kind) {
            .container => if (sym.container) |c| { if (c.is_pub) has_types = true; },
            .function  => if (sym.function)  |f| {
                if (f.is_pub and f.generic_return != null) has_types = true;
                if (f.is_pub and f.generic_return == null) has_fns   = true;
            },
            .variable  => if (sym.variable)  |v| { if (v.is_pub) has_consts = true; },
            else => {},
        }
    }
    if (!has_types and !has_fns and !has_consts) return;

    try buf.writeAll("<details class=\"nav-section page-toc\" open>\n<summary>On this page</summary>\n<ul>\n");

    if (has_types) {
        try buf.writeAll("<li><a href=\"#section-types\">Types</a>\n<ul class=\"toc-children\">\n");
        for (mod.symbols.items) |sym| {
            if (sym.kind != .container) continue;
            const c = sym.container orelse continue;
            if (!c.is_pub) continue;

            try buf.print("<li><a href=\"#sym-{s}\">", .{c.name});
            try htmlEscape(buf, c.name);
            try buf.writeAll("</a>");

            // Indented public methods
            var has_methods = false;
            for (c.decls.items) |d| {
                if (d.kind == .function) if (d.function) |mf| { if (mf.is_pub) { has_methods = true; break; } };
            }
            if (has_methods) {
                try buf.writeAll("\n<ul class=\"toc-methods\">\n");
                for (c.decls.items) |d| {
                    if (d.kind != .function) continue;
                    const mf = d.function orelse continue;
                    if (!mf.is_pub) continue;
                    try buf.print("<li><a href=\"#sym-{s}-{s}\">.{s}</a></li>\n", .{ c.name, mf.name, mf.name });
                }
                try buf.writeAll("</ul>\n");
            }
            try buf.writeAll("</li>\n");
        }
        // Generic type constructors
        for (mod.symbols.items) |sym| {
            if (sym.kind != .function) continue;
            const f = sym.function orelse continue;
            if (!f.is_pub or f.generic_return == null) continue;
            const gr = f.generic_return.?;

            try buf.print("<li><a href=\"#sym-{s}\">", .{f.name});
            try htmlEscape(buf, f.name);
            try buf.writeAll("</a>");

            var has_methods = false;
            for (gr.decls.items) |d| {
                if (d.kind == .function) if (d.function) |mf| { if (mf.is_pub) { has_methods = true; break; } };
            }
            if (has_methods) {
                try buf.writeAll("\n<ul class=\"toc-methods\">\n");
                for (gr.decls.items) |d| {
                    if (d.kind != .function) continue;
                    const mf = d.function orelse continue;
                    if (!mf.is_pub) continue;
                    try buf.print("<li><a href=\"#sym-{s}-{s}\">.{s}</a></li>\n", .{ f.name, mf.name, mf.name });
                }
                try buf.writeAll("</ul>\n");
            }
            try buf.writeAll("</li>\n");
        }
        try buf.writeAll("</ul>\n</li>\n");
    }

    if (has_fns) {
        try buf.writeAll("<li><a href=\"#section-functions\">Functions</a>\n<ul class=\"toc-children\">\n");
        for (mod.symbols.items) |sym| {
            if (sym.kind != .function) continue;
            const f = sym.function orelse continue;
            if (!f.is_pub) continue;
            if (f.generic_return != null) continue;
            try buf.print("<li><a href=\"#sym-{s}\">", .{f.name});
            try htmlEscape(buf, f.name);
            try buf.writeAll("</a></li>\n");
        }
        try buf.writeAll("</ul>\n</li>\n");
    }

    if (has_consts) {
        try buf.writeAll("<li><a href=\"#section-constants\">Constants</a>\n<ul class=\"toc-children\">\n");
        for (mod.symbols.items) |sym| {
            if (sym.kind != .variable) continue;
            const v = sym.variable orelse continue;
            if (!v.is_pub) continue;
            try buf.print("<li><a href=\"#sym-{s}\">", .{v.name});
            try htmlEscape(buf, v.name);
            try buf.writeAll("</a></li>\n");
        }
        try buf.writeAll("</ul>\n</li>\n");
    }

    try buf.writeAll("</ul>\n</details>\n");
}

/// Emit a collapsible "On this page" TOC for a guide (markdown) page.
/// Scans raw markdown source for `## ` headings (level 2 only).
fn writeGuideToc(buf: *Buf, raw_content: []const u8) !void {
    // First pass: count H2 headings.
    var has_h2 = false;
    {
        var lines = std.mem.splitScalar(u8, raw_content, '\n');
        while (lines.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, t, "## ")) { has_h2 = true; break; }
        }
    }
    if (!has_h2) return;

    try buf.writeAll("<details class=\"nav-section page-toc\" open>\n<summary>On this page</summary>\n<ul class=\"toc-children\">\n");

    var lines = std.mem.splitScalar(u8, raw_content, '\n');
    while (lines.next()) |line| {
        const t = std.mem.trim(u8, line, " \t\r");
        if (!std.mem.startsWith(u8, t, "## ")) continue;
        const heading = std.mem.trim(u8, t[3..], " \t");
        const slug = try markdown.slugify(buf.alloc, heading);
        defer buf.alloc.free(slug);
        try buf.print("<li><a href=\"#h2-{s}\">", .{slug});
        try htmlEscape(buf, heading);
        try buf.writeAll("</a></li>\n");
    }

    try buf.writeAll("</ul>\n</details>\n");
}

// ---------------------------------------------------------------------------
// Symbol renderers
// ---------------------------------------------------------------------------

fn renderFn(buf: *Buf, f: symbols.Function, parent_container: ?[]const u8) !void {
    if (parent_container) |pc| {
        try buf.print("<div class=\"symbol\" id=\"sym-{s}-{s}\">\n", .{ pc, f.name });
    } else {
        try buf.print("<div class=\"symbol\" id=\"sym-{s}\">\n", .{f.name});
    }
    if (f.generic_return != null) {
        try buf.writeAll("<div class=\"symbol-sig-row\">");
    }
    try buf.writeAll("<div class=\"symbol-sig\"><code>");
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
    if (f.generic_return != null) {
        try buf.writeAll("<span class=\"pill-generic\">generic</span></div>\n");
    }
    if (f.doc) |doc| try writeDoc(buf, doc);

    if (f.generic_return) |gr| {
        if (gr.fields.len > 0) {
            try buf.writeAll(
                \\<table class="fields-table">
                \\<tr><th>Field</th><th>Type</th><th>Description</th></tr>
                \\
            );
            for (gr.fields) |field| {
                try buf.writeAll("<tr><td>");
                try htmlEscape(buf, field.name);
                try buf.writeAll("</td><td>");
                if (field.type_src) |t| try htmlEscape(buf, t);
                try buf.writeAll("</td><td class=\"field-doc\">");
                if (field.doc) |d| try htmlEscape(buf, d);
                try buf.writeAll("</td></tr>\n");
            }
            try buf.writeAll("</table>\n");
        }

        var has_pub_decls = false;
        for (gr.decls.items) |d| {
            if (d.kind == .function) if (d.function) |mf| { if (mf.is_pub) { has_pub_decls = true; break; } };
        }
        if (has_pub_decls) {
            try buf.writeAll("<div class=\"symbol-decls\">\n<h4>Methods</h4>\n");
            for (gr.decls.items) |d| {
                if (d.kind == .function) if (d.function) |mf| {
                    if (mf.is_pub) try renderFn(buf, mf, f.name);
                };
            }
            try buf.writeAll("</div>\n");
        }
    }

    try buf.writeAll("</div>\n");
}

fn renderContainer(buf: *Buf, c: symbols.Container) !void {
    try buf.print("<div class=\"symbol\" id=\"sym-{s}\">\n", .{c.name});
    try buf.writeAll("<div class=\"symbol-sig\"><code>");
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
                if (f.is_pub) try renderFn(buf, f, c.name);
            };
        }
        try buf.writeAll("</div>\n");
    }

    try buf.writeAll("</div>\n");
}

fn renderVar(buf: *Buf, v: symbols.Variable) !void {
    try buf.print("<div class=\"symbol\" id=\"sym-{s}\">\n", .{v.name});
    try buf.writeAll("<div class=\"symbol-sig\"><code>");
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

fn loadGuideEntry(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    config_dir: []const u8,
) !GuideEntry {
    const src_val = obj.get("src") orelse return error.MissingField;
    if (src_val != .string) return error.InvalidField;
    const src = src_val.string;

    const full_path = try std.fs.path.join(allocator, &.{ config_dir, src });
    defer allocator.free(full_path);

    const content = try std.fs.cwd().readFileAlloc(allocator, full_path, 4 * 1024 * 1024);
    errdefer allocator.free(content);

    // Slug = src with .md stripped
    const slug_src = if (std.mem.endsWith(u8, src, ".md")) src[0 .. src.len - 3] else src;
    const slug = try allocator.dupe(u8, slug_src);
    errdefer allocator.free(slug);

    // Title: explicit config value, or extracted H1, or file stem
    const stem = std.fs.path.stem(src);
    const title = if (obj.get("title")) |tv|
        try allocator.dupe(u8, if (tv == .string) tv.string else extractTitle(content, stem))
    else
        try allocator.dupe(u8, extractTitle(content, stem));
    errdefer allocator.free(title);

    return .{ .slug = slug, .title = title, .content = content };
}

fn loadGuidesFromConfig(
    allocator: std.mem.Allocator,
    config_path: []const u8,
) ![]GuideNavItem {
    const raw = std.fs.cwd().readFileAlloc(allocator, config_path, 1 * 1024 * 1024) catch |err| {
        std.log.warn("Cannot open guides config '{s}': {}", .{ config_path, err });
        return &.{};
    };
    defer allocator.free(raw);

    const config_dir = std.fs.path.dirname(config_path) orelse ".";

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    if (parsed.value != .array) {
        std.log.warn("Guides config '{s}' must be a JSON array", .{config_path});
        return &.{};
    }

    var items = std.ArrayList(GuideNavItem){};
    errdefer {
        for (items.items) |*it| freeNavItem(allocator, it);
        items.deinit(allocator);
    }

    for (parsed.value.array.items) |json_item| {
        if (json_item != .object) continue;
        const obj = json_item.object;

        if (obj.get("section")) |sec_val| {
            if (sec_val != .string) continue;
            const sec_title = try allocator.dupe(u8, sec_val.string);
            errdefer allocator.free(sec_title);

            var sec_entries = std.ArrayList(GuideEntry){};
            errdefer {
                for (sec_entries.items) |*e| freeGuideEntry(allocator, e);
                sec_entries.deinit(allocator);
            }

            if (obj.get("entries")) |ev| if (ev == .array) {
                for (ev.array.items) |ei| {
                    if (ei != .object) continue;
                    const e = try loadGuideEntry(allocator, ei.object, config_dir);
                    errdefer freeGuideEntry(allocator, @constCast(&e));
                    try sec_entries.append(allocator, e);
                }
            };

            const sec_slice = try sec_entries.toOwnedSlice(allocator);
            errdefer {
                for (sec_slice) |*e| freeGuideEntry(allocator, e);
                allocator.free(sec_slice);
            }
            try items.append(allocator, .{ .section = .{
                .title = sec_title,
                .entries = sec_slice,
            } });
        } else if (obj.get("src") != null) {
            const e = try loadGuideEntry(allocator, obj, config_dir);
            errdefer freeGuideEntry(allocator, @constCast(&e));
            try items.append(allocator, .{ .entry = e });
        }
    }

    return items.toOwnedSlice(allocator);
}

fn loadGuidesFromDir(
    allocator: std.mem.Allocator,
    docs_dir_path: []const u8,
) ![]GuideNavItem {
    var dir = std.fs.cwd().openDir(docs_dir_path, .{ .iterate = true }) catch |err| {
        std.log.warn("Cannot open docs dir '{s}': {}", .{ docs_dir_path, err });
        return &.{};
    };
    defer dir.close();

    var list = std.ArrayList(GuideNavItem){};
    errdefer {
        for (list.items) |*it| freeNavItem(allocator, it);
        list.deinit(allocator);
    }

    var iter = dir.iterate();
    while (try iter.next()) |de| {
        if (de.kind != .file) continue;
        if (!std.mem.endsWith(u8, de.name, ".md")) continue;

        const content = dir.readFileAlloc(allocator, de.name, 4 * 1024 * 1024) catch |err| {
            std.log.warn("Cannot read '{s}': {}", .{ de.name, err });
            continue;
        };
        errdefer allocator.free(content);

        const stem_slice = de.name[0 .. de.name.len - 3];
        const slug = try allocator.dupe(u8, stem_slice);
        errdefer allocator.free(slug);
        const title = try allocator.dupe(u8, extractTitle(content, stem_slice));
        errdefer allocator.free(title);

        try list.append(allocator, .{ .entry = .{
            .slug = slug, .title = title, .content = content,
        } });
    }

    std.mem.sort(GuideNavItem, list.items, {}, struct {
        fn lt(_: void, a: GuideNavItem, b: GuideNavItem) bool {
            const as = switch (a) { .entry => |e| e.slug, .section => |s| s.title };
            const bs = switch (b) { .entry => |e| e.slug, .section => |s| s.title };
            return std.mem.lessThan(u8, as, bs);
        }
    }.lt);

    return list.toOwnedSlice(allocator);
}

fn loadGuides(allocator: std.mem.Allocator, docs_path: []const u8) ![]GuideNavItem {
    return if (std.mem.endsWith(u8, docs_path, ".json"))
        loadGuidesFromConfig(allocator, docs_path)
    else
        loadGuidesFromDir(allocator, docs_path);
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
    emoji_provider: emoji.Provider,
    progress: *Progress,
) !void {
    var out_dir = try std.fs.cwd().makeOpenPath(out_path, .{});
    defer out_dir.close();

    try out_dir.makePath("api");

    const guides: []GuideNavItem = if (docs_dir) |dd| try loadGuides(allocator, dd) else &.{};
    defer if (docs_dir != null) freeGuides(allocator, guides);

    if (guidesHaveEntries(guides)) try out_dir.makePath("guide");

    // ── index.html ──────────────────────────────────────────────────────────
    progress.begin("writing index");
    {
        var buf = Buf.init(allocator, emoji_provider);
        defer buf.deinit();

        try writeHeader(&buf, project_name, project_name, mods, guides, null, null, ".");
        // No per-page TOC on the index.
        try writeNavClose(&buf);

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

        if (guidesHaveEntries(guides)) {
            try buf.writeAll("<h2>Guides</h2>\n<ul class=\"module-list\">\n");
            for (guides) |item| switch (item) {
                .entry => |e| {
                    try buf.print("<li><a href=\"./guide/{s}.html\">", .{e.slug});
                    try htmlEscape(&buf, e.title);
                    try buf.writeAll("</a></li>\n");
                },
                .section => |s| {
                    try buf.writeAll("<li><strong>");
                    try htmlEscape(&buf, s.title);
                    try buf.writeAll("</strong>\n<ul class=\"module-list\">\n");
                    for (s.entries) |e| {
                        try buf.print("<li><a href=\"./guide/{s}.html\">", .{e.slug});
                        try htmlEscape(&buf, e.title);
                        try buf.writeAll("</a></li>\n");
                    }
                    try buf.writeAll("</ul></li>\n");
                },
            };
            try buf.writeAll("</ul>\n");
        }

        try writeFooter(&buf);

        const file = try out_dir.createFile("index.html", .{});
        defer file.close();
        try buf.flush(file);
    }

    // ── api/<module>.html ────────────────────────────────────────────────────
    {
        var label_buf: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "rendering api ({d} module{s})", .{
            mods.len, if (mods.len == 1) "" else "s",
        }) catch "rendering api";
        progress.begin(label);
    }
    for (mods) |mod| {
        Progress.setCurrent(mod.name);
        var buf = Buf.init(allocator, emoji_provider);
        defer buf.deinit();

        const title = try std.fmt.allocPrint(allocator, "{s} — {s}", .{ mod.name, project_name });
        defer allocator.free(title);

        try writeHeader(&buf, title, project_name, mods, guides, mod.name, null, "..");
        try writeApiToc(&buf, mod);
        try writeNavClose(&buf);

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
                .container => if (sym.container) |c| { if (c.is_pub) has_types = true; },
                .function  => if (sym.function)  |f| {
                    if (f.is_pub and f.generic_return != null) has_types = true;
                    if (f.is_pub and f.generic_return == null) has_fns   = true;
                },
                .variable  => if (sym.variable)  |v| { if (v.is_pub) has_consts = true; },
                else => {},
            }
        }

        if (has_types) {
            try buf.writeAll("<h2 id=\"section-types\">Types</h2>\n");
            for (mod.symbols.items) |sym| {
                if (sym.kind == .container) if (sym.container) |c| {
                    if (c.is_pub) try renderContainer(&buf, c);
                };
            }
            for (mod.symbols.items) |sym| {
                if (sym.kind != .function) continue;
                const f = sym.function orelse continue;
                if (f.is_pub and f.generic_return != null) try renderFn(&buf, f, null);
            }
        }
        if (has_fns) {
            try buf.writeAll("<h2 id=\"section-functions\">Functions</h2>\n");
            for (mod.symbols.items) |sym| {
                if (sym.kind == .function) if (sym.function) |f| {
                    if (f.is_pub and f.generic_return == null) try renderFn(&buf, f, null);
                };
            }
        }
        if (has_consts) {
            try buf.writeAll("<h2 id=\"section-constants\">Constants</h2>\n");
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
    if (mods.len > 0) Progress.endFiles();

    // ── guide pages ──────────────────────────────────────────────────────────
    if (guidesHaveEntries(guides)) {
        var n_guides: usize = 0;
        for (guides) |item| switch (item) {
            .entry   => n_guides += 1,
            .section => |s| n_guides += s.entries.len,
        };
        var label_buf: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "rendering guides ({d} page{s})", .{
            n_guides, if (n_guides == 1) "" else "s",
        }) catch "rendering guides";
        progress.begin(label);

        for (guides) |item| switch (item) {
            .entry => |e| {
                Progress.setCurrent(e.slug);
                try renderGuidePage(allocator, &out_dir, e, project_name, mods, guides, emoji_provider);
            },
            .section => |s| for (s.entries) |e| {
                Progress.setCurrent(e.slug);
                try renderGuidePage(allocator, &out_dir, e, project_name, mods, guides, emoji_provider);
            },
        };
        Progress.endFiles();
    }
}

fn renderGuidePage(
    allocator: std.mem.Allocator,
    out_dir: *std.fs.Dir,
    entry: GuideEntry,
    project_name: []const u8,
    mods: []const symbols.Module,
    guides: []const GuideNavItem,
    emoji_provider: emoji.Provider,
) !void {
    var buf = Buf.init(allocator, emoji_provider);
    defer buf.deinit();

    const title = try std.fmt.allocPrint(allocator, "{s} — {s}", .{ entry.title, project_name });
    defer allocator.free(title);

    // Pages in subdirs (slug contains '/') need an extra ".." to reach root
    const prefix: []const u8 = if (std.mem.indexOfScalar(u8, entry.slug, '/') != null)
        "../.."
    else
        "..";

    try writeHeader(&buf, title, project_name, mods, guides, null, entry.slug, prefix);
    try writeGuideToc(&buf, entry.content);
    try writeNavClose(&buf);

    const raw = try markdown.toHtml(allocator, entry.content);
    defer allocator.free(raw);
    const html = try emoji.replaceInHtml(allocator, raw, emoji_provider);
    defer allocator.free(html);

    try buf.writeAll("<div class=\"guide-content\">\n");
    try buf.writeAll(html);
    try buf.writeAll("</div>\n");

    try writeFooter(&buf);

    const filename = try std.fmt.allocPrint(allocator, "guide/{s}.html", .{entry.slug});
    defer allocator.free(filename);

    // Ensure parent directory exists for nested slugs
    if (std.fs.path.dirname(filename)) |dir_path| {
        try out_dir.makePath(dir_path);
    }

    const file = try out_dir.createFile(filename, .{});
    defer file.close();
    try buf.flush(file);
}
