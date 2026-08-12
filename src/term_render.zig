//! ANSI terminal rendering for markdown doc-comment text, used by the
//! `zkdocs show` / `zkdocs --dump` CLI output (see plans/future_features.md
//! §10.1). Mirrors the Formatters-override pattern `markdown.zig` already
//! uses for HTML, targeting ANSI escape codes instead of tags.
//!
//! zmd's `Node.zig` always HTML-escapes plain text (`&`, `<`, `>`)
//! regardless of which Formatters are supplied, since that escaping happens
//! before any formatter runs. Both formatter sets below undo it via
//! `default`, since nothing else in a terminal-rendered string should ever
//! contain those entity sequences.
const std = @import("std");
const Allocator = std.mem.Allocator;
const zmd = @import("./zmd/zmd.zig");

pub const reset = "\x1b[0m";
pub const bold = "\x1b[1m";
pub const dim = "\x1b[2m";
pub const italic_code = "\x1b[3m";
pub const underline = "\x1b[4m";
pub const cyan = "\x1b[36m";
pub const green = "\x1b[32m";
pub const gray = "\x1b[90m";

/// Render a doc-comment markdown string for terminal display. `color`
/// selects ANSI-styled output; pass `false` (e.g. when stdout isn't a TTY)
/// for plain, escape-free text that still preserves structure (headings,
/// lists, code spans, links).
pub fn renderDoc(allocator: Allocator, doc: []const u8, color: bool) ![]const u8 {
    // Each branch must call zmd.parse with its own literal Formatters
    // constant directly -- Formatters is a comptime-only type (its Handler
    // fields are bare function types, not function pointers), so selecting
    // between color_formatters/plain_formatters as a runtime value first
    // (e.g. via a single `if` *expression*) doesn't compile.
    if (color) {
        return zmd.parse(allocator, doc, color_formatters);
    } else {
        return zmd.parse(allocator, doc, plain_formatters);
    }
}

fn rootFmt(allocator: Allocator, node: zmd.Node) Allocator.Error![]const u8 {
    return allocator.dupe(u8, node.content);
}

fn unescapeEntities(allocator: Allocator, s: []const u8) Allocator.Error![]const u8 {
    const step1 = try std.mem.replaceOwned(u8, allocator, s, "&lt;", "<");
    defer allocator.free(step1);
    const step2 = try std.mem.replaceOwned(u8, allocator, step1, "&gt;", ">");
    defer allocator.free(step2);
    return std.mem.replaceOwned(u8, allocator, step2, "&amp;", "&");
}

fn defaultFmt(allocator: Allocator, node: zmd.Node) Allocator.Error![]const u8 {
    return unescapeEntities(allocator, node.content);
}

// ── Colored formatters ────────────────────────────────────────────────────

fn wrap(allocator: Allocator, code: []const u8, content: []const u8) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ code, content, reset });
}

fn colorBold(allocator: Allocator, node: zmd.Node) Allocator.Error![]const u8 {
    return wrap(allocator, bold, node.content);
}

fn colorItalic(allocator: Allocator, node: zmd.Node) Allocator.Error![]const u8 {
    return wrap(allocator, italic_code, node.content);
}

fn colorCode(allocator: Allocator, node: zmd.Node) Allocator.Error![]const u8 {
    return wrap(allocator, dim ++ cyan, node.content);
}

fn colorHeading(allocator: Allocator, node: zmd.Node) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}{s}\n\n", .{ bold, node.content, reset });
}

fn colorLink(allocator: Allocator, node: zmd.Node) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}{s} {s}({s}){s}", .{
        underline, node.title orelse "", reset, gray, node.href orelse "", reset,
    });
}

fn colorImage(allocator: Allocator, node: zmd.Node) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}[image: {s}]{s} {s}({s}){s}", .{
        dim, node.title orelse "", reset, gray, node.href orelse "", reset,
    });
}

fn colorParagraph(allocator: Allocator, node: zmd.Node) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}\n\n", .{node.content});
}

fn colorListItem(allocator: Allocator, node: zmd.Node) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "  - {s}\n", .{node.content});
}

fn colorList(allocator: Allocator, node: zmd.Node) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}\n", .{node.content});
}

fn colorBlock(allocator: Allocator, node: zmd.Node) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}{s}\n", .{ dim, node.content, reset });
}

const color_formatters: zmd.Formatters = .{
    .root = rootFmt,
    .default = defaultFmt,
    .bold = colorBold,
    .italic = colorItalic,
    .code = colorCode,
    .h1 = colorHeading,
    .h2 = colorHeading,
    .h3 = colorHeading,
    .h4 = colorHeading,
    .h5 = colorHeading,
    .h6 = colorHeading,
    .link = colorLink,
    .image = colorImage,
    .paragraph = colorParagraph,
    .list_item = colorListItem,
    .unordered_list = colorList,
    .ordered_list = colorList,
    .block = colorBlock,
    .table = plainPassthrough,
};

// ── Plain formatters (no ANSI, still structurally readable) ────────────────

fn plainPassthrough(allocator: Allocator, node: zmd.Node) Allocator.Error![]const u8 {
    return allocator.dupe(u8, node.content);
}

fn plainCode(allocator: Allocator, node: zmd.Node) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "`{s}`", .{node.content});
}

fn plainHeading(allocator: Allocator, node: zmd.Node) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}\n\n", .{node.content});
}

fn plainLink(allocator: Allocator, node: zmd.Node) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s} ({s})", .{ node.title orelse "", node.href orelse "" });
}

fn plainImage(allocator: Allocator, node: zmd.Node) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "[image: {s}] ({s})", .{ node.title orelse "", node.href orelse "" });
}

fn plainParagraph(allocator: Allocator, node: zmd.Node) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}\n\n", .{node.content});
}

fn plainListItem(allocator: Allocator, node: zmd.Node) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "  - {s}\n", .{node.content});
}

fn plainList(allocator: Allocator, node: zmd.Node) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}\n", .{node.content});
}

fn plainBlock(allocator: Allocator, node: zmd.Node) Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}\n", .{node.content});
}

const plain_formatters: zmd.Formatters = .{
    .root = rootFmt,
    .default = defaultFmt,
    .bold = plainPassthrough,
    .italic = plainPassthrough,
    .code = plainCode,
    .h1 = plainHeading,
    .h2 = plainHeading,
    .h3 = plainHeading,
    .h4 = plainHeading,
    .h5 = plainHeading,
    .h6 = plainHeading,
    .link = plainLink,
    .image = plainImage,
    .paragraph = plainParagraph,
    .list_item = plainListItem,
    .unordered_list = plainList,
    .ordered_list = plainList,
    .block = plainBlock,
    .table = plainPassthrough,
};
