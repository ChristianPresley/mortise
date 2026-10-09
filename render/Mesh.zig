//! A triangle mesh with per-vertex normals, plus generators for the shapes
//! sci-fi graphics lean on: cubes, spheres, faceted icospheres and tori.
//! Triangles wind counter-clockwise when seen from outside.

const std = @import("std");
const Allocator = std.mem.Allocator;
const m3 = @import("math3d.zig");
const Vec3 = m3.Vec3;
const vec3 = m3.vec3;

const Mesh = @This();

positions: []Vec3,
normals: []Vec3,
triangles: [][3]u32,

pub fn deinit(m: *Mesh, gpa: Allocator) void {
    gpa.free(m.positions);
    gpa.free(m.normals);
    gpa.free(m.triangles);
    m.* = undefined;
}

/// Collects vertices and triangles while a generator runs.
const Builder = struct {
    gpa: Allocator,
    positions: std.ArrayList(Vec3) = .empty,
    normals: std.ArrayList(Vec3) = .empty,
    triangles: std.ArrayList([3]u32) = .empty,

    fn vertex(b: *Builder, p: Vec3, n: Vec3) Allocator.Error!u32 {
        try b.positions.append(b.gpa, p);
        try b.normals.append(b.gpa, n);
        return @intCast(b.positions.items.len - 1);
    }

    fn tri(b: *Builder, i: u32, j: u32, k: u32) Allocator.Error!void {
        try b.triangles.append(b.gpa, .{ i, j, k });
    }

    fn finish(b: *Builder) Allocator.Error!Mesh {
        const positions = try b.positions.toOwnedSlice(b.gpa);
        errdefer b.gpa.free(positions);
        const normals = try b.normals.toOwnedSlice(b.gpa);
        errdefer b.gpa.free(normals);
        return .{ .positions = positions, .normals = normals, .triangles = try b.triangles.toOwnedSlice(b.gpa) };
    }

    fn deinit(b: *Builder) void {
        b.positions.deinit(b.gpa);
        b.normals.deinit(b.gpa);
        b.triangles.deinit(b.gpa);
    }
};

/// A cube centered on the origin, `2 * half` on a side, with sharp edges.
pub fn cube(gpa: Allocator, half: f32) Allocator.Error!Mesh {
    var b: Builder = .{ .gpa = gpa };
    defer b.deinit();
    // Each face: its normal and two axes spanning it, ordered so that
    // u x v = normal (counter-clockwise from outside).
    const faces = [_][3]Vec3{
        .{ vec3(1, 0, 0), vec3(0, 0, -1), vec3(0, 1, 0) },
        .{ vec3(-1, 0, 0), vec3(0, 0, 1), vec3(0, 1, 0) },
        .{ vec3(0, 1, 0), vec3(1, 0, 0), vec3(0, 0, -1) },
        .{ vec3(0, -1, 0), vec3(1, 0, 0), vec3(0, 0, 1) },
        .{ vec3(0, 0, 1), vec3(1, 0, 0), vec3(0, 1, 0) },
        .{ vec3(0, 0, -1), vec3(-1, 0, 0), vec3(0, 1, 0) },
    };
    for (faces) |f| {
        const n, const u, const v = f;
        var idx: [4]u32 = undefined;
        for (&idx, [_][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } }) |*i, c| {
            const p = m3.scale(n + m3.scale(u, c[0]) + m3.scale(v, c[1]), half);
            i.* = try b.vertex(p, n);
        }
        try b.tri(idx[0], idx[1], idx[2]);
        try b.tri(idx[0], idx[2], idx[3]);
    }
    return b.finish();
}

/// A latitude-longitude sphere. Its wireframe shows a globe grid.
pub fn uvSphere(gpa: Allocator, radius: f32, segments: u32, rings: u32) Allocator.Error!Mesh {
    std.debug.assert(segments >= 3 and rings >= 2);
    var b: Builder = .{ .gpa = gpa };
    defer b.deinit();
    for (0..rings + 1) |i| {
        const theta = std.math.pi * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(rings));
        for (0..segments + 1) |j| {
            const phi = std.math.tau * @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(segments));
            const n = vec3(@sin(theta) * @cos(phi), @cos(theta), -@sin(theta) * @sin(phi));
            _ = try b.vertex(m3.scale(n, radius), n);
        }
    }
    const row = segments + 1;
    for (0..rings) |i| {
        for (0..segments) |j| {
            const a: u32 = @intCast(i * row + j);
            const c = a + row;
            // Skip the zero-area triangles that touch each pole.
            if (i != 0) try b.tri(a, c, a + 1);
            if (i != rings - 1) try b.tri(a + 1, c, c + 1);
        }
    }
    return b.finish();
}

/// A sphere made by subdividing an icosahedron. With no subdivisions it is
/// an icosahedron; with flat shading it reads as a cut gem or a low-poly
/// planet. Each subdivision quadruples the triangle count.
pub fn icosphere(gpa: Allocator, radius: f32, subdivisions: u32) Allocator.Error!Mesh {
    const t = (1 + @sqrt(@as(f32, 5))) / 2;
    var verts: std.ArrayList(Vec3) = .empty;
    defer verts.deinit(gpa);
    for ([_]Vec3{
        vec3(-1, t, 0), vec3(1, t, 0), vec3(-1, -t, 0), vec3(1, -t, 0),
        vec3(0, -1, t), vec3(0, 1, t), vec3(0, -1, -t), vec3(0, 1, -t),
        vec3(t, 0, -1), vec3(t, 0, 1), vec3(-t, 0, -1), vec3(-t, 0, 1),
    }) |v| try verts.append(gpa, m3.normalize(v));

    var tris: std.ArrayList([3]u32) = .empty;
    defer tris.deinit(gpa);
    try tris.appendSlice(gpa, &.{
        .{ 0, 11, 5 }, .{ 0, 5, 1 },  .{ 0, 1, 7 },   .{ 0, 7, 10 }, .{ 0, 10, 11 },
        .{ 1, 5, 9 },  .{ 5, 11, 4 }, .{ 11, 10, 2 }, .{ 10, 7, 6 }, .{ 7, 1, 8 },
        .{ 3, 9, 4 },  .{ 3, 4, 2 },  .{ 3, 2, 6 },   .{ 3, 6, 8 },  .{ 3, 8, 9 },
        .{ 4, 9, 5 },  .{ 2, 4, 11 }, .{ 6, 2, 10 },  .{ 8, 6, 7 },  .{ 9, 8, 1 },
    });

    var midpoints: std.AutoHashMapUnmanaged(u64, u32) = .empty;
    defer midpoints.deinit(gpa);
    for (0..subdivisions) |_| {
        midpoints.clearRetainingCapacity();
        var next: std.ArrayList([3]u32) = .empty;
        errdefer next.deinit(gpa);
        for (tris.items) |tri| {
            var mid: [3]u32 = undefined;
            for (&mid, 0..) |*m, e| {
                const a = tri[e];
                const c = tri[(e + 1) % 3];
                const key = (@as(u64, @min(a, c)) << 32) | @max(a, c);
                const gop = try midpoints.getOrPut(gpa, key);
                if (!gop.found_existing) {
                    try verts.append(gpa, m3.normalize(verts.items[a] + verts.items[c]));
                    gop.value_ptr.* = @intCast(verts.items.len - 1);
                }
                m.* = gop.value_ptr.*;
            }
            try next.appendSlice(gpa, &.{
                .{ tri[0], mid[0], mid[2] },
                .{ tri[1], mid[1], mid[0] },
                .{ tri[2], mid[2], mid[1] },
                .{ mid[0], mid[1], mid[2] },
            });
        }
        tris.deinit(gpa);
        tris = next;
    }

    const normals = try gpa.dupe(Vec3, verts.items);
    errdefer gpa.free(normals);
    const positions = try gpa.alloc(Vec3, verts.items.len);
    errdefer gpa.free(positions);
    for (positions, verts.items) |*p, v| p.* = m3.scale(v, radius);
    return .{ .positions = positions, .normals = normals, .triangles = try tris.toOwnedSlice(gpa) };
}

/// A ring-shaped torus lying in the xz plane: `major` is the distance from
/// the center to the middle of the tube, `minor` the tube's radius.
pub fn torus(gpa: Allocator, major: f32, minor: f32, segments: u32, sides: u32) Allocator.Error!Mesh {
    std.debug.assert(segments >= 3 and sides >= 3);
    var b: Builder = .{ .gpa = gpa };
    defer b.deinit();
    for (0..segments + 1) |i| {
        const u = std.math.tau * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(segments));
        const center = vec3(major * @cos(u), 0, -major * @sin(u));
        const out = vec3(@cos(u), 0, -@sin(u));
        for (0..sides + 1) |j| {
            const v = std.math.tau * @as(f32, @floatFromInt(j)) / @as(f32, @floatFromInt(sides));
            const n = m3.scale(out, @cos(v)) + vec3(0, @sin(v), 0);
            _ = try b.vertex(center + m3.scale(n, minor), n);
        }
    }
    const row = sides + 1;
    for (0..segments) |i| {
        for (0..sides) |j| {
            const a: u32 = @intCast(i * row + j);
            const c = a + row;
            try b.tri(a, c, c + 1);
            try b.tri(a, c + 1, a + 1);
        }
    }
    return b.finish();
}

/// The geometric normal of a triangle (not normalized).
pub fn faceNormal(m: Mesh, t: [3]u32) Vec3 {
    const a = m.positions[t[0]];
    return m3.cross(m.positions[t[1]] - a, m.positions[t[2]] - a);
}

/// Edges worth drawing in a wireframe: those on the mesh boundary and those
/// where the two faces meet at more than `crease_deg` degrees. Diagonals
/// across flat quads drop out, so a cube shows twelve edges, not eighteen.
/// The caller owns the result.
pub fn featureEdges(m: Mesh, gpa: Allocator, crease_deg: f32) Allocator.Error![][2]u32 {
    const Entry = struct { normal: Vec3, count: u32, sharp: bool };
    var map: std.AutoArrayHashMapUnmanaged([2]u32, Entry) = .empty;
    defer map.deinit(gpa);
    const min_cos = @cos(crease_deg * std.math.pi / 180);
    for (m.triangles) |t| {
        const n = m3.normalize(m.faceNormal(t));
        for (0..3) |e| {
            const a = t[e];
            const b = t[(e + 1) % 3];
            const gop = try map.getOrPut(gpa, .{ @min(a, b), @max(a, b) });
            if (gop.found_existing) {
                gop.value_ptr.count += 1;
                if (m3.dot(gop.value_ptr.normal, n) < min_cos) gop.value_ptr.sharp = true;
            } else gop.value_ptr.* = .{ .normal = n, .count = 1, .sharp = false };
        }
    }
    var out: std.ArrayList([2]u32) = .empty;
    errdefer out.deinit(gpa);
    for (map.keys(), map.values()) |k, v| {
        if (v.count != 2 or v.sharp) try out.append(gpa, k);
    }
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

fn expectOutward(m: Mesh, center_of: fn (Vec3) Vec3) !void {
    for (m.triangles) |t| {
        const n = m.faceNormal(t);
        const centroid = m3.scale(m.positions[t[0]] + m.positions[t[1]] + m.positions[t[2]], 1.0 / 3.0);
        try testing.expect(m3.length(n) > 0);
        try testing.expect(m3.dot(n, centroid - center_of(centroid)) > 0);
    }
}

fn origin(_: Vec3) Vec3 {
    return vec3(0, 0, 0);
}

fn tubeCenter(p: Vec3) Vec3 {
    return m3.scale(m3.normalize(vec3(p[0], 0, p[2])), 2);
}

test "generated meshes wind outwards" {
    var c = try cube(testing.allocator, 1);
    defer c.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 12), c.triangles.len);
    try expectOutward(c, origin);

    var s = try uvSphere(testing.allocator, 2, 12, 8);
    defer s.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 12 * 8 * 2 - 24), s.triangles.len);
    try expectOutward(s, origin);

    var ico = try icosphere(testing.allocator, 1, 2);
    defer ico.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 20 * 16), ico.triangles.len);
    try testing.expectEqual(@as(usize, 162), ico.positions.len);
    try expectOutward(ico, origin);
    for (ico.positions) |p| try testing.expectApproxEqAbs(1, m3.length(p), 1e-5);

    var t = try torus(testing.allocator, 2, 0.5, 16, 8);
    defer t.deinit(testing.allocator);
    try expectOutward(t, tubeCenter);
}

test "feature edges drop flat diagonals" {
    var c = try cube(testing.allocator, 1);
    defer c.deinit(testing.allocator);
    // The cube's faces share no vertices, so each face contributes its own
    // four outline edges and nothing else.
    const edges = try c.featureEdges(testing.allocator, 1);
    defer testing.allocator.free(edges);
    try testing.expectEqual(@as(usize, 24), edges.len);

    var ico = try icosphere(testing.allocator, 1, 0);
    defer ico.deinit(testing.allocator);
    const ico_edges = try ico.featureEdges(testing.allocator, 1);
    defer testing.allocator.free(ico_edges);
    try testing.expectEqual(@as(usize, 30), ico_edges.len);
}
