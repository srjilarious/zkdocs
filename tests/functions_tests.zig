//* This test module checks that the `symbols` module correctly extracts information from Zig source files, and that the `markdown` and `render` modules correctly handle doc comments and link resolution. The tests use a sample Zig file `sample.zig` which contains various constructs to test against.
const std = @import("std");
const testz = @import("testz");
const zkdocs = @import("zkdocs");
const symbols = zkdocs.symbols;
const fix = @import("fixtures.zig");

pub fn addFunctionIsExtracted() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    const sample = fix.findModule(mods, "sample") orelse return error.SampleModuleNotFound;
    const sym = fix.findSymbol(sample.symbols.items, .function, "add") orelse {
        return error.SymbolNotFound;
    };
    const f = sym.function;
    try testz.expectTrue(f.is_pub);
    try testz.expectEqual(f.params.len, 2);
    try testz.expectEqualStr(f.params[0].name.?, "a");
    try testz.expectEqualStr(f.return_type_src.?, "i32");
}

pub fn privateHelperIsExtracted() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    const sample = fix.findModule(mods, "sample") orelse return error.SampleModuleNotFound;
    const sym = fix.findSymbol(sample.symbols.items, .function, "privateHelper") orelse {
        return error.SymbolNotFound;
    };
    try testz.expectTrue(!sym.function.is_pub);
}
