//* These tests exercise `render.renderSite` end to end against a synthetic,
//* two-levels-deep nested page tree (section containing a section containing
//* a page entry). They guard against the class of bug fixed in the page
//* rendering, search index, and home-entry lookup walks: a one-level-only
//* walk over `PageNavItem` silently drops anything nested further down.
const std = @import("std");
const testz = @import("testz");
const zkdocs = @import("zkdocs");
const symbols = zkdocs.symbols;
const render = zkdocs.render;
const fix = @import("fixtures.zig");

/// Builds a `Section -> Section -> entry` tree. The leaf entry's
/// `src_path` points at a real repo file (`sample.zig`) so cache
/// recording has something real to stat.
fn buildNestedPages(deep_items: *[1]render.PageNavItem, inner_items: *[1]render.PageNavItem) [1]render.PageNavItem {
    deep_items[0] = .{ .entry = .{
        .slug = "deep",
        .title = "Deep Page",
        .content = "# Deep\n\nHello from deep.",
        .src_path = "sample.zig",
        .mode = .markdown,
    } };
    inner_items[0] = .{ .section = .{ .title = "Inner", .items = deep_items } };
    return .{.{ .section = .{ .title = "Outer", .items = inner_items } }};
}

pub fn nestedPageIsRenderedToDisk() !void {
    const gpa = std.heap.page_allocator;

    var deep_items: [1]render.PageNavItem = undefined;
    var inner_items: [1]render.PageNavItem = undefined;
    var pages = buildNestedPages(&deep_items, &inner_items);

    var progress = render.Progress.init(10);
    var cache = render.cache_mod.Cache.init(fix.g_Io, gpa);
    defer cache.deinit();

    const out_dir = "test_tmp_render_nested_disk";
    defer std.Io.Dir.cwd().deleteTree(fix.g_Io, out_dir) catch {};

    try render.renderSite(fix.g_Io, gpa, .{
        .out_path = out_dir,
        .project_name = "Test",
        .mods = &.{},
        .pages = &pages,
        .emoji_provider = .unicode,
        .theme = .default,
        .progress = &progress,
        .conf_dir = null,
        .home_slug = null,
        .cache = &cache,
        .conf_abs_path = null,
        .show_imports = false,
        .repo_url = null,
        .extra_css = &.{},
        .header_html = null,
        .footer_html = null,
        .logo = null,
        .favicon = null,
        .base_url = null,
    });

    // The page nested two sections deep must actually be written to disk.
    const page_path = try std.fmt.allocPrint(gpa, "{s}/page/deep.html", .{out_dir});
    defer gpa.free(page_path);
    const content = std.Io.Dir.cwd().readFileAlloc(fix.g_Io, page_path, gpa, .limited(64 * 1024)) catch {
        return error.DeepPageNotRendered;
    };
    defer gpa.free(content);
    try testz.expectTrue(std.mem.indexOf(u8, content, "Hello from deep") != null);

    // The search index must include it too.
    const search_path = try std.fmt.allocPrint(gpa, "{s}/assets/search-data.js", .{out_dir});
    defer gpa.free(search_path);
    const search_data = try std.Io.Dir.cwd().readFileAlloc(fix.g_Io, search_path, gpa, .limited(1024 * 1024));
    defer gpa.free(search_data);
    try testz.expectTrue(std.mem.indexOf(u8, search_data, "page/deep.html") != null);

    // The cache must record the nested guide, so a later incremental
    // rebuild doesn't silently skip re-rendering it.
    try testz.expectTrue(cache.guides.contains("sample.zig"));
}

pub fn homeSlugIsFoundWhenNestedInSection() !void {
    const gpa = std.heap.page_allocator;

    var deep_items: [1]render.PageNavItem = undefined;
    var inner_items: [1]render.PageNavItem = undefined;
    var pages = buildNestedPages(&deep_items, &inner_items);

    var progress = render.Progress.init(10);
    var cache = render.cache_mod.Cache.init(fix.g_Io, gpa);
    defer cache.deinit();

    const out_dir = "test_tmp_render_nested_home";
    defer std.Io.Dir.cwd().deleteTree(fix.g_Io, out_dir) catch {};

    try render.renderSite(fix.g_Io, gpa, .{
        .out_path = out_dir,
        .project_name = "Test",
        .mods = &.{},
        .pages = &pages,
        .emoji_provider = .unicode,
        .theme = .default,
        .progress = &progress,
        .conf_dir = null,
        // "deep" is nested two sections down; the home lookup must find
        // it there instead of falling back to the default module listing.
        .home_slug = "deep",
        .cache = &cache,
        .conf_abs_path = null,
        .show_imports = false,
        .repo_url = null,
        .extra_css = &.{},
        .header_html = null,
        .footer_html = null,
        .logo = null,
        .favicon = null,
        .base_url = null,
    });

    const index_path = try std.fmt.allocPrint(gpa, "{s}/index.html", .{out_dir});
    defer gpa.free(index_path);
    const content = try std.Io.Dir.cwd().readFileAlloc(fix.g_Io, index_path, gpa, .limited(64 * 1024));
    defer gpa.free(content);
    try testz.expectTrue(std.mem.indexOf(u8, content, "Hello from deep") != null);
}

/// The per-page "On this page" TOC scans raw markdown for `## ` lines.
/// A `## ` line inside a fenced code block (e.g. a snippet showing
/// someone else's markdown) must not be fence-blind and land in the TOC
/// alongside real headings.
pub fn tocSkipsHeadingSyntaxInsideFence() !void {
    const gpa = std.heap.page_allocator;

    var items: [1]render.PageNavItem = .{.{ .entry = .{
        .slug = "toc-fence",
        .title = "TOC Fence",
        .content =
        \\# Title
        \\
        \\## Real Heading
        \\
        \\```
        \\## Fake Heading
        \\```
        \\
        \\## Another Real Heading
        ,
        .src_path = "sample.zig",
        .mode = .markdown,
    } }};

    var progress = render.Progress.init(10);
    var cache = render.cache_mod.Cache.init(fix.g_Io, gpa);
    defer cache.deinit();

    const out_dir = "test_tmp_render_toc_fence";
    defer std.Io.Dir.cwd().deleteTree(fix.g_Io, out_dir) catch {};

    try render.renderSite(fix.g_Io, gpa, .{
        .out_path = out_dir,
        .project_name = "Test",
        .mods = &.{},
        .pages = &items,
        .emoji_provider = .unicode,
        .theme = .default,
        .progress = &progress,
        .conf_dir = null,
        .home_slug = null,
        .cache = &cache,
        .conf_abs_path = null,
        .show_imports = false,
        .repo_url = null,
        .extra_css = &.{},
        .header_html = null,
        .footer_html = null,
        .logo = null,
        .favicon = null,
        .base_url = null,
    });

    const page_path = try std.fmt.allocPrint(gpa, "{s}/page/toc-fence.html", .{out_dir});
    defer gpa.free(page_path);
    const content = try std.Io.Dir.cwd().readFileAlloc(fix.g_Io, page_path, gpa, .limited(64 * 1024));
    defer gpa.free(content);

    const toc_start = std.mem.indexOf(u8, content, "page-toc") orelse return error.NoToc;
    const toc_end = std.mem.indexOf(u8, content[toc_start..], "</aside>") orelse return error.NoTocEnd;
    const toc = content[toc_start .. toc_start + toc_end];

    try testz.expectTrue(std.mem.indexOf(u8, toc, "Real Heading") != null);
    try testz.expectTrue(std.mem.indexOf(u8, toc, "Another Real Heading") != null);
    try testz.expectTrue(std.mem.indexOf(u8, toc, "Fake Heading") == null);
}

/// `writeDoc` (used for every `///`/`//!` doc comment on API pages) only
/// ran emoji replacement and code-symbol autolinking — it never called
/// resolveInternalLinks, so a `[text](sym:Name)` link written in a doc
/// comment silently stayed as a broken `href="sym:Name"` forever. Guards
/// the fix: doc-comment sym: links must resolve the same as they do in
/// guide pages.
pub fn docCommentSymLinkIsResolved() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "doc_links.zig");
    defer symbols.deinitModules(gpa, mods);

    var progress = render.Progress.init(10);
    var cache = render.cache_mod.Cache.init(fix.g_Io, gpa);
    defer cache.deinit();

    const out_dir = "test_tmp_render_doc_sym_link";
    defer std.Io.Dir.cwd().deleteTree(fix.g_Io, out_dir) catch {};

    try render.renderSite(fix.g_Io, gpa, .{
        .out_path = out_dir,
        .project_name = "Test",
        .mods = mods,
        .pages = &.{},
        .emoji_provider = .unicode,
        .theme = .default,
        .progress = &progress,
        .conf_dir = null,
        .home_slug = null,
        .cache = &cache,
        .conf_abs_path = null,
        .show_imports = false,
        .repo_url = null,
        .extra_css = &.{},
        .header_html = null,
        .footer_html = null,
        .logo = null,
        .favicon = null,
        .base_url = null,
    });

    const page_path = try std.fmt.allocPrint(gpa, "{s}/api/doc_links.html", .{out_dir});
    defer gpa.free(page_path);
    const content = try std.Io.Dir.cwd().readFileAlloc(fix.g_Io, page_path, gpa, .limited(64 * 1024));
    defer gpa.free(content);

    try testz.expectTrue(std.mem.indexOf(u8, content, "href=\"../api/doc_links.html#sym-bar\"") != null);
    try testz.expectTrue(std.mem.indexOf(u8, content, "href=\"sym:bar\"") == null);
}

/// Literate example-page prose ran `resolveInternalLinks` but never
/// emoji replacement, unlike guide pages and doc comments. Guards the
/// fix: a `:emoji:` shortcode in example prose must resolve too.
pub fn examplePageProseSupportsEmoji() !void {
    const gpa = std.heap.page_allocator;

    var items: [1]render.PageNavItem = .{.{ .entry = .{
        .slug = "emoji-example",
        .title = "Emoji Example",
        .content =
        \\//* Hello :smile: world
        \\pub fn foo() void {}
        ,
        .src_path = "sample.zig",
        .mode = .zig_prose,
    } }};

    var progress = render.Progress.init(10);
    var cache = render.cache_mod.Cache.init(fix.g_Io, gpa);
    defer cache.deinit();

    const out_dir = "test_tmp_render_example_emoji";
    defer std.Io.Dir.cwd().deleteTree(fix.g_Io, out_dir) catch {};

    try render.renderSite(fix.g_Io, gpa, .{
        .out_path = out_dir,
        .project_name = "Test",
        .mods = &.{},
        .pages = &items,
        .emoji_provider = .unicode,
        .theme = .default,
        .progress = &progress,
        .conf_dir = null,
        .home_slug = null,
        .cache = &cache,
        .conf_abs_path = null,
        .show_imports = false,
        .repo_url = null,
        .extra_css = &.{},
        .header_html = null,
        .footer_html = null,
        .logo = null,
        .favicon = null,
        .base_url = null,
    });

    const page_path = try std.fmt.allocPrint(gpa, "{s}/page/emoji-example.html", .{out_dir});
    defer gpa.free(page_path);
    const content = try std.Io.Dir.cwd().readFileAlloc(fix.g_Io, page_path, gpa, .limited(64 * 1024));
    defer gpa.free(content);

    // Scope the check to the rendered prose div — the page also has a
    // (CSS-hidden) "Raw view" pane showing the literal, unprocessed Zig
    // source, which legitimately still contains the literal ":smile:"
    // comment text since that pane is meant to show the source as-is.
    const prose_start = std.mem.indexOf(u8, content, "class=\"example-prose\"") orelse return error.NoProseDiv;
    const prose_end = std.mem.indexOf(u8, content[prose_start..], "</div>") orelse return error.NoProseDivEnd;
    const prose = content[prose_start .. prose_start + prose_end];

    try testz.expectTrue(std.mem.indexOf(u8, prose, ":smile:") == null);
    try testz.expectTrue(std.mem.indexOf(u8, prose, "\u{1F604}") != null);
}

/// `processImages` and `resolveInternalLinks` used to be two separate
/// full-buffer passes; they're now one combined scan (`rewriteAttributes`)
/// over the same HTML. A page with both a relative image and a sym: link
/// guards that merging them didn't break either — each must still resolve
/// correctly regardless of which one appears first in the markup.
pub fn combinedImageAndLinkRewriteBothResolve() !void {
    const gpa = std.heap.page_allocator;
    const conf_dir = "test_tmp_render_combined_conf";
    defer std.Io.Dir.cwd().deleteTree(fix.g_Io, conf_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(fix.g_Io, conf_dir);
    {
        const f = try std.Io.Dir.cwd().createFile(fix.g_Io, conf_dir ++ "/logo.png", .{});
        defer f.close(fix.g_Io);
        try f.writeStreamingAll(fix.g_Io, "not a real png, just needs to exist");
    }

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "doc_links.zig");
    defer symbols.deinitModules(gpa, mods);

    var items: [1]render.PageNavItem = .{.{ .entry = .{
        .slug = "combined",
        .title = "Combined",
        .content = "# Combined\n\n![logo](logo.png)\n\nSee [bar](sym:bar) too.",
        .src_path = "sample.zig",
        .mode = .markdown,
    } }};

    var progress = render.Progress.init(10);
    var cache = render.cache_mod.Cache.init(fix.g_Io, gpa);
    defer cache.deinit();

    const out_dir = "test_tmp_render_combined_out";
    defer std.Io.Dir.cwd().deleteTree(fix.g_Io, out_dir) catch {};

    try render.renderSite(fix.g_Io, gpa, .{
        .out_path = out_dir,
        .project_name = "Test",
        .mods = mods,
        .pages = &items,
        .emoji_provider = .unicode,
        .theme = .default,
        .progress = &progress,
        .conf_dir = conf_dir,
        .home_slug = null,
        .cache = &cache,
        .conf_abs_path = null,
        .show_imports = false,
        .repo_url = null,
        .extra_css = &.{},
        .header_html = null,
        .footer_html = null,
        .logo = null,
        .favicon = null,
        .base_url = null,
    });

    const page_path = try std.fmt.allocPrint(gpa, "{s}/page/combined.html", .{out_dir});
    defer gpa.free(page_path);
    const content = try std.Io.Dir.cwd().readFileAlloc(fix.g_Io, page_path, gpa, .limited(64 * 1024));
    defer gpa.free(content);

    try testz.expectTrue(std.mem.indexOf(u8, content, "src=\"../assets/logo.png\"") != null);
    try testz.expectTrue(std.mem.indexOf(u8, content, "href=\"../api/doc_links.html#sym-bar\"") != null);

    const copied_path = try std.fmt.allocPrint(gpa, "{s}/assets/logo.png", .{out_dir});
    defer gpa.free(copied_path);
    const copied = try std.Io.Dir.cwd().readFileAlloc(fix.g_Io, copied_path, gpa, .limited(1024));
    defer gpa.free(copied);
    try testz.expectEqualStr(copied, "not a real png, just needs to exist");
}
