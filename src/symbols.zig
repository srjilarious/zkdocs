const std = @import("std");

pub const SymbolKind = enum {
    function,
    variable,
    container,
    @"test",
    other,
};

pub const Param = struct {
    name: ?[]const u8,
    type_src: []const u8,
};

pub const Function = struct {
    name: []const u8,
    params: []const Param,
    return_type_src: ?[]const u8,
    doc: ?[]const u8,
    is_pub: bool,
};

pub const Container = struct {
    name: []const u8,
    doc: ?[]const u8,
    is_pub: bool,
    members: std.ArrayListUnmanaged(Symbol),
};

pub const Variable = struct {
    name: []const u8,
    type_src: ?[]const u8,
    doc: ?[]const u8,
    is_pub: bool,
};

pub const Symbol = struct {
    kind: SymbolKind,
    function: ?Function = null,
    variable: ?Variable = null,
    container: ?Container = null,
};

pub const Module = struct {
    name: []const u8,
    symbols: std.ArrayListUnmanaged(Symbol),
};

fn getDocCommentBefore(tree: std.zig.Ast, first_token: std.zig.Ast.TokenIndex) ?[]const u8 {
    if (first_token == 0) return null;
    var i = first_token - 1;
    while (i > 0) : (i -= 1) {
        const tag = tree.tokenTag(i);
        if (tag == .string_literal or tag == .doc_comment) {
            return tree.tokenSlice(i);
        }
        switch (tag) {
            .container_doc_comment => continue,
            else => break,
        }
    }
    return null;
}

fn isPub(tree: std.zig.Ast, first_token: std.zig.Ast.TokenIndex) bool {
    if (first_token == 0) return false;
    var i = first_token;
    while (i > 0) {
        i -= 1;
        if (tree.tokenTag(i) == .keyword_pub) return true;
        switch (tree.tokenTag(i)) {
            .keyword_extern, .keyword_export, .keyword_inline, .keyword_noinline,
            .keyword_comptime, .keyword_threadlocal, .string_literal, .doc_comment,
            => continue,
            else => break,
        }
    }
    return false;
}

fn nodeToSource(tree: std.zig.Ast, node: std.zig.Ast.Node.Index) []const u8 {
    const start_tok = tree.firstToken(node);
    const end_tok = tree.lastToken(node);
    const start_byte = tree.tokenStart(start_tok);
    const end_byte = tree.tokenStart(end_tok) + tree.tokenSlice(end_tok).len;
    return tree.source[start_byte..end_byte];
}

pub fn extractModule(
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    module_name: []const u8,
) !Module {
    var module: Module = .{
        .name = module_name,
        .symbols = .{},
    };
    errdefer module.symbols.deinit(allocator);

    var fn_proto_buffer: [1]std.zig.Ast.Node.Index = undefined;
    var container_buffer: [2]std.zig.Ast.Node.Index = undefined;

    const decls = tree.rootDecls();
    for (decls) |decl_index| {
        const tag = tree.nodeTag(decl_index);
        const first_tok = tree.firstToken(decl_index);
        const doc = getDocCommentBefore(tree.*, first_tok);
        const is_public = isPub(tree.*, first_tok);

        switch (tag) {
            .fn_decl => {
                const proto_node = tree.nodeData(decl_index).node_and_node[0];
                if (tree.fullFnProto(&fn_proto_buffer, proto_node)) |proto| {
                    const name = if (proto.name_token) |nt|
                        try allocator.dupe(u8, tree.tokenSlice(nt))
                    else
                        try allocator.dupe(u8, "(anonymous)");
                    errdefer allocator.free(name);

                    var params = try std.ArrayList(Param).initCapacity(allocator, 0);
                    defer params.deinit(allocator);

                    var it = proto.iterate(tree);
                    while (it.next()) |p| {
                        const param_name: ?[]const u8 = if (p.name_token) |nt|
                            try allocator.dupe(u8, tree.tokenSlice(nt))
                        else
                            null;
                        const type_src = if (p.type_expr) |tn|
                            try allocator.dupe(u8, nodeToSource(tree.*, tn))
                        else
                            try allocator.dupe(u8, "anytype");
                        try params.append(allocator, .{
                            .name = param_name,
                            .type_src = type_src,
                        });
                    }

                    const return_type_src: ?[]const u8 = if (proto.ast.return_type != .none)
                        try allocator.dupe(u8, nodeToSource(tree.*, proto.ast.return_type.unwrap().?))
                    else
                        null;
                    const doc_dup = if (doc) |d| try allocator.dupe(u8, d) else null;

                    try module.symbols.append(allocator, .{
                        .kind = .function,
                        .function = .{
                            .name = name,
                            .params = try params.toOwnedSlice(allocator),
                            .return_type_src = return_type_src,
                            .doc = doc_dup,
                            .is_pub = is_public,
                        },
                    });
                }
            },
            .fn_proto_simple,
            .fn_proto_multi,
            .fn_proto_one,
            .fn_proto,
            => {
                if (tree.fullFnProto(&fn_proto_buffer, decl_index)) |proto| {
                    const name = if (proto.name_token) |nt|
                        try allocator.dupe(u8, tree.tokenSlice(nt))
                    else
                        try allocator.dupe(u8, "(anonymous)");
                    errdefer allocator.free(name);

                    var params = try std.ArrayList(Param).initCapacity(allocator, 0);
                    defer params.deinit(allocator);
                    var it = proto.iterate(tree);
                    while (it.next()) |p| {
                        const type_src = if (p.type_expr) |tn|
                            try allocator.dupe(u8, nodeToSource(tree.*, tn))
                        else
                            try allocator.dupe(u8, "anytype");
                        try params.append(allocator, .{
                            .name = null,
                            .type_src = type_src,
                        });
                    }

                    const return_type_src: ?[]const u8 = if (proto.ast.return_type != .none)
                        try allocator.dupe(u8, nodeToSource(tree.*, proto.ast.return_type.unwrap().?))
                    else
                        null;
                    const doc_dup = if (doc) |d| try allocator.dupe(u8, d) else null;

                    try module.symbols.append(allocator, .{
                        .kind = .function,
                        .function = .{
                            .name = name,
                            .params = try params.toOwnedSlice(allocator),
                            .return_type_src = return_type_src,
                            .doc = doc_dup,
                            .is_pub = is_public,
                        },
                    });
                }
            },
            .container_decl,
            .container_decl_trailing,
            .container_decl_two,
            .container_decl_two_trailing,
            .container_decl_arg,
            .container_decl_arg_trailing,
            .tagged_union,
            .tagged_union_trailing,
            .tagged_union_two,
            .tagged_union_two_trailing,
            .tagged_union_enum_tag,
            .tagged_union_enum_tag_trailing,
            => {
                if (tree.fullContainerDecl(&container_buffer, decl_index)) |container_decl| {
                    const main_token = container_decl.ast.main_token;
                    const name = try allocator.dupe(u8, tree.tokenSlice(main_token));
                    const doc_dup = if (doc) |d| try allocator.dupe(u8, d) else null;
                    try module.symbols.append(allocator, .{
                        .kind = .container,
                        .container = .{
                            .name = name,
                            .doc = doc_dup,
                            .is_pub = is_public,
                            .members = .{},
                        },
                    });
                }
            },
            .global_var_decl,
            .local_var_decl,
            .simple_var_decl,
            .aligned_var_decl,
            => {
                if (tree.fullVarDecl(decl_index)) |var_decl| {
                    const mut_tok = var_decl.ast.mut_token;
                    const name_tok = mut_tok + 1;
                    const name = try allocator.dupe(u8, tree.tokenSlice(name_tok));
                    const type_src: ?[]const u8 = if (var_decl.ast.type_node != .none)
                        try allocator.dupe(u8, nodeToSource(tree.*, var_decl.ast.type_node.unwrap().?))
                    else
                        null;
                    const doc_dup = if (doc) |d| try allocator.dupe(u8, d) else null;
                    try module.symbols.append(allocator, .{
                        .kind = .variable,
                        .variable = .{
                            .name = name,
                            .type_src = type_src,
                            .doc = doc_dup,
                            .is_pub = is_public,
                        },
                    });
                }
            },
            else => {},
        }
    }

    return module;
}

pub fn deinitModule(allocator: std.mem.Allocator, module: *Module) void {
    for (module.symbols.items) |*sym| {
        switch (sym.kind) {
            .function => if (sym.function) |*f| {
                allocator.free(f.name);
                for (f.params) |p| {
                    if (p.name) |n| allocator.free(n);
                    allocator.free(p.type_src);
                }
                allocator.free(f.params);
                if (f.return_type_src) |s| allocator.free(s);
                if (f.doc) |s| allocator.free(s);
            },
            .variable => if (sym.variable) |*v| {
                allocator.free(v.name);
                if (v.type_src) |s| allocator.free(s);
                if (v.doc) |s| allocator.free(s);
            },
            .container => if (sym.container) |*c| {
                allocator.free(c.name);
                if (c.doc) |s| allocator.free(s);
                for (c.members.items) |*m| _ = m;
                c.members.deinit(allocator);
            },
            else => {},
        }
    }
    module.symbols.deinit(allocator);
}
