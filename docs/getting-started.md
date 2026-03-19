# Getting Started

zkdocs is a static documentation generator for Zig projects. It parses Zig
source files, extracts doc comments, and emits a self-contained HTML site
complete with syntax highlighting, emoji support, and hand-written guide pages.

## Installation

Add zkdocs as a dependency in your `build.zig.zon`:

```zig
.dependencies = .{
    .zkdocs = .{
        .url = "https://github.com/your-org/zkdocs/archive/main.tar.gz",
        .hash = "<hash>",
    },
},
```

## Quick Start

Run zkdocs directly from the command line:

```sh
zkdocs --root src/root.zig --name MyLib --out docs/
```

This scans `src/root.zig` (following relative `@import` chains), extracts all
`pub` symbols with `///` doc comments, and writes the HTML site to `docs/`.

## Adding to Your Build

Import zkdocs in your `build.zig` and call `addDocsStep`:

```zig
const zkdocs = @import("zkdocs");

pub fn build(b: *std.Build) void {
    // ... your normal build setup ...

    const docs = zkdocs.addDocsStep(b, .{
        .root  = "src/root.zig",
        .name  = "MyLib",
        .out   = "docs",
        .docs  = "docs-src/guides.json",
    });
    b.step("docs", "Generate documentation").dependOn(docs);
}
```

Run with:

```sh
zig build docs
```

## What Gets Extracted

zkdocs extracts **public** (`pub`) symbols from your Zig source:

- **Functions** — shown with signature and doc comment
- **Types** — structs, enums, unions with field tables and method cards
- **Generic type constructors** — `pub fn Foo(comptime T: type) type` is treated
  as a type and shown with fields and methods
- **Constants** — `pub const name: Type = value`

Private symbols (not marked `pub`) are silently ignored.
