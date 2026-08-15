//* Covers `completion.zig` (plans/future_features.md §10.2,
//* `zkdocs --generate-completion <bash|zsh|fish>`): shell name parsing, and
//* that each generated script registers completion for the `zkdocs`
//* command and wires the `show <TAB>` case to `--list-symbols` for dynamic,
//* project-specific symbol completion.
const std = @import("std");
const testz = @import("testz");
const zkdocs = @import("zkdocs");
const zargs = zkdocs.zargunaught;
const completion = zkdocs.completion;

pub fn fromStrParsesKnownShells() !void {
    try testz.expectEqual(completion.Shell.fromStr("bash").?, .bash);
    try testz.expectEqual(completion.Shell.fromStr("zsh").?, .zsh);
    try testz.expectEqual(completion.Shell.fromStr("fish").?, .fish);
}

pub fn fromStrRejectsUnknownShell() !void {
    try testz.expectTrue(completion.Shell.fromStr("tcsh") == null);
    try testz.expectTrue(completion.Shell.fromStr("") == null);
}

pub fn bashScriptRegistersCompletionAndQueriesListSymbols() !void {
    const gpa = std.heap.page_allocator;

    var printer = try zargs.print.Printer.memory(gpa);
    defer printer.deinit();
    try completion.printScript(&printer, .bash);

    const out = printer.array.writer.written();
    try testz.expectTrue(std.mem.indexOf(u8, out, "complete -F _zkdocs_completions zkdocs") != null);
    try testz.expectTrue(std.mem.indexOf(u8, out, "zkdocs --list-symbols") != null);
    try testz.expectTrue(std.mem.indexOf(u8, out, "--generate-completion") != null);
}

pub fn zshScriptDeclaresCompdefAndQueriesListSymbols() !void {
    const gpa = std.heap.page_allocator;

    var printer = try zargs.print.Printer.memory(gpa);
    defer printer.deinit();
    try completion.printScript(&printer, .zsh);

    const out = printer.array.writer.written();
    try testz.expectTrue(std.mem.startsWith(u8, out, "#compdef zkdocs"));
    try testz.expectTrue(std.mem.indexOf(u8, out, "zkdocs --list-symbols") != null);
}

pub fn fishScriptRegistersCompletionAndQueriesListSymbols() !void {
    const gpa = std.heap.page_allocator;

    var printer = try zargs.print.Printer.memory(gpa);
    defer printer.deinit();
    try completion.printScript(&printer, .fish);

    const out = printer.array.writer.written();
    try testz.expectTrue(std.mem.indexOf(u8, out, "complete -c zkdocs") != null);
    try testz.expectTrue(std.mem.indexOf(u8, out, "zkdocs --list-symbols") != null);
    try testz.expectTrue(std.mem.indexOf(u8, out, "__fish_seen_subcommand_from show") != null);
}
