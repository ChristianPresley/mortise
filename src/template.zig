//! The Mortise template engine. Syntax is specified in docs/templates.md.
//!
//!   {{ page.title }}                 output, HTML-escaped by default
//!   {{ content }}                    values marked as HTML are not escaped
//!   {{ page.title | upper }}         filters (five built-ins)
//!   {% if a and not b %}...{% elif c == "x" %}...{% else %}...{% endif %}
//!   {% for post in site.posts %}...{{ loop.index }}...{% endfor %}
//!   {% include "nav.html" %}
//!   {# comment #}
//!   {%- ... -%}                      `-` trims whitespace on that side
//!
//! Templates are parsed once into a node tree and rendered many times.
//! Syntax errors and render errors both carry the template name and line.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const escapeHtml = @import("markdown.zig").escapeHtml;

// ---------------------------------------------------------------------------
// Values

pub const Value = union(enum) {
    nil,
    boolean: bool,
    int: i64,
    float: f64,
    /// Text, escaped on output.
    string: []const u8,
    /// Trusted HTML, written as-is.
    html: []const u8,
    list: []const Value,
    object: Object,

    pub fn truthy(v: Value) bool {
        return switch (v) {
            .nil => false,
            .boolean => |b| b,
            .int => |i| i != 0,
            .float => |f| f != 0,
            .string, .html => |s| s.len > 0,
            .list => |l| l.len > 0,
            .object => true,
        };
    }

    fn typeName(v: Value) []const u8 {
        return switch (v) {
            .nil => "nothing",
            .boolean => "a boolean",
            .int, .float => "a number",
            .string, .html => "a string",
            .list => "a list",
            .object => "an object",
        };
    }

    fn eql(a: Value, b: Value) bool {
        const as = a.text();
        const bs = b.text();
        if (as != null and bs != null) return std.mem.eql(u8, as.?, bs.?);
        return switch (a) {
            .nil => b == .nil,
            .boolean => |x| b == .boolean and b.boolean == x,
            .int => |x| switch (b) {
                .int => |y| x == y,
                .float => |y| @as(f64, @floatFromInt(x)) == y,
                else => false,
            },
            .float => |x| switch (b) {
                .int => |y| x == @as(f64, @floatFromInt(y)),
                .float => |y| x == y,
                else => false,
            },
            else => false,
        };
    }

    fn text(v: Value) ?[]const u8 {
        return switch (v) {
            .string, .html => |s| s,
            else => null,
        };
    }
};

pub const Entry = struct { key: []const u8, value: Value };

pub const Object = struct {
    entries: []const Entry = &.{},

    pub fn get(o: Object, key: []const u8) ?Value {
        for (o.entries) |e| if (std.mem.eql(u8, e.key, key)) return e.value;
        return null;
    }
};

// ---------------------------------------------------------------------------
// Syntax tree

const Expr = union(enum) {
    path: []const []const u8,
    string: []const u8,
    int: i64,
    boolean: bool,
};

const Filter = struct {
    kind: FilterKind,
    arg: ?Expr = null,
};

pub const FilterKind = enum {
    /// Marks a string as trusted HTML so it is not escaped.
    raw,
    upper,
    lower,
    /// `default("x")`: the argument when the value is falsy.
    default,
    /// Formats a `YYYY-MM-DD` date as `January 5, 2024`.
    date,
};

const Comparison = struct {
    negate: bool,
    left: Expr,
    op: enum { truthy, eq, ne },
    right: Expr = .{ .boolean = false },
};

/// `or` of `and` groups.
const Condition = []const []const Comparison;

const Node = union(enum) {
    text: []const u8,
    output: struct { expr: Expr, filters: []const Filter, line: usize },
    @"if": struct { branches: []const Branch, line: usize },
    @"for": struct { name: []const u8, iter: Expr, body: []const Node, line: usize },
    include: struct { name: []const u8, line: usize },
};

const Branch = struct {
    /// Null for `else`.
    cond: ?Condition,
    body: []const Node,
};

pub const Template = struct {
    name: []const u8,
    nodes: []const Node,
    /// Names passed to `{% include %}`, for dependency tracking.
    includes: []const []const u8,
    /// Whether any expression reads `site.posts` or `site.pages`, whose
    /// contents change whenever any page or post does.
    reads_collections: bool,
};

pub const Diagnostic = struct {
    /// Template name (as given to `parse`) where the error occurred.
    template: []const u8 = "",
    line: usize = 0,
    message: []const u8 = "",
};

pub const ParseError = error{TemplateSyntax} || Allocator.Error;

// ---------------------------------------------------------------------------
// Parsing

const TagKind = enum { output, statement };

const Token = union(enum) {
    text: []const u8,
    tag: struct { kind: TagKind, body: []const u8, line: usize },
};

const Parser = struct {
    arena: Allocator,
    name: []const u8,
    diag: *Diagnostic,
    tokens: []const Token,
    pos: usize = 0,
    includes: std.ArrayList([]const u8) = .empty,
    reads_collections: bool = false,

    fn fail(p: *Parser, line: usize, comptime fmt: []const u8, args: anytype) ParseError {
        p.diag.* = .{
            .template = p.name,
            .line = line,
            .message = std.fmt.allocPrint(p.arena, fmt, args) catch "out of memory while reporting an error",
        };
        return error.TemplateSyntax;
    }
};

/// Parses `src`. `name` identifies the template in error messages.
pub fn parse(arena: Allocator, name: []const u8, src: []const u8, diag: *Diagnostic) ParseError!Template {
    var p: Parser = .{ .arena = arena, .name = name, .diag = diag, .tokens = &.{} };
    p.tokens = try tokenize(&p, src);
    var end: ?Stmt = null;
    const nodes = try parseNodes(&p, &end);
    if (end) |e| return p.fail(e.line, "unexpected '{s}'", .{e.keyword});
    return .{ .name = name, .nodes = nodes, .includes = p.includes.items, .reads_collections = p.reads_collections };
}

fn tokenize(p: *Parser, src: []const u8) ParseError![]const Token {
    var tokens: std.ArrayList(Token) = .empty;
    var i: usize = 0;
    var line: usize = 1;
    var trim_next = false;
    while (i < src.len) {
        const open = std.mem.indexOfScalarPos(u8, src, i, '{');
        const start = open orelse src.len;
        if (open != null and start + 1 < src.len and (src[start + 1] == '{' or src[start + 1] == '%' or src[start + 1] == '#')) {
            var text = src[i..start];
            if (trim_next) text = std.mem.trimStart(u8, text, " \t\r\n");
            const kind_char = src[start + 1];
            const trim_prev = start + 2 < src.len and src[start + 2] == '-';
            if (trim_prev) text = std.mem.trimEnd(u8, text, " \t\r\n");
            if (text.len > 0) try tokens.append(p.arena, .{ .text = text });
            line += std.mem.count(u8, src[i..start], "\n");

            const close_seq: []const u8 = switch (kind_char) {
                '{' => "}}",
                '%' => "%}",
                else => "#}",
            };
            const body_start = start + 2 + @intFromBool(trim_prev);
            const close = findClose(src, body_start, close_seq, kind_char == '#') orelse
                return p.fail(line, "unclosed '{{{c}' tag; expected '{s}'", .{ kind_char, close_seq });
            var body_end = close;
            trim_next = close > body_start and src[close - 1] == '-';
            if (trim_next) body_end -= 1;
            if (kind_char != '#') {
                try tokens.append(p.arena, .{ .tag = .{
                    .kind = if (kind_char == '{') .output else .statement,
                    .body = std.mem.trim(u8, src[body_start..body_end], " \t\r\n"),
                    .line = line,
                } });
            }
            line += std.mem.count(u8, src[start..close], "\n");
            i = close + 2;
        } else if (open) |o| {
            // A lone `{`: keep scanning past it.
            const next = o + 1;
            var text = src[i..next];
            if (trim_next) text = std.mem.trimStart(u8, text, " \t\r\n");
            trim_next = false;
            if (text.len > 0) try tokens.append(p.arena, .{ .text = text });
            line += std.mem.count(u8, src[i..next], "\n");
            i = next;
        } else {
            var text = src[i..];
            if (trim_next) text = std.mem.trimStart(u8, text, " \t\r\n");
            if (text.len > 0) try tokens.append(p.arena, .{ .text = text });
            i = src.len;
        }
    }
    return tokens.items;
}

/// Finds `close` after `from`, skipping over quoted strings in tags.
fn findClose(src: []const u8, from: usize, close: []const u8, is_comment: bool) ?usize {
    var i = from;
    var quote: u8 = 0;
    while (i + 1 < src.len) : (i += 1) {
        const c = src[i];
        if (!is_comment) {
            if (quote != 0) {
                if (c == '\\') {
                    i += 1;
                } else if (c == quote) quote = 0;
                continue;
            }
            if (c == '"' or c == '\'') {
                quote = c;
                continue;
            }
        }
        if (c == close[0] and src[i + 1] == close[1]) return i;
    }
    return null;
}

const Stmt = struct { keyword: []const u8, rest: []const u8, line: usize };

fn splitStmt(body: []const u8, line: usize) Stmt {
    const sp = std.mem.indexOfAny(u8, body, " \t\r\n") orelse body.len;
    return .{ .keyword = body[0..sp], .rest = std.mem.trim(u8, body[sp..], " \t\r\n"), .line = line };
}

/// Parses nodes until the end of input or a block-ending statement, which
/// is stored in `end`.
fn parseNodes(p: *Parser, end: *?Stmt) ParseError![]const Node {
    var nodes: std.ArrayList(Node) = .empty;
    end.* = null;
    while (p.pos < p.tokens.len) {
        const tok = p.tokens[p.pos];
        p.pos += 1;
        switch (tok) {
            .text => |t| try nodes.append(p.arena, .{ .text = t }),
            .tag => |tag| switch (tag.kind) {
                .output => try nodes.append(p.arena, try parseOutput(p, tag.body, tag.line)),
                .statement => {
                    const st = splitStmt(tag.body, tag.line);
                    if (std.mem.eql(u8, st.keyword, "if")) {
                        try nodes.append(p.arena, try parseIf(p, st));
                    } else if (std.mem.eql(u8, st.keyword, "for")) {
                        try nodes.append(p.arena, try parseFor(p, st));
                    } else if (std.mem.eql(u8, st.keyword, "include")) {
                        try nodes.append(p.arena, try parseInclude(p, st));
                    } else if (isBlockEnd(st.keyword)) {
                        end.* = st;
                        return nodes.items;
                    } else {
                        return p.fail(st.line, "unknown statement '{s}'", .{st.keyword});
                    }
                },
            },
        }
    }
    return nodes.items;
}

fn isBlockEnd(keyword: []const u8) bool {
    for ([_][]const u8{ "elif", "else", "endif", "endfor" }) |k| {
        if (std.mem.eql(u8, keyword, k)) return true;
    }
    return false;
}

fn parseIf(p: *Parser, first: Stmt) ParseError!Node {
    var branches: std.ArrayList(Branch) = .empty;
    var cond: ?Condition = try parseCondition(p, first.rest, first.line);
    var seen_else = false;
    while (true) {
        var end: ?Stmt = null;
        const body = try parseNodes(p, &end);
        try branches.append(p.arena, .{ .cond = cond, .body = body });
        const e = end orelse return p.fail(first.line, "'if' is not closed; add '{{% endif %}}'", .{});
        if (std.mem.eql(u8, e.keyword, "endif")) {
            if (e.rest.len != 0) return p.fail(e.line, "'endif' takes no arguments", .{});
            break;
        }
        if (seen_else) return p.fail(e.line, "unexpected '{s}' after 'else'", .{e.keyword});
        if (std.mem.eql(u8, e.keyword, "elif")) {
            cond = try parseCondition(p, e.rest, e.line);
        } else if (std.mem.eql(u8, e.keyword, "else")) {
            if (e.rest.len != 0) return p.fail(e.line, "'else' takes no arguments", .{});
            cond = null;
            seen_else = true;
        } else {
            return p.fail(e.line, "unexpected '{s}' inside 'if'", .{e.keyword});
        }
    }
    return .{ .@"if" = .{ .branches = branches.items, .line = first.line } };
}

fn parseFor(p: *Parser, st: Stmt) ParseError!Node {
    var lx: Lexer = .{ .p = p, .src = st.rest, .line = st.line };
    const name_tok = try lx.next();
    if (name_tok != .ident) return p.fail(st.line, "expected a loop variable name after 'for'", .{});
    const name = name_tok.ident;
    if (std.mem.indexOfScalar(u8, name, '.') != null or std.mem.eql(u8, name, "loop")) {
        return p.fail(st.line, "invalid loop variable name '{s}'", .{name});
    }
    const in_tok = try lx.next();
    if (in_tok != .ident or !std.mem.eql(u8, in_tok.ident, "in")) return p.fail(st.line, "expected 'in' after the loop variable", .{});
    const iter = try parseExpr(&lx);
    if (try lx.next() != .end) return p.fail(st.line, "unexpected text after the loop expression", .{});

    var end: ?Stmt = null;
    const body = try parseNodes(p, &end);
    const e = end orelse return p.fail(st.line, "'for' is not closed; add '{{% endfor %}}'", .{});
    if (!std.mem.eql(u8, e.keyword, "endfor")) return p.fail(e.line, "unexpected '{s}' inside 'for'", .{e.keyword});
    if (e.rest.len != 0) return p.fail(e.line, "'endfor' takes no arguments", .{});
    return .{ .@"for" = .{ .name = name, .iter = iter, .body = body, .line = st.line } };
}

fn parseInclude(p: *Parser, st: Stmt) ParseError!Node {
    var lx: Lexer = .{ .p = p, .src = st.rest, .line = st.line };
    const t = try lx.next();
    if (t != .string) return p.fail(st.line, "'include' expects a quoted template name", .{});
    if (try lx.next() != .end) return p.fail(st.line, "unexpected text after the include name", .{});
    try p.includes.append(p.arena, t.string);
    return .{ .include = .{ .name = t.string, .line = st.line } };
}

fn parseOutput(p: *Parser, body: []const u8, line: usize) ParseError!Node {
    var lx: Lexer = .{ .p = p, .src = body, .line = line };
    if (body.len == 0) return p.fail(line, "empty output tag", .{});
    const expr = try parseExpr(&lx);
    var filters: std.ArrayList(Filter) = .empty;
    while (true) {
        const t = try lx.next();
        switch (t) {
            .end => break,
            .pipe => {},
            else => return p.fail(line, "expected '|' or the end of the tag", .{}),
        }
        const name_tok = try lx.next();
        if (name_tok != .ident) return p.fail(line, "expected a filter name after '|'", .{});
        const kind = std.meta.stringToEnum(FilterKind, name_tok.ident) orelse
            return p.fail(line, "unknown filter '{s}'; the built-in filters are raw, upper, lower, default, date", .{name_tok.ident});
        var filter: Filter = .{ .kind = kind };
        if (lx.peekByte() == '(') {
            _ = try lx.next();
            filter.arg = try parseExpr(&lx);
            if (try lx.next() != .rparen) return p.fail(line, "expected ')' after the filter argument", .{});
        }
        const wants_arg = kind == .default;
        if (wants_arg and filter.arg == null) return p.fail(line, "filter 'default' needs an argument, as in default(\"x\")", .{});
        if (!wants_arg and filter.arg != null) return p.fail(line, "filter '{s}' takes no argument", .{@tagName(kind)});
        try filters.append(p.arena, filter);
    }
    return .{ .output = .{ .expr = expr, .filters = filters.items, .line = line } };
}

fn parseCondition(p: *Parser, src: []const u8, line: usize) ParseError!Condition {
    if (src.len == 0) return p.fail(line, "missing condition", .{});
    var lx: Lexer = .{ .p = p, .src = src, .line = line };
    var groups: std.ArrayList([]const Comparison) = .empty;
    var group: std.ArrayList(Comparison) = .empty;
    while (true) {
        var cmp: Comparison = .{ .negate = false, .left = undefined, .op = .truthy };
        if (lx.peekKeyword("not")) {
            _ = try lx.next();
            cmp.negate = true;
        }
        cmp.left = try parseExpr(&lx);
        var t = try lx.next();
        if (t == .eq or t == .ne) {
            cmp.op = if (t == .eq) .eq else .ne;
            cmp.right = try parseExpr(&lx);
            t = try lx.next();
        }
        try group.append(p.arena, cmp);
        switch (t) {
            .end => break,
            .ident => |w| {
                if (std.mem.eql(u8, w, "and")) continue;
                if (std.mem.eql(u8, w, "or")) {
                    try groups.append(p.arena, group.items);
                    group = .empty;
                    continue;
                }
                return p.fail(line, "unexpected '{s}' in condition", .{w});
            },
            else => return p.fail(line, "unexpected token in condition", .{}),
        }
    }
    try groups.append(p.arena, group.items);
    return groups.items;
}

fn parseExpr(lx: *Lexer) ParseError!Expr {
    const t = try lx.next();
    return switch (t) {
        .ident => |id| blk: {
            if (std.mem.eql(u8, id, "true")) break :blk .{ .boolean = true };
            if (std.mem.eql(u8, id, "false")) break :blk .{ .boolean = false };
            var segs: std.ArrayList([]const u8) = .empty;
            var it = std.mem.splitScalar(u8, id, '.');
            while (it.next()) |s| {
                if (s.len == 0) return lx.p.fail(lx.line, "invalid variable name '{s}'", .{id});
                try segs.append(lx.p.arena, s);
            }
            const path = segs.items;
            if (path.len >= 2 and std.mem.eql(u8, path[0], "site") and
                (std.mem.eql(u8, path[1], "posts") or std.mem.eql(u8, path[1], "pages")))
            {
                lx.p.reads_collections = true;
            }
            break :blk .{ .path = path };
        },
        .string => |s| .{ .string = s },
        .int => |n| .{ .int = n },
        .end => lx.p.fail(lx.line, "expected an expression", .{}),
        else => lx.p.fail(lx.line, "expected a variable, string, or number", .{}),
    };
}

const Tok = union(enum) {
    end,
    ident: []const u8,
    string: []const u8,
    int: i64,
    pipe,
    lparen,
    rparen,
    eq,
    ne,
};

const Lexer = struct {
    p: *Parser,
    src: []const u8,
    line: usize,
    i: usize = 0,

    fn skipSpace(lx: *Lexer) void {
        while (lx.i < lx.src.len and std.ascii.isWhitespace(lx.src[lx.i])) lx.i += 1;
    }

    fn peekByte(lx: *Lexer) u8 {
        lx.skipSpace();
        return if (lx.i < lx.src.len) lx.src[lx.i] else 0;
    }

    fn peekKeyword(lx: *Lexer, kw: []const u8) bool {
        lx.skipSpace();
        const rest = lx.src[lx.i..];
        if (!std.mem.startsWith(u8, rest, kw)) return false;
        return rest.len == kw.len or !isIdentChar(rest[kw.len]);
    }

    fn next(lx: *Lexer) ParseError!Tok {
        lx.skipSpace();
        if (lx.i >= lx.src.len) return .end;
        const s = lx.src;
        const c = s[lx.i];
        switch (c) {
            '|' => {
                lx.i += 1;
                return .pipe;
            },
            '(' => {
                lx.i += 1;
                return .lparen;
            },
            ')' => {
                lx.i += 1;
                return .rparen;
            },
            '=', '!' => {
                if (lx.i + 1 < s.len and s[lx.i + 1] == '=') {
                    lx.i += 2;
                    return if (c == '=') .eq else .ne;
                }
                return lx.p.fail(lx.line, "unexpected '{c}'; did you mean '{c}='?", .{ c, c });
            },
            '"', '\'' => {
                lx.i += 1;
                var out: std.ArrayList(u8) = .empty;
                while (lx.i < s.len and s[lx.i] != c) : (lx.i += 1) {
                    if (s[lx.i] == '\\' and lx.i + 1 < s.len) lx.i += 1;
                    try out.append(lx.p.arena, s[lx.i]);
                }
                if (lx.i >= s.len) return lx.p.fail(lx.line, "unterminated string", .{});
                lx.i += 1;
                return .{ .string = out.items };
            },
            '0'...'9', '-' => {
                const start = lx.i;
                lx.i += 1;
                while (lx.i < s.len and std.ascii.isDigit(s[lx.i])) lx.i += 1;
                const n = std.fmt.parseInt(i64, s[start..lx.i], 10) catch
                    return lx.p.fail(lx.line, "invalid number '{s}'", .{s[start..lx.i]});
                return .{ .int = n };
            },
            else => {
                if (!(std.ascii.isAlphabetic(c) or c == '_')) {
                    return lx.p.fail(lx.line, "unexpected character '{c}'", .{c});
                }
                const start = lx.i;
                while (lx.i < s.len and (isIdentChar(s[lx.i]) or s[lx.i] == '.')) lx.i += 1;
                return .{ .ident = s[start..lx.i] };
            },
        }
    }
};

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
}

// ---------------------------------------------------------------------------
// Rendering

/// Resolves include names to parsed templates.
pub const Loader = struct {
    ctx: *anyopaque,
    loadFn: *const fn (ctx: *anyopaque, name: []const u8, diag: *Diagnostic) LoadError!*const Template,

    pub const LoadError = error{ TemplateNotFound, TemplateSyntax } || Allocator.Error;

    fn load(l: Loader, name: []const u8, diag: *Diagnostic) LoadError!*const Template {
        return l.loadFn(l.ctx, name, diag);
    }
};

pub const RenderError = error{ TemplateRender, TemplateSyntax, TemplateNotFound } || Allocator.Error || Writer.Error;

const max_include_depth = 32;

const Binding = struct { name: []const u8, value: Value };

const Renderer = struct {
    arena: Allocator,
    loader: ?Loader,
    diag: *Diagnostic,
    root: Object,
    scope: std.ArrayList(Binding) = .empty,
    template: []const u8 = "",
    depth: usize = 0,

    fn fail(r: *Renderer, line: usize, comptime fmt: []const u8, args: anytype) RenderError {
        r.diag.* = .{
            .template = r.template,
            .line = line,
            .message = std.fmt.allocPrint(r.arena, fmt, args) catch "out of memory while reporting an error",
        };
        return error.TemplateRender;
    }
};

/// Renders `tpl` with `root` as the top-level variables.
pub fn render(arena: Allocator, tpl: *const Template, root: Object, loader: ?Loader, w: *Writer, diag: *Diagnostic) RenderError!void {
    var r: Renderer = .{ .arena = arena, .loader = loader, .diag = diag, .root = root, .template = tpl.name };
    try renderNodes(&r, tpl.nodes, w);
}

/// Renders to a newly allocated string.
pub fn renderAlloc(arena: Allocator, tpl: *const Template, root: Object, loader: ?Loader, diag: *Diagnostic) RenderError![]u8 {
    var aw: Writer.Allocating = .init(arena);
    try render(arena, tpl, root, loader, &aw.writer, diag);
    return aw.toOwnedSlice();
}

fn renderNodes(r: *Renderer, nodes: []const Node, w: *Writer) RenderError!void {
    for (nodes) |node| switch (node) {
        .text => |t| try w.writeAll(t),
        .output => |o| {
            var v = try evalExpr(r, o.expr);
            for (o.filters) |f| v = try applyFilter(r, f, v, o.line);
            try writeValue(r, v, w, o.line);
        },
        .@"if" => |n| {
            for (n.branches) |b| {
                const take = if (b.cond) |c| try evalCondition(r, c) else true;
                if (take) {
                    try renderNodes(r, b.body, w);
                    break;
                }
            }
        },
        .@"for" => |n| {
            const iter = try evalExpr(r, n.iter);
            const items: []const Value = switch (iter) {
                .nil => &.{},
                .list => |l| l,
                else => return r.fail(n.line, "cannot loop over {s}", .{iter.typeName()}),
            };
            const base = r.scope.items.len;
            defer r.scope.shrinkRetainingCapacity(base);
            try r.scope.appendNTimes(r.arena, .{ .name = "", .value = .nil }, 2);
            for (items, 0..) |item, idx| {
                const loop_entries = try r.arena.alloc(Entry, 4);
                loop_entries[0] = .{ .key = "index", .value = .{ .int = @intCast(idx + 1) } };
                loop_entries[1] = .{ .key = "index0", .value = .{ .int = @intCast(idx) } };
                loop_entries[2] = .{ .key = "first", .value = .{ .boolean = idx == 0 } };
                loop_entries[3] = .{ .key = "last", .value = .{ .boolean = idx + 1 == items.len } };
                r.scope.items[base] = .{ .name = "loop", .value = .{ .object = .{ .entries = loop_entries } } };
                r.scope.items[base + 1] = .{ .name = n.name, .value = item };
                try renderNodes(r, n.body, w);
            }
        },
        .include => |inc| {
            const loader = r.loader orelse return r.fail(inc.line, "includes are not available here", .{});
            if (r.depth >= max_include_depth) {
                return r.fail(inc.line, "includes nested more than {d} deep (is '{s}' including itself?)", .{ max_include_depth, inc.name });
            }
            const saved_diag = r.diag.*;
            const child = loader.load(inc.name, r.diag) catch |err| switch (err) {
                error.TemplateNotFound => {
                    r.diag.* = saved_diag;
                    return r.fail(inc.line, "included template '{s}' was not found", .{inc.name});
                },
                else => |e| return e,
            };
            const outer = r.template;
            r.template = child.name;
            r.depth += 1;
            try renderNodes(r, child.nodes, w);
            r.depth -= 1;
            r.template = outer;
        },
    };
}

fn lookup(r: *Renderer, path: []const []const u8) Value {
    const first = path[0];
    var v: Value = blk: {
        var k = r.scope.items.len;
        while (k > 0) {
            k -= 1;
            if (std.mem.eql(u8, r.scope.items[k].name, first)) break :blk r.scope.items[k].value;
        }
        break :blk r.root.get(first) orelse return .nil;
    };
    for (path[1..]) |seg| {
        v = switch (v) {
            .object => |o| o.get(seg) orelse return .nil,
            else => return .nil,
        };
    }
    return v;
}

fn evalExpr(r: *Renderer, e: Expr) RenderError!Value {
    return switch (e) {
        .path => |p| lookup(r, p),
        .string => |s| .{ .string = s },
        .int => |n| .{ .int = n },
        .boolean => |b| .{ .boolean = b },
    };
}

fn evalCondition(r: *Renderer, cond: Condition) RenderError!bool {
    for (cond) |group| {
        var all = true;
        for (group) |cmp| {
            const left = try evalExpr(r, cmp.left);
            var result = switch (cmp.op) {
                .truthy => left.truthy(),
                .eq => left.eql(try evalExpr(r, cmp.right)),
                .ne => !left.eql(try evalExpr(r, cmp.right)),
            };
            if (cmp.negate) result = !result;
            if (!result) {
                all = false;
                break;
            }
        }
        if (all) return true;
    }
    return false;
}

fn applyFilter(r: *Renderer, f: Filter, v: Value, line: usize) RenderError!Value {
    switch (f.kind) {
        .raw => return switch (v) {
            .string => |s| .{ .html = s },
            else => v,
        },
        .upper, .lower => {
            const s = v.text() orelse switch (v) {
                .nil => return v,
                else => return r.fail(line, "filter '{s}' expects a string, got {s}", .{ @tagName(f.kind), v.typeName() }),
            };
            const out = try r.arena.alloc(u8, s.len);
            if (f.kind == .upper) _ = std.ascii.upperString(out, s) else _ = std.ascii.lowerString(out, s);
            return if (v == .html) .{ .html = out } else .{ .string = out };
        },
        .default => return if (v.truthy()) v else try evalExpr(r, f.arg.?),
        .date => {
            const s = v.text() orelse switch (v) {
                .nil => return v,
                else => return r.fail(line, "filter 'date' expects a date string, got {s}", .{v.typeName()}),
            };
            const d = parseDate(s) orelse return r.fail(line, "filter 'date' expects YYYY-MM-DD, got '{s}'", .{s});
            return .{ .string = try std.fmt.allocPrint(r.arena, "{s} {d}, {d}", .{ month_names[d.month - 1], d.day, d.year }) };
        },
    }
}

const month_names = [_][]const u8{
    "January", "February", "March",     "April",   "May",      "June",
    "July",    "August",   "September", "October", "November", "December",
};

pub const Date = struct { year: u16, month: u8, day: u8 };

/// Parses the `YYYY-MM-DD` prefix of `s`. Anything after the date (a time,
/// for example) is ignored.
pub fn parseDate(s: []const u8) ?Date {
    if (s.len < 10 or s[4] != '-' or s[7] != '-') return null;
    if (s.len > 10 and s[10] != ' ' and s[10] != 'T') return null;
    const year = std.fmt.parseInt(u16, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > daysInMonth(year, month)) return null;
    return .{ .year = year, .month = month, .day = day };
}

fn daysInMonth(year: u16, month: u8) u8 {
    return switch (month) {
        2 => if ((year % 4 == 0 and year % 100 != 0) or year % 400 == 0) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
}

fn writeValue(r: *Renderer, v: Value, w: *Writer, line: usize) RenderError!void {
    switch (v) {
        .nil => {},
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .int => |n| try w.print("{d}", .{n}),
        .float => |f| try w.print("{d}", .{f}),
        .string => |s| try escapeHtml(w, s),
        .html => |s| try w.writeAll(s),
        .list, .object => return r.fail(line, "cannot output {s}; loop over it or pick a field", .{v.typeName()}),
    }
}

// ---------------------------------------------------------------------------

const testing = std.testing;

const TestLoader = struct {
    arena: Allocator,
    files: []const struct { []const u8, []const u8 },
    parsed: std.StringHashMapUnmanaged(*const Template) = .empty,

    fn loader(t: *TestLoader) Loader {
        return .{ .ctx = t, .loadFn = load };
    }

    fn load(ctx: *anyopaque, name: []const u8, diag: *Diagnostic) Loader.LoadError!*const Template {
        const t: *TestLoader = @ptrCast(@alignCast(ctx));
        if (t.parsed.get(name)) |tpl| return tpl;
        for (t.files) |f| {
            if (!std.mem.eql(u8, f[0], name)) continue;
            const tpl = try t.arena.create(Template);
            tpl.* = try parse(t.arena, f[0], f[1], diag);
            try t.parsed.put(t.arena, name, tpl);
            return tpl;
        }
        return error.TemplateNotFound;
    }
};

fn testRoot() Object {
    const S = struct {
        const posts = [_]Value{
            .{ .object = .{ .entries = &.{ .{ .key = "title", .value = .{ .string = "First" } }, .{ .key = "url", .value = .{ .string = "/a/" } } } } },
            .{ .object = .{ .entries = &.{ .{ .key = "title", .value = .{ .string = "Second & more" } }, .{ .key = "url", .value = .{ .string = "/b/" } } } } },
        };
        const page = [_]Entry{
            .{ .key = "title", .value = .{ .string = "<Hello>" } },
            .{ .key = "date", .value = .{ .string = "2024-01-05" } },
            .{ .key = "draft", .value = .{ .boolean = false } },
            .{ .key = "count", .value = .{ .int = 3 } },
            .{ .key = "ratio", .value = .{ .float = 1.5 } },
            .{ .key = "tags", .value = .{ .list = &.{ .{ .string = "zig" }, .{ .string = "web" } } } },
        };
        const root = [_]Entry{
            .{ .key = "page", .value = .{ .object = .{ .entries = &page } } },
            .{ .key = "content", .value = .{ .html = "<p>Body</p>" } },
            .{ .key = "posts", .value = .{ .list = &posts } },
            .{ .key = "empty", .value = .{ .list = &.{} } },
        };
    };
    return .{ .entries = &S.root };
}

fn expectRender(expected: []const u8, src: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const tpl = parse(arena.allocator(), "test.html", src, &diag) catch |err| {
        std.debug.print("{s}:{d}: {s}\n", .{ diag.template, diag.line, diag.message });
        return err;
    };
    var tl: TestLoader = .{ .arena = arena.allocator(), .files = &.{
        .{ "nav.html", "<nav>{{ page.title }}</nav>" },
        .{ "item.html", "<li>{{ post.title }}</li>" },
    } };
    const out = renderAlloc(arena.allocator(), &tpl, testRoot(), tl.loader(), &diag) catch |err| {
        std.debug.print("{s}:{d}: {s}\n", .{ diag.template, diag.line, diag.message });
        return err;
    };
    try testing.expectEqualStrings(expected, out);
}

fn expectParseError(src: []const u8, line: usize, part: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(error.TemplateSyntax, parse(arena.allocator(), "bad.html", src, &diag));
    try testing.expectEqualStrings("bad.html", diag.template);
    testing.expectEqual(line, diag.line) catch |err| {
        std.debug.print("message: {s}\n", .{diag.message});
        return err;
    };
    if (std.mem.indexOf(u8, diag.message, part) == null) {
        std.debug.print("expected '{s}' in '{s}'\n", .{ part, diag.message });
        return error.TestUnexpectedResult;
    }
}

fn expectRenderError(src: []const u8, template: []const u8, line: usize, part: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const tpl = try parse(arena.allocator(), "main.html", src, &diag);
    var tl: TestLoader = .{ .arena = arena.allocator(), .files = &.{
        .{ "self.html", "x{% include \"self.html\" %}" },
        .{ "broken.html", "\n{{ page.tags }}" },
    } };
    try testing.expectError(error.TemplateRender, renderAlloc(arena.allocator(), &tpl, testRoot(), tl.loader(), &diag));
    try testing.expectEqualStrings(template, diag.template);
    try testing.expectEqual(line, diag.line);
    if (std.mem.indexOf(u8, diag.message, part) == null) {
        std.debug.print("expected '{s}' in '{s}'\n", .{ part, diag.message });
        return error.TestUnexpectedResult;
    }
}

test "output and escaping" {
    try expectRender("<h1>&lt;Hello&gt;</h1>", "<h1>{{ page.title }}</h1>");
    try expectRender("<p>Body</p>", "{{ content }}");
    try expectRender("<Hello>", "{{ page.title | raw }}");
    try expectRender("3 1.5 false", "{{ page.count }} {{ page.ratio }} {{ page.draft }}");
    try expectRender("[]", "[{{ missing }}{{ page.missing.deeper }}]");
    try expectRender("a { b } c", "a { b } c");
    try expectRender("lit", "{{ \"lit\" }}");
}

test "filters" {
    try expectRender("&lt;HELLO&gt;", "{{ page.title | upper }}");
    try expectRender("&lt;hello&gt;", "{{ page.title | lower }}");
    try expectRender("Untitled", "{{ missing | default(\"Untitled\") }}");
    try expectRender("&lt;Hello&gt;", "{{ page.title | default(\"x\") }}");
    try expectRender("January 5, 2024", "{{ page.date | date }}");
    try expectRender("<HELLO>", "{{ page.title | upper | raw }}");
}

test "conditionals" {
    try expectRender("yes", "{% if page.title %}yes{% endif %}");
    try expectRender("no", "{% if page.draft %}yes{% else %}no{% endif %}");
    try expectRender("b", "{% if missing %}a{% elif page.count == 3 %}b{% else %}c{% endif %}");
    try expectRender("ok", "{% if not page.draft and page.count != 4 %}ok{% endif %}");
    try expectRender("ok", "{% if missing or page.title == \"<Hello>\" %}ok{% endif %}");
    try expectRender("", "{% if empty %}x{% endif %}");
}

test "loops" {
    try expectRender("1:First,2:Second &amp; more.", "{% for p in posts %}{{ loop.index }}:{{ p.title }}{% if not loop.last %},{% endif %}{% endfor %}.");
    try expectRender("", "{% for p in empty %}x{% endfor %}");
    try expectRender("", "{% for p in missing %}x{% endfor %}");
    try expectRender("zig web ", "{% for t in page.tags %}{{ t }} {% endfor %}");
}

test "includes share scope" {
    try expectRender("<nav>&lt;Hello&gt;</nav>", "{% include \"nav.html\" %}");
    try expectRender("<ul><li>First</li><li>Second &amp; more</li></ul>", "<ul>{% for post in posts %}{% include \"item.html\" %}{% endfor %}</ul>");
}

test "whitespace control and comments" {
    try expectRender("<ul>\n  <li>zig</li>\n  <li>web</li>\n</ul>",
        \\<ul>
        \\  {%- for t in page.tags %}
        \\  <li>{{ t }}</li>
        \\  {%- endfor %}
        \\</ul>
    );
    try expectRender("a|b", "a  {{- \"|\" -}}  \n b");
    try expectRender("ab", "a{# a comment with }} inside #}b");
}

test "templates record whether they read site collections" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const a = try parse(arena.allocator(), "a", "{% for p in site.posts %}{{ p.title }}{% endfor %}", &diag);
    try testing.expect(a.reads_collections);
    const b = try parse(arena.allocator(), "b", "{% if site.pages %}x{% endif %}", &diag);
    try testing.expect(b.reads_collections);
    const c = try parse(arena.allocator(), "c", "{{ site.title }} {{ page.posts }}", &diag);
    try testing.expect(!c.reads_collections);
}

test "includes are recorded for dependency tracking" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const tpl = try parse(arena.allocator(), "t", "{% include \"a.html\" %}{% if x %}{% include 'b.html' %}{% endif %}", &diag);
    try testing.expectEqual(@as(usize, 2), tpl.includes.len);
    try testing.expectEqualStrings("b.html", tpl.includes[1]);
}

test "syntax errors" {
    try expectParseError("a\n{{ page.title", 2, "unclosed");
    try expectParseError("{% if x %}\nno end", 1, "'if' is not closed");
    try expectParseError("{% for x in y %}", 1, "'for' is not closed");
    try expectParseError("\n\n{% endif %}", 3, "unexpected 'endif'");
    try expectParseError("{% if x %}{% else %}{% elif y %}{% endif %}", 1, "after 'else'");
    try expectParseError("{% if x %}{% endfor %}", 1, "inside 'if'");
    try expectParseError("{{ x | shout }}", 1, "unknown filter 'shout'");
    try expectParseError("{{ x | default }}", 1, "needs an argument");
    try expectParseError("{{ x | upper(1) }}", 1, "takes no argument");
    try expectParseError("{% render x %}", 1, "unknown statement");
    try expectParseError("{% include nav %}", 1, "quoted template name");
    try expectParseError("{% for in y %}", 1, "expected 'in'");
    try expectParseError("{% if x = 1 %}{% endif %}", 1, "did you mean '=='");
    try expectParseError("{{ }}", 1, "empty output tag");
    try expectParseError("{{ \"open }}", 1, "unclosed");
}

test "render errors name the template and line" {
    try expectRenderError("\n{{ posts }}", "main.html", 2, "cannot output a list");
    try expectRenderError("{% for x in page.title %}{% endfor %}", "main.html", 1, "cannot loop over a string");
    try expectRenderError("{% include \"missing.html\" %}", "main.html", 1, "was not found");
    try expectRenderError("{% include \"self.html\" %}", "self.html", 1, "nested more than");
    try expectRenderError("{% include \"broken.html\" %}", "broken.html", 2, "cannot output a list");
    try expectRenderError("{{ page.count | upper }}", "main.html", 1, "expects a string");
    try expectRenderError("{{ page.title | date }}", "main.html", 1, "expects YYYY-MM-DD");
}

test "parseDate" {
    try testing.expectEqual(Date{ .year = 2024, .month = 2, .day = 29 }, parseDate("2024-02-29").?);
    try testing.expect(parseDate("2023-02-29") == null);
    try testing.expect(parseDate("2024-13-01") == null);
    try testing.expect(parseDate("2024-01-05T10:00:00Z") != null);
    try testing.expect(parseDate("2024-01-05x") == null);
    try testing.expect(parseDate("Jan 5") == null);
}
