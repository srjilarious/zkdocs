# API Overview

The public API surface of zkdocs is intentionally small.

## Symbol types

zkdocs extracts four categories of symbols from each `.zig` file:

- **Functions** — `pub fn name(params) ReturnType`
- **Types** — `pub const Name = struct/enum/union/opaque { ... }`
- **Constants** — `pub const name: Type = value`
- **Tests** — `test "name" { ... }` (tracked but not rendered yet)

## Module graph

The `extractModuleGraph` function returns a slice of `Module` values,
one per reachable `.zig` file:

```zig
const mods = try symbols.extractModuleGraph(allocator, "src/root.zig");
defer symbols.deinitModules(allocator, mods);
```

Each `Module` exposes its `name`, absolute `path`, and a list of
`Symbol` values.

## Rendering

Pass the module slice to `renderSite` along with an output path:

```zig
try render.renderSite(allocator, "docs/", "MyLib", mods, null);
```

Optional: supply a directory of `.md` guide pages as the last argument.
