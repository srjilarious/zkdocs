const std = @import("std");
const symbols = @import("./symbols.zig");
pub const markdown = @import("./markdown.zig");
const emoji = @import("./emoji.zig");
pub const cache_mod = @import("./cache.zig");
const example_mod = @import("./example.zig");

const CSS = @embedFile("assets/style.css");
const MINISEARCH_JS = @embedFile("assets/minisearch.min.js");
const SEARCH_JS = @embedFile("assets/search.js");

// ---------------------------------------------------------------------------
// Theme
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Progress reporting
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

pub const GuideEntry = struct {
    slug: []const u8, // URL path, e.g. "getting-started" or "reference/cli"
    title: []const u8,
    content: []const u8,
    /// Absolute path to the source .md file; used for cache mtime checks.
    /// Empty string when the entry was not loaded from a file.
    src_path: []const u8,
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
    if (e.src_path.len > 0) allocator.free(e.src_path);
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

/// A single literate example page loaded from a `.zig` source file.
pub const ExampleEntry = struct {
    slug: []const u8,
    title: []const u8,
    /// Absolute path to the source .zig file; used for cache mtime checks.
    src_path: []const u8,
    /// Raw source content (loaded at conf-parse time).
    src: []const u8,

    pub fn deinit(self: *ExampleEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.slug);
        allocator.free(self.title);
        allocator.free(self.src_path);
        allocator.free(self.src);
    }
};

fn guidesHaveEntries(guides: []const GuideNavItem) bool {
    for (guides) |item| switch (item) {
        .entry => return true,
        .section => |s| if (s.entries.len > 0) return true,
    };
    return false;
}

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
            switch (sym.kind) {
                .container => if (sym.container) |c| {
                    if (c.is_pub) try idx.put(c.name, .{
                        .module_name = mod.name,
                        .anchor_name = c.name,
                    });
                },
                .function => if (sym.function) |f| {
                    if (f.is_pub and f.generic_return != null) try idx.put(f.name, .{
                        .module_name = mod.name,
                        .anchor_name = f.name,
                    });
                },
                else => {},
            }
        }
    }
    return idx;
}

// ---------------------------------------------------------------------------
// Internal write buffer
// ---------------------------------------------------------------------------

const Buf = struct {
    list: std.ArrayList(u8),
    alloc: std.mem.Allocator,
    emoji_provider: emoji.Provider,
    theme: Theme,
    /// Set for API pages so type names can be linked.
    type_index: ?*const TypeIndex = null,
    current_module: []const u8 = "",
    /// Slug of the guide rendered as index.html, if any.
    home_slug: ?[]const u8 = null,

    fn init(alloc: std.mem.Allocator, provider: emoji.Provider, theme: Theme) Buf {
        return .{ .list = .{}, .alloc = alloc, .emoji_provider = provider, .theme = theme };
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

/// Emit `type_src` with known type names wrapped in `<a>` links.
/// Falls back to plain HTML escaping when no type index is set.
/// `skip_name`: the current container's name; its occurrences are not linked
/// (avoids a self-referential link when rendering a type's own methods).
fn writeTypeSrc(buf: *Buf, type_src: []const u8, skip_name: ?[]const u8) !void {
    const idx = buf.type_index orelse return htmlEscape(buf, type_src);
    var i: usize = 0;
    while (i < type_src.len) {
        const c = type_src[i];
        if (std.ascii.isAlphabetic(c) or c == '_') {
            // Collect a full identifier.
            var j = i + 1;
            while (j < type_src.len and
                (std.ascii.isAlphanumeric(type_src[j]) or type_src[j] == '_')) j += 1;
            const ident = type_src[i..j];

            const is_skip = if (skip_name) |sn| std.mem.eql(u8, ident, sn) else false;
            if (!is_skip) {
                if (idx.get(ident)) |ref| {
                    // Same module → fragment-only href; other module → sibling file.
                    if (std.mem.eql(u8, ref.module_name, buf.current_module)) {
                        try buf.print(
                            "<a href=\"#sym-{s}\" class=\"type-link\">{s}</a>",
                            .{ ref.anchor_name, ident },
                        );
                    } else {
                        try buf.print(
                            "<a href=\"{s}.html#sym-{s}\" class=\"type-link\">{s}</a>",
                            .{ ref.module_name, ref.anchor_name, ident },
                        );
                    }
                    i = j;
                    continue;
                }
            }
            // Unknown type or skipped — emit plain (identifiers have no HTML special chars).
            try buf.writeAll(ident);
            i = j;
        } else {
            switch (c) {
                '<' => try buf.writeAll("&lt;"),
                '>' => try buf.writeAll("&gt;"),
                '&' => try buf.writeAll("&amp;"),
                '"' => try buf.writeAll("&quot;"),
                else => try buf.list.append(buf.alloc, c),
            }
            i += 1;
        }
    }
}

fn firstSentence(text: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, text, '.')) |pos| return text[0 .. pos + 1];
    return text;
}

/// Rewrite inline `<code>Identifier</code>` spans in rendered doc HTML to
/// links when the identifier names a known symbol.  Spans inside `<pre>` are
/// left untouched so fenced code examples are never turned into links.
fn linkCodeSymbols(
    allocator: std.mem.Allocator,
    html: []const u8,
    type_index: *const TypeIndex,
    current_module: []const u8,
) ![]const u8 {
    const open_code = "<code>";
    const close_code = "</code>";
    const open_pre = "<pre";
    const close_pre = "</pre>";

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);

    var rest = html;
    while (rest.len > 0) {
        const pre_pos = std.mem.indexOf(u8, rest, open_pre);
        const code_pos = std.mem.indexOf(u8, rest, open_code);

        // No more <code> spans at all — flush and stop.
        if (code_pos == null) {
            try out.appendSlice(allocator, rest);
            break;
        }

        // A <pre> appears before the next <code> — copy through to </pre>.
        if (pre_pos != null and pre_pos.? < code_pos.?) {
            try out.appendSlice(allocator, rest[0..pre_pos.?]);
            const tail = rest[pre_pos.?..];
            const end = (std.mem.indexOf(u8, tail, close_pre) orelse tail.len - close_pre.len) +
                close_pre.len;
            try out.appendSlice(allocator, tail[0..end]);
            rest = tail[end..];
            continue;
        }

        // Emit everything before the <code>.
        try out.appendSlice(allocator, rest[0..code_pos.?]);
        const after_open = rest[code_pos.? + open_code.len ..];

        const close_pos = std.mem.indexOf(u8, after_open, close_code) orelse {
            // Malformed — emit the open tag literally and keep scanning.
            try out.appendSlice(allocator, open_code);
            rest = after_open;
            continue;
        };

        const content = after_open[0..close_pos];

        // Returns true when `s` is a valid Zig identifier.
        const isIdent = struct {
            fn f(s: []const u8) bool {
                if (s.len == 0) return false;
                for (s, 0..) |c, i| {
                    if (c == '_' or std.ascii.isAlphabetic(c)) continue;
                    if (i > 0 and std.ascii.isDigit(c)) return false;
                    if (i == 0) return false;
                }
                return true;
            }
        }.f;

        // ── Plain type/generic name: `Point`, `Stack` ────────────────────────
        if (isIdent(content)) {
            if (type_index.get(content)) |ref| {
                if (std.mem.eql(u8, ref.module_name, current_module)) {
                    try out.writer(allocator).print(
                        "<a href=\"#sym-{s}\" class=\"type-link\"><code>{s}</code></a>",
                        .{ ref.anchor_name, content },
                    );
                } else {
                    try out.writer(allocator).print(
                        "<a href=\"{s}.html#sym-{s}\" class=\"type-link\"><code>{s}</code></a>",
                        .{ ref.module_name, ref.anchor_name, content },
                    );
                }
                rest = after_open[close_pos + close_code.len ..];
                continue;
            }
        }

        // ── Type.method (or Generic.method): `EventBus.subscribe` ────────────
        if (std.mem.indexOfScalar(u8, content, '.')) |dot| {
            const lhs = content[0..dot];
            const rhs = content[dot + 1 ..];
            // Require exactly one dot and both sides to be valid identifiers.
            if (isIdent(lhs) and isIdent(rhs) and
                std.mem.indexOfScalar(u8, rhs, '.') == null)
            {
                if (type_index.get(lhs)) |ref| {
                    if (std.mem.eql(u8, ref.module_name, current_module)) {
                        try out.writer(allocator).print(
                            "<a href=\"#sym-{s}-{s}\" class=\"type-link\"><code>{s}</code></a>",
                            .{ lhs, rhs, content },
                        );
                    } else {
                        try out.writer(allocator).print(
                            "<a href=\"{s}.html#sym-{s}-{s}\" class=\"type-link\"><code>{s}</code></a>",
                            .{ ref.module_name, lhs, rhs, content },
                        );
                    }
                    rest = after_open[close_pos + close_code.len ..];
                    continue;
                }
            }
        }

        // Unknown — emit verbatim.
        try out.appendSlice(allocator, open_code);
        try out.appendSlice(allocator, content);
        try out.appendSlice(allocator, close_code);
        rest = after_open[close_pos + close_code.len ..];
    }

    return out.toOwnedSlice(allocator);
}

fn writeDoc(buf: *Buf, doc: []const u8) !void {
    const raw = try markdown.toHtml(buf.alloc, doc);
    defer buf.alloc.free(raw);
    const with_emoji = try emoji.replaceInHtml(buf.alloc, raw, buf.emoji_provider);
    defer buf.alloc.free(with_emoji);
    const html: []const u8 = if (buf.type_index) |idx| blk: {
        const linked = try linkCodeSymbols(buf.alloc, with_emoji, idx, buf.current_module);
        break :blk linked;
    } else with_emoji;
    defer if (buf.type_index != null) buf.alloc.free(html);
    try buf.writeAll("<div class=\"symbol-doc\">");
    try buf.writeAll(html);
    try buf.writeAll("</div>\n");
}

// ---------------------------------------------------------------------------
// Module nav helpers
// ---------------------------------------------------------------------------

/// Recursively write a module nav `<li>` with any child modules nested inside.
fn writeModuleNavItem(
    buf: *Buf,
    mod: symbols.Module,
    all_mods: []const symbols.Module,
    active_module: ?[]const u8,
    prefix: []const u8,
) !void {
    const active = if (active_module) |am| std.mem.eql(u8, am, mod.name) else false;
    const cls: []const u8 = if (active) " class=\"active\"" else "";
    try buf.print("<li><a href=\"{s}/api/{s}.html\"{s}>", .{ prefix, mod.name, cls });
    try htmlEscape(buf, mod.name);
    try buf.writeAll("</a>");

    // Emit children (modules whose parent_name == this module's name).
    var has_children = false;
    for (all_mods) |child| {
        if (child.parent_name) |pn| {
            if (std.mem.eql(u8, pn, mod.name)) {
                has_children = true;
                break;
            }
        }
    }
    if (has_children) {
        try buf.writeAll("\n<ul class=\"nav-children\">\n");
        for (all_mods) |child| {
            if (child.parent_name) |pn| {
                if (std.mem.eql(u8, pn, mod.name))
                    try writeModuleNavItem(buf, child, all_mods, active_module, prefix);
            }
        }
        try buf.writeAll("</ul>\n");
    }
    try buf.writeAll("</li>\n");
}

// ---------------------------------------------------------------------------
// Page header / nav / footer
// ---------------------------------------------------------------------------

/// Write the page <head>, <body>, the left nav sidebar, and open <main>.
/// The per-page TOC aside is written after the main content via writeApiToc / writeGuideToc.
fn writeHeader(
    buf: *Buf,
    title: []const u8,
    project_name: []const u8,
    mods: []const symbols.Module,
    guides: []const GuideNavItem,
    examples: []const ExampleEntry,
    active_module: ?[]const u8,
    active_guide: ?[]const u8,
    active_example: ?[]const u8,
    prefix: []const u8,
) !void {
    try buf.writeAll("<!DOCTYPE html>\n<html lang=\"en\"");
    if (buf.theme.toAttr()) |attr| try buf.print(" data-theme=\"{s}\"", .{attr});
    try buf.print(
        \\>
        \\<head>
        \\<meta charset="UTF-8">
        \\<meta name="viewport" content="width=device-width,initial-scale=1">
        \\<title>
    , .{});
    try htmlEscape(buf, title);
    try buf.print(
        \\</title>
        \\<link rel="stylesheet" href="{s}/assets/style.css">
        \\<script>window.ZKDOCS_BASE='{s}/';</script>
        \\<script src="{s}/assets/minisearch.min.js" defer></script>
        \\<script src="{s}/assets/search-data.js" defer></script>
        \\<script src="{s}/assets/search.js" defer></script>
        \\</head>
        \\<body>
    , .{ prefix, prefix, prefix, prefix, prefix });
    // Mobile top bar
    try buf.print(
        \\<div class="mobile-bar">
        \\<button class="mob-btn" id="nav-toggle" aria-label="Open navigation"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="3" y1="6" x2="21" y2="6"/><line x1="3" y1="12" x2="21" y2="12"/><line x1="3" y1="18" x2="21" y2="18"/></svg></button>
        \\<a class="mob-title" href="{s}/index.html">
    , .{prefix});
    try htmlEscape(buf, project_name);
    try buf.writeAll(
        \\</a>
        \\<button class="mob-btn" id="toc-toggle" aria-label="On this page"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="8" y1="6" x2="21" y2="6"/><line x1="8" y1="12" x2="21" y2="12"/><line x1="8" y1="18" x2="21" y2="18"/><circle cx="3" cy="6" r="1.5" fill="currentColor"/><circle cx="3" cy="12" r="1.5" fill="currentColor"/><circle cx="3" cy="18" r="1.5" fill="currentColor"/></svg></button>
        \\</div>
        \\<div class="overlay" id="overlay"></div>
        \\<nav class="sidebar">
        \\
    );
    try buf.print("<a class=\"logo\" href=\"{s}/index.html\">", .{prefix});
    try htmlEscape(buf, project_name);
    try buf.writeAll("</a>\n");
    // Search bar
    try buf.writeAll(
        \\<div class="search-box">
        \\<input type="search" id="search-input" placeholder="Search docs&#x2026;" autocomplete="off" spellcheck="false">
        \\<div class="search-results" id="search-results"></div>
        \\</div>
        \\
    );

    if (guidesHaveEntries(guides)) {
        try buf.writeAll("<details class=\"nav-section\" open>\n<summary>Guides</summary>\n<ul>\n");
        for (guides) |item| {
            switch (item) {
                .entry => |e| {
                    const active = if (active_guide) |ag| std.mem.eql(u8, ag, e.slug) else false;
                    const cls: []const u8 = if (active) " class=\"active\"" else "";
                    const is_home = if (buf.home_slug) |hs| std.mem.eql(u8, hs, e.slug) else false;
                    if (is_home) {
                        try buf.print("<li><a href=\"{s}/index.html\"{s}>", .{ prefix, cls });
                    } else {
                        try buf.print("<li><a href=\"{s}/guide/{s}.html\"{s}>", .{ prefix, e.slug, cls });
                    }
                    try htmlEscape(buf, e.title);
                    try buf.writeAll("</a></li>\n");
                },
                .section => |s| {
                    try buf.writeAll("<details class=\"nav-subsection\" open>\n<summary>");
                    try htmlEscape(buf, s.title);
                    try buf.writeAll("</summary>\n<ul>\n");
                    for (s.entries) |e| {
                        const active = if (active_guide) |ag| std.mem.eql(u8, ag, e.slug) else false;
                        const cls: []const u8 = if (active) " class=\"active\"" else "";
                        const is_home = if (buf.home_slug) |hs| std.mem.eql(u8, hs, e.slug) else false;
                        if (is_home) {
                            try buf.print("<li><a href=\"{s}/index.html\"{s}>", .{ prefix, cls });
                        } else {
                            try buf.print("<li><a href=\"{s}/guide/{s}.html\"{s}>", .{ prefix, e.slug, cls });
                        }
                        try htmlEscape(buf, e.title);
                        try buf.writeAll("</a></li>\n");
                    }
                    try buf.writeAll("</ul>\n</details>\n");
                },
            }
        }
        try buf.writeAll("</ul>\n</details>\n");
    }

    if (mods.len > 0) {
        try buf.writeAll("<details class=\"nav-section\" open>\n<summary>Modules</summary>\n<ul>\n");
        for (mods) |mod| {
            // Only render top-level (root) modules here; children are nested inside their parent.
            if (mod.parent_name == null)
                try writeModuleNavItem(buf, mod, mods, active_module, prefix);
        }
        try buf.writeAll("</ul>\n</details>\n");
    }

    if (examples.len > 0) {
        try buf.writeAll("<details class=\"nav-section\" open>\n<summary>Examples</summary>\n<ul>\n");
        for (examples) |e| {
            const is_active = if (active_example) |ae| std.mem.eql(u8, ae, e.slug) else false;
            const ex_href = try std.fmt.allocPrint(buf.alloc, "{s}/example/{s}.html", .{ prefix, e.slug });
            defer buf.alloc.free(ex_href);
            if (is_active) {
                try buf.print("<li><a href=\"{s}\" class=\"active\">", .{ex_href});
            } else {
                try buf.print("<li><a href=\"{s}\">", .{ex_href});
            }
            try htmlEscape(buf, e.title);
            try buf.writeAll("</a></li>\n");
        }
        try buf.writeAll("</ul>\n</details>\n");
    }

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
    var has_types = false;
    var has_fns = false;
    var has_consts = false;
    for (mod.symbols.items) |sym| {
        switch (sym.kind) {
            .container => if (sym.container) |c| {
                if (c.is_pub) has_types = true;
            },
            .function => if (sym.function) |f| {
                if (f.is_pub and f.generic_return != null) has_types = true;
                if (f.is_pub and f.generic_return == null) has_fns = true;
            },
            .variable => if (sym.variable) |v| {
                if (v.is_pub) has_consts = true;
            },
            else => {},
        }
    }
    if (!has_types and !has_fns and !has_consts) return;

    try buf.writeAll("<aside class=\"page-toc\">\n<h4>On this page</h4>\n<ul>\n");

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
                if (d.kind == .function) if (d.function) |mf| {
                    if (mf.is_pub) {
                        has_methods = true;
                        break;
                    }
                };
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
                if (d.kind == .function) if (d.function) |mf| {
                    if (mf.is_pub) {
                        has_methods = true;
                        break;
                    }
                };
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

    try buf.writeAll("</ul>\n</aside>\n");
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
            if (std.mem.startsWith(u8, t, "## ")) {
                has_h2 = true;
                break;
            }
        }
    }
    if (!has_h2) return;

    try buf.writeAll("<aside class=\"page-toc\">\n<h4>On this page</h4>\n<ul class=\"toc-children\">\n");

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

    try buf.writeAll("</ul>\n</aside>\n");
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
        try writeTypeSrc(buf, p.type_src, parent_container);
        try buf.writeAll("</span>");
    }
    try buf.writeAll(")");
    if (f.return_type_src) |r| {
        try buf.writeAll(" <span class=\"type-name\">");
        try writeTypeSrc(buf, r, parent_container);
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
                if (field.type_src) |t| try writeTypeSrc(buf, t, f.name);
                try buf.writeAll("</td><td class=\"field-doc\">");
                if (field.doc) |d| try htmlEscape(buf, d);
                try buf.writeAll("</td></tr>\n");
            }
            try buf.writeAll("</table>\n");
        }

        var has_pub_decls = false;
        for (gr.decls.items) |d| {
            if (d.kind == .function) if (d.function) |mf| {
                if (mf.is_pub) {
                    has_pub_decls = true;
                    break;
                }
            };
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
            if (f.type_src) |t| try writeTypeSrc(buf, t, c.name);
            try buf.writeAll("</td><td class=\"field-doc\">");
            if (f.doc) |d| try htmlEscape(buf, d);
            try buf.writeAll("</td></tr>\n");
        }
        try buf.writeAll("</table>\n");
    }

    var has_pub_decls = false;
    for (c.decls.items) |d| {
        if (d.kind == .function) if (d.function) |f| {
            if (f.is_pub) {
                has_pub_decls = true;
                break;
            }
        };
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
        try writeTypeSrc(buf, t, null);
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

    // Resolve to absolute path for cache mtime tracking.
    const src_path = cache_mod.absPath(allocator, full_path) catch try allocator.dupe(u8, full_path);
    errdefer allocator.free(src_path);

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

    return .{ .slug = slug, .title = title, .content = content, .src_path = src_path };
}

// ---------------------------------------------------------------------------
// JSON with comments
// ---------------------------------------------------------------------------

/// Strip `//`-style line comments from `src` and return a freshly allocated
/// copy suitable for passing to `std.json.parseFromSlice`.
///
/// A comment is any line whose first non-whitespace characters are `//`.
/// The entire line (including its trailing newline) is replaced by a blank
/// line so that byte offsets in error messages remain meaningful.
pub fn stripJsonComments(allocator: std.mem.Allocator, src: []const u8) ![]const u8 {
    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);

    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "//")) {
            // Emit a blank line to preserve line numbers.
            try out.append(allocator, '\n');
        } else {
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
        }
    }

    return out.toOwnedSlice(allocator);
}

/// Parse `src` as JSON, transparently ignoring `//`-prefixed comment lines.
/// Returns a `std.json.Parsed(std.json.Value)`; the caller must call `.deinit()`.
pub fn parseJsonWithComments(
    allocator: std.mem.Allocator,
    src: []const u8,
) !std.json.Parsed(std.json.Value) {
    const stripped = try stripJsonComments(allocator, src);
    defer allocator.free(stripped);
    return std.json.parseFromSlice(std.json.Value, allocator, stripped, .{});
}

// ---------------------------------------------------------------------------
// Full site config (zkdocs.conf)
// ---------------------------------------------------------------------------

/// Parsed contents of a `zkdocs.conf` file.
/// All string fields are heap-allocated; call `deinit` to free them.
pub const SiteConf = struct {
    /// Project name (`"name"` key), or null if absent.
    name: ?[]const u8,
    /// Root source file paths (`"sources"` array), or null if absent.
    sources: ?[][]const u8,
    /// Color theme (`"theme"` key), defaults to `.default`.
    theme: Theme,
    /// Emoji provider string (`"emoji"` key), or null if absent.
    emoji: ?[]const u8,
    /// Parsed guide nav items (`"guides"` array).
    guides: []GuideNavItem,
    /// Directory containing the conf file; used to resolve relative image paths.
    conf_dir: []const u8,
    /// Slug of the guide to render as `index.html` (`"home"` key), or null.
    home_slug: ?[]const u8,
    /// Literate example pages (`"examples"` array in conf).
    examples: ?[]ExampleEntry = null,

    pub fn deinit(self: *SiteConf, allocator: std.mem.Allocator) void {
        if (self.name) |n| allocator.free(n);
        if (self.sources) |srcs| {
            for (srcs) |s| allocator.free(s);
            allocator.free(srcs);
        }
        if (self.emoji) |e| allocator.free(e);
        freeGuides(allocator, self.guides);
        allocator.free(self.conf_dir);
        if (self.home_slug) |hs| allocator.free(hs);
        if (self.examples) |exs| {
            for (exs) |*e| e.deinit(allocator);
            allocator.free(exs);
        }
    }
};

/// Parse a `zkdocs.conf` JSON file and return a `SiteConf`.
/// The caller owns the result and must call `result.deinit(allocator)`.
pub fn loadSiteConf(allocator: std.mem.Allocator, conf_path: []const u8) !SiteConf {
    const raw = try std.fs.cwd().readFileAlloc(allocator, conf_path, 2 * 1024 * 1024);
    defer allocator.free(raw);

    const conf_dir = std.fs.path.dirname(conf_path) orelse ".";

    const parsed = try parseJsonWithComments(allocator, raw);
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidConfig;
    const obj = parsed.value.object;

    // --- name ---
    const name: ?[]const u8 = if (obj.get("name")) |v|
        if (v == .string) try allocator.dupe(u8, v.string) else null
    else
        null;
    errdefer if (name) |n| allocator.free(n);

    // --- sources ---
    var sources: ?[][]const u8 = null;
    errdefer if (sources) |srcs| {
        for (srcs) |s| allocator.free(s);
        allocator.free(srcs);
    };
    if (obj.get("sources")) |sv| if (sv == .array) {
        var list = std.ArrayList([]const u8){};
        errdefer {
            for (list.items) |s| allocator.free(s);
            list.deinit(allocator);
        }
        for (sv.array.items) |item| {
            if (item != .string) continue;
            // Resolve each source path relative to the conf file directory.
            const resolved = try std.fs.path.join(allocator, &.{ conf_dir, item.string });
            try list.append(allocator, resolved);
        }
        sources = try list.toOwnedSlice(allocator);
    };

    // --- theme ---
    const theme: Theme = if (obj.get("theme")) |tv|
        if (tv == .string) Theme.fromStr(tv.string) orelse .default else .default
    else
        .default;

    // --- emoji ---
    const ep: ?[]const u8 = if (obj.get("emoji")) |v|
        if (v == .string) try allocator.dupe(u8, v.string) else null
    else
        null;
    errdefer if (ep) |e| allocator.free(e);

    // --- guides ---
    var guides: []GuideNavItem = &.{};
    if (obj.get("guides")) |gv| if (gv == .array) {
        var items = std.ArrayList(GuideNavItem){};
        errdefer {
            for (items.items) |*it| freeNavItem(allocator, it);
            items.deinit(allocator);
        }
        for (gv.array.items) |json_item| {
            if (json_item != .object) continue;
            const item_obj = json_item.object;
            if (item_obj.get("section")) |sec_val| {
                if (sec_val != .string) continue;
                const sec_title = try allocator.dupe(u8, sec_val.string);
                errdefer allocator.free(sec_title);
                var sec_entries = std.ArrayList(GuideEntry){};
                errdefer {
                    for (sec_entries.items) |*e| freeGuideEntry(allocator, e);
                    sec_entries.deinit(allocator);
                }
                if (item_obj.get("entries")) |ev| if (ev == .array) {
                    for (ev.array.items) |ei| {
                        if (ei != .object) continue;
                        const e = try loadGuideEntry(allocator, ei.object, conf_dir);
                        errdefer freeGuideEntry(allocator, @constCast(&e));
                        try sec_entries.append(allocator, e);
                    }
                };
                const sec_slice = try sec_entries.toOwnedSlice(allocator);
                errdefer {
                    for (sec_slice) |*e| freeGuideEntry(allocator, e);
                    allocator.free(sec_slice);
                }
                try items.append(allocator, .{ .section = .{ .title = sec_title, .entries = sec_slice } });
            } else if (item_obj.get("src") != null) {
                const e = try loadGuideEntry(allocator, item_obj, conf_dir);
                errdefer freeGuideEntry(allocator, @constCast(&e));
                try items.append(allocator, .{ .entry = e });
            }
        }
        guides = try items.toOwnedSlice(allocator);
    };

    // --- home ---
    // Accept either a slug ("getting-started") or a src filename ("getting-started.md").
    const home_slug: ?[]const u8 = if (obj.get("home")) |v| blk: {
        if (v != .string) break :blk null;
        const home_src = v.string;
        const home_slug_str = if (std.mem.endsWith(u8, home_src, ".md")) home_src[0 .. home_src.len - 3] else home_src;
        break :blk try allocator.dupe(u8, home_slug_str);
    } else null;
    errdefer if (home_slug) |hs| allocator.free(hs);

    // --- examples ---
    var examples: ?[]ExampleEntry = null;
    errdefer if (examples) |exs| {
        for (exs) |*e| e.deinit(allocator);
        allocator.free(exs);
    };
    if (obj.get("examples")) |ev| if (ev == .array) {
        var exs: std.ArrayList(ExampleEntry) = .{};
        errdefer {
            for (exs.items) |*e| e.deinit(allocator);
            exs.deinit(allocator);
        }
        for (ev.array.items) |item| {
            if (item != .object) continue;
            const eobj = item.object;
            const title_v = eobj.get("title") orelse continue;
            const src_v = eobj.get("src") orelse continue;
            if (title_v != .string or src_v != .string) continue;

            const full_path = try std.fs.path.join(allocator, &.{ conf_dir, src_v.string });
            defer allocator.free(full_path);

            const src_path = cache_mod.absPath(allocator, full_path) catch
                try allocator.dupe(u8, full_path);
            errdefer allocator.free(src_path);

            const src = try std.fs.cwd().readFileAlloc(allocator, full_path, 4 * 1024 * 1024);
            errdefer allocator.free(src);

            const stem = std.fs.path.stem(src_v.string);
            const slug = try allocator.dupe(u8, stem);
            errdefer allocator.free(slug);

            const title = try allocator.dupe(u8, title_v.string);
            errdefer allocator.free(title);

            try exs.append(allocator, .{
                .slug = slug,
                .title = title,
                .src_path = src_path,
                .src = src,
            });
        }
        examples = try exs.toOwnedSlice(allocator);
    };

    return .{
        .name = name,
        .sources = sources,
        .theme = theme,
        .emoji = ep,
        .guides = guides,
        .conf_dir = try allocator.dupe(u8, conf_dir),
        .home_slug = home_slug,
        .examples = examples,
    };
}

// ---------------------------------------------------------------------------
// Search index
// ---------------------------------------------------------------------------

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
    try buf.writer(allocator).print("{{\"id\":{d},\"title\":", .{id});
    try jsonEscapeStr(buf, allocator, title);
    try buf.appendSlice(allocator, ",\"content\":");
    try jsonEscapeStr(buf, allocator, trunc);
    try buf.appendSlice(allocator, ",\"url\":");
    try jsonEscapeStr(buf, allocator, url);
    try buf.appendSlice(allocator, ",\"type\":");
    try jsonEscapeStr(buf, allocator, doc_type);
    try buf.append(allocator, '}');
}

fn writeSearchIndex(
    allocator: std.mem.Allocator,
    out_dir: *std.fs.Dir,
    mods: []const symbols.Module,
    guides: []const GuideNavItem,
    examples: []const ExampleEntry,
    home_slug: ?[]const u8,
) !void {
    var buf: std.ArrayList(u8) = .{};
    defer buf.deinit(allocator);

    // Assign to a global so the index works on file:// URLs (fetch() is blocked there).
    try buf.appendSlice(allocator, "window.ZKDOCS_SEARCH_INDEX=[");
    var id: usize = 0;

    // Guide entries
    for (guides) |item| {
        switch (item) {
            .entry => |e| {
                const is_home = if (home_slug) |hs| std.mem.eql(u8, hs, e.slug) else false;
                const url = if (is_home)
                    try allocator.dupe(u8, "index.html")
                else
                    try std.fmt.allocPrint(allocator, "guide/{s}.html", .{e.slug});
                defer allocator.free(url);
                if (id > 0) try buf.append(allocator, ',');
                try appendSearchDoc(&buf, allocator, id, e.title, e.content, url, "guide");
                id += 1;
            },
            .section => |s| {
                for (s.entries) |e| {
                    const url = try std.fmt.allocPrint(allocator, "guide/{s}.html", .{e.slug});
                    defer allocator.free(url);
                    if (id > 0) try buf.append(allocator, ',');
                    try appendSearchDoc(&buf, allocator, id, e.title, e.content, url, "guide");
                    id += 1;
                }
            },
        }
    }

    // Example pages
    for (examples) |e| {
        const url = try std.fmt.allocPrint(allocator, "example/{s}.html", .{e.slug});
        defer allocator.free(url);
        if (id > 0) try buf.append(allocator, ',');
        try appendSearchDoc(&buf, allocator, id, e.title, e.src, url, "example");
        id += 1;
    }

    // API symbols
    for (mods) |mod| {
        for (mod.symbols.items) |sym| {
            switch (sym.kind) {
                .function => if (sym.function) |f| {
                    if (f.is_pub) {
                        const url = try std.fmt.allocPrint(allocator, "api/{s}.html#sym-{s}", .{ mod.name, f.name });
                        defer allocator.free(url);
                        if (id > 0) try buf.append(allocator, ',');
                        try appendSearchDoc(&buf, allocator, id, f.name, f.doc orelse "", url, "api");
                        id += 1;
                    }
                },
                .container => if (sym.container) |c| {
                    if (c.is_pub) {
                        const url = try std.fmt.allocPrint(allocator, "api/{s}.html#sym-{s}", .{ mod.name, c.name });
                        defer allocator.free(url);
                        if (id > 0) try buf.append(allocator, ',');
                        try appendSearchDoc(&buf, allocator, id, c.name, c.doc orelse "", url, "api");
                        id += 1;
                    }
                },
                .variable => if (sym.variable) |v| {
                    if (v.is_pub) {
                        const url = try std.fmt.allocPrint(allocator, "api/{s}.html#sym-{s}", .{ mod.name, v.name });
                        defer allocator.free(url);
                        if (id > 0) try buf.append(allocator, ',');
                        try appendSearchDoc(&buf, allocator, id, v.name, v.doc orelse "", url, "api");
                        id += 1;
                    }
                },
                else => {},
            }
        }
    }

    try buf.appendSlice(allocator, "];");

    const file = try out_dir.createFile("assets/search-data.js", .{});
    defer file.close();
    try file.writeAll(buf.items);
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
///     guide/<slug>.html     (one per guide entry in zkdocs.conf)
pub fn renderSite(
    allocator: std.mem.Allocator,
    out_path: []const u8,
    project_name: []const u8,
    mods: []const symbols.Module,
    /// Guide nav items loaded from `zkdocs.conf`. Not freed by this function.
    guides: []const GuideNavItem,
    /// Literate example pages loaded from `zkdocs.conf`. Not freed by this function.
    examples: []const ExampleEntry,
    emoji_provider: emoji.Provider,
    theme: Theme,
    progress: *Progress,
    /// Directory of the conf file; used to resolve relative image paths in guides.
    /// Pass null when running without a conf file.
    conf_dir: ?[]const u8,
    /// Slug of the guide to render as `index.html`. When set the default module
    /// listing is replaced by that guide's content.
    home_slug: ?[]const u8,
    /// Mutable build cache used to skip unchanged outputs.  The caller owns
    /// the cache and must call `cache.save` (or discard) after this returns.
    cache: *cache_mod.Cache,
    /// Absolute path to the zkdocs.conf file, or null when running without one.
    /// Used to record the conf mtime in the cache.
    conf_abs_path: ?[]const u8,
) !void {
    var out_dir = try std.fs.cwd().makeOpenPath(out_path, .{});
    defer out_dir.close();

    // ── Determine what changed since the last run ────────────────────────────
    const conf_changed = if (conf_abs_path) |cp|
        !cache.confUnchanged(cp)
    else
        false;

    // Check whether any asset file (e.g. logo image) changed since the last run.
    const assets_changed = !cache.allAssetsUnchanged();

    // Check whether any source file has changed since the last run.
    var sources_changed = conf_changed or assets_changed;
    for (mods) |mod| {
        if (!cache.sourceUnchanged(mod.abs_path)) sources_changed = true;
    }

    try out_dir.makePath("api");

    // Write the stylesheet and JS assets.
    try out_dir.makePath("assets");
    {
        const css_file = try out_dir.createFile("assets/style.css", .{});
        defer css_file.close();
        try css_file.writeAll(CSS);
    }
    {
        const f = try out_dir.createFile("assets/minisearch.min.js", .{});
        defer f.close();
        try f.writeAll(MINISEARCH_JS);
    }
    {
        const f = try out_dir.createFile("assets/search.js", .{});
        defer f.close();
        try f.writeAll(SEARCH_JS);
    }
    try writeSearchIndex(allocator, &out_dir, mods, guides, examples, home_slug);

    if (guidesHaveEntries(guides)) try out_dir.makePath("guide");

    // Build type index once for cross-module type linking.
    var type_index = try buildTypeIndex(allocator, mods);
    defer type_index.deinit();

    // ── index.html ──────────────────────────────────────────────────────────

    // Find the home guide entry if one is designated.
    const home_entry: ?GuideEntry = blk: {
        const hs = home_slug orelse break :blk null;
        for (guides) |item| switch (item) {
            .entry => |e| if (std.mem.eql(u8, e.slug, hs)) break :blk e,
            .section => |s| for (s.entries) |e| {
                if (std.mem.eql(u8, e.slug, hs)) break :blk e;
            },
        };
        break :blk null;
    };

    const home_changed = if (home_entry) |he|
        he.src_path.len > 0 and !cache.guideUnchanged(he.src_path)
    else
        false;

    if (!conf_changed and !sources_changed and !home_changed) {
        progress.begin("index up to date");
    } else {
        progress.begin("writing index");
    }

    if (conf_changed or sources_changed or home_changed) {
        if (home_entry) |he| {
            // Render the designated guide as index.html.
            try renderGuidePage(allocator, &out_dir, he, project_name, mods, guides, examples, emoji_provider, theme, conf_dir, home_slug, true, cache);
        } else {
            var buf = Buf.init(allocator, emoji_provider, theme);
            defer buf.deinit();
            buf.home_slug = home_slug;

            try writeHeader(&buf, project_name, project_name, mods, guides, examples, null, null, null, ".");

            try buf.writeAll("<h1>");
            try htmlEscape(&buf, project_name);
            try buf.writeAll("</h1>\n");

            if (mods.len > 0) {
                try buf.writeAll("<h2>Modules</h2>\n<ul class=\"module-list\">\n");
                for (mods) |mod| {
                    try buf.print("<li><a href=\"./api/{s}.html\">", .{mod.name});
                    try htmlEscape(&buf, mod.name);
                    try buf.writeAll("</a>");

                    // Prefer the file-level //! doc; fall back to first symbol doc, then path.
                    const blurb: ?[]const u8 = mod.doc orelse blk: {
                        for (mod.symbols.items) |sym| {
                            const d: ?[]const u8 = switch (sym.kind) {
                                .function => if (sym.function) |f| f.doc else null,
                                .variable => if (sym.variable) |v| v.doc else null,
                                .container => if (sym.container) |c| c.doc else null,
                                else => null,
                            };
                            if (d != null) break :blk d;
                        }
                        break :blk null;
                    };
                    try buf.writeAll("<div class=\"mod-doc\">");
                    if (blurb) |b|
                        try htmlEscape(&buf, firstSentence(b))
                    else
                        try htmlEscape(&buf, mod.path);
                    try buf.writeAll("</div>");
                    try buf.writeAll("</li>\n");
                }
                try buf.writeAll("</ul>\n");
            }

            if (guidesHaveEntries(guides)) {
                try buf.writeAll("<h2>Guides</h2>\n<ul class=\"module-list\">\n");
                for (guides) |item| switch (item) {
                    .entry => |e| {
                        const is_home = if (home_slug) |hs| std.mem.eql(u8, hs, e.slug) else false;
                        if (is_home) {
                            try buf.print("<li><a href=\"./index.html\">", .{});
                        } else {
                            try buf.print("<li><a href=\"./guide/{s}.html\">", .{e.slug});
                        }
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
        } // end else (no home guide)
    } // end if (conf_changed or sources_changed)

    // ── api/<module>.html ────────────────────────────────────────────────────
    {
        var label_buf: [64]u8 = undefined;
        const label = if (!sources_changed)
            "api pages up to date"
        else
            std.fmt.bufPrint(&label_buf, "rendering api ({d} module{s})", .{
                mods.len, if (mods.len == 1) "" else "s",
            }) catch "rendering api";
        progress.begin(label);
    }
    if (sources_changed) {
        for (mods) |mod| {
            Progress.setCurrent(mod.name);
            var buf = Buf.init(allocator, emoji_provider, theme);
            defer buf.deinit();
            buf.type_index = &type_index;
            buf.current_module = mod.name;
            buf.home_slug = home_slug;

            const title = try std.fmt.allocPrint(allocator, "{s} — {s}", .{ mod.name, project_name });
            defer allocator.free(title);

            try writeHeader(&buf, title, project_name, mods, guides, examples, mod.name, null, null, "..");

            try buf.writeAll("<h1>");
            try htmlEscape(&buf, mod.name);
            try buf.writeAll("</h1>\n<div class=\"mod-path\">");
            try htmlEscape(&buf, mod.path);
            try buf.writeAll("</div>\n");
            if (mod.doc) |doc| try writeDoc(&buf, doc);

            var has_types = false;
            var has_fns = false;
            var has_consts = false;
            for (mod.symbols.items) |sym| {
                switch (sym.kind) {
                    .container => if (sym.container) |c| {
                        if (c.is_pub) has_types = true;
                    },
                    .function => if (sym.function) |f| {
                        if (f.is_pub and f.generic_return != null) has_types = true;
                        if (f.is_pub and f.generic_return == null) has_fns = true;
                    },
                    .variable => if (sym.variable) |v| {
                        if (v.is_pub) has_consts = true;
                    },
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

            try writeApiToc(&buf, mod);
            try writeFooter(&buf);

            const filename = try std.fmt.allocPrint(allocator, "api/{s}.html", .{mod.name});
            defer allocator.free(filename);
            const file = try out_dir.createFile(filename, .{});
            defer file.close();
            try buf.flush(file);
        }
        if (mods.len > 0) Progress.endFiles();
    }

    // ── guide pages ──────────────────────────────────────────────────────────
    if (guidesHaveEntries(guides)) {
        var n_guides: usize = 0;
        for (guides) |item| switch (item) {
            .entry => n_guides += 1,
            .section => |s| n_guides += s.entries.len,
        };
        var label_buf: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "rendering guides ({d} page{s})", .{
            n_guides, if (n_guides == 1) "" else "s",
        }) catch "rendering guides";
        progress.begin(label);

        for (guides) |item| switch (item) {
            .entry => |e| {
                if (home_slug) |hs| if (std.mem.eql(u8, hs, e.slug)) continue;
                // Skip if the guide source, conf, and assets are all unchanged.
                if (!conf_changed and !assets_changed and e.src_path.len > 0 and cache.guideUnchanged(e.src_path))
                    continue;
                Progress.setCurrent(e.slug);
                try renderGuidePage(allocator, &out_dir, e, project_name, mods, guides, examples, emoji_provider, theme, conf_dir, home_slug, false, cache);
            },
            .section => |s| for (s.entries) |e| {
                if (home_slug) |hs| if (std.mem.eql(u8, hs, e.slug)) continue;
                if (!conf_changed and !assets_changed and e.src_path.len > 0 and cache.guideUnchanged(e.src_path))
                    continue;
                Progress.setCurrent(e.slug);
                try renderGuidePage(allocator, &out_dir, e, project_name, mods, guides, examples, emoji_provider, theme, conf_dir, home_slug, false, cache);
            },
        };
        Progress.endFiles();
    }

    // ── example pages ────────────────────────────────────────────────────────
    if (examples.len > 0) {
        try out_dir.makePath("example");
        for (examples) |e| {
            if (!conf_changed and e.src_path.len > 0 and cache.sourceUnchanged(e.src_path))
                continue;
            Progress.setCurrent(e.slug);
            try renderExamplePage(allocator, &out_dir, e, project_name, mods, guides, examples, emoji_provider, theme, home_slug);
            Progress.endFiles();
        }
        for (examples) |e| {
            if (e.src_path.len > 0) cache.recordSource(e.src_path) catch {};
        }
    }

    // ── Update and save build cache ──────────────────────────────────────────
    if (conf_abs_path) |cp| cache.recordConf(cp) catch {};
    for (mods) |mod| cache.recordSource(mod.abs_path) catch {};
    for (guides) |item| switch (item) {
        .entry => |e| {
            if (e.src_path.len > 0) cache.recordGuide(e.src_path) catch {};
        },
        .section => |s| for (s.entries) |e| {
            if (e.src_path.len > 0) cache.recordGuide(e.src_path) catch {};
        },
    };
    cache.save(out_path) catch |err| {
        std.debug.print("  warning: could not write build cache: {}\n", .{err});
    };
}

// ---------------------------------------------------------------------------
// Internal link resolution
// ---------------------------------------------------------------------------

/// Locate a public symbol by name across all modules.
/// Accepts:
///   `"Name"`            — searched across all modules
///   `"module.Name"`     — scoped to the named module
///   `"Container.method"`— method inside a container (fallback when first part is not a module)
const SymbolRef = struct {
    module_name: []const u8,
    /// Non-null for method lookups (Container.method syntax).
    container: ?[]const u8 = null,
    name: []const u8,
};

fn findSymbolRef(mods: []const symbols.Module, target: []const u8) ?SymbolRef {
    if (std.mem.indexOfScalar(u8, target, '.')) |dot| {
        const lhs = target[0..dot];
        const rhs = target[dot + 1 ..];

        // Check if lhs is a module name first.
        for (mods) |mod| {
            if (std.mem.eql(u8, mod.name, lhs)) {
                // module.Symbol — look up the symbol within this module only.
                for (mod.symbols.items) |sym| {
                    const sym_name: ?[]const u8 = switch (sym.kind) {
                        .function => if (sym.function) |f| (if (f.is_pub) f.name else null) else null,
                        .variable => if (sym.variable) |v| (if (v.is_pub) v.name else null) else null,
                        .container => if (sym.container) |c| (if (c.is_pub) c.name else null) else null,
                        else => null,
                    };
                    if (sym_name) |n| {
                        if (std.mem.eql(u8, n, rhs))
                            return .{ .module_name = mod.name, .name = n };
                    }
                }
                return null; // module found but symbol not in it
            }
        }

        // lhs is not a module → treat as Container.method.
        for (mods) |mod| {
            for (mod.symbols.items) |sym| {
                if (sym.kind == .container) {
                    if (sym.container) |c| {
                        if (c.is_pub and std.mem.eql(u8, c.name, lhs)) {
                            return .{ .module_name = mod.name, .container = c.name, .name = rhs };
                        }
                    }
                }
            }
        }
        return null;
    }

    // Plain symbol name — match across all modules.
    for (mods) |mod| {
        for (mod.symbols.items) |sym| {
            const sym_name: ?[]const u8 = switch (sym.kind) {
                .function => if (sym.function) |f| (if (f.is_pub) f.name else null) else null,
                .variable => if (sym.variable) |v| (if (v.is_pub) v.name else null) else null,
                .container => if (sym.container) |c| (if (c.is_pub) c.name else null) else null,
                else => null,
            };
            if (sym_name) |n| {
                if (std.mem.eql(u8, n, target))
                    return .{ .module_name = mod.name, .name = n };
            }
        }
    }
    return null;
}

/// Rewrite internal link schemes produced by the markdown parser into proper relative URLs.
///
/// Supported syntax in guide markdown:
///   `[text](sym:Name)`             → any public symbol (searched across all modules)
///   `[text](sym:module.Name)`      → symbol qualified by module name
///   `[text](sym:Container.method)` → method anchor (when first part is not a module)
///   `[text](mod:name)`             → module API page (`api/name.html`)
///   `[text](guide:slug)`           → another guide page (`guide/slug.html`)
pub fn resolveInternalLinks(
    allocator: std.mem.Allocator,
    html: []const u8,
    mods: []const symbols.Module,
    prefix: []const u8,
) ![]const u8 {
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);

    var rest = html;
    while (true) {
        const sym_pos = std.mem.indexOf(u8, rest, "href=\"sym:");
        const mod_pos = std.mem.indexOf(u8, rest, "href=\"mod:");
        const guide_pos = std.mem.indexOf(u8, rest, "href=\"guide:");

        // Pick the earliest marker.
        var fp: usize = std.math.maxInt(usize);
        if (sym_pos) |p| fp = @min(fp, p);
        if (mod_pos) |p| fp = @min(fp, p);
        if (guide_pos) |p| fp = @min(fp, p);
        if (fp == std.math.maxInt(usize)) {
            try out.appendSlice(allocator, rest);
            break;
        }

        try out.appendSlice(allocator, rest[0..fp]);

        const marker: []const u8 = if (sym_pos != null and fp == sym_pos.?)
            "href=\"sym:"
        else if (mod_pos != null and fp == mod_pos.?)
            "href=\"mod:"
        else
            "href=\"guide:";

        const after = rest[fp + marker.len ..];
        const close = std.mem.indexOfScalar(u8, after, '"') orelse {
            try out.appendSlice(allocator, marker);
            rest = after;
            continue;
        };
        const target = after[0..close];

        if (std.mem.eql(u8, marker, "href=\"sym:")) {
            if (findSymbolRef(mods, target)) |ref| {
                if (ref.container) |cont| {
                    try out.writer(allocator).print(
                        "href=\"{s}/api/{s}.html#sym-{s}-{s}",
                        .{ prefix, ref.module_name, cont, ref.name },
                    );
                } else {
                    try out.writer(allocator).print(
                        "href=\"{s}/api/{s}.html#sym-{s}",
                        .{ prefix, ref.module_name, ref.name },
                    );
                }
            } else {
                try out.writer(allocator).print("href=\"#sym-{s}", .{target});
            }
        } else if (std.mem.eql(u8, marker, "href=\"mod:")) {
            try out.writer(allocator).print(
                "href=\"{s}/api/{s}.html",
                .{ prefix, target },
            );
        } else {
            // guide:
            try out.writer(allocator).print(
                "href=\"{s}/guide/{s}.html",
                .{ prefix, target },
            );
        }

        rest = after[close..];

        // For sym: links with no explicit link text, inject `<code>name</code>`
        // so that `[](sym:Foo)` renders as [`Foo`](...) rather than a blank link.
        if (std.mem.eql(u8, marker, "href=\"sym:")) {
            if (std.mem.indexOf(u8, rest, ">")) |tag_end| {
                const after_tag = rest[tag_end + 1 ..];
                if (std.mem.startsWith(u8, after_tag, "</a>")) {
                    const display_name = if (std.mem.lastIndexOfScalar(u8, target, '.')) |dot|
                        target[dot + 1 ..]
                    else
                        target;
                    try out.appendSlice(allocator, rest[0 .. tag_end + 1]);
                    try out.writer(allocator).print("<code>{s}</code>", .{display_name});
                    try out.appendSlice(allocator, "</a>");
                    rest = after_tag[4..];
                }
            }
        }
    }

    return out.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Image processing
// ---------------------------------------------------------------------------

fn isRelativeUrl(url: []const u8) bool {
    if (std.mem.startsWith(u8, url, "/")) return false;
    if (std.mem.indexOf(u8, url, "://") != null) return false;
    return url.len > 0;
}

/// Copy an image from `conf_dir/rel_path` into `out_dir/assets/rel_path`,
/// creating intermediate directories as needed.
/// Records the source asset path in `cache` so future runs can detect changes.
fn copyImageFile(
    allocator: std.mem.Allocator,
    conf_dir: []const u8,
    rel_path: []const u8,
    out_dir: std.fs.Dir,
    cache: *cache_mod.Cache,
) !void {
    const dest_rel = try std.fs.path.join(allocator, &.{ "assets", rel_path });
    defer allocator.free(dest_rel);

    if (std.fs.path.dirname(dest_rel)) |parent| {
        try out_dir.makePath(parent);
    }

    const src_path = try std.fs.path.join(allocator, &.{ conf_dir, rel_path });
    defer allocator.free(src_path);

    try std.fs.cwd().copyFile(src_path, out_dir, dest_rel, .{});

    const abs_src = cache_mod.absPath(allocator, src_path) catch try allocator.dupe(u8, src_path);
    defer allocator.free(abs_src);
    cache.recordAsset(abs_src) catch {};
}

/// Scan rendered HTML for `<img src="...">` elements; copy any relative-path
/// images into `out_dir/assets/` and rewrite their src to `{prefix}/assets/…`.
fn processImages(
    allocator: std.mem.Allocator,
    html: []const u8,
    conf_dir: []const u8,
    out_dir: std.fs.Dir,
    prefix: []const u8,
    cache: *cache_mod.Cache,
) ![]const u8 {
    const marker = "src=\"";
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);

    var rest = html;
    while (true) {
        const pos = std.mem.indexOf(u8, rest, marker) orelse {
            try out.appendSlice(allocator, rest);
            break;
        };

        try out.appendSlice(allocator, rest[0..pos]);

        const after = rest[pos + marker.len ..];
        const close = std.mem.indexOfScalar(u8, after, '"') orelse {
            try out.appendSlice(allocator, marker);
            rest = after;
            continue;
        };

        const src = after[0..close];
        if (isRelativeUrl(src)) {
            copyImageFile(allocator, conf_dir, src, out_dir, cache) catch |err| {
                std.debug.print("Warning: could not copy image '{s}': {}\n", .{ src, err });
            };
            try out.writer(allocator).print("src=\"{s}/assets/{s}", .{ prefix, src });
        } else {
            try out.appendSlice(allocator, marker);
            try out.appendSlice(allocator, src);
        }

        // after[close..] starts with the closing `"` — preserved on next pass.
        rest = after[close..];
    }

    return out.toOwnedSlice(allocator);
}

fn renderGuidePage(
    allocator: std.mem.Allocator,
    out_dir: *std.fs.Dir,
    entry: GuideEntry,
    project_name: []const u8,
    mods: []const symbols.Module,
    guides: []const GuideNavItem,
    examples: []const ExampleEntry,
    emoji_provider: emoji.Provider,
    theme: Theme,
    conf_dir: ?[]const u8,
    home_slug: ?[]const u8,
    /// When true, output to `index.html` with prefix `.` instead of `guide/{slug}.html`.
    is_home: bool,
    cache: *cache_mod.Cache,
) !void {
    var buf = Buf.init(allocator, emoji_provider, theme);
    defer buf.deinit();
    buf.home_slug = home_slug;

    const title = try std.fmt.allocPrint(allocator, "{s} — {s}", .{ entry.title, project_name });
    defer allocator.free(title);

    const prefix: []const u8 = if (is_home)
        "."
    else if (std.mem.indexOfScalar(u8, entry.slug, '/') != null)
        "../.."
    else
        "..";

    try writeHeader(&buf, title, project_name, mods, guides, examples, null, entry.slug, null, prefix);

    const raw = try markdown.toHtml(allocator, entry.content);
    defer allocator.free(raw);
    const with_emoji = try emoji.replaceInHtml(allocator, raw, emoji_provider);
    defer allocator.free(with_emoji);
    const with_images = if (conf_dir) |cd|
        try processImages(allocator, with_emoji, cd, out_dir.*, prefix, cache)
    else
        try allocator.dupe(u8, with_emoji);
    defer allocator.free(with_images);
    const html = try resolveInternalLinks(allocator, with_images, mods, prefix);
    defer allocator.free(html);

    try buf.writeAll("<div class=\"guide-content\">\n");
    try buf.writeAll(html);
    try buf.writeAll("</div>\n");

    try writeGuideToc(&buf, entry.content);
    try writeFooter(&buf);

    const filename = if (is_home)
        try allocator.dupe(u8, "index.html")
    else
        try std.fmt.allocPrint(allocator, "guide/{s}.html", .{entry.slug});
    defer allocator.free(filename);

    // Ensure parent directory exists for nested slugs
    if (std.fs.path.dirname(filename)) |dir_path| {
        try out_dir.makePath(dir_path);
    }

    const file = try out_dir.createFile(filename, .{});
    defer file.close();
    try buf.flush(file);
}

// ---------------------------------------------------------------------------
// Literate example pages
// ---------------------------------------------------------------------------

fn renderExampleSegments(buf: *Buf, allocator: std.mem.Allocator, segments: []const example_mod.Segment, mods: []const symbols.Module, prefix: []const u8) !void {
    for (segments) |seg| {
        switch (seg.kind) {
            .prose => {
                const raw = try markdown.toHtml(allocator, seg.text);
                defer allocator.free(raw);
                const html = try resolveInternalLinks(allocator, raw, mods, prefix);
                defer allocator.free(html);
                if (seg.indent > 0) {
                    try buf.print("<div class=\"example-prose\" style=\"margin-left:{d}ch\">\n", .{seg.indent});
                } else {
                    try buf.writeAll("<div class=\"example-prose\">\n");
                }
                try buf.writeAll(html);
                try buf.writeAll("</div>\n");
            },
            .code => {
                const highlighted = markdown.highlight.highlightZig(allocator, seg.text) catch blk: {
                    // Fallback: HTML-escape raw source.
                    var esc: std.ArrayList(u8) = .{};
                    defer esc.deinit(allocator);
                    for (seg.text) |c| switch (c) {
                        '<' => try esc.appendSlice(allocator, "&lt;"),
                        '>' => try esc.appendSlice(allocator, "&gt;"),
                        '&' => try esc.appendSlice(allocator, "&amp;"),
                        else => try esc.append(allocator, c),
                    };
                    break :blk try esc.toOwnedSlice(allocator);
                };
                defer allocator.free(highlighted);
                try buf.writeAll("<pre class=\"example-code\"><code class=\"language-zig\">");
                try buf.writeAll(highlighted);
                try buf.writeAll("</code></pre>\n");
            },
            .collapsed => {
                const label = seg.label orelse "Show code";
                try buf.writeAll("<details class=\"example-collapsed\">\n<summary>");
                try htmlEscape(buf, label);
                try buf.writeAll("</summary>\n");
                try renderExampleSegments(buf, allocator, seg.children, mods, prefix);
                try buf.writeAll("</details>\n");
            },
        }
    }
}

fn renderExamplePage(
    allocator: std.mem.Allocator,
    out_dir: *std.fs.Dir,
    entry: ExampleEntry,
    project_name: []const u8,
    mods: []const symbols.Module,
    guides: []const GuideNavItem,
    examples: []const ExampleEntry,
    emoji_provider: emoji.Provider,
    theme: Theme,
    home_slug: ?[]const u8,
) !void {
    var buf = Buf.init(allocator, emoji_provider, theme);
    defer buf.deinit();
    buf.home_slug = home_slug;

    const title = try std.fmt.allocPrint(allocator, "{s} — {s}", .{ entry.title, project_name });
    defer allocator.free(title);

    // example/*.html → prefix is ".."
    const prefix = "..";

    try writeHeader(&buf, title, project_name, mods, guides, examples, null, null, entry.slug, prefix);

    try buf.writeAll("<div class=\"guide-content example-page\">\n");
    try buf.print("<h1>", .{});
    try htmlEscape(&buf, entry.title);
    try buf.writeAll("</h1>\n");

    const segments = try example_mod.parse(allocator, entry.src);
    defer {
        example_mod.freeSegments(allocator, segments);
        allocator.free(segments);
    }

    try renderExampleSegments(&buf, allocator, segments, mods, prefix);

    try buf.writeAll("</div>\n");
    try writeFooter(&buf);

    const filename = try std.fmt.allocPrint(allocator, "example/{s}.html", .{entry.slug});
    defer allocator.free(filename);

    const file = try out_dir.createFile(filename, .{});
    defer file.close();
    try buf.flush(file);
}
