//! Whole-canvas filters: blur, glow and scanlines.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Canvas = @import("Canvas.zig");
const Px = Canvas.Px;

/// What a blur sees beyond the canvas edges.
pub const Edge = enum {
    /// Nothing: light near an edge spreads out and fades. Right for sprites.
    transparent,
    /// The opposite edge, so tileable images stay tileable.
    wrap,
};

/// An approximate Gaussian blur with standard deviation `sigma` pixels:
/// three box blurs per axis, each linear time whatever the radius.
pub fn blur(gpa: Allocator, c: Canvas, sigma: f32, edge: Edge) Allocator.Error!void {
    if (sigma <= 0) return;
    const scratch = try gpa.alloc(Px, @max(c.width, c.height));
    defer gpa.free(scratch);
    const line = try gpa.alloc(Px, @max(c.width, c.height));
    defer gpa.free(line);
    const radii = boxRadii(sigma);

    for (0..c.height) |y| {
        const row = c.pixels[y * c.width ..][0..c.width];
        for (radii) |r| boxPass(row, scratch[0..c.width], r, edge);
    }
    for (0..c.width) |x| {
        const col = line[0..c.height];
        for (col, 0..) |*p, y| p.* = c.pixels[y * c.width + x];
        for (radii) |r| boxPass(col, scratch[0..c.height], r, edge);
        for (col, 0..) |p, y| c.pixels[y * c.width + x] = p;
    }
}

/// Radii of three box filters whose combination approximates a Gaussian
/// (Kovesi, "Fast almost-Gaussian filtering").
fn boxRadii(sigma: f32) [3]u32 {
    const n = 3.0;
    const w_ideal = @sqrt(12 * sigma * sigma / n + 1);
    var wl: i32 = @intFromFloat(@floor(w_ideal));
    if (@mod(wl, 2) == 0) wl -= 1;
    const wu = wl + 2;
    const wlf: f32 = @floatFromInt(wl);
    const m_ideal = (12 * sigma * sigma - n * wlf * wlf - 4 * n * wlf - 3 * n) / (-4 * wlf - 4);
    const m: i32 = @intFromFloat(@round(m_ideal));
    var out: [3]u32 = undefined;
    for (&out, 0..) |*r, i| {
        const w = if (@as(i32, @intCast(i)) < m) wl else wu;
        r.* = @intCast(@max(0, @divTrunc(w - 1, 2)));
    }
    return out;
}

/// One box blur of radius `r` along `data`, using `tmp` as scratch.
fn boxPass(data: []Px, tmp: []Px, r: u32, edge: Edge) void {
    if (r == 0) return;
    const ri: i64 = r;
    // The running sum is kept in f64: in f32 it drifts by rounding, leaving
    // faint noise long after the window has passed a bright pixel.
    const Acc = @Vector(4, f64);
    const inv: Acc = @splat(1 / @as(f64, @floatFromInt(2 * r + 1)));
    const at = struct {
        fn f(d: []const Px, i: i64, e: Edge) Acc {
            const len: i64 = @intCast(d.len);
            if (i >= 0 and i < len) return @floatCast(d[@intCast(i)]);
            return switch (e) {
                .transparent => @splat(0),
                .wrap => @floatCast(d[@intCast(@mod(i, len))]),
            };
        }
    }.f;
    var sum: Acc = @splat(0);
    var i: i64 = -ri;
    while (i <= ri) : (i += 1) sum += at(data, i, edge);
    for (tmp, 0..) |*t, k| {
        t.* = @floatCast(@max(sum * inv, @as(Acc, @splat(0))));
        const ki: i64 = @intCast(k);
        sum += at(data, ki + ri + 1, edge) - at(data, ki - ri, edge);
    }
    @memcpy(data, tmp);
}

/// Adds a blurred copy of the canvas to itself, so bright shapes bleed
/// light around them. `strength` scales the added halo.
pub fn glow(gpa: Allocator, c: Canvas, sigma: f32, strength: f32, edge: Edge) Allocator.Error!void {
    var halo = try c.clone(gpa);
    defer halo.deinit(gpa);
    try blur(gpa, halo, sigma, edge);
    c.draw(halo, 0, 0, .add, strength);
}

/// Darkens every `period`-th row band to imitate a CRT or hologram
/// display. `depth` 0 does nothing; 1 blacks the dark rows out.
pub fn scanlines(c: Canvas, period: u32, depth: f32) void {
    for (0..c.height) |y| {
        const phase = @as(f32, @floatFromInt(y % period)) / @as(f32, @floatFromInt(period));
        // A smooth dip in the second half of each period.
        const k = 1 - depth * (0.5 - 0.5 * @cos(phase * std.math.tau));
        for (c.pixels[y * c.width ..][0..c.width]) |*p| p.* *= @splat(k);
    }
}

const testing = std.testing;
const Color = @import("color.zig").Color;

fn total(c: Canvas) f32 {
    var s: f32 = 0;
    for (c.pixels) |p| s += p[3];
    return s;
}

test "wrapped blur conserves energy and spreads symmetrically" {
    var c = try Canvas.init(testing.allocator, 32, 32);
    defer c.deinit(testing.allocator);
    c.blend(16, 16, Color.white, 1, .normal);
    try blur(testing.allocator, c, 3, .wrap);
    try testing.expectApproxEqRel(1, total(c), 1e-4);
    try testing.expect(c.get(16, 16).a < 0.1);
    try testing.expectApproxEqAbs(c.pixels[c.index(13, 16)][3], c.pixels[c.index(19, 16)][3], 1e-6);
    try testing.expectApproxEqAbs(c.pixels[c.index(16, 13)][3], c.pixels[c.index(13, 16)][3], 1e-6);
}

test "wrapped blur crosses edges; transparent blur loses light there" {
    var a = try Canvas.init(testing.allocator, 16, 16);
    defer a.deinit(testing.allocator);
    a.blend(0, 8, Color.white, 1, .normal);
    var b = try a.clone(testing.allocator);
    defer b.deinit(testing.allocator);
    try blur(testing.allocator, a, 2, .wrap);
    try blur(testing.allocator, b, 2, .transparent);
    try testing.expect(a.pixels[a.index(15, 8)][3] > 0);
    try testing.expect(b.pixels[b.index(15, 8)][3] < 1e-6);
    try testing.expect(total(b) < total(a));
}

test "box radii approximate the requested sigma" {
    // Whole-pixel boxes cannot match tiny sigmas closely, so start at 2.5.
    for ([_]f32{ 2.5, 6, 20 }) |sigma| {
        var variance: f32 = 0;
        for (boxRadii(sigma)) |r| {
            const w: f32 = @floatFromInt(2 * r + 1);
            variance += (w * w - 1) / 12;
        }
        try testing.expectApproxEqRel(sigma, @sqrt(variance), 0.15);
    }
}

test "glow brightens surroundings, scanlines darken alternate bands" {
    var c = try Canvas.init(testing.allocator, 16, 16);
    defer c.deinit(testing.allocator);
    c.blend(8, 8, Color.white, 1, .normal);
    try glow(testing.allocator, c, 2, 1, .transparent);
    try testing.expect(c.get(10, 8).a > 0);
    c.fill(Color.white);
    scanlines(c, 4, 0.5);
    try testing.expectApproxEqAbs(1, c.pixels[c.index(0, 0)][0], 1e-6);
    try testing.expectApproxEqAbs(0.5, c.pixels[c.index(0, 2)][0], 1e-6);
}
