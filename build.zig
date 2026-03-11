const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zargunaught_dep = b.dependency("zargunaught", .{});
    const testz_dep = b.dependency("testz", .{});

    const symbols_mod = b.addModule("symbols", .{
        .root_source_file = b.path("src/symbols.zig"),
    });

    const render_mod = b.addModule("render", .{
        .root_source_file = b.path("src/render.zig"),
    });
    render_mod.addImport("symbols", symbols_mod);

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
