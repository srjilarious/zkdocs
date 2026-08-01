# Getting Started

zkdocs generates static HTML documentation for Zig projects by walking
the module graph starting from a root source file.

## Installation

Clone the repository and build with `zig build`:

```sh
git clone https://github.com/example/zkdocs
cd zkdocs
zig build
```

The binary is placed at `zig-out/bin/zkdocs`.

## Basic usage

Point zkdocs at your root source file:

```sh
zkdocs --root src/main.zig --name MyLib --out docs/
```

This follows every `@import("./relative.zig")` recursively, extracts
all public symbols and their `///` doc comments, and writes an HTML site
to `docs/`.

## Options

- `--root` / `-r` — Root `.zig` file (default: `sample.zig`)
- `--name` / `-n` — Project display name (default: `Documentation`)
- `--out`  / `-o` — Output directory (required for HTML generation)
- `--conf` / `-c` — Path to a `zkdocs.conf` project config file

## Doc comments

zkdocs reads `///` doc comments above functions, types, and constants.
Markdown is fully supported inside doc comments:

```zig
/// Adds two integers.
///
/// Returns `a + b`. Both parameters must fit in an `i32`.
pub fn add(a: i32, b: i32) i32 { return a + b; }
```

## Import following

Only **relative** imports are followed — `@import("./math.zig")` is
included, while `@import("std")` is skipped.
