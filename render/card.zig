//! Social cards: the 1200x630 images that link previews show (Open Graph
//! and Twitter cards), with a page's title set in the stroke font.
//!
//! Three looks: `plain` (an accent bar and large type), `visor` (a
//! chamfered HUD panel with glowing type, on a calm gradient), and `lcars`
//! (a console frame of rounded elbow bars).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Canvas = @import("Canvas.zig");
const Color = @import("color.zig").Color;
const shapes = @import("shapes.zig");
const filter = @import("filter.zig");
const hud = @import("hud.zig");
const text = @import("text.zig");
const Point = shapes.Point;
const Paint = shapes.Paint;

pub const Style = enum { plain, visor, lcars };

pub const Options = struct {
    width: u32 = 1200,
    height: u32 = 630,
    /// The page title, wrapped onto up to three lines.
    title: []const u8,
    /// Usually the site's name, shown small above the title.
    subtitle: []const u8 = "",
    /// A short line below the title, such as a date or a section.
    label: []const u8 = "",
    style: Style = .plain,
    /// Null picks the style's own colors.
    accent: ?Color = null,
    background: ?Color = null,
    foreground: ?Color = null,
};

const Palette = struct { accent: Color, background: Color, foreground: Color, muted: Color };

fn palette(o: Options) Palette {
    const d: Palette = switch (o.style) {
        .plain => .{ .accent = Color.hex(0xc2410c), .background = Color.hex(0x111827), .foreground = Color.hex(0xf9fafb), .muted = Color.hex(0x9ca3af) },
        .visor => .{ .accent = Color.hex(0x3fd8ff), .background = Color.hex(0x050b16), .foreground = Color.hex(0xd8f6ff), .muted = Color.hex(0x5fa8c4) },
        .lcars => .{ .accent = Color.hex(0xff9c00), .background = Color.hex(0x000000), .foreground = Color.hex(0xffcc99), .muted = Color.hex(0xcc99cc) },
    };
    return .{
        .accent = o.accent orelse d.accent,
        .background = o.background orelse d.background,
        .foreground = o.foreground orelse d.foreground,
        .muted = d.muted,
    };
}

pub fn render(gpa: Allocator, o: Options) Allocator.Error!Canvas {
    var c = try Canvas.init(gpa, o.width, o.height);
    errdefer c.deinit(gpa);
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const p = palette(o);
    const w: f32 = @floatFromInt(o.width);
    const h: f32 = @floatFromInt(o.height);
    // Layout scales with the card's height; 630 is the reference.
    const u = h / 630;

    // The text box, which each style frames differently.
    var box: struct { x: f32, y: f32, w: f32, h: f32 } = .{ .x = 96 * u, .y = 96 * u, .w = w - 192 * u, .h = h - 192 * u };
    // Opaque from edge to edge, under any anti-aliased shape edges.
    c.fill(p.background);

    switch (o.style) {
        .plain => {
            shapes.rect(c, 0, 0, w, h, 0, .{ .fill = .{ .linear = .{
                .from = .{ .x = 0, .y = 0 },
                .to = .{ .x = w, .y = h },
                .stops = &.{ .{ .t = 0, .color = p.background }, .{ .t = 1, .color = p.background.mix(p.accent, 0.025) } },
            } } });
            shapes.rect(c, 0, 0, 18 * u, h, 0, Paint.solid(p.accent));
        },
        .visor => {
            shapes.rect(c, 0, 0, w, h, 0, .{ .fill = .{ .linear = .{
                .from = .{ .x = 0, .y = 0 },
                .to = .{ .x = 0, .y = h },
                .stops = &.{ .{ .t = 0, .color = p.background.mix(p.accent, 0.04) }, .{ .t = 1, .color = p.background } },
            } } });
            var frame = try hud.panel(gpa, .{
                .width = o.width,
                .height = o.height,
                .color = p.accent,
                .chamfer = 56 * u,
                .stroke = 3 * u,
                .fill = 0.025,
                .glow = 8 * u,
                .margin = @intFromFloat(36 * u),
            });
            defer frame.deinit(gpa);
            c.draw(frame.canvas, 0, 0, .normal, 1);
            // A row of ticks under the frame's top edge.
            var x: f32 = 120 * u;
            while (x < 360 * u) : (x += 18 * u) {
                shapes.line(c, .{ .x = x, .y = 60 * u }, .{ .x = x, .y = 72 * u }, 2 * u, .butt, Paint.solid(p.accent.withAlpha(0.55)));
            }
        },
        .lcars => {
            c.fill(p.background);
            const bar = 64 * u;
            const side = 150 * u;
            const r = 70 * u;
            // The elbow: a top bar joined to a side bar by a rounded corner.
            shapes.rect(c, 24 * u, 24 * u, side, h - 48 * u, r, Paint.solid(p.accent));
            shapes.rect(c, 24 * u + r, 24 * u, w * 0.55 - r, bar, 0, Paint.solid(p.accent));
            // Black inner corner of the elbow.
            shapes.rect(c, 24 * u + side, 24 * u + bar, 60 * u, 60 * u, 0, Paint.solid(p.background));
            shapes.circle(c, .{ .x = 24 * u + side + 40 * u, .y = 24 * u + bar + 40 * u }, 40 * u, Paint.solid(p.background));
            shapes.rect(c, 24 * u + side, 24 * u + bar + 40 * u, 40 * u, h, 0, Paint.solid(p.background));
            // Colored segments continuing the top bar, and side bar blocks.
            const seg = [_]struct { f32, u24 }{ .{ 0.08, 0xcc99cc }, .{ 0.16, 0x9999ff }, .{ 0.10, 0xff9966 } };
            var sx = 24 * u + w * 0.55 + 8 * u;
            for (seg, 0..) |s, i| {
                const sw = if (i == seg.len - 1) w - 24 * u - sx else s[0] * w;
                shapes.rect(c, sx, 24 * u, sw, bar, if (i == seg.len - 1) bar / 2 else 0, Paint.solid(Color.hex(s[1])));
                sx += sw + 8 * u;
            }
            shapes.rect(c, 24 * u, h - 190 * u, side, 8 * u, 0, Paint.solid(p.background));
            shapes.rect(c, 24 * u, h - 110 * u, side, 8 * u, 0, Paint.solid(p.background));
            box = .{ .x = 24 * u + side + 60 * u, .y = 24 * u + bar + 56 * u, .w = w - (24 * u + side + 60 * u) - 64 * u, .h = h - (24 * u + bar + 56 * u) - 64 * u };
        },
    }

    // Text goes on its own layer so the visor style can make it glow.
    var layer = try Canvas.init(gpa, o.width, o.height);
    defer layer.deinit(gpa);
    const title_paint = Paint.solid(p.foreground);
    var y = box.y;
    if (o.subtitle.len > 0) {
        const s: text.Style = .{ .size = 26 * u, .weight = 0.12, .spacing = 0.18 };
        const sub = if (o.style == .visor) try std.mem.concat(arena, u8, &.{ "// ", o.subtitle }) else o.subtitle;
        const lines = try text.wrap(arena, sub, s, box.w, 1);
        if (lines.len > 0) _ = text.draw(layer, lines[0], box.x, y, s, Paint.solid(if (o.style == .plain) p.muted else p.accent));
        y += 26 * u + 44 * u;
    }
    // The largest size, down to a floor, at which the title fits in three lines.
    var size: f32 = 76 * u;
    var lines: []const []const u8 = &.{};
    while (true) : (size -= 4 * u) {
        const s: text.Style = .{ .size = size, .weight = 0.11, .spacing = 0.04 };
        lines = try text.wrap(arena, o.title, s, box.w, 3);
        const fits = lines.len < 3 or !std.mem.endsWith(u8, lines[lines.len - 1], "\u{2026}");
        if (fits or size <= 48 * u) break;
    }
    const title_style: text.Style = .{ .size = size, .weight = 0.11, .spacing = 0.04 };
    for (lines) |line| {
        _ = text.draw(layer, line, box.x, y, title_style, title_paint);
        y += size * 1.45;
    }
    if (o.label.len > 0) {
        const s: text.Style = .{ .size = 24 * u, .weight = 0.12, .spacing = 0.16 };
        const label_lines = try text.wrap(arena, o.label, s, box.w, 1);
        const ly = @max(y + 12 * u, box.y + box.h - 24 * u);
        if (label_lines.len > 0) _ = text.draw(layer, label_lines[0], box.x, @min(ly, h - 60 * u), s, Paint.solid(if (o.style == .plain) p.accent else p.muted));
    }
    if (o.style == .visor) try filter.glow(gpa, layer, 6 * u, 0.6, .transparent);
    c.draw(layer, 0, 0, .normal, 1);
    if (o.style == .visor) darkRows(c, @intFromFloat(@max(3, 4 * u)), 0.12);
    return c;
}

/// Scanlines that darken color but keep the card opaque.
fn darkRows(c: Canvas, period: u32, depth: f32) void {
    for (0..c.height) |y| {
        const phase = @as(f32, @floatFromInt(y % period)) / @as(f32, @floatFromInt(period));
        const k = 1 - depth * (0.5 - 0.5 * @cos(phase * std.math.tau));
        for (c.pixels[y * c.width ..][0..c.width]) |*p| p.* *= .{ k, k, k, 1 };
    }
}

const testing = std.testing;

test "every style renders the requested size with text on it" {
    for ([_]Style{ .plain, .visor, .lcars }) |style| {
        var c = try render(testing.allocator, .{
            .width = 300,
            .height = 158,
            .title = "A rather long title that has to wrap onto more than one line",
            .subtitle = "Site",
            .label = "2024-01-05",
            .style = style,
        });
        defer c.deinit(testing.allocator);
        try testing.expectEqual(@as(u32, 300), c.width);
        // Opaque everywhere: link previews show no transparency.
        for (c.pixels) |px| try testing.expect(px[3] > 0.99);
    }
}
