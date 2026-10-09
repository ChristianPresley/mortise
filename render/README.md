# Mortise render

A small CPU renderer for graphics that are made once, when a site is built:
starfield backgrounds, HUD frames for CSS `border-image`, planets, wireframe
holograms and sprite-sheet animations. It writes PNG files. There is no GPU,
no browser JavaScript and no dependency beyond the Zig standard library, so
the output is plain images that any theme can use.

The module imports nothing from Mortise. It lives in this repository for
now, and `render/` can move to its own repository as it is.

## Try it

```sh
zig build render-gallery            # writes zig-out/render-gallery/
zig build render-gallery -- my/dir  # or somewhere else
zig build test-render               # the renderer's tests only
```

The gallery directory holds every example image, `gallery.css` with the
`border-image` and sprite-sheet rules, and an `index.html` that uses them
the way a theme would. Serve it with `mortise serve zig-out/render-gallery`
to look at it. The whole gallery renders in under 3 seconds on a desktop.

## Use it

In `build.zig`, the module is exported as `render`:

```zig
const render = b.dependency("mortise", .{}).module("render"); // from another package
```

A starfield, saved as a seamless tile:

```zig
const r = @import("render");

var sky = try r.starfield.render(gpa, .{ .width = 1024, .height = 512, .seed = 7 });
defer sky.deinit(gpa);
try r.savePng(gpa, io, dir, "starfield.png", sky, .soft);
```

A panel frame and the CSS that stretches it over any box:

```zig
var p = try r.hud.panel(gpa, .{ .color = r.Color.hex(0x3fd8ff) });
defer p.deinit(gpa);
try r.savePng(gpa, io, dir, "panel.png", p.canvas, .soft);
// .panel { border: {p.slice}px solid transparent;
//          border-image: url("panel.png") {p.slice} fill stretch; }
```

A spinning planet as a sprite sheet, with its CSS animation:

```zig
var sheet = try r.SpriteSheet.init(gpa, 128, 128, 32, 8);
defer sheet.deinit(gpa);
for (0..32) |i| {
    var frame = try r.planet.render(gpa, .{
        .size = 128,
        .rotation = @as(f32, @floatFromInt(i)) * std.math.tau / 32,
    });
    defer frame.deinit(gpa);
    sheet.set(@intCast(i), frame);
}
try r.savePng(gpa, io, dir, "planet.png", sheet.canvas, .soft);
try sheet.writeCss(css_writer, .{ .class = "planet", .url = "planet.png", .seconds = 8 });
```

`render/gallery.zig` has complete examples of everything, including a 3D
scene built from meshes.

## What is in it

| File             | Contents                                                       |
| ---------------- | -------------------------------------------------------------- |
| `Canvas.zig`     | Float RGBA image in linear light, premultiplied; blending, downsampling, tone mapping |
| `color.zig`      | Colors, sRGB conversion, black-body star tints                 |
| `shapes.zig`     | Anti-aliased rectangles, circles, arcs, lines, polylines, polygons, gradients, soft dots |
| `filter.zig`     | Gaussian blur, glow, scanlines                                 |
| `noise.zig`      | Seeded, tileable gradient noise and fractal sums               |
| `math3d.zig`     | Vectors and 4x4 matrices                                       |
| `Mesh.zig`       | Cube, UV sphere, icosphere and torus generators; wireframe edge detection |
| `render3d.zig`   | Z-buffered triangle rasterizer: lighting, rim glow, procedural surfaces, hologram wireframes |
| `starfield.zig`  | Starfields with nebulae                                        |
| `hud.zig`        | Panel frames, reticles, radar scopes                           |
| `planet.zig`     | Terran, lava, ice and gas planets with atmospheres             |
| `SpriteSheet.zig`| Frame packing and CSS `steps` animation                        |
| `png.zig`        | PNG encoder and a decoder for 8-bit images                     |

## How it works

- Every canvas holds 32-bit float RGBA in linear light with premultiplied
  alpha. Blending happens there, so additive glows can go brighter than
  white. `toRgba8` converts to 8-bit sRGB at the end, optionally rolling
  highlights off smoothly (`.soft`) instead of clipping them.
- 2D shapes are signed distance functions. Each pixel's coverage comes from
  its distance to the edge, which anti-aliases any shape at any angle
  without supersampling.
- The 3D renderer rasterizes triangles with perspective-correct attribute
  interpolation, a depth buffer and a top-left fill rule, then shades each
  pixel (Lambert diffuse, Blinn-Phong highlight, rim glow, or a procedural
  surface function). It anti-aliases by supersampling: draw into a
  `Target` several times larger and `resolve` it.
- Noise is hashed, not table-driven, so a seed gives the same image on
  every platform. Periodic noise makes starfields and nebulae tile.
- PNG compression uses `std.compress.flate`; filtering, chunks and CRCs are
  here.

## Limitations

- Everything runs on one thread. The full gallery takes a few seconds; one
  planet at 256 px with 3x supersampling takes well under a second.
- The 3D renderer clips only against the near plane, has no shadows, no
  textures from image files, and no transparency sorting: draw opaque
  meshes first, then additive ones.
- Normals are transformed by the model matrix directly, so non-uniform
  scaling shades slightly wrong. Rotations, translations and uniform scales
  are exact.
- The PNG decoder reads only 8-bit, non-interlaced gray, RGB and RGBA
  files. The encoder always writes 8-bit RGBA.
- Output is deterministic for a given build, but floating-point results can
  differ in the last bit between CPU architectures, so tests check
  properties of images rather than exact pixel hashes.
