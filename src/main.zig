const std = @import("std");
const symbols = @import("symbols");
const render = @import("render");
const zargs = @import("zargunaught");
const emoji = @import("emoji");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var parser = try zargs.ArgParser.init(allocator, .{
        .name = "zkdocs",
        .description = "Generate documentation for Zig projects.",
        .opts = &.{
            .{ .longName = "root", .shortName = "r", .description = "Root source file to extract symbols from.", .maxNumParams = 1 },
            .{ .longName = "name", .shortName = "n", .description = "Display name for the root module.", .maxNumParams = 1 },
            .{ .longName = "out", .shortName = "o", .description = "Output directory for generated docs.", .maxNumParams = 1 },
            .{ .longName = "docs",  .shortName = "d", .description = "Path to guides.json config file (or legacy: directory of .md files).", .maxNumParams = 1 },
            .{ .longName = "emoji", .shortName = "e", .description = "Emoji provider: none, unicode (default), twemoji, noto, openmoji.", .maxNumParams = 1 },
            .{ .longName = "help",  .shortName = "h", .description = "Print help information." },
        },
    });
    defer parser.deinit();

    var args = parser.parse() catch |err| {
        std.debug.print("Error parsing args: {any}\n", .{err});
        return;
    };
    defer args.deinit();

    if (args.hasOption("help")) {
        var stdout = try zargs.print.Printer.stdout(allocator);
        defer stdout.deinit();
        var help = try zargs.help.HelpFormatter.init(&parser, stdout, zargs.help.DefaultTheme, allocator);
        defer help.deinit();
        try help.printHelpText();
        try stdout.flush();
        return;
    }

    const root_path = args.optionValOrDefault("root", "sample.zig");
    const project_name = args.optionValOrDefault("name", "Documentation");

    const emoji_str = args.optionValOrDefault("emoji", "unicode");
    const emoji_provider = emoji.Provider.fromStr(emoji_str) orelse blk: {
        std.debug.print("Unknown emoji provider '{s}', using 'unicode'.\n", .{emoji_str});
        break :blk emoji.Provider.unicode;
    };

    const modules = try symbols.extractModuleGraph(allocator, root_path);
    defer symbols.deinitModules(allocator, modules);

    if (args.optionVal("out")) |out_path| {
        const docs_dir = args.optionVal("docs");
        try render.renderSite(allocator, out_path, project_name, modules, docs_dir, emoji_provider);
        std.debug.print("Generated docs in '{s}/'\n", .{out_path});
    } else {
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
    const pfx = buf[0 .. @min(depth * 2, buf.len)];
    @memset(pfx, ' ');

    for (syms) |sym| {
        switch (sym.kind) {
            .function => if (sym.function) |f| {
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
            .variable => if (sym.variable) |v| {
                if (v.doc) |d| printDoc(pfx, "", d);
                std.debug.print("{s}const {s}", .{ pfx, v.name });
                if (v.type_src) |t| std.debug.print(": {s}", .{t});
                if (v.is_pub) std.debug.print("  [pub]", .{});
                std.debug.print("\n", .{});
            },
            .container => if (sym.container) |c| {
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
            else => {},
        }
    }
}
