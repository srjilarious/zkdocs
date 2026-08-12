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
| `--theme <name>` | `-t` | Color theme: `default`, `monokai`, `vscode-light`, `vscode-dark` (overrides conf). |
| `--emoji <provider>` | `-e` | Emoji provider: `none`, `unicode` (default), `twemoji`, `noto`, `openmoji` (overrides conf). |
| `--dump` | `-d` | Print the full extracted symbol tree to stdout (for piping into `grep`/`less`). |
| `--version` | `-v` | Print the zkdocs version and exit. |
| `--help` | `-h` | Print help information. |

There's also a `show` command: `zkdocs show <symbol>`.

When `--conf` is given, all settings in the config file are used as defaults.
Individual flags (`--root`, `--name`, `--theme`, `--emoji`) override the
corresponding config values. Pass exactly one of `show`, `--dump`, or `--out`
per invocation.

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

## Terminal Output: `show` and `--dump`

Instead of generating a site, you can print symbols straight to the
terminal.

`zkdocs show <symbol>` prints one symbol's signature and doc comment (and,
for containers, its fields and decls):

```sh
zkdocs --root src/root.zig show MyStruct
```

A bare name matches anywhere in the module graph, including nested inside
containers; if more than one symbol shares that name, every match is
printed, each labeled with its module/container path. A dotted query
narrows the match to a specific container (`MyStruct.init`) or module
(`math.multiply`), matching as many trailing path segments as given.

`zkdocs --dump` prints the entire extracted symbol tree, useful for piping
into `grep`/`less`:

```sh
zkdocs --root src/root.zig --dump | less
```

Both fall back to a `zkdocs.conf` in the current directory to find the root
source file when neither `--conf` nor `--root` is given, so they can be run
bare from a project root:

```sh
cd my-project && zkdocs show MyStruct
```

Color output is automatic on a TTY and disabled when piped.
