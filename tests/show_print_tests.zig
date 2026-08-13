//* These tests cover `show.zig`'s printing (not just `findSymbol`): that
//* import-const aliases (`const foo = @import(...)`) never appear in
//* `--dump`/`show` output, that a query matching a module's name dumps
//* that module's whole API, and that `--verbose` prints a function's
//* highlighted body source. Uses zargunaught's in-memory `Printer` so the
//* output can be asserted on directly instead of going to real stdout.
const std = @import("std");
const testz = @import("testz");
const zkdocs = @import("zkdocs");
const zargs = zkdocs.zargunaught;
const symbols = zkdocs.symbols;
const show = zkdocs.show;
const fix = @import("fixtures.zig");

pub fn dumpNeverPrintsImportConsts() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    var printer = try zargs.print.Printer.memory(gpa);
    defer printer.deinit();

    try show.printDump(&printer, gpa, mods, false, false);

    const out = printer.array.writer.written();
    // `const std = @import("std");` and `const math = @import("./math.zig");`
    // are the import aliases at the top of sample.zig -- neither should be
    // printed as a symbol line. (Doc-comment prose mentioning "@import" is
    // fine and expected -- math.zig's own module doc says as much.)
    try testz.expectTrue(std.mem.indexOf(u8, out, "const std") == null);
    try testz.expectTrue(std.mem.indexOf(u8, out, "const math") == null);
}

pub fn showOnModuleNameDumpsWholeApi() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    var printer = try zargs.print.Printer.memory(gpa);
    defer printer.deinit();

    const found = try show.printShow(&printer, gpa, mods, "math", false, false);
    try testz.expectTrue(found);

    const out = printer.array.writer.written();
    try testz.expectTrue(std.mem.indexOf(u8, out, "=== module math") != null);
    try testz.expectTrue(std.mem.indexOf(u8, out, "fn multiply") != null);
    try testz.expectTrue(std.mem.indexOf(u8, out, "fn divide") != null);
    try testz.expectTrue(std.mem.indexOf(u8, out, "fn clamp") != null);
}

pub fn verboseIncludesFunctionBodySource() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    var printer_quiet = try zargs.print.Printer.memory(gpa);
    defer printer_quiet.deinit();
    _ = try show.printShow(&printer_quiet, gpa, mods, "add", false, false);
    const quiet_out = printer_quiet.array.writer.written();
    try testz.expectTrue(std.mem.indexOf(u8, quiet_out, "return a + b") == null);

    var printer_verbose = try zargs.print.Printer.memory(gpa);
    defer printer_verbose.deinit();
    _ = try show.printShow(&printer_verbose, gpa, mods, "add", false, true);
    const verbose_out = printer_verbose.array.writer.written();
    try testz.expectTrue(std.mem.indexOf(u8, verbose_out, "return a + b") != null);
}
