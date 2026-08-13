const std = @import("std");
const ts = @import("tree_sitter");
const ts_zig = @import("tree-sitter-zig");
const ts_json = @import("tree-sitter-json");

const highlights_zig = @embedFile("assets/highlights.scm");

const highlights_json =
    \\(pair key: (_) @string.special.key)
    \\(string) @string
    \\(number) @number
    \\[(null)(true)(false)] @constant.builtin
    \\(escape_sequence) @string
    \\(comment) @comment
;

const CaptureRange = struct {
    start: u32,
    end: u32,
    name: []const u8,
    pattern_index: u16,
};

const RenderMode = enum { html, ansi };

/// Highlight source code for the given language fence tag, as HTML spans.
/// Falls back to plain escaped text for unknown languages.
pub fn highlight(allocator: std.mem.Allocator, lang: []const u8, source: []const u8) ![]const u8 {
    if (std.mem.eql(u8, lang, "zig")) return highlightWith(allocator, ts_zig.language(), highlights_zig, source, .html);
    if (std.mem.eql(u8, lang, "json")) return highlightWith(allocator, ts_json.language(), highlights_json, source, .html);
    return escapedOnly(allocator, source);
}

/// Highlight Zig source code (kept for backwards compat with callers).
pub fn highlightZig(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    return highlightWith(allocator, ts_zig.language(), highlights_zig, source, .html);
}

/// Highlight source code for the given language fence tag, as ANSI escape
/// codes for terminal display (used by `zkdocs show --verbose`). Falls
/// back to the unmodified source for unknown languages.
pub fn highlightAnsi(allocator: std.mem.Allocator, lang: []const u8, source: []const u8) ![]const u8 {
    if (std.mem.eql(u8, lang, "zig")) return highlightWith(allocator, ts_zig.language(), highlights_zig, source, .ansi);
    if (std.mem.eql(u8, lang, "json")) return highlightWith(allocator, ts_json.language(), highlights_json, source, .ansi);
    return allocator.dupe(u8, source);
}

fn highlightWith(
    allocator: std.mem.Allocator,
    grammar: *const anyopaque,
    query_src: []const u8,
    source: []const u8,
    mode: RenderMode,
) ![]const u8 {
    const parser = ts.Parser.create();
    defer parser.destroy();

    const lang: *const ts.Language = @ptrCast(@alignCast(grammar));
    try parser.setLanguage(lang);

    const tree = parser.parseString(source, null) orelse {
        return fallback(allocator, source, mode);
    };
    defer tree.destroy();

    var error_offset: u32 = 0;
    const query = ts.Query.create(lang, query_src, &error_offset) catch {
        return fallback(allocator, source, mode);
    };
    defer query.destroy();

    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();
    cursor.exec(query, tree.rootNode());

    var ranges: std.ArrayList(CaptureRange) = .empty;
    defer ranges.deinit(allocator);

    while (cursor.nextCapture()) |tup| {
        const ci = tup[0];
        const m = tup[1];
        if (ci >= m.captures.len) continue;
        const cap = m.captures[ci];
        const name = query.captureNameForId(cap.index) orelse continue;
        try ranges.append(allocator, .{
            .start = cap.node.startByte(),
            .end = cap.node.endByte(),
            .name = name,
            .pattern_index = m.pattern_index,
        });
    }

    std.mem.sort(CaptureRange, ranges.items, {}, struct {
        fn lt(_: void, a: CaptureRange, b: CaptureRange) bool {
            if (a.start != b.start) return a.start < b.start;
            return a.pattern_index < b.pattern_index;
        }
    }.lt);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const src_len: u32 = @intCast(source.len);
    var pos: u32 = 0;
    var ri: usize = 0;

    while (pos < src_len) {
        while (ri < ranges.items.len and ranges.items[ri].end <= pos) ri += 1;

        const next_start: u32 = if (ri < ranges.items.len) ranges.items[ri].start else src_len;

        if (next_start > pos) {
            try appendPlain(allocator, &out, source[pos..next_start], mode);
            pos = next_start;
        } else if (ri < ranges.items.len) {
            const r = ranges.items[ri];
            ri += 1;
            try appendStyled(allocator, &out, source[r.start..r.end], r.name, mode);
            pos = r.end;
            while (ri < ranges.items.len and ranges.items[ri].start < pos) ri += 1;
        } else {
            break;
        }
    }

    return out.toOwnedSlice(allocator);
}

fn fallback(allocator: std.mem.Allocator, source: []const u8, mode: RenderMode) ![]const u8 {
    return switch (mode) {
        .html => escapedOnly(allocator, source),
        .ansi => allocator.dupe(u8, source),
    };
}

fn appendPlain(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8, mode: RenderMode) !void {
    switch (mode) {
        .html => try appendEscaped(allocator, out, text),
        .ansi => try out.appendSlice(allocator, text),
    }
}

fn appendStyled(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8, capture_name: []const u8, mode: RenderMode) !void {
    switch (mode) {
        .html => {
            if (cssClass(capture_name)) |class| {
                try out.appendSlice(allocator, "<span class=\"");
                try out.appendSlice(allocator, class);
                try out.appendSlice(allocator, "\">");
                try appendEscaped(allocator, out, text);
                try out.appendSlice(allocator, "</span>");
            } else {
                try appendEscaped(allocator, out, text);
            }
        },
        .ansi => {
            if (ansiColor(capture_name)) |color| {
                try out.appendSlice(allocator, color);
                try out.appendSlice(allocator, text);
                try out.appendSlice(allocator, "\x1b[0m");
            } else {
                try out.appendSlice(allocator, text);
            }
        },
    }
}

fn escapedOnly(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try appendEscaped(allocator, &out, source);
    return out.toOwnedSlice(allocator);
}

fn cssClass(name: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, name, "keyword")) return "hl-keyword";
    if (std.mem.startsWith(u8, name, "function")) return "hl-function";
    if (std.mem.startsWith(u8, name, "type")) return "hl-type";
    if (std.mem.startsWith(u8, name, "constant")) return "hl-constant";
    if (std.mem.startsWith(u8, name, "string") or
        std.mem.eql(u8, name, "character")) return "hl-string";
    if (std.mem.startsWith(u8, name, "number")) return "hl-number";
    if (std.mem.eql(u8, name, "boolean")) return "hl-constant";
    if (std.mem.startsWith(u8, name, "comment")) return "hl-comment";
    if (std.mem.eql(u8, name, "operator")) return "hl-operator";
    return null;
}

// ANSI palette chosen to roughly parallel cssClass's groupings, reusing the
// same green for `type` that term_render.zig uses for signature types.
fn ansiColor(name: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, name, "keyword")) return "\x1b[35m"; // magenta
    if (std.mem.startsWith(u8, name, "function")) return "\x1b[34m"; // blue
    if (std.mem.startsWith(u8, name, "type")) return "\x1b[32m"; // green
    if (std.mem.startsWith(u8, name, "constant")) return "\x1b[33m"; // yellow
    if (std.mem.startsWith(u8, name, "string") or
        std.mem.eql(u8, name, "character")) return "\x1b[36m"; // cyan
    if (std.mem.startsWith(u8, name, "number")) return "\x1b[93m"; // bright yellow
    if (std.mem.eql(u8, name, "boolean")) return "\x1b[33m"; // yellow
    if (std.mem.startsWith(u8, name, "comment")) return "\x1b[90m"; // gray
    return null; // operator, etc.: left unstyled
}

fn appendEscaped(allocator: std.mem.Allocator, out: *std.ArrayList(u8), text: []const u8) !void {
    for (text) |ch| {
        switch (ch) {
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '&' => try out.appendSlice(allocator, "&amp;"),
            '"' => try out.appendSlice(allocator, "&quot;"),
            else => try out.append(allocator, ch),
        }
    }
}
