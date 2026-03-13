# Guides Configuration

zkdocs supports hand-written Markdown guide pages alongside the auto-extracted
API documentation. Guides are configured via a `guides.json` file that
describes the page structure, titles, and source paths.

## Config File Format

`guides.json` is a JSON array. Each element is either a **top-level guide
entry** or a **section** containing multiple entries:

```json
[
  { "title": "Getting Started", "src": "getting-started.md" },
  {
    "section": "Reference",
    "entries": [
      { "title": "CLI Options",  "src": "reference/cli.md" },
      { "title": "API Overview", "src": "reference/api.md" }
    ]
  }
]
```

### Top-level entry

```json
{ "title": "Page Title", "src": "relative/path.md" }
```

- `title` — displayed in the sidebar and as the browser tab title. If omitted,
  the first H1 heading in the Markdown file is used; if there is none, the
  filename stem is used.
- `src` — path to the Markdown source file, **relative to `guides.json`**.

### Section

```json
{
  "section": "Section Name",
  "entries": [ ... ]
}
```

- `section` — the label shown as a collapsible heading in the sidebar.
- `entries` — array of entry objects (same format as top-level entries).

Sections are displayed as collapsible `<details>` elements in the sidebar.
The active section (the one containing the current page) is expanded
automatically.

## Hierarchy Depth

Up to two levels of hierarchy are supported:

```
Guides
└── Getting Started           ← top-level entry
└── Reference                 ← section
    ├── CLI Options           ← section entry
    └── Build Integration     ← section entry
```

## Source Paths

`src` values are resolved relative to the `guides.json` file. You can
organise your Markdown files however you like:

```
docs-src/
  guides.json
  getting-started.md
  reference/
    cli.md
    build-integration.md
```

The generated URL for a guide mirrors its `src` path with the `.md`
extension replaced by `.html`:

- `"src": "getting-started.md"` → `guide/getting-started.html`
- `"src": "reference/cli.md"` → `guide/reference/cli.html`

## Passing the Config to zkdocs

Use the `--docs` flag:

```sh
zkdocs --root src/root.zig --name MyLib --out site/ --docs docs-src/guides.json
```

Or via `addDocsStep` in `build.zig`:

```zig
const docs = zkdocs.addDocsStep(b, .{
    .root = "src/root.zig",
    .name = "MyLib",
    .out  = "site",
    .docs = "docs-src/guides.json",
});
```

## Legacy: Directory-based Guides

If `--docs` points to a directory (no `.json` extension), zkdocs falls back to
the legacy behaviour: all `.md` files in that directory are included as
top-level guide entries, sorted alphabetically by filename. No nested sections
are supported in this mode.
