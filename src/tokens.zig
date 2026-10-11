//! Design tokens: a theme's named colors, written as CSS custom properties
//! (`--m-NAME`) at the top of `/theme.css`, overridable from
//! `_config.yml`, and checked for WCAG contrast at build time.
//!
//! A token holds one color, or a light and a dark color. A set whose
//! tokens have both is written with `light-dark()` and follows the
//! reader's color scheme; `scheme_toggle_html` lets readers pick one
//! without JavaScript, through `:has()`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const frontmatter = @import("frontmatter.zig");

pub const Scheme = enum {
    /// Light colors only.
    light,
    /// Dark colors only.
    dark,
    /// Light and dark, following the reader's preference.
    both,
};

pub const Rgb = [3]u8;

pub const Token = struct {
    name: []const u8,
    light: ?Rgb,
    dark: ?Rgb,
};

pub const Set = struct {
    scheme: Scheme,
    tokens: []const Token,

    pub fn get(s: Set, name: []const u8) ?Token {
        for (s.tokens) |t| if (std.mem.eql(u8, t.name, name)) return t;
        return null;
    }
};

pub const Diagnostic = struct {
    /// The key that is wrong; empty for the whole manifest.
    key: []const u8 = "",
    message: []const u8 = "",
};

pub const Error = error{InvalidTokens} || Allocator.Error;

/// Token names every theme defines, so site CSS can rely on them.
pub const standard = [_][]const u8{ "bg", "surface", "text", "muted", "accent", "border" };

/// Reads a manifest: `scheme: dark|light|both` and one key per token, each
/// `"#rrggbb"` or, for `both`, `["#light", "#dark"]`.
pub fn parse(arena: Allocator, fields: frontmatter.Map, diag: *Diagnostic) Error!Set {
    var scheme: Scheme = .dark;
    var list: std.ArrayList(Token) = .empty;
    for (fields.entries) |e| {
        if (std.mem.eql(u8, e.key, "scheme")) {
            scheme = if (e.value == .string) std.meta.stringToEnum(Scheme, e.value.string) orelse
                return fail(diag, e.key, "'scheme' must be light, dark or both") else return fail(diag, e.key, "'scheme' must be light, dark or both");
            continue;
        }
        try list.append(arena, try parseToken(e.key, e.value, diag));
    }
    const set: Set = .{ .scheme = scheme, .tokens = list.items };
    try validate(set, diag);
    return set;
}

fn parseToken(name: []const u8, v: frontmatter.Value, diag: *Diagnostic) Error!Token {
    switch (v) {
        .string => |s| {
            const c = parseHex(s) orelse return fail(diag, name, "must be a color such as \"#5ce1ff\", or a list of a light and a dark color");
            return .{ .name = name, .light = c, .dark = c };
        },
        .list => |l| {
            if (l.len != 2 or l[0] != .string or l[1] != .string) return fail(diag, name, "must be a list of two colors: [\"#light\", \"#dark\"]");
            return .{
                .name = name,
                .light = parseHex(l[0].string) orelse return fail(diag, name, "has a light color that is not like \"#5ce1ff\""),
                .dark = parseHex(l[1].string) orelse return fail(diag, name, "has a dark color that is not like \"#5ce1ff\""),
            };
        },
        else => return fail(diag, name, "must be a color such as \"#5ce1ff\""),
    }
}

fn validate(set: Set, diag: *Diagnostic) Error!void {
    for (set.tokens) |t| {
        for (t.name) |c| if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return fail(diag, t.name, "token names may hold letters, digits, '-' and '_'");
    }
}

fn fail(diag: *Diagnostic, key: []const u8, message: []const u8) Error {
    diag.* = .{ .key = key, .message = message };
    return error.InvalidTokens;
}

/// `base` with the tokens in `overrides` (a config map) replaced or added.
/// A single color overrides both schemes.
pub fn override(arena: Allocator, base: Set, overrides: frontmatter.Map, diag: *Diagnostic) Error!Set {
    var list: std.ArrayList(Token) = .empty;
    try list.appendSlice(arena, base.tokens);
    var scheme = base.scheme;
    for (overrides.entries) |e| {
        if (std.mem.eql(u8, e.key, "scheme")) {
            if (e.value != .string) return fail(diag, e.key, "'scheme' must be light, dark or both");
            scheme = std.meta.stringToEnum(Scheme, e.value.string) orelse return fail(diag, e.key, "'scheme' must be light, dark or both");
            continue;
        }
        const t = try parseToken(e.key, e.value, diag);
        for (list.items) |*old| {
            if (std.mem.eql(u8, old.name, t.name)) {
                old.* = t;
                break;
            }
        } else try list.append(arena, t);
    }
    const set: Set = .{ .scheme = scheme, .tokens = list.items };
    try validate(set, diag);
    return set;
}

/// The `:root` block: `color-scheme` and one `--m-NAME` per token, plus
/// the rules that let `scheme_toggle_html` force a scheme.
pub fn css(arena: Allocator, set: Set) Allocator.Error![]const u8 {
    var aw: Writer.Allocating = .init(arena);
    writeCss(&aw.writer, set) catch return error.OutOfMemory;
    return aw.written();
}

fn writeCss(w: *Writer, set: Set) Writer.Error!void {
    try w.writeAll("/* Design tokens, written by Mortise from the theme and _config.yml. */\n:root {\n");
    try w.print("  color-scheme: {s};\n", .{switch (set.scheme) {
        .light => "light",
        .dark => "dark",
        .both => "light dark",
    }});
    for (set.tokens) |t| {
        try w.print("  --m-{s}: ", .{t.name});
        const light = t.light orelse t.dark.?;
        const dark = t.dark orelse light;
        switch (set.scheme) {
            .light => try hex(w, light),
            .dark => try hex(w, dark),
            .both => if (std.mem.eql(u8, &light, &dark)) try hex(w, light) else {
                try w.writeAll("light-dark(");
                try hex(w, light);
                try w.writeAll(", ");
                try hex(w, dark);
                try w.writeAll(")");
            },
        }
        try w.writeAll(";\n");
    }
    try w.writeAll("}\n");
    if (set.scheme == .both) {
        try w.writeAll(
            \\:root:has(#mt-scheme-light:checked) { color-scheme: light; }
            \\:root:has(#mt-scheme-dark:checked) { color-scheme: dark; }
            \\.mt-scheme { display: inline-flex; gap: .6rem; margin: 0; padding: 0; border: 0; font-size: .85rem; }
            \\.mt-scheme legend { position: absolute; width: 1px; height: 1px; overflow: hidden; clip-path: inset(50%); }
            \\.mt-scheme label { display: inline-flex; gap: .25rem; align-items: center; cursor: pointer; }
            \\
        );
    }
}

fn hex(w: *Writer, c: Rgb) Writer.Error!void {
    try w.print("#{x:0>2}{x:0>2}{x:0>2}", .{ c[0], c[1], c[2] });
}

/// A color scheme switch for sets with both schemes: three radio buttons
/// that `:has()` rules in the token CSS act on, so it works without
/// JavaScript. A small script remembers the choice between pages.
pub const scheme_toggle_html =
    \\<fieldset class="mt-scheme"><legend>Color scheme</legend>
    \\<label><input type="radio" name="mt-scheme" id="mt-scheme-auto" value="auto" checked> Auto</label>
    \\<label><input type="radio" name="mt-scheme" id="mt-scheme-light" value="light"> Light</label>
    \\<label><input type="radio" name="mt-scheme" id="mt-scheme-dark" value="dark"> Dark</label>
    \\</fieldset>
    \\<script>(function(){try{var k="mt-scheme",v=localStorage.getItem(k);
    \\if(v){var i=document.getElementById(k+"-"+v);if(i)i.checked=true;}
    \\document.querySelectorAll('input[name="mt-scheme"]').forEach(function(i){
    \\i.addEventListener("change",function(){localStorage.setItem(k,i.value);});});}catch(e){}})();</script>
    \\
;

pub fn parseHex(s: []const u8) ?Rgb {
    const h = if (s.len > 0 and s[0] == '#') s[1..] else s;
    if (h.len == 3) {
        var c: Rgb = undefined;
        for (0..3) |i| {
            const d = std.fmt.charToDigit(h[i], 16) catch return null;
            c[i] = d * 17;
        }
        return c;
    }
    if (h.len != 6) return null;
    var c: Rgb = undefined;
    _ = std.fmt.hexToBytes(&c, h) catch return null;
    return c;
}

/// WCAG 2.x relative luminance.
fn luminance(c: Rgb) f64 {
    var sum: f64 = 0;
    const weights = [3]f64{ 0.2126, 0.7152, 0.0722 };
    for (c, weights) |v, wt| {
        const s = @as(f64, @floatFromInt(v)) / 255;
        const lin = if (s <= 0.04045) s / 12.92 else std.math.pow(f64, (s + 0.055) / 1.055, 2.4);
        sum += wt * lin;
    }
    return sum;
}

/// WCAG contrast ratio, from 1 to 21.
pub fn contrast(a: Rgb, b: Rgb) f64 {
    const la = luminance(a);
    const lb = luminance(b);
    return (@max(la, lb) + 0.05) / (@min(la, lb) + 0.05);
}

pub const Finding = struct {
    fg: []const u8,
    bg: []const u8,
    scheme: []const u8,
    ratio: f64,
    needed: f64,
};

/// Pairs that must stay readable: body text needs 4.5:1, accents used for
/// links, large text and controls need 3:1 (WCAG 2.2, 1.4.3 and 1.4.11).
const pairs = [_]struct { []const u8, []const u8, f64 }{
    .{ "text", "bg", 4.5 },
    .{ "text", "surface", 4.5 },
    .{ "muted", "bg", 4.5 },
    .{ "accent", "bg", 3 },
};

/// The token pairs whose contrast is too low, in each scheme in use.
pub fn check(arena: Allocator, set: Set) Allocator.Error![]const Finding {
    var out: std.ArrayList(Finding) = .empty;
    for (pairs) |p| {
        const fg = set.get(p[0]) orelse continue;
        const bg = set.get(p[1]) orelse continue;
        if (set.scheme != .dark) if (fg.light) |f| if (bg.light) |b| {
            const r = contrast(f, b);
            if (r < p[2]) try out.append(arena, .{ .fg = p[0], .bg = p[1], .scheme = "light", .ratio = r, .needed = p[2] });
        };
        if (set.scheme != .light) if (fg.dark) |f| if (bg.dark) |b| {
            const r = contrast(f, b);
            if (r < p[2]) try out.append(arena, .{ .fg = p[0], .bg = p[1], .scheme = "dark", .ratio = r, .needed = p[2] });
        };
    }
    return out.items;
}

const testing = std.testing;

fn testSet(arena: Allocator, src: []const u8) !Set {
    var fd: frontmatter.Diagnostic = .{};
    const fields = try frontmatter.parseFile(arena, src, &fd);
    var d: Diagnostic = .{};
    return parse(arena, fields, &d);
}

test "contrast matches WCAG examples" {
    try testing.expectApproxEqAbs(@as(f64, 21), contrast(.{ 0, 0, 0 }, .{ 255, 255, 255 }), 0.01);
    try testing.expectApproxEqAbs(@as(f64, 1), contrast(.{ 9, 9, 9 }, .{ 9, 9, 9 }), 0.001);
    // #767676 on white is the classic 4.54:1.
    try testing.expectApproxEqAbs(@as(f64, 4.54), contrast(parseHex("#767676").?, parseHex("#fff").?), 0.01);
}

test "css for one scheme and for both" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dark = try testSet(a, "scheme: dark\nbg: \"#000\"\naccent: \"#5ce1ff\"\n");
    try testing.expectEqualStrings(
        \\/* Design tokens, written by Mortise from the theme and _config.yml. */
        \\:root {
        \\  color-scheme: dark;
        \\  --m-bg: #000000;
        \\  --m-accent: #5ce1ff;
        \\}
        \\
    , try css(a, dark));
    const both = try testSet(a, "scheme: both\nbg: [\"#fff\", \"#111\"]\naccent: \"#c2410c\"\n");
    const out = try css(a, both);
    try testing.expect(std.mem.indexOf(u8, out, "color-scheme: light dark;") != null);
    try testing.expect(std.mem.indexOf(u8, out, "--m-bg: light-dark(#ffffff, #111111);") != null);
    try testing.expect(std.mem.indexOf(u8, out, "--m-accent: #c2410c;") != null);
    try testing.expect(std.mem.indexOf(u8, out, ":root:has(#mt-scheme-dark:checked) { color-scheme: dark; }") != null);
}

test "overrides replace and add tokens" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const base = try testSet(a, "bg: \"#000\"\naccent: \"#5ce1ff\"\n");
    var fd: frontmatter.Diagnostic = .{};
    const fields = try frontmatter.parseFile(a, "accent: \"#ff9c00\"\nbrand: \"#123456\"\n", &fd);
    var d: Diagnostic = .{};
    const set = try override(a, base, fields, &d);
    try testing.expectEqual(@as(usize, 3), set.tokens.len);
    try testing.expectEqual(parseHex("#ff9c00").?, set.get("accent").?.dark.?);
    const bad = try frontmatter.parseFile(a, "accent: teal\n", &fd);
    try testing.expectError(error.InvalidTokens, override(a, base, bad, &d));
    try testing.expectEqualStrings("accent", d.key);
}

test "check reports low contrast per scheme" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const set = try testSet(a, "scheme: both\nbg: [\"#ffffff\", \"#000000\"]\ntext: [\"#111111\", \"#333333\"]\nmuted: [\"#999999\", \"#999999\"]\n");
    const found = try check(a, set);
    // Dark text on black, and light-grey muted text on white.
    try testing.expectEqual(@as(usize, 2), found.len);
    try testing.expectEqualStrings("text", found[0].fg);
    try testing.expectEqualStrings("dark", found[0].scheme);
    try testing.expectEqualStrings("muted", found[1].fg);
    try testing.expectEqualStrings("light", found[1].scheme);
}
