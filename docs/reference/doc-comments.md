# Writing Doc Comments

zkdocs reads `///` doc comments from your Zig source and renders them as Markdown on the generated documentation pages.

## Syntax

Attach a doc comment directly above a `pub` declaration:

```zig
/// Adds two integers and returns the result.
/// Wraps on overflow.
pub fn add(a: i32, b: i32) i32 {
    return a +% b;
}
```

Multiple consecutive `///` lines are joined into a single block. The `/// ` prefix (with the trailing space) is stripped; `///` without a space is also supported.

## Markdown in Doc Comments

Doc comment content is rendered as Markdown. You can use:

- **Bold** and _italic_
- `` `inline code` ``
- Fenced code blocks (with Zig syntax highlighting)
- Links, lists, and blockquotes

Example:

```zig
/// Returns a sorted copy of `items`.
///
/// ## Example
///
/// ```zig
/// const sorted = sort(allocator, &.{ 3, 1, 2 });
/// defer allocator.free(sorted);
/// ```
///
/// See also: `sortInPlace`.
pub fn sort(allocator: std.mem.Allocator, items: []const i32) ![]i32 { ... }
```

## Struct Field Docs

Attach `///` comments above individual struct fields:

```zig
pub const Config = struct {
    /// Maximum number of items to buffer.
    capacity: usize = 64,
    /// Whether to flush automatically when full.
    auto_flush: bool = true,
};
```

zkdocs renders these in the **Field** column of the fields table.

## Generic Type Constructors

Functions that return `type` are treated as type constructors and shown in the **Types** section. Document them like any other `pub` declaration:

```zig
/// A generic ring buffer holding elements of type `T`.
pub fn RingBuf(comptime T: type) type {
    return struct {
        /// Backing storage slice.
        buf: []T,
        /// Number of items currently stored.
        len: usize,

        /// Push an item, overwriting the oldest if full.
        pub fn push(self: *@This(), item: T) void { ... }
    };
}
```

Fields and methods of the returned struct are extracted and displayed just like a named container.

## Emoji Shortcodes

You can use `:name:` shortcodes anywhere in doc comments or guide pages:

```zig
/// :rocket: Launches the server.
pub fn launch() !void { ... }
```

Shortcodes are skipped inside code blocks. See the CLI docs for available emoji providers.
