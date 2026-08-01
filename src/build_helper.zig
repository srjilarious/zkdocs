const std = @import("std");

pub const DocsOptions = struct {
    /// Path to the library's root source file (e.g. "src/root.zig").
    /// Optional when `conf` is provided and the conf file specifies `sources`.
    root: ?[]const u8 = null,
    /// Project name shown in the generated site title.
    /// Optional when `conf` is provided and the conf file specifies `name`.
    name: ?[]const u8 = null,
    /// Output directory for generated HTML (default: "docs").
    out: []const u8 = "docs",
    /// Path to a `zkdocs.conf` project config file. When provided, the conf file
    /// is used for sources, name, theme, emoji, and guides. CLI-equivalent fields
    /// in this struct (root, name, emoji, theme) override individual conf values.
    conf: ?[]const u8 = null,
    /// Color theme: "default" (dark), "monokai", or "vscode-light".
    /// Overrides the theme in `conf`.
    theme: ?[]const u8 = null,
    /// Emoji provider: "none", "unicode" (default), "twemoji", "noto", "openmoji".
    /// Overrides the emoji setting in `conf`.
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

    if (options.root) |r| run.addArgs(&.{ "--root", r });
    if (options.name) |n| run.addArgs(&.{ "--name", n });
    run.addArgs(&.{ "--out", options.out });
    if (options.conf)  |c| run.addArgs(&.{ "--conf",  c });
    if (options.theme) |t| run.addArgs(&.{ "--theme", t });
    if (options.emoji) |e| run.addArgs(&.{ "--emoji", e });

    return &run.step;
}
