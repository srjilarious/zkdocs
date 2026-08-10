//* This test module checks that the `symbols` module correctly follows
//* imports and extracts symbols from multiple modules, not just the root
//* file. The `sample.zig` file imports a `math.zig` module, so we check
//* that symbols from `math.zig` are also extracted and that their
//* properties (like `pub`) are correct.
const std = @import("std");
const testz = @import("testz");
const zkdocs = @import("zkdocs");
const symbols = zkdocs.symbols;
const fix = @import("fixtures.zig");

pub fn mathModuleFollowed() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    // Should have at least two modules: sample and math
    try testz.expectTrue(mods.len >= 2);

    // Find the math module
    var found_math = false;
    for (mods) |mod| {
        if (std.mem.eql(u8, mod.name, "math")) {
            found_math = true;
            // math.zig exports multiply, divide, clamp, Vec2
            const mul = fix.findSymbol(mod.symbols.items, .function, "multiply") orelse {
                return error.SymbolNotFound;
            };
            try testz.expectTrue(mul.function.is_pub);
        }
    }
    try testz.expectTrue(found_math);
}

pub fn vec2ContainerInMath() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    for (mods) |mod| {
        if (!std.mem.eql(u8, mod.name, "math")) continue;
        const sym = fix.findSymbol(mod.symbols.items, .container, "Vec2") orelse {
            return error.SymbolNotFound;
        };
        const c = sym.container;
        try testz.expectEqual(c.fields.len, 2);
        return;
    }
    return error.MathModuleNotFound;
}

pub fn missingImportReturnsErrorNotCrash() !void {
    const gpa = std.heap.page_allocator;

    // Regression test for a double-free: extracting a module whose
    // import can't be read must surface an error, not abort the
    // process (verified with DebugAllocator prior to the fix).
    const result = symbols.extractModuleGraph(fix.g_Io, gpa, "bad_import.zig");
    if (result) |mods| {
        symbols.deinitModules(gpa, mods);
        return error.ExpectedMissingImportError;
    } else |_| {}
}
