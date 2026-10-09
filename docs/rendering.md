# Rendered graphics

Mortise can draw images while it builds a site: starfields, HUD panel
frames, radar scopes, planets and hologram wireframes. Describe each image in
a small spec file under `_render/`, and the build writes the PNG (and, for
some kinds, a stylesheet) to the matching path in the output. No image
editor, no browser JavaScript.

```
_render/images/stars.yml   ->  /images/stars.png
_render/hud/panel.yml      ->  /hud/panel.png and /hud/panel.css
```

A spec uses the [frontmatter](frontmatter.md) format without the `---`
lines:

```yaml
# _render/images/stars.yml
kind: starfield
width: 1024
height: 512
seed: 7
nebula_color: "#7a1d4f"
```

Then use the image like any other:

```css
body { background: #03050c url("/images/stars.png") repeat; }
```

Write colors as quoted hex, such as `"#3fd8ff"`, because an unquoted `#`
starts a comment. Angles are in degrees. A misspelled field, a value out of
range, or an unknown kind stops the build with the spec's file and line.

The images are drawn by the [`render`](../render/README.md) module, on the
CPU, in linear light. The same spec always gives the same image.

## Kinds that come with CSS

Kinds you use through CSS get a stylesheet next to the image, named after
the spec. It defines one class, also named after the spec. Link it and use
the class:

```html
<link rel="stylesheet" href="{{ site.baseurl }}/hud/panel.css">
<div class="panel">Any content; the frame stretches to fit.</div>
```

- `panel` writes a `border-image` rule.
- `radar`, `planet` and `hologram` with `frames` above 1 write a sprite-sheet
  animation that loops every `seconds`. Visitors who ask for reduced motion
  see the first frame.

The stylesheet refers to the image by a relative URL, so it works under any
`baseurl`.

## Kinds and fields

Every field is optional except `kind`.

### starfield

A field of stars with an optional nebula. It tiles seamlessly by default.

| Field              | Default     | Meaning                                        |
| ------------------ | ----------- | ---------------------------------------------- |
| `width`, `height`  | 1024, 512   | Size in pixels (8 to 4096)                     |
| `seed`             | 1           | Change it for a different sky                  |
| `density`          | 8           | Stars per 10,000 square pixels                 |
| `brightness`       | 1           | Multiplies every star                          |
| `spikes`           | 0.004       | Fraction of stars with diffraction spikes      |
| `background`       | `"#03050c"` | Sky color                                      |
| `tileable`         | true        | Wrap stars and clouds around the edges         |
| `nebula`           | true        | Draw a nebula                                  |
| `nebula_color`, `nebula_color2` | violet, teal | The nebula's two colors      |
| `nebula_scale`     | 3           | Cloud features across the width (whole number) |
| `nebula_intensity` | 0.45        | Cloud brightness                               |
| `nebula_coverage`  | 0.55        | Fraction of sky with clouds, 0 to 1            |

### panel

A chamfered HUD frame for CSS `border-image`, with a glowing outline, corner
brackets and a translucent fill. All corner detail sits inside the border
slice, so it stretches to any box. Writes CSS.

| Field             | Default     | Meaning                                    |
| ----------------- | ----------- | ------------------------------------------ |
| `width`, `height` | 256, 256    | Image size; the box it frames can be any size |
| `color`           | `"#3fd8ff"` | Line and fill color                        |
| `chamfer`         | 22          | Size of the cut corners                    |
| `stroke`          | 2           | Outline thickness                          |
| `fill`            | 0.1         | Fill opacity, 0 for none                   |
| `glow`            | 5           | Glow radius, 0 for none                    |
| `margin`          | 14          | Transparent border that holds the glow     |
| `brackets`        | true        | Corner brackets and status pips            |

### reticle

A targeting reticle: graduated ring, broken arcs, crosshair, chevrons.

| Field    | Default     | Meaning                  |
| -------- | ----------- | ------------------------ |
| `size`   | 256         | Width and height         |
| `color`  | `"#3fd8ff"` | Lines                    |
| `accent` | `"#ff5a3c"` | Chevrons and center dot  |
| `glow`   | 4           | Glow radius              |
| `spin`   | 0           | Rotation of the arcs     |

### radar

A radar scope with a sweep and fading blips. Writes CSS when animated.

| Field     | Default     | Meaning                                      |
| --------- | ----------- | -------------------------------------------- |
| `size`    | 192         | Width and height                             |
| `color`   | `"#4dff9a"` | Scope color                                  |
| `blips`   | 4           | Number of contacts, placed by `seed`         |
| `seed`    | 1           | Where the blips are                          |
| `angle`   | 0           | Sweep angle of the first frame               |
| `glow`    | 3           | Glow radius                                  |
| `frames`  | 1           | Frames in one full turn of the sweep         |
| `seconds` | 3           | Length of one loop                           |
| `columns` | 8           | Frames per row in the sprite sheet           |

### planet

A planet lit from the upper left, with an atmosphere. Writes CSS when
animated; the animation is one full turn.

| Field        | Default    | Meaning                                         |
| ------------ | ---------- | ----------------------------------------------- |
| `type`       | terran     | `terran`, `lava`, `ice` or `gas`                |
| `size`       | 256        | Width and height                                |
| `seed`       | 1          | Change it for different continents              |
| `rotation`   | 0          | Turn around the axis                            |
| `tilt`       | 20         | Lean of the axis towards the viewer             |
| `atmosphere` | per type   | A color, `true` for the type's color, or `false` |
| `samples`    | 3          | Anti-aliasing samples per axis (1 to 4)         |
| `frames`, `seconds`, `columns` | 1, 3, 8 | As for `radar`                 |

### hologram

A glowing wireframe turning above a ring, with scanlines. Hidden edges show
faintly through. Writes CSS when animated.

| Field        | Default     | Meaning                                       |
| ------------ | ----------- | --------------------------------------------- |
| `shape`      | icosphere   | `icosphere`, `gem`, `sphere`, `cube`, `torus` |
| `size`       | 160         | Width and height                              |
| `color`      | `"#45e0ff"` | Wireframe color                               |
| `ring`       | true        | Draw the ring                                 |
| `ring_color` | `"#ff5a3c"` | Ring color                                    |
| `wire`       | 1.2         | Line width                                    |
| `hidden`     | 0.2         | Brightness of edges behind the shape, 0 to 1  |
| `frames`, `seconds`, `columns` | 24, 3, 8 | As for `radar`                |

## Speed

Rendering takes from a few milliseconds (a panel) to a few seconds (a large
planet animation). Animation frames render on every CPU core. `mortise
serve` keeps every rendered image and only renders a spec again when that
spec changes, so editing pages, layouts or styles never waits for it.

## Themes

Built-in themes can ship rendered images too: each `themes.Asset` in
`src/themes.zig` is a spec in this format, written to `/theme/NAME.png`
(and `/theme/NAME.css`). Theme stylesheets refer to them relative to
themselves, as `url("theme/NAME.png")`. A site's own file at the same path
replaces the rendered one.
