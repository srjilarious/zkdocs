# zkdocs — Future Feature Ideas

zkdocs is a complete, working Zig documentation generator. This document captures potential improvements
grouped by theme, roughly ordered from most to least impactful.

---

## 1. Zig Language Coverage

The biggest gap for a doc generator is how completely it mirrors the actual language.

### 1.1 Error Set Documentation
Zig error sets are a first-class type, but they're not extracted or rendered today.
- Extract `error{Foo, Bar}` declarations from `error_set_decl` AST nodes
- Document named error sets at the container level
- Link error types in function return signatures (`!T`) to their error set definitions
- Show which errors a function can return when the set is inlined in the return type

### 1.2 `comptime` Parameters and Blocks
Many Zig APIs are heavily comptime-parameterized.
- Annotate function parameters declared as `comptime T: type` or `comptime value: T`
- Extract and render doc comments from `comptime {}` blocks when they appear at container scope
- Detect and label "comptime-only" functions (functions that only make sense at compile time)

### 1.3 `extern` / C Interop Declarations
Zig is often used for C interop; those declarations need documentation too.
- Detect `extern fn` and `export fn` and render them with a distinct visual badge
- Show calling conventions (`callconv(.C)`, `callconv(.Stdcall)`) in signatures
- Document `extern struct` and `packed struct` distinctly from regular structs

### 1.4 Tagged Union Payloads
Unions with enum tags have richer semantics than structs.
- Render the tag type prominently on union documentation pages
- Show each field with its payload type in a table (similar to enum field listing)
- Link the tag enum if it is a named type defined elsewhere

### 1.5 `test` Block Listing
`test "description" { ... }` blocks are a form of documentation.
- Optionally extract test names and their doc comments
- Display them as a collapsible "Tests" section at the bottom of API pages
- Helps users understand expected behavior without reading the test file separately

---

## 2. Developer Experience

### 2.1 Watch Mode
Iterating on documentation requires regenerating after every change.
- Add `--watch` flag that uses `inotify` (Linux) / `kqueue` (macOS) to detect changes
- Re-run extraction and rendering only for changed modules (incremental)
- Optionally serve the output directory over HTTP so the browser auto-reloads

### 2.2 Incremental Builds
Even without watch mode, large projects benefit from not regenerating everything.
- Cache a content hash per source file; skip re-extraction when the file is unchanged
- Write a `.zkdocs-cache` file alongside the output directory
- Invalidate cache entries when imported files change (walk the import graph)

### 2.3 Lint / Validation Mode
- Add `--check` (or `--lint`) flag that exits non-zero when public symbols lack doc comments
- Report missing docs to stderr in a format that editors and CI can parse (`file:line: warning: ...`)
- Optionally enforce minimum doc length or prohibit placeholder text like "TODO"

### 2.4 Live HTTP Server
- Add `--serve [port]` to launch a small built-in HTTP server after generation
- Combine with `--watch` for a full "dev mode" workflow (`zkdocs --conf docs/zkdocs.conf --serve 4000 --watch`)
- This removes the need for a separate `python -m http.server` step

---

## 3. Search Improvements

### 3.1 Faceted / Filtered Search
The current minisearch index is flat — all result types mixed together.
- Add a "Type" filter dropdown: `All | Functions | Types | Constants | Guides`
- Pass a `category` field to minisearch and expose filter UI in `search.js`
- Low cost to implement given the data is already classified

### 3.2 Keyboard-Driven Search
- Bind `/` (or `Ctrl+K`) to focus the search box
- Arrow keys navigate results; `Enter` follows the selected result
- `Esc` clears the query and returns focus to the page

### 3.3 Search Result Snippets
Currently search results show only the symbol name and module.
- Truncate and highlight the first sentence of the doc comment in each result
- Bold the matching term inside the snippet (minisearch supports match data for this)

---

## 4. Output & Presentation

### 4.1 Breadcrumb Navigation
For nested modules and guide sections, users lose their position in the hierarchy.
- Add a breadcrumb bar below the header: `Home > api > mymodule > MyStruct`
- Breadcrumbs are inexpensive to generate and help with orientation in deep sites

### 4.2 Previous / Next Page Links
Common in MkDocs; guides especially benefit.
- Render `← Previous` and `Next →` links at the bottom of each guide and API page
- Order follows the sidebar order defined in the guides config

### 4.3 Stable Anchor IDs
Symbol anchors currently use `#sym-FunctionName`.
- Consider a more stable scheme when names conflict across modules: `#sym-moduleName-FunctionName`
- Add a `--base-url` flag so generated sites work correctly under a sub-path (e.g. GitHub Pages `/project/`)

### 4.4 Print Stylesheet
- Add a `@media print` CSS section that hides the sidebar and search, uses black-on-white, and expands all collapsed sections
- Useful for generating PDFs or printable reference sheets

### 4.5 Collapsible Symbol Sections
Large API pages with many symbols become hard to skim.
- Add collapse/expand triangles to each function or type card
- Persist collapsed state to `localStorage` so it survives page reloads
- Provide a global "Collapse all / Expand all" toggle

---

## 5. Customization & Theming

### 5.1 User CSS Injection
The theme enum approach is closed; advanced users need an escape hatch.
- Add `"extra_css": ["path/to/custom.css"]` to `zkdocs.conf`
- Inject a `<link rel="stylesheet">` tag after the built-in stylesheet
- Lets users override any CSS variable or rule without forking zkdocs

### 5.2 Custom Header / Footer HTML
- Add `"header_html"` and `"footer_html"` string fields in `zkdocs.conf`
- Injected verbatim; useful for analytics tags, organization logos, or legal footers

### 5.3 Logo / Favicon Support
- Add `"logo": "path/to/logo.png"` to `zkdocs.conf`
- Copy the file to `assets/logo.png` and display it in the sidebar header above the project name
- Add `"favicon"` similarly for `<link rel="icon">`

### 5.4 Syntax Highlighting for More Languages
The current highlighter handles Zig and JSON.
- Add grammars for C, C++, Bash, and TOML — commonly used in Zig project guides
- The tree-sitter integration already supports additional grammars; it's a matter of bundling them

---

## 6. Versioning & Multi-Instance

### 6.1 Version Switcher
Widely expected in mature library docs.
- Add `"versions": [{"label": "v0.3", "url": "/v0.3/"}, ...]` to `zkdocs.conf`
- Render a version dropdown in the sidebar header
- Each version is a separate build; the switcher just links between them

### 6.2 Canonical URL Meta Tag
When multiple versions of docs exist, search engines need a canonical.
- Add `"canonical_base"` to `zkdocs.conf` (e.g. `https://mylib.github.io/docs/`)
- Emit `<link rel="canonical" href="...">` on every page

---

## 7. CI / Deployment Helpers

### 7.1 GitHub Actions Workflow Template
- Add a `zkdocs init` sub-command that scaffolds a `.github/workflows/docs.yml`
- The workflow builds docs on every push to main and deploys to GitHub Pages
- Lowers the adoption barrier to near zero

### 7.2 `zkdocs check` for CI
- Already mentioned in §2.3, but worth calling out separately as a CI gate
- Exit-code contract: `0` = all public symbols documented, `1` = missing docs found
- Pairs with the GitHub Actions template above

---

## 8. Accessibility

### 8.1 Skip-to-Content Link
- Add a visually hidden `<a href="#main-content">Skip to main content</a>` as the very first element
- Becomes visible on focus for keyboard and screen-reader users

### 8.2 ARIA Roles on Sidebar and Navigation
- Add `role="navigation"` and `aria-label="Sidebar"` to the sidebar `<nav>`
- Add `aria-expanded` to collapsible section toggles and update it via JavaScript

### 8.3 Sufficient Color Contrast
- Audit the four themes against WCAG 2.1 AA (4.5:1 for normal text, 3:1 for large)
- The `default` and `monokai` dark themes likely pass; `vscode_light` should be verified

---

## 9. Miscellaneous Quality-of-Life

### 9.1 Configurable Output File Names
- Allow renaming `index.html` to something else (some static hosts use `default.html`)
- Not critical, but costs little to add

### 9.2 `--version` Flag
- Print `zkdocs 0.x.y` and exit
- The version string is already in `build.zig.zon`; just thread it through to the binary

### 9.3 Better Error Messages
- When `zkdocs.conf` is malformed JSON, report the line/column of the parse error
- When a source file listed in `sources` doesn't exist, suggest the nearest file by name

### 9.4 Parallel Module Rendering
- Modules are currently rendered sequentially
- Each API page is independent once symbols are extracted; they can be rendered in parallel using `std.Thread.Pool`
- Likely a noticeable speedup for projects with 20+ modules

---

## 10. Terminal / CLI Output Mode

Static HTML isn't always the fastest way to check "what does this function take again?" while heads-down in a terminal. zkdocs already has the hard part (symbol extraction, doc-comment markdown) — a terminal renderer is mostly a new `Formatters`-style backend, not a new pipeline.

### 10.1 `zkdocs show <symbol>` / `--dump` Command
- Reuse `symbols.extractModuleGraph` as-is; add a terminal-formatting backend as an alternative to `render.zig`'s HTML rendering (bold/italic via ANSI escapes, code spans dimmed, headings bolded — conceptually the same override mechanism `markdown.zig` already uses for zmd's `Formatters`, just targeting a different output)
- `zkdocs show MyStruct` prints that symbol's signature, doc comment, and (for containers) its fields/methods directly to stdout
- `zkdocs --dump` with no symbol prints the full project's API tree, for piping into `grep`/`less`

#### Not there yet for show
- Ability to dump an entire module, not just the imports.
- 

### 10.2 Shell Autocomplete
- `zkdocs --generate-completion=bash|zsh|fish` emits a completion script that knows the current project's real module/symbol names (extracted the same way `--dump` does), so `zkdocs show <TAB>` completes to actual symbols, not just static flag names
- Ties into zargunaught's existing arg-parsing; the dynamic part (symbol names) needs its own completion function per shell

### 10.3 Pager Integration
- When stdout is a TTY and output exceeds one screen, pipe through `$PAGER` (falling back to `less`), mirroring `git help`/`man` — avoids scrollback spam for a whole-project `--dump`

---

## Priority Summary

| Feature | Impact | Effort | Priority |
|---------|--------|--------|----------|
| Error set documentation | High | Medium | **P1** |
| Watch mode + HTTP server | High | Medium | **P1** |
| `--check` lint mode for CI | High | Low | **P1** |
| Keyboard search + snippets | Medium | Low | **P2** |
| User CSS injection | Medium | Low | **P2** |
| `comptime` parameter annotation | Medium | Medium | **P2** |
| Collapsible symbol sections | Medium | Low | **P2** |
| Previous / next page links | Medium | Low | **P2** |
| Terminal / CLI output mode (`zkdocs show`) | Medium | Medium | **P2** |
| `extern` / C interop badges | Low | Low | **P3** |
| `test` block listing | Low | Low | **P3** |
| Version switcher | Low | Medium | **P3** |
| Parallel rendering | Low | Medium | **P3** |
| GitHub Actions template | Low | Low | **P3** |
