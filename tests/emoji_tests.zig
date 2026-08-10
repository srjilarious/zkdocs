//* These tests cover `emoji.replaceInHtml`, which had no test coverage at
//* all: shortcode lookup, the `none` provider passthrough, and the
//* documented (but previously unverified) behavior that shortcodes inside
//* `<code>`/`<pre>` are left untouched so code samples aren't mangled.
const std = @import("std");
const testz = @import("testz");
const zkdocs = @import("zkdocs");
const emoji = zkdocs.emoji;

pub fn unicodeProviderReplacesKnownShortcode() !void {
    const gpa = std.heap.page_allocator;

    const html = try emoji.replaceInHtml(gpa, "<p>Hello :smile: world</p>", .unicode);
    defer gpa.free(html);

    try testz.expectTrue(std.mem.indexOf(u8, html, ":smile:") == null);
    // U+1F604 (SMILE) UTF-8 encoded.
    try testz.expectTrue(std.mem.indexOf(u8, html, "\u{1F604}") != null);
}

pub fn noneProviderLeavesShortcodesUntouched() !void {
    const gpa = std.heap.page_allocator;

    const src = "<p>Hello :smile: world</p>";
    const html = try emoji.replaceInHtml(gpa, src, .none);
    defer gpa.free(html);

    try testz.expectEqualStr(html, src);
}

pub fn shortcodeInsideCodeBlockIsNotReplaced() !void {
    const gpa = std.heap.page_allocator;

    const html = try emoji.replaceInHtml(gpa, "<pre><code>:smile:</code></pre>", .unicode);
    defer gpa.free(html);

    try testz.expectTrue(std.mem.indexOf(u8, html, ":smile:") != null);
}

pub fn unknownShortcodeIsLeftAsIs() !void {
    const gpa = std.heap.page_allocator;

    const src = "<p>:not_a_real_emoji:</p>";
    const html = try emoji.replaceInHtml(gpa, src, .unicode);
    defer gpa.free(html);

    try testz.expectEqualStr(html, src);
}
