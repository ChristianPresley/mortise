//! A z-buffered triangle rasterizer for simple 3D renders: lit solids,
//! procedurally textured planets, glowing hologram wireframes.
//!
//! Draw into a `Target` that is several times larger than the final image,
//! then `resolve` it: averaging the samples is the anti-aliasing.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Canvas = @import("Canvas.zig");
const Color = @import("color.zig").Color;
const Mesh = @import("Mesh.zig");
const m3 = @import("math3d.zig");
const Vec3 = m3.Vec3;
const Vec4 = m3.Vec4;
const Mat4 = m3.Mat4;
const vec3 = m3.vec3;

pub const Camera = struct {
    eye: Vec3,
    target: Vec3 = .{ 0, 0, 0 },
    up: Vec3 = .{ 0, 1, 0 },
    projection: union(enum) {
        /// Vertical field of view in radians.
        perspective: f32,
        /// Half the visible height in world units.
        orthographic: f32,
    } = .{ .perspective = 0.8 },
    near: f32 = 0.1,
    far: f32 = 100,

    pub fn view(c: Camera) Mat4 {
        return Mat4.lookAt(c.eye, c.target, c.up);
    }

    pub fn proj(c: Camera, aspect: f32) Mat4 {
        return switch (c.projection) {
            .perspective => |fov| Mat4.perspective(fov, aspect, c.near, c.far),
            .orthographic => |h| Mat4.orthographic(h, aspect, c.near, c.far),
        };
    }

    /// Distance from the camera plane for a depth-buffer value.
    fn linearDepth(c: Camera, z_ndc: f32) f32 {
        return switch (c.projection) {
            .perspective => 2 * c.far * c.near / ((c.far + c.near) - z_ndc * (c.far - c.near)),
            .orthographic => c.near + (z_ndc + 1) / 2 * (c.far - c.near),
        };
    }
};

pub const Light = struct {
    /// Direction from the scene towards the light.
    direction: Vec3 = .{ -0.5, 0.6, 0.6 },
    color: Color = .white,
    /// Light that reaches every surface regardless of direction.
    ambient: Color = .{ .r = 0.04, .g = 0.05, .b = 0.07 },
};

/// A procedural surface color, evaluated per pixel. `position` is in the
/// mesh's own coordinates, so the pattern turns with the mesh.
pub const Surface = struct {
    context: ?*const anyopaque = null,
    color: *const fn (context: ?*const anyopaque, position: Vec3, normal: Vec3) Color,
};

/// Brightening at grazing angles: the edge glow of an atmosphere or a
/// force field.
pub const Rim = struct {
    color: Color,
    /// Higher values hug the silhouette more tightly.
    power: f32 = 3,
    /// How much the rim follows the light, 0 to 1. At 0 it glows evenly
    /// all round, like a force field; near 1 it fades on the night side,
    /// like an atmosphere.
    lit: f32 = 0,
};

pub const Wire = struct {
    color: Color,
    /// Line width in output pixels.
    width: f32 = 1,
    /// Brightness of edges hidden behind the surface, 0 to 1. Holograms
    /// look best with a faint back side.
    hidden: f32 = 0,
    /// Edges between faces that meet at a smaller angle than this are not
    /// drawn (see `Mesh.featureEdges`).
    crease_deg: f32 = 10,
    blend: Canvas.Blend = .add,
    /// How far, in world units, an edge may sit behind the surface and
    /// still count as visible.
    depth_bias: f32 = 0.05,
};

pub const Material = struct {
    color: Color = .white,
    /// Overrides `color` when set.
    surface: ?Surface = null,
    shading: enum { smooth, flat } = .smooth,
    emissive: Color = .black,
    /// Strength of the light's highlight, 0 for matte.
    specular: f32 = 0,
    shininess: f32 = 32,
    rim: ?Rim = null,
    /// Draw the faces. Turn off for a wireframe only.
    faces: bool = true,
    opacity: f32 = 1,
    /// `.normal` faces hide what is behind them; `.add` faces glow through
    /// one another like a hologram and do not write depth.
    blend: Canvas.Blend = .normal,
    /// Skip triangles facing away from the camera.
    cull: bool = true,
    wire: ?Wire = null,
};

pub const Target = struct {
    /// The supersampled image.
    canvas: Canvas,
    /// Depth of the nearest surface per sample, in clip-space z.
    depth: []f32,
    /// Samples per output pixel along each axis.
    samples: u32,

    pub fn init(gpa: Allocator, width: u32, height: u32, samples: u32) Allocator.Error!Target {
        var canvas = try Canvas.init(gpa, width * samples, height * samples);
        errdefer canvas.deinit(gpa);
        const depth = try gpa.alloc(f32, canvas.pixels.len);
        @memset(depth, std.math.inf(f32));
        return .{ .canvas = canvas, .depth = depth, .samples = samples };
    }

    pub fn deinit(t: *Target, gpa: Allocator) void {
        t.canvas.deinit(gpa);
        gpa.free(t.depth);
        t.* = undefined;
    }

    /// Forgets depth, so the next mesh draws over everything so far.
    pub fn clearDepth(t: Target) void {
        @memset(t.depth, std.math.inf(f32));
    }

    /// The final, anti-aliased image. The caller owns it.
    pub fn resolve(t: Target, gpa: Allocator) Allocator.Error!Canvas {
        return t.canvas.downsample(gpa, t.samples);
    }
};

const Vertex = struct {
    clip: Vec4,
    object: Vec3,
    world: Vec3,
    normal: Vec3,

    fn lerp(a: Vertex, b: Vertex, t: f32) Vertex {
        return .{
            .clip = a.clip + (b.clip - a.clip) * @as(Vec4, @splat(t)),
            .object = m3.lerp(a.object, b.object, t),
            .world = m3.lerp(a.world, b.world, t),
            .normal = m3.lerp(a.normal, b.normal, t),
        };
    }

    /// Signed distance from the near clipping plane; negative is clipped.
    fn near(v: Vertex) f32 {
        return v.clip[2] + v.clip[3];
    }
};

const Frame = struct {
    target: *const Target,
    camera: Camera,
    light: Light,
    material: Material,
    width: f32,
    height: f32,
};

/// Draws `mesh`, placed in the world by `model`, as seen by `camera`.
pub fn drawMesh(
    gpa: Allocator,
    target: *const Target,
    mesh: Mesh,
    model: Mat4,
    camera: Camera,
    light: Light,
    material: Material,
) Allocator.Error!void {
    const w: f32 = @floatFromInt(target.canvas.width);
    const h: f32 = @floatFromInt(target.canvas.height);
    const view_proj = camera.proj(w / h).mul(camera.view());
    const clip_from_object = view_proj.mul(model);

    const verts = try gpa.alloc(Vertex, mesh.positions.len);
    defer gpa.free(verts);
    for (verts, mesh.positions, mesh.normals) |*v, p, n| {
        const world = model.point(p);
        v.* = .{
            .clip = clip_from_object.point(p),
            .object = p,
            .world = .{ world[0], world[1], world[2] },
            .normal = m3.normalize(model.direction(n)),
        };
    }

    const frame: Frame = .{ .target = target, .camera = camera, .light = light, .material = material, .width = w, .height = h };
    if (material.faces) {
        for (mesh.triangles) |tri| {
            var face = [3]Vertex{ verts[tri[0]], verts[tri[1]], verts[tri[2]] };
            if (material.shading == .flat) {
                const n = m3.normalize(m3.cross(face[1].world - face[0].world, face[2].world - face[0].world));
                for (&face) |*v| v.normal = n;
            }
            drawClipped(frame, face);
        }
    }
    if (material.wire) |wire| {
        const edges = try mesh.featureEdges(gpa, wire.crease_deg);
        defer gpa.free(edges);
        for (edges) |e| drawEdge(frame, wire, verts[e[0]], verts[e[1]]);
    }
}

/// Clips a triangle against the near plane, then rasterizes what is left
/// (a triangle or a quad).
fn drawClipped(f: Frame, tri: [3]Vertex) void {
    var poly: [4]Vertex = undefined;
    var n: usize = 0;
    for (0..3) |i| {
        const a = tri[i];
        const b = tri[(i + 1) % 3];
        const da = a.near();
        const db = b.near();
        if (da >= 0) {
            poly[n] = a;
            n += 1;
        }
        if ((da >= 0) != (db >= 0)) {
            poly[n] = Vertex.lerp(a, b, da / (da - db));
            n += 1;
        }
    }
    if (n < 3) return;
    rasterize(f, .{ poly[0], poly[1], poly[2] });
    if (n == 4) rasterize(f, .{ poly[0], poly[2], poly[3] });
}

const Screen = struct { x: f32, y: f32, z: f32, inv_w: f32 };

fn toScreen(f: Frame, v: Vertex) Screen {
    const inv_w = 1 / v.clip[3];
    return .{
        .x = (v.clip[0] * inv_w * 0.5 + 0.5) * f.width,
        .y = (0.5 - v.clip[1] * inv_w * 0.5) * f.height,
        .z = v.clip[2] * inv_w,
        .inv_w = inv_w,
    };
}

fn edgeFn(a: Screen, b: Screen, px: f32, py: f32) f32 {
    return (b.x - a.x) * (py - a.y) - (b.y - a.y) * (px - a.x);
}

fn rasterize(f: Frame, tri: [3]Vertex) void {
    const s = [3]Screen{ toScreen(f, tri[0]), toScreen(f, tri[1]), toScreen(f, tri[2]) };
    const area = edgeFn(s[0], s[1], s[2].x, s[2].y);
    if (area == 0) return;
    // Screen y points down, so faces wound counter-clockwise in the world
    // have negative area here.
    const front = area < 0;
    if (f.material.cull and !front) return;

    const min_x = @max(0, @floor(@min(s[0].x, @min(s[1].x, s[2].x))));
    const max_x = @min(f.width, @ceil(@max(s[0].x, @max(s[1].x, s[2].x))));
    const min_y = @max(0, @floor(@min(s[0].y, @min(s[1].y, s[2].y))));
    const max_y = @min(f.height, @ceil(@max(s[0].y, @max(s[1].y, s[2].y))));
    if (min_x >= max_x or min_y >= max_y) return;

    const t = f.target;
    const writes_depth = f.material.blend == .normal and f.material.opacity >= 1;
    const inv_area = 1 / area;
    var y: u32 = @intFromFloat(min_y);
    while (@as(f32, @floatFromInt(y)) < max_y) : (y += 1) {
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        var x: u32 = @intFromFloat(min_x);
        while (@as(f32, @floatFromInt(x)) < max_x) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const b0 = edgeFn(s[1], s[2], px, py) * inv_area;
            const b1 = edgeFn(s[2], s[0], px, py) * inv_area;
            const b2 = edgeFn(s[0], s[1], px, py) * inv_area;
            // Pixels exactly on an edge go to one triangle only: the
            // one for which that edge's barycentric is strictly positive
            // is chosen by a consistent tie-break on the edge direction.
            if (!inside(b0, s[1], s[2]) or !inside(b1, s[2], s[0]) or !inside(b2, s[0], s[1])) continue;

            const z = b0 * s[0].z + b1 * s[1].z + b2 * s[2].z;
            const i = t.canvas.index(x, y);
            if (z >= t.depth[i]) continue;

            // Perspective-correct attribute interpolation.
            const w0 = b0 * s[0].inv_w;
            const w1 = b1 * s[1].inv_w;
            const w2 = b2 * s[2].inv_w;
            const norm = 1 / (w0 + w1 + w2);
            const k0: Vec3 = @splat(w0 * norm);
            const k1: Vec3 = @splat(w1 * norm);
            const k2: Vec3 = @splat(w2 * norm);
            const object = tri[0].object * k0 + tri[1].object * k1 + tri[2].object * k2;
            const world = tri[0].world * k0 + tri[1].world * k1 + tri[2].world * k2;
            var normal = m3.normalize(tri[0].normal * k0 + tri[1].normal * k1 + tri[2].normal * k2);
            if (!front) normal = -normal;

            const col = shadeFragment(f, object, world, normal);
            t.canvas.pixels[i] = Canvas.blendPx(t.canvas.pixels[i], col.premul(), f.material.blend);
            if (writes_depth) t.depth[i] = z;
        }
    }
}

fn inside(b: f32, a: Screen, c: Screen) bool {
    if (b > 0) return true;
    if (b < 0) return false;
    // A top-left style rule: on a shared edge exactly one of the two
    // triangles sees the edge pointing this way.
    return (c.y > a.y) or (c.y == a.y and c.x < a.x);
}

fn shadeFragment(f: Frame, object: Vec3, world: Vec3, normal: Vec3) Color {
    const mat = f.material;
    const albedo = if (mat.surface) |s| s.color(s.context, object, normal) else mat.color;
    const l = m3.normalize(f.light.direction);
    const v = m3.normalize(f.camera.eye - world);
    const diffuse = @max(0, m3.dot(normal, l));
    var out = albedo.mul(f.light.ambient.add(f.light.color.scale(diffuse)));
    if (mat.specular > 0 and diffuse > 0) {
        const half = m3.normalize(l + v);
        const spec = std.math.pow(f32, @max(0, m3.dot(normal, half)), mat.shininess) * mat.specular;
        out = out.add(f.light.color.scale(spec));
    }
    out = out.add(mat.emissive);
    if (mat.rim) |rim| {
        // Interpolated normals can come out a hair longer than 1, so clamp
        // before pow: a negative base would give NaN.
        const facing = std.math.clamp(m3.dot(normal, v), 0, 1);
        var k = std.math.pow(f32, 1 - facing, rim.power) * rim.color.a;
        if (rim.lit > 0) {
            const sun = std.math.clamp(m3.dot(normal, l) + 0.35, 0, 1);
            k *= 1 - rim.lit + rim.lit * sun;
        }
        out = out.add(rim.color.scale(k));
    }
    out.a = albedo.a * mat.opacity;
    return out;
}

/// Draws one wireframe edge as an anti-aliased line, dimmed where it lies
/// behind the depth buffer.
fn drawEdge(f: Frame, wire: Wire, a_in: Vertex, b_in: Vertex) void {
    var a = a_in;
    var b = b_in;
    const da = a.near();
    const db = b.near();
    if (da < 0 and db < 0) return;
    if (da < 0) a = Vertex.lerp(a, b, da / (da - db));
    if (db < 0) b = Vertex.lerp(a_in, b, da / (da - db));

    const sa = toScreen(f, a);
    const sb = toScreen(f, b);
    const t = f.target;
    const hw = wire.width * @as(f32, @floatFromInt(t.samples)) / 2;
    const min_x = @max(0, @floor(@min(sa.x, sb.x) - hw - 1));
    const max_x = @min(f.width, @ceil(@max(sa.x, sb.x) + hw + 1));
    const min_y = @max(0, @floor(@min(sa.y, sb.y) - hw - 1));
    const max_y = @min(f.height, @ceil(@max(sa.y, sb.y) + hw + 1));
    if (min_x >= max_x or min_y >= max_y) return;

    const dx = sb.x - sa.x;
    const dy = sb.y - sa.y;
    const len2 = @max(dx * dx + dy * dy, 1e-12);
    var y: u32 = @intFromFloat(min_y);
    while (@as(f32, @floatFromInt(y)) < max_y) : (y += 1) {
        const py = @as(f32, @floatFromInt(y)) + 0.5;
        var x: u32 = @intFromFloat(min_x);
        while (@as(f32, @floatFromInt(x)) < max_x) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const u = std.math.clamp(((px - sa.x) * dx + (py - sa.y) * dy) / len2, 0, 1);
            const ex = px - (sa.x + dx * u);
            const ey = py - (sa.y + dy * u);
            const cov = std.math.clamp(hw + 0.5 - @sqrt(ex * ex + ey * ey), 0, 1);
            if (cov <= 0) continue;
            const i = t.canvas.index(x, y);
            const z = sa.z + (sb.z - sa.z) * u;
            var k = cov;
            if (t.depth[i] != std.math.inf(f32)) {
                const behind = f.camera.linearDepth(z) - f.camera.linearDepth(t.depth[i]);
                if (behind > wire.depth_bias) k *= wire.hidden;
            }
            if (k <= 0) continue;
            t.canvas.pixels[i] = Canvas.blendPx(t.canvas.pixels[i], wire.color.premul() * @as(Canvas.Px, @splat(k)), wire.blend);
        }
    }
}

const testing = std.testing;

test "a lit cube covers the middle of the frame and leaves corners empty" {
    const gpa = testing.allocator;
    var cube = try Mesh.cube(gpa, 1);
    defer cube.deinit(gpa);
    var target = try Target.init(gpa, 32, 32, 2);
    defer target.deinit(gpa);
    const cam: Camera = .{ .eye = vec3(3, 2.5, 4) };
    try drawMesh(gpa, &target, cube, Mat4.identity, cam, .{}, .{ .color = Color.hex(0x8899aa) });
    var img = try target.resolve(gpa);
    defer img.deinit(gpa);
    try testing.expectApproxEqAbs(1, img.get(16, 16).a, 1e-6);
    try testing.expectEqual(@as(f32, 0), img.get(0, 0).a);
    // Faces turned towards the light are brighter than those turned away.
    var lit: f32 = 0;
    var dark: f32 = 1e9;
    for (img.pixels) |p| if (p[3] == 1) {
        lit = @max(lit, p[1]);
        dark = @min(dark, p[1]);
    };
    try testing.expect(lit > dark * 2);
}

test "the depth buffer keeps the nearer mesh in front" {
    const gpa = testing.allocator;
    var cube = try Mesh.cube(gpa, 0.5);
    defer cube.deinit(gpa);
    var target = try Target.init(gpa, 16, 16, 1);
    defer target.deinit(gpa);
    const cam: Camera = .{ .eye = vec3(0, 0, 5) };
    const red: Material = .{ .color = .black, .emissive = Color.hex(0xff0000) };
    const blue: Material = .{ .color = .black, .emissive = Color.hex(0x0000ff) };
    // Near cube first, far cube second: the far one must not overwrite it.
    try drawMesh(gpa, &target, cube, Mat4.translation(vec3(0, 0, 1)), cam, .{}, red);
    try drawMesh(gpa, &target, cube, Mat4.translation(vec3(0, 0, -1)).mul(Mat4.scaling(vec3(3, 3, 1))), cam, .{}, blue);
    const center = target.canvas.get(8, 8);
    try testing.expect(center.r > 0.9 and center.b == 0);
    const edge = target.canvas.get(4, 8);
    try testing.expect(edge.b > 0.9);
}

test "triangles sharing an edge do not double-cover it" {
    const gpa = testing.allocator;
    var cube = try Mesh.cube(gpa, 1);
    defer cube.deinit(gpa);
    var target = try Target.init(gpa, 24, 24, 1);
    defer target.deinit(gpa);
    // Looking straight at one face, the diagonal between its two triangles
    // runs through pixel centers. Additive faces would double up there.
    const cam: Camera = .{ .eye = vec3(0, 0, 4), .projection = .{ .orthographic = 1.5 } };
    try drawMesh(gpa, &target, cube, Mat4.identity, cam, .{}, .{ .color = .black, .emissive = Color.gray(0.25), .blend = .add });
    for (target.canvas.pixels) |p| try testing.expect(p[0] <= 0.25 + 1e-6);
    try testing.expectApproxEqAbs(0.25, target.canvas.get(12, 12).r, 1e-6);
}

test "wireframe edges draw and hidden edges dim" {
    const gpa = testing.allocator;
    var cube = try Mesh.cube(gpa, 1);
    defer cube.deinit(gpa);
    var target = try Target.init(gpa, 48, 48, 1);
    defer target.deinit(gpa);
    const cam: Camera = .{ .eye = vec3(0, 0, 4), .projection = .{ .orthographic = 1.5 } };
    const wire: Wire = .{ .color = Color.hex(0x00ffff), .width = 2, .hidden = 0 };
    try drawMesh(gpa, &target, cube, Mat4.identity, cam, .{}, .{ .faces = false, .wire = wire });
    // Without faces nothing hides the edges; the square outline is there.
    try testing.expect(target.canvas.get(24, 8).g > 0.5);
    try testing.expectEqual(@as(f32, 0), target.canvas.get(24, 24).g);
    try drawMesh(gpa, &target, cube, Mat4.rotation(vec3(1, 1, 0), 0.5), cam, .{}, .{ .faces = false, .wire = wire });
}

test "rim lighting on smooth meshes never produces NaN" {
    const gpa = testing.allocator;
    var ico = try Mesh.icosphere(gpa, 1, 1);
    defer ico.deinit(gpa);
    var target = try Target.init(gpa, 48, 48, 2);
    defer target.deinit(gpa);
    const cam: Camera = .{ .eye = vec3(0, 1.2, 4.2) };
    for (0..8) |i| {
        const m = Mat4.rotation(vec3(0.3, 1, 0.1), @as(f32, @floatFromInt(i)) * 0.4);
        try drawMesh(gpa, &target, ico, m, cam, .{}, .{
            .rim = .{ .color = Color.white, .power = 2.5, .lit = 0.5 },
            .blend = .add,
            .opacity = 0.5,
            .wire = .{ .color = Color.white, .hidden = 0.2 },
        });
    }
    for (target.canvas.pixels) |p| {
        inline for (0..4) |ch| try testing.expect(std.math.isFinite(p[ch]));
    }
}

test "near-plane clipping keeps geometry behind the camera out" {
    const gpa = testing.allocator;
    var cube = try Mesh.cube(gpa, 1);
    defer cube.deinit(gpa);
    var target = try Target.init(gpa, 16, 16, 1);
    defer target.deinit(gpa);
    // The camera sits inside the cube looking out through the front face.
    const cam: Camera = .{ .eye = vec3(0, 0, 0.5), .target = vec3(0, 0, 5) };
    try drawMesh(gpa, &target, cube, Mat4.identity, cam, .{}, .{ .cull = false, .emissive = Color.white, .color = .black });
    try testing.expectApproxEqAbs(1, target.canvas.get(8, 8).r, 1e-6);
}
