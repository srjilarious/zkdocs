# CLI Options

zkdocs is invoked as:

```sh
zkdocs [options]
```

## Options

| Flag | Short | Description |
|------|-------|-------------|
| `--conf <path>` | `-c` | Path to a `zkdocs.conf` project config file. |
| `--root <path>` | `-r` | Root Zig source file to extract symbols from (overrides conf). |
| `--name <name>` | `-n` | Display name shown in the site title and navigation (overrides conf). |
| `--out <dir>` | `-o` | Output directory for the generated HTML site. |
| `--docs <path>` | `-d` | Path to a legacy `guides.json` file or a flat directory of `.md` files. |
| `--theme <name>` | `-t` | Color theme: `default`, `monokai`, `vscode-light`, `vscode-dark` (overrides conf). |
| `--emoji <provider>` | `-e` | Emoji provider: `none`, `unicode` (default), `twemoji`, `noto`, `openmoji` (overrides conf). |
| `--help` | `-h` | Print help information. |

When `--conf` is given, all settings in the config file are used as defaults.
Individual flags (`--root`, `--name`, `--theme`, `--emoji`) override the
corresponding config values.

## Output Layout

Given `--out docs/`, zkdocs produces:

```
docs/
  index.html           — module index
  api/<module>.html    — one page per Zig module
  guide/<slug>.html    — one page per guide entry
```

Guide slugs mirror the `src` paths in `zkdocs.conf` with the `.md` extension
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
