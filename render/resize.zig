//! Downscaling 8-bit RGBA images.
//!
//! Each output pixel is the average of the source area it covers, weighted
//! by how much of each source pixel falls inside it. Averaging happens in
//! linear light with premultiplied alpha, so thin bright lines keep their
//! brightness and transparent edges do not darken.

const std = @import("std");
const Allocator = std.mem.Allocator;
const png = @import("png.zig");

pub const Image = png.Image;

/// For one output pixel: the first source pixel it covers and the weight
/// of each source pixel from there.
const Span = struct { start: usize, weights: []f32 };

fn spans(gpa: Allocator, src: usize, dst: usize) Allocator.Error![]Span {
    const out = try gpa.alloc(Span, dst);
    var made: usize = 0;
    errdefer {
        for (out[0..made]) |s| gpa.free(s.weights);
        gpa.free(out);
    }
    const scale = @as(f64, @floatFromInt(src)) / @as(f64, @floatFromInt(dst));
    for (out, 0..) |*s, i| {
        const lo = @as(f64, @floatFromInt(i)) * scale;
        const hi = @min(@as(f64, @floatFromInt(src)), lo + scale);
        const first: usize = @intFromFloat(@floor(lo));
        const last: usize = @min(src - 1, @as(usize, @intFromFloat(@ceil(hi))) -| 1);
        s.start = first;
        s.weights = try gpa.alloc(f32, last - first + 1);
        made += 1;
        var total: f64 = 0;
        for (s.weights, first..) |*w, j| {
            const a = @max(lo, @as(f64, @floatFromInt(j)));
            const b = @min(hi, @as(f64, @floatFromInt(j + 1)));
            w.* = @floatCast(@max(0, b - a));
            total += w.*;
        }
        for (s.weights) |*w| w.* = @floatCast(w.* / total);
    }
    return out;
}

fn freeSpans(gpa: Allocator, s: []Span) void {
    for (s) |x| gpa.free(x.weights);
    gpa.free(s);
}

fn toLinear(v: f32) f32 {
    return if (v <= 0.04045) v / 12.92 else std.math.pow(f32, (v + 0.055) / 1.055, 2.4);
}

fn toSrgb(v: f32) f32 {
    return if (v <= 0.0031308) v * 12.92 else 1.055 * std.math.pow(f32, v, 1.0 / 2.4) - 0.055;
}

const srgb_steps = 16384;

/// A copy of `src` scaled to `width` x `height`, which must not be larger
/// than `src`. The caller owns the result.
pub fn downscale(gpa: Allocator, src: Image, width: u32, height: u32) Allocator.Error!Image {
    std.debug.assert(width > 0 and height > 0 and width <= src.width and height <= src.height);
    const sw: usize = src.width;
    const sh: usize = src.height;
    const dw: usize = width;
    const dh: usize = height;

    var linear: [256]f32 = undefined;
    for (&linear, 0..) |*l, i| l.* = toLinear(@as(f32, @floatFromInt(i)) / 255);
    const encode = try gpa.alloc(u8, srgb_steps + 1);
    defer gpa.free(encode);
    for (encode, 0..) |*e, i| e.* = @intFromFloat(@round(toSrgb(@as(f32, @floatFromInt(i)) / srgb_steps) * 255));

    const xs = try spans(gpa, sw, dw);
    defer freeSpans(gpa, xs);
    const ys = try spans(gpa, sh, dh);
    defer freeSpans(gpa, ys);

    // Horizontal pass into premultiplied linear floats, one row at a time.
    const tmp = try gpa.alloc([4]f32, dw * sh);
    defer gpa.free(tmp);
    for (0..sh) |y| {
        const row = src.rgba[y * sw * 4 ..][0 .. sw * 4];
        for (xs, 0..) |s, x| {
            var acc: [4]f32 = @splat(0);
            for (s.weights, s.start..) |w, sx| {
                const p = row[sx * 4 ..][0..4];
                const a = @as(f32, @floatFromInt(p[3])) / 255 * w;
                acc[0] += linear[p[0]] * a;
                acc[1] += linear[p[1]] * a;
                acc[2] += linear[p[2]] * a;
                acc[3] += a;
            }
            tmp[y * dw + x] = acc;
        }
    }

    const out = try gpa.alloc(u8, dw * dh * 4);
    for (ys, 0..) |s, y| {
        for (0..dw) |x| {
            var acc: [4]f32 = @splat(0);
            for (s.weights, s.start..) |w, sy| {
                const p = tmp[sy * dw + x];
                inline for (0..4) |c| acc[c] += p[c] * w;
            }
            const px = out[(y * dw + x) * 4 ..][0..4];
            if (acc[3] <= 0) {
                px.* = .{ 0, 0, 0, 0 };
                continue;
            }
            inline for (0..3) |c| {
                const v = std.math.clamp(acc[c] / acc[3], 0, 1);
                px[c] = encode[@intFromFloat(@round(v * srgb_steps))];
            }
            px[3] = @intFromFloat(@round(std.math.clamp(acc[3], 0, 1) * 255));
        }
    }
    return .{ .width = width, .height = height, .rgba = out };
}

const testing = std.testing;

test "downscale averages areas in linear light" {
    const gpa = testing.allocator;
    // 4x2: a black and white checkerboard of columns, then a red row.
    const src: Image = .{ .width = 4, .height = 2, .rgba = @constCast(&[_]u8{
        0,   0, 0, 255, 255, 255, 255, 255, 0,   0, 0, 255, 255, 255, 255, 255,
        255, 0, 0, 255, 255, 0,   0,   255, 255, 0, 0, 0,   255, 0,   0,   0,
    }) };
    var img = try downscale(gpa, src, 2, 1);
    defer img.deinit(gpa);
    // Left: black, white and two reds, all opaque.
    try testing.expectEqualSlices(u8, &.{ 225, 137, 137, 255 }, img.rgba[0..4]);
    // Right: black and white average to linear 0.5, which is sRGB 188 and
    // not 128; the transparent reds add nothing but halve the alpha.
    try testing.expectEqualSlices(u8, &.{ 188, 188, 188, 128 }, img.rgba[4..8]);

    // Scaling to the same size changes nothing.
    var same = try downscale(gpa, src, 4, 2);
    defer same.deinit(gpa);
    try testing.expectEqualSlices(u8, src.rgba[0..24], same.rgba[0..24]);
}
