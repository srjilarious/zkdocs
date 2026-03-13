const std = @import("std");
const zmd = @import("zmd");
const highlight = @import("highlight");

/// Render `markdown` to an HTML fragment (no DOCTYPE/html/body wrapper).
pub fn toHtml(allocator: std.mem.Allocator, markdown_text: []const u8) ![]const u8 {
    return zmd.parse(allocator, markdown_text, .{
        .root  = rootFmt,
        .code  = codeFmt,
        .block = blockFmt,
        .h2    = h2Fmt,
    });
}

/// Produce a URL-safe slug from a heading string.
/// Strips embedded HTML tags, lowercases alphanumerics, collapses non-alphanum runs
/// into single hyphens, and trims leading/trailing hyphens.
pub fn slugify(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var slug: std.ArrayList(u8) = .{};
    errdefer slug.deinit(allocator);

    var in_tag = false;
    var need_dash = false; // true if the next alphanumeric should be preceded by a dash

    for (text) |c| {
        if (c == '<') { in_tag = true; continue; }
        if (c == '>') { in_tag = false; continue; }
        if (in_tag) continue;

        if (std.ascii.isAlphanumeric(c)) {
            if (need_dash and slug.items.len > 0) try slug.append(allocator, '-');
            try slug.append(allocator, std.ascii.toLower(c));
            need_dash = false;
        } else {
            if (slug.items.len > 0) need_dash = true;
        }
    }

    return slug.toOwnedSlice(allocator);
}

// ── Formatters ──────────────────────────────────────────────────────────────

// Override root to return just the inner HTML (no DOCTYPE/html/body wrapper).
fn rootFmt(allocator: std.mem.Allocator, node: zmd.Node) ![]const u8 {
    return allocator.dupe(u8, node.content);
}

// Inline code: plain <code> element.
fn codeFmt(allocator: std.mem.Allocator, node: zmd.Node) ![]const u8 {
    return std.fmt.allocPrint(allocator, "<code>{s}</code>", .{node.content});
}

// Fenced code blocks: Zig blocks get tree-sitter syntax highlighting.
fn blockFmt(allocator: std.mem.Allocator, node: zmd.Node) ![]const u8 {
    if (node.meta) |lang| {
        if (std.mem.eql(u8, lang, "zig")) {
            if (highlight.highlightZig(allocator, node.content)) |hl| {
                defer allocator.free(hl);
                return std.fmt.allocPrint(
                    allocator,
                    "<pre><code class=\"language-zig\">{s}</code></pre>\n",
                    .{hl},
                );
            } else |_| {
                // Fall through to default on any highlighting error.
            }
        }
        return std.fmt.allocPrint(
            allocator,
            "<pre><code class=\"language-{s}\">{s}</code></pre>\n",
            .{ lang, node.content },
        );
    }
    return std.fmt.allocPrint(allocator, "<pre><code>{s}</code></pre>\n", .{node.content});
}

// H2 headings get an anchor id for in-page navigation.
fn h2Fmt(allocator: std.mem.Allocator, node: zmd.Node) ![]const u8 {
    const slug = try slugify(allocator, node.content);
    defer allocator.free(slug);
    return std.fmt.allocPrint(
        allocator,
        "<h2 id=\"h2-{s}\">{s}</h2>\n",
        .{ slug, node.content },
    );
}
