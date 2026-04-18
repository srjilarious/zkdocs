//* -- collapsed: Imports --
const std = @import("std");
const testz = @import("testz");
const zkdocs = @import("zkdocs");
const symbols = zkdocs.symbols;
const markdown = zkdocs.markdown;
const render = zkdocs.render;
const example = zkdocs.example;
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
        if (sym.kind != kind) continue;
        const sym_name = switch (kind) {
            .function => if (sym.function) |f| f.name else continue,
            .variable => if (sym.variable) |v| v.name else continue,
            .container => if (sym.container) |c| c.name else continue,
            else => continue,
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
        const f = sym.function.?;
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
        try testz.expectTrue(!sym.function.?.is_pub);
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
        const doc = sym.function.?.doc orelse return error.NoDoc;
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
        const doc = sym.function.?.doc orelse return error.NoDoc;
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
        try testz.expectTrue(sym.function.?.doc == null);
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
        const c = sym.container.?;
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
        const c = sym.container.?;
        try testz.expectTrue(c.decls.items.len >= 2);
        // zero() and translate() should be present
        var found_zero = false;
        var found_translate = false;
        for (c.decls.items) |decl| {
            if (decl.kind == .function) {
                if (decl.function) |f| {
                    if (std.mem.eql(u8, f.name, "zero")) found_zero = true;
                    if (std.mem.eql(u8, f.name, "translate")) found_translate = true;
                }
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
        const c = sym.container.?;
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
                try testz.expectTrue(mul.function.?.is_pub);
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
            const c = sym.container.?;
            try testz.expectEqual(c.fields.len, 2);
            return;
        }
        return error.MathModuleNotFound;
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
        const doc = sym.container.?.doc orelse return error.NoDoc;

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
}, .{});

pub fn main(init: std.process.Init) !void {
    g_Io = init.io;
    try testz.testzRunner(DiscoveredTests, init.minimal.args);
}
//* ---
