//! Text drawn with a built-in stroke font.
//!
//! The font is geometric and chamfered, in the style of instrument panels:
//! every glyph is a few straight strokes on a grid 12 units tall (0 is the
//! cap line, 12 the baseline). Strokes are drawn as anti-aliased lines, so
//! text stays sharp at any size and weight. Lowercase letters are drawn as
//! small capitals. Accented Latin letters fall back to their base letter,
//! and any other character to a box.
//!
//! The font has no kerning or hinting; it is meant for titles on generated
//! images, not body text.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Canvas = @import("Canvas.zig");
const shapes = @import("shapes.zig");
const Point = shapes.Point;
const Paint = shapes.Paint;

/// Grid units from the cap line to the baseline.
pub const cap_units: f32 = 12;
/// Space between glyphs, in grid units.
const tracking: f32 = 2.5;
/// Lowercase letters are capitals scaled by this much.
const small_caps: f32 = 0.78;

const Glyph = struct {
    width: f32,
    /// Strokes separated by `|`, points by spaces, `x,y` in grid units.
    strokes: []const u8,
};

fn glyph(c: u21) ?Glyph {
    return switch (c) {
        ' ' => .{ .width = 4, .strokes = "" },
        'A' => .{ .width = 8, .strokes = "0,12 0,3 3,0 5,0 8,3 8,12|0,7 8,7" },
        'B' => .{ .width = 8, .strokes = "0,0 6,0 8,2 8,4 6,6 0,6|6,6 8,8 8,10 6,12 0,12 0,0" },
        'C' => .{ .width = 8, .strokes = "8,2 6,0 2,0 0,2 0,10 2,12 6,12 8,10" },
        'D' => .{ .width = 8, .strokes = "0,0 5,0 8,3 8,9 5,12 0,12 0,0" },
        'E' => .{ .width = 7, .strokes = "7,0 0,0 0,12 7,12|0,6 5,6" },
        'F' => .{ .width = 7, .strokes = "7,0 0,0 0,12|0,6 5,6" },
        'G' => .{ .width = 8, .strokes = "8,2 6,0 2,0 0,2 0,10 2,12 6,12 8,10 8,7 4,7" },
        'H' => .{ .width = 8, .strokes = "0,0 0,12|8,0 8,12|0,6 8,6" },
        'I' => .{ .width = 4, .strokes = "0,0 4,0|2,0 2,12|0,12 4,12" },
        'J' => .{ .width = 7, .strokes = "7,0 7,10 5,12 2,12 0,10" },
        'K' => .{ .width = 8, .strokes = "0,0 0,12|8,0 2,6 0,6|2,6 8,12" },
        'L' => .{ .width = 7, .strokes = "0,0 0,12 7,12" },
        'M' => .{ .width = 10, .strokes = "0,12 0,0 5,6 10,0 10,12" },
        'N' => .{ .width = 8, .strokes = "0,12 0,0 8,12 8,0" },
        'O' => .{ .width = 8, .strokes = "2,0 6,0 8,2 8,10 6,12 2,12 0,10 0,2 2,0" },
        'P' => .{ .width = 8, .strokes = "0,12 0,0 6,0 8,2 8,4 6,6 0,6" },
        'Q' => .{ .width = 8, .strokes = "2,0 6,0 8,2 8,10 6,12 2,12 0,10 0,2 2,0|5,9 8,12" },
        'R' => .{ .width = 8, .strokes = "0,12 0,0 6,0 8,2 8,4 6,6 0,6|4,6 8,12" },
        'S' => .{ .width = 8, .strokes = "8,2 6,0 2,0 0,2 0,4 2,6 6,6 8,8 8,10 6,12 2,12 0,10" },
        'T' => .{ .width = 8, .strokes = "0,0 8,0|4,0 4,12" },
        'U' => .{ .width = 8, .strokes = "0,0 0,10 2,12 6,12 8,10 8,0" },
        'V' => .{ .width = 8, .strokes = "0,0 4,12 8,0" },
        'W' => .{ .width = 10, .strokes = "0,0 2,12 5,6 8,12 10,0" },
        'X' => .{ .width = 8, .strokes = "0,0 8,12|8,0 0,12" },
        'Y' => .{ .width = 8, .strokes = "0,0 4,6 8,0|4,6 4,12" },
        'Z' => .{ .width = 8, .strokes = "0,0 8,0 0,12 8,12" },
        '0' => .{ .width = 8, .strokes = "2,0 6,0 8,2 8,10 6,12 2,12 0,10 0,2 2,0|6,3 2,9" },
        '1' => .{ .width = 6, .strokes = "1,2 3,0 3,12|0,12 6,12" },
        '2' => .{ .width = 8, .strokes = "0,2 2,0 6,0 8,2 8,4 0,12 8,12" },
        '3' => .{ .width = 8, .strokes = "0,2 2,0 6,0 8,2 8,4 6,6 2,6|6,6 8,8 8,10 6,12 2,12 0,10" },
        '4' => .{ .width = 8, .strokes = "6,12 6,0 0,8 8,8" },
        '5' => .{ .width = 8, .strokes = "8,0 0,0 0,5 6,5 8,7 8,10 6,12 2,12 0,10" },
        '6' => .{ .width = 8, .strokes = "7,0 2,0 0,2 0,10 2,12 6,12 8,10 8,8 6,6 0,6" },
        '7' => .{ .width = 8, .strokes = "0,0 8,0 3,12" },
        '8' => .{ .width = 8, .strokes = "2,6 0,4 0,2 2,0 6,0 8,2 8,4 6,6 2,6 0,8 0,10 2,12 6,12 8,10 8,8 6,6" },
        '9' => .{ .width = 8, .strokes = "8,6 2,6 0,4 0,2 2,0 6,0 8,2 8,10 6,12 1,12" },
        '.' => .{ .width = 2, .strokes = "1,11 1,12" },
        ',' => .{ .width = 2, .strokes = "1,11 1,12 0,14" },
        ':' => .{ .width = 2, .strokes = "1,4 1,5|1,11 1,12" },
        ';' => .{ .width = 2, .strokes = "1,4 1,5|1,11 1,12 0,14" },
        '!' => .{ .width = 2, .strokes = "1,0 1,8|1,11 1,12" },
        '?' => .{ .width = 8, .strokes = "0,2 2,0 6,0 8,2 8,4 4,7 4,8|4,11 4,12" },
        '\'' => .{ .width = 2, .strokes = "1,0 1,3" },
        '"' => .{ .width = 4, .strokes = "1,0 1,3|3,0 3,3" },
        '`' => .{ .width = 2, .strokes = "0,0 2,2" },
        '-' => .{ .width = 6, .strokes = "0,6 6,6" },
        '_' => .{ .width = 8, .strokes = "0,12 8,12" },
        '/' => .{ .width = 6, .strokes = "6,0 0,12" },
        '\\' => .{ .width = 6, .strokes = "0,0 6,12" },
        '|' => .{ .width = 2, .strokes = "1,-1 1,14" },
        '(' => .{ .width = 4, .strokes = "4,0 1,3 1,9 4,12" },
        ')' => .{ .width = 4, .strokes = "0,0 3,3 3,9 0,12" },
        '[' => .{ .width = 4, .strokes = "4,0 1,0 1,12 4,12" },
        ']' => .{ .width = 4, .strokes = "0,0 3,0 3,12 0,12" },
        '{' => .{ .width = 5, .strokes = "5,0 3,0 2,1 2,5 0,6 2,7 2,11 3,12 5,12" },
        '}' => .{ .width = 5, .strokes = "0,0 2,0 3,1 3,5 5,6 3,7 3,11 2,12 0,12" },
        '<' => .{ .width = 6, .strokes = "6,2 0,6 6,10" },
        '>' => .{ .width = 6, .strokes = "0,2 6,6 0,10" },
        '=' => .{ .width = 8, .strokes = "1,4 7,4|1,8 7,8" },
        '+' => .{ .width = 8, .strokes = "4,3 4,9|1,6 7,6" },
        '*' => .{ .width = 8, .strokes = "4,2 4,10|1,4 7,8|7,4 1,8" },
        '#' => .{ .width = 8, .strokes = "3,1 2,11|6,1 5,11|1,4 8,4|0,8 7,8" },
        '%' => .{ .width = 8, .strokes = "0,12 8,0|1,1 2,1 2,2 1,2 1,1|6,10 7,10 7,11 6,11 6,10" },
        '&' => .{ .width = 8, .strokes = "8,12 1,4 1,2 3,0 5,0 6,2 6,3 1,8 1,10 3,12 5,12 8,9" },
        '@' => .{ .width = 9, .strokes = "6,8 6,4 3,4 3,8 6,8 9,8 9,2 7,0 2,0 0,2 0,10 2,12 7,12" },
        '$' => .{ .width = 8, .strokes = "8,2 6,0 2,0 0,2 0,4 2,6 6,6 8,8 8,10 6,12 2,12 0,10|4,-1 4,13" },
        '^' => .{ .width = 6, .strokes = "0,4 3,0 6,4" },
        '~' => .{ .width = 8, .strokes = "0,7 2,5 6,7 8,5" },
        // Typographic punctuation that titles often hold.
        0x2018, 0x2019 => glyph('\''),
        0x201C, 0x201D => glyph('"'),
        0x2013 => .{ .width = 7, .strokes = "0,6 7,6" },
        0x2014 => .{ .width = 11, .strokes = "0,6 11,6" },
        0x2026 => .{ .width = 8, .strokes = "1,11 1,12|4,11 4,12|7,11 7,12" },
        0x00B7 => .{ .width = 2, .strokes = "1,6 1,7" },
        else => null,
    };
}

/// Drawn for characters the font lacks.
const box: Glyph = .{ .width = 7, .strokes = "0,0 7,0 7,12 0,12 0,0" };

/// The base letter of common accented Latin letters, for the font.
fn baseLetter(c: u21) u21 {
    return switch (c) {
        0xC0...0xC5 => 'A',
        0xC7 => 'C',
        0xC8...0xCB => 'E',
        0xCC...0xCF => 'I',
        0xD1 => 'N',
        0xD2...0xD6, 0xD8 => 'O',
        0xD9...0xDC => 'U',
        0xDD => 'Y',
        0xE0...0xE5 => 'a',
        0xE7 => 'c',
        0xE8...0xEB => 'e',
        0xEC...0xEF => 'i',
        0xF1 => 'n',
        0xF2...0xF6, 0xF8 => 'o',
        0xF9...0xFC => 'u',
        0xFD, 0xFF => 'y',
        else => c,
    };
}

const Shaped = struct { glyph: Glyph, scale: f32 };

fn shape(c: u21) Shaped {
    const base = baseLetter(c);
    if (base >= 'a' and base <= 'z') return .{ .glyph = glyph(base - 32).?, .scale = small_caps };
    return .{ .glyph = glyph(base) orelse box, .scale = 1 };
}

pub const Style = struct {
    /// Cap height in pixels.
    size: f32,
    /// Stroke width as a fraction of the cap height.
    weight: f32 = 0.12,
    /// Extra space between glyphs as a fraction of the cap height.
    spacing: f32 = 0,
};

/// The advance of one character, in pixels.
fn advance(s: Shaped, style: Style) f32 {
    const unit = style.size / cap_units;
    return (s.glyph.width + tracking) * unit * s.scale + style.spacing * style.size;
}

/// The width of `text` in pixels, without trailing tracking.
pub fn measure(text: []const u8, style: Style) f32 {
    var w: f32 = 0;
    var it = codepoints(text);
    while (it.next()) |c| w += advance(shape(c), style);
    if (w > 0) w -= tracking * style.size / cap_units;
    return @max(w, 0);
}

/// Draws `text` with its cap line at `y` and its left edge at `x`.
/// Returns the x just past the last character.
pub fn draw(c: Canvas, text: []const u8, x: f32, y: f32, style: Style, paint: Paint) f32 {
    var pen = x;
    const unit = style.size / cap_units;
    const width = style.weight * style.size;
    var it = codepoints(text);
    while (it.next()) |cp| {
        const s = shape(cp);
        // Small capitals sit on the baseline.
        const top = y + (1 - s.scale) * style.size;
        drawGlyph(c, s.glyph, pen + width / 2, top, unit * s.scale, @max(width * (0.85 + 0.15 * s.scale), 0.75), paint);
        pen += advance(s, style);
    }
    return pen;
}

fn drawGlyph(c: Canvas, g: Glyph, x: f32, y: f32, unit: f32, width: f32, paint: Paint) void {
    var buf: [32]Point = undefined;
    var strokes = std.mem.splitScalar(u8, g.strokes, '|');
    while (strokes.next()) |stroke| {
        if (stroke.len == 0) continue;
        var n: usize = 0;
        var pts = std.mem.tokenizeScalar(u8, stroke, ' ');
        while (pts.next()) |pt| {
            const comma = std.mem.indexOfScalar(u8, pt, ',') orelse continue;
            const px = std.fmt.parseFloat(f32, pt[0..comma]) catch continue;
            const py = std.fmt.parseFloat(f32, pt[comma + 1 ..]) catch continue;
            if (n == buf.len) break;
            buf[n] = .{ .x = x + px * unit, .y = y + py * unit };
            n += 1;
        }
        shapes.polyline(c, buf[0..n], width, false, paint);
    }
}

/// Decodes UTF-8, replacing invalid bytes with U+FFFD.
fn codepoints(text: []const u8) Codepoints {
    return .{ .text = text };
}

const Codepoints = struct {
    text: []const u8,
    i: usize = 0,

    fn next(it: *Codepoints) ?u21 {
        if (it.i >= it.text.len) return null;
        const len = std.unicode.utf8ByteSequenceLength(it.text[it.i]) catch {
            it.i += 1;
            return 0xFFFD;
        };
        if (it.i + len > it.text.len) {
            it.i = it.text.len;
            return 0xFFFD;
        }
        const cp = std.unicode.utf8Decode(it.text[it.i..][0..len]) catch 0xFFFD;
        it.i += len;
        return cp;
    }
};

/// Splits `text` into at most `max_lines` lines no wider than `max_width`
/// pixels, breaking at spaces. When the text does not fit, the last line
/// ends with an ellipsis. A word wider than a whole line is cut.
pub fn wrap(arena: Allocator, text: []const u8, style: Style, max_width: f32, max_lines: usize) Allocator.Error![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    if (max_lines == 0) return lines.items;
    var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
    var current: []const u8 = "";
    var cut = false;
    while (words.next()) |raw| {
        var word = raw;
        if (measure(word, style) > max_width) {
            // A word wider than a whole line is cut.
            word = try fitPrefix(arena, word, style, max_width);
            cut = true;
        }
        const candidate = if (current.len == 0) word else try std.mem.concat(arena, u8, &.{ current, " ", word });
        if (measure(candidate, style) <= max_width) {
            current = candidate;
            continue;
        }
        if (lines.items.len + 1 == max_lines) {
            cut = true;
            break;
        }
        try lines.append(arena, current);
        current = word;
    }
    if (current.len > 0) {
        try lines.append(arena, if (cut) try ellipsize(arena, current, style, max_width) else current);
    }
    return lines.items;
}

/// The longest prefix of `word` (whole characters) that fits.
fn fitPrefix(arena: Allocator, word: []const u8, style: Style, max_width: f32) Allocator.Error![]const u8 {
    var end: usize = 0;
    var it = codepoints(word);
    while (it.next()) |_| {
        if (measure(word[0..it.i], style) > max_width) break;
        end = it.i;
    }
    return arena.dupe(u8, word[0..end]);
}

/// `line` shortened until it fits with a trailing ellipsis.
fn ellipsize(arena: Allocator, line: []const u8, style: Style, max_width: f32) Allocator.Error![]const u8 {
    const dots = "\u{2026}";
    var end = line.len;
    while (true) {
        const candidate = try std.mem.concat(arena, u8, &.{ std.mem.trimEnd(u8, line[0..end], " ,.;:-"), dots });
        if (measure(candidate, style) <= max_width or end == 0) return candidate;
        end -= 1;
        while (end > 0 and (line[end] & 0xC0) == 0x80) end -= 1;
    }
}

const testing = std.testing;

test "measure scales with size and treats lowercase as small capitals" {
    const a = measure("AB", .{ .size = 12 });
    try testing.expectApproxEqAbs(@as(f32, 8 + 2.5 + 8), a, 0.001);
    try testing.expectApproxEqAbs(2 * a, measure("AB", .{ .size = 24 }), 0.001);
    try testing.expect(measure("ab", .{ .size = 12 }) < a);
    try testing.expectEqual(@as(f32, 0), measure("", .{ .size = 12 }));
    // Accented letters use their base letter's width.
    try testing.expectApproxEqAbs(measure("E", .{ .size = 12 }), measure("\u{c9}", .{ .size = 12 }), 0.001);
}

test "every printable ASCII character has a glyph" {
    for (0x20..0x7f) |c| {
        try testing.expect(shape(@intCast(c)).glyph.strokes.ptr != box.strokes.ptr);
    }
    try testing.expectEqual(box.strokes.ptr, shape(0x4E2D).glyph.strokes.ptr);
}

test "wrap breaks at spaces and ends with an ellipsis when cut" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const style: Style = .{ .size = 12 };
    const w = measure("HELLO WORLD", style);
    const two = try wrap(a, "HELLO WORLD AGAIN", style, w, 3);
    try testing.expectEqual(@as(usize, 2), two.len);
    try testing.expectEqualStrings("HELLO WORLD", two[0]);
    try testing.expectEqualStrings("AGAIN", two[1]);
    const cut = try wrap(a, "HELLO WORLD AGAIN AND AGAIN", style, w, 2);
    try testing.expectEqual(@as(usize, 2), cut.len);
    try testing.expect(std.mem.endsWith(u8, cut[1], "\u{2026}"));
    try testing.expect(measure(cut[1], style) <= w);
    const long = try wrap(a, "SUPERCALIFRAGILISTIC", style, measure("SUPER", style), 1);
    try testing.expect(measure(long[0], style) <= measure("SUPER", style));
}

test "draw puts ink inside the text's box" {
    var c = try Canvas.init(testing.allocator, 120, 40);
    defer c.deinit(testing.allocator);
    const end = draw(c, "Hi!", 10, 10, .{ .size = 20 }, Paint.solid(@import("color.zig").Color.hex(0xffffff)));
    try testing.expect(end > 10 + measure("Hi!", .{ .size = 20 }) - 1);
    var ink: f32 = 0;
    for (c.pixels) |p| ink += p[3];
    try testing.expect(ink > 50);
    // Nothing above the cap line (less the stroke's half width).
    for (0..6) |y| for (0..120) |x| try testing.expectEqual(@as(f32, 0), c.pixels[y * 120 + x][3]);
}
