//* These tests check that doc comments (single-line and multi-line) are
//* extracted correctly, and that private declarations have no doc comment.
const std = @import("std");
const testz = @import("testz");
const zkdocs = @import("zkdocs");
const symbols = zkdocs.symbols;
const fix = @import("fixtures.zig");

pub fn singleLineDoc() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    const sample = fix.findModule(mods, "sample") orelse return error.SampleModuleNotFound;
    const sym = fix.findSymbol(sample.symbols.items, .function, "sub") orelse {
        return error.SymbolNotFound;
    };
    const doc = sym.function.doc orelse return error.NoDoc;
    try testz.expectEqualStr(doc, "Subtracts `b` from `a`.");
}

pub fn multiLineDoc() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    const sample = fix.findModule(mods, "sample") orelse return error.SampleModuleNotFound;
    const sym = fix.findSymbol(sample.symbols.items, .function, "add") orelse {
        return error.SymbolNotFound;
    };
    const doc = sym.function.doc orelse return error.NoDoc;
    try testz.expectTrue(std.mem.startsWith(u8, doc, "Adds two integers"));
    try testz.expectTrue(std.mem.indexOf(u8, doc, "Returns the sum") != null);
}

pub fn noDocForPrivate() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    const sample = fix.findModule(mods, "sample") orelse return error.SampleModuleNotFound;
    const sym = fix.findSymbol(sample.symbols.items, .function, "privateHelper") orelse {
        return error.SymbolNotFound;
    };
    try testz.expectTrue(sym.function.doc == null);
}
