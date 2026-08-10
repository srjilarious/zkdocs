//* Direct unit tests for the vendored zmd markdown parser (`src/zmd/`).
//* Previously zmd had no coverage of its own -- it was only ever exercised
//* indirectly through `markdown.toHtml`, which layers zkdocs's own
//* admonition extraction, formatter overrides, and post-processing passes
//* on top. These tests call `zmd.parse` (and, in one case, the lower-level
//* `Ast`/`Node` API it wraps) directly with zmd's own default `Formatters`,
//* so they isolate zmd's own parsing and rendering behavior.
const std = @import("std");
const testz = @import("testz");
const zkdocs = @import("zkdocs");
const zmd = zkdocs.zmd;

pub fn headingsRenderAllSixLevels() !void {
    const gpa = std.heap.page_allocator;

    const md =
        \\# One
        \\## Two
        \\### Three
        \\#### Four
        \\##### Five
        \\###### Six
    ;
    const html = try zmd.parse(gpa, md, .{});
    defer gpa.free(html);

    try testz.expectTrue(std.mem.indexOf(u8, html, "<h1>One</h1>") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "<h2>Two</h2>") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "<h3>Three</h3>") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "<h4>Four</h4>") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "<h5>Five</h5>") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "<h6>Six</h6>") != null);
}

pub fn boldAndItalicBothSyntaxesRender() !void {
    const gpa = std.heap.page_allocator;

    const html = try zmd.parse(gpa, "This is **bold** and _italic_ and *also italic*.", .{});
    defer gpa.free(html);

    try testz.expectTrue(std.mem.indexOf(u8, html, "<b>bold</b>") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "<i>italic</i>") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "<i>also italic</i>") != null);
}

/// zmd's `Default.code` formatter writes `node.content` verbatim -- it
/// assumes a caller-supplied override handles HTML-escaping, which is
/// exactly why zkdocs's own `codeFmt` in `markdown.zig` exists. Plain zmd
/// usage without an override leaves raw `<`/`>` unescaped.
pub fn inlineCodeSpanIsNotEscapedByDefaultFormatter() !void {
    const gpa = std.heap.page_allocator;

    const html = try zmd.parse(gpa, "`<script>`", .{});
    defer gpa.free(html);

    try testz.expectTrue(std.mem.indexOf(u8, html, "<script>") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "&lt;script&gt;") == null);
}

pub fn fencedCodeBlockCapturesLanguageMeta() !void {
    const gpa = std.heap.page_allocator;

    const md =
        \\```zig
        \\const x = 1;
        \\```
    ;
    const html = try zmd.parse(gpa, md, .{});
    defer gpa.free(html);

    try testz.expectTrue(std.mem.indexOf(u8, html, "language-zig") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "const x = 1;") != null);
}

pub fn fencedCodeBlockWithoutMetaHasNoLanguageClass() !void {
    const gpa = std.heap.page_allocator;

    const md =
        \\```
        \\plain text
        \\```
    ;
    const html = try zmd.parse(gpa, md, .{});
    defer gpa.free(html);

    try testz.expectTrue(std.mem.indexOf(u8, html, "plain text") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "language-") == null);
}

pub fn linkWithTitleRendersAnchor() !void {
    const gpa = std.heap.page_allocator;

    const html = try zmd.parse(gpa, "[Home](https://example.com)", .{});
    defer gpa.free(html);

    try testz.expectTrue(std.mem.indexOf(u8, html, "<a href=\"https://example.com\">Home</a>") != null);
}

/// `[](url)` -- empty brackets, no link text -- must still parse as a link,
/// just with an empty title. This is the raw zmd behavior that
/// `render.resolveInternalLinks` relies on to detect and fill in empty
/// `sym:` links.
pub fn linkWithEmptyBracketsHasEmptyLinkText() !void {
    const gpa = std.heap.page_allocator;

    const html = try zmd.parse(gpa, "[](https://example.com)", .{});
    defer gpa.free(html);

    try testz.expectTrue(std.mem.indexOf(u8, html, "<a href=\"https://example.com\"></a>") != null);
}

pub fn imageRendersImgTag() !void {
    const gpa = std.heap.page_allocator;

    const html = try zmd.parse(gpa, "![Alt text](img.png)", .{});
    defer gpa.free(html);

    try testz.expectTrue(std.mem.indexOf(u8, html, "<img src=\"img.png\" alt=\"Alt text\">") != null);
}

pub fn unorderedListSupportsAllThreeBulletSyntaxes() !void {
    const gpa = std.heap.page_allocator;

    const inputs = [_][]const u8{ "- one\n- two\n", "* one\n* two\n", "+ one\n+ two\n" };
    for (inputs) |md| {
        const html = try zmd.parse(gpa, md, .{});
        defer gpa.free(html);

        try testz.expectTrue(std.mem.indexOf(u8, html, "<ul>") != null);
        try testz.expectTrue(std.mem.indexOf(u8, html, "<li>one</li>") != null);
        try testz.expectTrue(std.mem.indexOf(u8, html, "<li>two</li>") != null);
    }
}

/// `ordered_list_item` isn't in `tokens.elements` at all -- it's matched by
/// a separate digit-prefix fallback in `Ast.firstToken`. Guards that this
/// still produces a real `<ol>`.
pub fn orderedListRendersOlWithDigitSyntax() !void {
    const gpa = std.heap.page_allocator;

    const html = try zmd.parse(gpa, "1. one\n2. two\n", .{});
    defer gpa.free(html);

    try testz.expectTrue(std.mem.indexOf(u8, html, "<ol>") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "<li>one</li>") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "<li>two</li>") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "</ol>") != null);
}

/// Covers the native GFM table path (`Ast.matchTableEnd`/`parseTable`) with
/// multiple body rows and alignment-colon separator syntax (`:---`/`---:`),
/// which the single-row table already covered at the `markdown.toHtml`
/// level doesn't exercise.
pub fn nativeTableRendersMultiRowTheadAndTbody() !void {
    const gpa = std.heap.page_allocator;

    const md =
        \\| A | B |
        \\|:---|---:|
        \\| 1 | 2 |
        \\| 3 | 4 |
    ;
    const html = try zmd.parse(gpa, md, .{});
    defer gpa.free(html);

    try testz.expectTrue(std.mem.indexOf(u8, html, "<thead>") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "<th>A</th>") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "<th>B</th>") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "</thead>") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "<tbody>") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "<td>1</td>") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "<td>4</td>") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "</tbody>") != null);
}

pub fn defaultRootFormatterWrapsFullHtmlDocument() !void {
    const gpa = std.heap.page_allocator;

    const html = try zmd.parse(gpa, "Hello.", .{});
    defer gpa.free(html);

    try testz.expectTrue(std.mem.indexOf(u8, html, "<!DOCTYPE html>") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "<body>") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "<p>Hello.</p>") != null);
}

/// Plain paragraph text (not inside a code span) goes through `Node.escape`,
/// which is separate from and unrelated to zkdocs's own `htmlEscapeInto`.
pub fn plainParagraphTextIsHtmlEscaped() !void {
    const gpa = std.heap.page_allocator;

    const html = try zmd.parse(gpa, "5 < 10 & true", .{});
    defer gpa.free(html);

    try testz.expectTrue(std.mem.indexOf(u8, html, "5 &lt; 10 &amp; true") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "5 < 10") == null);
}

fn shoutingH1(allocator: std.mem.Allocator, node: zmd.Node) ![]const u8 {
    return std.fmt.allocPrint(allocator, "<h1 class=\"custom\">{s}</h1>\n", .{node.content});
}

/// `Formatters` fields are plain function pointers with default values, so
/// any subset can be overridden while the rest fall back to `Default` --
/// this is the exact mechanism `markdown.zig` relies on for `rootFmt`/
/// `codeFmt`/etc.
pub fn customFormatterOverridesDefaultHandler() !void {
    const gpa = std.heap.page_allocator;

    const html = try zmd.parse(gpa, "# Title", .{ .h1 = shoutingH1 });
    defer gpa.free(html);

    try testz.expectTrue(std.mem.indexOf(u8, html, "<h1 class=\"custom\">Title</h1>") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "<h1>Title</h1>") == null);
}

/// Exercises `Ast.init`/`.parse`/`.deinit` and `Node.toHtml` directly,
/// instead of going through the `zmd.parse` convenience wrapper -- this is
/// the lower-level API surface `Ast.zig`'s own doc comments describe
/// (`parse()` "must call tokenize() first", which `init()` does).
pub fn astAndNodeLowLevelApiRendersDirectly() !void {
    const gpa = std.heap.page_allocator;
    const input = "# Direct\n";

    var ast = try zmd.Ast.init(gpa, input);
    defer ast.deinit(gpa);
    const root = try ast.parse(gpa);

    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try root.toHtml(gpa, input, &aw.writer, 0, .{});
    const html = try aw.toOwnedSlice();
    defer gpa.free(html);

    try testz.expectTrue(std.mem.indexOf(u8, html, "<h1>Direct</h1>") != null);
}

pub fn tableTokenConstantIsTypedTableAndClearing() !void {
    try testz.expectEqual(zmd.tokens.Table.type, zmd.tokens.ElementType.table);
    try testz.expectTrue(zmd.tokens.Table.clear);
}
