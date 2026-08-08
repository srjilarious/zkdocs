//* This module checks error-set documentation (plans/future_features.md
//* §1.1): named `error{...}` decls are extracted as their own symbol kind
//* (top-level and nested inside containers), a function's `!T` return type
//* keeps its leading `!` instead of silently dropping it, and an inline
//* `error{...}!T` return type has its members captured separately from a
//* named `MyError!T` return type (which is left for type-index linking
//* instead). The last two tests render `sample.zig` end to end and check
//* the generated HTML for the "Errors" section and the cross-reference link.
const std = @import("std");
const testz = @import("testz");
const zkdocs = @import("zkdocs");
const symbols = zkdocs.symbols;
const render = zkdocs.render;
const fix = @import("fixtures.zig");

pub fn namedErrorSetExtractedWithMemberDocs() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    const sample = fix.findModule(mods, "sample") orelse return error.SampleModuleNotFound;
    const sym = fix.findSymbol(sample.symbols.items, .error_set, "Error") orelse {
        return error.SymbolNotFound;
    };
    const e = sym.error_set;
    try testz.expectTrue(e.is_pub);
    try testz.expectEqualStr(e.doc.?, "Errors returned by bounds-checked operations.");
    try testz.expectEqual(e.errors.len, 2);
    try testz.expectEqualStr(e.errors[0].name, "OutOfBounds");
    try testz.expectEqualStr(e.errors[0].doc.?, "Index was outside the valid range.");
    try testz.expectEqualStr(e.errors[1].name, "InvalidInput");
    try testz.expectEqualStr(e.errors[1].doc.?, "Input value failed validation.");
}

pub fn nestedErrorSetExtractedInsideContainer() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    const sample = fix.findModule(mods, "sample") orelse return error.SampleModuleNotFound;
    const wrapper_sym = fix.findSymbol(sample.symbols.items, .container, "Wrapper") orelse {
        return error.SymbolNotFound;
    };
    const wrapper = wrapper_sym.container;

    var found: ?symbols.ErrorSet = null;
    for (wrapper.decls.items) |decl| {
        if (decl == .error_set and std.mem.eql(u8, decl.error_set.name, "ConstructError")) {
            found = decl.error_set;
        }
    }
    const e = found orelse return error.SymbolNotFound;
    try testz.expectTrue(e.is_pub);
    try testz.expectEqual(e.errors.len, 1);
    try testz.expectEqualStr(e.errors[0].name, "Negative");
    try testz.expectEqualStr(e.errors[0].doc.?, "The supplied value was negative.");
}

pub fn inferredErrorUnionKeepsLeadingBang() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    const sample = fix.findModule(mods, "sample") orelse return error.SampleModuleNotFound;
    const sym = fix.findSymbol(sample.symbols.items, .function, "maybeGet") orelse {
        return error.SymbolNotFound;
    };
    const f = sym.function;
    try testz.expectEqualStr(f.return_type_src.?, "!i32");
    try testz.expectEqual(f.inline_errors.len, 0);
}

pub fn namedErrorUnionReturnHasNoInlineErrors() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    const sample = fix.findModule(mods, "sample") orelse return error.SampleModuleNotFound;
    const sym = fix.findSymbol(sample.symbols.items, .function, "checkedGet") orelse {
        return error.SymbolNotFound;
    };
    const f = sym.function;
    try testz.expectEqualStr(f.return_type_src.?, "Error!i32");
    // Named error set (Error) — the errors live on Error's own symbol, not
    // duplicated here; linking is handled by the type index instead.
    try testz.expectEqual(f.inline_errors.len, 0);
}

pub fn inlineErrorUnionReturnCapturesMembers() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    const sample = fix.findModule(mods, "sample") orelse return error.SampleModuleNotFound;
    const sym = fix.findSymbol(sample.symbols.items, .function, "strictDivide") orelse {
        return error.SymbolNotFound;
    };
    const f = sym.function;
    try testz.expectEqualStr(f.return_type_src.?, "error{ DivByZero, Overflow }!i32");
    try testz.expectEqual(f.inline_errors.len, 2);
    try testz.expectEqualStr(f.inline_errors[0].name, "DivByZero");
    try testz.expectEqualStr(f.inline_errors[1].name, "Overflow");
}

pub fn renderedApiPageHasErrorsSectionAndInlineErrorTable() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    var progress = render.Progress.init(10);
    var cache = render.cache_mod.Cache.init(fix.g_Io, gpa);
    defer cache.deinit();

    const out_dir = "test_tmp_render_error_sets";
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
        .extra_css = &.{},
        .header_html = null,
        .footer_html = null,
        .logo = null,
        .favicon = null,
        .base_url = null,
    });

    const page_path = try std.fmt.allocPrint(gpa, "{s}/api/sample.html", .{out_dir});
    defer gpa.free(page_path);
    const content = try std.Io.Dir.cwd().readFileAlloc(fix.g_Io, page_path, gpa, .limited(256 * 1024));
    defer gpa.free(content);

    // The named error set gets its own documented block in a dedicated
    // "Errors" section, not just a bare constant.
    try testz.expectTrue(std.mem.indexOf(u8, content, "id=\"section-errors\"") != null);
    try testz.expectTrue(std.mem.indexOf(u8, content, "id=\"sym-Error\"") != null);
    try testz.expectTrue(std.mem.indexOf(u8, content, "OutOfBounds") != null);

    // The inferred `!T` return type must render with its `!`, not just "i32".
    try testz.expectTrue(std.mem.indexOf(u8, content, "!i32") != null);

    // strictDivide's inline error{...} members are listed alongside it.
    try testz.expectTrue(std.mem.indexOf(u8, content, "DivByZero") != null);
    try testz.expectTrue(std.mem.indexOf(u8, content, "Overflow") != null);
}

pub fn namedErrorSetReturnTypeLinksToDefinition() !void {
    const gpa = std.heap.page_allocator;

    const mods = try symbols.extractModuleGraph(fix.g_Io, gpa, "sample.zig");
    defer symbols.deinitModules(gpa, mods);

    var progress = render.Progress.init(10);
    var cache = render.cache_mod.Cache.init(fix.g_Io, gpa);
    defer cache.deinit();

    const out_dir = "test_tmp_render_error_set_link";
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
        .extra_css = &.{},
        .header_html = null,
        .footer_html = null,
        .logo = null,
        .favicon = null,
        .base_url = null,
    });

    const page_path = try std.fmt.allocPrint(gpa, "{s}/api/sample.html", .{out_dir});
    defer gpa.free(page_path);
    const content = try std.Io.Dir.cwd().readFileAlloc(fix.g_Io, page_path, gpa, .limited(256 * 1024));
    defer gpa.free(content);

    // checkedGet's `Error!i32` return type must link "Error" to its
    // same-module definition, same as any other cross-referenced type.
    try testz.expectTrue(std.mem.indexOf(u8, content, "href=\"#sym-Error\" class=\"type-link\">Error</a>") != null);
}
