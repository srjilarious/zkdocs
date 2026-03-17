const std = @import("std");
const zmd = @import("zmd");
const highlight = @import("highlight");

/// Render `markdown` to an HTML fragment (no DOCTYPE/html/body wrapper).
pub fn toHtml(allocator: std.mem.Allocator, markdown_text: []const u8) ![]const u8 {
    // Extract GFM tables before zmd sees them; zmd would wrap them in <p> tags.
    var tables: std.ArrayList([]const u8) = .{};
    defer {
        for (tables.items) |t| allocator.free(t);
        tables.deinit(allocator);
    }

    const stripped = try extractTables(allocator, markdown_text, &tables);
    defer allocator.free(stripped);

    const html = try zmd.parse(allocator, stripped, .{
        .root = rootFmt,
        .code = codeFmt,
        .block = blockFmt,
        .h2 = h2Fmt,
    });
    defer allocator.free(html);

    return restoreTables(allocator, html, tables.items);
}

/// Produce a URL-safe slug from a heading string.
/// Strips embedded HTML tags, lowercases alphanumerics, collapses non-alphanum runs
/// into single hyphens, and trims leading/trailing hyphens.
pub fn slugify(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var slug: std.ArrayList(u8) = .{};
    errdefer slug.deinit(allocator);

    var in_tag = false;
    var need_dash = false; // true if the next alphanumeric should be preceded by a dash

    for (text) |c| {
        if (c == '<') {
            in_tag = true;
            continue;
        }
        if (c == '>') {
            in_tag = false;
            continue;
        }
        if (in_tag) continue;

        if (std.ascii.isAlphanumeric(c)) {
            if (need_dash and slug.items.len > 0) try slug.append(allocator, '-');
            try slug.append(allocator, std.ascii.toLower(c));
            need_dash = false;
        } else {
            if (slug.items.len > 0) need_dash = true;
        }
    }

    return slug.toOwnedSlice(allocator);
}

// ── Table extraction ─────────────────────────────────────────────────────────

// Sentinel prefix embedded in the stripped markdown so we can find and swap
// back later. Chosen to be unlikely in normal doc text.
const sentinel_prefix = "ZKDOCSTABLE";

/// Scan `md` for GFM table blocks (lines starting with `|` where the second
/// line is a separator `|---|---|`). Each table block is replaced by a unique
/// sentinel string, and its rendered HTML is appended to `out_tables`.
fn extractTables(
    allocator: std.mem.Allocator,
    md: []const u8,
    out_tables: *std.ArrayList([]const u8),
) ![]const u8 {
    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(allocator);

    // Collect lines; keep track of raw slices into `md`.
    var line_iter = std.mem.splitScalar(u8, md, '\n');
    var lines: std.ArrayList([]const u8) = .{};
    defer lines.deinit(allocator);
    while (line_iter.next()) |ln| try lines.append(allocator, ln);

    var i: usize = 0;
    while (i < lines.items.len) {
        const line = lines.items[i];
        //const trimmed = std.mem.trim(u8, line, " \t");

        // Table starts when this line and the next both begin with `|`, and
        // the next line is a separator row.
        if (line.len > 0 and line[0] == '|' and
            i + 1 < lines.items.len)
        {
            const next = std.mem.trim(u8, lines.items[i + 1], " \t");
            if (next.len > 0 and next[0] == '|' and isTableSeparator(next)) {
                // Collect all consecutive `|`-starting lines after the separator.
                var end = i + 2;
                while (end < lines.items.len) {
                    const row = std.mem.trim(u8, lines.items[end], " \t");
                    if (row.len == 0 or row[0] != '|') break;
                    end += 1;
                }

                // Render the table block to HTML.
                var tbl: std.ArrayList(u8) = .{};
                errdefer tbl.deinit(allocator);
                try tbl.appendSlice(allocator, "<table class=\"fields-table\">\n<thead>\n<tr>");
                try appendTableCells(&tbl, allocator, line, true);
                try tbl.appendSlice(allocator, "</tr>\n</thead>\n<tbody>\n");
                var r = i + 2;
                while (r < end) : (r += 1) {
                    try tbl.appendSlice(allocator, "<tr>");
                    try appendTableCells(&tbl, allocator, lines.items[r], false);
                    try tbl.appendSlice(allocator, "</tr>\n");
                }
                try tbl.appendSlice(allocator, "</tbody>\n</table>");

                const idx = out_tables.items.len;
                try out_tables.append(allocator, try tbl.toOwnedSlice(allocator));

                // Emit sentinel (blank lines around it so zmd treats it as its
                // own paragraph, making it easy to strip the wrapping <p>).
                try result.writer(allocator).print("\n\n{s}{d}\n\n", .{ sentinel_prefix, idx });
                i = end;
                continue;
            }
        }

        try result.appendSlice(allocator, line);
        try result.append(allocator, '\n');
        i += 1;
    }

    return result.toOwnedSlice(allocator);
}

/// Returns true when `line` is a GFM table separator (`|---|:---:|` etc.).
fn isTableSeparator(line: []const u8) bool {
    var has_dash = false;
    for (line) |c| {
        switch (c) {
            '|', '-', ':', ' ', '\t' => {},
            else => return false,
        }
        if (c == '-') has_dash = true;
    }
    return has_dash;
}

/// Append `<th>` or `<td>` elements for one row of a pipe-delimited table.
/// Cells are HTML-escaped; backtick spans become `<code>`.
fn appendTableCells(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    line: []const u8,
    header: bool,
) !void {
    const tag = if (header) "th" else "td";
    var parts = std.mem.splitScalar(u8, line, '|');
    _ = parts.next(); // discard empty before leading `|`
    while (parts.next()) |raw| {
        // peek: if there's nothing after this split, it's the trailing empty
        const cell = std.mem.trim(u8, raw, " \t");
        // The last split after the trailing `|` is always empty — skip it.
        // We detect it by peeking: if rest of string is empty/whitespace.
        if (cell.len == 0 and parts.peek() == null) break;

        try out.writer(allocator).print("<{s}>", .{tag});
        try appendInline(out, allocator, cell);
        try out.writer(allocator).print("</{s}>", .{tag});
    }
}

/// Minimal inline renderer: handles `` `code` `` spans and HTML-escapes the rest.
fn appendInline(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '`') {
            if (std.mem.indexOfScalar(u8, text[i + 1 ..], '`')) |end| {
                try out.appendSlice(allocator, "<code>");
                try htmlEscapeInto(out, allocator, text[i + 1 .. i + 1 + end]);
                try out.appendSlice(allocator, "</code>");
                i += 1 + end + 1;
                continue;
            }
        }
        // HTML-escape single character.
        switch (text[i]) {
            '<' => try out.appendSlice(allocator, "&lt;"),
            '>' => try out.appendSlice(allocator, "&gt;"),
            '&' => try out.appendSlice(allocator, "&amp;"),
            else => try out.append(allocator, text[i]),
        }
        i += 1;
    }
}

fn htmlEscapeInto(out: *std.ArrayList(u8), allocator: std.mem.Allocator, s: []const u8) !void {
    for (s) |c| switch (c) {
        '<' => try out.appendSlice(allocator, "&lt;"),
        '>' => try out.appendSlice(allocator, "&gt;"),
        '&' => try out.appendSlice(allocator, "&amp;"),
        else => try out.append(allocator, c),
    };
}

/// Replace `<p>ZKDOCS_TABLE_N</p>` (or bare `ZKDOCS_TABLE_N`) with the
/// pre-rendered HTML tables stored in `tables`.
fn restoreTables(
    allocator: std.mem.Allocator,
    html: []const u8,
    tables: []const []const u8,
) ![]const u8 {
    if (tables.len == 0) return allocator.dupe(u8, html);

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);

    var rest = html;
    while (rest.len > 0) {
        // Find the next sentinel occurrence (possibly wrapped in <p>...</p>).
        const found = findSentinel(rest) orelse {
            try out.appendSlice(allocator, rest);
            break;
        };

        try out.appendSlice(allocator, rest[0..found.pre_start]);

        // Parse the index from the sentinel text.
        const idx = std.fmt.parseInt(usize, found.index_str, 10) catch {
            try out.appendSlice(allocator, rest[found.pre_start..found.post_end]);
            rest = rest[found.post_end..];
            continue;
        };
        if (idx < tables.len) {
            try out.appendSlice(allocator, tables[idx]);
        }
        rest = rest[found.post_end..];
    }

    return out.toOwnedSlice(allocator);
}

const SentinelMatch = struct {
    pre_start: usize, // start of the whole match (incl. possible <p>)
    index_str: []const u8,
    post_end: usize, // end of the whole match (incl. possible </p>)
};

fn findSentinel(html: []const u8) ?SentinelMatch {
    const idx = std.mem.indexOf(u8, html, sentinel_prefix) orelse return null;

    // Walk forward past the digits.
    var end = idx + sentinel_prefix.len;
    while (end < html.len and std.ascii.isDigit(html[end])) end += 1;
    const index_str = html[idx + sentinel_prefix.len .. end];

    // Expand to include any surrounding <p> / </p> and whitespace.
    var pre_start = idx;
    var post_end = end;

    // Check for <p> before (with optional whitespace between <p> and sentinel).
    const before = html[0..pre_start];
    if (std.mem.lastIndexOf(u8, before, "<p>")) |p_idx| {
        const between = std.mem.trim(u8, html[p_idx + 3 .. pre_start], " \t\r\n");
        if (between.len == 0) pre_start = p_idx;
    }
    // Check for </p> after.
    const after = std.mem.trimLeft(u8, html[post_end..], " \t\r\n");
    if (std.mem.startsWith(u8, after, "</p>")) {
        post_end = html.len - after.len + 4;
    }

    return .{
        .pre_start = pre_start,
        .index_str = index_str,
        .post_end = post_end,
    };
}

// ── Formatters ──────────────────────────────────────────────────────────────

// Override root to return just the inner HTML (no DOCTYPE/html/body wrapper).
fn rootFmt(allocator: std.mem.Allocator, node: zmd.Node) ![]const u8 {
    return allocator.dupe(u8, node.content);
}

// Inline code: plain <code> element.
fn codeFmt(allocator: std.mem.Allocator, node: zmd.Node) ![]const u8 {
    return std.fmt.allocPrint(allocator, "<code>{s}</code>", .{node.content});
}

// Fenced code blocks: Zig blocks get tree-sitter syntax highlighting.
fn blockFmt(allocator: std.mem.Allocator, node: zmd.Node) ![]const u8 {
    // zmd strips leading whitespace from code block content via std.mem.trim,
    // which eats the first line's indentation along with the opening newline.
    // Restore it by detecting the indent used by the first non-blank subsequent line.
    const content = try restoreCodeIndent(allocator, node.content);
    defer allocator.free(content);

    if (node.meta) |lang| {
        if (std.mem.eql(u8, lang, "zig")) {
            if (highlight.highlightZig(allocator, content)) |hl| {
                defer allocator.free(hl);
                return std.fmt.allocPrint(
                    allocator,
                    "<pre><code class=\"language-zig\">{s}</code></pre>\n",
                    .{hl},
                );
            } else |_| {
                // Fall through to default on any highlighting error.
            }
        }
        return std.fmt.allocPrint(
            allocator,
            "<pre><code class=\"language-{s}\">{s}</code></pre>\n",
            .{ lang, content },
        );
    }
    return std.fmt.allocPrint(allocator, "<pre><code>{s}</code></pre>\n", .{content});
}

/// zmd's `strip()` (std.mem.trim) removes the opening `\n` after the fence line
/// together with the first content line's leading whitespace. Detect the indent
/// used by subsequent lines and prepend it to the first line — but only when ALL
/// non-blank subsequent lines share a common base indent (i.e., no line is at
/// column 0). If any line has zero indent the first line was genuinely unindented
/// (e.g., a function definition with its closing `}` at col 0) and we leave it alone.
fn restoreCodeIndent(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    const nl = std.mem.indexOfScalar(u8, content, '\n') orelse
        return allocator.dupe(u8, content);

    const rest = content[nl + 1 ..];

    // Compute the minimum indent across all non-blank subsequent lines.
    // Any col-0 line means the first line was likely also at col 0 — bail out.
    var min_indent: usize = std.math.maxInt(usize);
    var line_iter = std.mem.splitScalar(u8, rest, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        var end: usize = 0;
        while (end < line.len and (line[end] == ' ' or line[end] == '\t')) end += 1;
        if (end == 0) return allocator.dupe(u8, content); // col-0 line → no restore
        if (end < min_indent) min_indent = end;
    }
    if (min_indent == std.math.maxInt(usize)) return allocator.dupe(u8, content);

    // Take the indent characters (up to min_indent) from the first non-blank line.
    line_iter = std.mem.splitScalar(u8, rest, '\n');
    const indent = while (line_iter.next()) |line| {
        if (line.len > 0) break line[0..min_indent];
    } else return allocator.dupe(u8, content);

    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, indent);
    try out.appendSlice(allocator, content[0..nl + 1]);
    try out.appendSlice(allocator, rest);
    return out.toOwnedSlice(allocator);
}

// H2 headings get an anchor id for in-page navigation.
fn h2Fmt(allocator: std.mem.Allocator, node: zmd.Node) ![]const u8 {
    const slug = try slugify(allocator, node.content);
    defer allocator.free(slug);
    return std.fmt.allocPrint(
        allocator,
        "<h2 id=\"h2-{s}\">{s}</h2>\n",
        .{ slug, node.content },
    );
}
