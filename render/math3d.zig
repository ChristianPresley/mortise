//! Vectors and 4x4 matrices for the 3D renderer. Right-handed coordinates
//! with y up, matrices column-major and applied to column vectors, clip
//! space depth from -1 (near) to 1 (far): the OpenGL conventions.

const std = @import("std");

pub const Vec3 = @Vector(3, f32);
pub const Vec4 = @Vector(4, f32);

pub fn vec3(x: f32, y: f32, z: f32) Vec3 {
    return .{ x, y, z };
}

pub fn dot(a: Vec3, b: Vec3) f32 {
    return @reduce(.Add, a * b);
}

pub fn cross(a: Vec3, b: Vec3) Vec3 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

pub fn length(a: Vec3) f32 {
    return @sqrt(dot(a, a));
}

pub fn normalize(a: Vec3) Vec3 {
    const l = length(a);
    return if (l > 0) a / @as(Vec3, @splat(l)) else a;
}

pub fn scale(a: Vec3, k: f32) Vec3 {
    return a * @as(Vec3, @splat(k));
}

pub fn lerp(a: Vec3, b: Vec3, t: f32) Vec3 {
    return a + scale(b - a, t);
}

/// A 4x4 matrix stored as four columns.
pub const Mat4 = struct {
    cols: [4]Vec4,

    pub const identity: Mat4 = .{ .cols = .{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    } };

    /// `a * b`: applies `b` first, then `a`.
    pub fn mul(a: Mat4, b: Mat4) Mat4 {
        var out: Mat4 = undefined;
        for (&out.cols, b.cols) |*o, col| o.* = a.apply(col);
        return out;
    }

    pub fn apply(m: Mat4, v: Vec4) Vec4 {
        return m.cols[0] * @as(Vec4, @splat(v[0])) +
            m.cols[1] * @as(Vec4, @splat(v[1])) +
            m.cols[2] * @as(Vec4, @splat(v[2])) +
            m.cols[3] * @as(Vec4, @splat(v[3]));
    }

    /// Transforms a point (w = 1), without the perspective divide.
    pub fn point(m: Mat4, p: Vec3) Vec4 {
        return m.apply(.{ p[0], p[1], p[2], 1 });
    }

    /// Transforms a direction (w = 0): rotation and scale, no translation.
    pub fn direction(m: Mat4, d: Vec3) Vec3 {
        const r = m.apply(.{ d[0], d[1], d[2], 0 });
        return .{ r[0], r[1], r[2] };
    }

    pub fn translation(t: Vec3) Mat4 {
        var m = identity;
        m.cols[3] = .{ t[0], t[1], t[2], 1 };
        return m;
    }

    pub fn scaling(s: Vec3) Mat4 {
        return .{ .cols = .{
            .{ s[0], 0, 0, 0 },
            .{ 0, s[1], 0, 0 },
            .{ 0, 0, s[2], 0 },
            .{ 0, 0, 0, 1 },
        } };
    }

    /// Rotation by `angle` radians around `axis`, counter-clockwise when
    /// looking down the axis towards the origin.
    pub fn rotation(axis: Vec3, angle: f32) Mat4 {
        const a = normalize(axis);
        const c = @cos(angle);
        const s = @sin(angle);
        const t = 1 - c;
        const x = a[0];
        const y = a[1];
        const z = a[2];
        return .{ .cols = .{
            .{ t * x * x + c, t * x * y + s * z, t * x * z - s * y, 0 },
            .{ t * x * y - s * z, t * y * y + c, t * y * z + s * x, 0 },
            .{ t * x * z + s * y, t * y * z - s * x, t * z * z + c, 0 },
            .{ 0, 0, 0, 1 },
        } };
    }

    /// A perspective projection with vertical field of view `fov_y`
    /// radians.
    pub fn perspective(fov_y: f32, aspect: f32, near: f32, far: f32) Mat4 {
        const f = 1 / @tan(fov_y / 2);
        return .{ .cols = .{
            .{ f / aspect, 0, 0, 0 },
            .{ 0, f, 0, 0 },
            .{ 0, 0, (far + near) / (near - far), -1 },
            .{ 0, 0, 2 * far * near / (near - far), 0 },
        } };
    }

    /// An orthographic projection showing `half_height` units above and
    /// below the view axis.
    pub fn orthographic(half_height: f32, aspect: f32, near: f32, far: f32) Mat4 {
        const hw = half_height * aspect;
        return .{ .cols = .{
            .{ 1 / hw, 0, 0, 0 },
            .{ 0, 1 / half_height, 0, 0 },
            .{ 0, 0, -2 / (far - near), 0 },
            .{ 0, 0, -(far + near) / (far - near), 1 },
        } };
    }

    /// The view matrix of a camera at `eye` looking at `target`.
    pub fn lookAt(eye: Vec3, target: Vec3, up: Vec3) Mat4 {
        const f = normalize(target - eye);
        const s = normalize(cross(f, up));
        const u = cross(s, f);
        return .{ .cols = .{
            .{ s[0], u[0], -f[0], 0 },
            .{ s[1], u[1], -f[1], 0 },
            .{ s[2], u[2], -f[2], 0 },
            .{ -dot(s, eye), -dot(u, eye), dot(f, eye), 1 },
        } };
    }
};

const testing = std.testing;

fn expectVec(expected: Vec3, actual: Vec3) !void {
    inline for (0..3) |i| try testing.expectApproxEqAbs(expected[i], actual[i], 1e-5);
}

test "rotation follows the right-hand rule" {
    const r = Mat4.rotation(vec3(0, 0, 1), std.math.pi / 2.0);
    try expectVec(vec3(0, 1, 0), r.direction(vec3(1, 0, 0)));
    const ry = Mat4.rotation(vec3(0, 1, 0), std.math.pi / 2.0);
    try expectVec(vec3(0, 0, -1), ry.direction(vec3(1, 0, 0)));
}

test "mul applies the right-hand matrix first" {
    const m = Mat4.translation(vec3(10, 0, 0)).mul(Mat4.scaling(vec3(2, 2, 2)));
    const p = m.point(vec3(1, 1, 1));
    try expectVec(vec3(12, 2, 2), .{ p[0], p[1], p[2] });
}

test "lookAt puts the target straight ahead" {
    const v = Mat4.lookAt(vec3(3, 4, 5), vec3(0, 0, 0), vec3(0, 1, 0));
    const p = v.point(vec3(0, 0, 0));
    try expectVec(vec3(0, 0, -length(vec3(3, 4, 5))), .{ p[0], p[1], p[2] });
}

test "perspective maps near and far to -1 and 1" {
    const proj = Mat4.perspective(1, 1, 0.5, 20);
    const n = proj.point(vec3(0, 0, -0.5));
    const f = proj.point(vec3(0, 0, -20));
    try testing.expectApproxEqAbs(-1, n[2] / n[3], 1e-5);
    try testing.expectApproxEqAbs(1, f[2] / f[3], 1e-5);
}

test "vector helpers" {
    try expectVec(vec3(0, 0, 1), cross(vec3(1, 0, 0), vec3(0, 1, 0)));
    try testing.expectApproxEqAbs(1, length(normalize(vec3(3, -4, 12))), 1e-6);
}
