//! Colors. Everything the renderer blends is linear-light RGB with straight
//! (not premultiplied) alpha at the API, so mixing and lighting behave
//! physically; conversion to and from sRGB happens only at the edges.

const std = @import("std");

pub const Color = struct {
    r: f32,
    g: f32,
    b: f32,
    a: f32 = 1,

    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };
    pub const black: Color = .{ .r = 0, .g = 0, .b = 0 };
    pub const white: Color = .{ .r = 1, .g = 1, .b = 1 };

    /// An opaque color from a 0xRRGGBB sRGB literal, as written in CSS.
    pub fn hex(rgb: u24) Color {
        return .{
            .r = srgbToLinear(@as(f32, @floatFromInt((rgb >> 16) & 0xff)) / 255),
            .g = srgbToLinear(@as(f32, @floatFromInt((rgb >> 8) & 0xff)) / 255),
            .b = srgbToLinear(@as(f32, @floatFromInt(rgb & 0xff)) / 255),
        };
    }

    /// An opaque gray of linear intensity `v`.
    pub fn gray(v: f32) Color {
        return .{ .r = v, .g = v, .b = v };
    }

    pub fn withAlpha(c: Color, a: f32) Color {
        return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
    }

    /// Multiplies the RGB channels, leaving alpha alone. Values above 1 make
    /// a color brighter than white, which is useful for additive glows.
    pub fn scale(c: Color, k: f32) Color {
        return .{ .r = c.r * k, .g = c.g * k, .b = c.b * k, .a = c.a };
    }

    /// Linear interpolation from `a` (t = 0) to `b` (t = 1).
    pub fn mix(a: Color, b: Color, t: f32) Color {
        return .{
            .r = a.r + (b.r - a.r) * t,
            .g = a.g + (b.g - a.g) * t,
            .b = a.b + (b.b - a.b) * t,
            .a = a.a + (b.a - a.a) * t,
        };
    }

    /// Component-wise product, for tinting by light.
    pub fn mul(a: Color, b: Color) Color {
        return .{ .r = a.r * b.r, .g = a.g * b.g, .b = a.b * b.b, .a = a.a * b.a };
    }

    pub fn add(a: Color, b: Color) Color {
        return .{ .r = a.r + b.r, .g = a.g + b.g, .b = a.b + b.b, .a = @min(1, a.a + b.a) };
    }

    /// The color as a premultiplied vector, the canvas's storage format.
    pub fn premul(c: Color) @Vector(4, f32) {
        return .{ c.r * c.a, c.g * c.a, c.b * c.a, c.a };
    }

    /// Approximate color of a black body at `kelvin`, normalized so its
    /// brightest channel is 1. Good enough for star tints (1,000-40,000 K).
    pub fn blackBody(kelvin: f32) Color {
        // Tanner Helland's fit, done in sRGB and then linearized.
        const t = std.math.clamp(kelvin, 1000, 40000) / 100;
        const r: f32 = if (t <= 66) 255 else 329.698727446 * std.math.pow(f32, t - 60, -0.1332047592);
        const g: f32 = if (t <= 66)
            99.4708025861 * @log(t) - 161.1195681661
        else
            288.1221695283 * std.math.pow(f32, t - 60, -0.0755148492);
        const b: f32 = if (t >= 66) 255 else if (t <= 19) 0 else 138.5177312231 * @log(t - 10) - 305.0447927307;
        const c: Color = .{
            .r = srgbToLinear(std.math.clamp(r, 0, 255) / 255),
            .g = srgbToLinear(std.math.clamp(g, 0, 255) / 255),
            .b = srgbToLinear(std.math.clamp(b, 0, 255) / 255),
        };
        const m = @max(c.r, @max(c.g, c.b));
        return c.scale(1 / m);
    }
};

pub fn srgbToLinear(v: f32) f32 {
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

pub fn linearToSrgb(v: f32) f32 {
    const c = std.math.clamp(v, 0, 1);
    return if (c <= 0.0031308) c * 12.92 else 1.055 * std.math.pow(f32, c, 1.0 / 2.4) - 0.055;
}

const expectApprox = std.testing.expectApproxEqAbs;

test "hex round-trips through linear light" {
    const c = Color.hex(0x22e6ff);
    try expectApprox(@as(f32, 0x22) / 255, linearToSrgb(c.r), 1e-5);
    try expectApprox(@as(f32, 0xe6) / 255, linearToSrgb(c.g), 1e-5);
    try expectApprox(1, linearToSrgb(c.b), 1e-5);
    // Mid sRGB gray is much darker than 0.5 in linear light.
    try expectApprox(0.2158605, Color.hex(0x808080).r, 1e-5);
}

test "black body runs from orange to blue" {
    const cool = Color.blackBody(3000);
    const hot = Color.blackBody(12000);
    try std.testing.expect(cool.r > cool.b);
    try std.testing.expect(hot.b > hot.r);
    try expectApprox(1, @max(hot.r, @max(hot.g, hot.b)), 1e-6);
}

test "mix interpolates every channel" {
    const m = Color.mix(.black, Color.white.withAlpha(0), 0.25);
    try expectApprox(0.25, m.g, 1e-6);
    try expectApprox(0.75, m.a, 1e-6);
}
