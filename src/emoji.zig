const std = @import("std");

/// Emoji provider / rendering strategy.
pub const Provider = enum {
    none,      // no substitution
    unicode,   // raw UTF-8 codepoint (default)
    twemoji,   // Twitter emoji via jsDelivr CDN <img>
    noto,      // Google Noto emoji via GitHub raw <img>
    openmoji,  // OpenMoji via jsDelivr CDN <img>

    pub fn fromStr(s: []const u8) ?Provider {
        return std.meta.stringToEnum(Provider, s);
    }
};

// ── Emoji table ──────────────────────────────────────────────────────────────

const Entry = struct { name: []const u8, cp: u21 };

/// Common emoji using GitHub-style shortcode names.
const table = [_]Entry{
    // Faces
    .{ .name = "smile",            .cp = 0x1F604 },
    .{ .name = "grin",             .cp = 0x1F601 },
    .{ .name = "joy",              .cp = 0x1F602 },
    .{ .name = "laughing",         .cp = 0x1F606 },
    .{ .name = "smiley",           .cp = 0x1F603 },
    .{ .name = "wink",             .cp = 0x1F609 },
    .{ .name = "blush",            .cp = 0x1F60A },
    .{ .name = "heart_eyes",       .cp = 0x1F60D },
    .{ .name = "thinking",         .cp = 0x1F914 },
    .{ .name = "nerd",             .cp = 0x1F913 },
    .{ .name = "sunglasses",       .cp = 0x1F60E },
    .{ .name = "sob",              .cp = 0x1F62D },
    .{ .name = "cry",              .cp = 0x1F622 },
    .{ .name = "angry",            .cp = 0x1F620 },
    .{ .name = "rage",             .cp = 0x1F621 },
    .{ .name = "confused",         .cp = 0x1F615 },
    .{ .name = "flushed",          .cp = 0x1F633 },
    .{ .name = "sweat_smile",      .cp = 0x1F605 },
    .{ .name = "grimacing",        .cp = 0x1F62C },
    .{ .name = "exploding_head",   .cp = 0x1F92F },
    .{ .name = "scream",           .cp = 0x1F631 },
    .{ .name = "ghost",            .cp = 0x1F47B },
    .{ .name = "alien",            .cp = 0x1F47D },
    .{ .name = "robot",            .cp = 0x1F916 },
    .{ .name = "skull",            .cp = 0x1F480 },
    .{ .name = "eyes",             .cp = 0x1F440 },
    // Hands / gestures
    .{ .name = "thumbsup",         .cp = 0x1F44D },
    .{ .name = "+1",               .cp = 0x1F44D },
    .{ .name = "thumbsdown",       .cp = 0x1F44E },
    .{ .name = "-1",               .cp = 0x1F44E },
    .{ .name = "clap",             .cp = 0x1F44F },
    .{ .name = "wave",             .cp = 0x1F44B },
    .{ .name = "raised_hands",     .cp = 0x1F64C },
    .{ .name = "pray",             .cp = 0x1F64F },
    .{ .name = "muscle",           .cp = 0x1F4AA },
    .{ .name = "ok_hand",          .cp = 0x1F44C },
    .{ .name = "v",                .cp = 0x270C  },
    .{ .name = "point_right",      .cp = 0x1F449 },
    .{ .name = "point_left",       .cp = 0x1F448 },
    .{ .name = "point_up",         .cp = 0x1F446 },
    .{ .name = "point_down",       .cp = 0x1F447 },
    // Objects / tools
    .{ .name = "book",             .cp = 0x1F4D6 },
    .{ .name = "books",            .cp = 0x1F4DA },
    .{ .name = "computer",         .cp = 0x1F4BB },
    .{ .name = "phone",            .cp = 0x1F4F1 },
    .{ .name = "email",            .cp = 0x1F4E7 },
    .{ .name = "link",             .cp = 0x1F517 },
    .{ .name = "key",              .cp = 0x1F511 },
    .{ .name = "lock",             .cp = 0x1F512 },
    .{ .name = "unlock",           .cp = 0x1F513 },
    .{ .name = "bulb",             .cp = 0x1F4A1 },
    .{ .name = "fire",             .cp = 0x1F525 },
    .{ .name = "tada",             .cp = 0x1F389 },
    .{ .name = "gift",             .cp = 0x1F381 },
    .{ .name = "bomb",             .cp = 0x1F4A3 },
    .{ .name = "memo",             .cp = 0x1F4DD },
    .{ .name = "pencil",           .cp = 0x270F  },
    .{ .name = "clipboard",        .cp = 0x1F4CB },
    .{ .name = "calendar",         .cp = 0x1F4C5 },
    .{ .name = "package",          .cp = 0x1F4E6 },
    .{ .name = "pushpin",          .cp = 0x1F4CC },
    .{ .name = "paperclip",        .cp = 0x1F4CE },
    .{ .name = "mag",              .cp = 0x1F50D },
    .{ .name = "bell",             .cp = 0x1F514 },
    .{ .name = "wrench",           .cp = 0x1F527 },
    .{ .name = "gear",             .cp = 0x2699  },
    .{ .name = "hammer",           .cp = 0x1F528 },
    .{ .name = "hammer_and_wrench",.cp = 0x1F6E0 },
    .{ .name = "test_tube",        .cp = 0x1F9EA },
    .{ .name = "microscope",       .cp = 0x1F52C },
    .{ .name = "telescope",        .cp = 0x1F52D },
    // Symbols
    .{ .name = "star",             .cp = 0x2B50  },
    .{ .name = "sparkles",         .cp = 0x2728  },
    .{ .name = "warning",          .cp = 0x26A0  },
    .{ .name = "white_check_mark", .cp = 0x2705  },
    .{ .name = "heavy_check_mark", .cp = 0x2714  },
    .{ .name = "x",                .cp = 0x274C  },
    .{ .name = "question",         .cp = 0x2753  },
    .{ .name = "exclamation",      .cp = 0x2757  },
    .{ .name = "red_circle",       .cp = 0x1F534 },
    .{ .name = "green_circle",     .cp = 0x1F7E2 },
    .{ .name = "yellow_circle",    .cp = 0x1F7E1 },
    .{ .name = "blue_circle",      .cp = 0x1F535 },
    .{ .name = "100",              .cp = 0x1F4AF },
    .{ .name = "recycle",          .cp = 0x267B  },
    .{ .name = "globe",            .cp = 0x1F310 },
    .{ .name = "no_entry",         .cp = 0x26D4  },
    .{ .name = "stop_sign",        .cp = 0x1F6D1 },
    // Nature / weather
    .{ .name = "sun",              .cp = 0x2600  },
    .{ .name = "moon",             .cp = 0x1F319 },
    .{ .name = "cloud",            .cp = 0x2601  },
    .{ .name = "rainbow",          .cp = 0x1F308 },
    .{ .name = "snowflake",        .cp = 0x2744  },
    .{ .name = "zap",              .cp = 0x26A1  },
    // Animals
    .{ .name = "cat",              .cp = 0x1F408 },
    .{ .name = "dog",              .cp = 0x1F415 },
    .{ .name = "snake",            .cp = 0x1F40D },
    .{ .name = "bug",              .cp = 0x1F41B },
    .{ .name = "bee",              .cp = 0x1F41D },
    // Food / drink
    .{ .name = "pizza",            .cp = 0x1F355 },
    .{ .name = "coffee",           .cp = 0x2615  },
    .{ .name = "beer",             .cp = 0x1F37A },
    // Transport
    .{ .name = "rocket",           .cp = 0x1F680 },
    .{ .name = "car",              .cp = 0x1F697 },
    // Hearts
    .{ .name = "heart",            .cp = 0x2764  },
    .{ .name = "green_heart",      .cp = 0x1F49A },
    .{ .name = "blue_heart",       .cp = 0x1F499 },
    .{ .name = "yellow_heart",     .cp = 0x1F49B },
    .{ .name = "purple_heart",     .cp = 0x1F49C },
};

fn lookup(name: []const u8) ?u21 {
    for (&table) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.cp;
    }
    return null;
}

// ── CDN URL helpers ──────────────────────────────────────────────────────────

fn cdnUrl(allocator: std.mem.Allocator, cp: u21, provider: Provider) ![]const u8 {
    return switch (provider) {
        .twemoji => std.fmt.allocPrint(
            allocator,
            "https://cdn.jsdelivr.net/npm/twemoji@14.0.2/assets/svg/{x}.svg",
            .{@as(u32, cp)},
        ),
        .noto => std.fmt.allocPrint(
            allocator,
            "https://raw.githubusercontent.com/googlefonts/noto-emoji/main/svg/emoji_u{x}.svg",
            .{@as(u32, cp)},
        ),
        .openmoji => std.fmt.allocPrint(
            allocator,
            "https://cdn.jsdelivr.net/npm/openmoji@15.1.0/color/svg/{X}.svg",
            .{@as(u32, cp)},
        ),
        else => unreachable,
    };
}

// ── Tag-name helpers ─────────────────────────────────────────────────────────

/// True if `tag` is an opening `<code ...>` or `<pre ...>` tag.
fn isOpenCodeTag(tag: []const u8) bool {
    inline for (.{ "code", "pre" }) |name| {
        if (tag.len >= name.len and std.ascii.eqlIgnoreCase(tag[0..name.len], name)) {
            if (tag.len == name.len) return true;
            const next = tag[name.len];
            if (next == ' ' or next == '\t' or next == '\r' or next == '\n') return true;
        }
    }
    return false;
}

/// True if `tag` is a closing `</code>` or `</pre>` tag.
fn isCloseCodeTag(tag: []const u8) bool {
    if (tag.len == 0 or tag[0] != '/') return false;
    const inner = tag[1..];
    return std.ascii.eqlIgnoreCase(inner, "code") or std.ascii.eqlIgnoreCase(inner, "pre");
}

// ── Public API ───────────────────────────────────────────────────────────────

/// Scan `html` and replace `:name:` shortcodes with the chosen emoji
/// representation. Replacement is skipped inside HTML tags, `<code>` elements,
/// and `<pre>` blocks so that inline code and code fences are left intact.
///
/// Always returns a freshly allocated slice (caller must free).
pub fn replaceInHtml(
    allocator: std.mem.Allocator,
    html: []const u8,
    provider: Provider,
) ![]const u8 {
    if (provider == .none) return allocator.dupe(u8, html);

    var out = std.ArrayList(u8){};
    errdefer out.deinit(allocator);

    var tag_buf = std.ArrayList(u8){};
    defer tag_buf.deinit(allocator);

    var i: usize = 0;
    var in_tag = false;
    var code_depth: u32 = 0;

    while (i < html.len) {
        const c = html[i];

        // ── Enter an HTML tag ────────────────────────────────────────────────
        if (!in_tag and c == '<') {
            in_tag = true;
            tag_buf.clearRetainingCapacity();
            try out.append(allocator, c);
            i += 1;
            continue;
        }

        // ── Inside a tag ─────────────────────────────────────────────────────
        if (in_tag) {
            if (c == '>') {
                in_tag = false;
                const tag = std.mem.trim(u8, tag_buf.items, " \t\r\n");
                if (isOpenCodeTag(tag)) {
                    code_depth +|= 1;
                } else if (isCloseCodeTag(tag) and code_depth > 0) {
                    code_depth -= 1;
                }
            } else {
                try tag_buf.append(allocator, c);
            }
            try out.append(allocator, c);
            i += 1;
            continue;
        }

        // ── Inside <code>/<pre> — copy verbatim ─────────────────────────────
        if (code_depth > 0 or c != ':') {
            try out.append(allocator, c);
            i += 1;
            continue;
        }

        // ── Potential :name: shortcode ───────────────────────────────────────
        const rest = html[i + 1 ..];
        if (std.mem.indexOfScalar(u8, rest, ':')) |end| {
            if (end > 0 and end <= 32) {
                const name = rest[0..end];
                // Validate name chars: alphanumeric, underscore, hyphen, plus
                const valid = blk: {
                    for (name) |nc| {
                        if (!std.ascii.isAlphanumeric(nc) and
                            nc != '_' and nc != '-' and nc != '+')
                        {
                            break :blk false;
                        }
                    }
                    break :blk true;
                };
                if (valid) {
                    if (lookup(name)) |cp| {
                        try appendEmoji(&out, allocator, cp, name, provider);
                        i += 1 + end + 1; // consume :name:
                        continue;
                    }
                }
            }
        }

        try out.append(allocator, c);
        i += 1;
    }

    return out.toOwnedSlice(allocator);
}

fn appendEmoji(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    cp: u21,
    name: []const u8,
    provider: Provider,
) !void {
    switch (provider) {
        .none => unreachable,
        .unicode => {
            var encoded: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(cp, &encoded) catch return;
            try out.appendSlice(allocator, encoded[0..len]);
        },
        .twemoji, .noto, .openmoji => {
            const url = try cdnUrl(allocator, cp, provider);
            defer allocator.free(url);
            const img = try std.fmt.allocPrint(
                allocator,
                "<img class=\"emoji\" src=\"{s}\" alt=\":{s}:\" title=\":{s}:\">",
                .{ url, name, name },
            );
            defer allocator.free(img);
            try out.appendSlice(allocator, img);
        },
    }
}
