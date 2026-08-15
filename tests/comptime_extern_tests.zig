//* This module checks comptime/extern documentation (plans/future_features.md
//* §1.2, §1.3) plus the constant-value display fix in terminal `show`:
//* - `comptime T: type` / `comptime value: T` parameters are flagged per-param,
//*   and a function is labeled "comptime-only" when every parameter is
//*   comptime (never for a zero-parameter function -- nothing there forces it).
//* - A bare `comptime { ... }` block at module/container scope is extracted as
//*   its own symbol kind, carrying whatever doc comment precedes it. Zig
//*   itself rejects a `///` comment directly above such a block (confirmed via
//*   `zig ast-check`), so that specific case is exercised against a synthetic
//*   in-memory source string rather than `sample.zig`, which stays realistic,
//*   buildable Zig.
//* - `extern fn` (no body, optional library name) and `export fn` (body,
//*   C-callable) are distinguished, and `callconv(...)` is captured.
//* - `extern struct` / `packed struct` record their layout distinctly from a
//*   plain struct.
//* - `printVariableSig` in terminal `show` now prints a non-import constant's
//*   value, matching what the HTML renderer already did.
const std = @import("std");
const testz = @import("testz");
const zkdocs = @import("zkdocs");
const symbols = zkdocs.symbols;
const render = zkdocs.render;
const show = zkdocs.show;
const zargs = zkdocs.zargunaught;
const fix = @import("fixtures.zig");

fn findParam(f: symbols.Function, name: []const u8) ?symbols.Param {
    for (f.params) |p| {
        if (p.name) |n| if (std.mem.eql(u8, n, name)) return p;
    }
    return null;
}

pub fn mixedComptimeParamsAnnotatedButNotComptimeOnly() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    const sample = fix.findModule(mods, "sample") orelse return error.SampleModuleNotFound;
    const sym = fix.findSymbol(sample.symbols.items, .function, "firstN") orelse return error.SymbolNotFound;
    const f = sym.function;

    try testz.expectTrue((findParam(f, "T") orelse return error.ParamNotFound).is_comptime);
    try testz.expectFalse((findParam(f, "items") orelse return error.ParamNotFound).is_comptime);
    try testz.expectFalse((findParam(f, "n") orelse return error.ParamNotFound).is_comptime);
    try testz.expectFalse(f.is_comptime_only);
}

pub fn allComptimeParamsMarkFunctionComptimeOnly() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    const sample = fix.findModule(mods, "sample") orelse return error.SampleModuleNotFound;
    const sym = fix.findSymbol(sample.symbols.items, .function, "sizeOfPadded") orelse return error.SymbolNotFound;
    const f = sym.function;

    try testz.expectTrue((findParam(f, "T") orelse return error.ParamNotFound).is_comptime);
    try testz.expectTrue((findParam(f, "alignment") orelse return error.ParamNotFound).is_comptime);
    try testz.expectTrue(f.is_comptime_only);
}

pub fn genericConstructorIsAlsoComptimeOnly() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    const sample = fix.findModule(mods, "sample") orelse return error.SampleModuleNotFound;
    const sym = fix.findSymbol(sample.symbols.items, .function, "Stack") orelse return error.SymbolNotFound;
    const f = sym.function;

    try testz.expectTrue(f.generic_return != null);
    try testz.expectTrue(f.is_comptime_only);
}

pub fn zeroParamFunctionIsNeverComptimeOnly() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    const sample = fix.findModule(mods, "sample") orelse return error.SampleModuleNotFound;
    const wrapper_sym = fix.findSymbol(sample.symbols.items, .container, "Wrapper") orelse return error.SymbolNotFound;
    for (wrapper_sym.container.decls.items) |decl| {
        if (decl == .function and std.mem.eql(u8, decl.function.name, "err")) {
            try testz.expectEqual(decl.function.params.len, 0);
            try testz.expectFalse(decl.function.is_comptime_only);
            return;
        }
    }
    return error.SymbolNotFound;
}

pub fn moduleLevelComptimeBlockExtracted() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    const sample = fix.findModule(mods, "sample") orelse return error.SampleModuleNotFound;
    var found: ?symbols.ComptimeBlock = null;
    for (sample.symbols.items) |sym| {
        if (sym == .comptime_block) found = sym.comptime_block;
    }
    const cb = found orelse return error.SymbolNotFound;
    // sample.zig's comptime block is preceded by a plain `//` comment (Zig
    // rejects `///` there), so no doc is expected.
    try testz.expectTrue(cb.doc == null);
    try testz.expectTrue(std.mem.indexOf(u8, cb.body_src, "default_buf_size") != null);
}

/// Zig's parser still produces a usable tree (just an internal warning, per
/// `zig ast-check`) for a `///` comment directly above a bare `comptime {}`
/// block, so zkdocs can and does still extract it -- exercised here against
/// a synthetic source string instead of polluting `sample.zig` with code a
/// real project could never actually compile.
pub fn commentDocOnComptimeBlockStillExtracted() !void {
    const gpa = std.heap.page_allocator;

    const src =
        \\/// explains the compile-time check
        \\comptime {
        \\    @compileLog("checked");
        \\}
        \\
    ;
    const src_z = try gpa.dupeZ(u8, src);
    defer gpa.free(src_z);
    var tree = try std.zig.Ast.parse(gpa, src_z, .zig);
    defer tree.deinit(gpa);

    var module = try symbols.extractModule(gpa, &tree, "inline_mod", "inline_mod.zig", "inline_mod.zig");
    defer symbols.deinitModule(gpa, &module);

    try testz.expectEqual(module.symbols.items.len, 1);
    const sym = module.symbols.items[0];
    try testz.expectTrue(sym == .comptime_block);
    try testz.expectEqualStr(sym.comptime_block.doc.?, "explains the compile-time check");
}

pub fn externFnHasNoBodyAndCapturesLibNameAndCallconv() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    const sample = fix.findModule(mods, "sample") orelse return error.SampleModuleNotFound;
    const sym = fix.findSymbol(sample.symbols.items, .function, "c_abs") orelse return error.SymbolNotFound;
    const f = sym.function;

    try testz.expectTrue(f.is_extern);
    try testz.expectFalse(f.is_export);
    try testz.expectEqualStr(f.extern_lib_name.?, "\"c\"");
    try testz.expectEqualStr(f.callconv_src.?, ".c");
    try testz.expectTrue(f.body_src == null);
}

pub fn exportFnHasBodyAndCallconv() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    const sample = fix.findModule(mods, "sample") orelse return error.SampleModuleNotFound;
    const sym = fix.findSymbol(sample.symbols.items, .function, "addExported") orelse return error.SymbolNotFound;
    const f = sym.function;

    try testz.expectFalse(f.is_extern);
    try testz.expectTrue(f.is_export);
    try testz.expectEqualStr(f.callconv_src.?, ".c");
    try testz.expectTrue(f.body_src != null);
}

pub fn externStructLayoutDetected() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    const sample = fix.findModule(mods, "sample") orelse return error.SampleModuleNotFound;
    const sym = fix.findSymbol(sample.symbols.items, .container, "ExternPoint") orelse return error.SymbolNotFound;
    try testz.expectEqual(@intFromEnum(sym.container.layout.?), @intFromEnum(symbols.ContainerLayout.@"extern"));
}

pub fn packedStructLayoutDetected() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    const sample = fix.findModule(mods, "sample") orelse return error.SampleModuleNotFound;
    const sym = fix.findSymbol(sample.symbols.items, .container, "PackedFlags") orelse return error.SymbolNotFound;
    try testz.expectEqual(@intFromEnum(sym.container.layout.?), @intFromEnum(symbols.ContainerLayout.@"packed"));
}

pub fn plainStructHasNoLayout() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    const sample = fix.findModule(mods, "sample") orelse return error.SampleModuleNotFound;
    const sym = fix.findSymbol(sample.symbols.items, .container, "Point") orelse return error.SymbolNotFound;
    try testz.expectTrue(sym.container.layout == null);
}

pub fn terminalShowPrintsNonImportConstantValue() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    var printer = try zargs.print.Printer.memory(gpa);
    defer printer.deinit();

    _ = try show.printShow(&printer, gpa, mods, "default_buf_size", false, false);
    const out = printer.array.writer.written();
    try testz.expectTrue(std.mem.indexOf(u8, out, "4096") != null);
}

pub fn terminalShowPrintsExternExportComptimeBadgesAndCallconv() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    var printer = try zargs.print.Printer.memory(gpa);
    defer printer.deinit();

    _ = try show.printShow(&printer, gpa, mods, "c_abs", false, false);
    _ = try show.printShow(&printer, gpa, mods, "addExported", false, false);
    _ = try show.printShow(&printer, gpa, mods, "sizeOfPadded", false, false);
    _ = try show.printShow(&printer, gpa, mods, "firstN", false, false);
    const out = printer.array.writer.written();

    try testz.expectTrue(std.mem.indexOf(u8, out, "[extern]") != null);
    try testz.expectTrue(std.mem.indexOf(u8, out, "[export]") != null);
    try testz.expectTrue(std.mem.indexOf(u8, out, "[comptime]") != null);
    try testz.expectTrue(std.mem.indexOf(u8, out, "callconv(.c)") != null);
    try testz.expectTrue(std.mem.indexOf(u8, out, "comptime T:") != null);
}

pub fn renderedApiPageShowsExternExportCallconvAndLayoutBadges() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    var progress = render.Progress.init(10);
    var cache = render.cache_mod.Cache.init(fix.g_Io, gpa);
    defer cache.deinit();

    const out_dir = "test_tmp_render_comptime_extern";
    defer std.Io.Dir.cwd().deleteTree(fix.g_Io, out_dir) catch {};

    try render.renderSite(fix.g_Io, gpa, .{
        .out_path = out_dir,
        .project_name = "Test",
        .mods = mods,
        .pages = &.{},
        .emoji_provider = .unicode,
        .theme = .default,
        .progress = &progress,
        .conf_dir = null,
        .home_slug = null,
        .cache = &cache,
        .conf_abs_path = null,
        .show_imports = false,
        .repo_url = null,
    });

    const page_path = try std.fmt.allocPrint(gpa, "{s}/api/sample.html", .{out_dir});
    defer gpa.free(page_path);
    const content = try std.Io.Dir.cwd().readFileAlloc(fix.g_Io, page_path, gpa, .limited(512 * 1024));
    defer gpa.free(content);

    // extern/export badges and callconv on the two FFI functions.
    try testz.expectTrue(std.mem.indexOf(u8, content, "\"pill\">extern<") != null);
    try testz.expectTrue(std.mem.indexOf(u8, content, "\"pill\">export<") != null);
    try testz.expectTrue(std.mem.indexOf(u8, content, "\"pill\">comptime<") != null);
    try testz.expectTrue(std.mem.indexOf(u8, content, "callconv") != null and std.mem.indexOf(u8, content, ">.c<") != null);

    // Comptime param prefix shown inline in a signature.
    try testz.expectTrue(std.mem.indexOf(u8, content, "<span class=\"kw\">comptime </span>") != null);

    // extern struct / packed struct rendered distinctly from a plain struct.
    try testz.expectTrue(std.mem.indexOf(u8, content, "<span class=\"kw\">extern </span><span class=\"kw\">struct</span>") != null);
    try testz.expectTrue(std.mem.indexOf(u8, content, "<span class=\"kw\">packed </span><span class=\"kw\">struct</span>") != null);

    // The module-level comptime block gets its own section.
    try testz.expectTrue(std.mem.indexOf(u8, content, "id=\"section-comptime\"") != null);
    try testz.expectTrue(std.mem.indexOf(u8, content, "default_buf_size") != null);

    // Non-import constant value still renders (pre-existing behavior, guarded
    // here so a future change to renderVar can't silently regress it).
    try testz.expectTrue(std.mem.indexOf(u8, content, "4096") != null);
}
