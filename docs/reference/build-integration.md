# Build Integration

zkdocs integrates with the Zig build system so you can generate docs with a
single `zig build docs` invocation.

## Adding the Dependency

Declare zkdocs in your project's `build.zig.zon`:

```zig
.dependencies = .{
    .zkdocs = .{
        .url = "https://github.com/your-org/zkdocs/archive/main.tar.gz",
        .hash = "<hash>",
    },
},
```

## Wiring Up the Build Step

In your `build.zig`, import the helper and call `addDocsStep`:

```zig
const std = @import("std");
const zkdocs = @import("zkdocs");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ... your library / executable setup ...

    // Documentation step
    const docs = zkdocs.addDocsStep(b, .{
        .root  = "src/root.zig",      // entry point for symbol extraction
        .name  = "MyLib",             // project name shown in site title
        .out   = "docs",              // output directory
        .docs  = "docs-src/guides.json", // optional guide config
        .emoji = "unicode",           // optional emoji provider
    });
    b.step("docs", "Generate API documentation").dependOn(docs);
}
```

Then run:

```sh
zig build docs
```

## DocsOptions Fields

| Field | Type | Default | Description |
|-------|------|---------|-------------|
| `root` | `[]const u8` | *(required)* | Root Zig source file |
| `name` | `[]const u8` | *(required)* | Project name |
| `out` | `[]const u8` | `"docs"` | Output directory |
| `docs` | `?[]const u8` | `null` | Path to `guides.json` config (or legacy directory) |
| `emoji` | `?[]const u8` | `null` | Emoji provider name |

## Import Following

zkdocs automatically follows relative `@import` calls from the root file:

```zig
// src/root.zig
pub const utils = @import("./utils.zig");   // ← followed
pub const std   = @import("std");            // ← ignored (non-relative)
```

Each imported file becomes its own **module** tab in the generated site. Only
`@import` paths starting with `./` or `../` are followed.

## Output Structure

```
out/
  index.html           — project index listing all modules and guides
  api/
    root.html          — symbols from the root file
    utils.html         — symbols from imported files
  guide/
    getting-started.html
    reference/
      cli.html
      build-integration.html
```
