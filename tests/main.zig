//* The `testz` framework uses a list of test groups and their associated
//* modules to discover test functions to run. Each group has a name, a tag
//* for filtering, and a reference to the module containing the tests. Tests
//* are organized one group per file (see `tests/*.zig`), following the same
//* pattern used in the nesterz project. The `main` function then runs all
//* discovered tests using the default `testzRunner` helper method, handling
//* argument parsing, etc.
const std = @import("std");
const testz = @import("testz");
const fix = @import("fixtures.zig");

const Tests = testz.discoverTests(.{
    testz.Group{ .name = "Function Extraction", .tag = "functions", .mod = @import("functions_tests.zig") },
    testz.Group{ .name = "Doc Comments", .tag = "docs", .mod = @import("docs_tests.zig") },
    testz.Group{ .name = "Container Extraction", .tag = "containers", .mod = @import("containers_tests.zig") },
    testz.Group{ .name = "Error Set Documentation", .tag = "error_sets", .mod = @import("error_sets_tests.zig") },
    testz.Group{ .name = "Import Following", .tag = "imports", .mod = @import("imports_tests.zig") },
    testz.Group{ .name = "Markdown Rendering", .tag = "markdown", .mod = @import("markdown_tests.zig") },
    testz.Group{ .name = "Render / Sym Links", .tag = "render", .mod = @import("render_tests.zig") },
    testz.Group{ .name = "Example Parsing", .tag = "example", .mod = @import("example_tests.zig") },
    testz.Group{ .name = "Site Rendering", .tag = "render_site", .mod = @import("render_site_tests.zig") },
    testz.Group{ .name = "Config Parsing", .tag = "conf", .mod = @import("conf_tests.zig") },
    testz.Group{ .name = "Build Cache", .tag = "cache", .mod = @import("cache_tests.zig") },
    testz.Group{ .name = "Emoji Shortcodes", .tag = "emoji", .mod = @import("emoji_tests.zig") },
    testz.Group{ .name = "Syntax Highlighting", .tag = "highlight", .mod = @import("highlight_tests.zig") },
    testz.Group{ .name = "Vendored zmd Parser", .tag = "zmd", .mod = @import("zmd_tests.zig") },
    testz.Group{ .name = "Terminal ANSI Rendering", .tag = "term_render", .mod = @import("term_render_tests.zig") },
    testz.Group{ .name = "Show / Symbol Lookup", .tag = "show", .mod = @import("show_tests.zig") },
    testz.Group{ .name = "Show / Dump Printing", .tag = "show_print", .mod = @import("show_print_tests.zig") },
    testz.Group{ .name = "Shell Completion", .tag = "completion", .mod = @import("completion_tests.zig") },
}, .{});

pub fn main(init: std.process.Init) !void {
    fix.g_Io = init.io;
    try testz.testzRunner(Tests, init.minimal.args);
}
