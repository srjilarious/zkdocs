const std = @import("std");
pub const symbols = @import("./symbols.zig");
pub const render = @import("./render.zig");
pub const markdown = @import("./markdown.zig");
pub const example = @import("./example.zig");
pub const zmd = @import("./zmd/zmd.zig");

const zargs = @import("zargunaught");
pub const emoji = @import("./emoji.zig");
const cache_mod = @import("./cache.zig");
const build_options = @import("build_options");

pub fn main(init: std.process.Init) !void {
    var allocator = init.gpa;
    // var allocator = std.heap.page_allocator;
    var parser = try zargs.ArgParser.init(allocator, .{
        .name = "zkdocs",
        .description = "Generate documentation for Zig projects.",
        .opts = &.{
            .{
                .longName = "conf",
                .shortName = "c",
                .description = "Path to zkdocs.conf project config file.",
                .maxNumParams = 1,
            },
            .{
                .longName = "root",
                .shortName = "r",
                .description = "Root source file to extract symbols from (overrides conf).",
                .maxNumParams = 1,
            },
            .{
                .longName = "name",
                .shortName = "n",
                .description = "Display name for the project (overrides conf).",
                .maxNumParams = 1,
            },
            .{
                .longName = "out",
                .shortName = "o",
                .description = "Output directory for generated docs.",
                .maxNumParams = 1,
            },
            .{
                .longName = "theme",
                .shortName = "t",
                .description = "Color theme: default, monokai, vscode-light, vscode-dark (overrides conf).",
                .maxNumParams = 1,
            },
            .{
                .longName = "emoji",
                .shortName = "e",
                .description = "Emoji provider: none, unicode (default), twemoji, noto, openmoji (overrides conf).",
                .maxNumParams = 1,
            },
            .{
                .longName = "version",
                .shortName = "v",
                .description = "Print the zkdocs version and exit.",
            },
            .{
                .longName = "help",
                .shortName = "h",
                .description = "Print help information.",
            },
        },
    });
    defer parser.deinit();

    var args = parser.parse(init.minimal.args) catch |err| {
        std.debug.print("Error parsing args: {any}\n", .{err});
        std.process.exit(1);
    };
    defer args.deinit();

    if (args.hasOption("version")) {
        std.debug.print("zkdocs {s}\n", .{build_options.version});
        return;
    }

    if (args.hasOption("help")) {
        var stdout = try zargs.print.Printer.stdout(allocator);
        defer stdout.deinit();
        var help = try zargs.help.HelpFormatter.init(&parser, stdout, zargs.help.DefaultTheme, allocator);
        defer help.deinit();
        try help.printHelpText();
        try stdout.flush();
        return;
    }

    // -- Load full project config from --conf if provided --------------------
    var site_conf: ?render.SiteConf = null;
    defer if (site_conf) |*sc| sc.deinit(allocator);

    if (args.optionVal("conf")) |conf_path| {
        site_conf = render.loadSiteConf(init.io, allocator, conf_path) catch |err| {
            std.debug.print("Error: could not parse '{s}': {}\n", .{ conf_path, err });
            std.process.exit(1);
        };
    }

    // -- Resolve settings: CLI flags override config values -------------------
    // root_path is null when neither --root nor conf sources are given; symbol
    // extraction is skipped in that case (guides-only site).
    const root_path: ?[]const u8 = args.optionVal("root") orelse
        if (site_conf) |sc| if (sc.sources) |srcs| if (srcs.len > 0) srcs[0] else null else null else null;

    const project_name = args.optionVal("name") orelse
        if (site_conf) |sc| sc.name orelse "Documentation" else "Documentation";

    const theme_str = args.optionVal("theme") orelse
        if (site_conf) |sc| sc.theme.toAttr() orelse "default" else "default";
    const theme = render.Theme.fromStr(theme_str) orelse blk: {
        std.debug.print("Unknown theme '{s}', using 'default'.\n", .{theme_str});
        break :blk render.Theme.default;
    };

    const emoji_str = args.optionVal("emoji") orelse
        if (site_conf) |sc| sc.emoji orelse "unicode" else "unicode";
    const emoji_provider = emoji.Provider.fromStr(emoji_str) orelse blk: {
        std.debug.print("Unknown emoji provider '{s}', using 'unicode'.\n", .{emoji_str});
        break :blk emoji.Provider.unicode;
    };

    if (args.optionVal("out")) |out_path| {
        const pages: []render.PageNavItem =
            if (site_conf) |*sc| sc.pages else &.{};

        const has_pages = pages.len > 0;
        const total_steps: usize =
            @as(usize, if (root_path != null) 1 else 0) + // extracting symbols
            2 + // writing index + api
            @as(usize, if (has_pages) 1 else 0);
        var progress = render.Progress.init(total_steps);

        // Load the incremental build cache (returns empty cache on first run).
        var build_cache = cache_mod.Cache.load(init.io, allocator, out_path);
        defer build_cache.deinit();

        // Resolve the conf file path to absolute for stable cache keys.
        const conf_abs_path: ?[]const u8 = if (args.optionVal("conf")) |cp|
            cache_mod.absPath(init.io, allocator, cp) catch null
        else
            null;
        defer if (conf_abs_path) |p| allocator.free(p);

        const modules: []symbols.Module = if (root_path) |rp| blk: {
            progress.begin("extracting symbols");
            break :blk try symbols.extractModuleGraph(init.io, allocator, rp);
        } else &.{};
        defer if (root_path != null) symbols.deinitModules(allocator, modules);

        const conf_dir: ?[]const u8 = if (site_conf) |sc| sc.conf_dir else null;
        const home_slug: ?[]const u8 = if (site_conf) |sc| sc.home_slug else null;
        const show_imports = if (site_conf) |sc| sc.show_imports else false;
        const repo_url: ?[]const u8 = if (site_conf) |sc| sc.repo else null;
        try render.renderSite(init.io, allocator, .{
            .out_path = out_path,
            .project_name = project_name,
            .mods = modules,
            .pages = pages,
            .emoji_provider = emoji_provider,
            .theme = theme,
            .progress = &progress,
            .conf_dir = conf_dir,
            .home_slug = home_slug,
            .cache = &build_cache,
            .conf_abs_path = conf_abs_path,
            .show_imports = show_imports,
            .repo_url = repo_url,
        });
    } else {
        const modules: []symbols.Module = if (root_path) |rp|
            try symbols.extractModuleGraph(init.io, allocator, rp)
        else
            &.{};
        defer if (root_path != null) symbols.deinitModules(allocator, modules);
        for (modules) |mod| {
            std.debug.print("=== module '{s}' ===\n    path: {s}\n", .{ mod.name, mod.path });
            printSymbols(mod.symbols.items, 1);
            std.debug.print("\n", .{});
        }
    }
}

fn printDoc(pfx: []const u8, extra: []const u8, doc: []const u8) void {
    var rest = doc;
    while (rest.len > 0) {
        const pos = std.mem.indexOfScalar(u8, rest, '\n');
        const line = if (pos) |p| rest[0..p] else rest;
        rest = if (pos) |p| rest[p + 1 ..] else "";
        std.debug.print("{s}{s}// {s}\n", .{ pfx, extra, line });
    }
}

fn printSymbols(syms: []const symbols.Symbol, depth: usize) void {
    var buf: [32]u8 = undefined;
    const pfx = buf[0..@min(depth * 2, buf.len)];
    @memset(pfx, ' ');

    for (syms) |sym| {
        switch (sym) {
            .function => |f| {
                if (f.doc) |d| printDoc(pfx, "", d);
                std.debug.print("{s}fn {s}(", .{ pfx, f.name });
                for (f.params, 0..) |p, i| {
                    if (i > 0) std.debug.print(", ", .{});
                    if (p.name) |n| std.debug.print("{s}: ", .{n});
                    std.debug.print("{s}", .{p.type_src});
                }
                std.debug.print(")", .{});
                if (f.return_type_src) |r| std.debug.print(" {s}", .{r});
                if (f.is_pub) std.debug.print("  [pub]", .{});
                std.debug.print("\n", .{});
            },
            .variable => |v| {
                if (v.doc) |d| printDoc(pfx, "", d);
                std.debug.print("{s}const {s}", .{ pfx, v.name });
                if (v.type_src) |t| std.debug.print(": {s}", .{t});
                if (v.is_pub) std.debug.print("  [pub]", .{});
                std.debug.print("\n", .{});
            },
            .container => |c| {
                if (c.doc) |d| printDoc(pfx, "", d);
                std.debug.print("{s}{s} {s}", .{ pfx, @tagName(c.kind), c.name });
                if (c.is_pub) std.debug.print("  [pub]", .{});
                std.debug.print("\n", .{});
                for (c.fields) |f| {
                    if (f.doc) |d| printDoc(pfx, "  ", d);
                    std.debug.print("{s}  .{s}", .{ pfx, f.name });
                    if (f.type_src) |t| std.debug.print(": {s}", .{t});
                    std.debug.print("\n", .{});
                }
                if (c.decls.items.len > 0) {
                    std.debug.print("{s}  --- decls ---\n", .{pfx});
                    printSymbols(c.decls.items, depth + 1);
                }
            },
            .@"test", .other => {},
        }
    }
}
