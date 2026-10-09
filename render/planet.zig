//! Procedural planets: a sphere textured with 3D noise, lit from one side,
//! with an atmosphere that glows at the rim. Render several `rotation`
//! values into a `SpriteSheet` for a turning globe.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Canvas = @import("Canvas.zig");
const Color = @import("color.zig").Color;
const shapes = @import("shapes.zig");
const noise = @import("noise.zig");
const Mesh = @import("Mesh.zig");
const render3d = @import("render3d.zig");
const m3 = @import("math3d.zig");
const Vec3 = m3.Vec3;

pub const Kind = enum {
    /// Oceans, continents, ice caps and clouds.
    terran,
    /// Cracked crust over glowing rivers.
    lava,
    /// Pale blue and white, with deep crevasses.
    ice,
    /// Turbulent latitude bands.
    gas,
};

pub const Options = struct {
    size: u32 = 256,
    kind: Kind = .terran,
    seed: u32 = 1,
    /// Turn around the planet's axis, in radians.
    rotation: f32 = 0,
    /// Lean of the axis towards the viewer, in radians.
    tilt: f32 = 0.35,
    /// Atmosphere color, or null for an airless body.
    atmosphere: ?Color = Color.hex(0x5ab4ff),
    /// Direction towards the sun, in view space (x right, y up, z out).
    sun: Vec3 = .{ -0.8, 0.35, 0.55 },
    /// Supersampling per axis.
    samples: u32 = 3,
};

/// Renders a planet centered in a transparent square. The caller owns it.
pub fn render(gpa: Allocator, o: Options) Allocator.Error!Canvas {
    var sphere = try Mesh.uvSphere(gpa, 1, 96, 64);
    defer sphere.deinit(gpa);
    var target = try render3d.Target.init(gpa, o.size, o.size, o.samples);
    defer target.deinit(gpa);

    // The sphere fills this fraction of the frame, leaving room for the
    // atmosphere's halo.
    const fill: f32 = 0.8;
    const cam: render3d.Camera = .{
        .eye = .{ 0, 0, 5 },
        .projection = .{ .orthographic = 1 / fill },
    };
    const model = m3.Mat4.rotation(.{ 1, 0, 0 }, o.tilt).mul(m3.Mat4.rotation(.{ 0, 1, 0 }, o.rotation));
    const surface: Surf = .{ .kind = o.kind, .seed = o.seed };
    try render3d.drawMesh(gpa, &target, sphere, model, cam, .{
        .direction = o.sun,
        .color = Color.gray(1.3),
        .ambient = Color.gray(0.015),
    }, .{
        .surface = .{ .context = &surface, .color = Surf.color },
        .specular = if (o.kind == .terran) 0.25 else 0.05,
        .shininess = 24,
        .rim = if (o.atmosphere) |a| .{ .color = a.withAlpha(0.9), .power = 3.5, .lit = 0.85 } else null,
        .emissive = .black,
    });
    var out = try target.resolve(gpa);
    errdefer out.deinit(gpa);
    if (o.kind == .lava) addLavaGlow(out, o, model, fill);
    if (o.atmosphere) |a| halo(out, a, o.sun, fill);
    return out;
}

const Surf = struct {
    kind: Kind,
    seed: u32,

    fn color(ctx: ?*const anyopaque, p: Vec3, _: Vec3) Color {
        const s: *const Surf = @ptrCast(@alignCast(ctx.?));
        return switch (s.kind) {
            .terran => terran(s.seed, p),
            .lava => lava(s.seed, p),
            .ice => ice(s.seed, p),
            .gas => gas(s.seed, p),
        };
    }
};

fn fbm(seed: u32, p: Vec3, freq: f32, octaves: u32) f32 {
    return noise.fbm3(seed, p[0] * freq, p[1] * freq, p[2] * freq, .{ .octaves = octaves });
}

fn terran(seed: u32, p: Vec3) Color {
    const height = fbm(seed, p, 1.6, 7);
    const lat = @abs(p[1]);
    const stops = [_]shapes.Stop{
        .{ .t = -0.6, .color = Color.hex(0x061a3d) },
        .{ .t = -0.05, .color = Color.hex(0x0f3f7a) },
        .{ .t = 0.0, .color = Color.hex(0x2a7fa8) },
        .{ .t = 0.02, .color = Color.hex(0xb5a46a) },
        .{ .t = 0.08, .color = Color.hex(0x3f7a35) },
        .{ .t = 0.25, .color = Color.hex(0x5b6b2e) },
        .{ .t = 0.4, .color = Color.hex(0x7a6650) },
        .{ .t = 0.5, .color = Color.hex(0xe8e8e8) },
    };
    var c = shapes.sample(&stops, height);
    // Ice caps, ragged by the height field.
    const cap = std.math.clamp((lat + height * 0.3 - 0.82) * 12, 0, 1);
    c = c.mix(Color.hex(0xf2f6fa), cap);
    const clouds = fbm(seed +% 77, p + Vec3{ 3.1, 0, 0 }, 2.4, 5);
    const k = std.math.clamp((clouds - 0.05) * 3, 0, 0.9);
    return c.mix(Color.gray(0.95), k);
}

fn lava(seed: u32, p: Vec3) Color {
    const crust = fbm(seed, p, 2.2, 6);
    const stops = [_]shapes.Stop{
        .{ .t = -0.5, .color = Color.hex(0x1a0f0c) },
        .{ .t = 0.3, .color = Color.hex(0x3a2a24) },
        .{ .t = 0.6, .color = Color.hex(0x5c4a40) },
    };
    return shapes.sample(&stops, crust);
}

/// How brightly the lava rivers glow at a point, 0 to 1.
fn lavaHeat(seed: u32, p: Vec3) f32 {
    const v = fbm(seed +% 13, p, 3, 5);
    // Narrow ridges where the noise crosses zero read as cracks.
    const crack = 1 - std.math.clamp(@abs(v) * 14, 0, 1);
    return crack * crack;
}

fn ice(seed: u32, p: Vec3) Color {
    const h = fbm(seed, p, 2, 6);
    const stops = [_]shapes.Stop{
        .{ .t = -0.4, .color = Color.hex(0x5a86a8) },
        .{ .t = 0.0, .color = Color.hex(0xb9d6e8) },
        .{ .t = 0.4, .color = Color.hex(0xf4fbff) },
    };
    var c = shapes.sample(&stops, h);
    const v = fbm(seed +% 5, p, 4, 4);
    const crevasse = 1 - std.math.clamp(@abs(v) * 20, 0, 1);
    c = c.mix(Color.hex(0x1d4a73), crevasse * 0.8);
    return c;
}

fn gas(seed: u32, p: Vec3) Color {
    const turb = fbm(seed, p, 2.5, 5);
    const band = @sin((p[1] + turb * 0.18) * 14);
    const stops = [_]shapes.Stop{
        .{ .t = -1, .color = Color.hex(0x8a5a3a) },
        .{ .t = -0.3, .color = Color.hex(0xd9b48a) },
        .{ .t = 0.3, .color = Color.hex(0xf2e2c4) },
        .{ .t = 1, .color = Color.hex(0xb07a52) },
    };
    return shapes.sample(&stops, band);
}

/// Adds emissive lava light on the planet's disc. Done in screen space so
/// the glow ignores the sun and shows on the night side too.
fn addLavaGlow(c: Canvas, o: Options, model: m3.Mat4, fill: f32) void {
    const s: f32 = @floatFromInt(o.size);
    const r = s / 2 * fill;
    // The model is a rotation, so its transpose is its inverse.
    const inv = transpose3(model);
    for (0..o.size) |y| {
        for (0..o.size) |x| {
            const nx = (@as(f32, @floatFromInt(x)) + 0.5 - s / 2) / r;
            const ny = -(@as(f32, @floatFromInt(y)) + 0.5 - s / 2) / r;
            const d2 = nx * nx + ny * ny;
            if (d2 >= 1) continue;
            const view: Vec3 = .{ nx, ny, @sqrt(1 - d2) };
            const obj = applyRows(inv, view);
            const heat = lavaHeat(o.seed, obj);
            if (heat <= 0) continue;
            const edge = std.math.clamp((1 - @sqrt(d2)) * r, 0, 1);
            c.blend(@intCast(x), @intCast(y), Color.hex(0xff6a1a).scale(1.8), heat * edge, .add);
        }
    }
}

fn transpose3(m: m3.Mat4) [3]Vec3 {
    return .{
        .{ m.cols[0][0], m.cols[0][1], m.cols[0][2] },
        .{ m.cols[1][0], m.cols[1][1], m.cols[1][2] },
        .{ m.cols[2][0], m.cols[2][1], m.cols[2][2] },
    };
}

fn applyRows(rows: [3]Vec3, v: Vec3) Vec3 {
    return .{ m3.dot(rows[0], v), m3.dot(rows[1], v), m3.dot(rows[2], v) };
}

/// A thin glowing shell outside the disc, brightest on the sunlit side.
fn halo(c: Canvas, col: Color, sun: Vec3, fill: f32) void {
    const s: f32 = @floatFromInt(c.width);
    const r = s / 2 * fill;
    const thick = r * 0.12;
    const sun2 = shapes.Point{ .x = sun[0], .y = -sun[1] };
    const sun_len = @max(sun2.len(), 1e-6);
    for (0..c.height) |y| {
        for (0..c.width) |x| {
            const d: shapes.Point = .{ .x = @as(f32, @floatFromInt(x)) + 0.5 - s / 2, .y = @as(f32, @floatFromInt(y)) + 0.5 - s / 2 };
            const l = d.len();
            if (l < r - 1 or l > r + thick) continue;
            const t = std.math.clamp((l - r) / thick, 0, 1);
            const fall = (1 - t) * (1 - t);
            const facing = 0.25 + 0.75 * std.math.clamp(d.dot(sun2) / (l * sun_len) * 0.5 + 0.5, 0, 1);
            const inside = std.math.clamp(l - r + 1, 0, 1);
            c.blend(@intCast(x), @intCast(y), col, fall * facing * inside * 0.8, .add);
        }
    }
}

const testing = std.testing;

test "planets are round, lit on the sun side and haloed" {
    const gpa = testing.allocator;
    var p = try render(gpa, .{ .size = 64, .samples = 2 });
    defer p.deinit(gpa);
    // Opaque in the middle, empty in the corners.
    try testing.expectApproxEqAbs(1, p.get(32, 32).a, 1e-3);
    try testing.expect(p.get(1, 1).a < 0.01);
    // The sun is to the left, so the left half outshines the right.
    var left: f32 = 0;
    var right: f32 = 0;
    for (0..64) |y| for (0..64) |x| {
        const v = p.pixels[y * 64 + x];
        if (x < 32) left += v[0] + v[1] + v[2] else right += v[0] + v[1] + v[2];
    };
    try testing.expect(left > right * 2);
    // Just outside the disc on the lit side the atmosphere glows.
    try testing.expect(p.get(5, 30).a > 0);
}

test "every kind renders" {
    const gpa = testing.allocator;
    for (std.enums.values(Kind)) |k| {
        var p = try render(gpa, .{ .size = 32, .samples = 1, .kind = k, .atmosphere = null });
        defer p.deinit(gpa);
        try testing.expect(p.get(16, 16).a > 0.99);
    }
}
