const std = @import("std");
pub const symbols = @import("./symbols.zig");
pub const render = @import("./render.zig");
pub const markdown = @import("./markdown.zig");
pub const example = @import("./example.zig");
pub const zmd = @import("./zmd/zmd.zig");
pub const show = @import("./show.zig");
pub const term_render = @import("./term_render.zig");

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
                .longName = "dump",
                .shortName = "d",
                .description = "Dump the full extracted symbol tree to stdout (for piping into grep/less).",
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
        .commands = &.{
            .{
                .name = "show",
                .description = "Print a symbol's signature and doc comment to stdout: `zkdocs show <symbol>`.",
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

    const is_show_cmd = if (args.command) |cmd| std.mem.eql(u8, cmd.name, "show") else false;
    const is_dump = args.hasOption("dump");

    // -- Load full project config from --conf if provided --------------------
    var site_conf: ?render.SiteConf = null;
    defer if (site_conf) |*sc| sc.deinit(allocator);

    if (args.optionVal("conf")) |conf_path| {
        site_conf = render.loadSiteConf(init.io, allocator, conf_path) catch |err| {
            std.debug.print("Error: could not parse '{s}': {}\n", .{ conf_path, err });
            std.process.exit(1);
        };
    } else if ((is_show_cmd or is_dump) and args.optionVal("root") == null) {
        // `show`/`--dump` fall back to a `zkdocs.conf` in the current
        // directory when neither --conf nor --root was given, so they can
        // be run from a project root the same way `zig build docs` is
        // configured. Best-effort: silently skip if it's missing or
        // malformed and fall through to the "no root source file" error
        // below, since the user never asked for this file explicitly.
        site_conf = render.loadSiteConf(init.io, allocator, "zkdocs.conf") catch null;
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

    const out_path = args.optionVal("out");

    const mode_count: u8 =
        @as(u8, if (is_show_cmd) 1 else 0) +
        @as(u8, if (is_dump) 1 else 0) +
        @as(u8, if (out_path != null) 1 else 0);
    if (mode_count > 1) {
        std.debug.print("Error: pass only one of `show`, --dump, or --out.\n", .{});
        std.process.exit(1);
    }

    if (is_show_cmd or is_dump) {
        if (is_show_cmd and args.positional.items.len != 1) {
            std.debug.print("Usage: zkdocs show <symbol>\n", .{});
            std.process.exit(1);
        }

        const rp = root_path orelse {
            std.debug.print("Error: no root source file given (use --root, or a conf with sources).\n", .{});
            std.process.exit(1);
        };

        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const modules = symbols.extractModuleGraph(init.io, aa, rp) catch |err| {
            std.debug.print("Error extracting symbols from '{s}': {}\n", .{ rp, err });
            std.process.exit(1);
        };

        var stdout = try zargs.print.Printer.stdout(allocator);
        defer stdout.deinit();
        const color = stdout.supportsColor();

        if (is_show_cmd) {
            const symbol_name = args.positional.items[0];
            const found = try show.printShow(&stdout, aa, modules, symbol_name, color);
            try stdout.flush();
            if (!found) {
                std.debug.print("No symbol named '{s}' found.\n", .{symbol_name});
                std.process.exit(1);
            }
        } else {
            try show.printDump(&stdout, aa, modules, color);
            try stdout.flush();
        }
        return;
    }

    if (out_path) |op| {
        const pages: []render.PageNavItem =
            if (site_conf) |*sc| sc.pages else &.{};

        const has_pages = pages.len > 0;
        const total_steps: usize =
            @as(usize, if (root_path != null) 1 else 0) + // extracting symbols
            2 + // writing index + api
            @as(usize, if (has_pages) 1 else 0);
        var progress = render.Progress.init(total_steps);

        // Load the incremental build cache (returns empty cache on first run).
        var build_cache = cache_mod.Cache.load(init.io, allocator, op);
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
            .out_path = op,
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
        std.debug.print("Nothing to do: pass --out to build a site, --dump to print the symbol tree, or `show <symbol>` to print one symbol.\n", .{});
        std.debug.print("Run `zkdocs --help` for usage.\n", .{});
        std.process.exit(1);
    }
}

