const std = @import("std");

pub const DocsOptions = struct {
    /// Path to the library's root source file (e.g. "src/root.zig").
    root: []const u8,
    /// Project name shown in the generated site title.
    name: []const u8,
    /// Output directory for generated HTML (default: "docs").
    out: []const u8 = "docs",
    /// Optional path to a `guides.json` config file listing hand-written guide pages,
    /// or a directory of flat `.md` files (legacy). See docs/guides.json for format.
    docs: ?[]const u8 = null,
    /// Emoji provider: "none", "unicode" (default), "twemoji", "noto", "openmoji".
    emoji: ?[]const u8 = null,
};

/// Add a documentation-generation step to the consuming project's build.
///
/// Usage in a consuming project's `build.zig`:
///
/// ```zig
/// const zkdocs = @import("zkdocs");
/// const docs_step = zkdocs.addDocsStep(b, .{
///     .root = "src/root.zig",
///     .name = "MyLib",
///     .out  = "docs",
/// });
/// b.step("docs", "Generate API documentation").dependOn(docs_step);
/// ```
///
/// The consuming project must declare `zkdocs` as a dependency in its
/// `build.zig.zon`.
pub fn addDocsStep(b: *std.Build, options: DocsOptions) *std.Build.Step {
    // Look up the zkdocs dependency from the consumer's build graph.
    // The binary is compiled for the host (it is a dev tool, not a target artifact).
    const dep = b.dependency("zkdocs", .{});
    const run = b.addRunArtifact(dep.artifact("zkdocs"));

    run.addArgs(&.{ "--root", options.root });
    run.addArgs(&.{ "--name", options.name });
    run.addArgs(&.{ "--out", options.out });
    if (options.docs)  |d| run.addArgs(&.{ "--docs",  d });
    if (options.emoji) |e| run.addArgs(&.{ "--emoji", e });

    return &run.step;
}
