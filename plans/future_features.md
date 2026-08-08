# zkdocs — Future Feature Ideas

zkdocs is a complete, working Zig documentation generator. This document captures potential improvements
grouped by theme, roughly ordered from most to least impactful.

---

## 1. Zig Language Coverage

### 1.1 Tagged Union Payloads
Unions with enum tags have richer semantics than structs. Union fields already appear in the standard
fields table (`renderContainer`), same as struct fields, so field/payload-type listing works today.
Still open:
- Render the tag type prominently (rather than folded into the generic fields table)
- Link the tag enum specifically when it's a named type defined elsewhere

### 1.2 `test` Block Listing
`test "description" { ... }` blocks are already extracted into `Symbol.@"test"` during parsing, but
every renderer explicitly skips that variant (`.@"test", .other => {}` in `render.zig`,
`page_render.zig`, `symbols.zig`) — nothing is ever displayed. Still open:
- Render the extracted test blocks as a collapsible "Tests" section at the bottom of API pages

---

## 2. Developer Experience

### 2.1 Watch Mode
Iterating on documentation requires regenerating after every change. Not implemented as a CLI flag —
`src/file_watcher.zig` (`inotify` on Linux, no-op stub elsewhere) only powers in-process hot-reload of
individual asset files (textures/atlases/fonts, per the pixzig-style resource loader pattern) during a
single run; there is no `--watch` loop that re-invokes extraction/rendering.
- Add `--watch` flag that uses `inotify` (Linux) / `kqueue` (macOS) to detect changes
- Re-run extraction and rendering only for changed modules (incremental)
- Optionally serve the output directory over HTTP so the browser auto-reloads

### 2.2 Lint / Validation Mode
- Add `--check` (or `--lint`) flag that exits non-zero when public symbols lack doc comments
- Report missing docs to stderr in a format that editors and CI can parse (`file:line: warning: ...`)
- Optionally enforce minimum doc length or prohibit placeholder text like "TODO"

### 2.3 Live HTTP Server
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

---

## 5. Theming

### 5.1 Syntax Highlighting for More Languages
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
This repo has its own hand-written `.github/workflows/docs.yml` for self-hosting, but there is no
`zkdocs init` sub-command that scaffolds one for other projects.
- Add a `zkdocs init` sub-command that scaffolds a `.github/workflows/docs.yml`
- The workflow builds docs on every push to main and deploys to GitHub Pages
- Lowers the adoption barrier to near zero

### 7.2 `zkdocs check` for CI
- Already mentioned in §2.2, but worth calling out separately as a CI gate
- Exit-code contract: `0` = all public symbols documented, `1` = missing docs found
- Pairs with the GitHub Actions template above

---

## 8. Miscellaneous Quality-of-Life

### 8.1 Configurable Output File Names
- Allow renaming `index.html` to something else (some static hosts use `default.html`)
- Not critical, but costs little to add

### 8.2 Better Error Messages
- When `zkdocs.conf` is malformed JSON, report the line/column of the parse error
- When a source file listed in `sources` doesn't exist, suggest the nearest file by name

---

## 9. Terminal / CLI Output Mode

### 9.1 Pager Integration
- When stdout is a TTY and output exceeds one screen, pipe through `$PAGER` (falling back to `less`), mirroring `git help`/`man` — avoids scrollback spam for a whole-project `--dump`

### 9.2 Whole-Module Dump for `show`
- `zkdocs show` can look up an individual symbol but has no way to dump every symbol in one named
  module (only the full-project `--dump` covers everything at once)

---

## Priority Summary

| Feature | Impact | Effort | Priority |
|---------|--------|--------|----------|
| Watch mode + HTTP server | High | Medium | **P1** |
| `--check` lint mode for CI | High | Low | **P1** |
| Keyboard search + snippets | Medium | Low | **P2** |
| Previous / next page links | Medium | Low | **P2** |
| `test` block listing | Low | Low | **P3** |
| Version switcher | Low | Medium | **P3** |
| GitHub Actions template | Low | Low | **P3** |
