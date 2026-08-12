//! Terminal output for `zkdocs show <symbol>` and `zkdocs --dump`
//! (plans/future_features.md §10.1): finds symbols by bare name across all
//! modules and nested container decls, and prints signatures, doc comments,
//! and (for containers) fields/decls to a zargunaught `Printer`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const zargs = @import("zargunaught");
const Printer = zargs.print.Printer;
const symbols = @import("./symbols.zig");
const term = @import("./term_render.zig");

pub const Match = struct {
    module: *const symbols.Module,
    /// Container-name breadcrumb from the module down to the symbol's
    /// immediate parent; empty for a top-level module symbol.
    path: []const []const u8,
    symbol: *const symbols.Symbol,
};

fn symbolName(sym: *const symbols.Symbol) ?[]const u8 {
    return switch (sym.*) {
        .function => |f| f.name,
        .variable => |v| v.name,
        .container => |c| c.name,
        .@"test", .other => null,
    };
}

fn findInSymbols(
    allocator: Allocator,
    module: *const symbols.Module,
    syms: []const symbols.Symbol,
    path: *std.ArrayList([]const u8),
    name: []const u8,
    out: *std.ArrayList(Match),
) !void {
    for (syms) |*sym| {
        if (symbolName(sym)) |sym_name| {
            if (std.mem.eql(u8, sym_name, name)) {
                try out.append(allocator, .{
                    .module = module,
                    .path = try allocator.dupe([]const u8, path.items),
                    .symbol = sym,
                });
            }
        }
        if (sym.* == .container) {
            try path.append(allocator, sym.container.name);
            try findInSymbols(allocator, module, sym.container.decls.items, path, name, out);
            _ = path.pop();
        }
    }
}

/// Search every module (top-level symbols and nested container decls) for
/// symbols named `name`. Returns every match rather than erroring on
/// ambiguity, since the same name (e.g. `init`) commonly appears on more
/// than one container -- callers are expected to print each match labeled
/// with its module/container path so the user can tell them apart.
pub fn findSymbol(allocator: Allocator, modules: []const symbols.Module, name: []const u8) ![]Match {
    var out: std.ArrayList(Match) = .empty;
    errdefer out.deinit(allocator);

    for (modules) |*mod| {
        var path: std.ArrayList([]const u8) = .empty;
        defer path.deinit(allocator);
        try findInSymbols(allocator, mod, mod.symbols.items, &path, name, &out);
    }

    return out.toOwnedSlice(allocator);
}

// ── Printing ────────────────────────────────────────────────────────────────

fn sc(color: bool, code: []const u8) []const u8 {
    return if (color) code else "";
}

fn printIndented(printer: *const Printer, text: []const u8, indent: usize) !void {
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    while (it.next()) |line| {
        try printer.printNum(" ", indent);
        try printer.print("{s}\n", .{line});
    }
}

fn printDoc(printer: *const Printer, allocator: Allocator, doc: ?[]const u8, indent: usize, color: bool) !void {
    const d = doc orelse return;
    const rendered = try term.renderDoc(allocator, d, color);
    defer allocator.free(rendered);
    try printIndented(printer, rendered, indent);
}

fn printFunctionSig(printer: *const Printer, indent: usize, f: symbols.Function, color: bool) !void {
    try printer.printNum(" ", indent);
    try printer.print("{s}fn {s}{s}(", .{ sc(color, term.bold), f.name, sc(color, term.reset) });
    for (f.params, 0..) |p, i| {
        if (i > 0) try printer.print(", ", .{});
        if (p.name) |n| try printer.print("{s}: ", .{n});
        try printer.print("{s}{s}{s}", .{ sc(color, term.green), p.type_src, sc(color, term.reset) });
    }
    try printer.print(")", .{});
    if (f.return_type_src) |r| try printer.print(" {s}{s}{s}", .{ sc(color, term.green), r, sc(color, term.reset) });
    if (f.is_pub) try printer.print("  {s}[pub]{s}", .{ sc(color, term.gray), sc(color, term.reset) });
    try printer.print("\n", .{});
}

fn printVariableSig(printer: *const Printer, indent: usize, v: symbols.Variable, color: bool) !void {
    try printer.printNum(" ", indent);
    try printer.print("{s}{s} {s}{s}", .{
        sc(color, term.bold), if (v.is_import) "import" else "const", v.name, sc(color, term.reset),
    });
    if (v.type_src) |t| try printer.print(": {s}{s}{s}", .{ sc(color, term.green), t, sc(color, term.reset) });
    if (v.is_pub) try printer.print("  {s}[pub]{s}", .{ sc(color, term.gray), sc(color, term.reset) });
    try printer.print("\n", .{});
}

fn printContainerSig(printer: *const Printer, indent: usize, c: symbols.Container, color: bool) !void {
    try printer.printNum(" ", indent);
    try printer.print("{s}{s} {s}{s}", .{ sc(color, term.bold), @tagName(c.kind), c.name, sc(color, term.reset) });
    if (c.is_pub) try printer.print("  {s}[pub]{s}", .{ sc(color, term.gray), sc(color, term.reset) });
    try printer.print("\n", .{});
}

/// Print one symbol (and, for containers, its fields and nested decls)
/// starting at `indent` spaces.
pub fn printSymbol(printer: *const Printer, allocator: Allocator, sym: *const symbols.Symbol, indent: usize, color: bool) !void {
    switch (sym.*) {
        .function => |f| {
            try printFunctionSig(printer, indent, f, color);
            try printDoc(printer, allocator, f.doc, indent + 2, color);
        },
        .variable => |v| {
            try printVariableSig(printer, indent, v, color);
            try printDoc(printer, allocator, v.doc, indent + 2, color);
        },
        .container => |c| {
            try printContainerSig(printer, indent, c, color);
            try printDoc(printer, allocator, c.doc, indent + 2, color);

            for (c.fields) |field| {
                try printer.printNum(" ", indent + 2);
                try printer.print("{s}.{s}{s}", .{ sc(color, term.bold), field.name, sc(color, term.reset) });
                if (field.type_src) |t| try printer.print(": {s}{s}{s}", .{ sc(color, term.green), t, sc(color, term.reset) });
                try printer.print("\n", .{});
                try printDoc(printer, allocator, field.doc, indent + 4, color);
            }

            if (c.decls.items.len > 0) {
                try printer.printNum(" ", indent + 2);
                try printer.print("{s}--- decls ---{s}\n", .{ sc(color, term.gray), sc(color, term.reset) });
                for (c.decls.items) |*decl| try printSymbol(printer, allocator, decl, indent + 2, color);
            }
        },
        .@"test", .other => {},
    }
}

/// Print the entire extracted module graph (`zkdocs --dump`).
pub fn printDump(printer: *const Printer, allocator: Allocator, modules: []const symbols.Module, color: bool) !void {
    for (modules) |*mod| {
        try printer.print("{s}=== module {s} {s}(path: {s}){s}\n", .{
            sc(color, term.bold), mod.name, sc(color, term.gray), mod.path, sc(color, term.reset),
        });
        try printDoc(printer, allocator, mod.doc, 2, color);
        for (mod.symbols.items) |*sym| try printSymbol(printer, allocator, sym, 1, color);
        try printer.print("\n", .{});
    }
}

/// Print every symbol matching `name` (`zkdocs show <name>`). Returns
/// `false` (with nothing printed) when no symbol matches.
pub fn printShow(printer: *const Printer, allocator: Allocator, modules: []const symbols.Module, name: []const u8, color: bool) !bool {
    const matches = try findSymbol(allocator, modules, name);
    defer allocator.free(matches);

    if (matches.len == 0) return false;

    for (matches, 0..) |m, i| {
        if (i > 0) try printer.print("\n", .{});
        try printer.print("{s}{s}", .{ sc(color, term.gray), m.module.name });
        for (m.path) |p| try printer.print(" > {s}", .{p});
        try printer.print("{s}\n", .{sc(color, term.reset)});
        try printSymbol(printer, allocator, m.symbol, 0, color);
    }

    return true;
}
