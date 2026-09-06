//! Site-wide render orchestration: `renderSite` walks the extracted modules
//! and configured pages, writes static assets, and delegates per-page HTML
//! generation to `page_render.zig`. Also the public re-export surface for
//! the render subsystem (conf parsing, page types, theme, progress, and the
//! HTML post-processors), so callers keep using `render.X` regardless of
//! which file `X` actually lives in.

const std = @import("std");
const symbols = @import("./symbols.zig");
const emoji = @import("./emoji.zig");
pub const cache_mod = @import("./cache.zig");

const pages = @import("./pages.zig");
const conf_mod = @import("./conf.zig");
const theme_mod = @import("./theme.zig");
const progress_mod = @import("./progress.zig");
const site_context = @import("./site_context.zig");
const html_transform = @import("./html_transform.zig");
const search_index = @import("./search_index.zig");
const page_render = @import("./page_render.zig");

const CSS = @embedFile("assets/style.css");
const MINISEARCH_JS = @embedFile("assets/minisearch.min.js");
const SEARCH_JS = @embedFile("assets/search.js");

// ---------------------------------------------------------------------------
// Re-exports — the public surface of the render subsystem.
// ---------------------------------------------------------------------------

pub const Theme = theme_mod.Theme;
pub const Progress = progress_mod.Progress;

pub const PageMode = pages.PageMode;
pub const PageEntry = pages.PageEntry;
pub const PageSection = pages.PageSection;
pub const PageNavItem = pages.PageNavItem;
pub const freePages = pages.freePages;
pub const pagesHaveEntries = pages.pagesHaveEntries;

pub const SiteConf = conf_mod.SiteConf;
pub const loadSiteConf = conf_mod.loadSiteConf;
pub const stripJsonComments = conf_mod.stripJsonComments;
pub const parseJsonWithComments = conf_mod.parseJsonWithComments;
pub const trimLeft = conf_mod.trimLeft;

pub const resolveInternalLinks = html_transform.resolveInternalLinks;

const SiteContext = site_context.SiteContext;
const Buf = site_context.Buf;
const htmlEscape = site_context.htmlEscape;
const buildTypeIndex = site_context.buildTypeIndex;

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/// Public options for `renderSite`; converted internally into the
/// `SiteContext` threaded through every page renderer.
pub const RenderSiteOptions = struct {
    out_path: []const u8,
    project_name: []const u8,
    mods: []const symbols.Module,
    /// Unified page nav items (guides + examples) from `zkdocs.conf`. Not freed by this function.
    pages: []const PageNavItem,
    emoji_provider: emoji.Provider,
    theme: Theme,
    progress: *Progress,
    /// Directory of the conf file; used to resolve relative image paths in pages.
    /// Pass null when running without a conf file.
    conf_dir: ?[]const u8,
    /// Slug of the page to render as `index.html`. When set the default module
    /// listing is replaced by that page's content.
    home_slug: ?[]const u8,
    /// Mutable build cache used to skip unchanged outputs.  The caller owns
    /// the cache and must call `cache.save` (or discard) after this returns.
    cache: *cache_mod.Cache,
    /// Absolute path to the zkdocs.conf file, or null when running without one.
    /// Used to record the conf mtime in the cache.
    conf_abs_path: ?[]const u8,
    /// When true, pub @import constants are included in API docs.
    show_imports: bool,
    /// Repository URL from the `"repo"` config key, or null if absent.
    repo_url: ?[]const u8,
    /// Extra stylesheet paths (`"extra_css"` conf key), relative to `conf_dir`.
    extra_css: []const []const u8,
    /// Verbatim HTML injected near the top of `<body>` (`"header_html"` conf key).
    header_html: ?[]const u8,
    /// Verbatim HTML injected into the site footer (`"footer_html"` conf key).
    footer_html: ?[]const u8,
    /// Logo image path (`"logo"` conf key), relative to `conf_dir`.
    logo: ?[]const u8,
    /// Favicon image path (`"favicon"` conf key), relative to `conf_dir`.
    favicon: ?[]const u8,
    /// Fixed absolute base path the site is served under (`"base_url"` conf key
    /// or `--base-url` flag), or null to use per-page relative prefixes.
    base_url: ?[]const u8,
};

/// `Io.Group.async` entry point for `renderModulePage`: renders one module's
/// `api/<module-slug>.html` on a pool thread, recording failure via `failed`
/// instead of propagating the error (the group has no per-task error channel).
fn renderModuleJob(ctx: *const SiteContext, out_dir: *std.Io.Dir, mod: symbols.Module, failed: *std.atomic.Value(bool)) void {
    renderModulePage(ctx, out_dir, mod) catch |err| {
        std.debug.print("  error rendering module '{s}': {}\n", .{ mod.name, err });
        failed.store(true, .monotonic);
    };
}

/// Render a single module's `api/<module-slug>.html`. Reads only shared,
/// already-built state off `ctx` (type index, cache, mods list) so it is
/// safe to call concurrently for different modules.
fn renderModulePage(ctx: *const SiteContext, out_dir: *std.Io.Dir, mod: symbols.Module) !void {
    Progress.setCurrent(mod.name);
    var buf = Buf.init(ctx.allocator);
    defer buf.deinit();

    const title = try std.fmt.allocPrint(ctx.allocator, "{s} — {s}", .{ mod.name, ctx.project_name });
    defer ctx.allocator.free(title);

    try page_render.writeHeader(&buf, ctx, title, mod.slug, null, site_context.prefixFor(ctx, ".."));

    try buf.writeAll("<h1>");
    try htmlEscape(&buf, mod.name);
    try buf.writeAll("</h1>\n<div class=\"mod-path\">");
    try htmlEscape(&buf, mod.path);
    try buf.writeAll("</div>\n");
    if (mod.doc) |doc| try page_render.writeDoc(&buf, ctx, mod.slug, doc);

    var has_types = false;
    var has_errors = false;
    var has_fns = false;
    var has_consts = false;
    var has_comptime_blocks = false;
    for (mod.symbols.items) |sym| {
        switch (sym) {
            .container => |c| {
                if (c.is_pub) has_types = true;
            },
            .function => |f| {
                if (f.is_pub and f.generic_return != null) has_types = true;
                if (f.is_pub and f.generic_return == null) has_fns = true;
            },
            .variable => |v| {
                if (v.is_pub and (ctx.show_imports or !v.is_import)) has_consts = true;
            },
            .error_set => |e| {
                if (e.is_pub) has_errors = true;
            },
            .comptime_block => has_comptime_blocks = true,
            .@"test", .other => {},
        }
    }

    if (has_types or has_errors or has_fns or has_consts or has_comptime_blocks) {
        try buf.writeAll(
            \\<div class="collapse-toggle-row">
            \\<button type="button" id="collapse-all-btn">Collapse all</button>
            \\<button type="button" id="expand-all-btn">Expand all</button>
            \\</div>
            \\
        );
    }

    if (has_types) {
        try buf.writeAll("<h2 id=\"section-types\">Types</h2>\n");
        for (mod.symbols.items) |sym| {
            if (sym == .container and sym.container.is_pub)
                try page_render.renderContainer(&buf, ctx, mod.slug, sym.container);
        }
        for (mod.symbols.items) |sym| {
            if (sym != .function) continue;
            const f = sym.function;
            if (f.is_pub and f.generic_return != null) try page_render.renderFn(&buf, ctx, mod.slug, f, null);
        }
    }
    if (has_errors) {
        try buf.writeAll("<h2 id=\"section-errors\">Errors</h2>\n");
        for (mod.symbols.items) |sym| {
            if (sym == .error_set and sym.error_set.is_pub)
                try page_render.renderErrorSet(&buf, ctx, mod.slug, sym.error_set);
        }
    }
    if (has_fns) {
        try buf.writeAll("<h2 id=\"section-functions\">Functions</h2>\n");
        for (mod.symbols.items) |sym| {
            if (sym == .function) {
                const f = sym.function;
                if (f.is_pub and f.generic_return == null) try page_render.renderFn(&buf, ctx, mod.slug, f, null);
            }
        }
    }
    if (has_consts) {
        try buf.writeAll("<h2 id=\"section-constants\">Constants</h2>\n");
        for (mod.symbols.items) |sym| {
            if (sym == .variable) {
                const v = sym.variable;
                if (v.is_pub and (ctx.show_imports or !v.is_import)) try page_render.renderVar(&buf, ctx, mod.slug, v);
            }
        }
    }
    if (has_comptime_blocks) {
        try buf.writeAll("<h2 id=\"section-comptime\">Comptime Blocks</h2>\n");
        var cb_index: usize = 0;
        for (mod.symbols.items) |sym| {
            if (sym == .comptime_block) {
                try page_render.renderComptimeBlock(&buf, ctx, mod.slug, cb_index, sym.comptime_block);
                cb_index += 1;
            }
        }
    }

    try page_render.writeApiToc(&buf, ctx, mod);
    try page_render.writeFooter(&buf, ctx);

    const filename = try std.fmt.allocPrint(ctx.allocator, "api/{s}.html", .{mod.slug});
    defer ctx.allocator.free(filename);
    const file = try out_dir.createFile(ctx.io, filename, .{});
    defer file.close(ctx.io);
    try buf.flush(ctx.io, file);
}

/// `Io.Group.async` entry point for rendering one `page/<slug>.html` guide or
/// example page, mirroring `renderModuleJob`.
fn renderPageJob(ctx: *const SiteContext, out_dir: *std.Io.Dir, entry: PageEntry, failed: *std.atomic.Value(bool)) void {
    renderPageEntry(ctx, out_dir, entry) catch |err| {
        std.debug.print("  error rendering page '{s}': {}\n", .{ entry.slug, err });
        failed.store(true, .monotonic);
    };
}

fn renderPageEntry(ctx: *const SiteContext, out_dir: *std.Io.Dir, entry: PageEntry) !void {
    Progress.setCurrent(entry.slug);
    switch (entry.mode) {
        .markdown => try page_render.renderMarkdownPage(ctx, out_dir, entry, false),
        .zig_prose, .zig_raw => try page_render.renderZigPage(ctx, out_dir, entry, false),
    }
}

/// Generate the full HTML site under `opts.out_path`.
///
/// Output layout:
///   out_path/
///     index.html
///     api/<module>.html     (one per module, pub symbols only)
///     page/<slug>.html      (one per page entry in zkdocs.conf)
pub fn renderSite(io: std.Io, allocator: std.mem.Allocator, opts: RenderSiteOptions) !void {
    // Build type index once for cross-module type linking.
    var type_index = try buildTypeIndex(allocator, opts.mods);
    defer type_index.deinit();

    var out_dir = try std.Io.Dir.cwd().createDirPathOpen(io, opts.out_path, .{});
    defer out_dir.close(io);

    // ── Copy conf-provided assets (logo, favicon, extra_css) ─────────────────
    // These only make sense relative to a conf file; silently skipped otherwise.
    var extra_css_rel: std.ArrayList([]const u8) = .empty;
    defer {
        for (extra_css_rel.items) |c| allocator.free(c);
        extra_css_rel.deinit(allocator);
    }
    var logo_rel: ?[]const u8 = null;
    defer if (logo_rel) |l| allocator.free(l);
    var favicon_rel: ?[]const u8 = null;
    defer if (favicon_rel) |f| allocator.free(f);

    if (opts.conf_dir) |cd| {
        try out_dir.createDirPath(io, "assets");
        for (opts.extra_css) |rel_path| {
            html_transform.copyAssetFile(io, allocator, cd, rel_path, out_dir, opts.cache) catch |err| {
                std.debug.print("  warning: could not copy extra_css '{s}': {}\n", .{ rel_path, err });
                continue;
            };
            const dest = try std.fs.path.join(allocator, &.{ "assets", rel_path });
            try extra_css_rel.append(allocator, dest);
        }
        if (opts.logo) |rel_path| blk: {
            html_transform.copyAssetFile(io, allocator, cd, rel_path, out_dir, opts.cache) catch |err| {
                std.debug.print("  warning: could not copy logo '{s}': {}\n", .{ rel_path, err });
                break :blk;
            };
            logo_rel = try std.fs.path.join(allocator, &.{ "assets", rel_path });
        }
        if (opts.favicon) |rel_path| blk: {
            html_transform.copyAssetFile(io, allocator, cd, rel_path, out_dir, opts.cache) catch |err| {
                std.debug.print("  warning: could not copy favicon '{s}': {}\n", .{ rel_path, err });
                break :blk;
            };
            favicon_rel = try std.fs.path.join(allocator, &.{ "assets", rel_path });
        }
    }

    var ctx = SiteContext{
        .io = io,
        .allocator = allocator,
        .project_name = opts.project_name,
        .mods = opts.mods,
        .pages = opts.pages,
        .emoji_provider = opts.emoji_provider,
        .theme = opts.theme,
        .conf_dir = opts.conf_dir,
        .home_slug = opts.home_slug,
        .show_imports = opts.show_imports,
        .repo_url = opts.repo_url,
        .cache = opts.cache,
        .type_index = type_index,
        .progress = opts.progress,
        .extra_css = extra_css_rel.items,
        .header_html = opts.header_html,
        .footer_html = opts.footer_html,
        .logo_rel = logo_rel,
        .favicon_rel = favicon_rel,
        .base_url = opts.base_url,
    };

    // ── Determine what changed since the last run ────────────────────────────
    const conf_changed = if (opts.conf_abs_path) |cp|
        !ctx.cache.confUnchanged(cp)
    else
        false;

    // Check whether any asset file (e.g. logo image) changed since the last run.
    const assets_changed = !ctx.cache.allAssetsUnchanged();

    // Check whether any source file has changed since the last run.
    var sources_changed = conf_changed or assets_changed;
    for (ctx.mods) |mod| {
        if (!ctx.cache.sourceUnchanged(mod.abs_path)) sources_changed = true;
    }

    try out_dir.createDirPath(io, "api");

    // Write the stylesheet and JS assets.
    try out_dir.createDirPath(io, "assets");
    {
        const css_file = try out_dir.createFile(io, "assets/style.css", .{});
        defer css_file.close(io);
        try css_file.writeStreamingAll(io, CSS);
    }
    {
        const f = try out_dir.createFile(io, "assets/minisearch.min.js", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, MINISEARCH_JS);
    }
    {
        const f = try out_dir.createFile(io, "assets/search.js", .{});
        defer f.close(io);
        try f.writeStreamingAll(io, SEARCH_JS);
    }
    try search_index.writeSearchIndex(&ctx, &out_dir);

    if (pagesHaveEntries(ctx.pages)) try out_dir.createDirPath(io, "page");

    // ── index.html ──────────────────────────────────────────────────────────

    // Find the home page entry if one is designated.
    const home_entry: ?PageEntry = blk: {
        const hs = ctx.home_slug orelse break :blk null;
        const HomeFinder = struct { slug: []const u8, found: ?PageEntry = null };
        var finder = HomeFinder{ .slug = hs };
        pages.visitPageEntries(ctx.pages, &finder, struct {
            fn visit(f: *HomeFinder, e: PageEntry) !void {
                if (f.found == null and std.mem.eql(u8, e.slug, f.slug)) f.found = e;
            }
        }.visit) catch {};
        break :blk finder.found;
    };

    const home_changed = if (home_entry) |he|
        he.src_path.len > 0 and !ctx.cache.guideUnchanged(he.src_path)
    else
        false;

    if (!conf_changed and !sources_changed and !home_changed) {
        ctx.progress.begin("index up to date");
    } else {
        ctx.progress.begin("writing index");
    }

    if (conf_changed or sources_changed or home_changed) {
        if (home_entry) |he| {
            // Render the designated page as index.html.
            switch (he.mode) {
                .markdown => try page_render.renderMarkdownPage(&ctx, &out_dir, he, true),
                .zig_prose, .zig_raw => try page_render.renderZigPage(&ctx, &out_dir, he, true),
            }
        } else {
            var buf = Buf.init(allocator);
            defer buf.deinit();

            try page_render.writeHeader(&buf, &ctx, ctx.project_name, null, null, site_context.prefixFor(&ctx, "."));

            try buf.writeAll("<h1>");
            try htmlEscape(&buf, ctx.project_name);
            try buf.writeAll("</h1>\n");

            if (ctx.mods.len > 0) {
                try buf.writeAll("<h2>Modules</h2>\n<ul class=\"module-list\">\n");
                for (ctx.mods) |mod| {
                    try buf.print("<li><a href=\"./api/{s}.html\">", .{mod.slug});
                    try htmlEscape(&buf, mod.name);
                    try buf.writeAll("</a>");

                    // Prefer the file-level //! doc; fall back to first symbol doc, then path.
                    const blurb: ?[]const u8 = mod.doc orelse blk2: {
                        for (mod.symbols.items) |sym| {
                            const d: ?[]const u8 = switch (sym) {
                                .function => |f| f.doc,
                                .variable => |v| v.doc,
                                .container => |c| c.doc,
                                .error_set => |e| e.doc,
                                .comptime_block, .@"test", .other => null,
                            };
                            if (d != null) break :blk2 d;
                        }
                        break :blk2 null;
                    };
                    try buf.writeAll("<div class=\"mod-doc\">");
                    if (blurb) |b|
                        try htmlEscape(&buf, page_render.firstSentence(b))
                    else
                        try htmlEscape(&buf, mod.path);
                    try buf.writeAll("</div>");
                    try buf.writeAll("</li>\n");
                }
                try buf.writeAll("</ul>\n");
            }

            if (pagesHaveEntries(ctx.pages)) {
                try buf.writeAll("<h2>Pages</h2>\n<ul class=\"module-list\">\n");
                try page_render.writeIndexPageList(&buf, &ctx, ctx.pages);
                try buf.writeAll("</ul>\n");
            }

            try page_render.writeFooter(&buf, &ctx);

            const file = try out_dir.createFile(io, "index.html", .{});
            defer file.close(io);
            try buf.flush(io, file);
        } // end else (no home page)
    } // end if (conf_changed or sources_changed)

    // ── api/<module>.html ────────────────────────────────────────────────────
    {
        // Count only the modules that actually need re-rendering.
        var n_to_render: usize = 0;
        for (ctx.mods) |mod| {
            if (conf_changed or assets_changed or !ctx.cache.sourceUnchanged(mod.abs_path))
                n_to_render += 1;
        }
        var label_buf: [64]u8 = undefined;
        const label = if (n_to_render == 0)
            "api pages up to date"
        else
            std.fmt.bufPrint(&label_buf, "rendering api ({d}/{d} module{s})", .{
                n_to_render, ctx.mods.len, if (ctx.mods.len == 1) "" else "s",
            }) catch "rendering api";
        ctx.progress.begin(label);
    }
    {
        // Each module page is independent once symbols are extracted, so fan
        // them out across the Io thread pool instead of rendering sequentially.
        var failed = std.atomic.Value(bool).init(false);
        var group: std.Io.Group = .init;
        for (ctx.mods) |mod| {
            // Skip this module if its source and the conf/assets are all unchanged.
            if (!conf_changed and !assets_changed and ctx.cache.sourceUnchanged(mod.abs_path))
                continue;
            group.async(io, renderModuleJob, .{ &ctx, &out_dir, mod, &failed });
        }
        try group.await(io);
        if (failed.load(.monotonic)) return error.RenderFailed;
        if (ctx.mods.len > 0) Progress.endFiles();
    }

    // ── page/ pages ──────────────────────────────────────────────────────────
    if (pagesHaveEntries(ctx.pages)) {
        const Counter = struct { n: usize = 0 };
        var counter = Counter{};
        try pages.visitPageEntries(ctx.pages, &counter, struct {
            fn visit(c: *Counter, e: PageEntry) !void {
                _ = e;
                c.n += 1;
            }
        }.visit);

        var label_buf: [64]u8 = undefined;
        const label = std.fmt.bufPrint(&label_buf, "rendering pages ({d} page{s})", .{
            counter.n, if (counter.n == 1) "" else "s",
        }) catch "rendering pages";
        ctx.progress.begin(label);

        // Pages are independent of each other too, so fan them out the same
        // way as api/<module>.html pages above.
        var page_failed = std.atomic.Value(bool).init(false);
        var page_group: std.Io.Group = .init;
        const RenderPageCtx = struct {
            ctx: *const SiteContext,
            out_dir: *std.Io.Dir,
            io: std.Io,
            group: *std.Io.Group,
            failed: *std.atomic.Value(bool),
            conf_changed: bool,
            assets_changed: bool,
        };
        try pages.visitPageEntries(ctx.pages, RenderPageCtx{
            .ctx = &ctx,
            .out_dir = &out_dir,
            .io = io,
            .group = &page_group,
            .failed = &page_failed,
            .conf_changed = conf_changed,
            .assets_changed = assets_changed,
        }, struct {
            fn visit(rctx: RenderPageCtx, e: PageEntry) !void {
                if (rctx.ctx.home_slug) |hs| if (std.mem.eql(u8, hs, e.slug)) return;
                // Skip if the page source, conf, and assets are all unchanged.
                if (!rctx.conf_changed and !rctx.assets_changed and e.src_path.len > 0 and rctx.ctx.cache.guideUnchanged(e.src_path))
                    return;
                rctx.group.async(rctx.io, renderPageJob, .{ rctx.ctx, rctx.out_dir, e, rctx.failed });
            }
        }.visit);
        try page_group.await(io);
        if (page_failed.load(.monotonic)) return error.RenderFailed;
        Progress.endFiles();
    }

    // ── Update and save build cache ──────────────────────────────────────────
    if (opts.conf_abs_path) |cp| ctx.cache.recordConf(cp) catch {};
    for (ctx.mods) |mod| ctx.cache.recordSource(mod.abs_path) catch {};
    try pages.visitPageEntries(ctx.pages, ctx.cache, struct {
        fn visit(c: *cache_mod.Cache, e: PageEntry) !void {
            if (e.src_path.len > 0) c.recordGuide(e.src_path) catch {};
        }
    }.visit);
    ctx.cache.save(opts.out_path) catch |err| {
        std.debug.print("  warning: could not write build cache: {}\n", .{err});
    };
}
