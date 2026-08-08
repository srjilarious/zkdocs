# zkdocs — Future Feature Ideas

zkdocs is a complete, working Zig documentation generator. This document captures potential improvements
grouped by theme, roughly ordered from most to least impactful.

---

## 1. Zig Language Coverage

The biggest gap for a doc generator is how completely it mirrors the actual language.

### 1.1 Error Set Documentation — done
- `error{Foo, Bar}` declarations are extracted (`ErrorSet`/`ErrorVal` in `symbols.zig`) and rendered
  in a dedicated "Errors" section per module (`renderErrorSet` in `page_render.zig`)
- Inline `error{...}!T` return types are captured on the function itself (`Function.inline_errors`)
  and rendered as an "Errors" table under the function
- Named error sets participate in the cross-module type index, so `!MyError` in a signature links
  to the error set's definition

### 1.2 `comptime` Parameters and Blocks — done
- `comptime T: type` / `comptime value: T` parameters are flagged (`Param.is_comptime`) and rendered
  with a `comptime ` keyword prefix
- `comptime {}` blocks at container/module scope are extracted (`ComptimeBlock`) with their doc
  comment and rendered as a collapsible source block (`renderComptimeBlock`)
- Functions whose every parameter is comptime-qualified are labelled with a "comptime" pill
  (`Function.is_comptime_only`)

### 1.3 `extern` / C Interop Declarations — done
- `extern fn` / `export fn` render with `extern`/`export` badges and pills (`Function.is_extern`,
  `.is_export`, `.extern_lib_name`)
- `callconv(...)` is captured and shown in the signature (`Function.callconv_src`)
- `extern struct` / `packed struct` render their layout keyword distinctly from a plain struct
  (`Container.layout`)

### 1.4 Tagged Union Payloads — partially done
Union fields already appear in the standard fields table (`renderContainer`), same as struct fields,
so field/payload-type listing works today. Still open:
- Render the tag type prominently (rather than folded into the generic fields table)
- Link the tag enum specifically when it's a named type defined elsewhere

### 1.5 `test` Block Listing
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

### 2.2 Incremental Builds — mostly done
`.zkdocs-cache` (`src/cache.zig`) already tracks an mtime (not content hash) per source/guide/asset
file plus the conf file, and `render.zig` skips re-rendering any `api/<module>.html` or `page/<slug>.html`
whose source, the conf, and all assets are unchanged. Since each imported module already gets its own
tracked `Module.abs_path` entry, most of the "invalidate when an import changes" need is covered
without an explicit import-graph walk. Still open:
- Switch from mtime to a content hash, if mtime-based staleness proves unreliable in practice
- `index.html`'s module-listing content depends on every module's blurb, but isn't invalidated by an
  unrelated module's doc-comment-only edit today (it's covered whenever conf/sources otherwise change)

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

### 4.3 Stable Anchor IDs — `--base-url` done; anchor scheme judged unnecessary
- `--base-url` (or conf `"base_url"`) now overrides every nav/asset/link prefix with a fixed absolute
  path (`site_context.prefixFor`, wired through `writeHeader`/`writeFooter`/page renderers), so a site
  deployed under e.g. `/project/` links correctly regardless of on-disk nesting depth
- The `#sym-moduleName-FunctionName` anchor scheme was not implemented: each module already renders to
  its own `api/<module>.html` page, and Zig disallows duplicate top-level declaration names within a
  single file, so `#sym-Name` collisions within one page cannot actually occur today. The real
  cross-module ambiguity is in `buildTypeIndex` (`site_context.zig`), which silently lets a
  same-named public symbol in a later-processed module overwrite an earlier module's entry for
  automatic `writeTypeSrc` linking — a `sym:module.Name`-style qualification already exists for
  explicit markdown links (`html_transform.zig`), but the automatic in-signature linker has no
  equivalent disambiguation. Worth a follow-up if projects with cross-module name collisions report bad links.

### 4.4 Print Stylesheet — done
- `@media print` in `style.css` hides the sidebar/search/mobile-bar/collapse-toggle-row, forces
  black-on-white
- `initPrintExpand` in `search.js` force-opens every collapsed `<details>` on `beforeprint` and
  restores prior state on `afterprint`, so nothing collapsed is silently omitted from a printed page

### 4.5 Collapsible Symbol Sections — done
- Each symbol card is now a native `<details class="symbol">` (`renderFn`/`renderContainer`/
  `renderVar`/`renderErrorSet`/`renderComptimeBlock` in `page_render.zig`) with the signature in
  `<summary>`
- `initSymbolCollapse` in `search.js` persists collapsed IDs to `localStorage` per page (keyed by
  `location.pathname`) and restores them on load
- A "Collapse all / Expand all" button pair (`.collapse-toggle-row`) is rendered above the symbol
  list on every API module page (`render.zig`)

---

## 5. Customization & Theming

### 5.1 User CSS Injection — done
- `"extra_css": ["path/to/custom.css"]` in `zkdocs.conf`, resolved relative to the conf file
- Each file is copied into `assets/` (`html_transform.copyAssetFile`) and linked via
  `<link rel="stylesheet">` after the built-in stylesheet, so later rules win

### 5.2 Custom Header / Footer HTML — done
- `"header_html"` and `"footer_html"` string fields in `zkdocs.conf`, injected verbatim
  (`SiteContext.header_html`/`.footer_html`) — right after the skip-link at the top of `<body>`,
  and inside `<footer>` below the generated project/version line

### 5.3 Logo / Favicon Support — done
- `"logo"` in `zkdocs.conf`: copied into `assets/`, shown above the project name in the sidebar
  header (`.site-logo`)
- `"favicon"` similarly, emitted as `<link rel="icon">`

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
This repo has its own hand-written `.github/workflows/docs.yml` for self-hosting, but there is no
`zkdocs init` sub-command that scaffolds one for other projects — still open:
- Add a `zkdocs init` sub-command that scaffolds a `.github/workflows/docs.yml`
- The workflow builds docs on every push to main and deploys to GitHub Pages
- Lowers the adoption barrier to near zero

### 7.2 `zkdocs check` for CI
- Already mentioned in §2.3, but worth calling out separately as a CI gate
- Exit-code contract: `0` = all public symbols documented, `1` = missing docs found
- Pairs with the GitHub Actions template above

---

## 8. Accessibility

### 8.1 Skip-to-Content Link — done
- `.skip-link` is the first element inside `<body>`, visually hidden until keyboard focus
  (`writeHeader` in `page_render.zig`), targeting `<main id="main-content">`

### 8.2 ARIA Roles on Sidebar and Navigation — done
- `role="navigation" aria-label="Sidebar"` on `<nav class="sidebar">`, `role="search"` on the search
  box
- The mobile nav/TOC toggle buttons (the only JS-driven, non-native disclosure widgets in the chrome)
  get `aria-expanded`, updated by `initMobileNav` in `search.js`. The `<details>`-based nav sections
  and symbol cards don't need manual `aria-expanded` — native disclosure semantics cover those.

### 8.3 Sufficient Color Contrast — audited, fixed
Computed WCAG 2.1 AA contrast ratios (4.5:1 normal text) for all four themes against their actual
backgrounds (including composited code-block backgrounds). Two real failures found and fixed in
`style.css`:
- `monokai --muted` (`#857e68`, 4.41:1 on `--bg`) → `#928a72` (5.19:1)
- `vscode-light --muted` (`#717171`, 4.40:1 on `--bg-sidebar`) → `#656565` (5.25:1)
- `vscode-light --type`/`--num` (3.88:1 / 3.90:1 against the code-block background used by
  syntax-highlighted `<pre>` blocks) → `#227289` / `#08784f` (4.63:1 / 4.67:1)
- `default` and `vscode-dark` already passed everywhere checked

---

## 9. Miscellaneous Quality-of-Life

### 9.1 Configurable Output File Names
- Allow renaming `index.html` to something else (some static hosts use `default.html`)
- Not critical, but costs little to add

### 9.2 `--version` Flag — done
- `-v`/`--version` prints `zkdocs <version>` from `build_options.version` and exits (`main.zig`)

### 9.3 Better Error Messages
- When `zkdocs.conf` is malformed JSON, report the line/column of the parse error
- When a source file listed in `sources` doesn't exist, suggest the nearest file by name

### 9.4 Parallel Module Rendering — done
- Each `api/<module>.html` page is rendered independently on the `Io.Group` thread pool (`std.Thread.Pool` no longer exists in current Zig; `Io.Group.async` is its replacement) instead of sequentially
- Guide/example `page/<slug>.html` pages get the same treatment, since they're just as independent of each other
- See `renderModulePage`/`renderModuleJob` and `renderPageEntry`/`renderPageJob` in `src/render.zig`

---

## 10. Terminal / CLI Output Mode

Static HTML isn't always the fastest way to check "what does this function take again?" while heads-down in a terminal. zkdocs already has the hard part (symbol extraction, doc-comment markdown) — a terminal renderer is mostly a new `Formatters`-style backend, not a new pipeline.

### 10.1 `zkdocs show <symbol>` / `--dump` Command — done
- `src/show.zig` + `src/term_render.zig` implement the ANSI terminal-formatting backend
  (`printShow`/`printDump`/`printSymbolNames`), wired up in `main.zig` as the `show` sub-command,
  `--dump`, and `--list-symbols`
- `zkdocs show MyStruct` prints that symbol's signature, doc comment, and (for containers) its fields/methods directly to stdout
- `zkdocs --dump` with no symbol prints the full project's API tree, for piping into `grep`/`less`

#### Not there yet for show
- Ability to dump an entire module, not just the imports.

### 10.2 Shell Autocomplete — done
- `src/completion.zig` + `--generate-completion=bash|zsh|fish` in `main.zig`; `--list-symbols` feeds
  the dynamic completion function with real module/symbol names per the project's own conf/root

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
