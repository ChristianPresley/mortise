//! TeX math to MathML, for browsers to typeset without scripts or fonts.
//!
//! The supported subset covers what documentation and notes usually need:
//! letters, numbers and operators; `^` and `_`; `\frac`, `\dfrac`, `\binom`,
//! `\sqrt[n]{}`; Greek letters; relations, arrows and other symbols; big
//! operators (`\sum`, `\int`, ...) with limits; functions (`\sin`, `\lim`,
//! `\operatorname{}`); `\text{}` and font commands (`\mathbf`, `\mathbb`,
//! `\mathcal`, ...); accents (`\hat`, `\vec`, `\overline`, ...);
//! `\left ... \right`; spaces (`\,`, `\quad`); and the environments
//! `matrix`, `pmatrix`, `bmatrix`, `Bmatrix`, `vmatrix`, `Vmatrix`,
//! `cases`, `aligned` and `array`. Anything else is an error naming the
//! command.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Diagnostic = struct { message: []const u8 = "" };
pub const Error = Allocator.Error || error{InvalidMath};

/// Writes `src` as a `<math>` element: a block for display math, inline
/// otherwise. The TeX source is kept as an annotation.
pub fn write(arena: Allocator, src: []const u8, display: bool, w: *Writer, diag: *Diagnostic) (Error || Writer.Error)!void {
    var p: Parser = .{ .arena = arena, .s = src, .diag = diag };
    const row = try p.row(.eof);
    try w.writeAll("<math xmlns=\"http://www.w3.org/1998/Math/MathML\"");
    if (display) try w.writeAll(" display=\"block\"");
    try w.writeAll("><semantics><mrow>");
    for (row) |a| {
        try w.writeAll(a.xml);
        try w.writeAll(a.after);
    }
    try w.writeAll("</mrow><annotation encoding=\"application/x-tex\">");
    try escape(w, std.mem.trim(u8, src, " \t\r\n"));
    try w.writeAll("</annotation></semantics></math>");
}

const Atom = struct {
    xml: []const u8,
    /// How `^` and `_` attach: as limits above and below in display style
    /// (`\sum`, `\lim`), always beside (`\int`), or normally.
    kind: enum { normal, big, limit } = .normal,
    /// Written after the atom and any scripts, such as the invisible
    /// function-application operator after `\sin`.
    after: []const u8 = "",
};

const Stop = enum { eof, brace, right, end, bracket };

const Parser = struct {
    arena: Allocator,
    s: []const u8,
    i: usize = 0,
    diag: *Diagnostic,
    /// The name of the environment being parsed, for `\end`.
    env_name: []const u8 = "",

    fn fail(p: *Parser, comptime fmt: []const u8, args: anytype) Error {
        p.diag.message = try std.fmt.allocPrint(p.arena, fmt, args);
        return error.InvalidMath;
    }

    fn print(p: *Parser, comptime fmt: []const u8, args: anytype) Allocator.Error![]const u8 {
        return std.fmt.allocPrint(p.arena, fmt, args);
    }

    fn skipSpace(p: *Parser) void {
        while (p.i < p.s.len and std.ascii.isWhitespace(p.s[p.i])) p.i += 1;
    }

    fn peek(p: *Parser) ?u8 {
        p.skipSpace();
        return if (p.i < p.s.len) p.s[p.i] else null;
    }

    /// A sequence of atoms up to `stop`, with scripts attached.
    fn row(p: *Parser, stop: Stop) Error![]Atom {
        var atoms: std.ArrayList(Atom) = .empty;
        while (true) {
            const c = p.peek() orelse {
                if (stop != .eof) return p.fail("missing {s}", .{switch (stop) {
                    .brace => "'}'",
                    .right => "\\right",
                    .end => "\\end",
                    .bracket => "']'",
                    .eof => unreachable,
                }});
                break;
            };
            switch (c) {
                '}' => {
                    if (stop == .brace) {
                        p.i += 1;
                        break;
                    }
                    return p.fail("unexpected '}}'", .{});
                },
                ']' => if (stop == .bracket) {
                    p.i += 1;
                    break;
                } else {
                    p.i += 1;
                    try atoms.append(p.arena, .{ .xml = "<mo>]</mo>" });
                },
                '^', '_' => try p.script(&atoms),
                '&' => {
                    if (stop != .end) return p.fail("'&' outside a matrix or aligned block", .{});
                    break;
                },
                '\\' => {
                    if (p.i + 1 < p.s.len and p.s[p.i + 1] == '\\') {
                        if (stop != .end) return p.fail("'\\\\' outside a matrix or aligned block", .{});
                        break;
                    }
                    const save = p.i;
                    const name = p.commandName();
                    if (std.mem.eql(u8, name, "right")) {
                        if (stop != .right) return p.fail("\\right without \\left", .{});
                        p.i = save;
                        break;
                    }
                    if (std.mem.eql(u8, name, "end")) {
                        if (stop != .end) return p.fail("\\end without \\begin", .{});
                        p.i = save;
                        break;
                    }
                    p.i = save;
                    try atoms.append(p.arena, try p.atom());
                },
                else => try atoms.append(p.arena, try p.atom()),
            }
        }
        return atoms.items;
    }

    /// Attaches `^` and `_` scripts to the last atom.
    fn script(p: *Parser, atoms: *std.ArrayList(Atom)) Error!void {
        const base: Atom = if (atoms.items.len > 0) atoms.pop().? else .{ .xml = "<mrow></mrow>" };
        var sub: ?[]const u8 = null;
        var sup: ?[]const u8 = null;
        while (p.peek()) |c| {
            if (c != '^' and c != '_') break;
            p.i += 1;
            const arg = try p.argument();
            if (c == '^') {
                if (sup != null) return p.fail("double superscript", .{});
                sup = arg;
            } else {
                if (sub != null) return p.fail("double subscript", .{});
                sub = arg;
            }
        }
        const under = base.kind == .big or base.kind == .limit;
        const xml = if (sub != null and sup != null)
            try p.print("<{s}>{s}{s}{s}</{s}>", .{ if (under) "munderover" else "msubsup", base.xml, sub.?, sup.?, if (under) "munderover" else "msubsup" })
        else if (sub) |s|
            try p.print("<{s}>{s}{s}</{s}>", .{ if (under) "munder" else "msub", base.xml, s, if (under) "munder" else "msub" })
        else
            try p.print("<{s}>{s}{s}</{s}>", .{ if (under) "mover" else "msup", base.xml, sup.?, if (under) "mover" else "msup" });
        try atoms.append(p.arena, .{ .xml = xml, .after = base.after });
    }

    /// One argument: a `{group}`, a command, or a single character.
    fn argument(p: *Parser) Error![]const u8 {
        const c = p.peek() orelse return p.fail("missing argument at the end", .{});
        if (c == '{') {
            p.i += 1;
            return p.group(try p.row(.brace));
        }
        if (c == '\\') {
            const a = try p.atom();
            return if (a.after.len == 0) a.xml else p.print("<mrow>{s}{s}</mrow>", .{ a.xml, a.after });
        }
        // A single character: one digit, letter or symbol, as TeX does.
        p.i += 1;
        return p.char(c);
    }

    fn group(p: *Parser, atoms: []const Atom) Allocator.Error![]const u8 {
        if (atoms.len == 1 and atoms[0].after.len == 0) return atoms[0].xml;
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(p.arena, "<mrow>");
        for (atoms) |a| {
            try out.appendSlice(p.arena, a.xml);
            try out.appendSlice(p.arena, a.after);
        }
        try out.appendSlice(p.arena, "</mrow>");
        return out.items;
    }

    /// A `{...}` argument's raw text, for `\text` and environment names.
    fn rawArgument(p: *Parser) Error![]const u8 {
        if (p.peek() != '{') return p.fail("expected '{{'", .{});
        p.i += 1;
        var depth: usize = 1;
        const start = p.i;
        while (p.i < p.s.len) : (p.i += 1) {
            switch (p.s[p.i]) {
                '{' => depth += 1,
                '}' => {
                    depth -= 1;
                    if (depth == 0) {
                        p.i += 1;
                        return p.s[start .. p.i - 1];
                    }
                },
                '\\' => p.i += 1,
                else => {},
            }
        }
        return p.fail("missing '}}'", .{});
    }

    fn char(p: *Parser, c: u8) Error![]const u8 {
        if (std.ascii.isDigit(c)) return p.print("<mn>{c}</mn>", .{c});
        if (std.ascii.isAlphabetic(c)) return p.print("<mi>{c}</mi>", .{c});
        return switch (c) {
            '<' => "<mo>&lt;</mo>",
            '>' => "<mo>&gt;</mo>",
            '+', '=', ',', ';', ':', '!', '?', '(', ')', '[', ']', '|', '/', '.' => p.print("<mo>{c}</mo>", .{c}),
            '-' => "<mo>\u{2212}</mo>",
            '*' => "<mo>\u{2217}</mo>",
            '\'' => "<mo>\u{2032}</mo>",
            else => if (c >= 0x80) p.print("<mi>{c}</mi>", .{c}) else p.fail("unexpected '{c}'", .{c}),
        };
    }

    /// The letters of a command after its backslash (or its one symbol).
    fn commandName(p: *Parser) []const u8 {
        p.i += 1; // the backslash
        const start = p.i;
        if (p.i < p.s.len and std.ascii.isAlphabetic(p.s[p.i])) {
            while (p.i < p.s.len and std.ascii.isAlphabetic(p.s[p.i])) p.i += 1;
        } else if (p.i < p.s.len) p.i += 1;
        return p.s[start..p.i];
    }

    fn atom(p: *Parser) Error!Atom {
        const c = p.peek().?;
        if (c == '{') {
            p.i += 1;
            return .{ .xml = try p.group(try p.row(.brace)) };
        }
        if (c != '\\') {
            // Numbers keep their digits and decimal point together.
            if (std.ascii.isDigit(c)) {
                const start = p.i;
                while (p.i < p.s.len and (std.ascii.isDigit(p.s[p.i]) or (p.s[p.i] == '.' and p.i + 1 < p.s.len and std.ascii.isDigit(p.s[p.i + 1])))) p.i += 1;
                return .{ .xml = try p.print("<mn>{s}</mn>", .{p.s[start..p.i]}) };
            }
            // A UTF-8 letter such as é stays whole.
            if (c >= 0x80) {
                const len = std.unicode.utf8ByteSequenceLength(c) catch 1;
                const end = @min(p.s.len, p.i + len);
                defer p.i = end;
                return .{ .xml = try p.print("<mi>{s}</mi>", .{p.s[p.i..end]}) };
            }
            p.i += 1;
            return .{ .xml = try p.char(c) };
        }
        return p.command();
    }

    fn command(p: *Parser) Error!Atom {
        const name = p.commandName();
        if (name.len == 0) return p.fail("'\\' at the end", .{});
        // Escaped symbols and spaces.
        if (name.len == 1 and !std.ascii.isAlphabetic(name[0])) {
            return .{ .xml = switch (name[0]) {
                ',' => "<mspace width=\"0.1667em\"></mspace>",
                ':', '>' => "<mspace width=\"0.2222em\"></mspace>",
                ';' => "<mspace width=\"0.2778em\"></mspace>",
                ' ' => "<mspace width=\"0.25em\"></mspace>",
                '!' => "<mspace width=\"-0.1667em\"></mspace>",
                '{' => "<mo>{</mo>",
                '}' => "<mo>}</mo>",
                '|' => "<mo>\u{2016}</mo>",
                '%', '$', '#', '_' => try p.print("<mi>{c}</mi>", .{name[0]}),
                '&' => "<mi>&amp;</mi>",
                else => return p.fail("unknown command '\\{s}'", .{name}),
            } };
        }
        if (lookup(&greek, name)) |g| {
            // Capital Greek is upright, as in TeX.
            return .{ .xml = if (std.ascii.isUpper(name[0])) try p.print("<mi mathvariant=\"normal\">{s}</mi>", .{g}) else try p.print("<mi>{s}</mi>", .{g}) };
        }
        if (lookup(&symbols, name)) |s| return .{ .xml = try p.print("<mo>{s}</mo>", .{s}) };
        if (lookup(&identifiers, name)) |s| return .{ .xml = try p.print("<mi>{s}</mi>", .{s}) };
        if (lookup(&big_operators, name)) |s| {
            const integral = std.mem.indexOf(u8, name, "int") != null;
            return .{ .xml = try p.print("<mo largeop=\"true\" movablelimits=\"{s}\">{s}</mo>", .{ if (integral) "false" else "true", s }), .kind = if (integral) .normal else .big };
        }
        for (functions) |f| if (std.mem.eql(u8, f, name)) {
            const limit = for (limit_functions) |l| {
                if (std.mem.eql(u8, l, name)) break true;
            } else false;
            return .{ .xml = try p.print("<mi>{s}</mi>", .{name}), .after = "<mo>\u{2061}</mo>", .kind = if (limit) .limit else .normal };
        };
        if (std.mem.eql(u8, name, "operatorname")) {
            const text = try p.rawArgument();
            return .{ .xml = try p.print("<mi>{s}</mi>", .{try escapeAlloc(p.arena, text)}), .after = "<mo>\u{2061}</mo>" };
        }
        if (std.mem.eql(u8, name, "frac") or std.mem.eql(u8, name, "dfrac") or std.mem.eql(u8, name, "tfrac")) {
            const num = try p.argument();
            const den = try p.argument();
            return .{ .xml = try p.print("<mfrac>{s}{s}</mfrac>", .{ num, den }) };
        }
        if (std.mem.eql(u8, name, "binom")) {
            const n = try p.argument();
            const k = try p.argument();
            return .{ .xml = try p.print("<mrow><mo>(</mo><mfrac linethickness=\"0\">{s}{s}</mfrac><mo>)</mo></mrow>", .{ n, k }) };
        }
        if (std.mem.eql(u8, name, "sqrt")) {
            if (p.peek() == '[') {
                p.i += 1;
                const index = try p.group(try p.row(.bracket));
                return .{ .xml = try p.print("<mroot>{s}{s}</mroot>", .{ try p.argument(), index }) };
            }
            return .{ .xml = try p.print("<msqrt>{s}</msqrt>", .{try p.argument()}) };
        }
        if (std.mem.eql(u8, name, "text") or std.mem.eql(u8, name, "textrm") or std.mem.eql(u8, name, "mbox")) {
            return .{ .xml = try p.print("<mtext>{s}</mtext>", .{try escapeAlloc(p.arena, try p.rawArgument())}) };
        }
        for (fonts) |f| if (std.mem.eql(u8, f[0], name)) {
            return .{ .xml = try p.print("<mstyle mathvariant=\"{s}\">{s}</mstyle>", .{ f[1], try p.argument() }) };
        };
        for (accents) |a| if (std.mem.eql(u8, a[0], name)) {
            const base = try p.argument();
            if (std.mem.eql(u8, name, "underline")) return .{ .xml = try p.print("<munder accentunder=\"true\">{s}<mo>{s}</mo></munder>", .{ base, a[1] }) };
            return .{ .xml = try p.print("<mover accent=\"true\">{s}<mo>{s}</mo></mover>", .{ base, a[1] }) };
        };
        if (std.mem.eql(u8, name, "left")) {
            const open = try p.delimiter();
            const inner = try p.row(.right);
            _ = p.commandName(); // \right
            const close = try p.delimiter();
            var out: std.ArrayList(u8) = .empty;
            try out.print(p.arena, "<mrow><mo fence=\"true\" stretchy=\"true\">{s}</mo>", .{open});
            for (inner) |a| {
                try out.appendSlice(p.arena, a.xml);
                try out.appendSlice(p.arena, a.after);
            }
            try out.print(p.arena, "<mo fence=\"true\" stretchy=\"true\">{s}</mo></mrow>", .{close});
            return .{ .xml = out.items };
        }
        if (std.mem.eql(u8, name, "begin")) return .{ .xml = try p.environment() };
        if (std.mem.eql(u8, name, "quad")) return .{ .xml = "<mspace width=\"1em\"></mspace>" };
        if (std.mem.eql(u8, name, "qquad")) return .{ .xml = "<mspace width=\"2em\"></mspace>" };
        return p.fail("unknown command '\\{s}'", .{name});
    }

    /// The delimiter after `\left` or `\right`: a character, an escaped
    /// brace, or a named one; `.` is none.
    fn delimiter(p: *Parser) Error![]const u8 {
        const c = p.peek() orelse return p.fail("missing delimiter after \\left or \\right", .{});
        if (c == '.') {
            p.i += 1;
            return "";
        }
        if (c == '\\') {
            const name = p.commandName();
            if (name.len == 1) return switch (name[0]) {
                '{' => "{",
                '}' => "}",
                '|' => "\u{2016}",
                else => p.fail("unknown delimiter '\\{s}'", .{name}),
            };
            if (lookup(&delimiters, name)) |d| return d;
            return p.fail("unknown delimiter '\\{s}'", .{name});
        }
        p.i += 1;
        return switch (c) {
            '(', ')', '[', ']', '|', '/' => p.print("{c}", .{c}),
            '<' => "\u{27e8}",
            '>' => "\u{27e9}",
            else => p.fail("unknown delimiter '{c}'", .{c}),
        };
    }

    /// `\begin{NAME} ... \end{NAME}`: rows separated by `\\`, cells by `&`.
    fn environment(p: *Parser) Error![]const u8 {
        const name = try p.rawArgument();
        const Fence = struct { []const u8, []const u8 };
        const fence: ?Fence = if (std.mem.eql(u8, name, "pmatrix")) .{ "(", ")" } else if (std.mem.eql(u8, name, "bmatrix")) .{ "[", "]" } else if (std.mem.eql(u8, name, "Bmatrix")) .{ "{", "}" } else if (std.mem.eql(u8, name, "vmatrix")) .{ "|", "|" } else if (std.mem.eql(u8, name, "Vmatrix")) .{ "\u{2016}", "\u{2016}" } else if (std.mem.eql(u8, name, "cases")) .{ "{", "" } else null;
        const known = fence != null or std.mem.eql(u8, name, "matrix") or std.mem.eql(u8, name, "aligned") or std.mem.eql(u8, name, "align") or std.mem.eql(u8, name, "array");
        if (!known) return p.fail("unknown environment '{s}'", .{name});
        // `array` takes a column spec, which only says how to align.
        if (std.mem.eql(u8, name, "array")) _ = try p.rawArgument();
        const aligned = std.mem.eql(u8, name, "aligned") or std.mem.eql(u8, name, "align");
        const left = std.mem.eql(u8, name, "cases");

        var out: std.ArrayList(u8) = .empty;
        if (fence) |f| try out.print(p.arena, "<mrow><mo fence=\"true\" stretchy=\"true\">{s}</mo>", .{f[0]});
        try out.appendSlice(p.arena, if (aligned) "<mtable displaystyle=\"true\" columnalign=\"right left\" columnspacing=\"0\">" else if (left) "<mtable columnalign=\"left left\">" else "<mtable>");
        var row_open = false;
        while (true) {
            if (!row_open) {
                try out.appendSlice(p.arena, "<mtr>");
                row_open = true;
            }
            const cell = try p.row(.end);
            try out.appendSlice(p.arena, "<mtd>");
            for (cell) |a| {
                try out.appendSlice(p.arena, a.xml);
                try out.appendSlice(p.arena, a.after);
            }
            try out.appendSlice(p.arena, "</mtd>");
            const c = p.peek() orelse return p.fail("missing \\end{{{s}}}", .{name});
            if (c == '&') {
                p.i += 1;
                continue;
            }
            // `\\` ends a row; `\end` ends the environment. A `\\` just
            // before `\end` adds no empty row.
            if (std.mem.eql(u8, p.commandName(), "\\")) {
                try out.appendSlice(p.arena, "</mtr>");
                row_open = false;
                const after = p.i;
                if (p.peek() != '\\' or !std.mem.eql(u8, p.commandName(), "end")) {
                    p.i = after;
                    continue;
                }
            }
            const end_name = try p.rawArgument();
            if (!std.mem.eql(u8, end_name, name)) return p.fail("\\begin{{{s}}} ends with \\end{{{s}}}", .{ name, end_name });
            break;
        }
        if (row_open) try out.appendSlice(p.arena, "</mtr>");
        try out.appendSlice(p.arena, "</mtable>");
        if (fence) |f| try out.print(p.arena, "<mo fence=\"true\" stretchy=\"true\">{s}</mo></mrow>", .{f[1]});
        return out.items;
    }
};

const Pair = struct { []const u8, []const u8 };

fn lookup(table: []const Pair, name: []const u8) ?[]const u8 {
    for (table) |e| if (std.mem.eql(u8, e[0], name)) return e[1];
    return null;
}

fn escape(w: *Writer, s: []const u8) Writer.Error!void {
    for (s) |c| switch (c) {
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '&' => try w.writeAll("&amp;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(c),
    };
}

fn escapeAlloc(arena: Allocator, s: []const u8) Allocator.Error![]const u8 {
    var aw: Writer.Allocating = .init(arena);
    escape(&aw.writer, s) catch return error.OutOfMemory;
    return aw.written();
}

const greek = [_]Pair{
    .{ "alpha", "\u{3b1}" },   .{ "beta", "\u{3b2}" },     .{ "gamma", "\u{3b3}" },   .{ "delta", "\u{3b4}" },
    .{ "epsilon", "\u{3f5}" }, .{ "varepsilon", "\u{3b5}" }, .{ "zeta", "\u{3b6}" },  .{ "eta", "\u{3b7}" },
    .{ "theta", "\u{3b8}" },   .{ "vartheta", "\u{3d1}" }, .{ "iota", "\u{3b9}" },    .{ "kappa", "\u{3ba}" },
    .{ "lambda", "\u{3bb}" },  .{ "mu", "\u{3bc}" },       .{ "nu", "\u{3bd}" },      .{ "xi", "\u{3be}" },
    .{ "pi", "\u{3c0}" },      .{ "varpi", "\u{3d6}" },    .{ "rho", "\u{3c1}" },     .{ "varrho", "\u{3f1}" },
    .{ "sigma", "\u{3c3}" },   .{ "varsigma", "\u{3c2}" }, .{ "tau", "\u{3c4}" },     .{ "upsilon", "\u{3c5}" },
    .{ "phi", "\u{3d5}" },     .{ "varphi", "\u{3c6}" },   .{ "chi", "\u{3c7}" },     .{ "psi", "\u{3c8}" },
    .{ "omega", "\u{3c9}" },   .{ "Gamma", "\u{393}" },    .{ "Delta", "\u{394}" },   .{ "Theta", "\u{398}" },
    .{ "Lambda", "\u{39b}" },  .{ "Xi", "\u{39e}" },       .{ "Pi", "\u{3a0}" },      .{ "Sigma", "\u{3a3}" },
    .{ "Upsilon", "\u{3a5}" }, .{ "Phi", "\u{3a6}" },      .{ "Psi", "\u{3a8}" },     .{ "Omega", "\u{3a9}" },
};

/// Letter-like symbols written as identifiers.
const identifiers = [_]Pair{
    .{ "infty", "\u{221e}" }, .{ "partial", "\u{2202}" }, .{ "nabla", "\u{2207}" }, .{ "ell", "\u{2113}" },
    .{ "hbar", "\u{210f}" },  .{ "emptyset", "\u{2205}" }, .{ "varnothing", "\u{2205}" }, .{ "aleph", "\u{2135}" },
    .{ "Re", "\u{211c}" },    .{ "Im", "\u{2111}" },      .{ "wp", "\u{2118}" },
};

const symbols = [_]Pair{
    .{ "pm", "\u{b1}" },          .{ "mp", "\u{2213}" },        .{ "times", "\u{d7}" },        .{ "div", "\u{f7}" },
    .{ "cdot", "\u{22c5}" },      .{ "ast", "\u{2217}" },       .{ "star", "\u{22c6}" },       .{ "circ", "\u{2218}" },
    .{ "bullet", "\u{2219}" },    .{ "oplus", "\u{2295}" },     .{ "otimes", "\u{2297}" },     .{ "cup", "\u{222a}" },
    .{ "cap", "\u{2229}" },       .{ "setminus", "\u{2216}" },  .{ "wedge", "\u{2227}" },      .{ "land", "\u{2227}" },
    .{ "vee", "\u{2228}" },       .{ "lor", "\u{2228}" },       .{ "neg", "\u{ac}" },          .{ "lnot", "\u{ac}" },
    .{ "leq", "\u{2264}" },       .{ "le", "\u{2264}" },        .{ "geq", "\u{2265}" },        .{ "ge", "\u{2265}" },
    .{ "neq", "\u{2260}" },       .{ "ne", "\u{2260}" },        .{ "approx", "\u{2248}" },     .{ "equiv", "\u{2261}" },
    .{ "sim", "\u{223c}" },       .{ "simeq", "\u{2243}" },     .{ "cong", "\u{2245}" },       .{ "propto", "\u{221d}" },
    .{ "ll", "\u{226a}" },        .{ "gg", "\u{226b}" },        .{ "prec", "\u{227a}" },       .{ "succ", "\u{227b}" },
    .{ "in", "\u{2208}" },        .{ "notin", "\u{2209}" },     .{ "ni", "\u{220b}" },         .{ "subset", "\u{2282}" },
    .{ "supset", "\u{2283}" },    .{ "subseteq", "\u{2286}" },  .{ "supseteq", "\u{2287}" },   .{ "mid", "\u{2223}" },
    .{ "parallel", "\u{2225}" },  .{ "perp", "\u{22a5}" },      .{ "to", "\u{2192}" },         .{ "rightarrow", "\u{2192}" },
    .{ "leftarrow", "\u{2190}" }, .{ "gets", "\u{2190}" },      .{ "leftrightarrow", "\u{2194}" }, .{ "Rightarrow", "\u{21d2}" },
    .{ "Leftarrow", "\u{21d0}" }, .{ "Leftrightarrow", "\u{21d4}" }, .{ "implies", "\u{27f9}" }, .{ "iff", "\u{27fa}" },
    .{ "mapsto", "\u{21a6}" },    .{ "uparrow", "\u{2191}" },   .{ "downarrow", "\u{2193}" },  .{ "longrightarrow", "\u{27f6}" },
    .{ "forall", "\u{2200}" },    .{ "exists", "\u{2203}" },    .{ "nexists", "\u{2204}" },    .{ "therefore", "\u{2234}" },
    .{ "because", "\u{2235}" },   .{ "ldots", "\u{2026}" },     .{ "dots", "\u{2026}" },       .{ "cdots", "\u{22ef}" },
    .{ "vdots", "\u{22ee}" },     .{ "ddots", "\u{22f1}" },     .{ "angle", "\u{2220}" },      .{ "triangle", "\u{25b3}" },
    .{ "langle", "\u{27e8}" },    .{ "rangle", "\u{27e9}" },    .{ "lfloor", "\u{230a}" },     .{ "rfloor", "\u{230b}" },
    .{ "lceil", "\u{2308}" },     .{ "rceil", "\u{2309}" },     .{ "vert", "|" },              .{ "Vert", "\u{2016}" },
    .{ "colon", ":" },            .{ "prime", "\u{2032}" },     .{ "degree", "\u{b0}" },
};

const delimiters = [_]Pair{
    .{ "langle", "\u{27e8}" }, .{ "rangle", "\u{27e9}" }, .{ "lfloor", "\u{230a}" }, .{ "rfloor", "\u{230b}" },
    .{ "lceil", "\u{2308}" },  .{ "rceil", "\u{2309}" },  .{ "vert", "|" },          .{ "Vert", "\u{2016}" },
    .{ "lbrace", "{" },        .{ "rbrace", "}" },
};

const big_operators = [_]Pair{
    .{ "sum", "\u{2211}" },     .{ "prod", "\u{220f}" },   .{ "coprod", "\u{2210}" }, .{ "int", "\u{222b}" },
    .{ "iint", "\u{222c}" },    .{ "iiint", "\u{222d}" },  .{ "oint", "\u{222e}" },   .{ "bigcup", "\u{22c3}" },
    .{ "bigcap", "\u{22c2}" },  .{ "bigoplus", "\u{2a01}" }, .{ "bigotimes", "\u{2a02}" }, .{ "bigvee", "\u{22c1}" },
    .{ "bigwedge", "\u{22c0}" },
};

const functions = [_][]const u8{
    "sin", "cos", "tan", "cot", "sec", "csc", "arcsin", "arccos", "arctan", "sinh", "cosh", "tanh", "coth",
    "log", "ln", "lg", "exp", "lim", "liminf", "limsup", "max", "min", "sup", "inf", "det", "gcd", "deg",
    "dim", "ker", "arg", "hom", "Pr", "mod",
};

/// Functions whose subscripts go underneath in display math.
const limit_functions = [_][]const u8{ "lim", "liminf", "limsup", "max", "min", "sup", "inf", "det", "gcd", "Pr" };

const fonts = [_]Pair{
    .{ "mathbf", "bold" },         .{ "boldsymbol", "bold-italic" }, .{ "mathit", "italic" },
    .{ "mathrm", "normal" },       .{ "mathbb", "double-struck" },   .{ "mathcal", "script" },
    .{ "mathscr", "script" },      .{ "mathfrak", "fraktur" },       .{ "mathsf", "sans-serif" },
    .{ "mathtt", "monospace" },
};

const accents = [_]Pair{
    .{ "hat", "^" },        .{ "widehat", "^" },       .{ "bar", "\u{af}" },  .{ "overline", "\u{af}" },
    .{ "vec", "\u{2192}" }, .{ "overrightarrow", "\u{2192}" }, .{ "tilde", "~" }, .{ "widetilde", "~" },
    .{ "dot", "\u{2d9}" },  .{ "ddot", "\u{a8}" },     .{ "check", "\u{2c7}" }, .{ "breve", "\u{2d8}" },
    .{ "underline", "\u{af}" },
};

const testing = std.testing;

fn mathml(src: []const u8, display: bool) ![]const u8 {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    errdefer arena_state.deinit();
    var aw: Writer.Allocating = .init(testing.allocator);
    var diag: Diagnostic = .{};
    write(arena_state.allocator(), src, display, &aw.writer, &diag) catch |err| {
        std.debug.print("math error: {s}\n", .{diag.message});
        aw.deinit();
        return err;
    };
    arena_state.deinit();
    return aw.toOwnedSlice();
}

fn expectBody(src: []const u8, body: []const u8) !void {
    const out = try mathml(src, false);
    defer testing.allocator.free(out);
    const start = std.mem.indexOf(u8, out, "<semantics><mrow>").? + "<semantics><mrow>".len;
    const end = std.mem.indexOf(u8, out, "</mrow><annotation").?;
    try testing.expectEqualStrings(body, out[start..end]);
}

test "scripts, fractions and roots" {
    try expectBody("x^2 + y_1", "<msup><mi>x</mi><mn>2</mn></msup><mo>+</mo><msub><mi>y</mi><mn>1</mn></msub>");
    try expectBody("a_i^{n+1}", "<msubsup><mi>a</mi><mi>i</mi><mrow><mi>n</mi><mo>+</mo><mn>1</mn></mrow></msubsup>");
    try expectBody("\\frac{1}{2} - 3.14", "<mfrac><mn>1</mn><mn>2</mn></mfrac><mo>\u{2212}</mo><mn>3.14</mn>");
    try expectBody("\\sqrt[3]{x}\\sqrt{2}", "<mroot><mi>x</mi><mn>3</mn></mroot><msqrt><mn>2</mn></msqrt>");
    try expectBody("x^10", "<msup><mi>x</mi><mn>1</mn></msup><mn>0</mn>");
}

test "symbols, operators with limits, functions and text" {
    try expectBody("\\sum_{i=0}^n \\alpha_i \\leq \\infty", "<munderover><mo largeop=\"true\" movablelimits=\"true\">\u{2211}</mo><mrow><mi>i</mi><mo>=</mo><mn>0</mn></mrow><mi>n</mi></munderover><msub><mi>\u{3b1}</mi><mi>i</mi></msub><mo>\u{2264}</mo><mi>\u{221e}</mi>");
    try expectBody("\\int_0^1 f", "<msubsup><mo largeop=\"true\" movablelimits=\"false\">\u{222b}</mo><mn>0</mn><mn>1</mn></msubsup><mi>f</mi>");
    try expectBody("\\lim_{x\\to 0} \\sin x", "<munder><mi>lim</mi><mrow><mi>x</mi><mo>\u{2192}</mo><mn>0</mn></mrow></munder><mo>\u{2061}</mo><mi>sin</mi><mo>\u{2061}</mo><mi>x</mi>");
    try expectBody("\\text{if } a<b", "<mtext>if </mtext><mi>a</mi><mo>&lt;</mo><mi>b</mi>");
    try expectBody("\\mathbb{R}\\hat{x}\\Omega", "<mstyle mathvariant=\"double-struck\"><mi>R</mi></mstyle><mover accent=\"true\"><mi>x</mi><mo>^</mo></mover><mi mathvariant=\"normal\">\u{3a9}</mi>");
}

test "fences and environments" {
    try expectBody("\\left( \\frac{a}{b} \\right]", "<mrow><mo fence=\"true\" stretchy=\"true\">(</mo><mfrac><mi>a</mi><mi>b</mi></mfrac><mo fence=\"true\" stretchy=\"true\">]</mo></mrow>");
    try expectBody("\\begin{pmatrix} a & b \\\\ c & d \\end{pmatrix}", "<mrow><mo fence=\"true\" stretchy=\"true\">(</mo><mtable><mtr><mtd><mi>a</mi></mtd><mtd><mi>b</mi></mtd></mtr><mtr><mtd><mi>c</mi></mtd><mtd><mi>d</mi></mtd></mtr></mtable><mo fence=\"true\" stretchy=\"true\">)</mo></mrow>");
    try expectBody("\\begin{cases} 1 & x > 0 \\\\ 0 & \\text{else} \\\\ \\end{cases}", "<mrow><mo fence=\"true\" stretchy=\"true\">{</mo><mtable columnalign=\"left left\"><mtr><mtd><mn>1</mn></mtd><mtd><mi>x</mi><mo>&gt;</mo><mn>0</mn></mtd></mtr><mtr><mtd><mn>0</mn></mtd><mtd><mtext>else</mtext></mtd></mtr></mtable><mo fence=\"true\" stretchy=\"true\"></mo></mrow>");
}

test "display math and the annotation" {
    const ok = try mathml("E = mc^2", true);
    defer testing.allocator.free(ok);
    try testing.expectEqualStrings("<math xmlns=\"http://www.w3.org/1998/Math/MathML\" display=\"block\"><semantics><mrow><mi>E</mi><mo>=</mo><mi>m</mi><msup><mi>c</mi><mn>2</mn></msup></mrow><annotation encoding=\"application/x-tex\">E = mc^2</annotation></semantics></math>", ok);
}

test "errors name the problem" {
    const cases = [_]struct { []const u8, []const u8 }{
        .{ "\\foo x", "unknown command '\\foo'" },
        .{ "{a", "missing '}'" },
        .{ "a}", "unexpected '}'" },
        .{ "x^1^2", "double superscript" },
        .{ "\\begin{tabular}x\\end{tabular}", "unknown environment 'tabular'" },
        .{ "\\left( x", "missing \\right" },
        .{ "a & b", "'&' outside" },
    };
    for (cases) |c| {
        var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
        defer arena_state.deinit();
        var aw: Writer.Allocating = .init(arena_state.allocator());
        var diag: Diagnostic = .{};
        try testing.expectError(error.InvalidMath, write(arena_state.allocator(), c[0], false, &aw.writer, &diag));
        if (std.mem.indexOf(u8, diag.message, c[1]) == null) {
            std.debug.print("expected '{s}' in '{s}' for {s}\n", .{ c[1], diag.message, c[0] });
            return error.TestUnexpectedResult;
        }
    }
}
