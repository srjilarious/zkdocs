//* These tests cover `conf.zig` (`zkdocs.conf` parsing), which had no direct
//* test coverage at all — only ever exercised indirectly by hand-running the
//* CLI. `stripJsonComments` and `loadSiteConf` are exactly the functions
//* touched when the render.zig split pulled config loading into its own file.
const std = @import("std");
const testz = @import("testz");
const zkdocs = @import("zkdocs");
const render = zkdocs.render;
const fix = @import("fixtures.zig");

pub fn stripJsonCommentsBlanksCommentLinesButKeepsLineCount() !void {
    const gpa = std.heap.page_allocator;

    const src = "{\n  // a comment\n  \"a\": 1\n}\n";
    const stripped = try render.stripJsonComments(gpa, src);
    defer gpa.free(stripped);

    try testz.expectTrue(std.mem.indexOf(u8, stripped, "comment") == null);
    try testz.expectTrue(std.mem.indexOf(u8, stripped, "\"a\": 1") != null);
    // Line 2 (0-indexed 1) held the comment and must now be blank, so
    // byte offsets for the lines around it are undisturbed.
    var lines = std.mem.splitScalar(u8, stripped, '\n');
    _ = lines.next();
    try testz.expectEqualStr(lines.next().?, "");
    // The result must still be valid JSON once comments are gone.
    const parsed = try std.json.parseFromSlice(std.json.Value, gpa, stripped, .{});
    defer parsed.deinit();
}

pub fn loadSiteConfParsesUnifiedPagesFormat() !void {
    const gpa = std.heap.page_allocator;
    const dir = "test_tmp_conf_unified";
    defer std.Io.Dir.cwd().deleteTree(fix.g_Io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(fix.g_Io, dir);

    {
        const f = try std.Io.Dir.cwd().createFile(fix.g_Io, dir ++ "/guide.md", .{});
        defer f.close(fix.g_Io);
        try f.writeStreamingAll(fix.g_Io, "# Guide Title\n\nHello.\n");
    }
    const conf_path = dir ++ "/zkdocs.conf";
    {
        const f = try std.Io.Dir.cwd().createFile(fix.g_Io, conf_path, .{});
        defer f.close(fix.g_Io);
        try f.writeStreamingAll(fix.g_Io,
            \\{
            \\  // top-level project settings
            \\  "name": "Widgets",
            \\  "theme": "monokai",
            \\  "home": "guide",
            \\  "pages": [
            \\    { "src": "guide.md" }
            \\  ]
            \\}
        );
    }

    var conf = try render.loadSiteConf(fix.g_Io, gpa, conf_path);
    defer conf.deinit(gpa);

    try testz.expectEqualStr(conf.name.?, "Widgets");
    try testz.expectEqual(conf.theme, .monokai);
    try testz.expectEqualStr(conf.home_slug.?, "guide");
    try testz.expectEqual(conf.pages.len, 1);
    try testz.expectEqualStr(conf.pages[0].entry.title, "Guide Title");
    try testz.expectEqualStr(conf.pages[0].entry.slug, "guide");
}

pub fn loadSiteConfParsesLegacyGuidesAndExamplesFormat() !void {
    const gpa = std.heap.page_allocator;
    const dir = "test_tmp_conf_legacy";
    defer std.Io.Dir.cwd().deleteTree(fix.g_Io, dir) catch {};
    try std.Io.Dir.cwd().createDirPath(fix.g_Io, dir);

    {
        const f = try std.Io.Dir.cwd().createFile(fix.g_Io, dir ++ "/legacy.md", .{});
        defer f.close(fix.g_Io);
        try f.writeStreamingAll(fix.g_Io, "# Legacy Guide\n\nHello.\n");
    }
    const conf_path = dir ++ "/zkdocs.conf";
    {
        const f = try std.Io.Dir.cwd().createFile(fix.g_Io, conf_path, .{});
        defer f.close(fix.g_Io);
        try f.writeStreamingAll(fix.g_Io,
            \\{
            \\  "guides": [
            \\    { "src": "legacy.md" }
            \\  ]
            \\}
        );
    }

    var conf = try render.loadSiteConf(fix.g_Io, gpa, conf_path);
    defer conf.deinit(gpa);

    try testz.expectEqual(conf.pages.len, 1);
    try testz.expectEqualStr(conf.pages[0].entry.title, "Legacy Guide");
}
