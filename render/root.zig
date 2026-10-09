//! Mortise render: a small CPU renderer for build-time graphics.
//!
//! It draws into floating-point canvases in linear light and writes PNG
//! files, with no GPU, no browser and no dependencies beyond the Zig
//! standard library. It is meant for assets that are rendered once when a
//! site is built: starfield backgrounds, HUD frames for CSS
//! `border-image`, planets, wireframe holograms and sprite-sheet
//! animations.
//!
//! The pieces, from low level to high:
//! - `Canvas`, `Color`: pixels and blending.
//! - `shapes`, `filter`, `noise`: anti-aliased 2D shapes, blur and glow,
//!   gradient noise.
//! - `math3d`, `Mesh`, `render3d`: a z-buffered triangle rasterizer.
//! - `starfield`, `hud`, `planet`: ready-made generators.
//! - `SpriteSheet`, `png`: packing frames and writing files.
//!
//! This module depends only on `std`, so it can move to its own repository.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const color = @import("color.zig");
pub const Color = color.Color;
pub const Canvas = @import("Canvas.zig");
pub const png = @import("png.zig");
pub const shapes = @import("shapes.zig");
pub const filter = @import("filter.zig");
pub const noise = @import("noise.zig");
pub const math3d = @import("math3d.zig");
pub const Mesh = @import("Mesh.zig");
pub const render3d = @import("render3d.zig");
pub const starfield = @import("starfield.zig");
pub const hud = @import("hud.zig");
pub const planet = @import("planet.zig");
pub const SpriteSheet = @import("SpriteSheet.zig");

/// Encodes a canvas as a PNG file in memory. The caller owns the result.
pub fn encodePng(gpa: Allocator, c: Canvas, tone: Canvas.ToneMap) Allocator.Error![]u8 {
    const rgba = try c.toRgba8(gpa, tone);
    defer gpa.free(rgba);
    return png.encodeAlloc(gpa, c.width, c.height, rgba, .{});
}

/// Writes a canvas to `sub_path` in `dir` as a PNG file.
pub fn savePng(gpa: Allocator, io: std.Io, dir: std.Io.Dir, sub_path: []const u8, c: Canvas, tone: Canvas.ToneMap) !void {
    const bytes = try encodePng(gpa, c, tone);
    defer gpa.free(bytes);
    try dir.writeFile(io, .{ .sub_path = sub_path, .data = bytes });
}

test {
    std.testing.refAllDecls(@This());
}

test "encodePng round-trips through png.decode" {
    const gpa = std.testing.allocator;
    var c = try Canvas.init(gpa, 5, 4);
    defer c.deinit(gpa);
    shapes.circle(c, .{ .x = 2.5, .y = 2 }, 1.5, .solid(Color.hex(0xff8800)));
    const bytes = try encodePng(gpa, c, .clamp);
    defer gpa.free(bytes);
    var img = try png.decode(gpa, bytes);
    defer img.deinit(gpa);
    try std.testing.expectEqualSlices(u8, &.{ 0xff, 0x88, 0x00, 0xff }, img.rgba[(2 * 5 + 2) * 4 ..][0..4]);
}
