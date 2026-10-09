//! Sci-fi interface pieces: glowing panel frames made for CSS
//! `border-image`, targeting reticles, and radar scopes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Canvas = @import("Canvas.zig");
const Color = @import("color.zig").Color;
const shapes = @import("shapes.zig");
const filter = @import("filter.zig");
const Point = shapes.Point;

pub const PanelOptions = struct {
    width: u32 = 256,
    height: u32 = 256,
    color: Color = Color.hex(0x3fd8ff),
    /// Size of the cut-off top-left and bottom-right corners.
    chamfer: f32 = 22,
    /// Outline thickness.
    stroke: f32 = 2,
    /// Opacity of the panel's tinted fill; 0 leaves it clear.
    fill: f32 = 0.10,
    /// Blur radius of the glow around the lines; 0 for none.
    glow: f32 = 5,
    /// Transparent border that keeps the glow from being clipped.
    margin: u32 = 14,
    /// Thick corner brackets at the two square corners.
    brackets: bool = true,
};

pub const Panel = struct {
    canvas: Canvas,
    /// Pixels from each edge that hold all corner detail. Use it as the
    /// CSS `border-image-slice` (and as `border-width`), so that only plain
    /// edge runs are stretched.
    slice: u32,

    pub fn deinit(p: *Panel, gpa: Allocator) void {
        p.canvas.deinit(gpa);
        p.* = undefined;
    }
};

/// A chamfered panel frame. Everything that is not a straight edge sits
/// within `slice` pixels of a corner, so the image scales to any box as a
/// CSS border image.
pub fn panel(gpa: Allocator, o: PanelOptions) Allocator.Error!Panel {
    var c = try Canvas.init(gpa, o.width, o.height);
    errdefer c.deinit(gpa);
    const m: f32 = @floatFromInt(o.margin);
    const x0 = m;
    const y0 = m;
    const x1 = @as(f32, @floatFromInt(o.width)) - m;
    const y1 = @as(f32, @floatFromInt(o.height)) - m;
    const k = o.chamfer;
    const outline = [_]Point{
        .{ .x = x0 + k, .y = y0 },
        .{ .x = x1, .y = y0 },
        .{ .x = x1, .y = y1 - k },
        .{ .x = x1 - k, .y = y1 },
        .{ .x = x0, .y = y1 },
        .{ .x = x0, .y = y0 + k },
    };

    if (o.fill > 0) {
        const stops = [_]shapes.Stop{
            .{ .t = 0, .color = o.color.withAlpha(o.fill * 1.6) },
            .{ .t = 1, .color = o.color.withAlpha(o.fill * 0.6) },
        };
        shapes.polygon(c, &outline, .{ .fill = .{ .linear = .{
            .from = .{ .x = 0, .y = y0 },
            .to = .{ .x = 0, .y = y1 },
            .stops = &stops,
        } } });
    }

    // Lines go on their own layer so the glow can be built from them alone.
    var lines = try Canvas.init(gpa, o.width, o.height);
    defer lines.deinit(gpa);
    const ink: shapes.Paint = .solid(o.color);
    shapes.polyline(lines, &outline, o.stroke, true, ink);

    // A second, fainter inset line along the chamfers.
    const inset = o.stroke * 3;
    const faint: shapes.Paint = .{ .fill = .{ .solid = o.color }, .opacity = 0.55 };
    shapes.line(lines, .{ .x = x0 + inset, .y = y0 + k + inset * 0.4 }, .{ .x = x0 + k + inset * 0.4, .y = y0 + inset }, o.stroke * 0.75, .round, faint);
    shapes.line(lines, .{ .x = x1 - inset, .y = y1 - k - inset * 0.4 }, .{ .x = x1 - k - inset * 0.4, .y = y1 - inset }, o.stroke * 0.75, .round, faint);

    if (o.brackets) {
        const arm = k * 0.8;
        const t = o.stroke * 2.2;
        const off = o.stroke * 2.5;
        // Top-right and bottom-left, the corners the chamfers leave square.
        shapes.polyline(lines, &.{
            .{ .x = x1 - arm, .y = y0 - off },
            .{ .x = x1 + off, .y = y0 - off },
            .{ .x = x1 + off, .y = y0 + arm },
        }, t, false, ink);
        shapes.polyline(lines, &.{
            .{ .x = x0 + arm, .y = y1 + off },
            .{ .x = x0 - off, .y = y1 + off },
            .{ .x = x0 - off, .y = y1 - arm },
        }, t, false, ink);
        // Three small status pips beside the top-right bracket.
        for (0..3) |i| {
            const px = x1 - arm - 8 - @as(f32, @floatFromInt(i)) * 6;
            shapes.rect(lines, px - 2, y0 - off - 1.5, 3, 3, 0, .{ .fill = .{ .solid = o.color }, .opacity = 0.9 - 0.25 * @as(f32, @floatFromInt(i)) });
        }
    }

    if (o.glow > 0) {
        var halo = try lines.clone(gpa);
        defer halo.deinit(gpa);
        try filter.blur(gpa, halo, o.glow, .transparent);
        c.draw(halo, 0, 0, .add, 1.4);
    }
    c.draw(lines, 0, 0, .normal, 1);

    // The farthest corner detail (bracket arm plus pips), and the reach of
    // its glow.
    const corner_extent = @max(k, k * 0.8 + 8 + 12 + 2) + o.stroke * 3 + o.glow * 3;
    return .{ .canvas = c, .slice = o.margin + @as(u32, @intFromFloat(@ceil(corner_extent))) };
}

pub const ReticleOptions = struct {
    size: u32 = 256,
    color: Color = Color.hex(0x3fd8ff),
    /// Accent for the inner markers.
    accent: Color = Color.hex(0xff5a3c),
    glow: f32 = 4,
    /// Rotation of the outer arcs in radians, to animate across frames.
    spin: f32 = 0,
};

/// A targeting reticle: graduated outer ring, broken arcs, a crosshair with
/// a gap, and corner markers.
pub fn reticle(gpa: Allocator, o: ReticleOptions) Allocator.Error!Canvas {
    var lines = try Canvas.init(gpa, o.size, o.size);
    defer lines.deinit(gpa);
    const s: f32 = @floatFromInt(o.size);
    const ctr: Point = .{ .x = s / 2, .y = s / 2 };
    const r = s * 0.42;
    const ink: shapes.Paint = .solid(o.color);
    const dim: shapes.Paint = .{ .fill = .{ .solid = o.color }, .opacity = 0.45 };

    shapes.ring(lines, ctr, r, 1.5, ink);
    // Graduations every 5 degrees, longer every 30.
    for (0..72) |i| {
        const a = @as(f32, @floatFromInt(i)) * std.math.tau / 72;
        const long = i % 6 == 0;
        const inner = r - (if (long) s * 0.045 else s * 0.02);
        shapes.line(lines, Point.polar(ctr, inner, a), Point.polar(ctr, r, a), if (long) 2 else 1, .butt, if (long) ink else dim);
    }
    // Four broken arcs that turn with `spin`.
    for (0..4) |i| {
        const a0 = o.spin + @as(f32, @floatFromInt(i)) * std.math.pi / 2.0 + 0.15;
        shapes.arc(lines, ctr, r * 0.78, 3, a0, a0 + std.math.pi / 2.0 - 0.6, ink);
    }
    shapes.ring(lines, ctr, r * 0.55, 1, dim);
    // Crosshair, open in the middle.
    const gap = s * 0.06;
    for ([_][2]f32{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 } }) |d| {
        const from: Point = .{ .x = ctr.x + d[0] * gap, .y = ctr.y + d[1] * gap };
        const to: Point = .{ .x = ctr.x + d[0] * r * 0.7, .y = ctr.y + d[1] * r * 0.7 };
        shapes.line(lines, from, to, 1.5, .butt, ink);
    }
    // Accent chevrons pointing in at the center.
    const acc: shapes.Paint = .solid(o.accent);
    for (0..3) |i| {
        const a = -std.math.pi / 2.0 + @as(f32, @floatFromInt(i)) * std.math.tau / 3.0;
        const tip = Point.polar(ctr, gap * 1.6, a);
        const l = Point.polar(ctr, gap * 2.6, a - 0.25);
        const rr = Point.polar(ctr, gap * 2.6, a + 0.25);
        shapes.polygon(lines, &.{ tip, l, rr }, acc);
    }
    shapes.circle(lines, ctr, 2, acc);

    var out = try Canvas.init(gpa, o.size, o.size);
    errdefer out.deinit(gpa);
    if (o.glow > 0) {
        var halo = try lines.clone(gpa);
        defer halo.deinit(gpa);
        try filter.blur(gpa, halo, o.glow, .transparent);
        out.draw(halo, 0, 0, .add, 1.5);
    }
    out.draw(lines, 0, 0, .normal, 1);
    return out;
}

pub const RadarOptions = struct {
    size: u32 = 192,
    color: Color = Color.hex(0x4dff9a),
    /// Angle of the sweep line in radians (0 = right, clockwise).
    angle: f32 = 0,
    /// Blips as (distance 0-1, angle) pairs. Each fades after the sweep
    /// passes it.
    blips: []const [2]f32 = &.{},
    glow: f32 = 3,
};

/// A round radar scope with a rotating sweep. Render it at evenly spaced
/// angles into a `SpriteSheet` to animate it.
pub fn radar(gpa: Allocator, o: RadarOptions) Allocator.Error!Canvas {
    var c = try Canvas.init(gpa, o.size, o.size);
    errdefer c.deinit(gpa);
    const s: f32 = @floatFromInt(o.size);
    const ctr: Point = .{ .x = s / 2, .y = s / 2 };
    const r = s * 0.46;

    shapes.circle(c, ctr, r, .solid(o.color.scale(0.05).withAlpha(0.85)));

    // The sweep: a wedge trailing the line, fading over a quarter turn.
    const trail = std.math.pi / 2.0;
    for (0..o.size) |y| {
        for (0..o.size) |x| {
            const dx = @as(f32, @floatFromInt(x)) + 0.5 - ctr.x;
            const dy = @as(f32, @floatFromInt(y)) + 0.5 - ctr.y;
            const d = @sqrt(dx * dx + dy * dy);
            if (d > r) continue;
            const behind = @mod(o.angle - std.math.atan2(dy, dx), std.math.tau);
            if (behind > trail) continue;
            const k = (1 - behind / trail);
            const edge = std.math.clamp(r - d + 0.5, 0, 1);
            c.blend(@intCast(x), @intCast(y), o.color, k * k * 0.45 * edge, .add);
        }
    }

    var lines = try Canvas.init(gpa, o.size, o.size);
    defer lines.deinit(gpa);
    const ink: shapes.Paint = .solid(o.color);
    const dim: shapes.Paint = .{ .fill = .{ .solid = o.color }, .opacity = 0.35 };
    shapes.ring(lines, ctr, r, 2, ink);
    for (1..4) |i| shapes.ring(lines, ctr, r * @as(f32, @floatFromInt(i)) / 4, 1, dim);
    shapes.line(lines, .{ .x = ctr.x - r, .y = ctr.y }, .{ .x = ctr.x + r, .y = ctr.y }, 1, .butt, dim);
    shapes.line(lines, .{ .x = ctr.x, .y = ctr.y - r }, .{ .x = ctr.x, .y = ctr.y + r }, 1, .butt, dim);
    shapes.line(lines, ctr, Point.polar(ctr, r, o.angle), 2, .round, ink);
    for (o.blips) |b| {
        const behind = @mod(o.angle - b[1], std.math.tau);
        const k = 1 - behind / std.math.tau;
        shapes.circle(lines, Point.polar(ctr, r * b[0], b[1]), 3, .{ .fill = .{ .solid = o.color }, .opacity = k * k });
    }

    if (o.glow > 0) {
        var halo = try lines.clone(gpa);
        defer halo.deinit(gpa);
        try filter.blur(gpa, halo, o.glow, .transparent);
        c.draw(halo, 0, 0, .add, 1.2);
    }
    c.draw(lines, 0, 0, .add, 1);
    return c;
}

const testing = std.testing;

test "panel corners hold the detail and edges are uniform" {
    const gpa = testing.allocator;
    var p = try panel(gpa, .{});
    defer p.deinit(gpa);
    const c = p.canvas;
    try testing.expect(p.slice * 2 < c.width);
    // Within the stretched band, every column along the top edge looks the
    // same, so CSS can stretch it without distortion.
    var y: u32 = 0;
    while (y < p.slice) : (y += 1) {
        const ref = c.pixels[c.index(p.slice, y)];
        var x = p.slice;
        while (x < c.width - p.slice) : (x += 1) {
            const q = c.pixels[c.index(x, y)];
            inline for (0..4) |ch| try testing.expectApproxEqAbs(ref[ch], q[ch], 1e-3);
        }
    }
    // The outline itself is opaque, the margin's outer edge is nearly empty.
    try testing.expect(c.get(c.width / 2, 14).a > 0.9);
    try testing.expect(c.get(c.width / 2, 0).a < 0.05);
}

test "reticle and radar render into their squares" {
    const gpa = testing.allocator;
    var r = try reticle(gpa, .{ .size = 96 });
    defer r.deinit(gpa);
    try testing.expect(r.get(48, 48).a > 0.5);
    try testing.expect(r.get(1, 1).a < 0.01);

    var a = try radar(gpa, .{ .size = 96, .angle = 0, .blips = &.{.{ 0.5, -0.3 }} });
    defer a.deinit(gpa);
    // Just behind the sweep line glows more than just ahead of it.
    const behind = a.get(70, 44);
    const ahead = a.get(70, 52);
    try testing.expect(behind.g > ahead.g);
}
