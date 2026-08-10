const std = @import("std");
const zkdocs = @import("zkdocs");
const symbols = zkdocs.symbols;

/// Set once in main() before any test runs; used by every group that needs
/// to read files or call into extractModuleGraph/renderSite.
pub var g_Io: std.Io = undefined;

pub fn findModule(mods: []const symbols.Module, name: []const u8) ?symbols.Module {
    for (mods) |m| {
        if (std.mem.eql(u8, m.name, name)) return m;
    }
    return null;
}

pub fn findSymbol(syms: []const symbols.Symbol, kind: symbols.SymbolKind, name: []const u8) ?symbols.Symbol {
    for (syms) |sym| {
        if (@as(symbols.SymbolKind, sym) != kind) continue;
        const sym_name = switch (sym) {
            .function => |f| f.name,
            .variable => |v| v.name,
            .container => |c| c.name,
            .@"test", .other => continue,
        };
        if (std.mem.eql(u8, sym_name, name)) return sym;
    }
    return null;
}
