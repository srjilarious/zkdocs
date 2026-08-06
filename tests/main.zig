//* -- collapsed: Imports --
const std = @import("std");
const testz = @import("testz");
const zkdocs = @import("zkdocs");
const symbols = zkdocs.symbols;
const markdown = zkdocs.markdown;
const render = zkdocs.render;
const example = zkdocs.example;
const emoji = zkdocs.emoji;
const highlight = markdown.highlight;
//* ---

//* -- collapsed: Helper methods --
fn findModule(mods: []const symbols.Module, name: []const u8) ?symbols.Module {
    for (mods) |m| {
        if (std.mem.eql(u8, m.name, name)) return m;
    }
    return null;
}

fn findSymbol(syms: []const symbols.Symbol, kind: symbols.SymbolKind, name: []const u8) ?symbols.Symbol {
    for (syms) |sym| {
        if (@as(symbols.SymbolKind, sym) != kind) continue;
        const sym_name = switch (sym) {
            .function => |f| f.name,
            .variable => |v| v.name,
            .container => |c| c.name,
            .@"test", .other => continue,
        };
        if (std.mem.eql(u8, sym_name, name)) return sym;
    }
    return null;
}

var g_Io: std.Io = undefined;

//* ---

//* The following tests module checks that the `symbols` module correctly extracts information from Zig source files, and that the `markdown` and `render` modules correctly handle doc comments and link resolution. The tests use a sample Zig file `sample.zig` which contains various constructs to test against.

const FunctionTests = struct {
    pub fn addFunctionIsExtracted() !void {
        const gpa = std.heap.page_allocator;

        const mods = try symbols.extractModuleGraph(g_Io, gpa, "sample.zig");
        defer symbols.deinitModules(gpa, mods);

        const sample = findModule(mods, "sample") orelse return error.SampleModuleNotFound;
        const sym = findSymbol(sample.symbols.items, .function, "add") orelse {
            return error.SymbolNotFound;
        };
        const f = sym.function;
        try testz.expectTrue(f.is_pub);
        try testz.expectEqual(f.params.len, 2);
        try testz.expectEqualStr(f.params[0].name.?, "a");
        try testz.expectEqualStr(f.return_type_src.?, "i32");
    }

    pub fn privateHelperIsExtracted() !void {
        const gpa = std.heap.page_allocator;

        const mods = try symbols.extractModuleGraph(g_Io, gpa, "sample.zig");
        defer symbols.deinitModules(gpa, mods);

        const sample = findModule(mods, "sample") orelse return error.SampleModuleNotFound;
        const sym = findSymbol(sample.symbols.items, .function, "privateHelper") orelse {
            return error.SymbolNotFound;
        };
        try testz.expectTrue(!sym.function.is_pub);
    }
};

// ---------------------------------------------------------------------------
// Tests: doc comment extraction
// ---------------------------------------------------------------------------

const DocTests = struct {
    pub fn singleLineDoc() !void {
        const gpa = std.heap.page_allocator;

        const mods = try symbols.extractModuleGraph(g_Io, gpa, "sample.zig");
        defer symbols.deinitModules(gpa, mods);

        const sample = findModule(mods, "sample") orelse return error.SampleModuleNotFound;
        const sym = findSymbol(sample.symbols.items, .function, "sub") orelse {
            return error.SymbolNotFound;
        };
        const doc = sym.function.doc orelse return error.NoDoc;
        try testz.expectEqualStr(doc, "Subtracts `b` from `a`.");
    }

    pub fn multiLineDoc() !void {
        const gpa = std.heap.page_allocator;

        const mods = try symbols.extractModuleGraph(g_Io, gpa, "sample.zig");
        defer symbols.deinitModules(gpa, mods);

        const sample = findModule(mods, "sample") orelse return error.SampleModuleNotFound;
        const sym = findSymbol(sample.symbols.items, .function, "add") orelse {
            return error.SymbolNotFound;
        };
        const doc = sym.function.doc orelse return error.NoDoc;
        try testz.expectTrue(std.mem.startsWith(u8, doc, "Adds two integers"));
        try testz.expectTrue(std.mem.indexOf(u8, doc, "Returns the sum") != null);
    }

    pub fn noDocForPrivate() !void {
        const gpa = std.heap.page_allocator;

        const mods = try symbols.extractModuleGraph(g_Io, gpa, "sample.zig");
        defer symbols.deinitModules(gpa, mods);

        const sample = findModule(mods, "sample") orelse return error.SampleModuleNotFound;
        const sym = findSymbol(sample.symbols.items, .function, "privateHelper") orelse {
            return error.SymbolNotFound;
        };
        try testz.expectTrue(sym.function.doc == null);
    }
};

//* This module checks that the `symbols` module correctly follows imports and extracts symbols from multiple modules, not just the root. The `sample.zig` file imports a `math.zig` module, so we check that symbols from `math.zig` are also extracted and that their properties (like `pub`) are correct.
const ContainerTests = struct {
    pub fn structFieldsExtracted() !void {
        const gpa = std.heap.page_allocator;

        const mods = try symbols.extractModuleGraph(g_Io, gpa, "sample.zig");
        defer symbols.deinitModules(gpa, mods);

        const sample = findModule(mods, "sample") orelse return error.SampleModuleNotFound;
        const sym = findSymbol(sample.symbols.items, .container, "Point") orelse {
            return error.SymbolNotFound;
        };
        const c = sym.container;
        try testz.expectTrue(c.is_pub);
        try testz.expectEqual(@intFromEnum(c.kind), @intFromEnum(symbols.ContainerKind.@"struct"));
        try testz.expectEqual(c.fields.len, 2);
        try testz.expectEqualStr(c.fields[0].name, "x");
        try testz.expectEqualStr(c.fields[1].name, "y");
    }

    pub fn structMethodsExtracted() !void {
        const gpa = std.heap.page_allocator;

        const mods = try symbols.extractModuleGraph(g_Io, gpa, "sample.zig");
        defer symbols.deinitModules(gpa, mods);

        const sample = findModule(mods, "sample") orelse return error.SampleModuleNotFound;
        const sym = findSymbol(sample.symbols.items, .container, "Point") orelse {
            return error.SymbolNotFound;
        };
        const c = sym.container;
        try testz.expectTrue(c.decls.items.len >= 2);
        // zero() and translate() should be present
        var found_zero = false;
        var found_translate = false;
        for (c.decls.items) |decl| {
            if (decl == .function) {
                const f = decl.function;
                if (std.mem.eql(u8, f.name, "zero")) found_zero = true;
                if (std.mem.eql(u8, f.name, "translate")) found_translate = true;
            }
        }
        try testz.expectTrue(found_zero);
        try testz.expectTrue(found_translate);
    }

    pub fn enumFieldsExtracted() !void {
        const gpa = std.heap.page_allocator;

        const mods = try symbols.extractModuleGraph(g_Io, gpa, "sample.zig");
        defer symbols.deinitModules(gpa, mods);

        const sample = findModule(mods, "sample") orelse return error.SampleModuleNotFound;
        const sym = findSymbol(sample.symbols.items, .container, "Color") orelse {
            return error.SymbolNotFound;
        };
        const c = sym.container;
        try testz.expectEqual(@intFromEnum(c.kind), @intFromEnum(symbols.ContainerKind.@"enum"));
        try testz.expectEqual(c.fields.len, 3);
        try testz.expectEqualStr(c.fields[0].name, "red");
        try testz.expectEqualStr(c.fields[1].name, "green");
        try testz.expectEqualStr(c.fields[2].name, "blue");
    }
};

//* This test module checks that the `symbols` module correctly follows imports and extracts symbols from multiple modules, not just the root file.
const ImportTests = struct {
    pub fn mathModuleFollowed() !void {
        const gpa = std.heap.page_allocator;

        const mods = try symbols.extractModuleGraph(g_Io, gpa, "sample.zig");
        defer symbols.deinitModules(gpa, mods);

        // Should have at least two modules: sample and math
        try testz.expectTrue(mods.len >= 2);

        // Find the math module
        var found_math = false;
        for (mods) |mod| {
            if (std.mem.eql(u8, mod.name, "math")) {
                found_math = true;
                // math.zig exports multiply, divide, clamp, Vec2
                const mul = findSymbol(mod.symbols.items, .function, "multiply") orelse {
                    return error.SymbolNotFound;
                };
                try testz.expectTrue(mul.function.is_pub);
            }
        }
        try testz.expectTrue(found_math);
    }

    pub fn vec2ContainerInMath() !void {
        const gpa = std.heap.page_allocator;

        const mods = try symbols.extractModuleGraph(g_Io, gpa, "sample.zig");
        defer symbols.deinitModules(gpa, mods);

        for (mods) |mod| {
            if (!std.mem.eql(u8, mod.name, "math")) continue;
            const sym = findSymbol(mod.symbols.items, .container, "Vec2") orelse {
                return error.SymbolNotFound;
            };
            const c = sym.container;
            try testz.expectEqual(c.fields.len, 2);
            return;
        }
        return error.MathModuleNotFound;
    }

    pub fn missingImportReturnsErrorNotCrash() !void {
        const gpa = std.heap.page_allocator;

        // Regression test for a double-free: extracting a module whose
        // import can't be read must surface an error, not abort the
        // process (verified with DebugAllocator prior to the fix).
        const result = symbols.extractModuleGraph(g_Io, gpa, "bad_import.zig");
        if (result) |mods| {
            symbols.deinitModules(gpa, mods);
            return error.ExpectedMissingImportError;
        } else |_| {}
    }
};

//* These tests check that the `markdown` module correctly handles various edge cases in Markdown rendering, such as embedded code fences, inline code escaping, and sequential fences. The tests verify that the output HTML is structured correctly and that special characters are escaped as needed. One test also checks that doc-comment lines starting with `///` inside code blocks are not mistakenly rendered as italics.
const MarkdownTests = struct {
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

        const mods = try symbols.extractModuleGraph(g_Io, gpa, "sample.zig");
        defer symbols.deinitModules(gpa, mods);

        const sample = findModule(mods, "sample") orelse return error.SampleModuleNotFound;
        const sym = findSymbol(sample.symbols.items, .container, "SequentialFenceExample") orelse
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
};

//* This module checks that the `symbols` module correctly follows imports and extracts symbols from multiple modules, not just the root file. The `sample.zig` file imports a `math.zig` module, so we check that symbols from `math.zig` are also extracted and that their properties (like `pub`) are correct.
const RenderTests = struct {
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
};

//* This module checks that prose lines in example zig files are handled properly. The `example` module should join adjacent non-empty lines into a single prose segment, but a blank line should create a paragraph break (double newline). Heading lines should start on their own line, and indented lines should track their indent level and flush the current segment when the indent changes.
const ExampleTests = struct {
    /// Adjacent non-empty prose lines are joined with a space, not separated
    /// into individual paragraphs.
    pub fn proseLinesJoinedWithSpace() !void {
        const gpa = std.heap.page_allocator;

        const src =
            \\//* First sentence of the paragraph.
            \\//* Second sentence on the next line.
            \\//* Third sentence still same paragraph.
        ;
        const segs = try example.parse(gpa, src);
        defer {
            example.freeSegments(gpa, segs);
            gpa.free(segs);
        }

        try testz.expectEqual(segs.len, 1);
        try testz.expectEqual(segs[0].kind, example.SegmentKind.prose);
        // All three sentences should be in a single prose segment joined by spaces.
        try testz.expectTrue(std.mem.indexOf(u8, segs[0].text, "First sentence") != null);
        try testz.expectTrue(std.mem.indexOf(u8, segs[0].text, "Second sentence") != null);
        try testz.expectTrue(std.mem.indexOf(u8, segs[0].text, "Third sentence") != null);
        // Must NOT contain a bare newline between the sentences (would cause paragraph split).
        const first_pos = std.mem.indexOf(u8, segs[0].text, "First sentence").?;
        const second_pos = std.mem.indexOf(u8, segs[0].text, "Second sentence").?;
        const between = segs[0].text[first_pos..second_pos];
        try testz.expectTrue(std.mem.indexOf(u8, between, "\n") == null);
    }

    /// A blank //* line creates a paragraph break (two newlines in the text).
    pub fn blankLineCreatesParagraphBreak() !void {
        const gpa = std.heap.page_allocator;

        const src =
            \\//* First paragraph text.
            \\//*
            \\//* Second paragraph text.
        ;
        const segs = try example.parse(gpa, src);
        defer {
            example.freeSegments(gpa, segs);
            gpa.free(segs);
        }

        try testz.expectEqual(segs.len, 1);
        // The single prose segment should contain a double newline between the paragraphs.
        try testz.expectTrue(std.mem.indexOf(u8, segs[0].text, "\n\n") != null);
    }

    /// A heading line (//* # ...) always starts on its own line, not joined
    /// with the preceding prose.
    pub fn headingStartsOnNewLine() !void {
        const gpa = std.heap.page_allocator;

        const src =
            \\//* Some intro text.
            \\//* # The Heading
            \\//* Text after heading.
        ;
        const segs = try example.parse(gpa, src);
        defer {
            example.freeSegments(gpa, segs);
            gpa.free(segs);
        }

        try testz.expectEqual(segs.len, 1);
        // The heading must start on its own line (preceded by \n, not a space).
        const heading_pos = std.mem.indexOf(u8, segs[0].text, "# The Heading").?;
        try testz.expectTrue(heading_pos == 0 or segs[0].text[heading_pos - 1] == '\n');
    }

    /// Indented //* lines produce separate segments with the correct indent
    /// count; a change in indent flushes the current segment.
    pub fn indentedProseTracksIndent() !void {
        const gpa = std.heap.page_allocator;

        const src =
            \\//* Top-level prose.
            \\    //* Indented prose inside function.
            \\    //* Still indented.
            \\//* Back to top level.
        ;
        const segs = try example.parse(gpa, src);
        defer {
            example.freeSegments(gpa, segs);
            gpa.free(segs);
        }

        // Three prose segments: indent 0, indent 4, indent 0.
        try testz.expectEqual(segs.len, 3);
        try testz.expectEqual(segs[0].indent, 0);
        try testz.expectEqual(segs[1].indent, 4);
        // The two indented lines should be joined into one segment.
        try testz.expectTrue(std.mem.indexOf(u8, segs[1].text, "Indented prose") != null);
        try testz.expectTrue(std.mem.indexOf(u8, segs[1].text, "Still indented") != null);
        try testz.expectEqual(segs[2].indent, 0);
    }
};

//* These tests exercise `render.renderSite` end to end against a synthetic,
//* two-levels-deep nested page tree (section containing a section containing
//* a page entry). They guard against the class of bug fixed in the page
//* rendering, search index, and home-entry lookup walks: a one-level-only
//* walk over `PageNavItem` silently drops anything nested further down.
const RenderSiteTests = struct {
    /// Builds a `Section -> Section -> entry` tree. The leaf entry's
    /// `src_path` points at a real repo file (`sample.zig`) so cache
    /// recording has something real to stat.
    fn buildNestedPages(deep_items: *[1]render.PageNavItem, inner_items: *[1]render.PageNavItem) [1]render.PageNavItem {
        deep_items[0] = .{ .entry = .{
            .slug = "deep",
            .title = "Deep Page",
            .content = "# Deep\n\nHello from deep.",
            .src_path = "sample.zig",
            .mode = .markdown,
        } };
        inner_items[0] = .{ .section = .{ .title = "Inner", .items = deep_items } };
        return .{.{ .section = .{ .title = "Outer", .items = inner_items } }};
    }

    pub fn nestedPageIsRenderedToDisk() !void {
        const gpa = std.heap.page_allocator;

        var deep_items: [1]render.PageNavItem = undefined;
        var inner_items: [1]render.PageNavItem = undefined;
        var pages = buildNestedPages(&deep_items, &inner_items);

        var progress = render.Progress.init(10);
        var cache = render.cache_mod.Cache.init(g_Io, gpa);
        defer cache.deinit();

        const out_dir = "test_tmp_render_nested_disk";
        defer std.Io.Dir.cwd().deleteTree(g_Io, out_dir) catch {};

        try render.renderSite(g_Io, gpa, .{
            .out_path = out_dir,
            .project_name = "Test",
            .mods = &.{},
            .pages = &pages,
            .emoji_provider = .unicode,
            .theme = .default,
            .progress = &progress,
            .conf_dir = null,
            .home_slug = null,
            .cache = &cache,
            .conf_abs_path = null,
            .show_imports = false,
            .repo_url = null,
        });

        // The page nested two sections deep must actually be written to disk.
        const page_path = try std.fmt.allocPrint(gpa, "{s}/page/deep.html", .{out_dir});
        defer gpa.free(page_path);
        const content = std.Io.Dir.cwd().readFileAlloc(g_Io, page_path, gpa, .limited(64 * 1024)) catch {
            return error.DeepPageNotRendered;
        };
        defer gpa.free(content);
        try testz.expectTrue(std.mem.indexOf(u8, content, "Hello from deep") != null);

        // The search index must include it too.
        const search_path = try std.fmt.allocPrint(gpa, "{s}/assets/search-data.js", .{out_dir});
        defer gpa.free(search_path);
        const search_data = try std.Io.Dir.cwd().readFileAlloc(g_Io, search_path, gpa, .limited(1024 * 1024));
        defer gpa.free(search_data);
        try testz.expectTrue(std.mem.indexOf(u8, search_data, "page/deep.html") != null);

        // The cache must record the nested guide, so a later incremental
        // rebuild doesn't silently skip re-rendering it.
        try testz.expectTrue(cache.guides.contains("sample.zig"));
    }

    pub fn homeSlugIsFoundWhenNestedInSection() !void {
        const gpa = std.heap.page_allocator;

        var deep_items: [1]render.PageNavItem = undefined;
        var inner_items: [1]render.PageNavItem = undefined;
        var pages = buildNestedPages(&deep_items, &inner_items);

        var progress = render.Progress.init(10);
        var cache = render.cache_mod.Cache.init(g_Io, gpa);
        defer cache.deinit();

        const out_dir = "test_tmp_render_nested_home";
        defer std.Io.Dir.cwd().deleteTree(g_Io, out_dir) catch {};

        try render.renderSite(g_Io, gpa, .{
            .out_path = out_dir,
            .project_name = "Test",
            .mods = &.{},
            .pages = &pages,
            .emoji_provider = .unicode,
            .theme = .default,
            .progress = &progress,
            .conf_dir = null,
            // "deep" is nested two sections down; the home lookup must find
            // it there instead of falling back to the default module listing.
            .home_slug = "deep",
            .cache = &cache,
            .conf_abs_path = null,
            .show_imports = false,
            .repo_url = null,
        });

        const index_path = try std.fmt.allocPrint(gpa, "{s}/index.html", .{out_dir});
        defer gpa.free(index_path);
        const content = try std.Io.Dir.cwd().readFileAlloc(g_Io, index_path, gpa, .limited(64 * 1024));
        defer gpa.free(content);
        try testz.expectTrue(std.mem.indexOf(u8, content, "Hello from deep") != null);
    }

    /// The per-page "On this page" TOC scans raw markdown for `## ` lines.
    /// A `## ` line inside a fenced code block (e.g. a snippet showing
    /// someone else's markdown) must not be fence-blind and land in the TOC
    /// alongside real headings.
    pub fn tocSkipsHeadingSyntaxInsideFence() !void {
        const gpa = std.heap.page_allocator;

        var items: [1]render.PageNavItem = .{.{ .entry = .{
            .slug = "toc-fence",
            .title = "TOC Fence",
            .content =
            \\# Title
            \\
            \\## Real Heading
            \\
            \\```
            \\## Fake Heading
            \\```
            \\
            \\## Another Real Heading
            ,
            .src_path = "sample.zig",
            .mode = .markdown,
        } }};

        var progress = render.Progress.init(10);
        var cache = render.cache_mod.Cache.init(g_Io, gpa);
        defer cache.deinit();

        const out_dir = "test_tmp_render_toc_fence";
        defer std.Io.Dir.cwd().deleteTree(g_Io, out_dir) catch {};

        try render.renderSite(g_Io, gpa, .{
            .out_path = out_dir,
            .project_name = "Test",
            .mods = &.{},
            .pages = &items,
            .emoji_provider = .unicode,
            .theme = .default,
            .progress = &progress,
            .conf_dir = null,
            .home_slug = null,
            .cache = &cache,
            .conf_abs_path = null,
            .show_imports = false,
            .repo_url = null,
        });

        const page_path = try std.fmt.allocPrint(gpa, "{s}/page/toc-fence.html", .{out_dir});
        defer gpa.free(page_path);
        const content = try std.Io.Dir.cwd().readFileAlloc(g_Io, page_path, gpa, .limited(64 * 1024));
        defer gpa.free(content);

        const toc_start = std.mem.indexOf(u8, content, "page-toc") orelse return error.NoToc;
        const toc_end = std.mem.indexOf(u8, content[toc_start..], "</aside>") orelse return error.NoTocEnd;
        const toc = content[toc_start .. toc_start + toc_end];

        try testz.expectTrue(std.mem.indexOf(u8, toc, "Real Heading") != null);
        try testz.expectTrue(std.mem.indexOf(u8, toc, "Another Real Heading") != null);
        try testz.expectTrue(std.mem.indexOf(u8, toc, "Fake Heading") == null);
    }
};

//* These tests exercise the on-disk build cache directly: a save/load round
//* trip must preserve recorded mtimes, and a cache written by a different
//* zkdocs binary version must be treated as stale rather than silently
//* served (the regression this guards: pages generated by an old binary
//* kept the old footer/markup forever because only the cache schema
//* version, not the zkdocs version, invalidated the cache).
const CacheTests = struct {
    pub fn saveLoadRoundTripPreservesSources() !void {
        const gpa = std.heap.page_allocator;
        const dir = "test_tmp_cache_roundtrip";
        defer std.Io.Dir.cwd().deleteTree(g_Io, dir) catch {};
        try std.Io.Dir.cwd().createDirPath(g_Io, dir);

        {
            var cache = render.cache_mod.Cache.init(g_Io, gpa);
            defer cache.deinit();
            try cache.recordSource("sample.zig");
            try cache.save(dir);
        }

        var loaded = render.cache_mod.Cache.load(g_Io, gpa, dir);
        defer loaded.deinit();
        try testz.expectTrue(loaded.sourceUnchanged("sample.zig"));
    }

    pub fn mismatchedAppVersionInvalidatesCache() !void {
        const gpa = std.heap.page_allocator;
        const dir = "test_tmp_cache_version";
        defer std.Io.Dir.cwd().deleteTree(g_Io, dir) catch {};
        try std.Io.Dir.cwd().createDirPath(g_Io, dir);

        {
            var cache = render.cache_mod.Cache.init(g_Io, gpa);
            defer cache.deinit();
            try cache.recordSource("sample.zig");
            try cache.save(dir);
        }

        // Corrupt the persisted app_ver so it can never match the running
        // binary's version, simulating a cache left behind by an older build.
        const cache_path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, render.cache_mod.CACHE_FILENAME });
        defer gpa.free(cache_path);
        const raw = try std.Io.Dir.cwd().readFileAlloc(g_Io, cache_path, gpa, .limited(64 * 1024));
        defer gpa.free(raw);
        const patched = try std.mem.replaceOwned(u8, gpa, raw, "\"app_ver\":\"", "\"app_ver\":\"stale-binary-");
        defer gpa.free(patched);
        {
            const f = try std.Io.Dir.cwd().createFile(g_Io, cache_path, .{});
            defer f.close(g_Io);
            try f.writeStreamingAll(g_Io, patched);
        }

        var loaded = render.cache_mod.Cache.load(g_Io, gpa, dir);
        defer loaded.deinit();
        // A version mismatch must fall back to an empty cache instead of
        // reusing the previous (now stale) run's recorded mtimes.
        try testz.expectFalse(loaded.sourceUnchanged("sample.zig"));
    }
};

//* These tests cover `emoji.replaceInHtml`, which had no test coverage at
//* all: shortcode lookup, the `none` provider passthrough, and the
//* documented (but previously unverified) behavior that shortcodes inside
//* `<code>`/`<pre>` are left untouched so code samples aren't mangled.
const EmojiTests = struct {
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
};

//* These tests cover `highlight.zig` (tree-sitter syntax highlighting), which
//* had no test coverage at all: the tree-sitter Zig path, the JSON path, and
//* the escaped-plain-text fallback for a language with no grammar.
const HighlightTests = struct {
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
};

//* These tests cover `conf.zig` (`zkdocs.conf` parsing), which had no direct
//* test coverage at all — only ever exercised indirectly by hand-running the
//* CLI. `stripJsonComments` and `loadSiteConf` are exactly the functions
//* touched when the render.zig split pulled config loading into its own file.
const ConfTests = struct {
    pub fn stripJsonCommentsBlanksCommentLinesButKeepsLineCount() !void {
        const gpa = std.heap.page_allocator;

        const src = "{\n  // a comment\n  \"a\": 1\n}\n";
        const stripped = try render.stripJsonComments(gpa, src);
        defer gpa.free(stripped);

        try testz.expectTrue(std.mem.indexOf(u8, stripped, "comment") == null);
        try testz.expectTrue(std.mem.indexOf(u8, stripped, "\"a\": 1") != null);
        // Line 2 (0-indexed 1) held the comment and must now be blank, so
        // byte offsets for the lines around it are undisturbed.
        var lines = std.mem.splitScalar(u8, stripped, '\n');
        _ = lines.next();
        try testz.expectEqualStr(lines.next().?, "");
        // The result must still be valid JSON once comments are gone.
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, stripped, .{});
        defer parsed.deinit();
    }

    pub fn loadSiteConfParsesUnifiedPagesFormat() !void {
        const gpa = std.heap.page_allocator;
        const dir = "test_tmp_conf_unified";
        defer std.Io.Dir.cwd().deleteTree(g_Io, dir) catch {};
        try std.Io.Dir.cwd().createDirPath(g_Io, dir);

        {
            const f = try std.Io.Dir.cwd().createFile(g_Io, dir ++ "/guide.md", .{});
            defer f.close(g_Io);
            try f.writeStreamingAll(g_Io, "# Guide Title\n\nHello.\n");
        }
        const conf_path = dir ++ "/zkdocs.conf";
        {
            const f = try std.Io.Dir.cwd().createFile(g_Io, conf_path, .{});
            defer f.close(g_Io);
            try f.writeStreamingAll(g_Io,
                \\{
                \\  // top-level project settings
                \\  "name": "Widgets",
                \\  "theme": "monokai",
                \\  "home": "guide",
                \\  "pages": [
                \\    { "src": "guide.md" }
                \\  ]
                \\}
            );
        }

        var conf = try render.loadSiteConf(g_Io, gpa, conf_path);
        defer conf.deinit(gpa);

        try testz.expectEqualStr(conf.name.?, "Widgets");
        try testz.expectEqual(conf.theme, .monokai);
        try testz.expectEqualStr(conf.home_slug.?, "guide");
        try testz.expectEqual(conf.pages.len, 1);
        try testz.expectEqualStr(conf.pages[0].entry.title, "Guide Title");
        try testz.expectEqualStr(conf.pages[0].entry.slug, "guide");
    }

    pub fn loadSiteConfParsesLegacyGuidesAndExamplesFormat() !void {
        const gpa = std.heap.page_allocator;
        const dir = "test_tmp_conf_legacy";
        defer std.Io.Dir.cwd().deleteTree(g_Io, dir) catch {};
        try std.Io.Dir.cwd().createDirPath(g_Io, dir);

        {
            const f = try std.Io.Dir.cwd().createFile(g_Io, dir ++ "/legacy.md", .{});
            defer f.close(g_Io);
            try f.writeStreamingAll(g_Io, "# Legacy Guide\n\nHello.\n");
        }
        const conf_path = dir ++ "/zkdocs.conf";
        {
            const f = try std.Io.Dir.cwd().createFile(g_Io, conf_path, .{});
            defer f.close(g_Io);
            try f.writeStreamingAll(g_Io,
                \\{
                \\  "guides": [
                \\    { "src": "legacy.md" }
                \\  ]
                \\}
            );
        }

        var conf = try render.loadSiteConf(g_Io, gpa, conf_path);
        defer conf.deinit(gpa);

        try testz.expectEqual(conf.pages.len, 1);
        try testz.expectEqualStr(conf.pages[0].entry.title, "Legacy Guide");
    }
};

//* -- collapsed: Test discovery and runner --
//* The `testz` framework uses a list of test groups and their associated modules to discover test functions to run. Each group has a name, a tag for filtering, and a reference to the module containing the tests. The `main` function then runs all discovered tests using the default `testzRunner` helper method, handling argument parsing, etc.
const DiscoveredTests = testz.discoverTests(.{
    testz.Group{ .name = "Function Extraction", .tag = "functions", .mod = FunctionTests },
    testz.Group{ .name = "Doc Comments", .tag = "docs", .mod = DocTests },
    testz.Group{ .name = "Container Extraction", .tag = "containers", .mod = ContainerTests },
    testz.Group{ .name = "Import Following", .tag = "imports", .mod = ImportTests },
    testz.Group{ .name = "Markdown Rendering", .tag = "markdown", .mod = MarkdownTests },
    testz.Group{ .name = "Render / Sym Links", .tag = "render", .mod = RenderTests },
    testz.Group{ .name = "Example Parsing", .tag = "example", .mod = ExampleTests },
    testz.Group{ .name = "Site Rendering", .tag = "render_site", .mod = RenderSiteTests },
    testz.Group{ .name = "Config Parsing", .tag = "conf", .mod = ConfTests },
    testz.Group{ .name = "Build Cache", .tag = "cache", .mod = CacheTests },
    testz.Group{ .name = "Emoji Shortcodes", .tag = "emoji", .mod = EmojiTests },
    testz.Group{ .name = "Syntax Highlighting", .tag = "highlight", .mod = HighlightTests },
}, .{});

pub fn main(init: std.process.Init) !void {
    g_Io = init.io;
    try testz.testzRunner(DiscoveredTests, init.minimal.args);
}
//* ---
