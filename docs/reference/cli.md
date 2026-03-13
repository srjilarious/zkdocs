# CLI Options

zkdocs is invoked as:

```sh
zkdocs [options]
```

## Options

| Flag | Short | Description |
|------|-------|-------------|
| `--root <path>` | `-r` | Root Zig source file to extract symbols from. Defaults to `sample.zig`. |
| `--name <name>` | `-n` | Display name shown in the site title and navigation. |
| `--out <dir>` | `-o` | Output directory for the generated HTML site. |
| `--docs <path>` | `-d` | Path to a `guides.json` config file (or a flat directory of `.md` files). |
| `--emoji <provider>` | `-e` | Emoji provider: `none`, `unicode` (default), `twemoji`, `noto`, `openmoji`. |
| `--help` | `-h` | Print help information. |

## Output Layout

Given `--out docs/`, zkdocs produces:

```
docs/
  index.html           — module index
  api/<module>.html    — one page per Zig module
  guide/<slug>.html    — one page per guide entry
```

Guide slugs mirror the `src` paths in `guides.json` with the `.md` extension
removed. A config entry with `"src": "reference/cli.md"` generates
`guide/reference/cli.html`.

## Emoji Providers

The `--emoji` flag controls how `:name:` shortcodes in doc comments and guide
pages are rendered:

- `none` — shortcodes are left as-is
- `unicode` — replaced with the Unicode emoji character (default)
- `twemoji` — replaced with `<img>` tags pointing to Twemoji CDN
- `noto` — replaced with `<img>` tags pointing to Google Noto Emoji CDN
- `openmoji` — replaced with `<img>` tags pointing to OpenMoji CDN

Emoji replacement is skipped inside `<code>` and `<pre>` blocks.

## Debug Output

Omitting `--out` prints extracted symbols to stderr instead of generating HTML,
which is useful for verifying extraction:

```sh
zkdocs --root src/root.zig --name MyLib
```
