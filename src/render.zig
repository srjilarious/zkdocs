const std = @import("std");
const symbols = @import("symbols");

const CSS = @embedFile("assets/style.css");

// ---------------------------------------------------------------------------
// Internal write buffer
// ---------------------------------------------------------------------------

const Buf = struct {
    list: std.ArrayList(u8),
    alloc: std.mem.Allocator,

    fn init(alloc: std.mem.Allocator) Buf {
        return .{ .list = .{}, .alloc = alloc };
    }

    fn deinit(self: *Buf) void {
        self.list.deinit(self.alloc);
    }

    fn writeAll(self: *Buf, s: []const u8) !void {
        try self.list.appendSlice(self.alloc, s);
    }

    fn print(self: *Buf, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.alloc, fmt, args);
        defer self.alloc.free(s);
        try self.list.appendSlice(self.alloc, s);
    }

    fn flush(self: *const Buf, file: std.fs.File) !void {
        try file.writeAll(self.list.items);
    }
};

// ---------------------------------------------------------------------------
// HTML helpers
// ---------------------------------------------------------------------------

fn htmlEscape(buf: *Buf, text: []const u8) !void {
    for (text) |c| {
        switch (c) {
            '<' => try buf.writeAll("&lt;"),
            '>' => try buf.writeAll("&gt;"),
            '&' => try buf.writeAll("&amp;"),
            '"' => try buf.writeAll("&quot;"),
            else => try buf.list.append(buf.alloc, c),
        }
    }
}

fn firstSentence(text: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, text, '.')) |pos| return text[0 .. pos + 1];
    return text;
}

fn writeHeader(
    buf: *Buf,
    title: []const u8,
    project_name: []const u8,
    mods: []const symbols.Module,
    active_module: ?[]const u8,
    is_api_page: bool,
) !void {
    const prefix: []const u8 = if (is_api_page) ".." else ".";

    try buf.print(
        \\<!DOCTYPE html>
        \\<html lang="en">
        \\<head>
        \\<meta charset="UTF-8">
        \\<meta name="viewport" content="width=device-width,initial-scale=1">
        \\<title>
    , .{});
    try htmlEscape(buf, title);
    try buf.print(
        \\</title>
        \\<style>
        \\{s}
        \\</style>
        \\</head>
        \\<body>
        \\<nav class="sidebar">
        \\<a class="logo" href="{s}/index.html">
    , .{ CSS, prefix });
    try htmlEscape(buf, project_name);
    try buf.writeAll("</a>\n<h4>Modules</h4>\n<ul>\n");

    for (mods) |mod| {
        const is_active = if (active_module) |am| std.mem.eql(u8, am, mod.name) else false;
        const cls: []const u8 = if (is_active) " class=\"active\"" else "";
        try buf.print("<li><a href=\"{s}/api/{s}.html\"{s}>", .{ prefix, mod.name, cls });
        try htmlEscape(buf, mod.name);
        try buf.writeAll("</a></li>\n");
    }

    try buf.writeAll("</ul>\n</nav>\n<main>\n");
}

fn writeFooter(buf: *Buf) !void {
    try buf.writeAll("\n</main>\n</body>\n</html>\n");
}

// ---------------------------------------------------------------------------
// Symbol renderers
// ---------------------------------------------------------------------------

fn renderFn(buf: *Buf, f: symbols.Function) !void {
    try buf.writeAll("<div class=\"symbol\">\n<div class=\"symbol-sig\"><code>");
    if (f.is_pub) try buf.writeAll("<span class=\"kw\">pub </span>");
    try buf.writeAll("<span class=\"kw\">fn </span>");
    try buf.print("<span class=\"fn-name\">{s}</span>(", .{f.name});
    for (f.params, 0..) |p, i| {
        if (i > 0) try buf.writeAll(", ");
        if (p.name) |n| {
            try buf.print("<span class=\"param-name\">{s}</span>: ", .{n});
        }
        try buf.writeAll("<span class=\"type-name\">");
        try htmlEscape(buf, p.type_src);
        try buf.writeAll("</span>");
    }
    try buf.writeAll(")");
    if (f.return_type_src) |r| {
        try buf.writeAll(" <span class=\"type-name\">");
        try htmlEscape(buf, r);
        try buf.writeAll("</span>");
    }
    try buf.writeAll("</code></div>\n");
    if (f.doc) |doc| {
        try buf.writeAll("<div class=\"symbol-doc\">");
        try htmlEscape(buf, doc);
        try buf.writeAll("</div>\n");
    }
    try buf.writeAll("</div>\n");
}

fn renderContainer(buf: *Buf, c: symbols.Container) !void {
    try buf.writeAll("<div class=\"symbol\">\n<div class=\"symbol-sig\"><code>");
    if (c.is_pub) try buf.writeAll("<span class=\"kw\">pub </span>");
    try buf.print(
        "<span class=\"kw\">{s}</span> <span class=\"fn-name\">{s}</span>",
        .{ @tagName(c.kind), c.name },
    );
    try buf.writeAll("</code></div>\n");

    if (c.doc) |doc| {
        try buf.writeAll("<div class=\"symbol-doc\">");
        try htmlEscape(buf, doc);
        try buf.writeAll("</div>\n");
    }

    if (c.fields.len > 0) {
        try buf.writeAll(
            \\<table class="fields-table">
            \\<tr><th>Field</th><th>Type</th><th>Description</th></tr>
            \\
        );
        for (c.fields) |f| {
            try buf.writeAll("<tr><td>");
            try htmlEscape(buf, f.name);
            try buf.writeAll("</td><td>");
            if (f.type_src) |t| try htmlEscape(buf, t);
            try buf.writeAll("</td><td class=\"field-doc\">");
            if (f.doc) |d| try htmlEscape(buf, d);
            try buf.writeAll("</td></tr>\n");
        }
        try buf.writeAll("</table>\n");
    }

    // Pub methods / nested decls
    var has_pub_decls = false;
    for (c.decls.items) |d| {
        if (d.kind == .function) if (d.function) |f| { if (f.is_pub) { has_pub_decls = true; break; } };
    }
    if (has_pub_decls) {
        try buf.writeAll("<div class=\"symbol-decls\">\n<h4>Methods</h4>\n");
        for (c.decls.items) |d| {
            if (d.kind == .function) if (d.function) |f| {
                if (f.is_pub) try renderFn(buf, f);
            };
        }
        try buf.writeAll("</div>\n");
    }

    try buf.writeAll("</div>\n");
}

fn renderVar(buf: *Buf, v: symbols.Variable) !void {
    try buf.writeAll("<div class=\"symbol\">\n<div class=\"symbol-sig\"><code>");
    if (v.is_pub) try buf.writeAll("<span class=\"kw\">pub </span>");
    try buf.writeAll("<span class=\"kw\">const </span>");
    try buf.print("<span class=\"fn-name\">{s}</span>", .{v.name});
    if (v.type_src) |t| {
        try buf.writeAll(": <span class=\"type-name\">");
        try htmlEscape(buf, t);
        try buf.writeAll("</span>");
    }
    try buf.writeAll("</code></div>\n");
    if (v.doc) |doc| {
        try buf.writeAll("<div class=\"symbol-doc\">");
        try htmlEscape(buf, doc);
        try buf.writeAll("</div>\n");
    }
    try buf.writeAll("</div>\n");
}

// ---------------------------------------------------------------------------
// Public entry point
// ---------------------------------------------------------------------------

/// Generate the full HTML site under `out_path`.
/// Output layout:
///   out_path/
///     index.html
///     api/<module>.html  (one per module)
pub fn renderSite(
    allocator: std.mem.Allocator,
    out_path: []const u8,
    project_name: []const u8,
    mods: []const symbols.Module,
) !void {
    var out_dir = try std.fs.cwd().makeOpenPath(out_path, .{});
    defer out_dir.close();

    try out_dir.makePath("api");

    // ── index.html ──────────────────────────────────────────────────────────
    {
        var buf = Buf.init(allocator);
        defer buf.deinit();

        try writeHeader(&buf, project_name, project_name, mods, null, false);
        try buf.writeAll("<h1>");
        try htmlEscape(&buf, project_name);
        try buf.writeAll("</h1>\n<h2>Modules</h2>\n<ul class=\"module-list\">\n");

        for (mods) |mod| {
            try buf.print("<li><a href=\"./api/{s}.html\">", .{mod.name});
            try htmlEscape(&buf, mod.name);
            try buf.writeAll("</a>");

            // First doc from the module's first documented symbol.
            var found_doc = false;
            for (mod.symbols.items) |sym| {
                const doc: ?[]const u8 = switch (sym.kind) {
                    .function => if (sym.function) |f| f.doc else null,
                    .variable => if (sym.variable) |v| v.doc else null,
                    .container => if (sym.container) |c| c.doc else null,
                    else => null,
                };
                if (doc) |d| {
                    try buf.writeAll("<div class=\"mod-doc\">");
                    try htmlEscape(&buf, firstSentence(d));
                    try buf.writeAll("</div>");
                    found_doc = true;
                    break;
                }
            }
            if (!found_doc) {
                try buf.writeAll("<div class=\"mod-doc\">");
                try htmlEscape(&buf, mod.path);
                try buf.writeAll("</div>");
            }

            try buf.writeAll("</li>\n");
        }

        try buf.writeAll("</ul>\n");
        try writeFooter(&buf);

        const file = try out_dir.createFile("index.html", .{});
        defer file.close();
        try buf.flush(file);
    }

    // ── api/<module>.html ────────────────────────────────────────────────────
    for (mods) |mod| {
        var buf = Buf.init(allocator);
        defer buf.deinit();

        const title = try std.fmt.allocPrint(allocator, "{s} — {s}", .{ mod.name, project_name });
        defer allocator.free(title);

        try writeHeader(&buf, title, project_name, mods, mod.name, true);
        try buf.writeAll("<h1>");
        try htmlEscape(&buf, mod.name);
        try buf.writeAll("</h1>\n<div class=\"mod-path\">");
        try htmlEscape(&buf, mod.path);
        try buf.writeAll("</div>\n");

        // Tally what's present (pub only).
        var has_types = false;
        var has_fns   = false;
        var has_consts= false;
        for (mod.symbols.items) |sym| {
            switch (sym.kind) {
                .container => if (sym.container) |c| { if (c.is_pub) has_types  = true; },
                .function  => if (sym.function)  |f| { if (f.is_pub) has_fns    = true; },
                .variable  => if (sym.variable)  |v| { if (v.is_pub) has_consts = true; },
                else => {},
            }
        }

        if (has_types) {
            try buf.writeAll("<h2>Types</h2>\n");
            for (mod.symbols.items) |sym| {
                if (sym.kind == .container) if (sym.container) |c| {
                    if (c.is_pub) try renderContainer(&buf, c);
                };
            }
        }

        if (has_fns) {
            try buf.writeAll("<h2>Functions</h2>\n");
            for (mod.symbols.items) |sym| {
                if (sym.kind == .function) if (sym.function) |f| {
                    if (f.is_pub) try renderFn(&buf, f);
                };
            }
        }

        if (has_consts) {
            try buf.writeAll("<h2>Constants</h2>\n");
            for (mod.symbols.items) |sym| {
                if (sym.kind == .variable) if (sym.variable) |v| {
                    if (v.is_pub) try renderVar(&buf, v);
                };
            }
        }

        try writeFooter(&buf);

        const filename = try std.fmt.allocPrint(allocator, "api/{s}.html", .{mod.name});
        defer allocator.free(filename);

        const file = try out_dir.createFile(filename, .{});
        defer file.close();
        try buf.flush(file);
    }
}
