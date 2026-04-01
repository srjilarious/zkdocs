const std = @import("std");

pub const SegmentKind = enum { prose, code, collapsed };

pub const Segment = struct {
    kind: SegmentKind,
    /// Prose or code text (owned, heap-allocated).
    text: []const u8 = "",
    /// For collapsed segments: optional summary label (owned, heap-allocated).
    label: ?[]const u8 = null,
    /// For collapsed segments: child segments (owned slice).
    children: []Segment = &.{},
};

/// Free all segments and their children recursively.
pub fn freeSegments(allocator: std.mem.Allocator, segments: []Segment) void {
    for (segments) |*seg| {
        allocator.free(seg.text);
        if (seg.label) |l| allocator.free(l);
        if (seg.children.len > 0) {
            freeSegments(allocator, seg.children);
            allocator.free(seg.children);
        }
    }
    // Note: the caller frees the slice itself (we don't own it here).
}

const State = enum { top, hidden, collapsed };

/// Parse a literate `.zig` source into segments.
/// The returned slice and all strings within are heap-allocated; free with
/// `freeSegments` then `allocator.free(result)`.
pub fn parse(allocator: std.mem.Allocator, src: []const u8) ![]Segment {
    var result: std.ArrayList(Segment) = .{};
    errdefer {
        freeSegments(allocator, result.items);
        result.deinit(allocator);
    }

    // Sub-segments for a collapsed block in progress.
    var sub: std.ArrayList(Segment) = .{};
    errdefer {
        freeSegments(allocator, sub.items);
        sub.deinit(allocator);
    }

    // Accumulator for the current run of same-kind lines.
    var acc: std.ArrayList(u8) = .{};
    errdefer acc.deinit(allocator);

    var state: State = .top;
    var collapsed_label: ?[]const u8 = null;
    var current_kind: ?SegmentKind = null;

    // Flush the current accumulator as a segment into `target`.
    const flush = struct {
        fn call(
            alloc: std.mem.Allocator,
            acc_list: *std.ArrayList(u8),
            kind: ?SegmentKind,
            target: *std.ArrayList(Segment),
        ) !void {
            const k = kind orelse return;
            if (acc_list.items.len == 0) return;
            // Trim a single trailing newline from code segments to avoid a
            // blank line at the end of <pre> blocks.
            var text = acc_list.items;
            if (k == .code and text.len > 0 and text[text.len - 1] == '\n') {
                text = text[0 .. text.len - 1];
            }
            try target.append(alloc, .{
                .kind = k,
                .text = try alloc.dupe(u8, text),
            });
            acc_list.clearRetainingCapacity();
        }
    }.call;

    var lines = std.mem.splitScalar(u8, src, '\n');
    while (lines.next()) |line| {
        // Strip leading whitespace to find //* markers regardless of indent.
        const trimmed = std.mem.trimLeft(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "//*")) {
            const after_marker = trimmed[3..];
            // Strip one leading space after //* if present.
            const rest = if (after_marker.len > 0 and after_marker[0] == ' ')
                after_marker[1..]
            else
                after_marker;

            // Section control directives.
            if (std.mem.eql(u8, rest, "-- hidden --")) {
                const target = if (state == .collapsed) &sub else &result;
                try flush(allocator, &acc, current_kind, target);
                current_kind = null;
                state = .hidden;
                continue;
            }
            if (std.mem.eql(u8, rest, "---")) {
                // Close the current section.
                const target = if (state == .collapsed) &sub else &result;
                try flush(allocator, &acc, current_kind, target);
                current_kind = null;
                if (state == .collapsed) {
                    // Build collapsed segment from sub.
                    const children = try sub.toOwnedSlice(allocator);
                    try result.append(allocator, .{
                        .kind = .collapsed,
                        .text = try allocator.dupe(u8, ""),
                        .label = collapsed_label,
                        .children = children,
                    });
                    collapsed_label = null;
                }
                state = .top;
                continue;
            }
            if (std.mem.startsWith(u8, rest, "-- collapsed --")) {
                const target = if (state == .collapsed) &sub else &result;
                try flush(allocator, &acc, current_kind, target);
                current_kind = null;
                state = .collapsed;
                collapsed_label = null;
                continue;
            }
            if (std.mem.startsWith(u8, rest, "-- collapsed:")) {
                const target = if (state == .collapsed) &sub else &result;
                try flush(allocator, &acc, current_kind, target);
                current_kind = null;
                state = .collapsed;
                // Extract label: everything after "-- collapsed:" trimmed, strip trailing " --"
                const after_colon = std.mem.trimLeft(u8, rest["-- collapsed:".len..], " ");
                const label_raw = if (std.mem.endsWith(u8, after_colon, " --"))
                    after_colon[0 .. after_colon.len - 3]
                else
                    after_colon;
                collapsed_label = try allocator.dupe(u8, std.mem.trim(u8, label_raw, " "));
                continue;
            }

            if (state == .hidden) continue;

            // Regular prose line.
            const target = if (state == .collapsed) &sub else &result;
            if (current_kind != .prose) {
                try flush(allocator, &acc, current_kind, target);
                current_kind = .prose;
            }
            if (rest.len == 0) {
                // Blank //* line → paragraph break.
                if (acc.items.len > 0 and
                    !(acc.items.len >= 2 and
                      acc.items[acc.items.len - 1] == '\n' and
                      acc.items[acc.items.len - 2] == '\n'))
                {
                    try acc.appendSlice(allocator, "\n\n");
                }
            } else {
                // Non-empty prose line: join with a space unless the accumulator
                // is empty, already ends with a newline, or this line starts a
                // markdown block element (heading, list, blockquote, fence).
                const starts_block = rest[0] == '#' or rest[0] == '>' or
                    rest[0] == '-' or rest[0] == '*' or rest[0] == '+' or
                    rest[0] == '`' or rest[0] == '|' or
                    (rest[0] >= '0' and rest[0] <= '9' and
                     std.mem.indexOfScalar(u8, rest, '.') != null);
                const needs_newline = starts_block or
                    acc.items.len == 0 or
                    acc.items[acc.items.len - 1] == '\n';
                if (needs_newline) {
                    if (acc.items.len > 0 and acc.items[acc.items.len - 1] != '\n')
                        try acc.append(allocator, '\n');
                } else {
                    try acc.append(allocator, ' ');
                }
                try acc.appendSlice(allocator, rest);
            }
        } else {
            // Code line.
            if (state == .hidden) continue;
            const target = if (state == .collapsed) &sub else &result;
            if (current_kind != .code) {
                try flush(allocator, &acc, current_kind, target);
                current_kind = .code;
            }
            if (acc.items.len > 0) try acc.append(allocator, '\n');
            try acc.appendSlice(allocator, line);
        }
    }

    // Flush whatever remains.
    const final_target = if (state == .collapsed) &sub else &result;
    try flush(allocator, &acc, current_kind, final_target);
    acc.deinit(allocator);

    // If still in a collapsed state at EOF, close it.
    if (state == .collapsed) {
        const children = try sub.toOwnedSlice(allocator);
        try result.append(allocator, .{
            .kind = .collapsed,
            .text = try allocator.dupe(u8, ""),
            .label = collapsed_label,
            .children = children,
        });
    }
    sub.deinit(allocator);

    return result.toOwnedSlice(allocator);
}
