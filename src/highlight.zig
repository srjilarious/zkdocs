const std = @import("std");
const ts = @import("tree_sitter");
const ts_zig = @import("tree-sitter-zig");

const highlights_scm = @embedFile("assets/highlights.scm");

const CaptureRange = struct {
    start: u32,
    end: u32,
    class: []const u8,
    pattern_index: u16,
};

/// Highlight Zig source code and return an HTML fragment with `<span>` elements.
/// The returned slice is owned by the caller (allocated with `allocator`).
/// Falls back gracefully — if parsing fails, returns HTML-escaped plain text.
pub fn highlightZig(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    const parser = ts.Parser.create();
    defer parser.destroy();

    const lang: *const ts.Language = @ptrCast(@alignCast(ts_zig.language()));
    try parser.setLanguage(lang);

    const tree = parser.parseString(source, null) orelse {
        // No tree — return plain escaped text
        return escapedOnly(allocator, source);
    };
    defer tree.destroy();

    var error_offset: u32 = 0;
    const query = ts.Query.create(lang, highlights_scm, &error_offset) catch {
        return escapedOnly(allocator, source);
    };
    defer query.destroy();

    const cursor = ts.QueryCursor.create();
    defer cursor.destroy();
    cursor.exec(query, tree.rootNode());

    // Collect captures.
    var ranges: std.ArrayList(CaptureRange) = .{};
    defer ranges.deinit(allocator);

    while (cursor.nextCapture()) |tup| {
        const ci = tup[0];
        const m = tup[1];
        if (ci >= m.captures.len) continue;
        const cap = m.captures[ci];
        const name = query.captureNameForId(cap.index) orelse continue;
        const class = cssClass(name) orelse continue;
        try ranges.append(allocator, .{
            .start = cap.node.startByte(),
            .end = cap.node.endByte(),
            .class = class,
            .pattern_index = m.pattern_index,
        });
    }

    // Sort: start byte ascending, then pattern_index ascending (lower = higher priority).
    std.mem.sort(CaptureRange, ranges.items, {}, struct {
        fn lt(_: void, a: CaptureRange, b: CaptureRange) bool {
            if (a.start != b.start) return a.start < b.start;
            return a.pattern_index < b.pattern_index;
        }
    }.lt);

    // Walk source left-to-right, emitting non-overlapping spans.
    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);

    const src_len: u32 = @intCast(source.len);
    var pos: u32 = 0;
    var ri: usize = 0;

    while (pos < src_len) {
        // Skip ranges whose end is at or before current position.
        while (ri < ranges.items.len and ranges.items[ri].end <= pos) ri += 1;

        const next_start: u32 = if (ri < ranges.items.len) ranges.items[ri].start else src_len;

        if (next_start > pos) {
            // Emit plain (escaped) text up to the next capture.
            try appendEscaped(allocator, &out, source[pos..next_start]);
            pos = next_start;
        } else if (ri < ranges.items.len) {
            // Emit highlighted span.
            const r = ranges.items[ri];
            ri += 1;
            try out.appendSlice(allocator, "<span class=\"");
            try out.appendSlice(allocator, r.class);
            try out.appendSlice(allocator, "\">");
            try appendEscaped(allocator, &out, source[r.start..r.end]);
            try out.appendSlice(allocator, "</span>");
            pos = r.end;
            // Skip any captures that overlap this span.
            while (ri < ranges.items.len and ranges.items[ri].start < pos) ri += 1;
        } else {
            break;
        }
    }

    return out.toOwnedSlice(allocator);
}

fn escapedOnly(allocator: std.mem.Allocator, source: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .{};
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
    return null; // variable, punctuation, label, module, spell, …
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
