---
name: zkdocs Zig Doc Generator
overview: "A MkDocs-like static site generator for Zig projects: extracts symbols and doc comments from Zig source via std.zig.Ast, renders markdown with zmd, highlights code with tree-sitter-zig, and produces a styled static HTML site."
---

# zkdocs: Zig Documentation Generator — Implementation Plan

## Architecture overview

```
Input
  ├── Root .zig file  ──→  @import follower  ──→  Module graph (N .zig files)
  │                            │
  │                            └──→ std.zig.Ast per file  ──→  Symbol tree
  │                                                              │
  └── .md doc files  ──────────────────────────────────────────→┤
                                                                 │
                                                           HTML renderer
                                                                 │
                                                         Static site output/
                                                           ├── index.html
                                                           ├── <module>.html
                                                           ├── <doc-page>.html
                                                           └── style.css
```

### Data flow detail

```
.zig files ──→ Ast.parse ──→ Symbol walker ──→ Symbol tree
                                                    │
.md files  ──→ zmd ──→ HTML fragment ───────────────┤
                │                                   │
                └── code blocks ──→ tree-sitter ────┤
                                                    │
                                             HTML templates ──→ site/
```

---

## Input model (CLI-first, import-following)

**Do not** couple directly to the Zig build system upfront. Instead:

- Primary CLI: `zkdocs --root src/root.zig --name MyLib --out docs/`
- The tool resolves the full module graph by following relative `@import("./relative.zig")` calls
  recursively from the root file. Absolute imports (`@import("std")`, `@import("builtin")`) are skipped.
- This gives the same result as "give me a module" without requiring build system integration.
- Optional config file (`zkdocs.zig.zon` or `zkdocs.zon`) for project-level settings.

Build system integration comes later (Phase 6) as a thin wrapper that runs the CLI binary as a
`RunStep` in the target project's `build.zig`.

---

## Current state (as of initial commit)

### What exists
- `src/symbols.zig` — AST extraction skeleton. Handles: `fn_decl`, all `fn_proto_*`, all
  `container_decl_*`/`tagged_union_*`, and all `var_decl` variants. Extracts doc comments (partial),
  visibility, params, and return types.
- `src/main.zig` — hardcoded to read `sample.zig`, parses, prints symbol tree to stderr.
- `sample.zig` — minimal test fixture.
- `build.zig` — skeleton; stub `build_step` that does nothing yet.
- No dependencies in `build.zig.zon`.

### Known bugs to fix in Phase 1
1. **Container name is wrong** (`symbols.zig:217`): uses `container_decl.ast.main_token` which is the
   keyword token (`struct`, `enum`, etc.), not the name. Names live on the enclosing `var_decl` node.
2. **Doc comment collection is incomplete** (`symbols.zig:50-64`): grabs one token and checks for
   `string_literal` (wrong tag) or `doc_comment`. Needs to scan backwards collecting all consecutive
   `doc_comment` tokens, strip `/// ` prefix, and join with `\n`.
3. **No import following**: only processes `rootDecls()` of the single given file.
4. **Container members not extracted**: container recursion is a stub (members list is always empty).
5. **No HTML output**: only debug prints.

---

## Phases

### Phase 1 — Fix and complete AST extraction

Goal: correct, complete in-memory symbol tree from a set of .zig files.

#### 1.1 Fix doc comment extraction
- Scan backwards from `first_token` collecting all consecutive `.doc_comment` tokens.
- For each token, strip the leading `/// ` prefix (or `//! ` for module-level).
- Join with `\n` and store as the doc string.
- Remove the `string_literal` check (wrong).

#### 1.2 Fix container naming
- Container nodes (`struct`, `enum`, `union`) get their name from the enclosing `var_decl`.
- When processing a `var_decl` whose init expression is a container, use the var name as the
  container's name, and recurse into the container's members.
- Remove the current container extraction branch that reads `main_token`.

#### 1.3 Extract container members
- For each container, iterate `container_decl.ast.members` (a slice of `Node.Index`).
- For each member, switch on `nodeTag` and extract:
  - Fields: `container_field`, `container_field_init`, `container_field_align` → name + type
  - Nested functions: `fn_decl` and `fn_proto_*` → same as root-level function extraction
  - Nested types: `var_decl` whose init is a container → recurse
- Store extracted members in `Container.members`.

#### 1.4 Add `@import` following
- After extracting root decls of the root file, scan all `var_decl` init expressions for
  `@import("./relative/path.zig")` calls (builtin_call nodes with name `import`).
- Resolve relative to the current file's directory.
- Skip if the import string does not start with `.` (i.e. skip std, builtin, package imports).
- Keep a visited set (by absolute path) to avoid cycles.
- Parse each discovered file and extract its module, adding it to a `[]Module` result.

#### 1.5 Enum member extraction
- For `tagged_union` and union-with-enum, extract enum fields as named members.

#### Deliverable
`extractModuleGraph(allocator, root_path) ![]Module` — returns one `Module` per .zig file reachable
from root via relative imports.

---

### Phase 2 — CLI interface and config

Goal: replace hardcoded `sample.zig` with a real CLI; add optional config.

#### 2.1 CLI arg parsing
- Use `std.process.argsAlloc` + manual parsing (no dep).
- Flags: `--root <path>`, `--name <string>`, `--out <dir>` (default: `docs/`).
- Print usage on bad args.
- Sub-commands: `zkdocs build` (generate), `zkdocs init` (scaffold config).

#### 2.2 Config file (`zkdocs.zon`)
```zig
.{
    .name = "MyLib",
    .root = "src/root.zig",
    .out = "docs",
    .docs_dir = "docs-src",   // directory with .md tutorial pages
    .nav = .{                  // ordered nav entries
        .{ .label = "Guide",   .file = "guide.md" },
        .{ .label = "API",     .module = "root" },
    },
}
```
- Parse with `std.zig.Zon` or a hand-rolled parser.
- CLI flags override config values.

#### 2.3 Wire `build_step`
- `build.zig`: `build_step` runs `zkdocs build` as a `RunStep` in the project's own docs.

---

### Phase 3 — HTML output skeleton

Goal: produce navigable (unstyled or minimally styled) HTML from the symbol tree.

#### 3.1 Output structure
```
out/
  index.html          ← module list + project overview
  api/<module>.html   ← one page per .zig file
  guide/<page>.html   ← one page per .md file
  style.css
```

#### 3.2 HTML renderer (`src/render.zig`)
- A struct with a `Writer` and helper methods: `writeHeader`, `writeNav`, `writeFooter`.
- `renderModule(module: Module) !void` — emits sections for each public symbol:
  - `<section class="fn">` with signature, param table, return type, and doc text.
  - `<section class="type">` for containers with field table.
  - `<section class="const">` for variables.
- `renderIndex(modules: []Module) !void` — list of modules with first-sentence doc previews.
- Escape HTML in all user-sourced text.

#### 3.3 CSS (`src/style.css`, embedded with `@embedFile`)
- Minimal but clean: sidebar nav, content area, code blocks, type signatures.
- Define `.hl-keyword`, `.hl-function`, `.hl-type`, `.hl-comment`, `.hl-string`, `.hl-number` for
  later tree-sitter integration.

#### Deliverable
`zig build run -- --root sample.zig --name Sample --out /tmp/docs` produces a browsable site.

---

### Phase 4 — Markdown pipeline

Goal: render `///` doc comments and `.md` tutorial pages as HTML.

#### 4.1 Add `zmd` dependency
```zig
// build.zig.zon
.dependencies = .{
    .zmd = .{ .url = "...", .hash = "..." },
},
```
```zig
// build.zig
const zmd = b.dependency("zmd", .{});
exe.root_module.addImport("zmd", zmd.module("zmd"));
```

#### 4.2 Render doc comments
- Pass each symbol's `doc` string through `zmd.parse(allocator, doc, .{})` → HTML fragment.
- Emit that fragment inside the symbol's `<section>` in the renderer.

#### 4.3 Render markdown pages
- For each `.md` file in `docs_dir`, call `zmd.parse` and wrap in the same site layout.
- Add nav entries.

#### 4.4 Custom code block formatter (hook for Phase 5)
- Pass `zmd.Options{ .code_block_formatter = myHighlighter }` where `myHighlighter` checks the info
  string for `zig` and returns a placeholder `<pre><code>` for now.
- This slot will be filled with the tree-sitter highlighter in Phase 5.

---

### Phase 5 — Syntax highlighting

Goal: highlighted Zig code blocks in both API docs and markdown pages.

#### 5.1 Dependencies
```zig
// build.zig.zon
.tree_sitter     = .{ .url = "...", .hash = "..." },  // tree-sitter/zig-tree-sitter
.tree_sitter_zig = .{ .url = "...", .hash = "..." },  // tree-sitter-grammars/tree-sitter-zig
```
Link the C libraries in `build.zig`:
```zig
const ts  = b.dependency("tree_sitter", .{});
const tsz = b.dependency("tree_sitter_zig", .{});
exe.linkLibrary(ts.artifact("tree-sitter"));
exe.linkLibrary(tsz.artifact("tree-sitter-zig"));
exe.root_module.addImport("tree_sitter", ts.module("tree-sitter"));
```

#### 5.2 Highlighter (`src/highlight.zig`)
- `extern fn tree_sitter_zig() *ts.Language;`
- Create a `ts.Parser`, set language, call `parseString`.
- Load `highlights.scm` via `@embedFile` from the tree-sitter-zig grammar.
- Create a `ts.Query`, run with `ts.QueryCursor`.
- Collect `(start_byte, end_byte, capture_name)` tuples; sort by start.
- Walk source, emit `<span class="hl-{name}">...</span>` with HTML-escaped text.
- Expose: `pub fn highlightZig(allocator, source: []const u8) ![]u8`

#### 5.3 Wire into markdown
- Replace the Phase 4 placeholder with a call to `highlightZig` in the code block formatter.
- Also use it when emitting function signatures in the API renderer.

---

### Phase 6 — Build step integration

Goal: target projects can add `zig build docs` with minimal config.

#### 6.1 `src/build_integration.zig` (public API)
```zig
pub fn addDocsStep(b: *std.Build, options: struct {
    root_module: *std.Build.Module,
    name: []const u8,
    out_dir: []const u8 = "docs",
    docs_src: ?[]const u8 = null,
}) *std.Build.Step
```
- Resolves `root_module.root_source_file` to get the root path.
- Creates a `RunStep` that runs the zkdocs binary with appropriate flags.
- Returns the step so the project can wire it into `zig build docs`.

#### 6.2 Usage in target project's `build.zig`
```zig
const zkdocs = b.dependency("zkdocs", .{});
const docs_step = @import("zkdocs").addDocsStep(b, .{
    .root_module = my_lib.root_module,
    .name = "MyLib",
});
b.step("docs", "Generate documentation").dependOn(docs_step);
```

---

## Key references

- **Zig AST:** `lib/std/zig/Ast.zig` — `rootDecls()`, `nodeTag()`, `fullFnProto()`, `fullContainerDecl()`, `fullVarDecl()`, `tokenSlice()`, `firstToken()`, `lastToken()`
- **Tree-sitter Zig bindings:** https://github.com/tree-sitter/zig-tree-sitter
- **Zig grammar + highlights:** https://github.com/tree-sitter-grammars/tree-sitter-zig — `queries/highlights.scm`
- **zmd markdown library:** https://github.com/jetzig-framework/zmd — `parse()` and custom formatters
- **zigdown (alternative):** https://github.com/JacobCrabill/zigdown — heavier but has built-in tree-sitter and tables

---

## File map

```
zkdocs/
  build.zig              ← build definition (exe + run + docs steps)
  build.zig.zon          ← dependencies (zmd, tree-sitter-*, later)
  zkdocs.zon             ← example project config (for zkdocs's own docs)
  sample.zig             ← test fixture
  src/
    main.zig             ← CLI entry point (arg parsing, orchestration)
    symbols.zig          ← AST extraction: Module, Symbol, Function, Container, ...
    highlight.zig        ← tree-sitter Zig highlighter → HTML (Phase 5)
    render.zig           ← HTML page renderer (Phase 3)
    markdown.zig         ← zmd wrapper + custom code block formatter (Phase 4)
    config.zig           ← config file parser (Phase 2)
    build_integration.zig← addDocsStep() public API (Phase 6)
  src/assets/
    style.css            ← embedded CSS
  plans/
    zig_doc_generator_plan.md  ← this file
  docs-src/              ← markdown tutorial pages (zkdocs's own docs)
```
