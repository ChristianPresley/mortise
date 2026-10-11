# Images

After a page renders, Mortise completes each `<img>` whose `src` names a
PNG, JPEG, GIF or WebP file of the site, whether it came from Markdown
(`![alt](/images/photo.jpg)`) or a template:

- **`width` and `height`** from the file's header, so the browser reserves
  the image's space before it loads and the page does not jump. A JPEG
  turned by its EXIF orientation reports its upright size.
- **`loading="lazy"` and `decoding="async"`** on every image but the
  page's first, which is often at the top of the page and should load at
  once.
- **`srcset` and `sizes`**, when `widths` is set (below): a PNG or JPEG
  wider than a listed width also gets copies scaled to each smaller width,
  written next to it as `photo.480w.jpg`, `photo.960w.jpg`, and so on.

An attribute the page already sets is left alone, and so is an image that
already has a `srcset`. External images and SVG files are not touched,
except for lazy loading.

```html
<img src="/images/photo.jpg" alt="Harbor" loading="lazy" decoding="async"
  width="1600" height="1000"
  srcset="/images/photo.480w.jpg 480w, /images/photo.960w.jpg 960w, /images/photo.jpg 1600w"
  sizes="auto, (min-width: 1600px) 1600px, 100vw">
```

Width and height attributes need `height: auto` in the stylesheet wherever
images are scaled with `max-width`, or they are stretched:

```css
img { max-width: 100%; height: auto; }
```

The built-in themes and `mortise new` include this rule.

## Settings

All settings live under `images:` in `_config.yml`:

```yaml
images:
  widths: [480, 960, 1600]   # resized copies; none by default
  quality: 82                # JPEG quality of the copies, 1 to 100
  sizes: "(min-width: 60rem) 40rem, 100vw"
  dimensions: true           # add width and height
  lazy: true                 # add loading="lazy" after the first image
```

`images: false` turns everything off.

Without `sizes`, lazy images get `auto, (min-width: Wpx) Wpx, 100vw`, where
W is the image's width: browsers that support `auto` pick a copy for the
width the image is actually laid out at, and the rest assume it is as wide
as the screen, up to its own width. Set `sizes` when a layout's images are
always narrower than the screen, such as in a sidebar layout.

## Resizing

Copies are scaled down by averaging the area each new pixel covers, in
linear light with premultiplied alpha, so fine detail and transparent
edges keep their brightness. PNG copies are PNG; JPEG copies are baseline
JPEGs with 4:2:0 chroma subsampling, turned upright if the original had an
EXIF orientation. No width larger than the original is made.

`mortise build` resizes every image on every run. `mortise serve` keeps the
copies and image headers between rebuilds, keyed by each file's path,
size and modification time, so only a changed image is resized again.
Editing an image re-renders the pages that show it.

An image Mortise cannot decode (see the limitations) fails the build when
`widths` is set, naming the file.
