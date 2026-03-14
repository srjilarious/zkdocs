# Site Configuration

zkdocs is configured via a `zkdocs.conf` file — a JSON object that describes
the project name, source files, color theme, emoji settings, and the
hand-written guide pages to include alongside the auto-extracted API docs.

## Config File Format

`zkdocs.conf` is a JSON object:

```json
{
  "name": "MyLib",
  "sources": ["src/root.zig"],
  "theme": "default",
  "emoji": "unicode",
  "guides": [
    { "title": "Getting Started", "src": "getting-started.md" },
    {
      "section": "Reference",
      "entries": [
        { "title": "CLI Options",  "src": "reference/cli.md" },
        { "title": "API Overview", "src": "reference/api.md" }
      ]
    }
  ]
}
```

### Top-level fields

| Field     | Type             | Description |
|-----------|------------------|-------------|
| `name`    | string           | Project name shown in the site header and `<title>`. |
| `sources` | array of strings | Root source file(s) for symbol extraction, relative to the conf file. |
| `theme`   | string           | Color theme: `"default"`, `"monokai"`, `"vscode-light"`, or `"vscode-dark"`. |
| `emoji`   | string           | Emoji provider: `"none"`, `"unicode"`, `"twemoji"`, `"noto"`, `"openmoji"`. |
| `guides`  | array            | Ordered list of guide pages and sections (see below). |

All fields are optional; any value not present falls back to the equivalent
CLI flag, and then to the built-in default.

## Color Themes

### `default`

The built-in dark theme. Deep navy background with a warm amber accent.
Syntax colors inspired by Material / One Dark.

### `monokai`

Dark theme with Monokai palette: charcoal background, green functions,
pink/red keywords, cyan types, and yellow strings.

### `vscode-light`

Light theme matching VS Code's default light color scheme: white background,
blue keywords, teal types, dark-gold function names, and red string literals.

### `vscode-dark`

Dark theme matching VS Code Dark+: charcoal background (`#1e1e1e`), blue
keywords, teal types, gold function names, and orange/tan strings.

## Guides Array

Each element of `"guides"` is either a **top-level guide entry** or a
**named section** containing multiple entries:

### Top-level entry

```json
{ "title": "Page Title", "src": "relative/path.md" }
```

- `title` — displayed in the sidebar and as the browser tab title. If omitted,
  the first H1 heading in the Markdown file is used; if there is none, the
  filename stem is used.
- `src` — path to the Markdown source file, **relative to `zkdocs.conf`**.

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

`src` values are resolved relative to the `zkdocs.conf` file. You can
organise your Markdown files however you like:

```
docs/
  zkdocs.conf
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

Use the `--conf` flag:

```sh
zkdocs --out site/ --conf docs/zkdocs.conf
```

Individual CLI flags override the corresponding conf values:

```sh
# Use conf but switch to the monokai theme
zkdocs --out site/ --conf docs/zkdocs.conf --theme monokai
```

Or via `addDocsStep` in `build.zig`:

```zig
const docs = zkdocs.addDocsStep(b, .{
    .root = "src/root.zig",
    .name = "MyLib",
    .out  = "site",
    .conf = "docs/zkdocs.conf",
});
```

## Legacy: guides-only JSON

If you pass a `.json` file whose root is an array (the old `guides.json`
format), zkdocs still accepts it via the `--docs` flag for backward
compatibility. Nested sections are supported.

```sh
zkdocs --root src/root.zig --name MyLib --out site/ --docs docs/guides.json
```

## Legacy: Directory-based Guides

If `--docs` points to a directory (no file extension), zkdocs falls back to
the legacy behaviour: all `.md` files in that directory are included as
top-level guide entries, sorted alphabetically by filename. No nested sections
are supported in this mode.
