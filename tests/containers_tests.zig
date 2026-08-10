//* This module checks that the `symbols` module correctly extracts struct
//* fields, struct methods, and enum fields from `sample.zig`'s `Point` and
//* `Color` containers.
const std = @import("std");
const testz = @import("testz");
const zkdocs = @import("zkdocs");
const symbols = zkdocs.symbols;
const fix = @import("fixtures.zig");

pub fn structFieldsExtracted() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    const sample = fix.findModule(mods, "sample") orelse return error.SampleModuleNotFound;
    const sym = fix.findSymbol(sample.symbols.items, .container, "Point") orelse {
        return error.SymbolNotFound;
    };
    const c = sym.container;
    try testz.expectTrue(c.is_pub);
    try testz.expectEqual(@intFromEnum(c.kind), @intFromEnum(symbols.ContainerKind.@"struct"));
    try testz.expectEqual(c.fields.len, 2);
    try testz.expectEqualStr(c.fields[0].name, "x");
    try testz.expectEqualStr(c.fields[1].name, "y");
}

pub fn structMethodsExtracted() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    const sample = fix.findModule(mods, "sample") orelse return error.SampleModuleNotFound;
    const sym = fix.findSymbol(sample.symbols.items, .container, "Point") orelse {
        return error.SymbolNotFound;
    };
    const c = sym.container;
    try testz.expectTrue(c.decls.items.len >= 2);
    // zero() and translate() should be present
    var found_zero = false;
    var found_translate = false;
    for (c.decls.items) |decl| {
        if (decl == .function) {
            const f = decl.function;
            if (std.mem.eql(u8, f.name, "zero")) found_zero = true;
            if (std.mem.eql(u8, f.name, "translate")) found_translate = true;
        }
    }
    try testz.expectTrue(found_zero);
    try testz.expectTrue(found_translate);
}

pub fn enumFieldsExtracted() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    const sample = fix.findModule(mods, "sample") orelse return error.SampleModuleNotFound;
    const sym = fix.findSymbol(sample.symbols.items, .container, "Color") orelse {
        return error.SymbolNotFound;
    };
    const c = sym.container;
    try testz.expectEqual(@intFromEnum(c.kind), @intFromEnum(symbols.ContainerKind.@"enum"));
    try testz.expectEqual(c.fields.len, 3);
    try testz.expectEqualStr(c.fields[0].name, "red");
    try testz.expectEqualStr(c.fields[1].name, "green");
    try testz.expectEqualStr(c.fields[2].name, "blue");
}
