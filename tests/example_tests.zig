//* This module checks that prose lines in example zig files are handled properly. The `example` module should join adjacent non-empty lines into a single prose segment, but a blank line should create a paragraph break (double newline). Heading lines should start on their own line, and indented lines should track their indent level and flush the current segment when the indent changes.
const std = @import("std");
const testz = @import("testz");
const zkdocs = @import("zkdocs");
const example = zkdocs.example;

/// Adjacent non-empty prose lines are joined with a space, not separated
/// into individual paragraphs.
pub fn proseLinesJoinedWithSpace() !void {
    const gpa = std.heap.page_allocator;

    const src =
        \\//* First sentence of the paragraph.
        \\//* Second sentence on the next line.
        \\//* Third sentence still same paragraph.
    ;
    const segs = try example.parse(gpa, src);
    defer {
        example.freeSegments(gpa, segs);
        gpa.free(segs);
    }

    try testz.expectEqual(segs.len, 1);
    try testz.expectEqual(segs[0].kind, example.SegmentKind.prose);
    // All three sentences should be in a single prose segment joined by spaces.
    try testz.expectTrue(std.mem.indexOf(u8, segs[0].text, "First sentence") != null);
    try testz.expectTrue(std.mem.indexOf(u8, segs[0].text, "Second sentence") != null);
    try testz.expectTrue(std.mem.indexOf(u8, segs[0].text, "Third sentence") != null);
    // Must NOT contain a bare newline between the sentences (would cause paragraph split).
    const first_pos = std.mem.indexOf(u8, segs[0].text, "First sentence").?;
    const second_pos = std.mem.indexOf(u8, segs[0].text, "Second sentence").?;
    const between = segs[0].text[first_pos..second_pos];
    try testz.expectTrue(std.mem.indexOf(u8, between, "\n") == null);
}

/// A blank //* line creates a paragraph break (two newlines in the text).
pub fn blankLineCreatesParagraphBreak() !void {
    const gpa = std.heap.page_allocator;

    const src =
        \\//* First paragraph text.
        \\//*
        \\//* Second paragraph text.
    ;
    const segs = try example.parse(gpa, src);
    defer {
        example.freeSegments(gpa, segs);
        gpa.free(segs);
    }

    try testz.expectEqual(segs.len, 1);
    // The single prose segment should contain a double newline between the paragraphs.
    try testz.expectTrue(std.mem.indexOf(u8, segs[0].text, "\n\n") != null);
}

/// A heading line (//* # ...) always starts on its own line, not joined
/// with the preceding prose.
pub fn headingStartsOnNewLine() !void {
    const gpa = std.heap.page_allocator;

    const src =
        \\//* Some intro text.
        \\//* # The Heading
        \\//* Text after heading.
    ;
    const segs = try example.parse(gpa, src);
    defer {
        example.freeSegments(gpa, segs);
        gpa.free(segs);
    }

    try testz.expectEqual(segs.len, 1);
    // The heading must start on its own line (preceded by \n, not a space).
    const heading_pos = std.mem.indexOf(u8, segs[0].text, "# The Heading").?;
    try testz.expectTrue(heading_pos == 0 or segs[0].text[heading_pos - 1] == '\n');
}

/// Indented //* lines produce separate segments with the correct indent
/// count; a change in indent flushes the current segment.
pub fn indentedProseTracksIndent() !void {
    const gpa = std.heap.page_allocator;

    const src =
        \\//* Top-level prose.
        \\    //* Indented prose inside function.
        \\    //* Still indented.
        \\//* Back to top level.
    ;
    const segs = try example.parse(gpa, src);
    defer {
        example.freeSegments(gpa, segs);
        gpa.free(segs);
    }

    // Three prose segments: indent 0, indent 4, indent 0.
    try testz.expectEqual(segs.len, 3);
    try testz.expectEqual(segs[0].indent, 0);
    try testz.expectEqual(segs[1].indent, 4);
    // The two indented lines should be joined into one segment.
    try testz.expectTrue(std.mem.indexOf(u8, segs[1].text, "Indented prose") != null);
    try testz.expectTrue(std.mem.indexOf(u8, segs[1].text, "Still indented") != null);
    try testz.expectEqual(segs[2].indent, 0);
}
