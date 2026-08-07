const std = @import("std");
const zmd = @import("./zmd/zmd.zig");
pub const highlight = @import("./highlight.zig");

/// Render `markdown` to an HTML fragment (no DOCTYPE/html/body wrapper).
pub fn toHtml(allocator: std.mem.Allocator, markdown_text: []const u8) anyerror![]const u8 {
    // Extract admonitions first, since bodies are rendered recursively.
    // Tables are handled natively by zmd (see zmd/Ast.zig's parseTable), so
    // unlike admonitions they need no separate extract/restore pass here.
    var admonitions: std.ArrayList([]const u8) = .empty;
    defer {
        for (admonitions.items) |a| allocator.free(a);
        admonitions.deinit(allocator);
    }
    const stripped_admon = try extractAdmonitions(allocator, markdown_text, &admonitions);
    defer allocator.free(stripped_admon);

    const html = try zmd.parse(allocator, stripped_admon, .{
        .root = rootFmt,
        .code = codeFmt,
        .block = blockFmt,
        .h2 = h2Fmt,
        .table = tableFmt,
    });
    defer allocator.free(html);

    return restoreBlocks(allocator, html, admonitions.items, admonition_sentinel_prefix);
}

/// Produce a URL-safe slug from a heading string.
/// Strips embedded HTML tags, lowercases alphanumerics, collapses non-alphanum runs
/// into single hyphens, and trims leading/trailing hyphens.
pub fn slugify(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    var slug: std.ArrayList(u8) = .empty;
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

// ── Fence tracking (shared by fence-blind line scanners) ─────────────────────

const FenceMarker = struct { ch: u8, len: usize };

/// A fence delimiter line: up to 3 leading spaces, then 3+ of the same
/// backtick/tilde character. For backtick fences, no further backtick may
/// appear on the line (that would make it an inline code span, not a fence).
fn fenceMarker(line: []const u8) ?FenceMarker {
    var i: usize = 0;
    while (i < line.len and i < 3 and line[i] == ' ') i += 1;
    const rest = line[i..];
    if (rest.len < 3) return null;
    const ch = rest[0];
    if (ch != '`' and ch != '~') return null;
    var n: usize = 0;
    while (n < rest.len and rest[n] == ch) n += 1;
    if (n < 3) return null;
    if (ch == '`' and std.mem.indexOfScalar(u8, rest[n..], '`') != null) return null;
    return .{ .ch = ch, .len = n };
}

/// Tracks whether a line-by-line scan is currently inside a fenced code
/// block (``` or ~~~, per CommonMark). Table, admonition, and heading-TOC
/// scanners must skip fence-interior lines so a code sample that merely
/// *demonstrates* the syntax they're looking for isn't misinterpreted as
/// the real thing.
pub const FenceTracker = struct {
    active: bool = false,
    fence_char: u8 = 0,
    fence_len: usize = 0,

    /// Update state for `line` and return whether `line` should be treated
    /// as fence interior — this includes the fence delimiter lines
    /// themselves, since those aren't real table/admonition/heading syntax
    /// either.
    pub fn observe(self: *FenceTracker, line: []const u8) bool {
        if (fenceMarker(line)) |m| {
            if (!self.active) {
                self.active = true;
                self.fence_char = m.ch;
                self.fence_len = m.len;
                return true;
            }
            if (m.ch == self.fence_char and m.len >= self.fence_len) {
                self.active = false;
                return true;
            }
            return true; // a shorter/different fence-looking line while active is still fence content
        }
        return self.active;
    }
};

// ── Block extraction (admonitions) ────────────────────────────────────────────
// GFM tables are handled natively by zmd (see zmd/Ast.zig's parseTable) and
// no longer need an extract/restore pass here. Admonitions still do, since
// zmd has no concept of them.

// Sentinel prefix embedded in the stripped markdown so we can find and swap
// back later. Chosen to be unlikely in normal doc text.
const admonition_sentinel_prefix = "ZKDOCSADMON";

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

    var out: std.ArrayList(u8) = .empty;
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
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, md, '\n');
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(allocator);
    while (line_iter.next()) |ln| try lines.append(allocator, ln);

    var fence = FenceTracker{};
    var i: usize = 0;
    while (i < lines.items.len) {
        const line = lines.items[i];

        // Inside a fenced code block, a `!!! `/`??? `-prefixed line is a code
        // sample demonstrating admonition syntax, not a real one — pass it through.
        if (fence.observe(line)) {
            try result.appendSlice(allocator, line);
            try result.append(allocator, '\n');
            i += 1;
            continue;
        }

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
            var body: std.ArrayList(u8) = .empty;
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
            var html: std.ArrayList(u8) = .empty;
            errdefer html.deinit(allocator);
            const admon_html = if (collapsible)
                try std.fmt.allocPrint(allocator,
                    "<details class=\"admonition {s}\"><summary class=\"admonition-title\">{s}</summary><div class=\"admonition-body\">{s}</div></details>",
                    .{ admon_type, admon_title, body_html })
            else
                try std.fmt.allocPrint(allocator,
                    "<div class=\"admonition {s}\"><div class=\"admonition-title\">{s}</div><div class=\"admonition-body\">{s}</div></div>",
                    .{ admon_type, admon_title, body_html });
            defer allocator.free(admon_html);
            try html.appendSlice(allocator, admon_html);

            const idx = out_admonitions.items.len;
            try out_admonitions.append(allocator, try html.toOwnedSlice(allocator));
            const admon_sentinel = try std.fmt.allocPrint(allocator, "\n\n{s}{d}\n\n", .{ admonition_sentinel_prefix, idx });
            defer allocator.free(admon_sentinel);
            try result.appendSlice(allocator, admon_sentinel);
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
    const after = std.mem.trimStart(u8, html[post_end..], " \t\r\n");
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
    var escaped: std.ArrayList(u8) = .empty;
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
        var escaped: std.ArrayList(u8) = .empty;
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
    var escaped: std.ArrayList(u8) = .empty;
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

// GFM tables get the same `fields-table` class used for symbol field tables
// so they share styling; zmd's default `table` formatter emits a plain,
// unclassed `<table>` since it has no notion of zkdocs-specific CSS.
fn tableFmt(allocator: std.mem.Allocator, node: zmd.Node) ![]const u8 {
    return std.fmt.allocPrint(
        allocator,
        "<table class=\"fields-table\">\n{s}</table>\n",
        .{node.content},
    );
}
