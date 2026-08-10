//* This module checks that `render.resolveInternalLinks` correctly rewrites
//* `sym:` links, including the empty-link-text case where the display text
//* is injected from the symbol name.
const std = @import("std");
const testz = @import("testz");
const zkdocs = @import("zkdocs");
const markdown = zkdocs.markdown;
const render = zkdocs.render;

/// `[](sym:Foo)` with no link text should inject `<code>Foo</code>`.
pub fn emptySymLinkInjectsCodeName() !void {
    const gpa = std.heap.page_allocator;

    const html = try render.resolveInternalLinks(gpa,
        \\<a href="sym:MyStruct"></a>
    , &.{}, ".");
    defer gpa.free(html);

    try testz.expectTrue(std.mem.indexOf(u8, html, "<code>MyStruct</code>") != null);
}

/// Qualified `[](sym:module.Foo)` should display only the last component.
pub fn emptySymLinkQualifiedUsesLastComponent() !void {
    const gpa = std.heap.page_allocator;

    const html = try render.resolveInternalLinks(gpa,
        \\<a href="sym:mymod.MyStruct"></a>
    , &.{}, ".");
    defer gpa.free(html);

    // Display text should be the last component only, not the qualified name.
    try testz.expectTrue(std.mem.indexOf(u8, html, "<code>MyStruct</code>") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "<code>mymod.MyStruct</code>") == null);
}

/// `[](sym:Foo)` with empty brackets in raw markdown must parse as a link.
pub fn emptyBracketsSymLinkParsesFromMarkdown() !void {
    const gpa = std.heap.page_allocator;

    const html = try markdown.toHtml(gpa, "[](sym:PixzigEngineOptions)");
    defer gpa.free(html);

    // Must produce an <a> tag, not render as plain text.
    try testz.expectTrue(std.mem.indexOf(u8, html, "<a ") != null or
        std.mem.indexOf(u8, html, "<a>") != null);
    // Must not appear as raw bracket text.
    try testz.expectTrue(std.mem.indexOf(u8, html, "[sym:") == null);
}

/// `[CustomText](sym:Foo)` already has link text — must not be altered.
pub fn nonEmptySymLinkPreservesText() !void {
    const gpa = std.heap.page_allocator;

    const html = try render.resolveInternalLinks(gpa,
        \\<a href="sym:MyStruct">CustomText</a>
    , &.{}, ".");
    defer gpa.free(html);

    try testz.expectTrue(std.mem.indexOf(u8, html, "CustomText") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "<code>") == null);
}
