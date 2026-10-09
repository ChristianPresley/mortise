//! Build-time syntax highlighting for fenced code blocks.
//!
//! A small lexer per language family marks keywords, literals, strings,
//! numbers, comments, and (for Zig) builtins with spans:
//!
//!   <span class="hl-keyword">const</span>
//!
//! Classes: hl-keyword, hl-literal, hl-string, hl-number, hl-comment,
//! hl-builtin. Mortise ships no stylesheet; sites style these classes.
//! Code in an unknown language is escaped and left unmarked.

const std = @import("std");
const Writer = std.Io.Writer;
const escapeHtml = @import("markdown.zig").escapeHtml;

const Lang = struct {
    keywords: []const []const u8,
    literals: []const []const u8 = &.{},
    line_comments: []const []const u8 = &.{},
    block_comment: ?[2][]const u8 = null,
    /// Quote characters that start strings.
    quotes: []const u8 = "\"'",
    /// `@name` builtins, as in Zig.
    at_builtins: bool = false,
    /// `\\` multiline string lines, as in Zig.
    zig_multiline: bool = false,
    /// Identifiers may contain `-`, as in shell words and YAML keys.
    dash_in_words: bool = false,
};

const c_like_comments = .{ .line_comments = &[_][]const u8{"//"}, .block_comment = [2][]const u8{ "/*", "*/" } };

const zig: Lang = .{
    .keywords = &.{ "addrspace", "align", "allowzero", "and", "anyframe", "anytype", "asm", "break", "callconv", "catch", "comptime", "const", "continue", "defer", "else", "enum", "errdefer", "error", "export", "extern", "fn", "for", "if", "inline", "linksection", "noalias", "noinline", "nosuspend", "opaque", "or", "orelse", "packed", "pub", "resume", "return", "struct", "suspend", "switch", "test", "threadlocal", "try", "union", "unreachable", "usingnamespace", "var", "volatile", "while" },
    .literals = &.{ "true", "false", "null", "undefined" },
    .line_comments = &.{"//"},
    .at_builtins = true,
    .zig_multiline = true,
};

const c: Lang = .{
    .keywords = &.{ "auto", "break", "case", "char", "const", "continue", "default", "do", "double", "else", "enum", "extern", "float", "for", "goto", "if", "inline", "int", "long", "register", "restrict", "return", "short", "signed", "sizeof", "static", "struct", "switch", "typedef", "union", "unsigned", "void", "volatile", "while", "bool", "class", "namespace", "template", "typename", "public", "private", "protected", "virtual", "new", "delete", "using", "constexpr", "auto", "#include", "#define", "#if", "#ifdef", "#ifndef", "#endif", "#else" },
    .literals = &.{ "true", "false", "NULL", "nullptr" },
    .line_comments = c_like_comments.line_comments,
    .block_comment = c_like_comments.block_comment,
};

const rust: Lang = .{
    .keywords = &.{ "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum", "extern", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod", "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super", "trait", "type", "unsafe", "use", "where", "while" },
    .literals = &.{ "true", "false", "None", "Some", "Ok", "Err" },
    .line_comments = c_like_comments.line_comments,
    .block_comment = c_like_comments.block_comment,
    .quotes = "\"",
};

const go: Lang = .{
    .keywords = &.{ "break", "case", "chan", "const", "continue", "default", "defer", "else", "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map", "package", "range", "return", "select", "struct", "switch", "type", "var" },
    .literals = &.{ "true", "false", "nil", "iota" },
    .line_comments = c_like_comments.line_comments,
    .block_comment = c_like_comments.block_comment,
    .quotes = "\"'`",
};

const js: Lang = .{
    .keywords = &.{ "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "export", "extends", "finally", "for", "from", "function", "if", "import", "in", "instanceof", "interface", "let", "new", "of", "return", "static", "super", "switch", "this", "throw", "try", "type", "typeof", "var", "void", "while", "yield" },
    .literals = &.{ "true", "false", "null", "undefined", "NaN", "Infinity" },
    .line_comments = c_like_comments.line_comments,
    .block_comment = c_like_comments.block_comment,
    .quotes = "\"'`",
};

const python: Lang = .{
    .keywords = &.{ "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del", "elif", "else", "except", "finally", "for", "from", "global", "if", "import", "in", "is", "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try", "while", "with", "yield" },
    .literals = &.{ "True", "False", "None" },
    .line_comments = &.{"#"},
};

const shell: Lang = .{
    .keywords = &.{ "if", "then", "else", "elif", "fi", "for", "while", "until", "do", "done", "case", "esac", "in", "function", "return", "local", "export", "readonly" },
    .literals = &.{ "true", "false" },
    .line_comments = &.{"#"},
    .dash_in_words = true,
};

const json: Lang = .{
    .keywords = &.{},
    .literals = &.{ "true", "false", "null" },
    .quotes = "\"",
};

const yaml: Lang = .{
    .keywords = &.{},
    .literals = &.{ "true", "false", "null", "yes", "no", "on", "off", "~" },
    .line_comments = &.{"#"},
    .dash_in_words = true,
};

/// The language for a code block's info word, or null if unsupported.
fn langFor(info: []const u8) ?*const Lang {
    const table = [_]struct { []const u8, *const Lang }{
        .{ "zig", &zig },
        .{ "c", &c },        .{ "h", &c },          .{ "cpp", &c },       .{ "c++", &c },       .{ "cc", &c },
        .{ "rust", &rust },  .{ "rs", &rust },
        .{ "go", &go },
        .{ "js", &js },      .{ "javascript", &js }, .{ "ts", &js },       .{ "typescript", &js }, .{ "jsx", &js }, .{ "tsx", &js },
        .{ "python", &python }, .{ "py", &python },
        .{ "sh", &shell },   .{ "bash", &shell },   .{ "shell", &shell }, .{ "zsh", &shell },
        .{ "json", &json },
        .{ "yaml", &yaml },  .{ "yml", &yaml },
    };
    for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(info, entry[0])) return entry[1];
    }
    return null;
}

/// Whether `info` names a language this module highlights.
pub fn supports(info: []const u8) bool {
    return langFor(info) != null;
}

/// Writes `code` escaped for HTML, with spans marking tokens when the
/// language named by `info` is supported.
pub fn write(w: *Writer, info: []const u8, code: []const u8) Writer.Error!void {
    const lang = langFor(info) orelse return escapeHtml(w, code);
    var i: usize = 0;
    var plain_start: usize = 0;
    while (i < code.len) {
        const tok = nextToken(lang, code, i) orelse {
            i += 1;
            continue;
        };
        try escapeHtml(w, code[plain_start..i]);
        if (tok.class) |class| {
            try w.print("<span class=\"hl-{s}\">", .{class});
            try escapeHtml(w, code[i..tok.end]);
            try w.writeAll("</span>");
        } else {
            try escapeHtml(w, code[i..tok.end]);
        }
        i = tok.end;
        plain_start = i;
    }
    try escapeHtml(w, code[plain_start..]);
}

const Token = struct { end: usize, class: ?[]const u8 };

/// Recognizes a token starting at `code[i]`, or returns null to treat the
/// byte as plain text.
fn nextToken(lang: *const Lang, code: []const u8, i: usize) ?Token {
    const rest = code[i..];
    for (lang.line_comments) |prefix| {
        // `#` in shell and YAML only starts a comment at a word boundary.
        if (std.mem.startsWith(u8, rest, prefix) and (prefix[0] != '#' or i == 0 or isSpace(code[i - 1]))) {
            return .{ .end = lineEnd(code, i), .class = "comment" };
        }
    }
    if (lang.block_comment) |bc| {
        if (std.mem.startsWith(u8, rest, bc[0])) {
            const close = std.mem.indexOfPos(u8, code, i + bc[0].len, bc[1]);
            return .{ .end = if (close) |cl| cl + bc[1].len else code.len, .class = "comment" };
        }
    }
    if (lang.zig_multiline and std.mem.startsWith(u8, rest, "\\\\")) {
        return .{ .end = lineEnd(code, i), .class = "string" };
    }
    const ch = code[i];
    if (std.mem.indexOfScalar(u8, lang.quotes, ch) != null) {
        return .{ .end = stringEnd(code, i), .class = "string" };
    }
    if (lang.at_builtins and ch == '@' and i + 1 < code.len and std.ascii.isAlphabetic(code[i + 1])) {
        return .{ .end = wordEnd(lang, code, i + 1), .class = "builtin" };
    }
    if (std.ascii.isDigit(ch) and (i == 0 or !isWordChar(lang, code[i - 1]))) {
        var end = i + 1;
        while (end < code.len and (std.ascii.isAlphanumeric(code[end]) or code[end] == '_' or code[end] == '.')) end += 1;
        return .{ .end = end, .class = "number" };
    }
    if (isWordStart(ch) and (i == 0 or !isWordChar(lang, code[i - 1]))) {
        const end = wordEnd(lang, code, i);
        const word = code[i..end];
        const class: ?[]const u8 = if (contains(lang.keywords, word))
            "keyword"
        else if (contains(lang.literals, word))
            "literal"
        else
            null;
        return .{ .end = end, .class = class };
    }
    if (ch == '#' and contains(lang.keywords, code[i..wordEnd(lang, code, i + 1)])) {
        return .{ .end = wordEnd(lang, code, i + 1), .class = "keyword" };
    }
    if (ch == '~' and contains(lang.literals, "~") and (i + 1 == code.len or isSpace(code[i + 1]))) {
        return .{ .end = i + 1, .class = "literal" };
    }
    return null;
}

fn contains(list: []const []const u8, word: []const u8) bool {
    for (list) |w| if (std.mem.eql(u8, w, word)) return true;
    return false;
}

fn isSpace(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
}

fn isWordStart(ch: u8) bool {
    return std.ascii.isAlphabetic(ch) or ch == '_' or ch == '$';
}

fn isWordChar(lang: *const Lang, ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '$' or (lang.dash_in_words and ch == '-');
}

fn wordEnd(lang: *const Lang, code: []const u8, start: usize) usize {
    var end = start;
    while (end < code.len and isWordChar(lang, code[end])) end += 1;
    return end;
}

fn lineEnd(code: []const u8, start: usize) usize {
    return std.mem.indexOfScalarPos(u8, code, start, '\n') orelse code.len;
}

/// End of the string starting with the quote at `code[start]`. Strings end
/// at the matching quote, honoring backslash escapes, or at the end of the
/// line for an unterminated string (except backtick strings, which may
/// span lines).
fn stringEnd(code: []const u8, start: usize) usize {
    const q = code[start];
    var i = start + 1;
    while (i < code.len) : (i += 1) {
        if (code[i] == '\\') {
            i += 1;
            continue;
        }
        if (code[i] == q) return i + 1;
        if (code[i] == '\n' and q != '`') return i;
    }
    return code.len;
}

const testing = std.testing;

fn expectHighlight(expected: []const u8, info: []const u8, code: []const u8) !void {
    var buf: [1024]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try write(&w, info, code);
    try testing.expectEqualStrings(expected, w.buffered());
}

test "zig" {
    try expectHighlight(
        "<span class=\"hl-keyword\">const</span> x = <span class=\"hl-builtin\">@import</span>(<span class=\"hl-string\">&quot;std&quot;</span>); <span class=\"hl-comment\">// hi &lt;3</span>",
        "zig",
        "const x = @import(\"std\"); // hi <3",
    );
    try expectHighlight(
        "<span class=\"hl-keyword\">return</span> <span class=\"hl-number\">0x1F</span> <span class=\"hl-keyword\">orelse</span> <span class=\"hl-literal\">null</span>",
        "Zig",
        "return 0x1F orelse null",
    );
    try expectHighlight("<span class=\"hl-string\">\\\\ multi</span>\n", "zig", "\\\\ multi\n");
}

test "identifiers containing keywords are not split" {
    try expectHighlight("constant iffy x1 var_if", "zig", "constant iffy x1 var_if");
}

test "other languages" {
    try expectHighlight("<span class=\"hl-keyword\">def</span> f(): <span class=\"hl-keyword\">return</span> <span class=\"hl-literal\">None</span>  <span class=\"hl-comment\"># c</span>", "py", "def f(): return None  # c");
    try expectHighlight("echo a#b <span class=\"hl-comment\"># c</span>", "sh", "echo a#b # c");
    try expectHighlight("{<span class=\"hl-string\">&quot;a&quot;</span>: [<span class=\"hl-number\">1</span>, <span class=\"hl-literal\">true</span>]}", "json", "{\"a\": [1, true]}");
    try expectHighlight("<span class=\"hl-comment\">/* a\nb */</span> <span class=\"hl-keyword\">int</span> x;", "c", "/* a\nb */ int x;");
    try expectHighlight("<span class=\"hl-keyword\">#include</span> &lt;stdio.h&gt;", "c", "#include <stdio.h>");
}

test "unknown languages are only escaped" {
    try expectHighlight("const &lt;x&gt;", "brainfudge", "const <x>");
    try testing.expect(supports("ts") and !supports(""));
}
