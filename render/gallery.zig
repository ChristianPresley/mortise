//! Renders a gallery of every generator into a directory, with an
//! index.html that uses the images the way a theme would: a tiled
//! starfield background, a panel drawn with `border-image`, and sprite
//! sheet animations.
//!
//!     zig build render-gallery -- [OUT_DIR]
//!
//! OUT_DIR defaults to zig-out/render-gallery.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const r = @import("render");
const Canvas = r.Canvas;
const Color = r.Color;
const m3 = r.math3d;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const gpa = init.gpa;
    const args = try init.minimal.args.toSlice(init.arena.allocator());
    const out_path = if (args.len > 1) args[1] else "zig-out/render-gallery";

    var dir = try Io.Dir.cwd().createDirPathOpen(io, out_path, .{});
    defer dir.close(io);

    var css: Io.Writer.Allocating = .init(gpa);
    defer css.deinit();

    const start = Io.Clock.Timestamp.now(io, .awake);
    const g: Gallery = .{ .gpa = gpa, .io = io, .dir = dir, .css = &css.writer };

    {
        var c = try r.starfield.render(gpa, .{ .width = 1024, .height = 512, .seed = 7 });
        defer c.deinit(gpa);
        try g.save("starfield.png", c);
    }
    {
        var c = try r.starfield.render(gpa, .{ .width = 512, .height = 512, .seed = 21, .nebula = .{
            .colors = .{ Color.hex(0x7a1d4f), Color.hex(0xd0702a) },
            .intensity = 0.6,
            .coverage = 0.6,
            .scale = 2,
        } });
        defer c.deinit(gpa);
        try g.save("starfield-ember.png", c);
    }
    {
        var p = try r.hud.panel(gpa, .{});
        defer p.deinit(gpa);
        try g.save("panel.png", p.canvas);
        try css.writer.print(
            \\.panel {{
            \\  border: {d}px solid transparent;
            \\  border-image: url("panel.png") {d} fill stretch;
            \\}}
            \\
        , .{ p.slice, p.slice });
    }
    {
        var p = try r.hud.panel(gpa, .{ .color = Color.hex(0xffb03a), .chamfer = 14, .glow = 4 });
        defer p.deinit(gpa);
        try g.save("panel-amber.png", p.canvas);
        try css.writer.print(
            \\.panel-amber {{
            \\  border: {d}px solid transparent;
            \\  border-image: url("panel-amber.png") {d} fill stretch;
            \\}}
            \\
        , .{ p.slice, p.slice });
    }
    {
        var c = try r.hud.reticle(gpa, .{});
        defer c.deinit(gpa);
        try g.save("reticle.png", c);
    }
    try g.radarSheet();
    for ([_]r.planet.Kind{ .terran, .lava, .ice, .gas }) |kind| {
        var c = try r.planet.render(gpa, .{
            .kind = kind,
            .seed = 3,
            .rotation = 0.6,
            .atmosphere = switch (kind) {
                .terran => Color.hex(0x5ab4ff),
                .lava => Color.hex(0xff7a30),
                .ice => Color.hex(0xbfe8ff),
                .gas => Color.hex(0xffd9a0),
            },
        });
        defer c.deinit(gpa);
        var name_buf: [32]u8 = undefined;
        try g.save(try std.fmt.bufPrint(&name_buf, "planet-{s}.png", .{@tagName(kind)}), c);
    }
    try g.planetSheet();
    try g.hologramSheet();
    try g.station();

    try dir.writeFile(io, .{ .sub_path = "gallery.css", .data = css.written() });
    try dir.writeFile(io, .{ .sub_path = "index.html", .data = index_html });
    const elapsed = start.durationTo(Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds;
    std.debug.print("wrote {s} in {d} ms\n", .{ out_path, @divTrunc(elapsed, std.time.ns_per_ms) });
}

const Gallery = struct {
    gpa: Allocator,
    io: Io,
    dir: Io.Dir,
    css: *Io.Writer,

    fn save(g: Gallery, name: []const u8, c: Canvas) !void {
        try r.savePng(g.gpa, g.io, g.dir, name, c, .soft);
    }

    fn radarSheet(g: Gallery) !void {
        const frames = 36;
        var sheet = try r.SpriteSheet.init(g.gpa, 160, 160, frames, 6);
        defer sheet.deinit(g.gpa);
        const blips = [_][2]f32{ .{ 0.62, 0.9 }, .{ 0.35, 2.6 }, .{ 0.8, 4.4 }, .{ 0.5, 5.5 } };
        for (0..frames) |i| {
            const a = @as(f32, @floatFromInt(i)) * std.math.tau / frames;
            var c = try r.hud.radar(g.gpa, .{ .size = 160, .angle = a, .blips = &blips });
            defer c.deinit(g.gpa);
            sheet.set(@intCast(i), c);
        }
        try g.save("radar.png", sheet.canvas);
        try sheet.writeCss(g.css, .{ .class = "radar", .url = "radar.png", .seconds = 3 });
    }

    fn planetSheet(g: Gallery) !void {
        const frames = 32;
        var sheet = try r.SpriteSheet.init(g.gpa, 128, 128, frames, 8);
        defer sheet.deinit(g.gpa);
        for (0..frames) |i| {
            var c = try r.planet.render(g.gpa, .{
                .size = 128,
                .seed = 11,
                .samples = 2,
                .rotation = @as(f32, @floatFromInt(i)) * std.math.tau / frames,
            });
            defer c.deinit(g.gpa);
            sheet.set(@intCast(i), c);
        }
        try g.save("planet-spin.png", sheet.canvas);
        try sheet.writeCss(g.css, .{ .class = "planet-spin", .url = "planet-spin.png", .seconds = 8 });
    }

    /// A glowing wireframe icosphere inside a counter-rotating ring.
    fn hologramSheet(g: Gallery) !void {
        const gpa = g.gpa;
        const frames = 24;
        const size = 160;
        var ico = try r.Mesh.icosphere(gpa, 1, 1);
        defer ico.deinit(gpa);
        var ring = try r.Mesh.torus(gpa, 1.45, 0.02, 96, 6);
        defer ring.deinit(gpa);
        var sheet = try r.SpriteSheet.init(gpa, size, size, frames, 6);
        defer sheet.deinit(gpa);
        const cyan = Color.hex(0x45e0ff);
        const cam: r.render3d.Camera = .{ .eye = .{ 0, 1.2, 4.2 }, .projection = .{ .perspective = 0.75 } };
        for (0..frames) |i| {
            const t = @as(f32, @floatFromInt(i)) * std.math.tau / frames;
            // Half a turn per loop around the mesh's own y axis, which is
            // an axis of two-fold symmetry, so the loop is seamless.
            const spin = m3.Mat4.rotation(.{ 1, 0, 0 }, 0.4).mul(m3.Mat4.rotation(.{ 0, 1, 0 }, t / 2));
            var target = try r.render3d.Target.init(gpa, size, size, 3);
            defer target.deinit(gpa);
            try r.render3d.drawMesh(gpa, &target, ico, spin, cam, .{}, .{
                .color = .black,
                .emissive = cyan.scale(0.02),
                .rim = .{ .color = cyan.scale(0.6), .power = 2.5 },
                .blend = .add,
                .opacity = 0.5,
                .wire = .{ .color = cyan, .width = 1.2, .hidden = 0.2 },
            });
            const tilt = m3.Mat4.rotation(.{ 0, 0, 1 }, 0.3).mul(m3.Mat4.rotation(.{ 0, 1, 0 }, -t));
            try r.render3d.drawMesh(gpa, &target, ring, tilt, cam, .{}, .{
                .color = .black,
                .emissive = Color.hex(0xff5a3c),
            });
            var frame = try target.resolve(gpa);
            defer frame.deinit(gpa);
            try r.filter.glow(gpa, frame, 4, 0.6, .transparent);
            r.filter.scanlines(frame, 3, 0.35);
            sheet.set(@intCast(i), frame);
        }
        try g.save("hologram.png", sheet.canvas);
        try sheet.writeCss(g.css, .{ .class = "hologram", .url = "hologram.png", .seconds = 2.4 });
    }

    /// A lit station: a ring around a faceted core, against the dark.
    fn station(g: Gallery) !void {
        const gpa = g.gpa;
        var core = try r.Mesh.icosphere(gpa, 0.7, 0);
        defer core.deinit(gpa);
        var ring = try r.Mesh.torus(gpa, 1.6, 0.18, 64, 16);
        defer ring.deinit(gpa);
        var spoke = try r.Mesh.cube(gpa, 1);
        defer spoke.deinit(gpa);
        var target = try r.render3d.Target.init(gpa, 384, 256, 3);
        defer target.deinit(gpa);
        const cam: r.render3d.Camera = .{ .eye = .{ 2.6, 1.8, 3.6 }, .projection = .{ .perspective = 0.75 } };
        const light: r.render3d.Light = .{ .direction = .{ -0.4, 0.7, 0.6 }, .color = Color.gray(1.2) };
        const hull: r.render3d.Material = .{
            .color = Color.hex(0x9aa3ad),
            .specular = 0.5,
            .shininess = 40,
            .rim = .{ .color = Color.hex(0x3fd8ff).withAlpha(0.5), .power = 4 },
        };
        const tilt = m3.Mat4.rotation(.{ 0, 0, 1 }, 0.25);
        var core_mat = hull;
        core_mat.shading = .flat;
        core_mat.color = Color.hex(0x6f7a88);
        core_mat.wire = .{ .color = Color.hex(0x3fd8ff), .width = 1, .crease_deg = 5 };
        try r.render3d.drawMesh(gpa, &target, core, tilt, cam, light, core_mat);
        try r.render3d.drawMesh(gpa, &target, ring, tilt, cam, light, hull);
        for (0..4) |i| {
            const a = @as(f32, @floatFromInt(i)) * std.math.pi / 2.0;
            const m = tilt.mul(m3.Mat4.rotation(.{ 0, 1, 0 }, a))
                .mul(m3.Mat4.translation(.{ 1.05, 0, 0 }))
                .mul(m3.Mat4.scaling(.{ 0.45, 0.05, 0.05 }));
            try r.render3d.drawMesh(gpa, &target, spoke, m, cam, light, hull);
        }
        // Running lights around the ring.
        for (0..24) |i| {
            const a = @as(f32, @floatFromInt(i)) * std.math.tau / 24;
            const m = tilt.mul(m3.Mat4.rotation(.{ 0, 1, 0 }, a))
                .mul(m3.Mat4.translation(.{ 1.6, 0.19, 0 }))
                .mul(m3.Mat4.scaling(.{ 0.025, 0.025, 0.025 }));
            try r.render3d.drawMesh(gpa, &target, spoke, m, cam, light, .{
                .color = .black,
                .emissive = if (i % 6 == 0) Color.hex(0xff4a3a).scale(3) else Color.hex(0xfff2c0).scale(2),
            });
        }
        var img = try target.resolve(gpa);
        defer img.deinit(gpa);
        try r.filter.glow(gpa, img, 3, 0.5, .transparent);
        try g.save("station.png", img);
    }
};

const index_html =
    \\<!doctype html>
    \\<html lang="en">
    \\<head>
    \\<meta charset="utf-8">
    \\<meta name="viewport" content="width=device-width, initial-scale=1">
    \\<title>Mortise render gallery</title>
    \\<link rel="stylesheet" href="gallery.css">
    \\<style>
    \\  body { margin: 0; color: #cfefff; font: 15px/1.5 system-ui, sans-serif;
    \\         background: #03050c url("starfield.png") repeat; }
    \\  main { max-width: 1100px; margin: 0 auto; padding: 24px 16px 64px; }
    \\  h1 { font-weight: 300; letter-spacing: .2em; text-transform: uppercase; }
    \\  .grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(260px, 1fr)); gap: 24px; }
    \\  figure { margin: 0; text-align: center; }
    \\  figcaption { opacity: .7; font-size: 13px; }
    \\  img { max-width: 100%; }
    \\  .panel, .panel-amber { padding: 8px 16px; margin: 24px 0; }
    \\  .panel-amber { color: #ffe2b0; }
    \\  .ember { height: 200px; background: url("starfield-ember.png") repeat; }
    \\  .radar, .planet-spin, .hologram { margin: 0 auto; }
    \\</style>
    \\</head>
    \\<body>
    \\<main>
    \\<h1>Mortise render</h1>
    \\<div class="panel">
    \\  <h2>Border-image panel</h2>
    \\  <p>This box is drawn with <code>panel.png</code> as a CSS border image. It
    \\  stretches to any size because all of the corner detail sits inside the slice.
    \\  The page background is <code>starfield.png</code>, a seamless tile.</p>
    \\</div>
    \\<div class="grid">
    \\  <figure><div class="radar"></div><figcaption>radar.png, 36-frame sprite sheet</figcaption></figure>
    \\  <figure><div class="planet-spin"></div><figcaption>planet-spin.png, 32 frames</figcaption></figure>
    \\  <figure><div class="hologram"></div><figcaption>hologram.png, wireframe with hidden lines</figcaption></figure>
    \\  <figure><img src="reticle.png" alt=""><figcaption>reticle.png</figcaption></figure>
    \\  <figure><img src="planet-terran.png" alt=""><figcaption>planet-terran.png</figcaption></figure>
    \\  <figure><img src="planet-lava.png" alt=""><figcaption>planet-lava.png</figcaption></figure>
    \\  <figure><img src="planet-ice.png" alt=""><figcaption>planet-ice.png</figcaption></figure>
    \\  <figure><img src="planet-gas.png" alt=""><figcaption>planet-gas.png</figcaption></figure>
    \\  <figure><img src="station.png" alt=""><figcaption>station.png, lit meshes</figcaption></figure>
    \\</div>
    \\<div class="panel-amber">
    \\  <h2>Amber variant</h2>
    \\  <div class="ember"></div>
    \\  <p>starfield-ember.png: a second seed with a warm nebula.</p>
    \\</div>
    \\</main>
    \\</body>
    \\</html>
    \\
;
