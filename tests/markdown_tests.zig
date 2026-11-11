//* These tests check that the `markdown` module correctly handles various edge cases in Markdown rendering, such as embedded code fences, inline code escaping, and sequential fences. The tests verify that the output HTML is structured correctly and that special characters are escaped as needed. One test also checks that doc-comment lines starting with `///` inside code blocks are not mistakenly rendered as italics.
const std = @import("std");
const testz = @import("testz");
const zkdocs = @import("zkdocs");
const symbols = zkdocs.symbols;
const markdown = zkdocs.markdown;
const render = zkdocs.render;
const fix = @import("fixtures.zig");

/// Code fence containing embedded ``` lines (e.g. doc-comment examples)
/// must not close the outer block prematurely.
pub fn embeddedFenceDoesNotCloseBlock() !void {
    const gpa = std.heap.page_allocator;

    const md =
        \\```zig
        \\/// ## Example
        \\///
        \\/// ```zig
        \\/// const x = foo();
        \\/// ```
        \\pub fn foo() void {}
        \\```
    ;
    const html = try markdown.toHtml(gpa, md);
    defer gpa.free(html);

    // Whole input must appear in one <pre><code> block.
    try testz.expectTrue(std.mem.indexOf(u8, html, "<pre>") != null);
    // The embedded ``` should appear as literal text, not close the block.
    try testz.expectTrue(std.mem.indexOf(u8, html, "```zig") != null);
    // There should be exactly one closing </code></pre>, not two.
    const first = std.mem.indexOf(u8, html, "</code></pre>") orelse
        return error.NoCodeBlock;
    const second = std.mem.indexOf(u8, html[first + 1 ..], "</code></pre>");
    try testz.expectTrue(second == null);
}

/// Inline code content must be HTML-escaped (no raw < > & in output).
pub fn inlineCodeIsEscaped() !void {
    const gpa = std.heap.page_allocator;

    const html = try markdown.toHtml(gpa, "use `a < b && c > 0` here");
    defer gpa.free(html);

    try testz.expectTrue(std.mem.indexOf(u8, html, "<code>") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "&lt;") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "&amp;&amp;") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "&gt;") != null);
    // Raw unescaped characters must not appear inside <code>.
    try testz.expectTrue(std.mem.indexOf(u8, html, "<code>a < b") == null);
}

/// Two sequential code fences must produce two separate code blocks with
/// any content between them rendered as a normal paragraph.
pub fn sequentialFencesProduceTwoBlocks() !void {
    const gpa = std.heap.page_allocator;

    // Use plain fences (no language tag) so content isn't split by the
    // syntax highlighter, making substring checks on content reliable.
    const md =
        \\```
        \\block_one_content
        \\```
        \\
        \\and then...
        \\
        \\```
        \\block_two_content
        \\```
    ;
    const html = try markdown.toHtml(gpa, md);
    defer gpa.free(html);

    // Must contain exactly two <pre> blocks.
    const first_pre = std.mem.indexOf(u8, html, "<pre>") orelse
        return error.NoPre;
    const second_pre = std.mem.indexOf(u8, html[first_pre + 1 ..], "<pre>");
    try testz.expectTrue(second_pre != null);

    // The middle paragraph must appear between the two blocks.
    try testz.expectTrue(std.mem.indexOf(u8, html, "and then") != null);

    // Content of both blocks must be present.
    try testz.expectTrue(std.mem.indexOf(u8, html, "block_one_content") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "block_two_content") != null);
}

/// Sequential code fences in an extracted doc comment must produce two
/// separate code blocks, not merge into one or garble the closing fence.
pub fn sequentialFencesInDocComment() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    const sample = fix.findModule(mods, "sample") orelse return error.SampleModuleNotFound;
    const sym = fix.findSymbol(sample.symbols.items, .container, "SequentialFenceExample") orelse
        return error.SymbolNotFound;
    const doc = sym.container.doc orelse return error.NoDoc;

    // The extracted doc must contain two separate fences on their own lines.
    const first_fence = std.mem.indexOf(u8, doc, "```") orelse return error.NoFence;
    const second_fence = std.mem.indexOf(u8, doc[first_fence + 3 ..], "```");
    try testz.expectTrue(second_fence != null);

    // Render to HTML and verify two <pre> blocks are produced.
    const html = try markdown.toHtml(gpa, doc);
    defer gpa.free(html);

    const first_pre = std.mem.indexOf(u8, html, "<pre>") orelse return error.NoPre;
    const second_pre = std.mem.indexOf(u8, html[first_pre + 1 ..], "<pre>");
    try testz.expectTrue(second_pre != null);
}

/// Doc-comment lines starting with `///` inside a code block must not be
/// rendered as italics (the `*` or `_` formatters must not fire inside blocks).
pub fn docCommentLinesNotItalic() !void {
    const gpa = std.heap.page_allocator;

    const md =
        \\```zig
        \\/// Returns a sorted copy of `items`.
        \\pub fn sort(items: []const i32) ![]i32 { ... }
        \\```
    ;
    const html = try markdown.toHtml(gpa, md);
    defer gpa.free(html);

    try testz.expectTrue(std.mem.indexOf(u8, html, "<i>") == null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "<em>") == null);
}

/// A real GFM table outside any fence must render as an actual <table>.
pub fn realTableRendersAsTable() !void {
    const gpa = std.heap.page_allocator;

    const md =
        \\| Name | Type |
        \\|------|------|
        \\| foo  | i32  |
    ;
    const html = try markdown.toHtml(gpa, md);
    defer gpa.free(html);

    try testz.expectTrue(std.mem.indexOf(u8, html, "<table") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "<th>Name</th>") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "<td>foo</td>") != null);
}

/// `[text](url)` inside a table cell must become a real `<a>`, and an
/// internal `sym:` link scheme must survive so `render.resolveInternalLinks`
/// (which runs over the whole page afterward) can rewrite it — table
/// cells previously only supported backtick code spans.
pub fn tableCellLinkBecomesAnchor() !void {
    const gpa = std.heap.page_allocator;

    const md =
        \\| Name | Docs |
        \\|------|------|
        \\| foo  | [Foo](sym:Foo) |
    ;
    const html = try markdown.toHtml(gpa, md);
    defer gpa.free(html);

    try testz.expectTrue(std.mem.indexOf(u8, html, "<a href=\"sym:Foo\">Foo</a>") != null);

    const resolved = try render.resolveInternalLinks(gpa, html, &.{}, "..");
    defer gpa.free(resolved);
    try testz.expectTrue(std.mem.indexOf(u8, resolved, "href=\"#sym-Foo") != null);
}

/// A code span inside a table cell must be HTML-escaped, same as a code
/// span anywhere else — zmd's own default `code` formatter doesn't
/// escape (it assumes a caller override handles that, as zkdocs's
/// top-level `codeFmt` does), so table cells need their own override.
pub fn tableCellCodeSpanIsEscaped() !void {
    const gpa = std.heap.page_allocator;

    const md =
        \\| Flag | Description |
        \\|------|------|
        \\| `--root <path>` | root source file |
    ;
    const html = try markdown.toHtml(gpa, md);
    defer gpa.free(html);

    try testz.expectTrue(std.mem.indexOf(u8, html, "<code>--root &lt;path&gt;</code>") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "<path>") == null);
}

/// Table cells now go through zmd's real inline parser (not the old
/// minimal hand-rolled renderer), so bold/italic work inside cells too.
pub fn tableCellSupportsBoldAndItalic() !void {
    const gpa = std.heap.page_allocator;

    const md =
        \\| Name | Note |
        \\|------|------|
        \\| foo  | **important** and _also this_ |
    ;
    const html = try markdown.toHtml(gpa, md);
    defer gpa.free(html);

    try testz.expectTrue(std.mem.indexOf(u8, html, "<b>important</b>") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "<i>also this</i>") != null);
}

/// A fenced code block that merely *demonstrates* GFM table syntax must
/// stay literal text inside <pre><code> — not get extracted into a real
/// <table>, and not leave a stray ZKDOCSTABLE sentinel in the output.
pub fn tableSyntaxInsideFenceIsNotExtracted() !void {
    const gpa = std.heap.page_allocator;

    const md =
        \\Example table syntax:
        \\
        \\```
        \\| Name | Type |
        \\|------|------|
        \\| foo  | i32  |
        \\```
    ;
    const html = try markdown.toHtml(gpa, md);
    defer gpa.free(html);

    try testz.expectTrue(std.mem.indexOf(u8, html, "<table") == null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "ZKDOCSTABLE") == null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "| Name | Type |") != null);
}

/// A real MkDocs-style admonition outside any fence must render as a
/// `.admonition` div.
pub fn realAdmonitionRendersAsDiv() !void {
    const gpa = std.heap.page_allocator;

    const md =
        \\!!! note "Heads up"
        \\    Body text here.
    ;
    const html = try markdown.toHtml(gpa, md);
    defer gpa.free(html);

    try testz.expectTrue(std.mem.indexOf(u8, html, "class=\"admonition note\"") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "Heads up") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "Body text here.") != null);
}

/// A fenced code block that merely *demonstrates* admonition syntax must
/// stay literal text — not get extracted into a real `.admonition` div.
pub fn admonitionSyntaxInsideFenceIsNotExtracted() !void {
    const gpa = std.heap.page_allocator;

    const md =
        \\Example admonition syntax:
        \\
        \\```
        \\!!! note "Heads up"
        \\    Body text here.
        \\```
    ;
    const html = try markdown.toHtml(gpa, md);
    defer gpa.free(html);

    try testz.expectTrue(std.mem.indexOf(u8, html, "class=\"admonition") == null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "ZKDOCSADMON") == null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "!!! note") != null);
}

/// Consecutive `=== "Label"` headers form one tab group: one label button
/// and one panel per tab, the first selected and the rest hidden, with each
/// tab's indented body rendered as markdown (here, highlighted code).
pub fn consecutiveTabHeadersFormOneGroup() !void {
    const gpa = std.heap.page_allocator;

    const md =
        \\=== "Zig"
        \\
        \\    ```zig
        \\    eng.quit();
        \\    ```
        \\
        \\=== "Python"
        \\
        \\    ```python
        \\    self.quit()
        \\    ```
        \\
        \\After the tabs.
    ;
    const html = try markdown.toHtml(gpa, md);
    defer gpa.free(html);

    try testz.expectEqual(std.mem.count(u8, html, "class=\"tabbed-set\""), 1);
    try testz.expectTrue(std.mem.indexOf(u8, html, "class=\"tabbed-label active\" role=\"tab\" aria-selected=\"true\" data-tab=\"Zig\">Zig</button>") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "data-tab=\"Python\">Python</button>") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "role=\"tabpanel\" data-tab=\"Zig\">") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "role=\"tabpanel\" data-tab=\"Python\" hidden>") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "language-zig") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "language-python") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "ZKDOCSADMON") == null);
    // Text after the group is ordinary paragraph content, outside it.
    const set_end = std.mem.lastIndexOf(u8, html, "</div></div>").?;
    const after = std.mem.indexOf(u8, html, "<p>After the tabs.</p>").?;
    try testz.expectTrue(after > set_end);
}

/// Tab groups separated by other content stay separate groups.
pub fn tabGroupsSplitByProseAreSeparate() !void {
    const gpa = std.heap.page_allocator;

    const md =
        \\=== "A"
        \\    one
        \\
        \\Between.
        \\
        \\=== "A"
        \\    two
    ;
    const html = try markdown.toHtml(gpa, md);
    defer gpa.free(html);

    try testz.expectEqual(std.mem.count(u8, html, "class=\"tabbed-set\""), 2);
}

/// Labels are escaped in both the attribute and the button text.
pub fn tabLabelsAreEscaped() !void {
    const gpa = std.heap.page_allocator;

    const md =
        \\=== "<b>&"
        \\    body
    ;
    const html = try markdown.toHtml(gpa, md);
    defer gpa.free(html);

    try testz.expectTrue(std.mem.indexOf(u8, html, "data-tab=\"&lt;b&gt;&amp;\">&lt;b&gt;&amp;</button>") != null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "<b>") == null);
}

/// A fenced code block demonstrating tab syntax stays literal.
pub fn tabSyntaxInsideFenceIsNotExtracted() !void {
    const gpa = std.heap.page_allocator;

    const md =
        \\```
        \\=== "Zig"
        \\    body
        \\```
    ;
    const html = try markdown.toHtml(gpa, md);
    defer gpa.free(html);

    try testz.expectTrue(std.mem.indexOf(u8, html, "tabbed-set") == null);
    try testz.expectTrue(std.mem.indexOf(u8, html, "=== &quot;Zig&quot;") != null or
        std.mem.indexOf(u8, html, "=== \"Zig\"") != null);
}

/// An admonition inside a tab renders inside that tab's panel.
pub fn admonitionInsideTabRenders() !void {
    const gpa = std.heap.page_allocator;

    const md =
        \\=== "Zig"
        \\
        \\    !!! note
        \\        Inside a tab.
    ;
    const html = try markdown.toHtml(gpa, md);
    defer gpa.free(html);

    const panel = std.mem.indexOf(u8, html, "role=\"tabpanel\"").?;
    const admon = std.mem.indexOf(u8, html, "class=\"admonition note\"").?;
    try testz.expectTrue(admon > panel);
    try testz.expectTrue(std.mem.indexOf(u8, html, "Inside a tab.") != null);
}
