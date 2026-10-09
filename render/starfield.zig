//! Procedural starfields: a power-law spread of star brightnesses tinted by
//! temperature, diffraction spikes on the brightest, and an optional
//! nebula. By default the result tiles seamlessly, so a page background can
//! repeat it.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Canvas = @import("Canvas.zig");
const Color = @import("color.zig").Color;
const shapes = @import("shapes.zig");
const noise = @import("noise.zig");

pub const Nebula = struct {
    /// The cloud shades between these two colors.
    colors: [2]Color = .{ Color.hex(0x3b1d7a), Color.hex(0x0b6f8a) },
    /// Cloud features across the image's width. Whole numbers keep the
    /// image tileable.
    scale: u32 = 3,
    /// 0 hides the nebula; around 1 makes it dominate.
    intensity: f32 = 0.45,
    /// Fraction of the sky the clouds cover, 0 to 1.
    coverage: f32 = 0.55,
};

pub const Options = struct {
    width: u32,
    height: u32,
    seed: u32 = 1,
    /// Stars per 10,000 square pixels. Most are faint.
    density: f32 = 8,
    /// Multiplies every star's brightness.
    brightness: f32 = 1,
    /// Fraction of stars bright enough to get diffraction spikes.
    spike_fraction: f32 = 0.004,
    background: Color = Color.hex(0x03050c),
    nebula: ?Nebula = .{},
    tileable: bool = true,
};

/// Renders a starfield. The caller owns the canvas.
pub fn render(gpa: Allocator, opts: Options) Allocator.Error!Canvas {
    var c = try Canvas.init(gpa, opts.width, opts.height);
    errdefer c.deinit(gpa);
    c.fill(opts.background);
    if (opts.nebula) |neb| paintNebula(c, opts, neb);

    var prng: std.Random.DefaultPrng = .init(opts.seed);
    const rand = prng.random();
    const area = @as(f32, @floatFromInt(opts.width)) * @as(f32, @floatFromInt(opts.height));
    const count: u32 = @intFromFloat(area / 10_000 * opts.density);
    const w: f32 = @floatFromInt(opts.width);
    const h: f32 = @floatFromInt(opts.height);
    // Magnitudes are u^7 for uniform u, so P(mag > t) = 1 - t^(1/7).
    const spike_threshold = std.math.pow(f32, 1 - std.math.clamp(opts.spike_fraction, 0, 1), 7);
    for (0..count) |_| {
        const p: shapes.Point = .{ .x = rand.float(f32) * w, .y = rand.float(f32) * h };
        // A steep power law: thousands of faint stars per bright one.
        const mag = std.math.pow(f32, rand.float(f32), 7);
        // Mostly white stars, some blue, a few warm ones.
        const temp = 3600 + 11000 * std.math.pow(f32, rand.float(f32), 0.8);
        const tint = Color.blackBody(temp).mix(.white, 0.5);
        const intensity = (0.2 + 5 * mag) * opts.brightness;
        const sigma = 0.42 + 0.7 * mag;
        shapes.splat(c, p, sigma, tint.scale(intensity), opts.tileable);
        if (mag > 0.4) {
            // A soft halo around the brightest stars.
            shapes.splat(c, p, sigma * 4, tint.scale(intensity * 0.05), opts.tileable);
        }
        if (mag > spike_threshold) {
            spikes(c, p, 10 + 40 * mag, tint.scale(intensity * 0.5), opts.tileable);
        }
    }
    return c;
}

fn paintNebula(c: Canvas, opts: Options, neb: Nebula) void {
    const w: f32 = @floatFromInt(opts.width);
    const h: f32 = @floatFromInt(opts.height);
    const sx: f32 = @floatFromInt(neb.scale);
    // Keep the noise cells square, and a whole number of them per tile.
    const sy = @max(1, @round(sx * h / w));
    const period: noise.Period = if (opts.tileable) .{ neb.scale, @intFromFloat(sy) } else noise.no_period;
    const threshold = 1 - 2 * neb.coverage;
    for (0..opts.height) |y| {
        for (0..opts.width) |x| {
            const u = (@as(f32, @floatFromInt(x)) + 0.5) / w * sx;
            const v = (@as(f32, @floatFromInt(y)) + 0.5) / h * sy;
            const density = noise.fbm2(opts.seed, u, v, period, .{ .octaves = 6, .gain = 0.55 });
            const shade = noise.fbm2(opts.seed +% 101, u + 7.3, v + 1.9, period, .{ .octaves = 3 });
            // Wispy filaments: emphasize where the density field is high.
            const d = std.math.clamp((density * 1.6 - threshold) / (1 - threshold), 0, 1);
            const k = d * d * neb.intensity;
            if (k <= 0) continue;
            const col = neb.colors[0].mix(neb.colors[1], std.math.clamp(shade * 0.5 + 0.5, 0, 1));
            c.blend(@intCast(x), @intCast(y), col.scale(k), 1, .add);
        }
    }
}

/// Four thin diffraction spikes, fading with distance from the star.
fn spikes(c: Canvas, p: shapes.Point, length: f32, col: Color, wrap: bool) void {
    const reach: i32 = @intFromFloat(@ceil(length));
    const w: i32 = @intCast(c.width);
    const h: i32 = @intCast(c.height);
    const cx: i32 = @intFromFloat(@floor(p.x));
    const cy: i32 = @intFromFloat(@floor(p.y));
    var d: i32 = -reach;
    while (d <= reach) : (d += 1) {
        if (d == 0) continue;
        const fall = @exp(-@abs(@as(f32, @floatFromInt(d))) / (length / 4));
        for ([_][2]i32{ .{ cx + d, cy }, .{ cx, cy + d } }) |q| {
            const x = if (wrap) @mod(q[0], w) else q[0];
            const y = if (wrap) @mod(q[1], h) else q[1];
            c.blend(x, y, col, fall, .add);
        }
    }
}

const testing = std.testing;

test "starfields are deterministic and tile seamlessly" {
    const gpa = testing.allocator;
    var a = try render(gpa, .{ .width = 96, .height = 64, .seed = 3 });
    defer a.deinit(gpa);
    var b = try render(gpa, .{ .width = 96, .height = 64, .seed = 3 });
    defer b.deinit(gpa);
    try testing.expectEqualSlices(Canvas.Px, a.pixels, b.pixels);

    // Across the wrap-around seam, neighbouring pixels differ no more than
    // neighbours inside the image do.
    var seam: f32 = 0;
    var inner: f32 = 0;
    for (0..a.height) |y| {
        seam += lumDiff(a, a.width - 1, 0, y);
        inner += lumDiff(a, a.width / 2 - 1, a.width / 2, y);
    }
    try testing.expect(seam < inner * 3 + 1);
}

fn lumDiff(c: Canvas, x0: usize, x1: usize, y: usize) f32 {
    const p = c.pixels[y * c.width + x0];
    const q = c.pixels[y * c.width + x1];
    return @abs(p[1] - q[1]);
}

test "density controls the number of stars" {
    const gpa = testing.allocator;
    var sparse = try render(gpa, .{ .width = 64, .height = 64, .density = 2, .nebula = null });
    defer sparse.deinit(gpa);
    var dense = try render(gpa, .{ .width = 64, .height = 64, .density = 20, .nebula = null });
    defer dense.deinit(gpa);
    var s: f32 = 0;
    var d: f32 = 0;
    for (sparse.pixels, dense.pixels) |p, q| {
        s += p[1];
        d += q[1];
    }
    try testing.expect(d > s * 3);
}
