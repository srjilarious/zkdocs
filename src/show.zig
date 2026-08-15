//! Terminal output for `zkdocs show <symbol>`, `zkdocs --dump`, and
//! `zkdocs --list-symbols` (plans/future_features.md §10.1, §10.2): finds
//! symbols across all modules and nested container decls by bare name or by
//! a dotted, scoped query (`MyStruct.init`, or `math.multiply` to qualify by
//! module -- see `chainMatches`), and prints signatures, doc comments, and
//! (for containers) fields/decls to a zargunaught `Printer`. A query
//! matching a module's name dumps that module's whole API instead of a
//! single symbol. `--verbose` additionally prints a function's body source,
//! highlighted. `printSymbolNames` prints the flat name list that shell
//! completion scripts query for `show <TAB>`.
const std = @import("std");
const Allocator = std.mem.Allocator;
const zargs = @import("zargunaught");
const Printer = zargs.print.Printer;
const symbols = @import("./symbols.zig");
const term = @import("./term_render.zig");
const highlight = @import("./highlight.zig");

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
        .error_set => |e| e.name,
        .@"test", .other => null,
    };
}

/// `const foo = @import("./foo.zig");`-style aliases are plumbing, not
/// meaningful API surface -- excluded from every listing and match so they
/// don't clutter a module dump or get treated as a "symbol" to show.
fn isImportConst(sym: *const symbols.Symbol) bool {
    return switch (sym.*) {
        .variable => |v| v.is_import,
        else => false,
    };
}

/// Largest supported `module.Container.Nested...symbol` chain for query
/// matching -- Zig container nesting never gets remotely close to this in
/// practice, so a fixed buffer avoids allocating on every symbol checked.
const max_query_chain = 32;

/// True if `query_segs` is a trailing, contiguous match against the
/// `module.name` / container-breadcrumb / symbol-name chain, e.g. query
/// `["MyStruct", "init"]` matches a symbol named `init` whose immediate
/// parent container is `MyStruct`, regardless of module or outer nesting;
/// query `["init"]` alone matches an `init` anywhere (the pre-existing
/// bare-name behavior); query `["math", "multiply"]` matches only the
/// top-level `multiply` in the `math` module, not `sample`'s.
fn chainMatches(
    module_name: []const u8,
    path: []const []const u8,
    sym_name: []const u8,
    query_segs: []const []const u8,
) bool {
    if (query_segs.len == 0) return false;

    const chain_len = path.len + 2; // + module name + symbol name
    if (chain_len > max_query_chain or query_segs.len > chain_len) return false;

    var chain: [max_query_chain][]const u8 = undefined;
    chain[0] = module_name;
    for (path, 0..) |p, i| chain[1 + i] = p;
    chain[chain_len - 1] = sym_name;

    const tail = chain[chain_len - query_segs.len .. chain_len];
    for (tail, query_segs) |c, q| {
        if (!std.mem.eql(u8, c, q)) return false;
    }
    return true;
}

fn findInSymbols(
    allocator: Allocator,
    module: *const symbols.Module,
    syms: []const symbols.Symbol,
    path: *std.ArrayList([]const u8),
    query_segs: []const []const u8,
    out: *std.ArrayList(Match),
) !void {
    for (syms) |*sym| {
        if (isImportConst(sym)) continue;

        if (symbolName(sym)) |sym_name| {
            if (chainMatches(module.name, path.items, sym_name, query_segs)) {
                try out.append(allocator, .{
                    .module = module,
                    .path = try allocator.dupe([]const u8, path.items),
                    .symbol = sym,
                });
            }
        }
        if (sym.* == .container) {
            try path.append(allocator, sym.container.name);
            try findInSymbols(allocator, module, sym.container.decls.items, path, query_segs, out);
            _ = path.pop();
        } else if (sym.* == .function and sym.function.generic_return != null) {
            // A generic type constructor (`fn Stack(comptime T: type) type`)
            // is queryable the same way a plain container is, e.g.
            // `zkdocs show Stack.push`.
            try path.append(allocator, sym.function.name);
            try findInSymbols(allocator, module, sym.function.generic_return.?.decls.items, path, query_segs, out);
            _ = path.pop();
        }
    }
}

/// Search every module (top-level symbols and nested container decls) for
/// symbols matching `query`. A bare name (`init`) matches anywhere; a
/// dotted, scoped query (`MyStruct.init`, or `math.multiply` to qualify by
/// module) matches as many trailing segments as given -- see `chainMatches`.
/// Returns every match rather than erroring on ambiguity, since the same
/// name commonly appears on more than one container -- callers are expected
/// to print each match labeled with its module/container path so the user
/// can tell them apart.
pub fn findSymbol(allocator: Allocator, modules: []const symbols.Module, query: []const u8) ![]Match {
    var query_segs: std.ArrayList([]const u8) = .empty;
    defer query_segs.deinit(allocator);
    var it = std.mem.splitScalar(u8, query, '.');
    while (it.next()) |seg| try query_segs.append(allocator, seg);

    var out: std.ArrayList(Match) = .empty;
    errdefer out.deinit(allocator);

    for (modules) |*mod| {
        var path: std.ArrayList([]const u8) = .empty;
        defer path.deinit(allocator);
        try findInSymbols(allocator, mod, mod.symbols.items, &path, query_segs.items, &out);
    }

    return out.toOwnedSlice(allocator);
}

/// Exact match against a module's name (not a symbol inside it) -- used so
/// `zkdocs show <module>` dumps that module's whole API.
pub fn findModule(modules: []const symbols.Module, name: []const u8) ?*const symbols.Module {
    for (modules) |*mod| {
        if (std.mem.eql(u8, mod.name, name)) return mod;
    }
    return null;
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

/// Prints a function's body source (`--verbose`), highlighted when `color`.
fn printFunctionBody(printer: *const Printer, allocator: Allocator, body_src: []const u8, indent: usize, color: bool) !void {
    if (color) {
        const highlighted = try highlight.highlightAnsi(allocator, "zig", body_src);
        defer allocator.free(highlighted);
        try printIndented(printer, highlighted, indent);
    } else {
        try printIndented(printer, body_src, indent);
    }
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
    if (f.generic_return != null) try printer.print("  {s}[generic]{s}", .{ sc(color, term.gray), sc(color, term.reset) });
    try printer.print("\n", .{});
}

fn printVariableSig(printer: *const Printer, indent: usize, v: symbols.Variable, color: bool) !void {
    try printer.printNum(" ", indent);
    try printer.print("{s}const {s}{s}", .{ sc(color, term.bold), v.name, sc(color, term.reset) });
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

fn printErrorSetSig(printer: *const Printer, indent: usize, e: symbols.ErrorSet, color: bool) !void {
    try printer.printNum(" ", indent);
    try printer.print("{s}error {s}{s}", .{ sc(color, term.bold), e.name, sc(color, term.reset) });
    if (e.is_pub) try printer.print("  {s}[pub]{s}", .{ sc(color, term.gray), sc(color, term.reset) });
    try printer.print("\n", .{});
}

/// Print a container's fields and nested decls (but not its own signature/doc)
/// at `indent + 2`. Shared by the `.container` case and, for a function whose
/// return type is itself a generic container (`fn Stack(comptime T: type) type`),
/// the `.function` case -- both expose the same fields/methods, just reached
/// via a plain type versus a generic type constructor.
fn printContainerBody(printer: *const Printer, allocator: Allocator, c: symbols.Container, indent: usize, color: bool, verbose: bool) anyerror!void {
    for (c.fields) |field| {
        try printer.printNum(" ", indent + 2);
        try printer.print("{s}.{s}{s}", .{ sc(color, term.bold), field.name, sc(color, term.reset) });
        if (field.type_src) |t| try printer.print(": {s}{s}{s}", .{ sc(color, term.green), t, sc(color, term.reset) });
        try printer.print("\n", .{});
        try printDoc(printer, allocator, field.doc, indent + 4, color);
    }

    const decls = c.decls.items;
    var printed_header = false;
    for (decls) |*decl| {
        if (isImportConst(decl)) continue;
        if (!printed_header) {
            try printer.printNum(" ", indent + 2);
            try printer.print("{s}--- decls ---{s}\n", .{ sc(color, term.gray), sc(color, term.reset) });
            printed_header = true;
        }
        try printSymbol(printer, allocator, decl, indent + 2, color, verbose);
    }
}

/// Print one symbol (and, for containers, its fields and nested decls)
/// starting at `indent` spaces. `verbose` additionally prints a function's
/// highlighted body source.
pub fn printSymbol(printer: *const Printer, allocator: Allocator, sym: *const symbols.Symbol, indent: usize, color: bool, verbose: bool) !void {
    switch (sym.*) {
        .function => |f| {
            try printFunctionSig(printer, indent, f, color);
            try printDoc(printer, allocator, f.doc, indent + 2, color);
            if (f.generic_return) |gr| {
                // Body source is intentionally null for generic-return
                // functions (see symbols.zig) -- the container it returns
                // is the useful thing to show instead.
                try printContainerBody(printer, allocator, gr, indent, color, verbose);
            }
            if (verbose) {
                if (f.body_src) |body| try printFunctionBody(printer, allocator, body, indent + 2, color);
            }
        },
        .variable => |v| {
            try printVariableSig(printer, indent, v, color);
            try printDoc(printer, allocator, v.doc, indent + 2, color);
        },
        .container => |c| {
            try printContainerSig(printer, indent, c, color);
            try printDoc(printer, allocator, c.doc, indent + 2, color);
            try printContainerBody(printer, allocator, c, indent, color, verbose);
        },
        .error_set => |e| {
            try printErrorSetSig(printer, indent, e, color);
            try printDoc(printer, allocator, e.doc, indent + 2, color);

            for (e.errors) |err_val| {
                try printer.printNum(" ", indent + 2);
                try printer.print("{s}error.{s}{s}\n", .{ sc(color, term.bold), err_val.name, sc(color, term.reset) });
                try printDoc(printer, allocator, err_val.doc, indent + 4, color);
            }
        },
        .@"test", .other => {},
    }
}

/// Print one module's header/doc and every non-import top-level symbol.
fn printModule(printer: *const Printer, allocator: Allocator, mod: *const symbols.Module, color: bool, verbose: bool) !void {
    try printer.print("{s}=== module {s} {s}(path: {s}){s}\n", .{
        sc(color, term.bold), mod.name, sc(color, term.gray), mod.path, sc(color, term.reset),
    });
    try printDoc(printer, allocator, mod.doc, 2, color);
    for (mod.symbols.items) |*sym| {
        if (isImportConst(sym)) continue;
        try printSymbol(printer, allocator, sym, 1, color, verbose);
    }
    try printer.print("\n", .{});
}

/// Print the entire extracted module graph (`zkdocs --dump`).
pub fn printDump(printer: *const Printer, allocator: Allocator, modules: []const symbols.Module, color: bool, verbose: bool) !void {
    for (modules) |*mod| try printModule(printer, allocator, mod, color, verbose);
}

fn collectNames(allocator: Allocator, syms: []const symbols.Symbol, seen: *std.StringHashMap(void)) !void {
    for (syms) |*sym| {
        if (isImportConst(sym)) continue;
        if (symbolName(sym)) |name| try seen.put(name, {});
        if (sym.* == .container) {
            try collectNames(allocator, sym.container.decls.items, seen);
        } else if (sym.* == .function and sym.function.generic_return != null) {
            try collectNames(allocator, sym.function.generic_return.?.decls.items, seen);
        }
    }
}

/// Print every module name and every non-import symbol name (top-level and
/// nested in containers), one per line, deduplicated and sorted -- the data
/// source for `zkdocs --generate-completion`'s dynamic `show <TAB>`
/// completion (plans/future_features.md §10.2). Matches `findSymbol`'s
/// bare-name matching: any name printed here is one `zkdocs show <name>`
/// will find.
pub fn printSymbolNames(printer: *const Printer, allocator: Allocator, modules: []const symbols.Module) !void {
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();

    for (modules) |*mod| {
        try seen.put(mod.name, {});
        try collectNames(allocator, mod.symbols.items, &seen);
    }

    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(allocator);
    var it = seen.keyIterator();
    while (it.next()) |k| try names.append(allocator, k.*);

    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    for (names.items) |name| try printer.print("{s}\n", .{name});
}

/// Print whatever matches `query` (`zkdocs show <query>`): a module whose
/// name matches `query` exactly is printed as its whole API; any symbols
/// matching `query` (bare or scoped, see `findSymbol`) are printed after.
/// Returns `false` (with nothing printed) when neither matches anything.
pub fn printShow(printer: *const Printer, allocator: Allocator, modules: []const symbols.Module, query: []const u8, color: bool, verbose: bool) !bool {
    var printed_anything = false;

    if (findModule(modules, query)) |mod| {
        try printModule(printer, allocator, mod, color, verbose);
        printed_anything = true;
    }

    const matches = try findSymbol(allocator, modules, query);
    defer allocator.free(matches);

    for (matches, 0..) |m, i| {
        if (printed_anything or i > 0) try printer.print("\n", .{});
        try printer.print("{s}{s}", .{ sc(color, term.gray), m.module.name });
        for (m.path) |p| try printer.print(" > {s}", .{p});
        try printer.print("{s}\n", .{sc(color, term.reset)});
        try printSymbol(printer, allocator, m.symbol, 0, color, verbose);
        printed_anything = true;
    }

    return printed_anything;
}
