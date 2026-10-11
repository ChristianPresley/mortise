//! Site icons: a square emblem with one or two letters in the stroke
//! font, for favicons and app icons. Drawn four times larger and shrunk,
//! so even a 16-pixel favicon is smoothly anti-aliased.
//!
//! Styles match the social cards: `plain` (a rounded tile), `visor` (a
//! chamfered HUD plate with corner brackets) and `lcars` (a console pill
//! with an elbow bar).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Canvas = @import("Canvas.zig");
const Color = @import("color.zig").Color;
const shapes = @import("shapes.zig");
const text = @import("text.zig");
const card = @import("card.zig");
const Point = shapes.Point;
const Paint = shapes.Paint;

pub const Options = struct {
    size: u32 = 512,
    /// One or two characters; more are cut.
    letters: []const u8,
    style: card.Style = .plain,
    accent: ?Color = null,
    background: ?Color = null,
    foreground: ?Color = null,
};

pub fn render(gpa: Allocator, o: Options) Allocator.Error!Canvas {
    // Small icons need more supersampling than large ones, whose own
    // anti-aliasing is already smooth.
    const factor: u32 = if (o.size >= 128) 2 else 4;
    var big = try Canvas.init(gpa, o.size * factor, o.size * factor);
    defer big.deinit(gpa);
    draw(big, o);
    return big.downsample(gpa, factor);
}

fn draw(c: Canvas, o: Options) void {
    const s: f32 = @floatFromInt(c.width);
    const accent = o.accent orelse switch (o.style) {
        .plain => Color.hex(0xc2410c),
        .visor => Color.hex(0x3fd8ff),
        .lcars => Color.hex(0xff9c00),
    };
    const bg = o.background orelse switch (o.style) {
        .plain => accent,
        .visor => Color.hex(0x050b16),
        .lcars => Color.hex(0x000000),
    };
    const fg = o.foreground orelse switch (o.style) {
        .plain => Color.hex(0xffffff),
        .visor => accent,
        .lcars => Color.hex(0xffcc99),
    };
    // The letters' box, inside each style's frame.
    var box: struct { x: f32, y: f32, w: f32, h: f32 } = .{ .x = s * 0.18, .y = s * 0.18, .w = s * 0.64, .h = s * 0.64 };
    switch (o.style) {
        .plain => shapes.rect(c, 0, 0, s, s, s * 0.22, Paint.solid(bg)),
        .visor => {
            const k = s * 0.2;
            const plate = [_]Point{
                .{ .x = k, .y = 0 },     .{ .x = s, .y = 0 }, .{ .x = s, .y = s - k },
                .{ .x = s - k, .y = s }, .{ .x = 0, .y = s }, .{ .x = 0, .y = k },
            };
            shapes.polygon(c, &plate, Paint.solid(bg));
            const inset = s * 0.07;
            const k2 = k * 0.75;
            const outline = [_]Point{
                .{ .x = inset + k2, .y = inset },         .{ .x = s - inset, .y = inset }, .{ .x = s - inset, .y = s - inset - k2 },
                .{ .x = s - inset - k2, .y = s - inset }, .{ .x = inset, .y = s - inset }, .{ .x = inset, .y = inset + k2 },
            };
            shapes.polyline(c, &outline, s * 0.045, true, Paint.solid(accent));
        },
        .lcars => {
            shapes.rect(c, 0, 0, s, s, s * 0.3, Paint.solid(bg));
            // An elbow along the left and top.
            shapes.rect(c, s * 0.06, s * 0.06, s * 0.2, s * 0.88, s * 0.1, Paint.solid(accent));
            shapes.rect(c, s * 0.06, s * 0.06, s * 0.88, s * 0.16, s * 0.08, Paint.solid(accent));
            shapes.rect(c, s * 0.26, s * 0.22, s * 0.2, s * 0.2, 0, Paint.solid(bg));
            shapes.circle(c, .{ .x = s * 0.36, .y = s * 0.32 }, s * 0.1, Paint.solid(bg));
            box = .{ .x = s * 0.31, .y = s * 0.3, .w = s * 0.58, .h = s * 0.6 };
        },
    }
    // Up to two characters, as large as fits the box.
    var end: usize = 0;
    var count: usize = 0;
    while (end < o.letters.len and count < 2) : (count += 1) {
        end += std.unicode.utf8ByteSequenceLength(o.letters[end]) catch 1;
    }
    const letters = o.letters[0..@min(end, o.letters.len)];
    if (letters.len == 0) return;
    var style: text.Style = .{ .size = box.h * 0.7, .weight = 0.16 };
    // Ink width: the advance plus the stroke's width at both ends.
    const ink = text.measure(letters, style) + style.weight * style.size;
    if (ink > box.w) style.size *= box.w / ink;
    const tw = text.measure(letters, style) + style.weight * style.size;
    _ = text.draw(c, letters, box.x + (box.w - tw) / 2, box.y + (box.h - style.size) / 2, style, Paint.solid(fg));
}

/// One image of an icon file: a square PNG and its size.
pub const IcoImage = struct { size: u32, png: []const u8 };

/// A Windows icon file holding the PNG images given (each a square PNG
/// of the size listed). Every browser reads PNG-compressed icons.
pub fn ico(gpa: Allocator, images: []const IcoImage) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    const w = struct {
        fn int(list: *std.ArrayList(u8), a: Allocator, comptime T: type, v: T) Allocator.Error!void {
            var buf: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &buf, v, .little);
            try list.appendSlice(a, &buf);
        }
    };
    try w.int(&out, gpa, u16, 0);
    try w.int(&out, gpa, u16, 1); // icon
    try w.int(&out, gpa, u16, @intCast(images.len));
    var offset: u32 = @intCast(6 + 16 * images.len);
    for (images) |im| {
        // 256 is written as 0.
        try out.append(gpa, if (im.size >= 256) 0 else @intCast(im.size));
        try out.append(gpa, if (im.size >= 256) 0 else @intCast(im.size));
        try out.append(gpa, 0); // no palette
        try out.append(gpa, 0);
        try w.int(&out, gpa, u16, 1); // planes
        try w.int(&out, gpa, u16, 32); // bits per pixel
        try w.int(&out, gpa, u32, @intCast(im.png.len));
        try w.int(&out, gpa, u32, offset);
        offset += @intCast(im.png.len);
    }
    for (images) |im| try out.appendSlice(gpa, im.png);
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

test "icons render at the requested size in every style" {
    for ([_]card.Style{ .plain, .visor, .lcars }) |style| {
        var c = try render(testing.allocator, .{ .size = 32, .letters = "Mo", .style = style });
        defer c.deinit(testing.allocator);
        try testing.expectEqual(@as(u32, 32), c.width);
        var ink: f32 = 0;
        for (c.pixels) |p| ink += p[3];
        try testing.expect(ink > 32 * 32 / 4);
    }
}

test "ico directory" {
    const out = try ico(testing.allocator, &.{ .{ .size = 16, .png = "abc" }, .{ .size = 256, .png = "de" } });
    defer testing.allocator.free(out);
    try testing.expectEqual(@as(usize, 6 + 32 + 5), out.len);
    try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, out[4..6], .little));
    try testing.expectEqual(@as(u8, 16), out[6]);
    try testing.expectEqual(@as(u8, 0), out[22]); // 256 written as 0
    try testing.expectEqual(@as(u32, 38), std.mem.readInt(u32, out[18..22], .little));
    try testing.expectEqual(@as(u32, 41), std.mem.readInt(u32, out[34..38], .little));
    try testing.expectEqualStrings("abcde", out[38..]);
}
