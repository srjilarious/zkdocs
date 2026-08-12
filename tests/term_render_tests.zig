//* These tests cover `term_render.zig`, the ANSI markdown renderer used by
//* the `zkdocs show`/`--dump` CLI output (plans/future_features.md §10.1).
//* Covers the color/plain formatter split and the entity-unescape fix for
//* zmd's Node.zig, which always HTML-escapes plain text regardless of which
//* Formatters are supplied.
const std = @import("std");
const testz = @import("testz");
const zkdocs = @import("zkdocs");
const term = zkdocs.term_render;

pub fn boldUsesAnsiEscapesWhenColorEnabled() !void {
    const gpa = std.heap.page_allocator;

    const out = try term.renderDoc(gpa, "This is **bold** text.", true);
    defer gpa.free(out);

    try testz.expectTrue(std.mem.indexOf(u8, out, term.bold ++ "bold" ++ term.reset) != null);
}

pub fn boldIsPlainTextWhenColorDisabled() !void {
    const gpa = std.heap.page_allocator;

    const out = try term.renderDoc(gpa, "This is **bold** text.", false);
    defer gpa.free(out);

    try testz.expectTrue(std.mem.indexOf(u8, out, "\x1b[") == null);
    try testz.expectTrue(std.mem.indexOf(u8, out, "bold") != null);
}

pub fn italicUsesAnsiEscapeWhenColorEnabled() !void {
    const gpa = std.heap.page_allocator;

    const out = try term.renderDoc(gpa, "This is _italic_ text.", true);
    defer gpa.free(out);

    try testz.expectTrue(std.mem.indexOf(u8, out, term.italic_code ++ "italic" ++ term.reset) != null);
}

pub fn codeSpanIsDimmedWhenColorEnabled() !void {
    const gpa = std.heap.page_allocator;

    const out = try term.renderDoc(gpa, "Call `doThing()` first.", true);
    defer gpa.free(out);

    try testz.expectTrue(std.mem.indexOf(u8, out, term.dim ++ term.cyan ++ "doThing()" ++ term.reset) != null);
}

pub fn codeSpanIsBacktickedWhenColorDisabled() !void {
    const gpa = std.heap.page_allocator;

    const out = try term.renderDoc(gpa, "Call `doThing()` first.", false);
    defer gpa.free(out);

    try testz.expectTrue(std.mem.indexOf(u8, out, "`doThing()`") != null);
    try testz.expectTrue(std.mem.indexOf(u8, out, "\x1b[") == null);
}

pub fn headingIsBoldedWhenColorEnabled() !void {
    const gpa = std.heap.page_allocator;

    const out = try term.renderDoc(gpa, "# Title\n\nBody text.", true);
    defer gpa.free(out);

    try testz.expectTrue(std.mem.indexOf(u8, out, term.bold ++ "Title" ++ term.reset) != null);
}

pub fn linkShowsTitleAndHrefInBothModes() !void {
    const gpa = std.heap.page_allocator;

    const colored = try term.renderDoc(gpa, "See [the docs](https://example.com/docs).", true);
    defer gpa.free(colored);
    try testz.expectTrue(std.mem.indexOf(u8, colored, "the docs") != null);
    try testz.expectTrue(std.mem.indexOf(u8, colored, "https://example.com/docs") != null);

    const plain = try term.renderDoc(gpa, "See [the docs](https://example.com/docs).", false);
    defer gpa.free(plain);
    try testz.expectTrue(std.mem.indexOf(u8, plain, "the docs (https://example.com/docs)") != null);
}

// Regression test: zmd's Node.zig HTML-escapes all plain text unconditionally
// (before any Formatter runs), so without term_render's `default` override
// unescaping it back out, literal `<`/`>`/`&` in a doc comment would show up
// as `&lt;`/`&gt;`/`&amp;` in terminal output too.
pub fn htmlEntitiesAreUnescapedInColorMode() !void {
    const gpa = std.heap.page_allocator;

    const out = try term.renderDoc(gpa, "a < b & b > a", true);
    defer gpa.free(out);

    try testz.expectTrue(std.mem.indexOf(u8, out, "a < b & b > a") != null);
    try testz.expectTrue(std.mem.indexOf(u8, out, "&lt;") == null);
    try testz.expectTrue(std.mem.indexOf(u8, out, "&amp;") == null);
    try testz.expectTrue(std.mem.indexOf(u8, out, "&gt;") == null);
}

pub fn htmlEntitiesAreUnescapedInPlainMode() !void {
    const gpa = std.heap.page_allocator;

    const out = try term.renderDoc(gpa, "a < b & b > a", false);
    defer gpa.free(out);

    try testz.expectTrue(std.mem.indexOf(u8, out, "a < b & b > a") != null);
    try testz.expectTrue(std.mem.indexOf(u8, out, "&lt;") == null);
}
