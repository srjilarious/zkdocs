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

pub fn listSymbolsIncludesModulesAndNestedNamesDeduplicated() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    var printer = try zargs.print.Printer.memory(gpa);
    defer printer.deinit();

    try show.printSymbolNames(&printer, gpa, mods);

    const out = printer.array.writer.written();
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(gpa);
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, out, "\n"), '\n');
    while (it.next()) |line| try names.append(gpa, line);

    // Module names and top-level symbols are present.
    try testz.expectTrue(std.mem.indexOf(u8, out, "sample\n") != null);
    try testz.expectTrue(std.mem.indexOf(u8, out, "math\n") != null);
    try testz.expectTrue(std.mem.indexOf(u8, out, "add\n") != null);
    // Names nested inside a container are present too (bare-name match, same
    // as `findSymbol`).
    try testz.expectTrue(std.mem.indexOf(u8, out, "zero\n") != null);
    // `multiply` is defined in both sample.zig and math.zig -- listed once.
    var occurrences: usize = 0;
    for (names.items) |n| {
        if (std.mem.eql(u8, n, "multiply")) occurrences += 1;
    }
    try testz.expectEqual(occurrences, 1);
    // Import-const aliases never appear.
    try testz.expectTrue(std.mem.indexOf(u8, out, "std\n") == null);
    // Output is sorted.
    var sorted = true;
    for (1..names.items.len) |i| {
        if (!std.mem.lessThan(u8, names.items[i - 1], names.items[i])) sorted = false;
    }
    try testz.expectTrue(sorted);
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
