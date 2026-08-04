//! Page-level HTML renderers: the shared header/nav/footer chrome, per-page
//! "on this page" TOCs, individual symbol renderers (fn/container/var), and
//! the top-level markdown/zig page renderers. Site-wide orchestration
//! (`renderSite` itself) lives in `render.zig`; this module only knows how
//! to render one page at a time given a `SiteContext`.

const std = @import("std");
const build_options = @import("build_options");
const symbols = @import("./symbols.zig");
const markdown = @import("./markdown.zig");
const emoji = @import("./emoji.zig");
const example_mod = @import("./example.zig");
const pages = @import("./pages.zig");
const site_context = @import("./site_context.zig");
const html_transform = @import("./html_transform.zig");

const SiteContext = site_context.SiteContext;
const Buf = site_context.Buf;
const htmlEscape = site_context.htmlEscape;
const PageEntry = pages.PageEntry;
const PageNavItem = pages.PageNavItem;
const pagesHaveEntries = pages.pagesHaveEntries;

const ZKDOCS_VERSION = build_options.version;
const ZKDOCS_REPO_URL = "https://github.com/srjilarious/zkdocs";

pub fn firstSentence(text: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, text, '.')) |pos| return text[0 .. pos + 1];
    return text;
}

/// Emit `type_src` with known type names wrapped in `<a>` links.
/// `skip_name`: the current container's name; its occurrences are not linked
/// (avoids a self-referential link when rendering a type's own methods).
/// `current_module`: the module the containing page belongs to, so a
/// same-module reference gets a fragment-only href.
fn writeTypeSrc(buf: *Buf, ctx: *const SiteContext, current_module: []const u8, type_src: []const u8, skip_name: ?[]const u8) !void {
    const idx = &ctx.type_index;
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
                    if (std.mem.eql(u8, ref.module_name, current_module)) {
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

pub fn writeDoc(buf: *Buf, ctx: *const SiteContext, current_module: []const u8, doc: []const u8) !void {
    const raw = try markdown.toHtml(buf.alloc, doc);
    defer buf.alloc.free(raw);
    const with_emoji = try emoji.replaceInHtml(buf.alloc, raw, ctx.emoji_provider);
    defer buf.alloc.free(with_emoji);
    const html = try html_transform.linkCodeSymbols(buf.alloc, with_emoji, &ctx.type_index, current_module);
    defer buf.alloc.free(html);
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
    ctx: *const SiteContext,
    mod: symbols.Module,
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
    for (ctx.mods) |child| {
        if (child.parent_name) |pn| {
            if (std.mem.eql(u8, pn, mod.name)) {
                has_children = true;
                break;
            }
        }
    }
    if (has_children) {
        try buf.writeAll("\n<ul class=\"nav-children\">\n");
        for (ctx.mods) |child| {
            if (child.parent_name) |pn| {
                if (std.mem.eql(u8, pn, mod.name))
                    try writeModuleNavItem(buf, ctx, child, active_module, prefix);
            }
        }
        try buf.writeAll("</ul>\n");
    }
    try buf.writeAll("</li>\n");
}

// ---------------------------------------------------------------------------
// Page header / nav / footer
// ---------------------------------------------------------------------------

fn writePageNavItems(
    buf: *Buf,
    ctx: *const SiteContext,
    items: []const PageNavItem,
    active_page: ?[]const u8,
    prefix: []const u8,
) !void {
    for (items) |item| {
        switch (item) {
            .entry => |e| {
                const active = if (active_page) |ap| std.mem.eql(u8, ap, e.slug) else false;
                const cls: []const u8 = if (active) " class=\"active\"" else "";
                const is_home = if (ctx.home_slug) |hs| std.mem.eql(u8, hs, e.slug) else false;
                if (is_home) {
                    try buf.print("<li><a href=\"{s}/index.html\"{s}>", .{ prefix, cls });
                } else {
                    try buf.print("<li><a href=\"{s}/page/{s}.html\"{s}>", .{ prefix, e.slug, cls });
                }
                try htmlEscape(buf, e.title);
                try buf.writeAll("</a></li>\n");
            },
            .section => |s| {
                try buf.writeAll("<details class=\"nav-subsection\" open>\n<summary>");
                try htmlEscape(buf, s.title);
                try buf.writeAll("</summary>\n<ul>\n");
                try writePageNavItems(buf, ctx, s.items, active_page, prefix);
                try buf.writeAll("</ul>\n</details>\n");
            },
        }
    }
}

/// Write the page <head>, <body>, the left nav sidebar, and open <main>.
/// The per-page TOC aside is written after the main content via writeApiToc / writeGuideToc.
pub fn writeHeader(
    buf: *Buf,
    ctx: *const SiteContext,
    title: []const u8,
    active_module: ?[]const u8,
    active_page: ?[]const u8,
    prefix: []const u8,
) !void {
    try buf.writeAll("<!DOCTYPE html>\n<html lang=\"en\"");
    if (ctx.theme.toAttr()) |attr| try buf.print(" data-theme=\"{s}\"", .{attr});
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
    try htmlEscape(buf, ctx.project_name);
    try buf.writeAll(
        \\</a>
        \\<button class="mob-btn" id="toc-toggle" aria-label="On this page"><svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2"><line x1="8" y1="6" x2="21" y2="6"/><line x1="8" y1="12" x2="21" y2="12"/><line x1="8" y1="18" x2="21" y2="18"/><circle cx="3" cy="6" r="1.5" fill="currentColor"/><circle cx="3" cy="12" r="1.5" fill="currentColor"/><circle cx="3" cy="18" r="1.5" fill="currentColor"/></svg></button>
        \\</div>
        \\<div class="overlay" id="overlay"></div>
        \\<nav class="sidebar">
        \\
    );
    try buf.writeAll("<div class=\"logo-row\">");
    try buf.print("<a class=\"logo\" href=\"{s}/index.html\">", .{prefix});
    try htmlEscape(buf, ctx.project_name);
    try buf.writeAll("</a>");
    if (ctx.repo_url) |rurl| {
        try buf.writeAll("<a class=\"repo-link\" href=\"");
        try htmlEscape(buf, rurl);
        try buf.writeAll("\" target=\"_blank\" rel=\"noopener noreferrer\" title=\"Source repository\"><svg width=\"16\" height=\"16\" viewBox=\"0 0 24 24\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"2\" stroke-linecap=\"round\" stroke-linejoin=\"round\"><line x1=\"6\" y1=\"3\" x2=\"6\" y2=\"15\"/><circle cx=\"18\" cy=\"6\" r=\"3\"/><circle cx=\"6\" cy=\"18\" r=\"3\"/><path d=\"M18 9a9 9 0 0 1-9 9\"/></svg></a>");
    }
    try buf.writeAll("</div>\n");
    // Search bar
    try buf.writeAll(
        \\<div class="search-box">
        \\<input type="search" id="search-input" placeholder="Search docs&#x2026;" autocomplete="off" spellcheck="false">
        \\<div class="search-results" id="search-results"></div>
        \\</div>
        \\
    );

    if (pagesHaveEntries(ctx.pages)) {
        try buf.writeAll("<details class=\"nav-section\" open>\n<summary>Pages</summary>\n<ul>\n");
        try writePageNavItems(buf, ctx, ctx.pages, active_page, prefix);
        try buf.writeAll("</ul>\n</details>\n");
    }

    if (ctx.mods.len > 0) {
        try buf.writeAll("<details class=\"nav-section\" open>\n<summary>Modules</summary>\n<ul>\n");
        for (ctx.mods) |mod| {
            // Only render top-level (root) modules here; children are nested inside their parent.
            if (mod.parent_name == null)
                try writeModuleNavItem(buf, ctx, mod, active_module, prefix);
        }
        try buf.writeAll("</ul>\n</details>\n");
    }

    try buf.writeAll("</nav>\n<div class=\"page-body\">\n<main>\n");
}

pub fn writeFooter(buf: *Buf, ctx: *const SiteContext) !void {
    try buf.writeAll("\n</main>\n<footer class=\"site-footer\">\n<span class=\"footer-project\">");
    if (ctx.repo_url) |rurl| {
        try buf.writeAll("<a href=\"");
        try htmlEscape(buf, rurl);
        try buf.writeAll("\" target=\"_blank\" rel=\"noopener noreferrer\">");
        try htmlEscape(buf, ctx.project_name);
        try buf.writeAll("</a>");
    } else {
        try htmlEscape(buf, ctx.project_name);
    }
    try buf.writeAll("</span>\n<span class=\"footer-generated\">Generated with <a href=\"" ++ ZKDOCS_REPO_URL ++ "\" target=\"_blank\" rel=\"noopener noreferrer\">zkdocs</a> " ++ ZKDOCS_VERSION ++ "</span>\n</footer>\n</div>\n</body>\n</html>\n");
}

// ---------------------------------------------------------------------------
// Per-page TOC writers
// ---------------------------------------------------------------------------

/// Emit a collapsible "On this page" TOC for an API module page.
/// Shows Types → container names (with indented methods), Functions, Constants.
pub fn writeApiToc(buf: *Buf, ctx: *const SiteContext, mod: symbols.Module) !void {
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
                if (v.is_pub and (ctx.show_imports or !v.is_import)) has_consts = true;
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
            if (!ctx.show_imports and v.is_import) continue;
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
pub fn writeGuideToc(buf: *Buf, raw_content: []const u8) !void {
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

pub fn renderFn(buf: *Buf, ctx: *const SiteContext, current_module: []const u8, f: symbols.Function, parent_container: ?[]const u8) !void {
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
        try writeTypeSrc(buf, ctx, current_module, p.type_src, parent_container);
        try buf.writeAll("</span>");
    }
    try buf.writeAll(")");
    if (f.return_type_src) |r| {
        try buf.writeAll(" <span class=\"type-name\">");
        try writeTypeSrc(buf, ctx, current_module, r, parent_container);
        try buf.writeAll("</span>");
    }
    try buf.writeAll("</code></div>\n");
    if (f.generic_return != null) {
        try buf.writeAll("<span class=\"pill-generic\">generic</span></div>\n");
    }
    if (f.doc) |doc| try writeDoc(buf, ctx, current_module, doc);

    if (f.body_src) |body| {
        const highlighted = markdown.highlight.highlightZig(buf.alloc, body) catch blk: {
            var esc: std.ArrayList(u8) = .empty;
            defer esc.deinit(buf.alloc);
            for (body) |c| switch (c) {
                '<' => try esc.appendSlice(buf.alloc, "&lt;"),
                '>' => try esc.appendSlice(buf.alloc, "&gt;"),
                '&' => try esc.appendSlice(buf.alloc, "&amp;"),
                else => try esc.append(buf.alloc, c),
            };
            break :blk try esc.toOwnedSlice(buf.alloc);
        };
        defer buf.alloc.free(highlighted);
        try buf.writeAll("<details class=\"fn-body\"><summary>source</summary><pre><code class=\"language-zig\">");
        try buf.writeAll(highlighted);
        try buf.writeAll("</code></pre></details>\n");
    }

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
                if (field.type_src) |t| try writeTypeSrc(buf, ctx, current_module, t, f.name);
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
                    if (mf.is_pub) try renderFn(buf, ctx, current_module, mf, f.name);
                };
            }
            try buf.writeAll("</div>\n");
        }
    }

    try buf.writeAll("</div>\n");
}

pub fn renderContainer(buf: *Buf, ctx: *const SiteContext, current_module: []const u8, c: symbols.Container) !void {
    try buf.print("<div class=\"symbol\" id=\"sym-{s}\">\n", .{c.name});
    try buf.writeAll("<div class=\"symbol-sig\"><code>");
    if (c.is_pub) try buf.writeAll("<span class=\"kw\">pub </span>");
    try buf.print(
        "<span class=\"kw\">{s}</span> <span class=\"fn-name\">{s}</span>",
        .{ @tagName(c.kind), c.name },
    );
    try buf.writeAll("</code></div>\n");
    if (c.doc) |doc| try writeDoc(buf, ctx, current_module, doc);

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
            if (f.type_src) |t| try writeTypeSrc(buf, ctx, current_module, t, c.name);
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
                if (f.is_pub) try renderFn(buf, ctx, current_module, f, c.name);
            };
        }
        try buf.writeAll("</div>\n");
    }

    try buf.writeAll("</div>\n");
}

pub fn renderVar(buf: *Buf, ctx: *const SiteContext, current_module: []const u8, v: symbols.Variable) !void {
    try buf.print("<div class=\"symbol\" id=\"sym-{s}\">\n", .{v.name});
    try buf.writeAll("<div class=\"symbol-sig\"><code>");
    if (v.is_pub) try buf.writeAll("<span class=\"kw\">pub </span>");
    try buf.writeAll("<span class=\"kw\">const </span>");
    try buf.print("<span class=\"fn-name\">{s}</span>", .{v.name});
    if (v.type_src) |t| {
        try buf.writeAll(": <span class=\"type-name\">");
        try writeTypeSrc(buf, ctx, current_module, t, null);
        try buf.writeAll("</span>");
    }
    if (v.value_src) |val| {
        const is_multiline = std.mem.indexOfScalar(u8, val, '\n') != null;
        if (!is_multiline) {
            try buf.writeAll(" <span class=\"sym-eq\">=</span> <span class=\"sym-value\">");
            try htmlEscape(buf, val);
            try buf.writeAll("</span>");
        }
    }
    try buf.writeAll("</code></div>\n");
    if (v.value_src) |val| {
        if (std.mem.indexOfScalar(u8, val, '\n') != null) {
            try buf.writeAll("<details class=\"sym-value-details\"><summary>value</summary><pre><code>");
            try htmlEscape(buf, val);
            try buf.writeAll("</code></pre></details>\n");
        }
    }
    if (v.doc) |doc| try writeDoc(buf, ctx, current_module, doc);
    try buf.writeAll("</div>\n");
}

// ---------------------------------------------------------------------------
// Index-page "Pages" listing
// ---------------------------------------------------------------------------

/// Recursively render the "Pages" list on the index page, preserving
/// nested `<ul>`s for each level of section nesting.
pub fn writeIndexPageList(buf: *Buf, ctx: *const SiteContext, items: []const PageNavItem) !void {
    for (items) |item| {
        switch (item) {
            .entry => |e| {
                const is_home = if (ctx.home_slug) |hs| std.mem.eql(u8, hs, e.slug) else false;
                if (is_home) {
                    try buf.writeAll("<li><a href=\"./index.html\">");
                } else {
                    try buf.print("<li><a href=\"./page/{s}.html\">", .{e.slug});
                }
                try htmlEscape(buf, e.title);
                try buf.writeAll("</a></li>\n");
            },
            .section => |s| {
                try buf.writeAll("<li><strong>");
                try htmlEscape(buf, s.title);
                try buf.writeAll("</strong>\n<ul class=\"module-list\">\n");
                try writeIndexPageList(buf, ctx, s.items);
                try buf.writeAll("</ul></li>\n");
            },
        }
    }
}

// ---------------------------------------------------------------------------
// Markdown page renderer
// ---------------------------------------------------------------------------

pub fn renderMarkdownPage(
    ctx: *const SiteContext,
    out_dir: *std.Io.Dir,
    entry: PageEntry,
    /// When true, output to `index.html` with prefix `.` instead of `page/{slug}.html`.
    is_home: bool,
) !void {
    const io = ctx.io;
    const allocator = ctx.allocator;

    var buf = Buf.init(allocator);
    defer buf.deinit();

    const title = try std.fmt.allocPrint(allocator, "{s} — {s}", .{ entry.title, ctx.project_name });
    defer allocator.free(title);

    const prefix: []const u8 = if (is_home)
        "."
    else if (std.mem.indexOfScalar(u8, entry.slug, '/') != null)
        "../.."
    else
        "..";

    try writeHeader(&buf, ctx, title, null, entry.slug, prefix);

    const raw = try markdown.toHtml(allocator, entry.content);
    defer allocator.free(raw);
    const with_emoji = try emoji.replaceInHtml(allocator, raw, ctx.emoji_provider);
    defer allocator.free(with_emoji);
    const with_images = if (ctx.conf_dir) |cd|
        try html_transform.processImages(io, allocator, with_emoji, cd, out_dir.*, prefix, ctx.cache)
    else
        try allocator.dupe(u8, with_emoji);
    defer allocator.free(with_images);
    const html = try html_transform.resolveInternalLinks(allocator, with_images, ctx.mods, prefix);
    defer allocator.free(html);

    try buf.writeAll("<div class=\"guide-content\">\n");
    try buf.writeAll(html);
    try buf.writeAll("</div>\n");

    try writeGuideToc(&buf, entry.content);
    try writeFooter(&buf, ctx);

    const filename = if (is_home)
        try allocator.dupe(u8, "index.html")
    else
        try std.fmt.allocPrint(allocator, "page/{s}.html", .{entry.slug});
    defer allocator.free(filename);

    // Ensure parent directory exists for nested slugs
    if (std.fs.path.dirname(filename)) |dir_path| {
        try out_dir.createDirPath(io, dir_path);
    }

    const file = try out_dir.createFile(io, filename, .{});
    defer file.close(io);
    try buf.flush(io, file);
}

// ---------------------------------------------------------------------------
// Literate example pages
// ---------------------------------------------------------------------------

fn renderExampleSegments(buf: *Buf, ctx: *const SiteContext, segments: []const example_mod.Segment, prefix: []const u8) !void {
    const allocator = ctx.allocator;
    for (segments) |seg| {
        switch (seg.kind) {
            .prose => {
                const raw = try markdown.toHtml(allocator, seg.text);
                defer allocator.free(raw);
                const html = try html_transform.resolveInternalLinks(allocator, raw, ctx.mods, prefix);
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
                    var esc: std.ArrayList(u8) = .empty;
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
                try renderExampleSegments(buf, ctx, seg.children, prefix);
                try buf.writeAll("</details>\n");
            },
        }
    }
}

pub fn renderZigPage(
    ctx: *const SiteContext,
    out_dir: *std.Io.Dir,
    entry: PageEntry,
    /// When true, output to `index.html` with prefix `.` instead of `page/{slug}.html`.
    is_home: bool,
) !void {
    const io = ctx.io;
    const allocator = ctx.allocator;

    var buf = Buf.init(allocator);
    defer buf.deinit();

    const title = try std.fmt.allocPrint(allocator, "{s} — {s}", .{ entry.title, ctx.project_name });
    defer allocator.free(title);

    const prefix: []const u8 = if (is_home)
        "."
    else if (std.mem.indexOfScalar(u8, entry.slug, '/') != null)
        "../.."
    else
        "..";

    try writeHeader(&buf, ctx, title, null, entry.slug, prefix);
    // Zig pages have no right-sidebar TOC; reclaim that margin.
    try buf.writeAll("<style>.page-body{margin-right:0}</style>\n");

    const show_prose = entry.mode == .zig_prose;

    try buf.writeAll("<div class=\"guide-content example-page\">\n");
    try buf.writeAll("<div class=\"example-page-header\">\n<h1>");
    try htmlEscape(&buf, entry.title);
    try buf.writeAll("</h1>\n");
    if (show_prose) {
        try buf.writeAll("<button id=\"raw-toggle\">Raw view</button>\n");
    }
    try buf.writeAll("</div>\n");

    if (show_prose) {
        // Prose + code segments view (visible by default).
        try buf.writeAll("<div class=\"example-page-content\">\n");
        const segments = try example_mod.parse(allocator, entry.content);
        defer {
            example_mod.freeSegments(allocator, segments);
            allocator.free(segments);
        }
        try renderExampleSegments(&buf, ctx, segments, prefix);
        try buf.writeAll("</div>\n");
    }

    // Raw view: full source in a single syntax-highlighted block.
    // Hidden initially when prose mode is active; shown directly in raw mode.
    const raw_hl = markdown.highlight.highlightZig(allocator, entry.content) catch blk: {
        var esc: std.ArrayList(u8) = .empty;
        defer esc.deinit(allocator);
        for (entry.content) |c| switch (c) {
            '<' => try esc.appendSlice(allocator, "&lt;"),
            '>' => try esc.appendSlice(allocator, "&gt;"),
            '&' => try esc.appendSlice(allocator, "&amp;"),
            else => try esc.append(allocator, c),
        };
        break :blk try esc.toOwnedSlice(allocator);
    };
    defer allocator.free(raw_hl);
    if (show_prose) {
        try buf.writeAll("<pre class=\"example-raw-view example-hidden\"><code class=\"language-zig\">");
    } else {
        try buf.writeAll("<pre class=\"example-raw-view\"><code class=\"language-zig\">");
    }
    try buf.writeAll(raw_hl);
    try buf.writeAll("</code></pre>\n");

    try buf.writeAll("</div>\n");

    if (show_prose) {
        try buf.writeAll(
            \\<script>(function(){
            \\var btn=document.getElementById('raw-toggle');
            \\var raw=document.querySelector('.example-raw-view');
            \\var content=document.querySelector('.example-page-content');
            \\btn.addEventListener('click',function(){
            \\var toRaw=raw.classList.contains('example-hidden');
            \\raw.classList.toggle('example-hidden',!toRaw);
            \\content.classList.toggle('example-hidden',toRaw);
            \\btn.textContent=toRaw?'Prose view':'Raw view';
            \\});})();</script>
            \\
        );
    }
    try writeFooter(&buf, ctx);

    const filename = if (is_home)
        try allocator.dupe(u8, "index.html")
    else
        try std.fmt.allocPrint(allocator, "page/{s}.html", .{entry.slug});
    defer allocator.free(filename);

    if (std.fs.path.dirname(filename)) |dir_path| {
        try out_dir.createDirPath(io, dir_path);
    }

    const file = try out_dir.createFile(io, filename, .{});
    defer file.close(io);
    try buf.flush(io, file);
}
