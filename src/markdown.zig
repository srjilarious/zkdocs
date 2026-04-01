const std = @import("std");
const zmd = @import("./zmd/zmd.zig");
pub const highlight = @import("./highlight.zig");

/// Render `markdown` to an HTML fragment (no DOCTYPE/html/body wrapper).
pub fn toHtml(allocator: std.mem.Allocator, markdown_text: []const u8) anyerror![]const u8 {
    // Extract admonitions first (before tables, since bodies are rendered recursively).
    var admonitions: std.ArrayList([]const u8) = .{};
    defer {
        for (admonitions.items) |a| allocator.free(a);
        admonitions.deinit(allocator);
    }
    const stripped_admon = try extractAdmonitions(allocator, markdown_text, &admonitions);
    defer allocator.free(stripped_admon);

    // Extract GFM tables before zmd sees them; zmd would wrap them in <p> tags.
    var tables: std.ArrayList([]const u8) = .{};
    defer {
        for (tables.items) |t| allocator.free(t);
        tables.deinit(allocator);
    }

    const stripped = try extractTables(allocator, stripped_admon, &tables);
    defer allocator.free(stripped);

    const html = try zmd.parse(allocator, stripped, .{
        .root = rootFmt,
        .code = codeFmt,
        .block = blockFmt,
        .h2 = h2Fmt,
    });
    defer allocator.free(html);

    const with_tables = try restoreBlocks(allocator, html, tables.items, table_sentinel_prefix);
    defer allocator.free(with_tables);

    return restoreBlocks(allocator, with_tables, admonitions.items, admonition_sentinel_prefix);
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

// ── Block extraction (tables + admonitions) ──────────────────────────────────

// Sentinel prefixes embedded in the stripped markdown so we can find and swap
// back later. Chosen to be unlikely in normal doc text.
const table_sentinel_prefix = "ZKDOCSTABLE";
const admonition_sentinel_prefix = "ZKDOCSADMON";

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
                try result.writer(allocator).print("\n\n{s}{d}\n\n", .{ table_sentinel_prefix, idx });
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

/// Replace sentinel-prefixed placeholders with their pre-rendered HTML blocks.
/// Placeholders may be bare or wrapped in `<p>…</p>` by zmd.
fn restoreBlocks(
    allocator: std.mem.Allocator,
    html: []const u8,
    blocks: []const []const u8,
    prefix: []const u8,
) ![]const u8 {
    if (blocks.len == 0) return allocator.dupe(u8, html);

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);

    var rest = html;
    while (rest.len > 0) {
        const found = findSentinel(rest, prefix) orelse {
            try out.appendSlice(allocator, rest);
            break;
        };

        try out.appendSlice(allocator, rest[0..found.pre_start]);

        const idx = std.fmt.parseInt(usize, found.index_str, 10) catch {
            try out.appendSlice(allocator, rest[found.pre_start..found.post_end]);
            rest = rest[found.post_end..];
            continue;
        };
        if (idx < blocks.len) {
            try out.appendSlice(allocator, blocks[idx]);
        }
        rest = rest[found.post_end..];
    }

    return out.toOwnedSlice(allocator);
}

// ── Admonition extraction ─────────────────────────────────────────────────────

/// Scan `md` for MkDocs-style admonition blocks:
///   `!!! type "Optional Title"`  (non-collapsible)
///   `??? type "Optional Title"`  (collapsible <details>)
/// Body lines are indented 4 spaces. Each block is replaced by a sentinel and
/// its rendered HTML is appended to `out_admonitions`.
fn extractAdmonitions(
    allocator: std.mem.Allocator,
    md: []const u8,
    out_admonitions: *std.ArrayList([]const u8),
) ![]const u8 {
    var result: std.ArrayList(u8) = .{};
    errdefer result.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, md, '\n');
    var lines: std.ArrayList([]const u8) = .{};
    defer lines.deinit(allocator);
    while (line_iter.next()) |ln| try lines.append(allocator, ln);

    var i: usize = 0;
    while (i < lines.items.len) {
        const line = lines.items[i];

        const collapsible = std.mem.startsWith(u8, line, "??? ");
        const is_admon = std.mem.startsWith(u8, line, "!!! ") or collapsible;

        if (is_admon) {
            const rest = line[4..];

            // Parse `type` and optional `"title"` from the header line.
            var admon_type: []const u8 = undefined;
            var admon_title: []const u8 = undefined;
            if (std.mem.indexOfScalar(u8, rest, ' ')) |sp| {
                admon_type = rest[0..sp];
                const title_raw = std.mem.trim(u8, rest[sp + 1 ..], " \t\"");
                admon_title = if (title_raw.len > 0) title_raw else titleForType(admon_type);
            } else {
                admon_type = std.mem.trim(u8, rest, " \t");
                admon_title = titleForType(admon_type);
            }

            // Collect body lines (each indented by 4 spaces; blank lines pass through).
            var body: std.ArrayList(u8) = .{};
            errdefer body.deinit(allocator);
            i += 1;
            while (i < lines.items.len) {
                const body_line = lines.items[i];
                if (body_line.len == 0) {
                    try body.append(allocator, '\n');
                    i += 1;
                    continue;
                }
                if (std.mem.startsWith(u8, body_line, "    ")) {
                    try body.appendSlice(allocator, body_line[4..]);
                    try body.append(allocator, '\n');
                    i += 1;
                } else {
                    break;
                }
            }

            // Render the body as HTML (recursive call handles nested markdown).
            const body_md = try body.toOwnedSlice(allocator);
            defer allocator.free(body_md);
            const body_html = try toHtml(allocator, body_md);
            defer allocator.free(body_html);

            // Build the admonition HTML.
            var html: std.ArrayList(u8) = .{};
            errdefer html.deinit(allocator);
            const w = html.writer(allocator);
            if (collapsible) {
                try w.print(
                    "<details class=\"admonition {s}\"><summary class=\"admonition-title\">{s}</summary><div class=\"admonition-body\">{s}</div></details>",
                    .{ admon_type, admon_title, body_html },
                );
            } else {
                try w.print(
                    "<div class=\"admonition {s}\"><div class=\"admonition-title\">{s}</div><div class=\"admonition-body\">{s}</div></div>",
                    .{ admon_type, admon_title, body_html },
                );
            }

            const idx = out_admonitions.items.len;
            try out_admonitions.append(allocator, try html.toOwnedSlice(allocator));
            try result.writer(allocator).print("\n\n{s}{d}\n\n", .{ admonition_sentinel_prefix, idx });
            continue;
        }

        try result.appendSlice(allocator, line);
        try result.append(allocator, '\n');
        i += 1;
    }

    return result.toOwnedSlice(allocator);
}

fn titleForType(admon_type: []const u8) []const u8 {
    if (std.mem.eql(u8, admon_type, "note")) return "Note";
    if (std.mem.eql(u8, admon_type, "abstract")) return "Abstract";
    if (std.mem.eql(u8, admon_type, "info")) return "Info";
    if (std.mem.eql(u8, admon_type, "tip")) return "Tip";
    if (std.mem.eql(u8, admon_type, "success")) return "Success";
    if (std.mem.eql(u8, admon_type, "question")) return "Question";
    if (std.mem.eql(u8, admon_type, "warning")) return "Warning";
    if (std.mem.eql(u8, admon_type, "failure")) return "Failure";
    if (std.mem.eql(u8, admon_type, "danger")) return "Danger";
    if (std.mem.eql(u8, admon_type, "bug")) return "Bug";
    if (std.mem.eql(u8, admon_type, "example")) return "Example";
    if (std.mem.eql(u8, admon_type, "quote")) return "Quote";
    return admon_type;
}

// ─────────────────────────────────────────────────────────────────────────────

const SentinelMatch = struct {
    pre_start: usize, // start of the whole match (incl. possible <p>)
    index_str: []const u8,
    post_end: usize, // end of the whole match (incl. possible </p>)
};

fn findSentinel(html: []const u8, prefix: []const u8) ?SentinelMatch {
    const idx = std.mem.indexOf(u8, html, prefix) orelse return null;

    // Walk forward past the digits.
    var end = idx + prefix.len;
    while (end < html.len and std.ascii.isDigit(html[end])) end += 1;
    const index_str = html[idx + prefix.len .. end];

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
    var escaped: std.ArrayList(u8) = .{};
    errdefer escaped.deinit(allocator);
    try htmlEscapeInto(&escaped, allocator, node.content);
    const escaped_str = try escaped.toOwnedSlice(allocator);
    defer allocator.free(escaped_str);
    return std.fmt.allocPrint(allocator, "<code>{s}</code>", .{escaped_str});
}

// Fenced code blocks: Zig blocks get tree-sitter syntax highlighting.
fn blockFmt(allocator: std.mem.Allocator, node: zmd.Node) ![]const u8 {
    if (node.meta) |lang| {
        if (highlight.highlight(allocator, lang, node.content)) |hl| {
            defer allocator.free(hl);
            return std.fmt.allocPrint(
                allocator,
                "<pre><code class=\"language-{s}\">{s}</code></pre>\n",
                .{ lang, hl },
            );
        } else |_| {}
        // Unknown language — escape the raw source.
        var escaped: std.ArrayList(u8) = .{};
        errdefer escaped.deinit(allocator);
        try htmlEscapeInto(&escaped, allocator, node.content);
        const escaped_str = try escaped.toOwnedSlice(allocator);
        defer allocator.free(escaped_str);
        return std.fmt.allocPrint(
            allocator,
            "<pre><code class=\"language-{s}\">{s}</code></pre>\n",
            .{ lang, escaped_str },
        );
    }
    var escaped: std.ArrayList(u8) = .{};
    errdefer escaped.deinit(allocator);
    try htmlEscapeInto(&escaped, allocator, node.content);
    const escaped_str = try escaped.toOwnedSlice(allocator);
    defer allocator.free(escaped_str);
    return std.fmt.allocPrint(allocator, "<pre><code>{s}</code></pre>\n", .{escaped_str});
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
