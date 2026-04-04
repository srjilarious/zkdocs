const std = @import("std");

// ---------------------------------------------------------------------------
// Public types
// ---------------------------------------------------------------------------

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
    generic_return: ?Container = null,
    /// Source text of the function body block (including braces), or null for
    /// extern/proto-only declarations.
    body_src: ?[]const u8 = null,
};

pub const ContainerKind = enum { @"struct", @"enum", @"union", @"opaque" };

pub const Field = struct {
    name: []const u8,
    type_src: ?[]const u8,
    doc: ?[]const u8,
};

pub const Container = struct {
    name: []const u8,
    kind: ContainerKind,
    doc: ?[]const u8,
    is_pub: bool,
    fields: []const Field,
    /// Nested functions and types declared inside the container.
    decls: std.ArrayListUnmanaged(Symbol),
};

pub const Variable = struct {
    name: []const u8,
    type_src: ?[]const u8,
    /// Initialiser source text, or null when the value was not captured.
    /// Always null when `is_import` is true.
    value_src: ?[]const u8,
    doc: ?[]const u8,
    is_pub: bool,
    /// True when the initialiser is an `@import(...)` call.
    is_import: bool,
};

pub const Symbol = struct {
    kind: SymbolKind,
    function: ?Function = null,
    variable: ?Variable = null,
    container: ?Container = null,
};

pub const Module = struct {
    name: []const u8,
    /// Display path shown in the generated HTML (relative to the root source dir).
    path: []const u8,
    /// Absolute filesystem path; used for build-cache mtime tracking.
    abs_path: []const u8,
    symbols: std.ArrayListUnmanaged(Symbol),
    /// Name of the module that directly imported this one, or null for roots.
    /// Heap-allocated; freed by deinitModule.
    parent_name: ?[]const u8 = null,
    /// File-level `//!` doc comment, joined into a single string.
    /// Heap-allocated; freed by deinitModule.
    doc: ?[]const u8 = null,
};

// ---------------------------------------------------------------------------
// Private helpers
// ---------------------------------------------------------------------------

/// Collect the doc comment block immediately preceding `first_token`.
/// Scans backwards, skipping declaration modifier keywords, then collects
/// all consecutive `.doc_comment` tokens. Strips the `/// ` prefix from each
/// line and joins them with `\n`. Returns null if no doc comment is found.
fn collectDocComment(
    allocator: std.mem.Allocator,
    tree: std.zig.Ast,
    first_token: std.zig.Ast.TokenIndex,
) !?[]u8 {
    if (first_token == 0) return null;

    // Scan backwards from first_token looking for the last doc_comment token.
    // `first_token` is already the first token of the whole declaration
    // (including `pub`, `extern`, etc.), so modifier keywords may appear
    // between the doc comment and first_token.
    var last_doc: ?std.zig.Ast.TokenIndex = null;
    {
        var i: std.zig.Ast.TokenIndex = first_token;
        while (i > 0) {
            i -= 1;
            switch (tree.tokenTag(i)) {
                .doc_comment => {
                    last_doc = i;
                    break;
                },
                .keyword_pub,
                .keyword_extern,
                .keyword_export,
                .keyword_inline,
                .keyword_noinline,
                .keyword_comptime,
                .keyword_threadlocal,
                .string_literal,
                => {},
                else => break,
            }
        }
    }
    const last = last_doc orelse return null;

    // Walk further back to find the start of the consecutive doc_comment block.
    var first = last;
    while (first > 0) {
        const prev = first - 1;
        if (tree.tokenTag(prev) == .doc_comment) {
            first = prev;
        } else break;
    }

    // Concatenate lines, stripping the `/// ` or `///` prefix.
    // In Zig 0.15, ArrayList is unmanaged; all methods take the allocator.
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);

    var idx: std.zig.Ast.TokenIndex = first;
    var inCodeBlock = false;
    while (idx <= last) : (idx += 1) {
        const raw = tree.tokenSlice(idx);
        const text = if (std.mem.startsWith(u8, raw, "/// "))
            raw[4..]
        else if (std.mem.startsWith(u8, raw, "///"))
            raw[3..]
        else
            raw;

        // Track code-fence boundaries. We need to know whether we were inside
        // a code block BEFORE this line to decide the join character, so
        // capture the pre-toggle state first.
        const wasInCodeBlock = inCodeBlock;
        if (std.mem.indexOf(u8, text, "```") != null) inCodeBlock = !inCodeBlock;

        if (buf.items.len > 0) {
            if (wasInCodeBlock or inCodeBlock) {
                // Inside a code block (or transitioning into/out of one) every
                // line keeps its newline so fences sit on their own lines.
                try buf.append(allocator, '\n');
            } else if (text.len == 0) {
                // Blank doc-comment line → paragraph break.
                try buf.append(allocator, '\n');
            } else {
                // Regular paragraph text: join with a space so words don't
                // run together; zmd renders a single space between them.
                try buf.append(allocator, ' ');
            }
        }

        try buf.appendSlice(allocator, text);
    }

    if (buf.items.len == 0) return null;
    return try buf.toOwnedSlice(allocator);
}

fn isPub(tree: std.zig.Ast, first_token: std.zig.Ast.TokenIndex) bool {
    // `first_token` may itself be the `pub` token (e.g. when tree.firstToken()
    // returns the visib_token of a fn_proto or var_decl).
    if (tree.tokenTag(first_token) == .keyword_pub) return true;
    if (first_token == 0) return false;
    var i: std.zig.Ast.TokenIndex = first_token;
    while (i > 0) {
        i -= 1;
        if (tree.tokenTag(i) == .keyword_pub) return true;
        switch (tree.tokenTag(i)) {
            .keyword_extern,
            .keyword_export,
            .keyword_inline,
            .keyword_noinline,
            .keyword_comptime,
            .keyword_threadlocal,
            .string_literal,
            .doc_comment,
            => {},
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

/// Normalise a function body block for display.
/// `src` starts with `{` (the body's opening brace token) and inner lines
/// carry their full file-absolute indentation.  We strip the indentation of
/// the *closing brace* line so that `{` and `}` sit at column 0 while the
/// body content retains one level of relative indent.
fn dedentBlock(allocator: std.mem.Allocator, src: []const u8) ![]const u8 {
    // Find the indent of the last non-empty line (the closing `}`).
    var strip: usize = 0;
    var pos: usize = src.len;
    // Walk backwards past any trailing newline.
    while (pos > 0 and src[pos - 1] == '\n') pos -= 1;
    // Walk back to the start of this last line.
    const line_end = pos;
    while (pos > 0 and src[pos - 1] != '\n') pos -= 1;
    const last_line = src[pos..line_end];
    // Count leading spaces/tabs on the closing brace line.
    for (last_line) |c| {
        if (c == ' ' or c == '\t') strip += 1 else break;
    }
    if (strip == 0) return allocator.dupe(u8, src);

    var out: std.ArrayList(u8) = .{};
    errdefer out.deinit(allocator);
    var lines = std.mem.splitScalar(u8, src, '\n');
    var line_num: usize = 0;
    while (lines.next()) |line| {
        if (line_num > 0) try out.append(allocator, '\n');
        if (line_num == 0) {
            // Opening `{` line: always at col 0 in the slice, keep verbatim.
            try out.appendSlice(allocator, line);
        } else if (line.len == 0) {
            // Blank line: keep empty.
        } else {
            // Strip up to `strip` leading spaces/tabs.
            var s: usize = 0;
            while (s < strip and s < line.len and
                (line[s] == ' ' or line[s] == '\t')) s += 1;
            try out.appendSlice(allocator, line[s..]);
        }
        line_num += 1;
    }
    return out.toOwnedSlice(allocator);
}

fn isContainerTag(tag: std.zig.Ast.Node.Tag) bool {
    return switch (tag) {
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
        => true,
        else => false,
    };
}

/// If `fn_decl_node` is a `fn_decl` whose body is a single `return <container>`,
/// returns the container node index. Otherwise returns null.
fn findReturnedContainerNode(
    tree: *const std.zig.Ast,
    fn_decl_node: std.zig.Ast.Node.Index,
) ?std.zig.Ast.Node.Index {
    // fn_decl data is .node_and_node: [fn_proto, body_block]
    const body = tree.nodeData(fn_decl_node).node_and_node[1];

    var stmts_buf: [2]std.zig.Ast.Node.Index = undefined;
    const stmts = tree.blockStatements(&stmts_buf, body) orelse return null;

    for (stmts) |stmt| {
        if (tree.nodeTag(stmt) != .@"return") continue;
        const ret_expr = tree.nodeData(stmt).opt_node.unwrap() orelse continue;

        // Direct: `return struct { ... }`
        if (isContainerTag(tree.nodeTag(ret_expr))) return ret_expr;

        // Indirect: `const X = struct { ... }; return X;`
        if (tree.nodeTag(ret_expr) == .identifier) {
            const ret_name = tree.tokenSlice(tree.nodeMainToken(ret_expr));
            for (stmts) |other| {
                const vd = tree.fullVarDecl(other) orelse continue;
                const decl_name = tree.tokenSlice(vd.ast.mut_token + 1);
                if (!std.mem.eql(u8, decl_name, ret_name)) continue;
                if (vd.ast.init_node.unwrap()) |init| {
                    if (isContainerTag(tree.nodeTag(init))) return init;
                }
            }
        }
    }
    return null;
}

fn getContainerKind(tree: std.zig.Ast, cd: std.zig.Ast.full.ContainerDecl) ContainerKind {
    return switch (tree.tokenTag(cd.ast.main_token)) {
        .keyword_struct => .@"struct",
        .keyword_enum => .@"enum",
        .keyword_union => .@"union",
        .keyword_opaque => .@"opaque",
        else => .@"struct",
    };
}

/// If `node` is a `@import("./relative/path.zig")` call, return the path
/// string (without quotes). Returns null otherwise or for non-relative imports.
fn getImportPath(tree: std.zig.Ast, node: std.zig.Ast.Node.Index) ?[]const u8 {
    const tag = tree.nodeTag(node);
    if (tag != .builtin_call_two and tag != .builtin_call_two_comma) return null;

    const main_tok = tree.nodeMainToken(node);
    if (!std.mem.eql(u8, tree.tokenSlice(main_tok), "@import")) return null;

    var buf: [2]std.zig.Ast.Node.Index = undefined;
    const params = tree.builtinCallParams(&buf, node) orelse return null;
    if (params.len != 1) return null;

    const arg_tok = tree.nodeMainToken(params[0]);
    if (tree.tokenTag(arg_tok) != .string_literal) return null;

    const raw = tree.tokenSlice(arg_tok);
    if (raw.len < 2) return null;
    const inner = raw[1 .. raw.len - 1]; // strip surrounding quotes

    // Only follow relative imports.
    if (!std.mem.startsWith(u8, inner, "./") and
        !std.mem.startsWith(u8, inner, "../")) return null;

    return inner;
}

/// Return true when `node` is any `@import(...)` call (relative or builtin).
fn isImportNode(tree: std.zig.Ast, node: std.zig.Ast.Node.Index) bool {
    const tag = tree.nodeTag(node);
    if (tag != .builtin_call_two and tag != .builtin_call_two_comma) return false;
    const main_tok = tree.nodeMainToken(node);
    return std.mem.eql(u8, tree.tokenSlice(main_tok), "@import");
}

fn deinitContainer(allocator: std.mem.Allocator, c: *Container) void {
    allocator.free(c.name);
    if (c.doc) |s| allocator.free(s);
    for (c.fields) |f| {
        allocator.free(f.name);
        if (f.type_src) |s| allocator.free(s);
        if (f.doc) |s| allocator.free(s);
    }
    allocator.free(c.fields);
    for (c.decls.items) |*d| deinitSymbol(allocator, d);
    c.decls.deinit(allocator);
}

fn deinitSymbol(allocator: std.mem.Allocator, sym: *Symbol) void {
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
            if (f.body_src) |s| allocator.free(s);
            if (f.generic_return) |*c| deinitContainer(allocator, c);
        },
        .variable => if (sym.variable) |*v| {
            allocator.free(v.name);
            if (v.type_src) |s| allocator.free(s);
            if (v.value_src) |s| allocator.free(s);
            if (v.doc) |s| allocator.free(s);
        },
        .container => if (sym.container) |*c| deinitContainer(allocator, c),
        else => {},
    }
}

// ---------------------------------------------------------------------------
// Symbol extractors
// ---------------------------------------------------------------------------

/// Extract a function symbol from a fn_decl or fn_proto_* node.
/// Computes doc and is_pub from the node's first token.
fn extractFnSymbol(
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
) std.mem.Allocator.Error!Symbol {
    const first_tok = tree.firstToken(node);
    const doc = try collectDocComment(allocator, tree.*, first_tok);
    errdefer if (doc) |d| allocator.free(d);
    const is_pub = isPub(tree.*, first_tok);

    var fn_buf: [1]std.zig.Ast.Node.Index = undefined;
    const proto = tree.fullFnProto(&fn_buf, node).?;

    const name = if (proto.name_token) |nt|
        try allocator.dupe(u8, tree.tokenSlice(nt))
    else
        try allocator.dupe(u8, "(anonymous)");
    errdefer allocator.free(name);

    var params_list = std.ArrayList(Param){};
    errdefer {
        for (params_list.items) |p| {
            if (p.name) |n| allocator.free(n);
            allocator.free(p.type_src);
        }
        params_list.deinit(allocator);
    }

    var it = proto.iterate(tree);
    while (it.next()) |p| {
        const param_name: ?[]const u8 = if (p.name_token) |nt|
            try allocator.dupe(u8, tree.tokenSlice(nt))
        else
            null;
        errdefer if (param_name) |n| allocator.free(n);

        const type_src = if (p.type_expr) |tn|
            try allocator.dupe(u8, nodeToSource(tree.*, tn))
        else
            try allocator.dupe(u8, "anytype");
        errdefer allocator.free(type_src);

        try params_list.append(allocator, .{ .name = param_name, .type_src = type_src });
    }

    const return_type_src: ?[]const u8 = if (proto.ast.return_type != .none)
        try allocator.dupe(u8, nodeToSource(tree.*, proto.ast.return_type.unwrap().?))
    else
        null;
    errdefer if (return_type_src) |s| allocator.free(s);

    var generic_return: ?Container = null;
    errdefer if (generic_return) |*c| deinitContainer(allocator, c);

    var body_src: ?[]const u8 = null;
    errdefer if (body_src) |s| allocator.free(s);

    if (tree.nodeTag(node) == .fn_decl) {
        const body_node = tree.nodeData(node).node_and_node[1];
        body_src = try dedentBlock(allocator, nodeToSource(tree.*, body_node));

        if (return_type_src) |rts| {
            if (std.mem.eql(u8, rts, "type")) {
                if (findReturnedContainerNode(tree, node)) |cn| {
                    const gr_name = try allocator.dupe(u8, name);
                    const sym = try extractContainerSymbol(
                        allocator,
                        tree,
                        cn,
                        gr_name,
                        tree.firstToken(cn),
                        is_pub,
                    );
                    generic_return = sym.container;
                    // Body of a generic function is the returned container's
                    // definition, not useful to show — suppress it.
                    if (body_src) |s| allocator.free(s);
                    body_src = null;
                }
            }
        }
    }

    return .{
        .kind = .function,
        .function = .{
            .name = name,
            .params = try params_list.toOwnedSlice(allocator),
            .return_type_src = return_type_src,
            .doc = doc,
            .is_pub = is_pub,
            .generic_return = generic_return,
            .body_src = body_src,
        },
    };
}

/// Extract a container symbol from a container_decl_* or tagged_union_* node.
/// `name` must be an already-allocated string; ownership is transferred to this
/// function (freed on error, owned by the returned Symbol on success).
/// `first_decl_tok` is the first token of the outer var_decl, used to locate
/// the doc comment.
fn extractContainerSymbol(
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    container_node: std.zig.Ast.Node.Index,
    name: []u8,
    first_decl_tok: std.zig.Ast.TokenIndex,
    is_pub: bool,
) std.mem.Allocator.Error!Symbol {
    errdefer allocator.free(name);

    const doc = try collectDocComment(allocator, tree.*, first_decl_tok);
    errdefer if (doc) |d| allocator.free(d);

    var cd_buf: [2]std.zig.Ast.Node.Index = undefined;
    const cd = tree.fullContainerDecl(&cd_buf, container_node).?;
    const kind = getContainerKind(tree.*, cd);

    var fields_list = std.ArrayList(Field){};
    errdefer {
        for (fields_list.items) |f| {
            allocator.free(f.name);
            if (f.type_src) |s| allocator.free(s);
            if (f.doc) |s| allocator.free(s);
        }
        fields_list.deinit(allocator);
    }

    var decls_list = std.ArrayListUnmanaged(Symbol){};
    errdefer {
        for (decls_list.items) |*s| deinitSymbol(allocator, s);
        decls_list.deinit(allocator);
    }

    for (cd.ast.members) |member| {
        const member_tag = tree.nodeTag(member);
        switch (member_tag) {
            // --- fields ---
            .container_field,
            .container_field_init,
            .container_field_align,
            => {
                var cf = tree.fullContainerField(member).?;
                // Convert enum-style "tuple-like" fields (e.g. `enum { red }`)
                // into named fields so `main_token` holds the member name and
                // `type_expr` is cleared.
                cf.convertToNonTupleLike(tree);
                const field_doc = try collectDocComment(allocator, tree.*, cf.firstToken());
                errdefer if (field_doc) |d| allocator.free(d);

                const field_name = if (!cf.ast.tuple_like)
                    try allocator.dupe(u8, tree.tokenSlice(cf.ast.main_token))
                else
                    try allocator.dupe(u8, "_");
                errdefer allocator.free(field_name);

                const type_src: ?[]const u8 = if (cf.ast.type_expr.unwrap()) |tn|
                    try allocator.dupe(u8, nodeToSource(tree.*, tn))
                else
                    null;
                errdefer if (type_src) |s| allocator.free(s);

                try fields_list.append(allocator, .{
                    .name = field_name,
                    .type_src = type_src,
                    .doc = field_doc,
                });
            },
            // --- methods / associated functions ---
            .fn_decl,
            .fn_proto_simple,
            .fn_proto_multi,
            .fn_proto_one,
            .fn_proto,
            => {
                const sym = try extractFnSymbol(allocator, tree, member);
                errdefer deinitSymbol(allocator, @constCast(&sym));
                try decls_list.append(allocator, sym);
            },
            // Nested types (pub const Inner = struct { ... }) inside containers
            .global_var_decl,
            .local_var_decl,
            .simple_var_decl,
            .aligned_var_decl,
            => {
                const var_decl = tree.fullVarDecl(member) orelse continue;
                const member_first_tok = tree.firstToken(member);
                const member_pub = isPub(tree.*, member_first_tok);
                const name_tok = var_decl.ast.mut_token + 1;

                if (var_decl.ast.init_node.unwrap()) |init_node| {
                    if (isContainerTag(tree.nodeTag(init_node))) {
                        const nested_name = try allocator.dupe(u8, tree.tokenSlice(name_tok));
                        const sym = try extractContainerSymbol(
                            allocator,
                            tree,
                            init_node,
                            nested_name,
                            member_first_tok,
                            member_pub,
                        );
                        errdefer deinitSymbol(allocator, @constCast(&sym));
                        try decls_list.append(allocator, sym);
                        continue;
                    }
                }

                // Plain variable / constant inside the container.
                const nested_name = try allocator.dupe(u8, tree.tokenSlice(name_tok));
                errdefer allocator.free(nested_name);
                const nested_doc = try collectDocComment(allocator, tree.*, member_first_tok);
                errdefer if (nested_doc) |d| allocator.free(d);
                const type_src: ?[]const u8 = if (var_decl.ast.type_node.unwrap()) |tn|
                    try allocator.dupe(u8, nodeToSource(tree.*, tn))
                else
                    null;
                errdefer if (type_src) |s| allocator.free(s);
                const nested_is_import = if (var_decl.ast.init_node.unwrap()) |in|
                    isImportNode(tree.*, in)
                else
                    false;
                const nested_value_src: ?[]const u8 = if (!nested_is_import)
                    if (var_decl.ast.init_node.unwrap()) |in|
                        try allocator.dupe(u8, nodeToSource(tree.*, in))
                    else
                        null
                else
                    null;
                errdefer if (nested_value_src) |s| allocator.free(s);
                try decls_list.append(allocator, .{
                    .kind = .variable,
                    .variable = .{
                        .name = nested_name,
                        .type_src = type_src,
                        .value_src = nested_value_src,
                        .doc = nested_doc,
                        .is_pub = member_pub,
                        .is_import = nested_is_import,
                    },
                });
            },
            else => {},
        }
    }

    return .{
        .kind = .container,
        .container = .{
            .name = name,
            .kind = kind,
            .doc = doc,
            .is_pub = is_pub,
            .fields = try fields_list.toOwnedSlice(allocator),
            .decls = decls_list,
        },
    };
}

// ---------------------------------------------------------------------------
// Public API
// ---------------------------------------------------------------------------

/// Collect consecutive `//!` container-doc-comment tokens from the start of
/// the file. Strips the `//! ` (or `//!`) prefix and joins using the same
/// rules as collectDocComment: regular lines join with a space (soft-wrap),
/// blank `//!` lines produce a paragraph break, code fences are preserved.
/// Returns null when no such tokens are present.
fn collectContainerDocComment(
    allocator: std.mem.Allocator,
    tree: std.zig.Ast,
) !?[]u8 {
    var buf = std.ArrayList(u8){};
    errdefer buf.deinit(allocator);

    var inCodeBlock = false;
    var found = false;
    var i: std.zig.Ast.TokenIndex = 0;
    while (i < tree.tokens.len and
        tree.tokenTag(i) == .container_doc_comment) : (i += 1)
    {
        found = true;
        const raw = tree.tokenSlice(i);
        const text: []const u8 = if (std.mem.startsWith(u8, raw, "//! "))
            raw[4..]
        else if (std.mem.startsWith(u8, raw, "//!"))
            raw[3..]
        else
            raw;

        if (std.mem.indexOf(u8, text, "```") != null) inCodeBlock = !inCodeBlock;

        if (buf.items.len > 0) {
            if (inCodeBlock) {
                try buf.append(allocator, '\n');
            } else if (text.len == 0) {
                try buf.append(allocator, '\n');
            } else {
                try buf.append(allocator, ' ');
            }
        }
        try buf.appendSlice(allocator, text);
    }

    if (!found) return null;
    return try buf.toOwnedSlice(allocator);
}

/// Parse a single Zig source tree into a Module.
/// `module_name`, `file_path`, and `abs_file_path` are all duped; the caller
/// retains ownership of the originals.
pub fn extractModule(
    allocator: std.mem.Allocator,
    tree: *const std.zig.Ast,
    module_name: []const u8,
    file_path: []const u8,
    abs_file_path: []const u8,
) !Module {
    const module_doc = try collectContainerDocComment(allocator, tree.*);
    errdefer if (module_doc) |d| allocator.free(d);

    var module: Module = .{
        .name = try allocator.dupe(u8, module_name),
        .path = try allocator.dupe(u8, file_path),
        .abs_path = try allocator.dupe(u8, abs_file_path),
        .symbols = .{},
        .doc = module_doc,
    };
    errdefer {
        allocator.free(module.name);
        allocator.free(module.path);
        module.symbols.deinit(allocator);
    }

    for (tree.rootDecls()) |decl_index| {
        const tag = tree.nodeTag(decl_index);
        const first_tok = tree.firstToken(decl_index);

        switch (tag) {
            // --- functions ---
            .fn_decl,
            .fn_proto_simple,
            .fn_proto_multi,
            .fn_proto_one,
            .fn_proto,
            => {
                const sym = try extractFnSymbol(allocator, tree, decl_index);
                errdefer deinitSymbol(allocator, @constCast(&sym));
                try module.symbols.append(allocator, sym);
            },

            // --- variable / const declarations (including named containers) ---
            .global_var_decl,
            .local_var_decl,
            .simple_var_decl,
            .aligned_var_decl,
            => {
                const var_decl = tree.fullVarDecl(decl_index) orelse continue;
                const is_pub = isPub(tree.*, first_tok);
                const name_tok = var_decl.ast.mut_token + 1;

                // Check whether the initialiser is a container.
                if (var_decl.ast.init_node.unwrap()) |init_node| {
                    if (isContainerTag(tree.nodeTag(init_node))) {
                        const name = try allocator.dupe(u8, tree.tokenSlice(name_tok));
                        const sym = try extractContainerSymbol(
                            allocator,
                            tree,
                            init_node,
                            name,
                            first_tok,
                            is_pub,
                        );
                        errdefer deinitSymbol(allocator, @constCast(&sym));
                        try module.symbols.append(allocator, sym);
                        continue;
                    }
                }

                // Plain variable / constant.
                const name = try allocator.dupe(u8, tree.tokenSlice(name_tok));
                errdefer allocator.free(name);
                const doc = try collectDocComment(allocator, tree.*, first_tok);
                errdefer if (doc) |d| allocator.free(d);
                const type_src: ?[]const u8 = if (var_decl.ast.type_node.unwrap()) |tn|
                    try allocator.dupe(u8, nodeToSource(tree.*, tn))
                else
                    null;
                errdefer if (type_src) |s| allocator.free(s);
                const is_import = if (var_decl.ast.init_node.unwrap()) |in|
                    isImportNode(tree.*, in)
                else
                    false;
                const value_src: ?[]const u8 = if (!is_import)
                    if (var_decl.ast.init_node.unwrap()) |in|
                        try allocator.dupe(u8, nodeToSource(tree.*, in))
                    else
                        null
                else
                    null;
                errdefer if (value_src) |s| allocator.free(s);
                try module.symbols.append(allocator, .{
                    .kind = .variable,
                    .variable = .{
                        .name = name,
                        .type_src = type_src,
                        .value_src = value_src,
                        .doc = doc,
                        .is_pub = is_pub,
                        .is_import = is_import,
                    },
                });
            },

            else => {},
        }
    }

    return module;
}

pub fn deinitModule(allocator: std.mem.Allocator, module: *Module) void {
    allocator.free(module.name);
    allocator.free(module.path);
    allocator.free(module.abs_path);
    if (module.parent_name) |pn| allocator.free(pn);
    if (module.doc) |d| allocator.free(d);
    for (module.symbols.items) |*sym| deinitSymbol(allocator, sym);
    module.symbols.deinit(allocator);
}

pub fn deinitModules(allocator: std.mem.Allocator, modules: []Module) void {
    for (modules) |*m| deinitModule(allocator, m);
    allocator.free(modules);
}

// ---------------------------------------------------------------------------
// Module graph (import following)
// ---------------------------------------------------------------------------

/// Walk the AST looking for relative @import paths in root-level var decls.
fn collectRelativeImports(
    allocator: std.mem.Allocator,
    tree: std.zig.Ast,
    dir_path: []const u8,
    out: *std.ArrayList([]const u8),
) !void {
    for (tree.rootDecls()) |decl_index| {
        const tag = tree.nodeTag(decl_index);
        switch (tag) {
            .global_var_decl,
            .local_var_decl,
            .simple_var_decl,
            .aligned_var_decl,
            => {
                const var_decl = tree.fullVarDecl(decl_index) orelse continue;
                const init_node = var_decl.ast.init_node.unwrap() orelse continue;
                const rel = getImportPath(tree, init_node) orelse continue;

                const joined = try std.fs.path.join(allocator, &.{ dir_path, rel });
                errdefer allocator.free(joined);
                try out.append(allocator, joined);
            },
            else => {},
        }
    }
}

fn extractModuleGraphRecurse(
    allocator: std.mem.Allocator,
    path: []const u8,
    root_dir: []const u8, // absolute path of the root module's directory
    modules: *std.ArrayList(Module),
    visited: *std.StringHashMap(void),
    parent_name: ?[]const u8,
) !void {
    // Resolve to an absolute path so symlinks / ".." don't create duplicates.
    const abs_path = try std.fs.cwd().realpathAlloc(allocator, path);
    defer allocator.free(abs_path);

    const gop = try visited.getOrPut(abs_path);
    if (gop.found_existing) return;
    // Take ownership of abs_path for the map key.
    gop.key_ptr.* = try allocator.dupe(u8, abs_path);

    // Read source.
    const source = try std.fs.cwd().readFileAlloc(allocator, abs_path, std.math.maxInt(usize));
    defer allocator.free(source);
    const source_z = try allocator.dupeZ(u8, source);
    defer allocator.free(source_z);

    // Parse.
    var tree = try std.zig.Ast.parse(allocator, source_z, .zig);
    defer tree.deinit(allocator);

    // Derive module name from the file stem.
    const module_name = std.fs.path.stem(abs_path);

    // Build a path relative to the root source directory for display.
    // Strip the root_dir prefix (plus path separator) from abs_path.
    const rel_path = if (std.mem.startsWith(u8, abs_path, root_dir) and
        abs_path.len > root_dir.len and
        abs_path[root_dir.len] == std.fs.path.sep)
        abs_path[root_dir.len + 1 ..]
    else
        abs_path; // fallback: show absolute path if outside root tree

    var module = try extractModule(allocator, &tree, module_name, rel_path, abs_path);
    errdefer deinitModule(allocator, &module);
    module.parent_name = if (parent_name) |pn| try allocator.dupe(u8, pn) else null;
    try modules.append(allocator, module);

    // Find and follow relative imports, recording this module as their parent.
    const dir_path = std.fs.path.dirname(abs_path) orelse ".";
    var import_paths = std.ArrayList([]const u8){};
    defer {
        for (import_paths.items) |p| allocator.free(p);
        import_paths.deinit(allocator);
    }
    try collectRelativeImports(allocator, tree, dir_path, &import_paths);

    for (import_paths.items) |import_path| {
        try extractModuleGraphRecurse(allocator, import_path, root_dir, modules, visited, module_name);
    }
}

/// Extract documentation from the module graph rooted at `root_path`.
/// Follows relative `@import` chains recursively. Returns a caller-owned
/// slice; free with `deinitModules`.
pub fn extractModuleGraph(
    allocator: std.mem.Allocator,
    root_path: []const u8,
) ![]Module {
    var modules = std.ArrayList(Module){};
    errdefer {
        for (modules.items) |*m| deinitModule(allocator, m);
        modules.deinit(allocator);
    }

    var visited = std.StringHashMap(void).init(allocator);
    defer {
        var it = visited.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        visited.deinit();
    }

    // Resolve root to absolute so we can strip it from all child paths.
    const abs_root = try std.fs.cwd().realpathAlloc(allocator, root_path);
    defer allocator.free(abs_root);
    const root_dir = std.fs.path.dirname(abs_root) orelse ".";

    try extractModuleGraphRecurse(allocator, root_path, root_dir, &modules, &visited, null);
    const slice = try modules.toOwnedSlice(allocator);
    // Sort alphabetically by name so each sidebar level is ordered consistently.
    std.mem.sort(Module, slice, {}, struct {
        fn lessThan(_: void, a: Module, b: Module) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);
    return slice;
}
