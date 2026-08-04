//! `zkdocs.conf` parsing: JSON-with-`//`-comments, the `SiteConf` structure,
//! and loading individual page entries (guides/examples) referenced by it.

const std = @import("std");
const cache_mod = @import("./cache.zig");
const theme_mod = @import("./theme.zig");
const pages = @import("./pages.zig");

const Theme = theme_mod.Theme;
const PageEntry = pages.PageEntry;
const PageNavItem = pages.PageNavItem;
const freePageEntry = pages.freePageEntry;
const freePageNavItem = pages.freePageNavItem;
const freePages = pages.freePages;

// ---------------------------------------------------------------------------
// JSON with comments
// ---------------------------------------------------------------------------

pub fn trimLeft(comptime T: type, slice: []const T, values_to_strip: []const T) []const T {
    var begin: usize = 0;
    while (begin < slice.len and std.mem.indexOfScalar(T, values_to_strip, slice[begin]) != null) : (begin += 1) {}
    return slice[begin..slice.len];
}

/// Strip `//`-style line comments from `src` and return a freshly allocated
/// copy suitable for passing to `std.json.parseFromSlice`.
///
/// A comment is any line whose first non-whitespace characters are `//`.
/// The entire line (including its trailing newline) is replaced by a blank
/// line so that byte offsets in error messages remain meaningful.
pub fn stripJsonComments(allocator: std.mem.Allocator, src: []const u8) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |line| {
        const trimmed = trimLeft(u8, line, " \t");
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
// Page entry loading
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

pub fn loadPageEntry(
    io: std.Io,
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    config_dir: []const u8,
    /// Overrides per-entry mode inference. Pass null to auto-detect from extension.
    force_mode: ?pages.PageMode,
    /// When true, all .zig files default to zig_raw instead of zig_prose.
    prose_disabled: bool,
) !PageEntry {
    const src_val = obj.get("src") orelse return error.MissingField;
    if (src_val != .string) return error.InvalidField;
    const src = src_val.string;

    const full_path = try std.fs.path.join(allocator, &.{ config_dir, src });
    defer allocator.free(full_path);

    // Resolve to absolute path for cache mtime tracking.
    const src_path = cache_mod.absPath(io, allocator, full_path) catch try allocator.dupe(u8, full_path);
    errdefer allocator.free(src_path);

    const content = std.Io.Dir.cwd().readFileAlloc(io, full_path, allocator, .limited(4 * 1024 * 1024)) catch {
        std.log.err("Unabled to read page source file: {s}", .{full_path});
        return error.CantReadPageEntry;
    };

    errdefer allocator.free(content);

    const is_zig = std.mem.endsWith(u8, src, ".zig");
    const is_md = std.mem.endsWith(u8, src, ".md");

    // Determine mode: forced > per-entry "raw" flag > prose_disabled global > extension default.
    const mode: pages.PageMode = if (force_mode) |fm|
        fm
    else if (is_zig) blk: {
        const raw_flag = if (obj.get("raw")) |rv| rv == .bool and rv.bool else false;
        break :blk if (prose_disabled or raw_flag) .zig_raw else .zig_prose;
    } else if (is_md)
        .markdown
    else
        .markdown;

    // Slug = src with extension stripped
    const slug_src = if (is_md)
        src[0 .. src.len - 3]
    else if (is_zig)
        std.fs.path.stem(src)
    else
        src;
    const slug = try allocator.dupe(u8, slug_src);
    errdefer allocator.free(slug);

    // Title: explicit config value, or extracted H1 (md only), or file stem
    const stem = std.fs.path.stem(src);
    const title = if (obj.get("title")) |tv|
        try allocator.dupe(u8, if (tv == .string) tv.string else if (is_md) extractTitle(content, stem) else stem)
    else if (is_md)
        try allocator.dupe(u8, extractTitle(content, stem))
    else
        try allocator.dupe(u8, stem);
    errdefer allocator.free(title);

    return .{ .slug = slug, .title = title, .content = content, .src_path = src_path, .mode = mode };
}

/// Recursively load a JSON array of page items into `items_out`.
/// Sections use the `"pages"` key for children (new format).
fn loadPageItemsFromArray(
    io: std.Io,
    allocator: std.mem.Allocator,
    array: std.json.Array,
    config_dir: []const u8,
    prose_disabled: bool,
    items_out: *std.ArrayList(PageNavItem),
) !void {
    for (array.items) |json_item| {
        if (json_item != .object) continue;
        const item_obj = json_item.object;
        if (item_obj.get("section")) |sec_val| {
            if (sec_val != .string) continue;
            const sec_title = try allocator.dupe(u8, sec_val.string);
            errdefer allocator.free(sec_title);
            var sec_items: std.ArrayList(PageNavItem) = .empty;
            errdefer {
                for (sec_items.items) |*it| freePageNavItem(allocator, it);
                sec_items.deinit(allocator);
            }
            // Support both "pages" (new) and "entries" (backward compat) as child key.
            const child_key: []const u8 = if (item_obj.get("pages") != null) "pages" else "entries";
            if (item_obj.get(child_key)) |cv| if (cv == .array) {
                try loadPageItemsFromArray(io, allocator, cv.array, config_dir, prose_disabled, &sec_items);
            };
            const sec_slice = try sec_items.toOwnedSlice(allocator);
            errdefer {
                for (sec_slice) |*it| freePageNavItem(allocator, it);
                allocator.free(sec_slice);
            }
            try items_out.append(allocator, .{ .section = .{ .title = sec_title, .items = sec_slice } });
        } else if (item_obj.get("src") != null) {
            const e = try loadPageEntry(io, allocator, item_obj, config_dir, null, prose_disabled);
            errdefer freePageEntry(allocator, @constCast(&e));
            try items_out.append(allocator, .{ .entry = e });
        }
    }
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
    /// Unified page nav items from `"guides"` and `"examples"` arrays.
    pages: []PageNavItem,
    /// Directory containing the conf file; used to resolve relative image paths.
    conf_dir: []const u8,
    /// Slug of the page to render as `index.html` (`"home"` key), or null.
    home_slug: ?[]const u8,
    /// When true, pub `@import` constants are shown in API docs.
    /// Defaults to false (imports are hidden).
    show_imports: bool = false,
    /// Repository URL (`"repo"` key), or null if absent.
    /// When set, a source-control icon linking to this URL is shown next to the project name.
    repo: ?[]const u8,

    pub fn deinit(self: *SiteConf, allocator: std.mem.Allocator) void {
        if (self.name) |n| allocator.free(n);
        if (self.sources) |srcs| {
            for (srcs) |s| allocator.free(s);
            allocator.free(srcs);
        }
        if (self.emoji) |e| allocator.free(e);
        freePages(allocator, self.pages);
        allocator.free(self.conf_dir);
        if (self.home_slug) |hs| allocator.free(hs);
        if (self.repo) |r| allocator.free(r);
    }
};

/// Parse a `zkdocs.conf` JSON file and return a `SiteConf`.
/// The caller owns the result and must call `result.deinit(allocator)`.
pub fn loadSiteConf(io: std.Io, allocator: std.mem.Allocator, conf_path: []const u8) !SiteConf {
    const raw = try std.Io.Dir.cwd().readFileAlloc(io, conf_path, allocator, .limited(2 * 1024 * 1024));
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
        var list = std.ArrayList([]const u8).empty;
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

    // --- pages ---
    // Global prose flag: "prose": false disables prose rendering for all .zig pages.
    const prose_disabled = if (obj.get("prose")) |v| v == .bool and !v.bool else false;

    var page_items = std.ArrayList(PageNavItem).empty;
    errdefer {
        for (page_items.items) |*it| freePageNavItem(allocator, it);
        page_items.deinit(allocator);
    }

    if (obj.get("pages")) |pv| if (pv == .array) {
        // New unified "pages" format: extension determines mode, sections use "pages" key.
        try loadPageItemsFromArray(io, allocator, pv.array, conf_dir, prose_disabled, &page_items);
    } else {} else {
        // Backward-compat: read old "guides" + "examples" format.
        if (obj.get("guides")) |gv| if (gv == .array) {
            for (gv.array.items) |json_item| {
                if (json_item != .object) continue;
                const item_obj = json_item.object;
                if (item_obj.get("section")) |sec_val| {
                    if (sec_val != .string) continue;
                    const sec_title = try allocator.dupe(u8, sec_val.string);
                    errdefer allocator.free(sec_title);
                    var sec_entries = std.ArrayList(PageNavItem).empty;
                    errdefer {
                        for (sec_entries.items) |*e| freePageNavItem(allocator, e);
                        sec_entries.deinit(allocator);
                    }
                    if (item_obj.get("entries")) |ev| if (ev == .array) {
                        for (ev.array.items) |ei| {
                            if (ei != .object) continue;
                            const e = try loadPageEntry(io, allocator, ei.object, conf_dir, .markdown, false);
                            errdefer freePageEntry(allocator, @constCast(&e));
                            try sec_entries.append(allocator, .{ .entry = e });
                        }
                    };
                    const sec_slice = try sec_entries.toOwnedSlice(allocator);
                    errdefer {
                        for (sec_slice) |*e| freePageNavItem(allocator, e);
                        allocator.free(sec_slice);
                    }
                    try page_items.append(allocator, .{ .section = .{ .title = sec_title, .items = sec_slice } });
                } else if (item_obj.get("src") != null) {
                    const e = try loadPageEntry(io, allocator, item_obj, conf_dir, .markdown, false);
                    errdefer freePageEntry(allocator, @constCast(&e));
                    try page_items.append(allocator, .{ .entry = e });
                }
            }
        };
        if (obj.get("examples")) |ev| if (ev == .array) {
            for (ev.array.items) |item| {
                if (item != .object) continue;
                const e = try loadPageEntry(io, allocator, item.object, conf_dir, .zig_prose, prose_disabled);
                errdefer freePageEntry(allocator, @constCast(&e));
                try page_items.append(allocator, .{ .entry = e });
            }
        };
    }

    const pages_slice = try page_items.toOwnedSlice(allocator);
    errdefer freePages(allocator, pages_slice);

    // --- home ---
    // Accept either a slug ("getting-started") or a src filename ("getting-started.md").
    const home_slug: ?[]const u8 = if (obj.get("home")) |v| blk: {
        if (v != .string) break :blk null;
        const home_src = v.string;
        const home_slug_str = if (std.mem.endsWith(u8, home_src, ".md"))
            home_src[0 .. home_src.len - 3]
        else if (std.mem.endsWith(u8, home_src, ".zig"))
            std.fs.path.stem(home_src)
        else
            home_src;
        break :blk try allocator.dupe(u8, home_slug_str);
    } else null;
    errdefer if (home_slug) |hs| allocator.free(hs);

    const show_imports = if (obj.get("show_imports")) |v| v == .bool and v.bool else false;

    // --- repo ---
    const repo: ?[]const u8 = if (obj.get("repo")) |v|
        if (v == .string) try allocator.dupe(u8, v.string) else null
    else
        null;
    errdefer if (repo) |r| allocator.free(r);

    return .{
        .name = name,
        .sources = sources,
        .theme = theme,
        .emoji = ep,
        .pages = pages_slice,
        .conf_dir = try allocator.dupe(u8, conf_dir),
        .home_slug = home_slug,
        .show_imports = show_imports,
        .repo = repo,
    };
}
