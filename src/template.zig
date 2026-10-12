//! The Mortise template engine. Syntax is specified in docs/templates.md,
//! and the Liquid dialect in docs/liquid.md.
//!
//!   {{ page.title }}                 output, HTML-escaped by default
//!   {{ content }}                    values marked as HTML are not escaped
//!   {{ page.title | upper }}         filters (built-ins only)
//!   {% if a and not b %}...{% elif c == "x" %}...{% else %}...{% endif %}
//!   {% for post in site.posts | limit(5) %}...{{ loop.index }}...{% endfor %}
//!   {% include "card.html" title=page.title %}
//!   {% extends "base.html" %}{% block main %}...{{ super }}...{% endblock %}
//!   {# comment #}
//!   {%- ... -%}                      `-` trims whitespace on that side
//!
//! The engine also reads Liquid as Shopify and Jekyll write it: `elsif`,
//! `unless`, `case`, `assign`, `capture`, `{% raw %}`, `| filter: arg`,
//! `forloop`, `{% include file.html key=value %}` and the rest. With the
//! `liquid` option it also behaves as Liquid where the two differ: output
//! is not escaped, only `nil` and `false` are false, `and` and `or` group
//! from the right, and filters follow Liquid's and Jekyll's definitions.
//!
//! Templates are parsed once into a node tree and rendered many times.
//! Syntax errors and render errors both carry the template name and line.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const markdown = @import("markdown.zig");
const highlight = @import("highlight.zig");
const filters = @import("filters.zig");
const escapeHtml = markdown.escapeHtml;

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

    /// Mortise's truth: missing, `false`, 0, empty strings and empty lists
    /// are false.
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

    /// Liquid's truth: only `nil` and `false` are false.
    pub fn liquidTruthy(v: Value) bool {
        return switch (v) {
            .nil => false,
            .boolean => |b| b,
            else => true,
        };
    }

    pub fn typeName(v: Value) []const u8 {
        return switch (v) {
            .nil => "nothing",
            .boolean => "a boolean",
            .int, .float => "a number",
            .string, .html => "a string",
            .list => "a list",
            .object => "an object",
        };
    }

    pub fn eql(a: Value, b: Value) bool {
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
            .list => |x| b == .list and b.list.len == x.len and for (x, b.list) |p, q| {
                if (!p.eql(q)) break false;
            } else true,
            .object => |x| b == .object and b.object.entries.len == x.entries.len and for (x.entries) |e| {
                const other = b.object.get(e.key) orelse break false;
                if (!e.value.eql(other)) break false;
            } else true,
            .string, .html => false,
        };
    }

    pub fn text(v: Value) ?[]const u8 {
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

pub const Expr = union(enum) {
    path: []const Seg,
    string: []const u8,
    int: i64,
    float: f64,
    boolean: bool,
    nil,
    /// Liquid's `empty`: equal to an empty string, list or object.
    empty,
    /// Liquid's `blank`: also equal to `nil`, `false` and white space.
    blank,
    /// `(from..to)`: the whole numbers from `from` to `to`.
    range: *const [2]Expr,
};

/// One step of a variable path: `.name` or `[expression]`.
pub const Seg = union(enum) {
    name: []const u8,
    index: *const Expr,
};

pub const Filter = struct {
    kind: filters.Kind,
    args: []const Expr = &.{},
    /// `name: value` options, as in `default: "x", allow_false: true`.
    options: []const Option = &.{},
};

pub const Option = struct { name: []const u8, value: Expr };

pub const Op = enum { truthy, eq, ne, lt, gt, le, ge, contains };

const Comparison = struct {
    negate: bool = false,
    left: Expr,
    op: Op = .truthy,
    right: Expr = .nil,
};

/// Comparisons joined by `and` and `or`; `joins[i]` joins items `i` and
/// `i + 1`.
pub const Condition = struct {
    items: []const Comparison,
    joins: []const Join,
    line: usize,
};

const Join = enum { @"and", @"or" };

/// An output tag, or the value of `assign`.
pub const Output = struct { expr: Expr, filters: []const Filter, line: usize };

const Node = union(enum) {
    text: []const u8,
    output: Output,
    @"if": struct { branches: []const Branch, line: usize },
    case: struct { subject: Expr, whens: []const When, line: usize },
    @"for": *const For,
    tablerow: *const For,
    @"break",
    @"continue",
    assign: struct { name: []const u8, value: Output },
    capture: struct { name: []const u8, body: []const Node },
    /// `increment` and `decrement`.
    counter: struct { name: []const u8, decrement: bool },
    cycle: struct { group: ?Expr, key: []const u8, values: []const Expr, line: usize },
    include: *const Include,
    /// `{% block NAME %}...{% endblock %}`: content a child template can
    /// replace.
    block: struct { name: []const u8, body: []const Node, line: usize },
    /// `{{ super }}` inside a block: the block's content one template up.
    super: usize,
    /// Jekyll's `{% highlight LANG [linenos] %}`.
    highlight: struct { lang: []const u8, linenos: bool, body: []const Node },
    /// Jekyll's `{% link PATH %}` and `{% post_url NAME %}`.
    link: struct { kind: Links.Kind, target: Name, line: usize },
};

const Branch = struct {
    /// Null for `else`.
    cond: ?Condition,
    /// The first branch of `unless`.
    negate: bool = false,
    body: []const Node,
};

const When = struct {
    /// Null for `else`.
    values: ?[]const Expr,
    body: []const Node,
};

const For = struct {
    name: []const u8,
    iter: Expr,
    filters: []const Filter = &.{},
    limit: ?Expr = null,
    offset: ?Expr = null,
    /// `offset: continue`: start where the last loop with this `key` ended.
    offset_continue: bool = false,
    reversed: bool = false,
    /// `tablerow` only: cells per row.
    cols: ?Expr = null,
    body: []const Node = &.{},
    else_body: []const Node = &.{},
    /// `NAME-COLLECTION`, as Liquid names loops.
    key: []const u8,
    line: usize,
};

/// A template name, written out or built from variables, as in Jekyll's
/// `{% include {{ page.sidebar }} %}`.
pub const Name = union(enum) {
    static: []const u8,
    dynamic: *const Template,
};

const Include = struct {
    name: Name,
    kind: enum { include, render, relative },
    args: []const Arg = &.{},
    /// `with EXPR` or `for EXPR`, bound to `alias`.
    with: ?Expr = null,
    each: bool = false,
    alias: ?[]const u8 = null,
    line: usize,
};

/// `name=expression` (Mortise and Jekyll) or `name: expression` (Liquid)
/// after an include's name.
const Arg = struct { name: []const u8, expr: Expr, jekyll: bool };

pub const BlockDef = struct { name: []const u8, body: []const Node };

pub const Template = struct {
    name: []const u8,
    nodes: []const Node,
    /// Names passed to `{% include %}` and `{% render %}`, for dependency
    /// tracking.
    includes: []const []const u8,
    /// Whether any expression reads `site.posts`, `site.pages`, or
    /// `site.tags`, whose contents change whenever any page or post does.
    reads_collections: bool,
    /// Whether any expression reads `seo`, the page's head tags.
    reads_seo: bool = false,
    /// The parent named by `{% extends %}`, or null.
    extends: ?[]const u8 = null,
    extends_line: usize = 0,
    /// Every block in the template, at any depth.
    blocks: []const BlockDef = &.{},

    fn findBlock(t: *const Template, name: []const u8) ?[]const Node {
        for (t.blocks) |b| if (std.mem.eql(u8, b.name, name)) return b.body;
        return null;
    }
};

pub const Diagnostic = struct {
    /// Template name (as given to `parse`) where the error occurred.
    template: []const u8 = "",
    line: usize = 0,
    message: []const u8 = "",
};

pub const ParseError = error{TemplateSyntax} || Allocator.Error;

pub const ParseOptions = struct {
    /// Read the template as Liquid: `{#` is plain text, and strings have no
    /// backslash escapes.
    liquid: bool = false,
    /// Collection labels (Liquid mode): reading `site.LABEL` depends on
    /// other pages, as `site.posts` does.
    collections: []const []const u8 = &.{},
};

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
    options: ParseOptions = .{},
    tokens: []const Token,
    pos: usize = 0,
    includes: std.ArrayList([]const u8) = .empty,
    reads_collections: bool = false,
    reads_seo: bool = false,
    extends: ?[]const u8 = null,
    extends_line: usize = 0,
    blocks: std.ArrayList(BlockDef) = .empty,
    /// How deep inside `if`, `for` and `block` the parser is; `extends`
    /// must be at the top.
    depth: usize = 0,
    /// Blocks open around the current position, for `{{ super }}`.
    block_depth: usize = 0,

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
    return parseWith(arena, name, src, .{}, diag);
}

/// `parse` with options.
pub fn parseWith(arena: Allocator, name: []const u8, src: []const u8, options: ParseOptions, diag: *Diagnostic) ParseError!Template {
    var p: Parser = .{ .arena = arena, .name = name, .diag = diag, .options = options, .tokens = &.{} };
    p.tokens = try tokenize(&p, src);
    var end: ?Stmt = null;
    const nodes = try parseNodes(&p, &end);
    if (end) |e| return p.fail(e.line, "unexpected '{s}'", .{e.keyword});
    return .{
        .name = name,
        .nodes = nodes,
        .includes = p.includes.items,
        .reads_collections = p.reads_collections,
        .reads_seo = p.reads_seo,
        .extends = p.extends,
        .extends_line = p.extends_line,
        .blocks = p.blocks.items,
    };
}

fn tokenize(p: *Parser, src: []const u8) ParseError![]const Token {
    var tokens: std.ArrayList(Token) = .empty;
    var i: usize = 0;
    var line: usize = 1;
    var trim_next = false;
    while (i < src.len) {
        const start = findOpen(src, i, p.options.liquid) orelse {
            var text = src[i..];
            if (trim_next) text = std.mem.trimStart(u8, text, " \t\r\n");
            if (text.len > 0) try tokens.append(p.arena, .{ .text = text });
            break;
        };
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
        const close = findClose(src, body_start, close_seq, kind_char == '#', p.options.liquid) orelse
            return p.fail(line, "unclosed '{{{c}' tag; expected '{s}'", .{ kind_char, close_seq });
        var body_end = close;
        trim_next = close > body_start and src[close - 1] == '-';
        if (trim_next) body_end -= 1;
        const body = std.mem.trim(u8, src[body_start..body_end], " \t\r\n");
        const tag_line = line;
        line += std.mem.count(u8, src[start..close], "\n");
        i = close + 2;
        if (kind_char == '#') continue;

        const keyword = splitStmt(body, tag_line).keyword;
        if (kind_char == '%' and (std.mem.eql(u8, keyword, "raw") or std.mem.eql(u8, keyword, "comment"))) {
            // The text up to the matching end tag is not parsed: it is
            // written as it is (`raw`) or dropped (`comment`).
            const end = findEndTag(src, i, keyword) orelse
                return p.fail(tag_line, "'{s}' is not closed; add '{{% end{s} %}}'", .{ keyword, keyword });
            if (keyword[0] == 'r') {
                var raw = src[i..end.start];
                if (trim_next) raw = std.mem.trimStart(u8, raw, " \t\r\n");
                if (end.trim_before) raw = std.mem.trimEnd(u8, raw, " \t\r\n");
                if (raw.len > 0) try tokens.append(p.arena, .{ .text = raw });
            }
            line += std.mem.count(u8, src[i..end.end], "\n");
            i = end.end;
            trim_next = end.trim_after;
            continue;
        }
        try tokens.append(p.arena, .{ .tag = .{
            .kind = if (kind_char == '{') .output else .statement,
            .body = body,
            .line = tag_line,
        } });
    }
    return tokens.items;
}

/// The next `{{`, `{%`, or (outside Liquid) `{#` at or after `from`.
fn findOpen(src: []const u8, from: usize, liquid: bool) ?usize {
    var i = from;
    while (std.mem.indexOfScalarPos(u8, src, i, '{')) |o| {
        if (o + 1 < src.len) switch (src[o + 1]) {
            '{', '%' => return o,
            '#' => if (!liquid) return o,
            else => {},
        };
        i = o + 1;
    }
    return null;
}

/// Finds `close` after `from`, skipping over quoted strings in tags.
fn findClose(src: []const u8, from: usize, close: []const u8, is_comment: bool, liquid: bool) ?usize {
    var i = from;
    var quote: u8 = 0;
    while (i + 1 < src.len) : (i += 1) {
        const c = src[i];
        if (!is_comment) {
            if (quote != 0) {
                if (c == '\\' and !liquid) {
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

const EndTag = struct { start: usize, end: usize, trim_before: bool, trim_after: bool };

/// Finds the `{% endKEYWORD %}` that closes a `raw` or `comment` opened
/// before `from`; comments nest.
fn findEndTag(src: []const u8, from: usize, keyword: []const u8) ?EndTag {
    var depth: usize = 0;
    var i = from;
    while (std.mem.indexOfPos(u8, src, i, "{%")) |o| {
        const trim_before = o + 2 < src.len and src[o + 2] == '-';
        const body_start = o + 2 + @intFromBool(trim_before);
        const close = std.mem.indexOfPos(u8, src, body_start, "%}") orelse return null;
        const trim_after = close > body_start and src[close - 1] == '-';
        const body = std.mem.trim(u8, src[body_start .. close - @intFromBool(trim_after)], " \t\r\n");
        const k = splitStmt(body, 0).keyword;
        if (std.mem.eql(u8, keyword, "comment") and std.mem.eql(u8, k, "comment")) {
            depth += 1;
        } else if (std.mem.startsWith(u8, k, "end") and std.mem.eql(u8, k[3..], keyword)) {
            if (depth == 0) return .{ .start = o, .end = close + 2, .trim_before = trim_before, .trim_after = trim_after };
            depth -= 1;
        }
        i = close + 2;
    }
    return null;
}

const Stmt = struct {
    keyword: []const u8,
    rest: []const u8,
    line: usize,
    /// Newlines between the keyword and `rest`.
    rest_line_offset: usize = 0,
};

fn splitStmt(body: []const u8, line: usize) Stmt {
    const sp = std.mem.indexOfAny(u8, body, " \t\r\n") orelse body.len;
    const after = body[sp..];
    const rest = std.mem.trim(u8, after, " \t\r\n");
    const lead = if (rest.len > 0) after[0 .. std.mem.indexOf(u8, after, rest) orelse 0] else "";
    return .{ .keyword = body[0..sp], .rest = rest, .line = line, .rest_line_offset = std.mem.count(u8, lead, "\n") };
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
                .output => if (try parseOutputTag(p, tag.body, tag.line)) |n| try nodes.append(p.arena, n),
                .statement => {
                    const st = splitStmt(tag.body, tag.line);
                    const k = st.keyword;
                    // `{% # a comment %}`
                    if (k.len > 0 and k[0] == '#') continue;
                    if (isBlockEnd(k)) {
                        end.* = st;
                        return nodes.items;
                    }
                    if (std.mem.eql(u8, k, "liquid")) {
                        try nodes.appendSlice(p.arena, try parseLiquidTag(p, st));
                    } else if (std.mem.eql(u8, k, "extends")) {
                        try parseExtends(p, st, nodes.items);
                    } else if (std.mem.eql(u8, k, "comment")) {
                        // Only inside `{% liquid %}`; elsewhere the
                        // tokenizer drops comments.
                        try skipComment(p, st);
                    } else {
                        try nodes.append(p.arena, try parseStatement(p, st));
                    }
                },
            },
        }
    }
    return nodes.items;
}

fn parseStatement(p: *Parser, st: Stmt) ParseError!Node {
    const k = st.keyword;
    const is = struct {
        fn f(a: []const u8, b: []const u8) bool {
            return std.mem.eql(u8, a, b);
        }
    }.f;
    if (is(k, "if")) return parseIf(p, st, false);
    if (is(k, "unless")) return parseIf(p, st, true);
    if (is(k, "case")) return parseCase(p, st);
    if (is(k, "for")) return parseFor(p, st, false);
    if (is(k, "tablerow")) return parseFor(p, st, true);
    if (is(k, "break") or is(k, "continue")) {
        if (st.rest.len != 0) return p.fail(st.line, "'{s}' takes no arguments", .{k});
        return if (is(k, "break")) .@"break" else .@"continue";
    }
    if (is(k, "assign")) return parseAssign(p, st);
    if (is(k, "capture")) return parseCapture(p, st);
    if (is(k, "increment") or is(k, "decrement")) {
        if (st.rest.len == 0 or !validName(st.rest)) return p.fail(st.line, "'{s}' needs a variable name", .{k});
        return .{ .counter = .{ .name = st.rest, .decrement = is(k, "decrement") } };
    }
    if (is(k, "cycle")) return parseCycle(p, st);
    if (is(k, "echo")) {
        if (st.rest.len == 0) return .{ .text = "" };
        return parseOutput(p, st.rest, st.line);
    }
    if (is(k, "include")) return parseInclude(p, st, .include);
    if (is(k, "render")) return parseInclude(p, st, .render);
    if (is(k, "include_relative")) return parseInclude(p, st, .relative);
    if (is(k, "block")) return parseBlock(p, st);
    if (is(k, "highlight")) return parseHighlight(p, st);
    if (is(k, "link")) return parseLink(p, st, .link);
    if (is(k, "post_url")) return parseLink(p, st, .post_url);
    if (is(k, "raw")) return p.fail(st.line, "'raw' cannot be used inside a 'liquid' tag", .{});
    return p.fail(st.line, "unknown statement '{s}'", .{k});
}

fn isBlockEnd(keyword: []const u8) bool {
    for ([_][]const u8{
        "elif",   "elsif",       "else",       "when",     "endif",        "endunless",  "endcase",
        "endfor", "endtablerow", "endcapture", "endblock", "endhighlight", "endcomment",
    }) |k| {
        if (std.mem.eql(u8, keyword, k)) return true;
    }
    return false;
}

fn parseIf(p: *Parser, first: Stmt, unless: bool) ParseError!Node {
    var branches: std.ArrayList(Branch) = .empty;
    var cond: ?Condition = try parseCondition(p, first.rest, first.line);
    var negate = unless;
    var seen_else = false;
    const end_keyword: []const u8 = if (unless) "endunless" else "endif";
    while (true) {
        var end: ?Stmt = null;
        p.depth += 1;
        const body = try parseNodes(p, &end);
        p.depth -= 1;
        try branches.append(p.arena, .{ .cond = cond, .negate = negate, .body = body });
        negate = false;
        const e = end orelse return p.fail(first.line, "'{s}' is not closed; add '{{% {s} %}}'", .{ first.keyword, end_keyword });
        if (std.mem.eql(u8, e.keyword, end_keyword)) {
            if (e.rest.len != 0) return p.fail(e.line, "'{s}' takes no arguments", .{end_keyword});
            break;
        }
        if (seen_else) return p.fail(e.line, "unexpected '{s}' after 'else'", .{e.keyword});
        if (std.mem.eql(u8, e.keyword, "elif") or std.mem.eql(u8, e.keyword, "elsif")) {
            cond = try parseCondition(p, e.rest, e.line);
        } else if (std.mem.eql(u8, e.keyword, "else")) {
            if (e.rest.len != 0) return p.fail(e.line, "'else' takes no arguments", .{});
            cond = null;
            seen_else = true;
        } else {
            return p.fail(e.line, "unexpected '{s}' inside '{s}'", .{ e.keyword, first.keyword });
        }
    }
    return .{ .@"if" = .{ .branches = branches.items, .line = first.line } };
}

fn parseCase(p: *Parser, st: Stmt) ParseError!Node {
    if (st.rest.len == 0) return p.fail(st.line, "'case' needs a value, as in {{% case page.layout %}}", .{});
    var lx: Lexer = .{ .p = p, .src = st.rest, .line = st.line };
    const subject = try parseExpr(&lx);
    if (try lx.next() != .end) return p.fail(st.line, "unexpected text after the 'case' value", .{});
    p.depth += 1;
    defer p.depth -= 1;
    var end: ?Stmt = null;
    // Text before the first `when` is never rendered.
    _ = try parseNodes(p, &end);
    var whens: std.ArrayList(When) = .empty;
    while (true) {
        const e = end orelse return p.fail(st.line, "'case' is not closed; add '{{% endcase %}}'", .{});
        if (std.mem.eql(u8, e.keyword, "endcase")) break;
        var values: ?[]const Expr = null;
        if (std.mem.eql(u8, e.keyword, "when")) {
            values = try parseWhenValues(p, e);
        } else if (!std.mem.eql(u8, e.keyword, "else")) {
            return p.fail(e.line, "unexpected '{s}' inside 'case'", .{e.keyword});
        }
        const body = try parseNodes(p, &end);
        try whens.append(p.arena, .{ .values = values, .body = body });
    }
    return .{ .case = .{ .subject = subject, .whens = whens.items, .line = st.line } };
}

fn parseWhenValues(p: *Parser, st: Stmt) ParseError![]const Expr {
    if (st.rest.len == 0) return p.fail(st.line, "'when' needs a value", .{});
    var lx: Lexer = .{ .p = p, .src = st.rest, .line = st.line };
    var values: std.ArrayList(Expr) = .empty;
    while (true) {
        try values.append(p.arena, try parseExpr(&lx));
        switch (try lx.next()) {
            .end => break,
            .comma => {},
            .ident => |w| if (!std.mem.eql(u8, w, "or")) return p.fail(st.line, "expected ',' or 'or' between 'when' values", .{}),
            else => return p.fail(st.line, "expected ',' or 'or' between 'when' values", .{}),
        }
    }
    return values.items;
}

fn parseFor(p: *Parser, st: Stmt, tablerow: bool) ParseError!Node {
    const kw = st.keyword;
    var lx: Lexer = .{ .p = p, .src = st.rest, .line = st.line };
    const name_tok = try lx.next();
    if (name_tok != .ident) return p.fail(st.line, "expected a loop variable name after '{s}'", .{kw});
    const name = name_tok.ident;
    for ([_][]const u8{ "loop", "forloop", "tablerowloop" }) |reserved| {
        if (std.mem.eql(u8, name, reserved)) return p.fail(st.line, "invalid loop variable name '{s}'", .{name});
    }
    const in_tok = try lx.next();
    if (in_tok != .ident or !std.mem.eql(u8, in_tok.ident, "in")) return p.fail(st.line, "expected 'in' after the loop variable", .{});
    lx.skipSpace();
    const iter_start = lx.i;
    const iter = try parseExpr(&lx);
    const key = try std.fmt.allocPrint(p.arena, "{s}-{s}", .{ name, std.mem.trim(u8, st.rest[iter_start..lx.i], " \t\r\n") });
    var f: For = .{ .name = name, .iter = iter, .key = key, .line = st.line };
    var filter_list: std.ArrayList(Filter) = .empty;
    while (true) {
        switch (try lx.next()) {
            .end => break,
            .comma => {},
            .pipe => {
                if (tablerow) return p.fail(st.line, "'tablerow' does not take filters", .{});
                try filter_list.append(p.arena, try parseFilter(p, &lx, st.line));
            },
            .ident => |w| {
                if (std.mem.eql(u8, w, "reversed") and !tablerow) {
                    f.reversed = true;
                    continue;
                }
                const is_param = std.mem.eql(u8, w, "limit") or std.mem.eql(u8, w, "offset") or (tablerow and std.mem.eql(u8, w, "cols"));
                if (!is_param) return p.fail(st.line, "unexpected '{s}' in '{s}'", .{ w, kw });
                if (try lx.next() != .colon) return p.fail(st.line, "expected ':' after '{s}'", .{w});
                if (std.mem.eql(u8, w, "offset") and lx.peekKeyword("continue")) {
                    _ = try lx.next();
                    f.offset_continue = true;
                    continue;
                }
                const e = try parseExpr(&lx);
                switch (w[0]) {
                    'l' => f.limit = e,
                    'o' => f.offset = e,
                    else => f.cols = e,
                }
            },
            else => return p.fail(st.line, "expected '|', a parameter, or the end of the loop expression", .{}),
        }
    }
    f.filters = filter_list.items;

    const close_keyword: []const u8 = if (tablerow) "endtablerow" else "endfor";
    p.depth += 1;
    defer p.depth -= 1;
    var end: ?Stmt = null;
    f.body = try parseNodes(p, &end);
    var e = end orelse return p.fail(st.line, "'{s}' is not closed; add '{{% {s} %}}'", .{ kw, close_keyword });
    if (!tablerow and std.mem.eql(u8, e.keyword, "else")) {
        if (e.rest.len != 0) return p.fail(e.line, "'else' takes no arguments", .{});
        f.else_body = try parseNodes(p, &end);
        e = end orelse return p.fail(st.line, "'{s}' is not closed; add '{{% {s} %}}'", .{ kw, close_keyword });
    }
    if (!std.mem.eql(u8, e.keyword, close_keyword)) return p.fail(e.line, "unexpected '{s}' inside '{s}'", .{ e.keyword, kw });
    if (e.rest.len != 0) return p.fail(e.line, "'{s}' takes no arguments", .{close_keyword});
    const ptr = try p.arena.create(For);
    ptr.* = f;
    return if (tablerow) .{ .tablerow = ptr } else .{ .@"for" = ptr };
}

fn parseAssign(p: *Parser, st: Stmt) ParseError!Node {
    var lx: Lexer = .{ .p = p, .src = st.rest, .line = st.line };
    const name = try lx.next();
    if (name != .ident) return p.fail(st.line, "expected a variable name after 'assign'", .{});
    if (try lx.next() != .assign) return p.fail(st.line, "expected '=' after '{s}'", .{name.ident});
    const expr = try parseExpr(&lx);
    const fs = try parseFilters(p, &lx, st.line, "the value");
    return .{ .assign = .{ .name = name.ident, .value = .{ .expr = expr, .filters = fs, .line = st.line } } };
}

fn parseCapture(p: *Parser, st: Stmt) ParseError!Node {
    var lx: Lexer = .{ .p = p, .src = st.rest, .line = st.line };
    const name: []const u8 = switch (try lx.next()) {
        .ident => |s| s,
        .string => |s| s,
        else => return p.fail(st.line, "expected a variable name after 'capture'", .{}),
    };
    if (try lx.next() != .end) return p.fail(st.line, "unexpected text after the 'capture' name", .{});
    p.depth += 1;
    defer p.depth -= 1;
    var end: ?Stmt = null;
    const body = try parseNodes(p, &end);
    const e = end orelse return p.fail(st.line, "'capture' is not closed; add '{{% endcapture %}}'", .{});
    if (!std.mem.eql(u8, e.keyword, "endcapture")) return p.fail(e.line, "unexpected '{s}' inside 'capture'", .{e.keyword});
    return .{ .capture = .{ .name = name, .body = body } };
}

fn parseCycle(p: *Parser, st: Stmt) ParseError!Node {
    if (st.rest.len == 0) return p.fail(st.line, "'cycle' needs values, as in {{% cycle \"odd\", \"even\" %}}", .{});
    var lx: Lexer = .{ .p = p, .src = st.rest, .line = st.line };
    var group: ?Expr = null;
    var first = try parseExpr(&lx);
    if (lx.peekByte() == ':') {
        _ = try lx.next();
        group = first;
        first = try parseExpr(&lx);
    }
    var values: std.ArrayList(Expr) = .empty;
    try values.append(p.arena, first);
    while (true) switch (try lx.next()) {
        .end => break,
        .comma => try values.append(p.arena, try parseExpr(&lx)),
        else => return p.fail(st.line, "expected ',' between 'cycle' values", .{}),
    };
    return .{ .cycle = .{ .group = group, .key = st.rest, .values = values.items, .line = st.line } };
}

fn parseInclude(p: *Parser, st: Stmt, kind: @FieldType(Include, "kind")) ParseError!Node {
    const rest = st.rest;
    if (rest.len == 0) return p.fail(st.line, "'{s}' needs a template name", .{st.keyword});
    var lx: Lexer = .{ .p = p, .src = rest, .line = st.line };
    var inc: Include = .{ .name = undefined, .kind = kind, .line = st.line };
    if (rest[0] == '"' or rest[0] == '\'') {
        inc.name = .{ .static = (try lx.next()).string };
    } else {
        // Jekyll: an unquoted path, which may hold `{{ variables }}`.
        const end_i = nameEnd(rest);
        inc.name = try parseName(p, rest[0..end_i], st.line);
        lx.i = end_i;
    }
    if (inc.name == .static and kind != .relative) try p.includes.append(p.arena, inc.name.static);
    if (lx.peekByte() == ',') _ = try lx.next();
    if (lx.peekWord("with") or lx.peekWord("for")) {
        inc.each = (try lx.next()).ident[0] == 'f';
        inc.with = try parseExpr(&lx);
        if (lx.peekWord("as")) {
            _ = try lx.next();
            const alias = try lx.next();
            if (alias != .ident) return p.fail(st.line, "expected a name after 'as'", .{});
            inc.alias = alias.ident;
        }
    }
    var args: std.ArrayList(Arg) = .empty;
    while (true) {
        var t = try lx.next();
        if (t == .comma) t = try lx.next();
        if (t == .end) break;
        if (t != .ident) return p.fail(st.line, "expected name=value arguments after the template name", .{});
        const jekyll = switch (try lx.next()) {
            .assign => true,
            .colon => false,
            else => return p.fail(st.line, "expected '=' or ':' after '{s}'", .{t.ident}),
        };
        try args.append(p.arena, .{ .name = t.ident, .expr = try parseExpr(&lx), .jekyll = jekyll });
    }
    inc.args = args.items;
    const ptr = try p.arena.create(Include);
    ptr.* = inc;
    return .{ .include = ptr };
}

/// The end of an unquoted template name: the first space or comma outside
/// `{{ ... }}`.
fn nameEnd(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len) {
        if (std.mem.startsWith(u8, s[i..], "{{")) {
            i = (std.mem.indexOfPos(u8, s, i + 2, "}}") orelse return s.len) + 2;
            continue;
        }
        if (std.ascii.isWhitespace(s[i]) or s[i] == ',') break;
        i += 1;
    }
    return i;
}

fn parseName(p: *Parser, text: []const u8, line: usize) ParseError!Name {
    if (std.mem.indexOf(u8, text, "{{") == null) return .{ .static = text };
    var sub: Parser = .{ .arena = p.arena, .name = p.name, .diag = p.diag, .options = p.options, .tokens = &.{} };
    const toks = try p.arena.dupe(Token, try tokenize(&sub, text));
    for (toks) |*t| switch (t.*) {
        .tag => |*tag| tag.line = line,
        .text => {},
    };
    sub.tokens = toks;
    var end: ?Stmt = null;
    const nodes = try parseNodes(&sub, &end);
    if (end != null) return p.fail(line, "only {{{{ variables }}}} may appear in a template name", .{});
    p.reads_collections = p.reads_collections or sub.reads_collections;
    const t = try p.arena.create(Template);
    t.* = .{ .name = p.name, .nodes = nodes, .includes = &.{}, .reads_collections = sub.reads_collections };
    return .{ .dynamic = t };
}

fn parseBlock(p: *Parser, st: Stmt) ParseError!Node {
    const name = st.rest;
    if (name.len == 0 or !validName(name)) return p.fail(st.line, "'block' needs a name, as in {{% block content %}}", .{});
    for (p.blocks.items) |b| {
        if (std.mem.eql(u8, b.name, name)) return p.fail(st.line, "block '{s}' is defined twice", .{name});
    }
    // Reserve the block's place, so parents list before their children.
    const index = p.blocks.items.len;
    try p.blocks.append(p.arena, .{ .name = name, .body = &.{} });
    var end: ?Stmt = null;
    p.depth += 1;
    p.block_depth += 1;
    const body = try parseNodes(p, &end);
    p.block_depth -= 1;
    p.depth -= 1;
    const e = end orelse return p.fail(st.line, "block '{s}' is not closed; add '{{% endblock %}}'", .{name});
    if (!std.mem.eql(u8, e.keyword, "endblock")) return p.fail(e.line, "unexpected '{s}' inside block '{s}'", .{ e.keyword, name });
    if (e.rest.len != 0 and !std.mem.eql(u8, e.rest, name)) return p.fail(e.line, "'endblock {s}' closes block '{s}'", .{ e.rest, name });
    p.blocks.items[index].body = body;
    return .{ .block = .{ .name = name, .body = body, .line = st.line } };
}

fn parseExtends(p: *Parser, st: Stmt, before: []const Node) ParseError!void {
    if (p.extends != null) return p.fail(st.line, "a template can extend only one parent", .{});
    const ok = p.depth == 0 and p.blocks.items.len == 0 and for (before) |n| {
        if (n != .text or std.mem.trim(u8, n.text, " \t\r\n").len != 0) break false;
    } else true;
    if (!ok) return p.fail(st.line, "'extends' must come first in a template", .{});
    var lx: Lexer = .{ .p = p, .src = st.rest, .line = st.line };
    const t = try lx.next();
    if (t != .string) return p.fail(st.line, "'extends' expects a quoted layout name, as in {{% extends \"base.html\" %}}", .{});
    if (try lx.next() != .end) return p.fail(st.line, "unexpected text after the layout name", .{});
    p.extends = t.string;
    p.extends_line = st.line;
}

fn parseHighlight(p: *Parser, st: Stmt) ParseError!Node {
    var it = std.mem.tokenizeAny(u8, st.rest, " \t\r\n");
    const lang = it.next() orelse return p.fail(st.line, "'highlight' needs a language, as in {{% highlight ruby %}}", .{});
    for (lang) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '+' or c == '#' or c == '-')) {
            return p.fail(st.line, "invalid language '{s}' for 'highlight'", .{lang});
        }
    }
    var linenos = false;
    while (it.next()) |opt| {
        if (std.mem.eql(u8, opt, "linenos") or std.mem.startsWith(u8, opt, "linenos=")) linenos = true;
    }
    p.depth += 1;
    defer p.depth -= 1;
    var end: ?Stmt = null;
    const body = try parseNodes(p, &end);
    const e = end orelse return p.fail(st.line, "'highlight' is not closed; add '{{% endhighlight %}}'", .{});
    if (!std.mem.eql(u8, e.keyword, "endhighlight")) return p.fail(e.line, "unexpected '{s}' inside 'highlight'", .{e.keyword});
    return .{ .highlight = .{ .lang = lang, .linenos = linenos, .body = body } };
}

fn parseLink(p: *Parser, st: Stmt, kind: Links.Kind) ParseError!Node {
    if (st.rest.len == 0) return p.fail(st.line, "'{s}' needs a {s}", .{ st.keyword, if (kind == .link) "file path" else "post name" });
    // The URL depends on other pages.
    p.reads_collections = true;
    return .{ .link = .{ .kind = kind, .target = try parseName(p, st.rest, st.line), .line = st.line } };
}

/// `{% liquid %}`: one statement per line, without delimiters.
fn parseLiquidTag(p: *Parser, st: Stmt) ParseError![]const Node {
    var sub: std.ArrayList(Token) = .empty;
    var it = std.mem.splitScalar(u8, st.rest, '\n');
    var n: usize = 0;
    while (it.next()) |raw| : (n += 1) {
        const l = std.mem.trim(u8, raw, " \t\r");
        if (l.len == 0) continue;
        try sub.append(p.arena, .{ .tag = .{ .kind = .statement, .body = l, .line = st.line + st.rest_line_offset + n } });
    }
    const saved_tokens = p.tokens;
    const saved_pos = p.pos;
    p.tokens = sub.items;
    p.pos = 0;
    defer {
        p.tokens = saved_tokens;
        p.pos = saved_pos;
    }
    var end: ?Stmt = null;
    const nodes = try parseNodes(p, &end);
    if (end) |e| return p.fail(e.line, "unexpected '{s}'", .{e.keyword});
    return nodes;
}

/// Skips tokens up to the `endcomment` matching `st`.
fn skipComment(p: *Parser, st: Stmt) ParseError!void {
    var depth: usize = 0;
    while (p.pos < p.tokens.len) {
        const tok = p.tokens[p.pos];
        p.pos += 1;
        if (tok != .tag or tok.tag.kind != .statement) continue;
        const k = splitStmt(tok.tag.body, 0).keyword;
        if (std.mem.eql(u8, k, "comment")) {
            depth += 1;
        } else if (std.mem.eql(u8, k, "endcomment")) {
            if (depth == 0) return;
            depth -= 1;
        }
    }
    return p.fail(st.line, "'comment' is not closed; add 'endcomment'", .{});
}

fn validName(s: []const u8) bool {
    for (s) |c| if (!isIdentChar(c)) return false;
    return true;
}

fn parseOutputTag(p: *Parser, body: []const u8, line: usize) ParseError!?Node {
    if (body.len == 0) {
        if (p.options.liquid) return null;
        return p.fail(line, "empty output tag", .{});
    }
    if (std.mem.eql(u8, body, "super")) {
        if (p.block_depth == 0) return p.fail(line, "'super' works only inside a block", .{});
        return .{ .super = line };
    }
    return try parseOutput(p, body, line);
}

fn parseOutput(p: *Parser, src: []const u8, line: usize) ParseError!Node {
    var lx: Lexer = .{ .p = p, .src = src, .line = line };
    const expr = try parseExpr(&lx);
    const fs = try parseFilters(p, &lx, line, "the tag");
    return .{ .output = .{ .expr = expr, .filters = fs, .line = line } };
}

/// Parses `| filter` clauses up to the end of `lx`.
fn parseFilters(p: *Parser, lx: *Lexer, line: usize, what: []const u8) ParseError![]const Filter {
    var list: std.ArrayList(Filter) = .empty;
    while (true) {
        switch (try lx.next()) {
            .end => break,
            .pipe => try list.append(p.arena, try parseFilter(p, lx, line)),
            else => return p.fail(line, "expected '|' or the end of {s}", .{what}),
        }
    }
    return list.items;
}

/// Parses one filter after its `|`: `name`, `name(args)`, or
/// `name: args, option: value`.
fn parseFilter(p: *Parser, lx: *Lexer, line: usize) ParseError!Filter {
    const name_tok = try lx.next();
    if (name_tok != .ident) return p.fail(line, "expected a filter name after '|'", .{});
    const name = name_tok.ident;
    const kind = std.meta.stringToEnum(filters.Kind, name) orelse {
        if (closestFilter(name)) |guess| {
            return p.fail(line, "unknown filter '{s}'; did you mean '{s}'? docs/templates.md lists the built-in filters", .{ name, guess });
        }
        return p.fail(line, "unknown filter '{s}'; docs/templates.md lists the built-in filters", .{name});
    };
    var args: std.ArrayList(Expr) = .empty;
    var options: std.ArrayList(Option) = .empty;
    if (lx.peekByte() == '(') {
        _ = try lx.next();
        if (lx.peekByte() == ')') {
            _ = try lx.next();
        } else while (true) {
            try args.append(p.arena, try parseExpr(lx));
            switch (try lx.next()) {
                .comma => continue,
                .rparen => break,
                else => return p.fail(line, "expected ',' or ')' after a filter argument", .{}),
            }
        }
    } else if (lx.peekByte() == ':') {
        _ = try lx.next();
        while (true) {
            if (try lx.optionName()) |opt| {
                if (!filters.hasOption(kind, opt)) return p.fail(line, "filter '{s}' has no option '{s}'", .{ name, opt });
                try options.append(p.arena, .{ .name = opt, .value = try parseExpr(lx) });
            } else {
                try args.append(p.arena, try parseExpr(lx));
            }
            if (lx.peekByte() != ',') break;
            _ = try lx.next();
        }
    }
    const min, const max = filters.arity(kind);
    if (args.items.len < min) {
        if (min == 1 and max == 1) return p.fail(line, "filter '{s}' needs an argument, as in {s}(\"x\") or {s}: \"x\"", .{ name, name, name });
        return p.fail(line, "filter '{s}' needs {s}", .{ name, if (min == 1) "an argument" else "two arguments" });
    }
    if (args.items.len > max) {
        if (max == 0) return p.fail(line, "filter '{s}' takes no argument", .{name});
        return p.fail(line, "filter '{s}' takes at most {d} argument{s}", .{ name, max, if (max == 1) "" else "s" });
    }
    if (kind == .where_exp or kind == .find_exp or kind == .group_by_exp) p.reads_collections = true;
    return .{ .kind = kind, .args = args.items, .options = options.items };
}

/// The built-in filter closest to a misspelled `name`, if any is close.
fn closestFilter(name: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_d: usize = 3;
    for (std.meta.fieldNames(filters.Kind)) |candidate| {
        const d = editDistance(name, candidate);
        if (d < best_d) {
            best_d = d;
            best = candidate;
        }
    }
    return best;
}

fn editDistance(a: []const u8, b: []const u8) usize {
    if (a.len > 32 or b.len > 32) return std.math.maxInt(usize);
    var row: [33]usize = undefined;
    for (0..b.len + 1) |j| row[j] = j;
    for (a, 1..) |ca, i| {
        var diag = row[0];
        row[0] = i;
        for (b, 1..) |cb, j| {
            const up = row[j];
            row[j] = @min(@min(row[j] + 1, row[j - 1] + 1), diag + @intFromBool(ca != cb));
            diag = up;
        }
    }
    return row[b.len];
}

fn parseCondition(p: *Parser, src: []const u8, line: usize) ParseError!Condition {
    if (src.len == 0) return p.fail(line, "missing condition", .{});
    var lx: Lexer = .{ .p = p, .src = src, .line = line };
    var items: std.ArrayList(Comparison) = .empty;
    var joins: std.ArrayList(Join) = .empty;
    while (true) {
        var cmp: Comparison = .{ .left = undefined };
        if (lx.peekKeyword("not")) {
            _ = try lx.next();
            cmp.negate = true;
        }
        cmp.left = try parseExpr(&lx);
        var t = try lx.next();
        const op: ?Op = switch (t) {
            .eq => .eq,
            .ne => .ne,
            .lt => .lt,
            .gt => .gt,
            .le => .le,
            .ge => .ge,
            .ident => |w| if (std.mem.eql(u8, w, "contains")) .contains else null,
            else => null,
        };
        if (op) |o| {
            cmp.op = o;
            cmp.right = try parseExpr(&lx);
            t = try lx.next();
        }
        try items.append(p.arena, cmp);
        switch (t) {
            .end => break,
            .ident => |w| {
                if (std.mem.eql(u8, w, "and")) {
                    try joins.append(p.arena, .@"and");
                } else if (std.mem.eql(u8, w, "or")) {
                    try joins.append(p.arena, .@"or");
                } else return p.fail(line, "unexpected '{s}' in condition", .{w});
            },
            .assign => return p.fail(line, "unexpected '='; did you mean '=='?", .{}),
            else => return p.fail(line, "unexpected token in condition", .{}),
        }
    }
    return .{ .items = items.items, .joins = joins.items, .line = line };
}

fn parseExpr(lx: *Lexer) ParseError!Expr {
    const t = try lx.next();
    return switch (t) {
        .ident => |id| blk: {
            if (!lx.atPathStep()) {
                if (std.mem.eql(u8, id, "true")) break :blk .{ .boolean = true };
                if (std.mem.eql(u8, id, "false")) break :blk .{ .boolean = false };
                if (std.mem.eql(u8, id, "nil") or std.mem.eql(u8, id, "null")) break :blk .nil;
                if (std.mem.eql(u8, id, "empty")) break :blk .empty;
                if (std.mem.eql(u8, id, "blank")) break :blk .blank;
            }
            break :blk parsePath(lx, .{ .name = id });
        },
        .lbracket => blk: {
            const e = try lx.p.arena.create(Expr);
            e.* = try parseExpr(lx);
            if (try lx.next() != .rbracket) return lx.p.fail(lx.line, "expected ']'", .{});
            break :blk parsePath(lx, .{ .index = e });
        },
        .lparen => blk: {
            const r = try lx.p.arena.create([2]Expr);
            r[0] = try parseExpr(lx);
            if (try lx.next() != .dotdot) return lx.p.fail(lx.line, "expected '..' in a range, as in (1..5)", .{});
            r[1] = try parseExpr(lx);
            if (try lx.next() != .rparen) return lx.p.fail(lx.line, "expected ')' after a range", .{});
            break :blk .{ .range = r };
        },
        .string => |s| .{ .string = s },
        .int => |n| .{ .int = n },
        .float => |x| .{ .float = x },
        .end => lx.p.fail(lx.line, "expected an expression", .{}),
        else => lx.p.fail(lx.line, "expected a variable, string, or number", .{}),
    };
}

fn parsePath(lx: *Lexer, first: Seg) ParseError!Expr {
    var segs: std.ArrayList(Seg) = .empty;
    try segs.append(lx.p.arena, first);
    while (lx.atPathStep()) {
        if (lx.src[lx.i] == '.') {
            lx.i += 1;
            const t = try lx.next();
            if (t != .ident) return lx.p.fail(lx.line, "expected a field name after '.'", .{});
            try segs.append(lx.p.arena, .{ .name = t.ident });
        } else {
            lx.i += 1;
            const e = try lx.p.arena.create(Expr);
            e.* = try parseExpr(lx);
            if (try lx.next() != .rbracket) return lx.p.fail(lx.line, "expected ']'", .{});
            try segs.append(lx.p.arena, .{ .index = e });
        }
    }
    noteCollections(lx.p, segs.items);
    return .{ .path = segs.items };
}

/// Records whether `path` reads data that changes whenever any page does.
fn noteCollections(p: *Parser, path: []const Seg) void {
    const first = switch (path[0]) {
        .name => |n| n,
        .index => {
            p.reads_collections = true;
            return;
        },
    };
    // The head tags hold breadcrumbs, which depend on other pages.
    if (std.mem.eql(u8, first, "seo")) {
        p.reads_seo = true;
        p.reads_collections = true;
        return;
    }
    const is_site = std.mem.eql(u8, first, "site");
    const is_page = std.mem.eql(u8, first, "page");
    if (!is_site and !is_page) return;
    if (path.len == 1) {
        // The whole object, as in `{% assign s = site %}`.
        if (is_site) p.reads_collections = true;
        return;
    }
    const second = switch (path[1]) {
        .name => |n| n,
        .index => {
            p.reads_collections = true;
            return;
        },
    };
    const site_keys = [_][]const u8{ "posts", "pages", "tags", "nav", "apis", "taxonomies", "menus", "collections", "categories", "static_files" };
    if (is_site) for (p.options.collections) |c| {
        if (std.mem.eql(u8, second, c)) p.reads_collections = true;
    };
    // Navigation fields depend on other pages' titles and URLs.
    const page_keys = [_][]const u8{ "breadcrumbs", "previous", "next", "related", "menus", "backlinks", "translations", "versions", "version_nav", "latest_url" };
    const keys: []const []const u8 = if (is_site) &site_keys else &page_keys;
    for (keys) |k| {
        if (std.mem.eql(u8, second, k)) p.reads_collections = true;
    }
}

const Tok = union(enum) {
    end,
    ident: []const u8,
    string: []const u8,
    int: i64,
    float: f64,
    pipe,
    lparen,
    rparen,
    lbracket,
    rbracket,
    comma,
    colon,
    dotdot,
    /// A single `=`, in `assign` and include arguments.
    assign,
    eq,
    ne,
    lt,
    gt,
    le,
    ge,
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

    /// `kw` as a keyword rather than an argument name (`with=1`).
    fn peekWord(lx: *Lexer, kw: []const u8) bool {
        if (!lx.peekKeyword(kw)) return false;
        const after = std.mem.trimStart(u8, lx.src[lx.i + kw.len ..], " \t\r\n");
        return after.len == 0 or (after[0] != '=' and after[0] != ':');
    }

    /// Whether a `.field` or `[index]` follows directly.
    fn atPathStep(lx: *Lexer) bool {
        if (lx.i >= lx.src.len) return false;
        const c = lx.src[lx.i];
        if (c == '[') return true;
        return c == '.' and !(lx.i + 1 < lx.src.len and lx.src[lx.i + 1] == '.');
    }

    /// Consumes `name:` and returns the name when a filter option follows.
    fn optionName(lx: *Lexer) ParseError!?[]const u8 {
        lx.skipSpace();
        const start = lx.i;
        if (start >= lx.src.len or !(std.ascii.isAlphabetic(lx.src[start]) or lx.src[start] == '_')) return null;
        var j = start;
        while (j < lx.src.len and isIdentChar(lx.src[j])) j += 1;
        var k = j;
        while (k < lx.src.len and (lx.src[k] == ' ' or lx.src[k] == '\t')) k += 1;
        if (k >= lx.src.len or lx.src[k] != ':') return null;
        lx.i = k + 1;
        return lx.src[start..j];
    }

    fn next(lx: *Lexer) ParseError!Tok {
        lx.skipSpace();
        if (lx.i >= lx.src.len) return .end;
        const s = lx.src;
        const c = s[lx.i];
        const c2: u8 = if (lx.i + 1 < s.len) s[lx.i + 1] else 0;
        switch (c) {
            '|', '(', ')', '[', ']', ',', ':' => {
                lx.i += 1;
                return switch (c) {
                    '|' => .pipe,
                    '(' => .lparen,
                    ')' => .rparen,
                    '[' => .lbracket,
                    ']' => .rbracket,
                    ',' => .comma,
                    else => .colon,
                };
            },
            '.' => {
                if (c2 == '.') {
                    lx.i += 2;
                    return .dotdot;
                }
                return lx.p.fail(lx.line, "unexpected '.'", .{});
            },
            '=' => {
                if (c2 == '=') {
                    lx.i += 2;
                    return .eq;
                }
                lx.i += 1;
                return .assign;
            },
            '!' => {
                if (c2 == '=') {
                    lx.i += 2;
                    return .ne;
                }
                return lx.p.fail(lx.line, "unexpected '!'; did you mean '!='?", .{});
            },
            '<', '>' => {
                if (c2 == '=') {
                    lx.i += 2;
                    return if (c == '<') .le else .ge;
                }
                if (c == '<' and c2 == '>') {
                    lx.i += 2;
                    return .ne;
                }
                lx.i += 1;
                return if (c == '<') .lt else .gt;
            },
            '"', '\'' => {
                lx.i += 1;
                var out: std.ArrayList(u8) = .empty;
                while (lx.i < s.len and s[lx.i] != c) : (lx.i += 1) {
                    if (s[lx.i] == '\\' and lx.i + 1 < s.len and !lx.p.options.liquid) lx.i += 1;
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
                if (lx.i + 1 < s.len and s[lx.i] == '.' and std.ascii.isDigit(s[lx.i + 1])) {
                    lx.i += 1;
                    while (lx.i < s.len and std.ascii.isDigit(s[lx.i])) lx.i += 1;
                    const x = std.fmt.parseFloat(f64, s[start..lx.i]) catch
                        return lx.p.fail(lx.line, "invalid number '{s}'", .{s[start..lx.i]});
                    return .{ .float = x };
                }
                const n = std.fmt.parseInt(i64, s[start..lx.i], 10) catch
                    return lx.p.fail(lx.line, "invalid number '{s}'", .{s[start..lx.i]});
                return .{ .int = n };
            },
            else => {
                if (!(std.ascii.isAlphabetic(c) or c == '_')) {
                    return lx.p.fail(lx.line, "unexpected character '{c}'", .{c});
                }
                const start = lx.i;
                while (lx.i < s.len and isIdentChar(s[lx.i])) lx.i += 1;
                if (lx.i < s.len and s[lx.i] == '?') lx.i += 1;
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
    /// Resolves `{% extends %}` names, which name layouts; null uses
    /// `loadFn`.
    extendsFn: ?*const fn (ctx: *anyopaque, name: []const u8, diag: *Diagnostic) LoadError!*const Template = null,
    /// Resolves `{% include_relative %}` names against the template `from`;
    /// null when the tag is not available.
    relativeFn: ?*const fn (ctx: *anyopaque, from: []const u8, name: []const u8, diag: *Diagnostic) LoadError!*const Template = null,

    pub const LoadError = error{ TemplateNotFound, TemplateSyntax } || Allocator.Error;

    fn load(l: Loader, name: []const u8, diag: *Diagnostic) LoadError!*const Template {
        return l.loadFn(l.ctx, name, diag);
    }

    fn loadParent(l: Loader, name: []const u8, diag: *Diagnostic) LoadError!*const Template {
        return (l.extendsFn orelse l.loadFn)(l.ctx, name, diag);
    }
};

/// How many templates an `extends` chain may hold.
const max_extends_depth = 16;

pub const RenderError = error{ TemplateRender, TemplateSyntax, TemplateNotFound } || Allocator.Error || Writer.Error;

const max_include_depth = 32;

/// The longest list a range such as `(1..n)` may make.
const max_range = 100_000;

const Binding = struct { name: []const u8, value: Value };

const Flow = enum { normal, @"break", @"continue" };

pub const Renderer = struct {
    arena: Allocator,
    loader: ?Loader,
    diag: *Diagnostic,
    root: Object,
    /// Loop variables and include arguments, innermost last.
    scope: std.ArrayList(Binding) = .empty,
    /// Variables set by `assign` and `capture`.
    assigns: *std.StringArrayHashMapUnmanaged(Value),
    /// `increment` and `decrement` counters.
    counters: *std.StringArrayHashMapUnmanaged(i64),
    /// Positions of `cycle` tags.
    cycles: std.StringHashMapUnmanaged(usize) = .empty,
    /// Where each loop stopped, for `offset: continue`.
    offsets: std.StringHashMapUnmanaged(usize) = .empty,
    template: []const u8 = "",
    /// The line being rendered, for errors raised without one.
    line: usize = 0,
    depth: usize = 0,
    strict: bool = false,
    liquid: bool = false,
    /// Whether output strings are HTML-escaped: off in Liquid, and while
    /// rendering a `highlight` body, which is escaped as a whole.
    escape: bool = true,
    now: i64 = 0,
    assets: ?Assets = null,
    links: ?Links = null,
    stash: ?*std.ArrayList([]const u8) = null,
    /// For the `sample` filter; seeded the same way every render, so builds
    /// are reproducible.
    prng: std.Random.DefaultPrng,
    /// The `extends` chain being rendered, most derived template first.
    /// Each block renders from the first template that defines it.
    chain: []const *const Template = &.{},
    /// The block being rendered and where `{{ super }}` continues.
    super: ?struct { name: []const u8, next: usize } = null,

    pub fn fail(r: *Renderer, line: usize, comptime fmt: []const u8, args: anytype) RenderError {
        r.diag.* = .{
            .template = r.template,
            .line = line,
            .message = std.fmt.allocPrint(r.arena, fmt, args) catch "out of memory while reporting an error",
        };
        return error.TemplateRender;
    }
};

pub const RenderOptions = struct {
    /// Fail on undefined variables instead of rendering nothing: an output
    /// tag whose value is undefined (unless a `default` filter follows),
    /// and a loop over a variable whose first name is unknown. Conditions
    /// stay lenient, so `{% if page.subtitle %}` works on every page.
    strict: bool = false,
    /// Render as Liquid does where it differs from Mortise: output is not
    /// escaped, only `nil` and `false` are false, `and` and `or` group from
    /// the right, and filters follow Liquid's and Jekyll's definitions.
    liquid: bool = false,
    /// What `"now"` and `"today"` mean to date filters, in seconds since
    /// the Unix epoch.
    now: i64 = 0,
    /// Answers the `asset` and `sri` filters; without one they fail.
    assets: ?Assets = null,
    /// Answers `{% link %}` and `{% post_url %}`; without one they fail.
    links: ?Links = null,
    /// When set, the HTML that `highlight` and includes write at the top
    /// level is kept here and a placeholder written instead, so that
    /// Markdown rendered from the output leaves it alone; `restoreStashed`
    /// puts it back.
    stash: ?*std.ArrayList([]const u8) = null,
};

/// Looks up static files for the `asset` and `sri` filters.
pub const Assets = struct {
    ctx: *anyopaque,
    /// The answer for `path` (as written in the template), or null with a
    /// reason in `why`.
    lookupFn: *const fn (ctx: *anyopaque, path: []const u8, kind: Kind, why: *[]const u8) Allocator.Error!?[]const u8,

    pub const Kind = enum { url, sri };
};

/// Looks up pages for `{% link %}` and posts for `{% post_url %}`.
pub const Links = struct {
    ctx: *anyopaque,
    /// The URL for `target`, or null with a reason in `why`.
    lookupFn: *const fn (ctx: *anyopaque, kind: Kind, target: []const u8, why: *[]const u8) Allocator.Error!?[]const u8,

    pub const Kind = enum { link, post_url };
};

/// Renders `tpl` with `root` as the top-level variables.
pub fn render(arena: Allocator, tpl: *const Template, root: Object, loader: ?Loader, w: *Writer, diag: *Diagnostic) RenderError!void {
    return renderWith(arena, tpl, root, loader, .{}, w, diag);
}

/// `render` with options.
pub fn renderWith(arena: Allocator, tpl: *const Template, root: Object, loader: ?Loader, options: RenderOptions, w: *Writer, diag: *Diagnostic) RenderError!void {
    var assigns: std.StringArrayHashMapUnmanaged(Value) = .empty;
    var counters: std.StringArrayHashMapUnmanaged(i64) = .empty;
    var r: Renderer = .{
        .arena = arena,
        .loader = loader,
        .diag = diag,
        .root = root,
        .assigns = &assigns,
        .counters = &counters,
        .template = tpl.name,
        .strict = options.strict,
        .liquid = options.liquid,
        .escape = !options.liquid,
        .now = options.now,
        .assets = options.assets,
        .links = options.links,
        .stash = options.stash,
        .prng = .init(0x6d6f7274697365),
    };
    // Follow `extends` to the root template, which supplies the page; the
    // templates below it only fill its blocks.
    var chain: std.ArrayList(*const Template) = .empty;
    try chain.append(arena, tpl);
    var cur = tpl;
    while (cur.extends) |parent_name| {
        if (chain.items.len >= max_extends_depth) {
            r.template = cur.name;
            return r.fail(cur.extends_line, "templates extend each other more than {d} deep (does '{s}' extend itself?)", .{ max_extends_depth, parent_name });
        }
        const loader_ = loader orelse {
            r.template = cur.name;
            return r.fail(cur.extends_line, "'extends' is not available here", .{});
        };
        const saved_diag = r.diag.*;
        const parent = loader_.loadParent(parent_name, r.diag) catch |err| switch (err) {
            error.TemplateNotFound => {
                r.diag.* = saved_diag;
                r.template = cur.name;
                return r.fail(cur.extends_line, "the layout '{s}' to extend was not found", .{parent_name});
            },
            else => |e| return e,
        };
        cur = parent;
        try chain.append(arena, cur);
    }
    r.chain = chain.items;
    r.template = cur.name;
    _ = try renderNodes(&r, cur.nodes, w);
}

/// Renders block `name` from the first template in the chain at or after
/// `start` that defines it.
fn renderBlock(r: *Renderer, name: []const u8, start: usize, w: *Writer) RenderError!Flow {
    for (r.chain[@min(start, r.chain.len)..], start..) |t, i| {
        const body = t.findBlock(name) orelse continue;
        const outer_template = r.template;
        const outer_super = r.super;
        r.template = t.name;
        r.super = .{ .name = name, .next = i + 1 };
        defer {
            r.template = outer_template;
            r.super = outer_super;
        }
        return renderNodes(r, body, w);
    }
    return .normal;
}

/// Renders to a newly allocated string.
pub fn renderAlloc(arena: Allocator, tpl: *const Template, root: Object, loader: ?Loader, diag: *Diagnostic) RenderError![]u8 {
    return renderAllocWith(arena, tpl, root, loader, .{}, diag);
}

/// `renderAlloc` with options.
pub fn renderAllocWith(arena: Allocator, tpl: *const Template, root: Object, loader: ?Loader, options: RenderOptions, diag: *Diagnostic) RenderError![]u8 {
    var aw: Writer.Allocating = .init(arena);
    try renderWith(arena, tpl, root, loader, options, &aw.writer, diag);
    return aw.toOwnedSlice();
}

fn renderNodes(r: *Renderer, nodes: []const Node, w: *Writer) RenderError!Flow {
    for (nodes) |node| {
        const flow = try renderNode(r, node, w);
        if (flow != .normal) return flow;
    }
    return .normal;
}

fn renderToString(r: *Renderer, nodes: []const Node) RenderError![]const u8 {
    var aw: Writer.Allocating = .init(r.arena);
    _ = try renderNodes(r, nodes, &aw.writer);
    return aw.written();
}

fn renderNode(r: *Renderer, node: Node, w: *Writer) RenderError!Flow {
    switch (node) {
        .text => |t| try w.writeAll(t),
        .output => |o| try writeValue(r, try evalOutput(r, o), w, o.line),
        .@"if" => |n| for (n.branches) |b| {
            var take = if (b.cond) |c| try evalCondition(r, c) else true;
            if (b.negate) take = !take;
            if (take) return renderNodes(r, b.body, w);
        },
        .case => |n| {
            r.line = n.line;
            const subject = try evalExpr(r, n.subject);
            var matched = false;
            for (n.whens) |wh| {
                const values = wh.values orelse {
                    if (!matched) {
                        const flow = try renderNodes(r, wh.body, w);
                        if (flow != .normal) return flow;
                    }
                    continue;
                };
                for (values) |e| {
                    if (!equalExprs(n.subject, subject, e, try evalExpr(r, e))) continue;
                    matched = true;
                    const flow = try renderNodes(r, wh.body, w);
                    if (flow != .normal) return flow;
                    // Liquid renders a `when` once for each value that
                    // matches; Mortise once.
                    if (!r.liquid) break;
                }
            }
        },
        .@"for" => |f| return renderFor(r, f, w),
        .tablerow => |f| return renderTablerow(r, f, w),
        .@"break" => return .@"break",
        .@"continue" => return .@"continue",
        .assign => |a| try r.assigns.put(r.arena, a.name, try evalOutput(r, a.value)),
        .capture => |c| {
            var aw: Writer.Allocating = .init(r.arena);
            const flow = try renderNodes(r, c.body, &aw.writer);
            // The captured text was escaped as it was rendered.
            try r.assigns.put(r.arena, c.name, if (r.liquid) .{ .string = aw.written() } else .{ .html = aw.written() });
            return flow;
        },
        .counter => |c| {
            const cur = r.counters.get(c.name) orelse 0;
            const next = if (c.decrement) cur - 1 else cur + 1;
            try r.counters.put(r.arena, c.name, next);
            try w.print("{d}", .{if (c.decrement) next else cur});
        },
        .cycle => |c| {
            r.line = c.line;
            const key = if (c.group) |g| try filters.toText(r, try evalExpr(r, g)) else c.key;
            const index = r.cycles.get(key) orelse 0;
            try writeValue(r, try evalExpr(r, c.values[index % c.values.len]), w, c.line);
            try r.cycles.put(r.arena, key, index + 1);
        },
        .include => |inc| {
            if (r.stash == null or r.depth > 0) return renderInclude(r, inc, w);
            var aw: Writer.Allocating = .init(r.arena);
            const flow = try renderInclude(r, inc, &aw.writer);
            // HTML is kept from Markdown; text such as Markdown is not.
            const out = aw.written();
            if (std.mem.trimStart(u8, out, " \t\r\n").len > 0 and std.mem.trimStart(u8, out, " \t\r\n")[0] == '<') {
                try stashHtml(r, out, w);
            } else try w.writeAll(out);
            return flow;
        },
        .block => |b| {
            if (r.chain.len == 0) return renderNodes(r, b.body, w);
            return renderBlock(r, b.name, 0, w);
        },
        .super => {
            const s = r.super orelse return .normal;
            return renderBlock(r, s.name, s.next, w);
        },
        .highlight => |h| {
            if (r.stash == null or r.depth > 0) {
                try renderHighlight(r, h.lang, h.linenos, h.body, w);
            } else {
                var aw: Writer.Allocating = .init(r.arena);
                try renderHighlight(r, h.lang, h.linenos, h.body, &aw.writer);
                try stashHtml(r, aw.written(), w);
            }
        },
        .link => |l| {
            r.line = l.line;
            const target = switch (l.target) {
                .static => |s| s,
                .dynamic => |t| std.mem.trim(u8, try renderToString(r, t.nodes), " \t\r\n"),
            };
            const links = r.links orelse return r.fail(l.line, "'{s}' is not available here", .{@tagName(l.kind)});
            var why: []const u8 = "";
            const url = try links.lookupFn(links.ctx, l.kind, target, &why) orelse
                return r.fail(l.line, "'{s} {s}': {s}", .{ @tagName(l.kind), target, why });
            try w.writeAll(url);
        },
    }
    return .normal;
}

fn evalOutput(r: *Renderer, o: Output) RenderError!Value {
    r.line = o.line;
    var v = try evalExpr(r, o.expr);
    if (r.strict and o.expr == .path and !hasDefault(o.filters)) {
        if ((try resolve(r, o.expr.path)) == null) return undefinedVariable(r, o.expr.path, o.line);
    }
    for (o.filters) |f| v = try filters.apply(r, f, v, o.line);
    return v;
}

/// The items a `for` or `tablerow` loops over, after `offset`, `limit` and
/// `reversed`.
fn loopItems(r: *Renderer, f: *const For) RenderError![]const Value {
    r.line = f.line;
    if (r.strict and f.iter == .path and f.iter.path[0] == .name and !isBound(r, f.iter.path[0].name)) {
        return undefinedVariable(r, f.iter.path[0..1], f.line);
    }
    var iter = try evalExpr(r, f.iter);
    for (f.filters) |flt| iter = try filters.apply(r, flt, iter, f.line);
    var items: []const Value = switch (iter) {
        .nil => &.{},
        .list => |l| l,
        else => if (!r.liquid) return r.fail(f.line, "cannot loop over {s}", .{iter.typeName()}) else switch (iter) {
            // Liquid loops over an object's [key, value] pairs, and over a
            // string once.
            .object => |o| blk: {
                const pairs = try r.arena.alloc(Value, o.entries.len);
                for (pairs, o.entries) |*pair, e| {
                    pair.* = .{ .list = try r.arena.dupe(Value, &.{ .{ .string = e.key }, e.value }) };
                }
                break :blk pairs;
            },
            .string, .html => |s| if (s.len == 0) &.{} else try r.arena.dupe(Value, &.{iter}),
            else => &.{},
        },
    };
    var from: usize = 0;
    if (f.offset_continue) {
        from = r.offsets.get(f.key) orelse 0;
    } else if (f.offset) |e| {
        from = @intCast(@max(0, try filters.toInteger(r, try evalExpr(r, e), f.line)));
    }
    from = @min(from, items.len);
    var to = items.len;
    if (f.limit) |e| {
        const n: usize = @intCast(@max(0, try filters.toInteger(r, try evalExpr(r, e), f.line)));
        to = @min(to, from +| n);
    }
    items = items[from..to];
    try r.offsets.put(r.arena, f.key, from + items.len);
    if (f.reversed) {
        const rev = try r.arena.dupe(Value, items);
        std.mem.reverse(Value, rev);
        items = rev;
    }
    return items;
}

fn renderFor(r: *Renderer, f: *const For, w: *Writer) RenderError!Flow {
    const items = try loopItems(r, f);
    if (items.len == 0) return renderNodes(r, f.else_body, w);
    const parent = lookupName(r, "forloop") orelse .nil;
    const base = r.scope.items.len;
    defer r.scope.shrinkRetainingCapacity(base);
    try r.scope.appendNTimes(r.arena, .{ .name = "", .value = .nil }, 3);
    for (items, 0..) |item, i| {
        const len = items.len;
        const entries = try r.arena.dupe(Entry, &.{
            .{ .key = "name", .value = .{ .string = f.key } },
            .{ .key = "length", .value = .{ .int = @intCast(len) } },
            .{ .key = "index", .value = .{ .int = @intCast(i + 1) } },
            .{ .key = "index0", .value = .{ .int = @intCast(i) } },
            .{ .key = "rindex", .value = .{ .int = @intCast(len - i) } },
            .{ .key = "rindex0", .value = .{ .int = @intCast(len - i - 1) } },
            .{ .key = "first", .value = .{ .boolean = i == 0 } },
            .{ .key = "last", .value = .{ .boolean = i + 1 == len } },
            .{ .key = "parentloop", .value = parent },
        });
        const loop: Value = .{ .object = .{ .entries = entries } };
        r.scope.items[base] = .{ .name = "loop", .value = loop };
        r.scope.items[base + 1] = .{ .name = "forloop", .value = loop };
        r.scope.items[base + 2] = .{ .name = f.name, .value = item };
        if (try renderNodes(r, f.body, w) == .@"break") break;
    }
    return .normal;
}

/// Liquid's `tablerow`: table cells, `cols` to a row.
fn renderTablerow(r: *Renderer, f: *const For, w: *Writer) RenderError!Flow {
    const items = try loopItems(r, f);
    var cols: ?usize = null;
    if (f.cols) |e| {
        const n = try filters.toInteger(r, try evalExpr(r, e), f.line);
        if (n > 0) cols = @intCast(n);
    }
    const base = r.scope.items.len;
    defer r.scope.shrinkRetainingCapacity(base);
    try r.scope.appendNTimes(r.arena, .{ .name = "", .value = .nil }, 2);
    try w.writeAll("<tr class=\"row1\">\n");
    var col: usize = 1;
    var row: usize = 1;
    for (items, 0..) |item, i| {
        const len = items.len;
        const col_last = cols != null and col == cols.?;
        const entries = try r.arena.dupe(Entry, &.{
            .{ .key = "length", .value = .{ .int = @intCast(len) } },
            .{ .key = "index", .value = .{ .int = @intCast(i + 1) } },
            .{ .key = "index0", .value = .{ .int = @intCast(i) } },
            .{ .key = "rindex", .value = .{ .int = @intCast(len - i) } },
            .{ .key = "rindex0", .value = .{ .int = @intCast(len - i - 1) } },
            .{ .key = "first", .value = .{ .boolean = i == 0 } },
            .{ .key = "last", .value = .{ .boolean = i + 1 == len } },
            .{ .key = "col", .value = .{ .int = @intCast(col) } },
            .{ .key = "col0", .value = .{ .int = @intCast(col - 1) } },
            .{ .key = "col_first", .value = .{ .boolean = col == 1 } },
            .{ .key = "col_last", .value = .{ .boolean = col_last } },
            .{ .key = "row", .value = .{ .int = @intCast(row) } },
        });
        r.scope.items[base] = .{ .name = "tablerowloop", .value = .{ .object = .{ .entries = entries } } };
        r.scope.items[base + 1] = .{ .name = f.name, .value = item };
        try w.print("<td class=\"col{d}\">", .{col});
        const flow = try renderNodes(r, f.body, w);
        try w.writeAll("</td>");
        if (col_last and i + 1 < len) try w.print("</tr>\n<tr class=\"row{d}\">", .{row + 1});
        if (flow == .@"break") break;
        if (col_last) {
            col = 1;
            row += 1;
        } else col += 1;
    }
    try w.writeAll("</tr>\n");
    return .normal;
}

fn renderInclude(r: *Renderer, inc: *const Include, w: *Writer) RenderError!Flow {
    r.line = inc.line;
    const loader = r.loader orelse return r.fail(inc.line, "includes are not available here", .{});
    const name = switch (inc.name) {
        .static => |s| s,
        .dynamic => |t| std.mem.trim(u8, try renderToString(r, t.nodes), " \t\r\n"),
    };
    if (name.len == 0) return r.fail(inc.line, "the name of the template to include is empty", .{});
    if (r.depth >= max_include_depth) {
        return r.fail(inc.line, "includes nested more than {d} deep (is '{s}' including itself?)", .{ max_include_depth, name });
    }
    const saved_diag = r.diag.*;
    const loaded = switch (inc.kind) {
        .relative => blk: {
            const f = loader.relativeFn orelse return r.fail(inc.line, "'include_relative' is not available here", .{});
            break :blk f(loader.ctx, r.template, name, r.diag);
        },
        else => loader.load(name, r.diag),
    };
    const child = loaded catch |err| switch (err) {
        error.TemplateNotFound => {
            r.diag.* = saved_diag;
            return r.fail(inc.line, "included template '{s}' was not found", .{name});
        },
        else => |e| return e,
    };

    // Arguments are evaluated where the include is, then bound for the
    // included template only. Jekyll's `key=value` arguments are also
    // fields of `include`.
    var bindings: std.ArrayList(Binding) = .empty;
    var jekyll_args: std.ArrayList(Entry) = .empty;
    for (inc.args) |a| {
        const v = try evalExpr(r, a.expr);
        try bindings.append(r.arena, .{ .name = a.name, .value = v });
        if (a.jekyll) try jekyll_args.append(r.arena, .{ .key = a.name, .value = v });
    }
    if (jekyll_args.items.len > 0) {
        try bindings.append(r.arena, .{ .name = "include", .value = .{ .object = .{ .entries = jekyll_args.items } } });
    }
    var each: ?[]const Value = null;
    var alias: []const u8 = "";
    if (inc.with) |e| {
        const v = try evalExpr(r, e);
        alias = inc.alias orelse name[if (std.mem.lastIndexOfScalar(u8, name, '/')) |s| s + 1 else 0..];
        // `include` binds each item of a list in turn, with `with` as with
        // `for`; `render` only with `for`.
        if (v == .list and (inc.each or inc.kind != .render)) {
            each = v.list;
        } else if (inc.each and v == .nil) {
            each = &.{};
        } else {
            try bindings.append(r.arena, .{ .name = alias, .value = v });
        }
    }

    const outer_template = r.template;
    const outer_chain = r.chain;
    const outer_super = r.super;
    const outer_scope = r.scope;
    const outer_assigns = r.assigns;
    const outer_counters = r.counters;
    var own_assigns: std.StringArrayHashMapUnmanaged(Value) = .empty;
    var own_counters: std.StringArrayHashMapUnmanaged(i64) = .empty;
    if (inc.kind == .render) {
        // `render` sees only its arguments and the site's variables.
        r.scope = .empty;
        r.assigns = &own_assigns;
        r.counters = &own_counters;
    }
    const base = r.scope.items.len;
    try r.scope.appendSlice(r.arena, bindings.items);
    // An included template's blocks are its own, not the page's.
    r.chain = &.{child};
    r.super = null;
    r.template = child.name;
    r.depth += 1;
    var flow: Flow = .normal;
    if (each) |items| {
        const slot = r.scope.items.len;
        try r.scope.appendNTimes(r.arena, .{ .name = "", .value = .nil }, 2);
        for (items, 0..) |item, i| {
            const entries = try r.arena.dupe(Entry, &.{
                .{ .key = "length", .value = .{ .int = @intCast(items.len) } },
                .{ .key = "index", .value = .{ .int = @intCast(i + 1) } },
                .{ .key = "index0", .value = .{ .int = @intCast(i) } },
                .{ .key = "first", .value = .{ .boolean = i == 0 } },
                .{ .key = "last", .value = .{ .boolean = i + 1 == items.len } },
            });
            r.scope.items[slot] = .{ .name = "forloop", .value = .{ .object = .{ .entries = entries } } };
            r.scope.items[slot + 1] = .{ .name = alias, .value = item };
            flow = try renderNodes(r, child.nodes, w);
            if (flow == .@"break") break;
        }
    } else {
        flow = try renderNodes(r, child.nodes, w);
    }
    r.depth -= 1;
    r.scope.shrinkRetainingCapacity(base);
    r.template = outer_template;
    r.chain = outer_chain;
    r.super = outer_super;
    if (inc.kind == .render) {
        r.scope = outer_scope;
        r.assigns = outer_assigns;
        r.counters = outer_counters;
        return .normal;
    }
    return flow;
}

const stash_mark = "\x02mt-raw-";

fn stashHtml(r: *Renderer, html: []const u8, w: *Writer) RenderError!void {
    const stash = r.stash.?;
    try w.print(stash_mark ++ "{d}\x02", .{stash.items.len});
    try stash.append(r.arena, std.mem.trim(u8, html, " \t\r\n"));
}

/// Puts the HTML kept by the `stash` option back in place of its
/// placeholders in `html`: a placeholder that is a whole paragraph
/// replaces the paragraph.
pub fn restoreStashed(arena: Allocator, html: []const u8, stash: []const []const u8) Allocator.Error![]const u8 {
    if (stash.len == 0) return html;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, html, i, stash_mark)) |at| {
        const num_start = at + stash_mark.len;
        const end = std.mem.indexOfScalarPos(u8, html, num_start, '\x02') orelse break;
        const index = std.fmt.parseInt(usize, html[num_start..end], 10) catch break;
        if (index >= stash.len) break;
        var start = at;
        var after = end + 1;
        // `<p>MARK</p>`: the paragraph Markdown wrapped around it goes too.
        if (std.mem.endsWith(u8, html[i..at], "<p>") and std.mem.startsWith(u8, html[after..], "</p>")) {
            start -= "<p>".len;
            after += "</p>".len;
        }
        try out.appendSlice(arena, html[i..start]);
        try out.appendSlice(arena, stash[index]);
        i = after;
    }
    try out.appendSlice(arena, html[i..]);
    return out.items;
}

/// Jekyll's `{% highlight %}` markup, with the code highlighted where
/// Mortise knows the language.
fn renderHighlight(r: *Renderer, lang: []const u8, linenos: bool, body: []const Node, w: *Writer) RenderError!void {
    const outer_escape = r.escape;
    r.escape = false;
    const rendered = try renderToString(r, body);
    r.escape = outer_escape;
    const code = std.mem.trim(u8, rendered, "\r\n");
    try w.writeAll("<figure class=\"highlight\"><pre><code class=\"language-");
    for (lang) |c| try w.writeByte(if (c == '+') '-' else c);
    try w.print("\" data-lang=\"{s}\">", .{lang});
    if (linenos) {
        try w.writeAll("<table class=\"rouge-table\"><tbody><tr><td class=\"gutter gl\"><pre class=\"lineno\">");
        const lines = std.mem.count(u8, code, "\n") + 1;
        for (1..lines + 1) |n| try w.print("{d}\n", .{n});
        try w.writeAll("</pre></td><td class=\"code\"><pre>");
        try highlight.write(w, lang, code);
        try w.writeAll("\n</pre></td></tr></tbody></table>");
    } else {
        try highlight.write(w, lang, code);
    }
    try w.writeAll("</code></pre></figure>");
}

fn lookupName(r: *Renderer, name: []const u8) ?Value {
    var k = r.scope.items.len;
    while (k > 0) {
        k -= 1;
        if (std.mem.eql(u8, r.scope.items[k].name, name)) return r.scope.items[k].value;
    }
    if (r.assigns.get(name)) |v| return v;
    if (r.counters.get(name)) |n| return .{ .int = n };
    return r.root.get(name);
}

/// The value at `path`, or null when it is undefined.
pub fn resolve(r: *Renderer, path: []const Seg) RenderError!?Value {
    const first = switch (path[0]) {
        .name => |n| n,
        .index => |e| (try evalExpr(r, e.*)).text() orelse return null,
    };
    var v = lookupName(r, first) orelse return null;
    for (path[1..]) |seg| {
        v = switch (seg) {
            .name => |n| member(r, v, n),
            .index => |e| switch (try evalExpr(r, e.*)) {
                .int => |i| switch (v) {
                    .list => |l| listAt(l, i),
                    else => null,
                },
                .string, .html => |key| member(r, v, key),
                else => null,
            },
        } orelse return null;
    }
    return v;
}

/// Field `name` of `v`, or for lists and strings the `size`, `first` and
/// `last` that Liquid offers.
pub fn member(r: *Renderer, v: Value, name: []const u8) ?Value {
    if (v == .object) {
        if (v.object.get(name)) |x| return x;
    }
    if (std.mem.eql(u8, name, "size")) return switch (v) {
        .list => |l| .{ .int = @intCast(l.len) },
        .string, .html => |s| .{ .int = @intCast(if (r.liquid) filters.charCount(s) else s.len) },
        .object => |o| .{ .int = @intCast(o.entries.len) },
        else => null,
    };
    if (v == .list and (std.mem.eql(u8, name, "first") or std.mem.eql(u8, name, "last"))) {
        const l = v.list;
        if (l.len == 0) return null;
        return if (name[0] == 'f') l[0] else l[l.len - 1];
    }
    return null;
}

fn listAt(l: []const Value, i: i64) ?Value {
    const len: i64 = @intCast(l.len);
    const at = if (i < 0) len + i else i;
    if (at < 0 or at >= len) return null;
    return l[@intCast(at)];
}

fn isBound(r: *Renderer, name: []const u8) bool {
    return lookupName(r, name) != null;
}

fn hasDefault(fs: []const Filter) bool {
    for (fs) |f| if (f.kind == .default) return true;
    return false;
}

fn pathText(arena: Allocator, path: []const Seg) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (path, 0..) |seg, i| switch (seg) {
        .name => |n| {
            if (i > 0) try out.append(arena, '.');
            try out.appendSlice(arena, n);
        },
        .index => try out.appendSlice(arena, "[...]"),
    };
    return out.items;
}

fn undefinedVariable(r: *Renderer, path: []const Seg, line: usize) RenderError {
    const name = try pathText(r.arena, path);
    if (path[0] != .name or !isBound(r, path[0].name)) {
        return r.fail(line, "undefined variable '{s}' (strict mode); add a default, as in {{{{ {s} | default(\"\") }}}}", .{ name, name });
    }
    return r.fail(line, "'{s}' is not defined (strict mode); guard it with {{% if {s} %}} or add | default(\"\")", .{ name, name });
}

pub fn evalExpr(r: *Renderer, e: Expr) RenderError!Value {
    return switch (e) {
        .path => |p| (try resolve(r, p)) orelse .nil,
        .string => |s| .{ .string = s },
        .int => |n| .{ .int = n },
        .float => |x| .{ .float = x },
        .boolean => |b| .{ .boolean = b },
        .nil, .empty, .blank => .nil,
        .range => |rg| blk: {
            const from = try filters.toInteger(r, try evalExpr(r, rg[0]), r.line);
            const to = try filters.toInteger(r, try evalExpr(r, rg[1]), r.line);
            if (to < from) break :blk .{ .list = &.{} };
            if (to - from >= max_range) return r.fail(r.line, "the range ({d}..{d}) is longer than {d}", .{ from, to, max_range });
            const list = try r.arena.alloc(Value, @intCast(to - from + 1));
            for (list, 0..) |*v, i| v.* = .{ .int = from + @as(i64, @intCast(i)) };
            break :blk .{ .list = list };
        },
    };
}

pub fn evalCondition(r: *Renderer, c: Condition) RenderError!bool {
    r.line = c.line;
    const n = c.items.len;
    if (r.liquid) {
        // Liquid groups from the right: `a and b or c` is `a and (b or c)`.
        var acc = try evalComparison(r, c.items[n - 1]);
        var i = n - 1;
        while (i > 0) {
            i -= 1;
            acc = switch (c.joins[i]) {
                .@"and" => acc and try evalComparison(r, c.items[i]),
                .@"or" => acc or try evalComparison(r, c.items[i]),
            };
        }
        return acc;
    }
    // Mortise: `and` binds tighter than `or`.
    var group = true;
    for (c.items, 0..) |cmp, i| {
        if (group) group = try evalComparison(r, cmp);
        if (i + 1 == n or c.joins[i] == .@"or") {
            if (group) return true;
            group = true;
        }
    }
    return false;
}

fn evalComparison(r: *Renderer, cmp: Comparison) RenderError!bool {
    const left = try evalExpr(r, cmp.left);
    var result = switch (cmp.op) {
        .truthy => if (r.liquid) left.liquidTruthy() else left.truthy(),
        .eq => equalExprs(cmp.left, left, cmp.right, try evalExpr(r, cmp.right)),
        .ne => !equalExprs(cmp.left, left, cmp.right, try evalExpr(r, cmp.right)),
        .contains => contains(r, left, try evalExpr(r, cmp.right)),
        .lt, .gt, .le, .ge => blk: {
            const ord = try order(r, left, try evalExpr(r, cmp.right)) orelse break :blk false;
            break :blk switch (cmp.op) {
                .lt => ord == .lt,
                .gt => ord == .gt,
                .le => ord != .gt,
                else => ord != .lt,
            };
        },
    };
    if (cmp.negate) result = !result;
    return result;
}

/// `==`, where either side may be Liquid's `empty` or `blank`.
fn equalExprs(left_expr: Expr, left: Value, right_expr: Expr, right: Value) bool {
    if (right_expr == .empty) return isEmpty(left);
    if (left_expr == .empty) return isEmpty(right);
    if (right_expr == .blank) return isBlank(left);
    if (left_expr == .blank) return isBlank(right);
    return left.eql(right);
}

fn isEmpty(v: Value) bool {
    return switch (v) {
        .string, .html => |s| s.len == 0,
        .list => |l| l.len == 0,
        .object => |o| o.entries.len == 0,
        else => false,
    };
}

fn isBlank(v: Value) bool {
    return switch (v) {
        .nil => true,
        .boolean => |b| !b,
        .string, .html => |s| std.mem.trim(u8, s, " \t\r\n\x0b\x0c").len == 0,
        else => isEmpty(v),
    };
}

fn contains(r: *Renderer, haystack: Value, needle: Value) bool {
    if (needle == .nil) return false;
    return switch (haystack) {
        .string, .html => |s| std.mem.indexOf(u8, s, filters.toText(r, needle) catch return false) != null,
        .list => |l| for (l) |x| {
            if (x.eql(needle)) break true;
        } else false,
        .object => |o| o.get(needle.text() orelse return false) != null,
        else => false,
    };
}

/// How `a` and `b` order for `<` and the like: numbers by value and
/// strings by bytes. Null when either is missing; an error for other
/// mixes, as in Liquid.
fn order(r: *Renderer, a: Value, b: Value) RenderError!?std.math.Order {
    if (a == .nil or b == .nil) return null;
    const an = a == .int or a == .float;
    const bn = b == .int or b == .float;
    if (an and bn) {
        if (a == .int and b == .int) return std.math.order(a.int, b.int);
        return std.math.order(filters.toFloat(a), filters.toFloat(b));
    }
    if (a.text() != null and b.text() != null) return std.mem.order(u8, a.text().?, b.text().?);
    return r.fail(r.line, "cannot compare {s} with {s}", .{ a.typeName(), b.typeName() });
}

// Parsing at render time, for filters such as `where_exp` that take an
// expression as a string.

fn sourceParser(r: *Renderer) Parser {
    return .{ .arena = r.arena, .name = r.template, .diag = r.diag, .options = .{ .liquid = r.liquid }, .tokens = &.{} };
}

pub fn parseSourceCondition(r: *Renderer, src: []const u8) RenderError!Condition {
    var p = sourceParser(r);
    return parseCondition(&p, std.mem.trim(u8, src, " \t\r\n"), r.line);
}

pub fn parseSourceOutput(r: *Renderer, src: []const u8) RenderError!Output {
    var p = sourceParser(r);
    const trimmed = std.mem.trim(u8, src, " \t\r\n");
    if (trimmed.len == 0) return p.fail(r.line, "expected an expression", .{});
    return (try parseOutput(&p, trimmed, r.line)).output;
}

pub fn evalSourceOutput(r: *Renderer, o: Output) RenderError!Value {
    return evalOutput(r, o);
}

/// Binds `name` to `value` until `unbind` with the returned mark.
pub fn bind(r: *Renderer, name: []const u8, value: Value) Allocator.Error!usize {
    const mark = r.scope.items.len;
    try r.scope.append(r.arena, .{ .name = name, .value = value });
    return mark;
}

pub fn unbind(r: *Renderer, mark: usize) void {
    r.scope.shrinkRetainingCapacity(mark);
}

fn writeValue(r: *Renderer, v: Value, w: *Writer, line: usize) RenderError!void {
    if (r.liquid) return filters.writeText(r, w, v);
    switch (v) {
        .nil => {},
        .boolean => |b| try w.writeAll(if (b) "true" else "false"),
        .int => |n| try w.print("{d}", .{n}),
        .float => |f| try w.print("{d}", .{f}),
        .string => |s| if (r.escape) try escapeHtml(w, s) else try w.writeAll(s),
        .html => |s| try w.writeAll(s),
        .list, .object => return r.fail(line, "cannot output {s}; loop over it or pick a field", .{v.typeName()}),
    }
}

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

// ---------------------------------------------------------------------------

const testing = std.testing;

const TestFile = struct { []const u8, []const u8 };

const TestLoader = struct {
    arena: Allocator,
    files: []const TestFile,
    parsed: std.StringHashMapUnmanaged(*const Template) = .empty,
    options: ParseOptions = .{},

    fn loader(t: *TestLoader) Loader {
        return .{ .ctx = t, .loadFn = load, .relativeFn = loadRelative };
    }

    fn load(ctx: *anyopaque, name: []const u8, diag: *Diagnostic) Loader.LoadError!*const Template {
        const t: *TestLoader = @ptrCast(@alignCast(ctx));
        if (t.parsed.get(name)) |tpl| return tpl;
        for (t.files) |f| {
            if (!std.mem.eql(u8, f[0], name)) continue;
            const tpl = try t.arena.create(Template);
            tpl.* = try parseWith(t.arena, f[0], f[1], t.options, diag);
            try t.parsed.put(t.arena, name, tpl);
            return tpl;
        }
        return error.TemplateNotFound;
    }

    fn loadRelative(ctx: *anyopaque, from: []const u8, name: []const u8, diag: *Diagnostic) Loader.LoadError!*const Template {
        const t: *TestLoader = @ptrCast(@alignCast(ctx));
        _ = from;
        return load(t, try std.mem.concat(t.arena, u8, &.{ "rel/", name }), diag);
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
            .{ .key = "zero", .value = .{ .int = 0 } },
            .{ .key = "blank", .value = .{ .string = "  " } },
        };
        const root = [_]Entry{
            .{ .key = "page", .value = .{ .object = .{ .entries = &page } } },
            .{ .key = "content", .value = .{ .html = "<p>Body</p>" } },
            .{ .key = "posts", .value = .{ .list = &posts } },
            .{ .key = "empty", .value = .{ .list = &.{} } },
            .{ .key = "pages", .value = .{ .list = &pages } },
            .{ .key = "site", .value = .{ .object = .{ .entries = &site } } },
        };
        const pages = [_]Value{
            .{ .object = .{ .entries = &.{ .{ .key = "name", .value = .{ .string = "x" } }, .{ .key = "tags", .value = .{ .list = &.{.{ .string = "zig" }} } } } } },
            .{ .object = .{ .entries = &.{ .{ .key = "name", .value = .{ .string = "y" } }, .{ .key = "tags", .value = .{ .list = &.{.{ .string = "go" }} } } } } },
        };
        const site = [_]Entry{
            .{ .key = "baseurl", .value = .{ .string = "/blog" } },
            .{ .key = "url", .value = .{ .string = "https://example.com" } },
        };
    };
    return .{ .entries = &S.root };
}

const test_files = [_]TestFile{
    .{ "nav.html", "<nav>{{ page.title }}</nav>" },
    .{ "item.html", "<li>{{ post.title }}</li>" },
    .{ "card.html", "<div class=\"card\">{{ title }}{% if count %} ({{ count }}){% endif %}</div>" },
    .{ "base.html", "<title>{% block title %}Site{% endblock %}</title><main>{% block main %}base main{% endblock %}</main><footer>{% block footer %}(c){% endblock %}</footer>" },
    .{ "doc.html", "{% extends \"base.html\" %}{% block main %}<article>{% block body %}doc body{% endblock %}</article>{% endblock %}" },
    .{ "jekyll.html", "[{{ include.title }}|{{ include.n }}]" },
    .{ "product", "<{{ product.title }}>" },
    .{ "isolated", "{{ title }}|{{ outer }}|{{ page.count }}" },
    .{ "setter", "{% assign from_include = 'set' %}" },
    .{ "breaker", "{% break %}" },
    .{ "rel/notes.md", "relative {{ page.count }}" },
};

const RenderMode = enum { mortise, liquid };

fn renderTest(arena: Allocator, mode: RenderMode, strict: bool, src: []const u8, diag: *Diagnostic) ![]u8 {
    const options: ParseOptions = .{ .liquid = mode == .liquid };
    const tpl = try parseWith(arena, "test.html", src, options, diag);
    const tl = try arena.create(TestLoader);
    tl.* = .{ .arena = arena, .files = &test_files, .options = options };
    return renderAllocWith(arena, &tpl, testRoot(), tl.loader(), .{
        .strict = strict,
        .liquid = mode == .liquid,
        .now = 1704450600, // 2024-01-05 10:30:00 UTC
    }, diag);
}

fn expectMode(mode: RenderMode, expected: []const u8, src: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const out = renderTest(arena.allocator(), mode, false, src, &diag) catch |err| {
        std.debug.print("{s}:{d}: {s}\n", .{ diag.template, diag.line, diag.message });
        return err;
    };
    try testing.expectEqualStrings(expected, out);
}

fn expectRender(expected: []const u8, src: []const u8) !void {
    return expectMode(.mortise, expected, src);
}

pub fn expectLiquid(expected: []const u8, src: []const u8) !void {
    return expectMode(.liquid, expected, src);
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
    return expectModeError(.mortise, src, template, line, part);
}

pub fn expectModeError(mode: RenderMode, src: []const u8, template: []const u8, line: usize, part: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const tpl = try parseWith(arena.allocator(), "main.html", src, .{ .liquid = mode == .liquid }, &diag);
    var tl: TestLoader = .{ .arena = arena.allocator(), .files = &.{
        .{ "self.html", "x{% include \"self.html\" %}" },
        .{ "loop.html", "{% extends \"loop.html\" %}" },
        .{ "broken.html", "\n{{ page.tags }}" },
    } };
    try testing.expectError(error.TemplateRender, renderAllocWith(arena.allocator(), &tpl, testRoot(), tl.loader(), .{ .liquid = mode == .liquid }, &diag));
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

test "strict mode" {
    try expectRenderStrict("Untitled|", "{{ page.subtitle | default(\"Untitled\") }}|{% if page.subtitle %}{{ page.subtitle }}{% endif %}");
    try expectRenderStrict("", "{% for t in page.missing %}{{ t }}{% endfor %}");
    try expectStrictError("\n{{ page.titel }}", 2, "'page.titel' is not defined");
    try expectStrictError("{{ pgae.title }}", 1, "undefined variable 'pgae.title'");
    try expectStrictError("{% for p in sit.posts %}{% endfor %}", 1, "undefined variable 'sit'");
    try expectStrictError("{% for t in page.tags %}{{ t.name }}{% endfor %}", 1, "'t.name' is not defined");
}

fn expectRenderStrict(expected: []const u8, src: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const tpl = try parse(arena.allocator(), "s.html", src, &diag);
    const out = renderAllocWith(arena.allocator(), &tpl, testRoot(), null, .{ .strict = true }, &diag) catch |err| {
        std.debug.print("{s}:{d}: {s}\n", .{ diag.template, diag.line, diag.message });
        return err;
    };
    try testing.expectEqualStrings(expected, out);
}

fn expectStrictError(src: []const u8, line: usize, part: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const tpl = try parse(arena.allocator(), "s.html", src, &diag);
    // Lenient rendering of the same template succeeds.
    _ = try renderAlloc(arena.allocator(), &tpl, testRoot(), null, &diag);
    try testing.expectError(error.TemplateRender, renderAllocWith(arena.allocator(), &tpl, testRoot(), null, .{ .strict = true }, &diag));
    try testing.expectEqual(line, diag.line);
    if (std.mem.indexOf(u8, diag.message, part) == null) {
        std.debug.print("expected '{s}' in '{s}'\n", .{ part, diag.message });
        return error.TestUnexpectedResult;
    }
}

test "conditionals" {
    try expectRender("yes", "{% if page.title %}yes{% endif %}");
    try expectRender("no", "{% if page.draft %}yes{% else %}no{% endif %}");
    try expectRender("b", "{% if missing %}a{% elif page.count == 3 %}b{% else %}c{% endif %}");
    try expectRender("ok", "{% if not page.draft and page.count != 4 %}ok{% endif %}");
    try expectRender("ok", "{% if missing or page.title == \"<Hello>\" %}ok{% endif %}");
    try expectRender("", "{% if empty %}x{% endif %}");
    // `and` binds tighter than `or`.
    try expectRender("yes", "{% if page.count == 3 and missing or page.title %}yes{% endif %}");
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

test "include arguments" {
    try expectRender("<div class=\"card\">&lt;Hello&gt; (3)</div>", "{% include \"card.html\" title=page.title count=page.count %}");
    try expectRender("<div class=\"card\">Fixed</div>", "{% include \"card.html\" title=\"Fixed\" %}");
    // Arguments last only for the include.
    try expectRender("<div class=\"card\">x</div>[]", "{% include \"card.html\" title='x' %}[{{ title }}]");
    try expectRender("<div class=\"card\">First</div><div class=\"card\">Second &amp; more</div>", "{% for p in posts %}{% include \"card.html\" title=p.title %}{% endfor %}");
}

test "extends and blocks" {
    // A child fills the parent's blocks; the rest keeps its defaults.
    try expectRender("<title>Home</title><main>Hi</main><footer>(c)</footer>", "{% extends \"base.html\" %}{% block title %}Home{% endblock %}{% block main %}Hi{% endblock main %}");
    // Text outside blocks in a child is ignored.
    try expectRender("<title>Site</title><main>base main</main><footer>(c)</footer>", "{% extends \"base.html\" %}ignored");
    // super renders the parent's content of the block.
    try expectRender("<title>Home | Site</title><main>base main</main><footer>(c) 2024</footer>", "{% extends \"base.html\" %}{% block title %}Home | {{ super }}{% endblock %}{% block footer %}{{ super }} 2024{% endblock %}");
    // Three levels: a block from the grandchild fills a block the middle
    // template added inside one of the root's.
    try expectRender("<title>Site</title><main><article>mine, then doc body</article></main><footer>(c)</footer>", "{% extends \"doc.html\" %}{% block body %}mine, then {{ super }}{% endblock %}");
    // Without extends, blocks render in place.
    try expectRender("a[b]c", "a[{% block x %}b{% endblock %}]c");
}

test "extends errors" {
    try expectParseError("<p>\n{% extends \"base.html\" %}", 2, "must come first");
    try expectParseError("{% extends \"a.html\" %}{% extends \"b.html\" %}", 1, "only one parent");
    try expectParseError("{% block a %}{% endblock %}{% block a %}{% endblock %}", 1, "defined twice");
    try expectParseError("{% block a %}", 1, "is not closed");
    try expectParseError("{% block a %}{% endblock b %}", 1, "closes block 'a'");
    try expectParseError("{{ super }}", 1, "only inside a block");
    try expectParseError("{% include \"x.html\" a %}", 1, "expected '=' or ':' after 'a'");
    try expectRenderError("{% extends \"nope.html\" %}", "main.html", 1, "was not found");
    try expectRenderError("{% extends \"loop.html\" %}", "loop.html", 1, "more than 16 deep");
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
    const d = try parse(arena.allocator(), "d", "{% assign s = site %}{{ site[\"posts\"] }}", &diag);
    try testing.expect(d.reads_collections);
    const e = try parse(arena.allocator(), "e", "{% link about.md %}", &diag);
    try testing.expect(e.reads_collections);
    // A collection's documents, named by label.
    const opts: ParseOptions = .{ .liquid = true, .collections = &.{"recipes"} };
    try testing.expect((try parseWith(arena.allocator(), "f", "{{ site.recipes.size }}", opts, &diag)).reads_collections);
    try testing.expect((try parseWith(arena.allocator(), "g", "{{ site.collections.size }}", opts, &diag)).reads_collections);
    try testing.expect(!(try parseWith(arena.allocator(), "h", "{{ site.recipe }}", opts, &diag)).reads_collections);
}

test "includes are recorded for dependency tracking" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const tpl = try parse(arena.allocator(), "t", "{% include \"a.html\" %}{% if x %}{% include 'b.html' %}{% endif %}{% render 'c' %}{% include d.html x=1 %}", &diag);
    try testing.expectEqual(@as(usize, 4), tpl.includes.len);
    try testing.expectEqualStrings("b.html", tpl.includes[1]);
    try testing.expectEqualStrings("d.html", tpl.includes[3]);
}

test "syntax errors" {
    try expectParseError("a\n{{ page.title", 2, "unclosed");
    try expectParseError("{% if x %}\nno end", 1, "'if' is not closed");
    try expectParseError("{% for x in y %}", 1, "'for' is not closed");
    try expectParseError("\n\n{% endif %}", 3, "unexpected 'endif'");
    try expectParseError("{% if x %}{% else %}{% elif y %}{% endif %}", 1, "after 'else'");
    try expectParseError("{% if x %}{% endfor %}", 1, "inside 'if'");
    try expectParseError("{{ x | shout }}", 1, "unknown filter 'shout'");
    try expectParseError("{{ x | upcsae }}", 1, "did you mean 'upcase'?");
    try expectParseError("{{ x | default }}", 1, "needs an argument");
    try expectParseError("{{ x | upper(1) }}", 1, "takes no argument");
    try expectParseError("{{ x | default: 1, allow_true: 1 }}", 1, "no option 'allow_true'");
    try expectParseError("{% shout x %}", 1, "unknown statement");
    try expectParseError("{% for in y %}", 1, "expected 'in'");
    try expectParseError("{% if x = 1 %}{% endif %}", 1, "did you mean '=='");
    try expectParseError("{{ }}", 1, "empty output tag");
    try expectParseError("{{ \"open }}", 1, "unclosed");
    try expectParseError("{% raw %}{{ x }}", 1, "'raw' is not closed");
    try expectParseError("{% unless x %}{% endif %}", 1, "inside 'unless'");
    try expectParseError("{% case x %}{% when %}{% endcase %}", 1, "'when' needs a value");
    try expectParseError("{% for x in y limit 2 %}{% endfor %}", 1, "expected ':' after 'limit'");
    try expectParseError("{% capture %}{% endcapture %}", 1, "expected a variable name");
    try expectParseError("{% assign = 1 %}", 1, "expected a variable name");
    try expectParseError("{% liquid\nassign x = 1\nif x\nendfor %}", 4, "unexpected 'endfor'");
    try expectParseError("{% highlight %}{% endhighlight %}", 1, "needs a language");
    try expectParseError("{% for x in (1..3 %}{% endfor %}", 1, "expected ')'");
}

test "render errors name the template and line" {
    try expectRenderError("\n{{ posts }}", "main.html", 2, "cannot output a list");
    try expectRenderError("{% for x in page.title %}{% endfor %}", "main.html", 1, "cannot loop over a string");
    try expectRenderError("{% include \"missing.html\" %}", "main.html", 1, "was not found");
    try expectRenderError("{% include \"self.html\" %}", "self.html", 1, "nested more than");
    try expectRenderError("{% include \"broken.html\" %}", "broken.html", 2, "cannot output a list");
    try expectRenderError("{{ page.count | upper }}", "main.html", 1, "expects a string");
    try expectRenderError("{{ page.title | date }}", "main.html", 1, "expects a date");
    try expectRenderError("\n{% if page.count > \"a\" %}{% endif %}", "main.html", 2, "cannot compare a number with a string");
    try expectRenderError("{% link x.md %}", "main.html", 1, "'link' is not available here");
}

test "parseDate" {
    try testing.expectEqual(Date{ .year = 2024, .month = 2, .day = 29 }, parseDate("2024-02-29").?);
    try testing.expect(parseDate("2023-02-29") == null);
    try testing.expect(parseDate("2024-13-01") == null);
    try testing.expect(parseDate("2024-01-05T10:00:00Z") != null);
    try testing.expect(parseDate("2024-01-05x") == null);
    try testing.expect(parseDate("Jan 5") == null);
}

// Liquid

test "liquid output is not escaped and prints as Ruby does" {
    try expectLiquid("<Hello> <p>Body</p>", "{{ page.title }} {{ content }}");
    try expectLiquid("1.5 3 false zigweb", "{{ page.ratio }} {{ page.count }} {{ page.draft }} {{ page.tags }}");
    try expectLiquid("2.0 1.0e+20 0.0001 1.0e-05", "{{ 2.0 }} {{ 100000000000000000000.0 }} {{ 0.0001 }} {{ 0.00001 }}");
    try expectLiquid("", "{{ }}{{ nil }}");
    try expectLiquid("{\"title\"=>\"First\", \"url\"=>\"/a/\"}", "{{ posts.first }}");
}

test "liquid truth and conditions" {
    // Only nil and false are false.
    try expectLiquid("0 is true, '' is true", "{% if page.zero %}0 is true{% endif %}, {% if \"\" %}'' is true{% endif %}");
    try expectRender("", "{% if page.zero %}0 is true{% endif %}");
    try expectLiquid("b", "{% if page.count < 2 %}a{% elsif page.count >= 3 %}b{% endif %}");
    try expectLiquid("yes", "{% if page.tags contains \"zig\" and page.title contains \"Hell\" %}yes{% endif %}");
    try expectLiquid("no", "{% if page.tags contains \"rust\" %}yes{% else %}no{% endif %}");
    try expectLiquid("x", "{% if page.count <> 4 %}x{% endif %}");
    try expectLiquid("empty blank", "{% if empty == empty %}{% endif %}{% if \"\" == empty %}empty{% endif %} {% if page.blank == blank and nil == blank %}blank{% endif %}");
    // `and`/`or` group from the right in Liquid: true and (false or true).
    try expectLiquid("liquid", "{% if true and false or true %}liquid{% endif %}");
    try expectLiquid("", "{% if false and false or true %}x{% endif %}");
    try expectRender("mortise", "{% if false and false or true %}mortise{% endif %}");
    try expectLiquid("ok", "{% unless page.draft %}ok{% endunless %}");
    try expectLiquid("b", "{% unless page.count == 3 %}a{% elsif page.title %}b{% endunless %}");
}

test "liquid case" {
    try expectLiquid("three", "{% case page.count %}{% when 1 %}one{% when 2, 3 %}three{% else %}other{% endcase %}");
    try expectLiquid("other", "{% case page.title %}{% when \"a\" or \"b\" %}ab{% else %}other{% endcase %}");
    try expectLiquid("xx", "{% case 1 %}{% when 1, 1 %}x{% endcase %}");
    try expectRender("x", "{% case 1 %}{% when 1, 1 %}x{% endcase %}");
}

test "liquid variables" {
    try expectLiquid("Hi there|5", "{% assign greeting = \"Hi\" | append: \" there\" %}{{ greeting }}|{% assign n = 2 | plus: 3 %}{{ n }}");
    try expectLiquid("[Second & more]", "{% capture t %}[{{ posts[1].title }}]{% endcapture %}{{ t }}");
    try expectRender("[Second &amp; more]", "{% capture t %}[{{ posts[1].title }}]{% endcapture %}{{ t }}");
    try expectLiquid("0 1 2 -1 -2 3", "{% increment c %} {% increment c %} {% increment c %} {% decrement d %} {% decrement d %} {{ c }}");
    try expectLiquid("10 0 10", "{% assign x = 10 %}{{ x }} {% increment x %} {{ x }}");
    // Assignments made in a loop outlive it.
    try expectLiquid("web", "{% for t in page.tags %}{% assign last = t %}{% endfor %}{{ last }}");
    try expectLiquid("Second & more web 2 zig", "{{ posts[-1].title }} {{ page.tags[1] }} {{ page.tags.size }} {{ page.tags.first }}");
    try expectLiquid("/a/", "{% assign key = \"url\" %}{{ posts[0][key] }}");
}

test "liquid loops" {
    try expectLiquid("1/3 2/2 3/1 ", "{% for i in (1..3) %}{{ forloop.index }}/{{ forloop.rindex }} {% endfor %}");
    try expectLiquid("3 2 ", "{% for i in (1..5) offset: 1 limit: 2 reversed %}{{ i }} {% endfor %}");
    try expectLiquid("12|34|5", "{% for i in (1..5) limit: 2 %}{{ i }}{% endfor %}|{% for i in (1..5) limit: 2 offset: continue %}{{ i }}{% endfor %}|{% for i in (1..5) offset: continue %}{{ i }}{% endfor %}");
    try expectLiquid("none", "{% for i in empty %}x{% else %}none{% endfor %}");
    try expectLiquid("1 2 4 ", "{% for i in (1..10) %}{% if i == 3 %}{% continue %}{% endif %}{% if i > 4 %}{% break %}{% endif %}{{ i }} {% endfor %}");
    try expectLiquid("a.1 b.2 ", "{% for o in (1..2) %}{% for i in (1..1) %}{% cycle 'a', 'b' %}.{{ forloop.parentloop.index }} {% endfor %}{% endfor %}");
    try expectLiquid("odd even odd ", "{% for i in (1..3) %}{% cycle \"g\": \"odd\", \"even\" %} {% endfor %}");
    try expectLiquid("title=First url=/a/ ", "{% for pair in posts[0] %}{{ pair[0] }}={{ pair[1] }} {% endfor %}");
    try expectLiquid("i-(1..2)", "{% for i in (1..2) %}{% if forloop.last %}{{ forloop.name }}{% endif %}{% endfor %}");
    try expectLiquid("ab", "{% for x in \"ab\" %}{{ x }}{% endfor %}");
}

test "liquid tablerow" {
    try expectLiquid("<tr class=\"row1\">\n<td class=\"col1\">1</td><td class=\"col2\">2</td></tr>\n<tr class=\"row2\"><td class=\"col1\">3</td></tr>\n", "{% tablerow i in (1..3) cols: 2 %}{{ i }}{% endtablerow %}");
    try expectLiquid("<tr class=\"row1\">\n<td class=\"col1\">1:true</td><td class=\"col2\">2:false</td></tr>\n", "{% tablerow i in (1..2) %}{{ i }}:{{ tablerowloop.col_first }}{% endtablerow %}");
}

test "liquid raw, comments and the liquid tag" {
    try expectLiquid("{{ not parsed }} {% if %}", "{% raw %}{{ not parsed }} {% if %}{% endraw %}");
    try expectRender("{{ x }}", "{%- raw -%} {{ x }} {%- endraw -%}");
    try expectLiquid("ab", "a{% comment %} {{ broken {% comment %}nested{% endcomment %} {% endcomment %}b");
    try expectLiquid("ab", "a{% # inline comment %}b");
    try expectLiquid("a{# kept #}", "a{# kept #}");
    try expectLiquid("Hello, zig! web! ",
        \\{% liquid
        \\  # a comment line
        \\  assign who = "zig"
        \\  echo "Hello, " | append: who | append: "! "
        \\  for t in page.tags
        \\    if t != "zig"
        \\      echo t | append: "! "
        \\    endif
        \\  endfor
        \\%}
    );
}

test "liquid include and render" {
    // Jekyll: unquoted names and `include.` arguments.
    try expectLiquid("[First|2]", "{% include jekyll.html title=posts[0].title n=2 %}");
    try expectLiquid("[x|]", "{% assign f = \"jekyll\" %}{% include {{ f }}.html title='x' %}");
    // Shopify: `with`, `for` and `name: value`.
    try expectLiquid("<First>", "{% include 'product' with posts[0] %}");
    try expectLiquid("<First><Second & more>", "{% include 'product' for posts %}");
    try expectLiquid("<First>", "{% include 'product', product: posts[0] %}");
    // `render` sees only its arguments and the page, not assignments.
    try expectLiquid("T||3", "{% assign outer = 'o' %}{% render 'isolated', title: 'T' %}");
    try expectLiquid("<First><Second & more>", "{% render 'product' for posts as product %}");
    // `include` shares assignments; `render` does not.
    try expectLiquid("set", "{% include 'setter' %}{{ from_include }}");
    try expectLiquid("", "{% render 'setter' %}{{ from_include }}");
    try expectLiquid("relative 3", "{% include_relative notes.md %}");
    // A break inside an include ends the loop around it.
    try expectLiquid("1", "{% for i in (1..3) %}{{ i }}{% include 'breaker' %}{% endfor %}");
}

test "liquid highlight" {
    try expectLiquid("<figure class=\"highlight\"><pre><code class=\"language-c-\" data-lang=\"c+\">a &lt; b</code></pre></figure>", "{% highlight c+ %}\na < b\n{% endhighlight %}");
    try expectRender("<figure class=\"highlight\"><pre><code class=\"language-text\" data-lang=\"text\">&lt;Hello&gt;</code></pre></figure>", "{% highlight text %}{{ page.title }}{% endhighlight %}");
    try expectLiquid("<figure class=\"highlight\"><pre><code class=\"language-text\" data-lang=\"text\"><table class=\"rouge-table\"><tbody><tr><td class=\"gutter gl\"><pre class=\"lineno\">1\n2\n</pre></td><td class=\"code\"><pre>a\nb\n</pre></td></tr></tbody></table></code></pre></figure>", "{% highlight text linenos %}a\nb{% endhighlight %}");
}

test "HTML from includes and highlight survives Markdown through the stash" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diag: Diagnostic = .{};
    const tpl = try parseWith(a, "t.md", "Intro {% include product %} and {% include jekyll.html title='*md*' %}\n\n{% highlight text %}a < b{% endhighlight %}\n", .{ .liquid = true }, &diag);
    var tl: TestLoader = .{ .arena = a, .files = &test_files, .options = .{ .liquid = true } };
    var stash: std.ArrayList([]const u8) = .empty;
    const out = try renderAllocWith(a, &tpl, testRoot(), tl.loader(), .{ .liquid = true, .stash = &stash }, &diag);
    try testing.expectEqual(@as(usize, 2), stash.items.len);
    const html = try markdown.toHtml(a, out);
    try testing.expectEqualStrings("<p>Intro <> and [<em>md</em>|]</p>\n<figure class=\"highlight\"><pre><code class=\"language-text\" data-lang=\"text\">a &lt; b</code></pre></figure>\n", try restoreStashed(a, html, stash.items));
}

test "liquid errors" {
    try expectModeError(.liquid, "{{ 1 | divided_by: 0 }}", "main.html", 1, "divided by 0");
    try expectModeError(.liquid, "\n{% for i in (1..1000000) %}{% endfor %}", "main.html", 2, "longer than");
    try expectModeError(.liquid, "{% include_relative x.md %}", "main.html", 1, "was not found");
}
