//! A floating-point RGBA image: linear light, premultiplied alpha, and no
//! upper limit on brightness until it is encoded. Every drawing function in
//! the renderer writes into a Canvas, and `toRgba8` turns one into the 8-bit
//! sRGB pixels that `png.encode` writes.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Color = @import("color.zig").Color;
const color = @import("color.zig");

const Canvas = @This();

pub const Px = @Vector(4, f32);

/// How a drawn color combines with what is already on the canvas.
pub const Blend = enum {
    /// Porter-Duff source-over: paint covers what is beneath it.
    normal,
    /// Adds light, for glows, stars and holograms. Never darkens.
    add,
    /// Screen: brightens like `add` but saturates more gently.
    screen,
};

width: u32,
height: u32,
/// Row-major, top row first.
pixels: []Px,

pub fn init(gpa: Allocator, width: u32, height: u32) Allocator.Error!Canvas {
    const pixels = try gpa.alloc(Px, @as(usize, width) * height);
    @memset(pixels, @splat(0));
    return .{ .width = width, .height = height, .pixels = pixels };
}

pub fn deinit(c: *Canvas, gpa: Allocator) void {
    gpa.free(c.pixels);
    c.* = undefined;
}

pub fn clone(c: Canvas, gpa: Allocator) Allocator.Error!Canvas {
    return .{ .width = c.width, .height = c.height, .pixels = try gpa.dupe(Px, c.pixels) };
}

pub fn fill(c: Canvas, col: Color) void {
    @memset(c.pixels, col.premul());
}

pub fn index(c: Canvas, x: u32, y: u32) usize {
    return @as(usize, y) * c.width + x;
}

/// The straight-alpha color at a pixel.
pub fn get(c: Canvas, x: u32, y: u32) Color {
    const p = c.pixels[c.index(x, y)];
    if (p[3] <= 0) return .{ .r = p[0], .g = p[1], .b = p[2], .a = 0 };
    return .{ .r = p[0] / p[3], .g = p[1] / p[3], .b = p[2] / p[3], .a = p[3] };
}

/// Blends `col` into one pixel with the given coverage (0-1). Pixels
/// outside the canvas are ignored, so callers can draw past the edges.
pub fn blend(c: Canvas, x: i32, y: i32, col: Color, coverage: f32, mode: Blend) void {
    if (x < 0 or y < 0 or x >= c.width or y >= c.height) return;
    const i = c.index(@intCast(x), @intCast(y));
    c.pixels[i] = blendPx(c.pixels[i], col.premul() * @as(Px, @splat(coverage)), mode);
}

pub fn blendPx(dst: Px, src: Px, mode: Blend) Px {
    return switch (mode) {
        .normal => src + dst * @as(Px, @splat(1 - src[3])),
        .add => blk: {
            var out = dst + src;
            out[3] = @min(1, dst[3] + src[3]);
            break :blk out;
        },
        .screen => blk: {
            const one: Px = @splat(1);
            var out = src + dst - src * dst;
            // Light brighter than white keeps adding rather than inverting.
            out = @select(f32, dst > one, dst + src, out);
            out[3] = @min(1, dst[3] + src[3] - dst[3] * src[3]);
            break :blk out;
        },
    };
}

/// Composites `src` onto `c` at offset (dx, dy), scaled by `opacity`.
pub fn draw(c: Canvas, src: Canvas, dx: i32, dy: i32, mode: Blend, opacity: f32) void {
    const k: Px = @splat(opacity);
    var y: u32 = 0;
    while (y < src.height) : (y += 1) {
        const ty = @as(i64, dy) + y;
        if (ty < 0 or ty >= c.height) continue;
        var x: u32 = 0;
        while (x < src.width) : (x += 1) {
            const tx = @as(i64, dx) + x;
            if (tx < 0 or tx >= c.width) continue;
            const i = c.index(@intCast(tx), @intCast(ty));
            c.pixels[i] = blendPx(c.pixels[i], src.pixels[src.index(x, y)] * k, mode);
        }
    }
}

/// Copies `src` into `c` at (dx, dy), replacing what is there.
pub fn blit(c: Canvas, src: Canvas, dx: u32, dy: u32) void {
    var y: u32 = 0;
    while (y < src.height and dy + y < c.height) : (y += 1) {
        const w = @min(src.width, c.width -| dx);
        const from = src.pixels[src.index(0, y)..][0..w];
        @memcpy(c.pixels[c.index(dx, dy + y)..][0..w], from);
    }
}

/// Multiplies every pixel, including alpha, by `k`.
pub fn fade(c: Canvas, k: f32) void {
    for (c.pixels) |*p| p.* *= @splat(k);
}

/// A canvas `factor` times smaller, each pixel the average of a
/// factor x factor block. Rendering large and shrinking is how the 3D
/// renderer anti-aliases.
pub fn downsample(c: Canvas, gpa: Allocator, factor: u32) Allocator.Error!Canvas {
    std.debug.assert(factor > 0 and c.width % factor == 0 and c.height % factor == 0);
    var out = try init(gpa, c.width / factor, c.height / factor);
    const inv: Px = @splat(1 / @as(f32, @floatFromInt(factor * factor)));
    for (0..out.height) |y| {
        for (0..out.width) |x| {
            var sum: Px = @splat(0);
            for (0..factor) |sy| {
                const row = c.pixels[(y * factor + sy) * c.width + x * factor ..][0..factor];
                for (row) |p| sum += p;
            }
            out.pixels[y * out.width + x] = sum * inv;
        }
    }
    return out;
}

pub const ToneMap = enum {
    /// Values above 1 are cut off at white.
    clamp,
    /// Highlights roll off smoothly towards white (Reinhard on luminance),
    /// so bright additive glows keep their color instead of clipping.
    soft,
};

/// Encodes the canvas as 8-bit sRGB RGBA with straight alpha, the layout
/// PNG expects. The caller owns the result.
pub fn toRgba8(c: Canvas, gpa: Allocator, tone: ToneMap) Allocator.Error![]u8 {
    const out = try gpa.alloc(u8, c.pixels.len * 4);
    for (c.pixels, 0..) |p, i| {
        const a = std.math.clamp(p[3], 0, 1);
        if (quantize(a) == 0) {
            // Fully transparent once quantized. Dividing by a near-zero
            // alpha would turn rounding noise into random colors.
            out[i * 4 ..][0..4].* = .{ 0, 0, 0, 0 };
            continue;
        }
        var rgb: [3]f32 = if (a > 0) .{ p[0] / a, p[1] / a, p[2] / a } else .{ 0, 0, 0 };
        if (tone == .soft) {
            const lum = 0.2126 * rgb[0] + 0.7152 * rgb[1] + 0.0722 * rgb[2];
            // Leave everything below 0.6 untouched; compress the rest so
            // that infinity maps to 1.
            const knee: f32 = 0.6;
            if (lum > knee) {
                const over = lum - knee;
                const mapped = knee + (1 - knee) * over / (over + (1 - knee));
                const k = mapped / lum;
                for (&rgb) |*v| v.* *= k;
            }
        }
        for (rgb, 0..) |v, ch| out[i * 4 + ch] = quantize(color.linearToSrgb(v));
        out[i * 4 + 3] = quantize(a);
    }
    return out;
}

fn quantize(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

const testing = std.testing;

test "normal blending covers, additive blending accumulates" {
    var c = try init(testing.allocator, 2, 1);
    defer c.deinit(testing.allocator);
    c.fill(.black);
    c.blend(0, 0, Color.white, 0.5, .normal);
    try testing.expectApproxEqAbs(0.5, c.get(0, 0).r, 1e-6);
    c.blend(1, 0, Color.gray(0.75), 1, .add);
    c.blend(1, 0, Color.gray(0.75), 1, .add);
    try testing.expectApproxEqAbs(1.5, c.get(1, 0).r, 1e-6);
    try testing.expectApproxEqAbs(1, c.get(1, 0).a, 1e-6);
    // Off-canvas writes are ignored.
    c.blend(-1, 0, Color.white, 1, .normal);
    c.blend(0, 5, Color.white, 1, .normal);
}

test "transparent canvases composite with premultiplied alpha" {
    var c = try init(testing.allocator, 1, 1);
    defer c.deinit(testing.allocator);
    c.blend(0, 0, Color.hex(0xff0000), 0.5, .normal);
    c.blend(0, 0, Color.hex(0x0000ff), 0.5, .normal);
    const p = c.get(0, 0);
    try testing.expectApproxEqAbs(0.75, p.a, 1e-6);
    // Blue went on last, so it outweighs red.
    try testing.expect(p.b > p.r and p.r > 0);
}

test "downsample averages blocks" {
    var c = try init(testing.allocator, 4, 2);
    defer c.deinit(testing.allocator);
    c.blend(0, 0, Color.white, 1, .normal);
    c.blend(3, 1, Color.white, 1, .normal);
    c.blend(2, 1, Color.white, 1, .normal);
    var small = try c.downsample(testing.allocator, 2);
    defer small.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 2), small.width);
    try testing.expectApproxEqAbs(0.25, small.pixels[0][3], 1e-6);
    try testing.expectApproxEqAbs(0.5, small.pixels[1][3], 1e-6);
}

test "toRgba8 writes sRGB with straight alpha and tone maps highlights" {
    var c = try init(testing.allocator, 3, 1);
    defer c.deinit(testing.allocator);
    c.blend(0, 0, Color.hex(0x808080), 0.5, .normal);
    c.blend(1, 0, Color.gray(4), 1, .normal);
    c.blend(2, 0, Color.hex(0x336699), 1, .normal);
    const clamped = try c.toRgba8(testing.allocator, .clamp);
    defer testing.allocator.free(clamped);
    try testing.expectEqualSlices(u8, &.{ 0x80, 0x80, 0x80, 128, 255, 255, 255, 255, 0x33, 0x66, 0x99, 255 }, clamped);
    const soft = try c.toRgba8(testing.allocator, .soft);
    defer testing.allocator.free(soft);
    // A bright highlight stays below pure white; dark colors are untouched.
    try testing.expect(soft[4] < 255 and soft[4] > 230);
    try testing.expectEqualSlices(u8, &.{ 0x33, 0x66, 0x99 }, soft[8..11]);
}

test "draw composites at an offset and clips" {
    var dst = try init(testing.allocator, 3, 3);
    defer dst.deinit(testing.allocator);
    var src = try init(testing.allocator, 2, 2);
    defer src.deinit(testing.allocator);
    src.fill(Color.white);
    dst.draw(src, 2, -1, .normal, 0.5);
    try testing.expectApproxEqAbs(0.5, dst.get(2, 0).a, 1e-6);
    try testing.expectEqual(@as(f32, 0), dst.get(1, 0).a);
    try testing.expectEqual(@as(f32, 0), dst.get(2, 1).a);
}
