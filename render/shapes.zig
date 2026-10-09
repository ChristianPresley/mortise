//! Anti-aliased 2D shapes. Each shape is a signed distance function (SDF):
//! negative inside, positive outside, in pixels. A pixel's coverage is
//! how far its center sits inside the edge, clamped to one pixel, which
//! gives smooth edges at any angle without supersampling.
//!
//! Coordinates are in pixels with (0, 0) at the top-left corner of the
//! canvas, so the center of pixel (x, y) is (x + 0.5, y + 0.5).

const std = @import("std");
const Canvas = @import("Canvas.zig");
const Color = @import("color.zig").Color;

pub const Point = struct {
    x: f32,
    y: f32,

    pub fn add(a: Point, b: Point) Point {
        return .{ .x = a.x + b.x, .y = a.y + b.y };
    }
    pub fn sub(a: Point, b: Point) Point {
        return .{ .x = a.x - b.x, .y = a.y - b.y };
    }
    pub fn scale(a: Point, k: f32) Point {
        return .{ .x = a.x * k, .y = a.y * k };
    }
    pub fn dot(a: Point, b: Point) f32 {
        return a.x * b.x + a.y * b.y;
    }
    pub fn len(a: Point) f32 {
        return @sqrt(a.dot(a));
    }
    /// The point at `angle` radians (0 = right, increasing clockwise on
    /// screen) and distance `r` from `center`.
    pub fn polar(center: Point, r: f32, angle: f32) Point {
        return .{ .x = center.x + r * @cos(angle), .y = center.y + r * @sin(angle) };
    }
};

pub const Stop = struct {
    /// Position along the gradient, 0 to 1.
    t: f32,
    color: Color,
};

/// What a shape is filled with.
pub const Fill = union(enum) {
    solid: Color,
    /// Color stops spread from `from` (t = 0) to `to` (t = 1).
    linear: struct { from: Point, to: Point, stops: []const Stop },
    /// Color stops spread from `center` (t = 0) out to `radius` (t = 1).
    radial: struct { center: Point, radius: f32, stops: []const Stop },

    pub fn at(f: Fill, p: Point) Color {
        return switch (f) {
            .solid => |c| c,
            .linear => |g| blk: {
                const d = g.to.sub(g.from);
                const t = p.sub(g.from).dot(d) / @max(d.dot(d), 1e-12);
                break :blk sample(g.stops, t);
            },
            .radial => |g| sample(g.stops, p.sub(g.center).len() / @max(g.radius, 1e-6)),
        };
    }
};

/// The color at `t` along sorted gradient stops. Beyond the ends the end
/// colors continue.
pub fn sample(stops: []const Stop, t: f32) Color {
    std.debug.assert(stops.len > 0);
    if (t <= stops[0].t) return stops[0].color;
    for (stops[1..], 1..) |s, i| {
        if (t <= s.t) {
            const prev = stops[i - 1];
            const span = s.t - prev.t;
            return if (span <= 0) s.color else prev.color.mix(s.color, (t - prev.t) / span);
        }
    }
    return stops[stops.len - 1].color;
}

pub const Paint = struct {
    fill: Fill,
    blend: Canvas.Blend = .normal,
    opacity: f32 = 1,

    pub fn solid(c: Color) Paint {
        return .{ .fill = .{ .solid = c } };
    }
    /// A solid color that adds light, for glowing lines.
    pub fn glow(c: Color) Paint {
        return .{ .fill = .{ .solid = c }, .blend = .add };
    }
};

/// An axis-aligned box in pixels: x0 <= x < x1, y0 <= y < y1.
const Bounds = struct { x0: i32, y0: i32, x1: i32, y1: i32 };

fn bounds(c: Canvas, min_x: f32, min_y: f32, max_x: f32, max_y: f32) Bounds {
    // One pixel of slack for the anti-aliased fringe.
    const w: f32 = @floatFromInt(c.width);
    const h: f32 = @floatFromInt(c.height);
    return .{
        .x0 = @intFromFloat(std.math.clamp(@floor(min_x) - 1, 0, w)),
        .y0 = @intFromFloat(std.math.clamp(@floor(min_y) - 1, 0, h)),
        .x1 = @intFromFloat(std.math.clamp(@ceil(max_x) + 1, 0, w)),
        .y1 = @intFromFloat(std.math.clamp(@ceil(max_y) + 1, 0, h)),
    };
}

/// Fills every pixel in `b` by the coverage `sdf(ctx, p)` implies.
fn shade(c: Canvas, b: Bounds, paint: Paint, ctx: anytype, comptime sdf: fn (@TypeOf(ctx), Point) f32) void {
    var y = b.y0;
    while (y < b.y1) : (y += 1) {
        var x = b.x0;
        while (x < b.x1) : (x += 1) {
            const p: Point = .{ .x = @as(f32, @floatFromInt(x)) + 0.5, .y = @as(f32, @floatFromInt(y)) + 0.5 };
            const cov = std.math.clamp(0.5 - sdf(ctx, p), 0, 1);
            if (cov <= 0) continue;
            c.blend(x, y, paint.fill.at(p), cov * paint.opacity, paint.blend);
        }
    }
}

/// A rectangle with optionally rounded corners.
pub fn rect(c: Canvas, x: f32, y: f32, w: f32, h: f32, radius: f32, paint: Paint) void {
    const Ctx = struct { center: Point, half: Point, r: f32 };
    const ctx: Ctx = .{
        .center = .{ .x = x + w / 2, .y = y + h / 2 },
        .half = .{ .x = w / 2, .y = h / 2 },
        .r = @min(radius, @min(w, h) / 2),
    };
    shade(c, bounds(c, x, y, x + w, y + h), paint, ctx, struct {
        fn f(k: Ctx, p: Point) f32 {
            return boxSdf(p.sub(k.center), k.half, k.r);
        }
    }.f);
}

/// The outline of a rectangle, `width` pixels thick, centered on its edge.
pub fn strokeRect(c: Canvas, x: f32, y: f32, w: f32, h: f32, radius: f32, width: f32, paint: Paint) void {
    const Ctx = struct { center: Point, half: Point, r: f32, hw: f32 };
    const ctx: Ctx = .{
        .center = .{ .x = x + w / 2, .y = y + h / 2 },
        .half = .{ .x = w / 2, .y = h / 2 },
        .r = @min(radius, @min(w, h) / 2),
        .hw = width / 2,
    };
    shade(c, bounds(c, x - width, y - width, x + w + width, y + h + width), paint, ctx, struct {
        fn f(k: Ctx, p: Point) f32 {
            return @abs(boxSdf(p.sub(k.center), k.half, k.r)) - k.hw;
        }
    }.f);
}

fn boxSdf(p: Point, half: Point, r: f32) f32 {
    const qx = @abs(p.x) - half.x + r;
    const qy = @abs(p.y) - half.y + r;
    const outside: Point = .{ .x = @max(qx, 0), .y = @max(qy, 0) };
    return outside.len() + @min(@max(qx, qy), 0) - r;
}

pub fn circle(c: Canvas, center: Point, r: f32, paint: Paint) void {
    const Ctx = struct { center: Point, r: f32 };
    shade(c, bounds(c, center.x - r, center.y - r, center.x + r, center.y + r), paint, Ctx{ .center = center, .r = r }, struct {
        fn f(k: Ctx, p: Point) f32 {
            return p.sub(k.center).len() - k.r;
        }
    }.f);
}

/// A circle outline `width` pixels thick.
pub fn ring(c: Canvas, center: Point, r: f32, width: f32, paint: Paint) void {
    arc(c, center, r, width, 0, std.math.tau, paint);
}

/// Part of a ring from angle `a0` to `a1` (radians, clockwise on screen
/// from the positive x axis), with square ends.
pub fn arc(c: Canvas, center: Point, r: f32, width: f32, a0: f32, a1: f32, paint: Paint) void {
    const span = a1 - a0;
    const Ctx = struct { center: Point, r: f32, hw: f32, mid: f32, half_span: f32, full: bool };
    const ctx: Ctx = .{
        .center = center,
        .r = r,
        .hw = width / 2,
        .mid = a0 + span / 2,
        .half_span = @abs(span) / 2,
        .full = @abs(span) >= std.math.tau,
    };
    const ext = r + width;
    shade(c, bounds(c, center.x - ext, center.y - ext, center.x + ext, center.y + ext), paint, ctx, struct {
        fn f(k: Ctx, p: Point) f32 {
            const d = p.sub(k.center);
            const l = d.len();
            const radial = @abs(l - k.r) - k.hw;
            if (k.full) return radial;
            // Angle from the arc's middle, wrapped to [-pi, pi].
            var rel = std.math.atan2(d.y, d.x) - k.mid;
            rel = rel - std.math.tau * @round(rel / std.math.tau);
            const along = (@abs(rel) - k.half_span) * l;
            return @max(radial, along);
        }
    }.f);
}

pub const Cap = enum { round, butt };

/// A straight line `width` pixels thick.
pub fn line(c: Canvas, a: Point, b: Point, width: f32, cap: Cap, paint: Paint) void {
    const Ctx = struct { a: Point, b: Point, hw: f32, cap: Cap };
    const hw = width / 2;
    shade(c, bounds(c, @min(a.x, b.x) - hw, @min(a.y, b.y) - hw, @max(a.x, b.x) + hw, @max(a.y, b.y) + hw), paint, Ctx{ .a = a, .b = b, .hw = hw, .cap = cap }, struct {
        fn f(k: Ctx, p: Point) f32 {
            return segmentSdf(p, k.a, k.b, k.hw, k.cap);
        }
    }.f);
}

fn segmentSdf(p: Point, a: Point, b: Point, hw: f32, cap: Cap) f32 {
    const ab = b.sub(a);
    const ap = p.sub(a);
    const len2 = @max(ab.dot(ab), 1e-12);
    switch (cap) {
        .round => {
            const t = std.math.clamp(ap.dot(ab) / len2, 0, 1);
            return ap.sub(ab.scale(t)).len() - hw;
        },
        .butt => {
            const l = @sqrt(len2);
            const dir = ab.scale(1 / l);
            const along = ap.dot(dir);
            const across = @abs(ap.x * dir.y - ap.y * dir.x);
            const dx = @abs(along - l / 2) - l / 2;
            const dy = across - hw;
            const outside: Point = .{ .x = @max(dx, 0), .y = @max(dy, 0) };
            return outside.len() + @min(@max(dx, dy), 0);
        },
    }
}

/// Connected line segments with round joins. When `closed`, the last point
/// connects back to the first.
pub fn polyline(c: Canvas, points: []const Point, width: f32, closed: bool, paint: Paint) void {
    if (points.len < 2) return;
    const Ctx = struct { pts: []const Point, hw: f32, closed: bool };
    const hw = width / 2;
    const bb = boxOf(points);
    shade(c, bounds(c, bb[0].x - hw, bb[0].y - hw, bb[1].x + hw, bb[1].y + hw), paint, Ctx{ .pts = points, .hw = hw, .closed = closed }, struct {
        fn f(k: Ctx, p: Point) f32 {
            var d: f32 = std.math.inf(f32);
            const n = if (k.closed) k.pts.len else k.pts.len - 1;
            for (0..n) |i| {
                d = @min(d, segmentSdf(p, k.pts[i], k.pts[(i + 1) % k.pts.len], k.hw, .round));
            }
            return d;
        }
    }.f);
}

/// Fills a closed polygon using the nonzero winding rule, so
/// self-intersecting outlines fill solidly.
pub fn polygon(c: Canvas, points: []const Point, paint: Paint) void {
    if (points.len < 3) return;
    const bb = boxOf(points);
    shade(c, bounds(c, bb[0].x, bb[0].y, bb[1].x, bb[1].y), paint, points, polygonSdf);
}

fn polygonSdf(pts: []const Point, p: Point) f32 {
    var d2: f32 = std.math.inf(f32);
    var winding: i32 = 0;
    var j = pts.len - 1;
    for (pts, 0..) |b, i| {
        const a = pts[j];
        j = i;
        const e = b.sub(a);
        const w = p.sub(a);
        const t = std.math.clamp(w.dot(e) / @max(e.dot(e), 1e-12), 0, 1);
        const q = w.sub(e.scale(t));
        d2 = @min(d2, q.dot(q));
        const cross = e.x * w.y - e.y * w.x;
        if (a.y <= p.y) {
            if (b.y > p.y and cross > 0) winding += 1;
        } else if (b.y <= p.y and cross < 0) winding -= 1;
    }
    const d = @sqrt(d2);
    return if (winding != 0) -d else d;
}

fn boxOf(points: []const Point) [2]Point {
    var lo = points[0];
    var hi = points[0];
    for (points[1..]) |p| {
        lo = .{ .x = @min(lo.x, p.x), .y = @min(lo.y, p.y) };
        hi = .{ .x = @max(hi.x, p.x), .y = @max(hi.y, p.y) };
    }
    return .{ lo, hi };
}

/// A soft round dot whose brightness falls off as a Gaussian with standard
/// deviation `sigma`, drawn additively. Stars and light points use it.
/// When `wrap` is set, the parts that fall off one edge come back on the
/// opposite edge, for seamless tiles.
pub fn splat(c: Canvas, center: Point, sigma: f32, col: Color, wrap: bool) void {
    const reach = sigma * 3.5;
    const x0: i32 = @intFromFloat(@floor(center.x - reach));
    const x1: i32 = @intFromFloat(@ceil(center.x + reach));
    const y0: i32 = @intFromFloat(@floor(center.y - reach));
    const y1: i32 = @intFromFloat(@ceil(center.y + reach));
    const inv = 1 / (2 * sigma * sigma);
    const w: i32 = @intCast(c.width);
    const h: i32 = @intCast(c.height);
    var y = y0;
    while (y <= y1) : (y += 1) {
        var x = x0;
        while (x <= x1) : (x += 1) {
            const dx = @as(f32, @floatFromInt(x)) + 0.5 - center.x;
            const dy = @as(f32, @floatFromInt(y)) + 0.5 - center.y;
            const k = @exp(-(dx * dx + dy * dy) * inv);
            if (k < 1.0 / 1024.0) continue;
            const px = if (wrap) @mod(x, w) else x;
            const py = if (wrap) @mod(y, h) else y;
            c.blend(px, py, col, k, .add);
        }
    }
}

const testing = std.testing;

fn alphaAt(c: Canvas, x: u32, y: u32) f32 {
    return c.pixels[c.index(x, y)][3];
}

test "rect covers its interior and anti-aliases a half-pixel edge" {
    var c = try Canvas.init(testing.allocator, 10, 10);
    defer c.deinit(testing.allocator);
    rect(c, 2, 2, 5.5, 4, 0, .solid(.white));
    try testing.expectApproxEqAbs(1, alphaAt(c, 4, 4), 1e-6);
    try testing.expectApproxEqAbs(0.5, alphaAt(c, 7, 4), 1e-6);
    try testing.expectEqual(@as(f32, 0), alphaAt(c, 8, 4));
    try testing.expectEqual(@as(f32, 0), alphaAt(c, 4, 1));
}

test "circle area matches pi r squared" {
    var c = try Canvas.init(testing.allocator, 64, 64);
    defer c.deinit(testing.allocator);
    circle(c, .{ .x = 32, .y = 32 }, 20, .solid(.white));
    var area: f32 = 0;
    for (c.pixels) |p| area += p[3];
    try testing.expectApproxEqRel(std.math.pi * 400, area, 0.005);
}

test "ring and arc" {
    var c = try Canvas.init(testing.allocator, 64, 64);
    defer c.deinit(testing.allocator);
    // The right-hand quarter only: from -45 to +45 degrees.
    arc(c, .{ .x = 32, .y = 32 }, 20, 4, -std.math.pi / 4.0, std.math.pi / 4.0, .solid(.white));
    try testing.expectApproxEqAbs(1, alphaAt(c, 52, 32), 1e-6);
    try testing.expectEqual(@as(f32, 0), alphaAt(c, 11, 32));
    try testing.expectEqual(@as(f32, 0), alphaAt(c, 32, 52));
    try testing.expectEqual(@as(f32, 0), alphaAt(c, 32, 32));
    ring(c, .{ .x = 32, .y = 32 }, 20, 4, .solid(.white));
    try testing.expectApproxEqAbs(1, alphaAt(c, 11, 32), 1e-6);
}

test "line caps" {
    var c = try Canvas.init(testing.allocator, 20, 5);
    defer c.deinit(testing.allocator);
    line(c, .{ .x = 5, .y = 2.5 }, .{ .x = 15, .y = 2.5 }, 3, .butt, .solid(.white));
    try testing.expectApproxEqAbs(1, alphaAt(c, 10, 2), 1e-6);
    try testing.expectEqual(@as(f32, 0), alphaAt(c, 3, 2));
    line(c, .{ .x = 5, .y = 2.5 }, .{ .x = 15, .y = 2.5 }, 3, .round, .solid(.white));
    try testing.expect(alphaAt(c, 4, 2) > 0.9);
}

test "polygon uses nonzero winding" {
    var c = try Canvas.init(testing.allocator, 40, 40);
    defer c.deinit(testing.allocator);
    // A five-pointed star drawn as one self-intersecting path: the
    // pentagon in the middle is filled under nonzero winding.
    var pts: [5]Point = undefined;
    for (&pts, 0..) |*p, i| {
        const a = -std.math.pi / 2.0 + @as(f32, @floatFromInt(i * 2)) * std.math.tau / 5.0;
        p.* = Point.polar(.{ .x = 20, .y = 20 }, 18, a);
    }
    polygon(c, &pts, .solid(.white));
    try testing.expectApproxEqAbs(1, alphaAt(c, 20, 20), 1e-6);
    try testing.expectApproxEqAbs(1, alphaAt(c, 19, 8), 1e-6);
    try testing.expectEqual(@as(f32, 0), alphaAt(c, 2, 2));
}

test "gradients interpolate between stops" {
    const stops = [_]Stop{ .{ .t = 0, .color = .black }, .{ .t = 1, .color = .white } };
    const f: Fill = .{ .linear = .{ .from = .{ .x = 0, .y = 0 }, .to = .{ .x = 10, .y = 0 }, .stops = &stops } };
    try testing.expectApproxEqAbs(0.3, f.at(.{ .x = 3, .y = 7 }).r, 1e-6);
    try testing.expectEqual(@as(f32, 1), f.at(.{ .x = 30, .y = 0 }).r);
    const r: Fill = .{ .radial = .{ .center = .{ .x = 0, .y = 0 }, .radius = 10, .stops = &stops } };
    try testing.expectApproxEqAbs(0.5, r.at(.{ .x = 3, .y = 4 }).r, 1e-6);
}

test "splat wraps around tile edges" {
    var c = try Canvas.init(testing.allocator, 16, 16);
    defer c.deinit(testing.allocator);
    splat(c, .{ .x = 0, .y = 8 }, 1, .white, true);
    try testing.expect(alphaAt(c, 15, 7) > 0.2);
    try testing.expectApproxEqAbs(alphaAt(c, 0, 7), alphaAt(c, 15, 7), 1e-6);
}
