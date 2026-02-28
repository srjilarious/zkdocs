const std = @import("std");
const symbols = @import("symbols.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const path = "sample.zig";
    const source = try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
    defer allocator.free(source);

    const source_null = try allocator.dupeZ(u8, source);
    defer allocator.free(source_null);

    var tree = try std.zig.Ast.parse(allocator, source_null, .zig);
    defer tree.deinit(allocator);

    var module = try symbols.extractModule(allocator, &tree, "sample");
    defer symbols.deinitModule(allocator, &module);

    std.debug.print("Module: {s}\n", .{module.name});
    for (module.symbols.items) |sym| {
        switch (sym.kind) {
            .function => if (sym.function) |f| {
                std.debug.print("  fn {s} ({d} params)", .{ f.name, f.params.len });
                if (f.is_pub) std.debug.print(" pub", .{});
                if (f.doc) |d| std.debug.print(" doc: {s}", .{d});
                std.debug.print("\n", .{});
            },
            .variable => if (sym.variable) |v| {
                std.debug.print("  var {s}", .{v.name});
                if (v.is_pub) std.debug.print(" pub", .{});
                if (v.doc) |d| std.debug.print(" doc: {s}", .{d});
                std.debug.print("\n", .{});
            },
            .container => if (sym.container) |c| {
                std.debug.print("  container {s}", .{c.name});
                if (c.is_pub) std.debug.print(" pub", .{});
                if (c.doc) |d| std.debug.print(" doc: {s}", .{d});
                std.debug.print("\n", .{});
            },
            else => {},
        }
    }
}
