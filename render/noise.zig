//! Deterministic gradient noise (Perlin's improved noise, with hashed
//! gradients) and fractal sums of it. The same seed and coordinates give the
//! same value on every platform, so rendered assets are reproducible.

const std = @import("std");

/// Mixes integers into a well-distributed 32-bit hash.
pub fn hash(seed: u32, a: i32, b: i32, c: i32) u32 {
    var h: u32 = seed *% 0x9e3779b1;
    for ([_]i32{ a, b, c }) |v| {
        h ^= @bitCast(v);
        h *%= 0x85ebca6b;
        h ^= h >> 13;
        h *%= 0xc2b2ae35;
        h ^= h >> 16;
    }
    return h;
}

/// A hash mapped to [0, 1).
pub fn hashUnit(seed: u32, a: i32, b: i32, c: i32) f32 {
    return @as(f32, @floatFromInt(hash(seed, a, b, c) >> 8)) / (1 << 24);
}

fn fade(t: f32) f32 {
    return t * t * t * (t * (t * 6 - 15) + 10);
}

fn lerp(a: f32, b: f32, t: f32) f32 {
    return a + (b - a) * t;
}

fn grad2(h: u32, x: f32, y: f32) f32 {
    // Eight directions around the circle.
    return switch (h & 7) {
        0 => x + y,
        1 => x - y,
        2 => -x + y,
        3 => -x - y,
        4 => x * std.math.sqrt2,
        5 => -x * std.math.sqrt2,
        6 => y * std.math.sqrt2,
        else => -y * std.math.sqrt2,
    };
}

fn grad3(h: u32, x: f32, y: f32, z: f32) f32 {
    // The twelve cube-edge directions of improved Perlin noise.
    return switch (h % 12) {
        0 => x + y,
        1 => -x + y,
        2 => x - y,
        3 => -x - y,
        4 => x + z,
        5 => -x + z,
        6 => x - z,
        7 => -x - z,
        8 => y + z,
        9 => -y + z,
        10 => y - z,
        else => -y - z,
    };
}

/// How often 2D noise repeats along x and y, in noise units. Zero on an
/// axis means it never repeats there.
pub const Period = [2]u32;
pub const no_period: Period = .{ 0, 0 };

/// 2D gradient noise in roughly [-1, 1]. A non-zero `period` makes the
/// noise repeat, which is what makes tileable textures possible.
pub fn perlin2(seed: u32, x: f32, y: f32, period: Period) f32 {
    const fx = @floor(x);
    const fy = @floor(y);
    const ix: i32 = @intFromFloat(fx);
    const iy: i32 = @intFromFloat(fy);
    const tx = x - fx;
    const ty = y - fy;
    const wrap = struct {
        fn f(v: i32, per: u32) i32 {
            return if (per > 0) @mod(v, @as(i32, @intCast(per))) else v;
        }
    }.f;
    const x0 = wrap(ix, period[0]);
    const x1 = wrap(ix + 1, period[0]);
    const y0 = wrap(iy, period[1]);
    const y1 = wrap(iy + 1, period[1]);
    const n00 = grad2(hash(seed, x0, y0, 0), tx, ty);
    const n10 = grad2(hash(seed, x1, y0, 0), tx - 1, ty);
    const n01 = grad2(hash(seed, x0, y1, 0), tx, ty - 1);
    const n11 = grad2(hash(seed, x1, y1, 0), tx - 1, ty - 1);
    const u = fade(tx);
    // Scaled so the output fills roughly [-1, 1].
    return 0.7071 * lerp(lerp(n00, n10, u), lerp(n01, n11, u), fade(ty));
}

/// 3D gradient noise in roughly [-1, 1]. Sampling it on a sphere's surface
/// textures the sphere without seams or pinched poles.
pub fn perlin3(seed: u32, x: f32, y: f32, z: f32) f32 {
    const fx = @floor(x);
    const fy = @floor(y);
    const fz = @floor(z);
    const ix: i32 = @intFromFloat(fx);
    const iy: i32 = @intFromFloat(fy);
    const iz: i32 = @intFromFloat(fz);
    const tx = x - fx;
    const ty = y - fy;
    const tz = z - fz;
    var corners: [8]f32 = undefined;
    for (&corners, 0..) |*n, i| {
        const dx: i32 = @intCast(i & 1);
        const dy: i32 = @intCast((i >> 1) & 1);
        const dz: i32 = @intCast((i >> 2) & 1);
        n.* = grad3(
            hash(seed, ix + dx, iy + dy, iz + dz),
            tx - @as(f32, @floatFromInt(dx)),
            ty - @as(f32, @floatFromInt(dy)),
            tz - @as(f32, @floatFromInt(dz)),
        );
    }
    const u = fade(tx);
    const v = fade(ty);
    const w = fade(tz);
    const x00 = lerp(corners[0], corners[1], u);
    const x10 = lerp(corners[2], corners[3], u);
    const x01 = lerp(corners[4], corners[5], u);
    const x11 = lerp(corners[6], corners[7], u);
    return lerp(lerp(x00, x10, v), lerp(x01, x11, v), w);
}

pub const Fractal = struct {
    octaves: u32 = 5,
    /// Frequency multiplier per octave.
    lacunarity: f32 = 2,
    /// Amplitude multiplier per octave.
    gain: f32 = 0.5,
};

/// A fractional shift for each octave. Without it every octave's lattice
/// lines up at the origin, and the noise's zeros at lattice points add up
/// to a faint visible grid. Shifting does not affect periodicity.
fn octaveOffset(seed: u32, octave: usize) [3]f32 {
    const o: i32 = @intCast(octave);
    return .{
        hashUnit(seed, o, 1, 0) * 64,
        hashUnit(seed, o, 2, 0) * 64,
        hashUnit(seed, o, 3, 0) * 64,
    };
}

/// Fractal Brownian motion: octaves of `perlin2` at rising frequency and
/// falling amplitude, normalized to roughly [-1, 1]. A non-zero `period`
/// keeps it tileable (lacunarity is then rounded to a whole number).
pub fn fbm2(seed: u32, x: f32, y: f32, period: Period, f: Fractal) f32 {
    var sum: f32 = 0;
    var amp: f32 = 1;
    var norm: f32 = 0;
    var freq: f32 = 1;
    var per = period;
    const tiled = period[0] > 0 or period[1] > 0;
    const lac = if (tiled) @max(1, @round(f.lacunarity)) else f.lacunarity;
    for (0..f.octaves) |o| {
        const off = octaveOffset(seed, o);
        sum += amp * perlin2(seed +% @as(u32, @intCast(o)), x * freq + off[0], y * freq + off[1], per);
        norm += amp;
        amp *= f.gain;
        freq *= lac;
        if (tiled) {
            const l: u32 = @intFromFloat(lac);
            per = .{ per[0] * l, per[1] * l };
        }
    }
    return sum / norm;
}

/// Fractal sum of `perlin3`, normalized to roughly [-1, 1].
pub fn fbm3(seed: u32, x: f32, y: f32, z: f32, f: Fractal) f32 {
    var sum: f32 = 0;
    var amp: f32 = 1;
    var norm: f32 = 0;
    var freq: f32 = 1;
    for (0..f.octaves) |o| {
        const off = octaveOffset(seed, o);
        sum += amp * perlin3(seed +% @as(u32, @intCast(o)), x * freq + off[0], y * freq + off[1], z * freq + off[2]);
        norm += amp;
        amp *= f.gain;
        freq *= f.lacunarity;
    }
    return sum / norm;
}

const testing = std.testing;

test "noise is deterministic, bounded and zero on lattice points" {
    try testing.expectEqual(perlin2(1, 3.7, -2.2, no_period), perlin2(1, 3.7, -2.2, no_period));
    try testing.expect(perlin2(1, 3.7, -2.2, no_period) != perlin2(2, 3.7, -2.2, no_period));
    try testing.expectEqual(@as(f32, 0), perlin2(9, 4, 5, no_period));
    try testing.expectEqual(@as(f32, 0), perlin3(9, 4, 5, -6));
    var lo: f32 = 0;
    var hi: f32 = 0;
    for (0..2000) |i| {
        const t: f32 = @floatFromInt(i);
        const v = perlin3(3, t * 0.173, t * 0.071, t * 0.029);
        const u = fbm2(3, t * 0.131, t * 0.057, no_period, .{});
        lo = @min(lo, @min(v, u));
        hi = @max(hi, @max(v, u));
    }
    try testing.expect(lo >= -1.1 and hi <= 1.1);
    try testing.expect(lo < -0.3 and hi > 0.3);
}

test "periodic noise tiles" {
    for (0..50) |i| {
        const t = @as(f32, @floatFromInt(i)) * 0.37;
        try testing.expectApproxEqAbs(perlin2(5, t, 1.3, .{ 8, 4 }), perlin2(5, t + 8, 1.3 + 12, .{ 8, 4 }), 1e-5);
        try testing.expectApproxEqAbs(fbm2(5, t, 0.4, .{ 4, 2 }, .{}), fbm2(5, t + 4, 0.4 + 2, .{ 4, 2 }, .{}), 1e-5);
    }
}

test "hashUnit spreads evenly" {
    var buckets = [_]u32{0} ** 10;
    for (0..10000) |i| {
        const v = hashUnit(42, @intCast(i), 0, 0);
        try testing.expect(v >= 0 and v < 1);
        buckets[@intFromFloat(v * 10)] += 1;
    }
    for (buckets) |b| try testing.expect(b > 900 and b < 1100);
}
