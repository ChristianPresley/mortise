//! Animation frames packed into one image, with CSS that plays them back.
//! One image means one request, and CSS `steps()` animation needs no
//! JavaScript.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const Canvas = @import("Canvas.zig");

const SpriteSheet = @This();

canvas: Canvas,
frame_width: u32,
frame_height: u32,
columns: u32,
count: u32,

/// An empty sheet for `count` frames laid out `columns` to a row.
pub fn init(gpa: Allocator, frame_width: u32, frame_height: u32, count: u32, columns: u32) Allocator.Error!SpriteSheet {
    std.debug.assert(count > 0 and columns > 0);
    const cols = @min(columns, count);
    const rows = std.math.divCeil(u32, count, cols) catch unreachable;
    return .{
        .canvas = try Canvas.init(gpa, frame_width * cols, frame_height * rows),
        .frame_width = frame_width,
        .frame_height = frame_height,
        .columns = cols,
        .count = count,
    };
}

pub fn deinit(s: *SpriteSheet, gpa: Allocator) void {
    s.canvas.deinit(gpa);
    s.* = undefined;
}

/// The top-left pixel of frame `i`.
pub fn origin(s: SpriteSheet, i: u32) [2]u32 {
    return .{ (i % s.columns) * s.frame_width, (i / s.columns) * s.frame_height };
}

/// Copies `frame` into slot `i`.
pub fn set(s: SpriteSheet, i: u32, frame: Canvas) void {
    std.debug.assert(i < s.count and frame.width == s.frame_width and frame.height == s.frame_height);
    const o = s.origin(i);
    s.canvas.blit(frame, o[0], o[1]);
}

pub const CssOptions = struct {
    /// The class name that plays the animation, without the dot.
    class: []const u8,
    /// URL of the sheet's PNG as the stylesheet will see it.
    url: []const u8,
    /// Length of one loop.
    seconds: f32 = 1,
};

/// Writes a CSS rule that shows the sheet as an element of one frame's size
/// and cycles through the frames. Visitors who ask for reduced motion see
/// the first frame only.
pub fn writeCss(s: SpriteSheet, w: *Writer, o: CssOptions) Writer.Error!void {
    try w.print(
        \\.{s} {{
        \\  width: {d}px;
        \\  height: {d}px;
        \\  background: url("{s}") 0 0 no-repeat;
        \\  animation: {s}-frames {d}s step-end infinite;
        \\}}
        \\@media (prefers-reduced-motion: reduce) {{
        \\  .{s} {{ animation: none; }}
        \\}}
        \\@keyframes {s}-frames {{
        \\
    , .{ o.class, s.frame_width, s.frame_height, o.url, o.class, o.seconds, o.class, o.class });
    for (0..s.count) |i| {
        const pos = s.origin(@intCast(i));
        const pct = @as(f32, @floatFromInt(i)) * 100 / @as(f32, @floatFromInt(s.count));
        try w.print("  {d:.3}% {{ background-position: -{d}px -{d}px; }}\n", .{ pct, pos[0], pos[1] });
    }
    // The 100% keyframe repeats the last frame so step-end shows it for a
    // full step before the loop restarts.
    const last = s.origin(s.count - 1);
    try w.print("  100% {{ background-position: -{d}px -{d}px; }}\n}}\n", .{ last[0], last[1] });
}

const testing = std.testing;
const Color = @import("color.zig").Color;

test "frames land in grid order" {
    const gpa = testing.allocator;
    var sheet = try init(gpa, 4, 3, 5, 2);
    defer sheet.deinit(gpa);
    try testing.expectEqual(@as(u32, 8), sheet.canvas.width);
    try testing.expectEqual(@as(u32, 9), sheet.canvas.height);
    var frame = try Canvas.init(gpa, 4, 3);
    defer frame.deinit(gpa);
    frame.fill(Color.white);
    sheet.set(3, frame);
    try testing.expectEqual(@as(f32, 1), sheet.canvas.get(4, 3).a);
    try testing.expectEqual(@as(f32, 1), sheet.canvas.get(7, 5).a);
    try testing.expectEqual(@as(f32, 0), sheet.canvas.get(3, 3).a);
    try testing.expectEqual(@as(f32, 0), sheet.canvas.get(4, 6).a);
}

test "css steps through every frame" {
    const gpa = testing.allocator;
    var sheet = try init(gpa, 10, 10, 4, 2);
    defer sheet.deinit(gpa);
    var aw: Writer.Allocating = .init(gpa);
    defer aw.deinit();
    try sheet.writeCss(&aw.writer, .{ .class = "radar", .url = "radar.png", .seconds = 2 });
    const css = aw.written();
    try testing.expect(std.mem.indexOf(u8, css, ".radar {") != null);
    try testing.expect(std.mem.indexOf(u8, css, "animation: radar-frames 2s step-end infinite;") != null);
    try testing.expect(std.mem.indexOf(u8, css, "  50.000% { background-position: -0px -10px; }") != null);
    try testing.expect(std.mem.indexOf(u8, css, "  75.000% { background-position: -10px -10px; }") != null);
}
