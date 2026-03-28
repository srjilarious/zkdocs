const std = @import("std");
const testz = @import("testz");
const symbols = @import("symbols");

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn findModule(mods: []const symbols.Module, name: []const u8) ?symbols.Module {
    for (mods) |m| {
        if (std.mem.eql(u8, m.name, name)) return m;
    }
    return null;
}

fn findSymbol(syms: []const symbols.Symbol, kind: symbols.SymbolKind, name: []const u8) ?symbols.Symbol {
    for (syms) |sym| {
        if (sym.kind != kind) continue;
        const sym_name = switch (kind) {
            .function => if (sym.function) |f| f.name else continue,
            .variable => if (sym.variable) |v| v.name else continue,
            .container => if (sym.container) |c| c.name else continue,
            else => continue,
        };
        if (std.mem.eql(u8, sym_name, name)) return sym;
    }
    return null;
}

// ---------------------------------------------------------------------------
// Tests: function extraction
// ---------------------------------------------------------------------------

const FunctionTests = struct {
    pub fn addFunctionIsExtracted() !void {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        const mods = try symbols.extractModuleGraph(allocator, "sample.zig");
        defer symbols.deinitModules(allocator, mods);

        const sample = findModule(mods, "sample") orelse return error.SampleModuleNotFound;
        const sym = findSymbol(sample.symbols.items, .function, "add") orelse {
            return error.SymbolNotFound;
        };
        const f = sym.function.?;
        try testz.expectTrue(f.is_pub);
        try testz.expectEqual(f.params.len, 2);
        try testz.expectEqualStr(f.params[0].name.?, "a");
        try testz.expectEqualStr(f.return_type_src.?, "i32");
    }

    pub fn privateHelperIsExtracted() !void {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        const mods = try symbols.extractModuleGraph(allocator, "sample.zig");
        defer symbols.deinitModules(allocator, mods);

        const sample = findModule(mods, "sample") orelse return error.SampleModuleNotFound;
        const sym = findSymbol(sample.symbols.items, .function, "privateHelper") orelse {
            return error.SymbolNotFound;
        };
        try testz.expectTrue(!sym.function.?.is_pub);
    }
};

// ---------------------------------------------------------------------------
// Tests: doc comment extraction
// ---------------------------------------------------------------------------

const DocTests = struct {
    pub fn singleLineDoc() !void {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        const mods = try symbols.extractModuleGraph(allocator, "sample.zig");
        defer symbols.deinitModules(allocator, mods);

        const sample = findModule(mods, "sample") orelse return error.SampleModuleNotFound;
        const sym = findSymbol(sample.symbols.items, .function, "sub") orelse {
            return error.SymbolNotFound;
        };
        const doc = sym.function.?.doc orelse return error.NoDoc;
        try testz.expectEqualStr(doc, "Subtracts `b` from `a`.");
    }

    pub fn multiLineDoc() !void {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        const mods = try symbols.extractModuleGraph(allocator, "sample.zig");
        defer symbols.deinitModules(allocator, mods);

        const sample = findModule(mods, "sample") orelse return error.SampleModuleNotFound;
        const sym = findSymbol(sample.symbols.items, .function, "add") orelse {
            return error.SymbolNotFound;
        };
        const doc = sym.function.?.doc orelse return error.NoDoc;
        try testz.expectTrue(std.mem.startsWith(u8, doc, "Adds two integers"));
        try testz.expectTrue(std.mem.indexOf(u8, doc, "Returns the sum") != null);
    }

    pub fn noDocForPrivate() !void {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        const mods = try symbols.extractModuleGraph(allocator, "sample.zig");
        defer symbols.deinitModules(allocator, mods);

        const sample = findModule(mods, "sample") orelse return error.SampleModuleNotFound;
        const sym = findSymbol(sample.symbols.items, .function, "privateHelper") orelse {
            return error.SymbolNotFound;
        };
        try testz.expectTrue(sym.function.?.doc == null);
    }
};

// ---------------------------------------------------------------------------
// Tests: container extraction
// ---------------------------------------------------------------------------

const ContainerTests = struct {
    pub fn structFieldsExtracted() !void {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        const mods = try symbols.extractModuleGraph(allocator, "sample.zig");
        defer symbols.deinitModules(allocator, mods);

        const sample = findModule(mods, "sample") orelse return error.SampleModuleNotFound;
        const sym = findSymbol(sample.symbols.items, .container, "Point") orelse {
            return error.SymbolNotFound;
        };
        const c = sym.container.?;
        try testz.expectTrue(c.is_pub);
        try testz.expectEqual(@intFromEnum(c.kind), @intFromEnum(symbols.ContainerKind.@"struct"));
        try testz.expectEqual(c.fields.len, 2);
        try testz.expectEqualStr(c.fields[0].name, "x");
        try testz.expectEqualStr(c.fields[1].name, "y");
    }

    pub fn structMethodsExtracted() !void {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        const mods = try symbols.extractModuleGraph(allocator, "sample.zig");
        defer symbols.deinitModules(allocator, mods);

        const sample = findModule(mods, "sample") orelse return error.SampleModuleNotFound;
        const sym = findSymbol(sample.symbols.items, .container, "Point") orelse {
            return error.SymbolNotFound;
        };
        const c = sym.container.?;
        try testz.expectTrue(c.decls.items.len >= 2);
        // zero() and translate() should be present
        var found_zero = false;
        var found_translate = false;
        for (c.decls.items) |decl| {
            if (decl.kind == .function) {
                if (decl.function) |f| {
                    if (std.mem.eql(u8, f.name, "zero")) found_zero = true;
                    if (std.mem.eql(u8, f.name, "translate")) found_translate = true;
                }
            }
        }
        try testz.expectTrue(found_zero);
        try testz.expectTrue(found_translate);
    }

    pub fn enumFieldsExtracted() !void {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        const mods = try symbols.extractModuleGraph(allocator, "sample.zig");
        defer symbols.deinitModules(allocator, mods);

        const sample = findModule(mods, "sample") orelse return error.SampleModuleNotFound;
        const sym = findSymbol(sample.symbols.items, .container, "Color") orelse {
            return error.SymbolNotFound;
        };
        const c = sym.container.?;
        try testz.expectEqual(@intFromEnum(c.kind), @intFromEnum(symbols.ContainerKind.@"enum"));
        try testz.expectEqual(c.fields.len, 3);
        try testz.expectEqualStr(c.fields[0].name, "red");
        try testz.expectEqualStr(c.fields[1].name, "green");
        try testz.expectEqualStr(c.fields[2].name, "blue");
    }
};

// ---------------------------------------------------------------------------
// Tests: import following
// ---------------------------------------------------------------------------

const ImportTests = struct {
    pub fn mathModuleFollowed() !void {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        const mods = try symbols.extractModuleGraph(allocator, "sample.zig");
        defer symbols.deinitModules(allocator, mods);

        // Should have at least two modules: sample and math
        try testz.expectTrue(mods.len >= 2);

        // Find the math module
        var found_math = false;
        for (mods) |mod| {
            if (std.mem.eql(u8, mod.name, "math")) {
                found_math = true;
                // math.zig exports multiply, divide, clamp, Vec2
                const mul = findSymbol(mod.symbols.items, .function, "multiply") orelse {
                    return error.SymbolNotFound;
                };
                try testz.expectTrue(mul.function.?.is_pub);
            }
        }
        try testz.expectTrue(found_math);
    }

    pub fn vec2ContainerInMath() !void {
        var gpa = std.heap.GeneralPurposeAllocator(.{}){};
        defer _ = gpa.deinit();
        const allocator = gpa.allocator();

        const mods = try symbols.extractModuleGraph(allocator, "sample.zig");
        defer symbols.deinitModules(allocator, mods);

        for (mods) |mod| {
            if (!std.mem.eql(u8, mod.name, "math")) continue;
            const sym = findSymbol(mod.symbols.items, .container, "Vec2") orelse {
                return error.SymbolNotFound;
            };
            const c = sym.container.?;
            try testz.expectEqual(c.fields.len, 2);
            return;
        }
        return error.MathModuleNotFound;
    }
};

// ---------------------------------------------------------------------------
// Test runner
// ---------------------------------------------------------------------------

const DiscoveredTests = testz.discoverTests(.{
    testz.Group{ .name = "Function Extraction", .tag = "functions", .mod = FunctionTests },
    testz.Group{ .name = "Doc Comments", .tag = "docs", .mod = DocTests },
    testz.Group{ .name = "Container Extraction", .tag = "containers", .mod = ContainerTests },
    testz.Group{ .name = "Import Following", .tag = "imports", .mod = ImportTests },
}, .{});

pub fn main() !void {
    try testz.testzRunner(DiscoveredTests);
}
