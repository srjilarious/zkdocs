const std = @import("std");
const zmd = @import("zmd");
const highlight = @import("highlight");

/// Render `markdown` to an HTML fragment (no DOCTYPE/html/body wrapper).
pub fn toHtml(allocator: std.mem.Allocator, markdown_text: []const u8) ![]const u8 {
    return zmd.parse(allocator, markdown_text, .{
        .root  = rootFmt,
        .code  = codeFmt,
        .block = blockFmt,
    });
}

// Override root to return just the inner HTML, not a full document.
fn rootFmt(allocator: std.mem.Allocator, node: zmd.Node) ![]const u8 {
    return allocator.dupe(u8, node.content);
}

// Use a plain <code> element; CSS handles the styling.
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
