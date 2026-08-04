//! Post-processing passes over rendered page HTML: linking bare `<code>`
//! spans to known symbols, resolving `sym:`/`mod:`/`page:` internal link
//! schemes, and copying+rewriting relative image sources.

const std = @import("std");
const symbols = @import("./symbols.zig");
const cache_mod = @import("./cache.zig");
const site_context = @import("./site_context.zig");

const TypeIndex = site_context.TypeIndex;

// ---------------------------------------------------------------------------
// Code-symbol autolinking
// ---------------------------------------------------------------------------

/// Rewrite inline `<code>Identifier</code>` spans in rendered doc HTML to
/// links when the identifier names a known symbol.  Spans inside `<pre>` are
/// left untouched so fenced code examples are never turned into links.
pub fn linkCodeSymbols(
    allocator: std.mem.Allocator,
    html: []const u8,
    type_index: *const TypeIndex,
    current_module: []const u8,
) ![]const u8 {
    const open_code = "<code>";
    const close_code = "</code>";
    const open_pre = "<pre";
    const close_pre = "</pre>";

    var out: std.ArrayList(u8) = .empty;
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
                    const lnk = try std.fmt.allocPrint(allocator, "<a href=\"#sym-{s}\" class=\"type-link\"><code>{s}</code></a>", .{ ref.anchor_name, content });
                    defer allocator.free(lnk);
                    try out.appendSlice(allocator, lnk);
                } else {
                    const lnk = try std.fmt.allocPrint(allocator, "<a href=\"{s}.html#sym-{s}\" class=\"type-link\"><code>{s}</code></a>", .{ ref.module_name, ref.anchor_name, content });
                    defer allocator.free(lnk);
                    try out.appendSlice(allocator, lnk);
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
                        const lnk = try std.fmt.allocPrint(allocator, "<a href=\"#sym-{s}-{s}\" class=\"type-link\"><code>{s}</code></a>", .{ lhs, rhs, content });
                        defer allocator.free(lnk);
                        try out.appendSlice(allocator, lnk);
                    } else {
                        const lnk = try std.fmt.allocPrint(allocator, "<a href=\"{s}.html#sym-{s}-{s}\" class=\"type-link\"><code>{s}</code></a>", .{ ref.module_name, lhs, rhs, content });
                        defer allocator.free(lnk);
                        try out.appendSlice(allocator, lnk);
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
/// Supported syntax in page markdown:
///   `[text](sym:Name)`             → any public symbol (searched across all modules)
///   `[text](sym:module.Name)`      → symbol qualified by module name
///   `[text](sym:Container.method)` → method anchor (when first part is not a module)
///   `[text](mod:name)`             → module API page (`api/name.html`)
///   `[text](page:slug)`            → another page (`page/slug.html`)
///   `[text](guide:slug)`           → another page, backward-compat alias for `page:slug`
pub fn resolveInternalLinks(
    allocator: std.mem.Allocator,
    html: []const u8,
    mods: []const symbols.Module,
    prefix: []const u8,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    var rest = html;
    while (true) {
        const sym_pos = std.mem.indexOf(u8, rest, "href=\"sym:");
        const mod_pos = std.mem.indexOf(u8, rest, "href=\"mod:");
        const guide_pos = std.mem.indexOf(u8, rest, "href=\"guide:");
        const page_pos = std.mem.indexOf(u8, rest, "href=\"page:");

        // Pick the earliest marker.
        var fp: usize = std.math.maxInt(usize);
        if (sym_pos) |p| fp = @min(fp, p);
        if (mod_pos) |p| fp = @min(fp, p);
        if (guide_pos) |p| fp = @min(fp, p);
        if (page_pos) |p| fp = @min(fp, p);
        if (fp == std.math.maxInt(usize)) {
            try out.appendSlice(allocator, rest);
            break;
        }

        try out.appendSlice(allocator, rest[0..fp]);

        const marker: []const u8 = if (sym_pos != null and fp == sym_pos.?)
            "href=\"sym:"
        else if (mod_pos != null and fp == mod_pos.?)
            "href=\"mod:"
        else if (guide_pos != null and fp == guide_pos.?)
            "href=\"guide:"
        else
            "href=\"page:";

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
                    const lnk = try std.fmt.allocPrint(allocator, "href=\"{s}/api/{s}.html#sym-{s}-{s}", .{ prefix, ref.module_name, cont, ref.name });
                    defer allocator.free(lnk);
                    try out.appendSlice(allocator, lnk);
                } else {
                    const lnk = try std.fmt.allocPrint(allocator, "href=\"{s}/api/{s}.html#sym-{s}", .{ prefix, ref.module_name, ref.name });
                    defer allocator.free(lnk);
                    try out.appendSlice(allocator, lnk);
                }
            } else {
                const lnk = try std.fmt.allocPrint(allocator, "href=\"#sym-{s}", .{target});
                defer allocator.free(lnk);
                try out.appendSlice(allocator, lnk);
            }
        } else if (std.mem.eql(u8, marker, "href=\"mod:")) {
            const lnk = try std.fmt.allocPrint(allocator, "href=\"{s}/api/{s}.html", .{ prefix, target });
            defer allocator.free(lnk);
            try out.appendSlice(allocator, lnk);
        } else {
            // guide: (backward compat) or page:
            const lnk = try std.fmt.allocPrint(allocator, "href=\"{s}/page/{s}.html", .{ prefix, target });
            defer allocator.free(lnk);
            try out.appendSlice(allocator, lnk);
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
                    const code_tag = try std.fmt.allocPrint(allocator, "<code>{s}</code>", .{display_name});
                    defer allocator.free(code_tag);
                    try out.appendSlice(allocator, code_tag);
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
    io: std.Io,
    allocator: std.mem.Allocator,
    conf_dir: []const u8,
    rel_path: []const u8,
    out_dir: std.Io.Dir,
    cache: *cache_mod.Cache,
) !void {
    const dest_rel = try std.fs.path.join(allocator, &.{ "assets", rel_path });
    defer allocator.free(dest_rel);

    if (std.fs.path.dirname(dest_rel)) |parent| {
        try out_dir.createDirPath(io, parent);
    }

    const src_path = try std.fs.path.join(allocator, &.{ conf_dir, rel_path });
    defer allocator.free(src_path);

    try std.Io.Dir.copyFile(std.Io.Dir.cwd(), src_path, out_dir, dest_rel, io, .{});

    const abs_src = cache_mod.absPath(io, allocator, src_path) catch try allocator.dupe(u8, src_path);
    defer allocator.free(abs_src);
    cache.recordAsset(abs_src) catch {};
}

/// Scan rendered HTML for `<img src="...">` elements; copy any relative-path
/// images into `out_dir/assets/` and rewrite their src to `{prefix}/assets/…`.
pub fn processImages(
    io: std.Io,
    allocator: std.mem.Allocator,
    html: []const u8,
    conf_dir: []const u8,
    out_dir: std.Io.Dir,
    prefix: []const u8,
    cache: *cache_mod.Cache,
) ![]const u8 {
    const marker = "src=\"";
    var out: std.ArrayList(u8) = .empty;
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
            copyImageFile(io, allocator, conf_dir, src, out_dir, cache) catch |err| {
                std.debug.print("Warning: could not copy image '{s}': {}\n", .{ src, err });
            };
            const img_src = try std.fmt.allocPrint(allocator, "src=\"{s}/assets/{s}", .{ prefix, src });
            defer allocator.free(img_src);
            try out.appendSlice(allocator, img_src);
        } else {
            try out.appendSlice(allocator, marker);
            try out.appendSlice(allocator, src);
        }

        // after[close..] starts with the closing `"` — preserved on next pass.
        rest = after[close..];
    }

    return out.toOwnedSlice(allocator);
}
