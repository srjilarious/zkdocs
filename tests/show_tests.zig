//* These tests cover `show.zig`'s `findSymbol` (plans/future_features.md
//* §10.1, `zkdocs show <symbol>`): bare-name lookup across all modules and
//* nested container decls, including the case where the same name appears
//* more than once (e.g. `multiply` is defined both in `sample.zig` and in
//* the `math.zig` module it imports) -- `findSymbol` is expected to return
//* every match rather than pick one, since the caller prints each labeled
//* by its module/container path. Also covers dotted, scoped queries
//* (`Point.zero`, `math.multiply`) that narrow the match to a specific
//* container or module.
const std = @import("std");
const testz = @import("testz");
const zkdocs = @import("zkdocs");
const symbols = zkdocs.symbols;
const show = zkdocs.show;
const fix = @import("fixtures.zig");

pub fn findsSingleTopLevelFunction() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    const matches = try show.findSymbol(gpa, mods, "add");
    defer gpa.free(matches);

    try testz.expectEqual(matches.len, 1);
    try testz.expectEqualStr(matches[0].module.name, "sample");
    try testz.expectEqual(matches[0].path.len, 0);
    try testz.expectEqualStr(matches[0].symbol.function.name, "add");
}

pub fn findsSymbolNestedInsideContainer() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    const matches = try show.findSymbol(gpa, mods, "zero");
    defer gpa.free(matches);

    try testz.expectEqual(matches.len, 1);
    try testz.expectEqualStr(matches[0].module.name, "sample");
    try testz.expectEqual(matches[0].path.len, 1);
    try testz.expectEqualStr(matches[0].path[0], "Point");
    try testz.expectEqualStr(matches[0].symbol.function.name, "zero");
}

pub fn returnsEveryMatchForAnAmbiguousName() !void {
    const gpa = std.heap.page_allocator;

    // `multiply` is defined at the top level of both `sample.zig` (a
    // proxy) and `math.zig` (the real implementation, imported by sample).
    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    const matches = try show.findSymbol(gpa, mods, "multiply");
    defer gpa.free(matches);

    try testz.expectEqual(matches.len, 2);

    var saw_sample = false;
    var saw_math = false;
    for (matches) |m| {
        try testz.expectEqualStr(m.symbol.function.name, "multiply");
        if (std.mem.eql(u8, m.module.name, "sample")) saw_sample = true;
        if (std.mem.eql(u8, m.module.name, "math")) saw_math = true;
    }
    try testz.expectTrue(saw_sample);
    try testz.expectTrue(saw_math);
}

pub fn returnsNoMatchesForUnknownName() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    const matches = try show.findSymbol(gpa, mods, "ThisSymbolDoesNotExist");
    defer gpa.free(matches);

    try testz.expectEqual(matches.len, 0);
}

pub fn scopedContainerQueryMatchesOnlyThatContainer() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    // `Wrapper` also has a decl (`err`, unrelated to `Point.zero`), but
    // `Point.zero` should resolve to exactly the one nested under `Point`.
    const matches = try show.findSymbol(gpa, mods, "Point.zero");
    defer gpa.free(matches);

    try testz.expectEqual(matches.len, 1);
    try testz.expectEqualStr(matches[0].path[0], "Point");
    try testz.expectEqualStr(matches[0].symbol.function.name, "zero");
}

pub fn moduleQualifiedQueryDisambiguatesSameName() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    const matches = try show.findSymbol(gpa, mods, "math.multiply");
    defer gpa.free(matches);

    try testz.expectEqual(matches.len, 1);
    try testz.expectEqualStr(matches[0].module.name, "math");
}

pub fn mismatchedContainerQualifierMatchesNothing() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    // `zero` is nested under `Point`, not `Wrapper`.
    const matches = try show.findSymbol(gpa, mods, "Wrapper.zero");
    defer gpa.free(matches);

    try testz.expectEqual(matches.len, 0);
}
