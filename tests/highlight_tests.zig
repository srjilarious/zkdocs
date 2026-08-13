//* These tests cover `highlight.zig` (tree-sitter syntax highlighting), which
//* had no test coverage at all: the tree-sitter Zig path, the JSON path, and
//* the escaped-plain-text fallback for a language with no grammar.
const std = @import("std");
const testz = @import("testz");
const zkdocs = @import("zkdocs");
const highlight = zkdocs.markdown.highlight;

pub fn zigKeywordsAreWrappedInSpans() !void {
    const gpa = std.heap.page_allocator;

    const html = try highlight.highlightZig(gpa, "pub fn foo() void {}");
    defer gpa.free(html);

    try testz.expectTrue(std.mem.indexOf(u8, html, "hl-keyword") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "foo") != null);
}

pub fn zigHighlightEscapesHtmlInStringLiterals() !void {
    const gpa = std.heap.page_allocator;

    const html = try highlight.highlightZig(gpa, "const s = \"<a>\";");
    defer gpa.free(html);

    try testz.expectTrue(std.mem.indexOf(u8, html, "&lt;a&gt;") != null);
    // The raw angle brackets must not survive un-escaped inside the span.
    try testz.expectTrue(std.mem.indexOf(u8, html, "<a>") == null);
}

pub fn unknownLanguageFallsBackToEscapedPlainText() !void {
    const gpa = std.heap.page_allocator;

    const html = try highlight.highlight(gpa, "python", "<script>alert(1)</script>");
    defer gpa.free(html);

    try testz.expectTrue(std.mem.indexOf(u8, html, "&lt;script&gt;") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "hl-") == null);
}

pub fn jsonHighlightWrapsStringsAndNumbers() !void {
    const gpa = std.heap.page_allocator;

    const html = try highlight.highlight(gpa, "json", "{\"a\": 1}");
    defer gpa.free(html);

    try testz.expectTrue(std.mem.indexOf(u8, html, "hl-string") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "hl-number") != null);
}

pub fn ansiHighlightColorsZigKeywords() !void {
    const gpa = std.heap.page_allocator;

    const ansi = try highlight.highlightAnsi(gpa, "zig", "pub fn foo() void {}");
    defer gpa.free(ansi);

    // keyword color code, and no HTML markup at all in the ANSI path.
    try testz.expectTrue(std.mem.indexOf(u8, ansi, "\x1b[35m") != null);
    try testz.expectTrue(std.mem.indexOf(u8, ansi, "foo") != null);
    try testz.expectTrue(std.mem.indexOf(u8, ansi, "<span") == null);
    try testz.expectTrue(std.mem.indexOf(u8, ansi, "hl-") == null);
}

pub fn ansiHighlightDoesNotHtmlEscapeStringLiterals() !void {
    const gpa = std.heap.page_allocator;

    const ansi = try highlight.highlightAnsi(gpa, "zig", "const s = \"<a>\";");
    defer gpa.free(ansi);

    // Terminal output should never HTML-escape -- the raw text should
    // survive unmodified inside the color-wrapped string span.
    try testz.expectTrue(std.mem.indexOf(u8, ansi, "<a>") != null);
    try testz.expectTrue(std.mem.indexOf(u8, ansi, "&lt;") == null);
}

pub fn ansiUnknownLanguageFallsBackToRawSource() !void {
    const gpa = std.heap.page_allocator;

    const ansi = try highlight.highlightAnsi(gpa, "python", "<script>alert(1)</script>");
    defer gpa.free(ansi);

    try testz.expectEqualStr(ansi, "<script>alert(1)</script>");
}
