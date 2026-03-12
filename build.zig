const std = @import("std");
const build_helper = @import("src/build_helper.zig");

/// Re-export so consumers that depend on zkdocs as a path dep can call this directly.
pub const DocsOptions = build_helper.DocsOptions;
pub const addDocsStep = build_helper.addDocsStep;

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zargunaught_dep = b.dependency("zargunaught", .{});
    const testz_dep = b.dependency("testz", .{});
    const zmd_dep = b.dependency("zmd", .{});
    const tree_sitter_dep = b.dependency("tree_sitter", .{
        .target = target,
        .optimize = optimize,
    });
    const tree_sitter_zig_dep = b.dependency("tree_sitter_zig", .{
        .target = target,
        .optimize = optimize,
        .@"build-shared" = false,
    });

    // Expose the build helper as the "zkdocs" module so consuming projects can
    // @import("zkdocs") in their build.zig and call addDocsStep.
    _ = b.addModule("zkdocs", .{
        .root_source_file = b.path("src/build_helper.zig"),
    });

    const symbols_mod = b.addModule("symbols", .{
        .root_source_file = b.path("src/symbols.zig"),
    });

    const highlight_mod = b.addModule("highlight", .{
        .root_source_file = b.path("src/highlight.zig"),
    });
    highlight_mod.addImport("tree_sitter", tree_sitter_dep.module("tree_sitter"));
    highlight_mod.addImport("tree-sitter-zig", tree_sitter_zig_dep.module("tree-sitter-zig"));

    const markdown_mod = b.addModule("markdown", .{
        .root_source_file = b.path("src/markdown.zig"),
    });
    markdown_mod.addImport("zmd", zmd_dep.module("zmd"));
    markdown_mod.addImport("highlight", highlight_mod);

    const render_mod = b.addModule("render", .{
        .root_source_file = b.path("src/render.zig"),
    });
    render_mod.addImport("symbols", symbols_mod);
    render_mod.addImport("markdown", markdown_mod);

    const exe = b.addExecutable(.{
        .name = "zkdocs",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    exe.root_module.addImport("symbols", symbols_mod);
    exe.root_module.addImport("render", render_mod);
    exe.root_module.addImport("zargunaught", zargunaught_dep.module("zargunaught"));

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    const run_step = b.step("run", "Run zkdocs");
    run_step.dependOn(&run_cmd.step);

    const tests_exe = b.addExecutable(.{
        .name = "tests",
        .root_module = b.addModule("main", .{
            .root_source_file = b.path("tests/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    tests_exe.root_module.addImport("testz", testz_dep.module("testz"));
    tests_exe.root_module.addImport("symbols", symbols_mod);

    const tests_run = b.addRunArtifact(tests_exe);
    const tests_step = b.step("tests", "Run unit tests");
    tests_step.dependOn(&tests_run.step);
}
