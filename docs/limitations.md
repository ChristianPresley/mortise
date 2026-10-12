# Known limitations

This list grows with each milestone. Anything Mortise does not handle, or
handles differently from what a user might expect, belongs here.

## Languages

Mortise, its build script, its tests, and its benchmark are written only in
Zig. Two pieces of non-Zig code remain because nothing else can do their
job:

- **The dev server's browser script.** Reloading a page and drawing the
  error overlay has to happen inside the browser, which runs JavaScript. The
  script is a string in `src/server.zig`, sent only by `serve`, and never
  appears in `build` output.
- **The search client.** Searching happens in the reader's browser, so
  `search: true` writes `src/search.js`, a small hand-written script with
  no libraries, to the site. Sites without search get no script.
- **The CI bootstrap step.** CI has to download Zig before any Zig code can
  run, so one workflow step uses the runner's shell (`curl`, a checksum
  check, and `tar` or `unzip`). Every other check (the exact Zig version,
  the empty dependency table) is enforced by `build.zig`.
- **Release packaging.** The release workflow packs the binaries with the
  runner's `tar`, `zip` and `sha256sum` and publishes them with `gh`. The
  starters' Pages workflow downloads a release the same way.

## Releases and starters

- Release binaries are built for six targets only; other systems need a
  build from source.
- The starters' Pages workflow pins the Mortise version that created the
  site. Raise `MORTISE_VERSION` in it to build with a newer release.
- The Pages workflow does not set `baseurl`; a project site at
  `https://USER.github.io/REPO/` needs `baseurl: /REPO` in `_config.yml`,
  and Markdown links should be relative (`docs/`, `../configuration/`)
  because `baseurl` is not added to them.

## Paths and files

- **Both `/` and `\` are path separators on every platform.** A file on Linux
  or macOS whose name contains a backslash cannot be part of a site; the
  build reports it as an invalid path.
- **Names Windows cannot create are rejected everywhere.** A component may
  not contain `< > : " | ? *` or control characters, may not end in `.` or a
  space, and may not be a reserved device name (`CON`, `PRN`, `AUX`, `NUL`,
  `COM1`–`COM9`, `LPT1`–`LPT9`, with or without an extension). This keeps a
  site portable, at the cost of rejecting names that are legal on Linux and
  macOS.
- **Case is not normalized.** `About.md` and `about.md` are different site
  paths. Two outputs that differ only in case are rejected, because they
  would overwrite each other on the default case-insensitive file systems
  of Windows and macOS.
- **Symlinks are skipped** when listing a source tree, as are sockets, pipes
  and other special files.
- **Files larger than 64 MiB are not read.** The build fails with
  `StreamTooLong`.
- **Non-UTF-8 file names on Linux** are passed through as bytes and are not
  validated as UTF-8.

## Memory

- Each build allocates from one arena that is freed when the next build
  starts. Up to 64 MiB of that capacity is kept between dev-server rebuilds
  rather than returned to the OS.

## Markdown

- Only the subset in [markdown.md](markdown.md) is supported. Everything in
  its "Not supported" list renders as literal paragraph text.
- Content is trusted. Link and image destinations are not filtered, so a
  `javascript:` URL in a source file is written to the output unchanged.
- Emphasis rules treat non-ASCII whitespace and punctuation as letters.
- Heading anchors and copy buttons apply to Markdown pages only, not to
  HTML templates or OpenAPI pages. The copy script is inline, so a Content
  Security Policy without `'unsafe-inline'` blocks it; set
  `copy_code: false` on such sites.
- Heading anchors add a `#` to the heading's text content, which `strip_html`
  and `word_count` see.
- `<<<` includes only files inside the site directory, so a docs site in a
  subfolder cannot include its repository's source files. Included files
  are code only; Markdown files cannot be included as Markdown.
- Region markers are found by text: a line that merely mentions `#region`
  or `#endregion` in a string counts as a marker.
- Shortcodes work only on a line of their own; `{{< x >}}` in the middle of
  a sentence stays text. Arguments are text only (no numbers, lists or
  expressions), and there are no positional arguments.
- Shortcodes render while pages load, so their templates see the config as
  `site` but not `site.posts`, `site.pages`, navigation or data files.

## Wikilinks and backlinks

- Wikilinks are resolved after Markdown renders, so a missing page is
  marked in the output rather than reported with a line number, and an
  ambiguous name's error names the file but not the line.
- `![[embeds]]` (transclusion) and wikilinks in templates are not
  supported; `[[...]]` inside a link's text is literal.
- Heading anchors in `[[Page#Heading]]` are the heading's slug; a heading
  whose id got a `-2` suffix for being repeated cannot be targeted by name.
- Backlinks count links in Markdown content only, not links written in
  layouts, includes or HTML pages.
- Editing any page re-renders every page that has wikilinks or shows
  backlinks, since either can change when another page's title does.

## Math

- Only the TeX listed in [markdown.md](markdown.md#math) is understood: no
  macros (`\newcommand`), no `\tag` or equation numbers, no `\color`, and no
  chemistry or diagram packages.
- Math errors name the file and the formula, not the line.
- Typesetting is left to the browser's MathML support, which differs a
  little between browsers; very old browsers show the formula's text.
- `...` must sit inside one paragraph: a blank line inside it ends the
  math. Use a `math` code block for long display math.

## Diagrams

- Only Mermaid flowcharts and sequence diagrams are drawn; other kinds
  (class, state, Gantt, pie, ...) and flowchart subgraphs fail the build.
- Styling lines (`classDef`, `style`, ...) are ignored, as are click handlers,
  `activate` and `autonumber`.
- Flowchart layout is a simple layered layout: links between nodes in the
  same layer, and links from a node to itself, are not drawn well, and big
  charts can have crossings a better layout would avoid.
- Text sizes are estimated, since SVG text cannot be measured at build
  time; very long labels can overflow their boxes. Labels are one line.

## Data files

- Changing anything in `_data/` rebuilds the whole site, since any page may
  read `site.data`.
- JSON `null` becomes an empty value. Very large JSON integers that do not
  fit in 64 bits are kept as strings.
- A data file and a directory with the same name (`_data/a.json` and
  `_data/a/`) are an error.

## Feed and sitemap

- The feed and sitemap are only generated when `_config.yml` sets an
  absolute `url`.
- Feed entries use midnight UTC on the post's date as their time, so builds
  stay reproducible. Posts without a title get an empty one.
- Feed content is the post's rendered Markdown; relative links in it are
  not rewritten to absolute ones.
- The sitemap has no `changefreq` or `priority`, and `lastmod` only for
  posts and pages with `updated:` in their frontmatter.
- The generated `robots.txt` allows every crawler; write your own
  `robots.txt` for anything else. Like the sitemap, it needs `url`.

## Git dates

- `git_dates` reads `.git` directly and supports SHA-1 repositories with
  loose objects and version 2 pack indexes, including linked worktrees.
  SHA-256 repositories, commit-graph and bitmap shortcuts, and partial
  clones with missing objects are not supported; a missing parent commit
  (a shallow clone) ends the history there.
- Dates follow the first parent only, like `git log --first-parent`: a
  file changed on a merged branch is dated by the merge commit.
- Uncommitted changes do not count; a page edited but not committed keeps
  its last commit's date.
- Only `.md` and `.html` pages get dates; the history is read once per full
  build, so `serve` picks up new commits on the next full rebuild.
- Pack files are read into memory whole, which suits documentation
  repositories but not multi-gigabyte ones.

## Redirects

- Alias pages redirect with `<meta http-equiv="refresh">`, which works on
  any static host but is a client-side redirect: the old URL answers
  `200 OK`, not `301`. The `_redirects` file gives a real `301` only on
  hosts that read it (Netlify, Cloudflare Pages); GitHub Pages ignores it.
- Aliases are paths on this site; they cannot redirect to other sites, and
  `_redirects` lists exact paths without wildcards or splats.

## Themes

- Pages use a theme's layouts only when they name one (`layout: post`);
  there are no default layouts per page kind.
- Site themes cannot ship rendered images; put specs in the site's
  `_render/theme/` instead.
- A built-in theme's files are reported as `(theme NAME) _layouts/FILE`
  in errors; copy the file into the site to change it.

## Design tokens

- Token values are hex colors only (`#rgb` or `#rrggbb`); no `rgb()`,
  named colors, transparency or non-color tokens such as sizes or fonts.
- Overriding tokens recolors a theme's CSS but not its rendered art:
  `visor`'s panel frames and `lcars`'s planet and hologram keep their
  colors. Copy the specs into `_render/theme/` to recolor them.
- The contrast check covers four fixed token pairs, not every color
  combination a theme or site stylesheet uses, and ignores alpha.
- `light-dark()` and `:has()` need a 2024 browser (Chrome 123, Firefox
  120, Safari 17.5); older browsers fall back to the light colors and
  ignore the scheme switch.
- Without JavaScript the scheme switch resets to Auto on every page.

## Site icons

- The icon is drawn from letters in the built-in stroke font; there is no
  way to use a logo image except by putting your own `favicon.ico` and
  PNGs in the site, which replace the generated ones.
- No SVG icon, maskable icon or Windows tile images are written.
- The web manifest names the site and its icons only; it has no
  `description`, `scope`, shortcuts or screenshots.

## Images

- Only PNG and JPEG files are resized. GIF and WebP images get sizes and
  lazy loading but no `srcset`; SVG images get only lazy loading.
- The JPEG decoder reads 8-bit Huffman-coded baseline and progressive
  files. Arithmetic-coded, lossless, 12-bit and CMYK JPEGs cannot be
  resized, and fail the build when `widths` is set.
- Resized copies drop all metadata, including ICC color profiles, so a
  wide-gamut (Display P3 or Adobe RGB) photo's copies show less saturated
  colors than the original. Copies are always treated as sRGB.
- The JPEG decoder upsamples chroma by repeating samples, which can show
  slight color fringes along sharp edges in subsampled originals before
  they are scaled down.
- Only `<img>` tags in rendered pages are completed. `<picture>` sources,
  CSS backgrounds, and images in HTML files copied unchanged are not.
- `mortise build` resizes every image on every run; a site with many
  large photos builds slowly. `mortise serve` keeps the copies between
  rebuilds.
- A copy's name (`photo.480w.jpg`) can collide with a file of the same
  name in the site; the site's own file wins and no copy is made.
- The page's first image is never lazy, even when it is far down the page.

## llms.txt and twins

- Markdown twins hold the page's source after frontmatter, as written:
  component, include and template syntax is left as it is, and links keep
  pointing at HTML pages rather than at other twins.
- Template (`.html`) pages and OpenAPI pages have no twin; `llms.txt` links
  their HTML. `llms.txt` lists every page, in path order, without grouping
  them into sections of their own.
- `mortise serve` sends twins and `llms.txt` as `text/plain`.
- The JSON Feed carries the same 20 newest posts as the Atom feed, with no
  summaries, images or tags.

## Rendered graphics

- `mortise build` renders every `_render/` spec and theme asset from scratch
  each time; a large planet animation can take a few seconds. Only
  `mortise serve` keeps rendered images between builds.
- The dev server keeps every version of a spec it has rendered until it
  exits, so editing a large spec many times grows its memory.
- Editing a spec rebuilds the whole site (cheaply, since unchanged images
  come from the cache) rather than only that spec's outputs.
- Templates cannot read a rendered image's size or a panel's border slice;
  use the generated stylesheet instead.
- Specs choose from a fixed set of kinds and fields. Anything else means
  writing Zig against the `render` module (see render/README.md).

## SEO and social cards

- Social cards are drawn from scratch on every `build`, about 0.1 s each
  in a release build (several at once on a multi-core machine) and several
  times slower in a debug build. `serve` keeps them between rebuilds.
- Card titles use the built-in stroke font: characters outside ASCII and
  common accented Latin letters are drawn as boxes, so titles in other
  scripts get unreadable cards. Set `image:` on such pages, or
  `social_cards: false`.
- Without `url` in `_config.yml`, Open Graph URLs and images stay
  root-relative, which most link previews ignore.
- Descriptions are cut from the first paragraph by characters, not by
  rendered width, and inline markup is dropped.
- `seo` writes no `<title>`, `hreflang`, robots or author meta tags.

## Themes

- Themes name fonts that are common on each system but ship none, so
  type looks somewhat different on Windows, macOS and Linux; `cockpit`,
  `cyberdeck` and `visor` look best with Bahnschrift (Windows).
- `grid`'s floor and `cockpit`'s canopy are fixed behind the page; very
  short windows show little of them, and `cockpit` hides its struts below
  900 pixels wide.
- `phosphor` and `freighter` add scanlines over the whole page, which
  slightly dims images.
- The theme gallery's previews are scaled-down frames of the real pages,
  so it loads every theme's home page at once.

## Charts

- Charts are bar (grouped, not stacked), line, area, pie and donut only,
  with at most six series. There are no logarithmic or time axes; labels are
  evenly spaced text.
- Label and legend sizes are estimated, since SVG text cannot be measured at
  build time: long legends can run past the right edge, and crowded x-axis
  labels are thinned to every second or third one.
- Errors name the line within the chart block, not within the Markdown
  file.
- Hovering shows values through SVG `<title>` tooltips, which touch screens
  do not show.

## Syntax highlighting

- Highlighting is lexical: keywords, literals, strings, numbers, comments,
  and Zig builtins. It does not know about types, function names, or
  string interpolation, and nested constructs such as JavaScript template
  literals are marked as one string.
- Only the listed languages are highlighted; HTML and CSS are not.
- There are two built-in themes (see docs/themes.md). They style the layout
  hooks listed there; other markup keeps the site's own styles.

## Templates

- Built-in filters only; no custom filters.
- Conditions have no parentheses. Filters work in output tags, `assign` and
  loop lists, not in conditions.
- Outside strict mode (the default for `build`), missing variables render
  as nothing, so a typo in a variable name produces empty output rather
  than an error. Strict mode does not check conditions, or fields of a
  missing value that a loop iterates.
- `upper`, `lower` and `slugify` change ASCII letters only; `slugify` keeps
  other non-ASCII bytes as they are.
- `truncate` counts code points, not grapheme clusters, and `size` counts
  a string's bytes.
- `reading_time` assumes 200 words a minute and counts words by spaces, so
  text without spaces (Chinese, Japanese) counts as few words.
- `sort` compares strings byte by byte, not by locale.
- `json` output is safe inside `<script>` but not inside an HTML attribute.
- Dates use English month and day names. Outside Liquid mode an unknown
  `date` directive is an error.

## Liquid

- Raw HTML in Markdown passes through only with `liquid: true`; Mortise
  sites escape it. HTML blocks follow CommonMark, not kramdown: Markdown
  inside a block is converted only after a blank line, and kramdown's
  `markdown="1"` and `markdown="0"` attributes are written out unchanged
  rather than obeyed. An HTML block line indented four or more spaces is
  inline HTML in a paragraph, since Mortise has no indented code blocks.
  Character references such as `&nbsp;` pass through in Liquid mode
  without being checked against HTML's list of names, and heading ids
  leave them out.
- Front matter `defaults:` has no `drafts` type, and a change to
  `defaults:` rebuilds the whole site, as any config change does.
- Collections: Jekyll's `order:` list, `collections_dir`, `site.documents`, a
  collection's `files` and `directory`, or settings beyond `output`,
  `sort_by` and `permalink`. Posts cannot be configured under
  `collections:`. Adding, removing or editing a document of an unpublished
  collection rebuilds the pages that read `site.LABEL`, and adding or
  removing any document rebuilds the whole site.
- Permalinks: without `permalink:` in the config, posts publish at
  `/:categories/:year/:month/:day/:title/` rather than Jekyll's `date`
  style, and Markdown pages get a folder; set `permalink: date` for
  Jekyll's URLs. Categories come only from front matter, not from folders
  above `_posts/`, which Mortise does not read. Placeholder values are
  used as they are, not URL-escaped, and the `:path` of a nested
  collection document keeps its case and spaces. Jekyll's `:slugified_categories`,
  `:basename` for collections and the `jekyll-permalinks` plugin's
  extras are not supported.
- `site.tags` keeps Mortise's shape in Liquid mode, a list of `name` and
  `posts`, where Jekyll's maps each tag to its posts as `site.categories`
  does; `{% for tag in site.tags %}{{ tag[0] }}` writes nothing.
- A page showing a static file's `modified_time` from `site.static_files`
  is not re-rendered when only that file changes; the next full build
  updates it.
- Not supported from Jekyll:
  `site.html_pages`, `page.id`, the `layout` variable, `jekyll.environment`,
  plugins and their tags (`{% seo %}`, `{% feed_meta %}`; Mortise writes
  feeds and SEO tags itself), and `sassify`/`scssify`.
- A date without a zone is UTC; Jekyll's `timezone:` is not read. `%Z`
  writes `UTC` for a zero offset and nothing for others. Dates Ruby's
  `Time.parse` reads in other forms than those in
  [liquid.md](liquid.md#filters) are passed through by `date` and are an
  error for Jekyll's date filters.
- Numbers are 64-bit: whole numbers that overflow are an error rather than
  growing, and decimals are binary floats rather than Ruby's `BigDecimal`,
  so `"0.1" | times: 3` gives `0.30000000000000004` where Liquid gives `0.3`.
- Errors stop the build with the file and line, as in Jekyll, rather than
  appearing in the page as in Liquid's lax mode: unknown tags and filters,
  comparing a number with a string, dividing by zero, and invalid numbers.
- `include` without `with` does not bind a variable named after the
  template, an old Shopify behavior. `render` can read `site` and `page`.
- Changing case (`upcase`, `capitalize`, `sort_natural`) is ASCII-only.
  `slugify` treats every non-ASCII character as a letter, and its `latin`
  mode knows common accented Latin letters only.
- Objects print as Ruby 3.3 shows them (`{"a"=>1}`).
- `sample` is seeded the same way on every build, so it picks the same
  items each time.

## Link checking

- `mortise check` checks internal links only. External URLs are skipped,
  not fetched.
- Only `href` and `src` attributes are read; `srcset`, CSS `url()` and
  links built by JavaScript are not checked.
- An HTML scanner, not a full parser, finds links: it skips comments and
  the bodies of `<script>` and `<style>`, and decodes only the character
  references Mortise writes (`&amp;`, `&quot;`, `&#39;`, `&lt;`, `&gt;`).
- A link to a directory without a trailing slash (`/docs`) counts as valid
  when `docs/index.html` exists, matching `serve` and most static hosts.

## Search

- The whole index is one file that the browser downloads on first search;
  past a few thousand pages it grows to megabytes. There is no index
  splitting yet.
- Words are split at anything that is not a letter or digit and matched by
  prefix; there is no stemming (`running` does not find `run`), no typo
  tolerance and no phrase search. The stop-word list is English.
- Text in scripts without spaces between words (Chinese, Japanese, Thai)
  is indexed as long runs and only matches from the start of a run.
- Only `h2` and `h3` headings start sections.
- `serve` rebuilds the whole index after every change, which grows the
  rebuild time on large sites with search on.

## Schemas

- A page gets one schema: `posts`, its top directory's, or `pages`;
  schemas do not combine, and nested directories use their top one.
- Rules cover a field's own value: there are no rules for list items, the
  fields of a map, string patterns or lengths, or fields a schema does not
  mention.
- OpenAPI pages (`_api/`) are not checked.

## Accessibility lint

- The lint reads markup only. Color contrast, focus
  order, keyboard traps, and content added by JavaScript are not checked.
- An `aria-labelledby` attribute counts as a name without checking that
  the ids it lists exist.
- Problems cannot be silenced per page or per rule; `check` reports them
  all and exits with status 1.
- Every heading on a page counts toward the skip check, including those in
  layouts and includes.

## Site pipeline

- `gzip: true` writes gzip only (no Brotli or Zstandard), and only in
  `build`; `serve` does not compress responses. Compression uses the
  standard library's deflate at its best level, which is close to but a
  little larger than zlib's `-9` or zopfli.
- Posts must be Markdown files in `_posts/` named `YYYY-MM-DD-slug.md`,
  even when frontmatter sets a `date` that overrides the file name's.
- Frontmatter dates are calendar dates. A time after the date is accepted
  and ignored; there are no time zones.
- Scheduling compares dates with today's date in UTC, so a post dated
  today appears at midnight UTC, not local midnight. `serve` reads the date
  once when it starts; a server left running past midnight publishes the
  next day's posts only after a restart or a full rebuild.
- A static site cannot publish itself: a scheduled post appears only when
  the site is built again on or after its date, for example by a daily CI
  job.
- Only posts are scheduled by date; pages have no date. `expires` works on
  both.
- Markdown content is not run through the template engine, so template tags
  inside a `.md` file appear literally.
- `baseurl` is added to page URLs and to static files linked with the
  `asset` filter (`{{ "css/site.css" | asset }}`). Other links to static
  files in templates must add it themselves, and Markdown links are
  written out exactly as authored.
- The `asset` filter names static files only; generated files such as
  `theme.css`, `mortise.css` or rendered images cannot be fingerprinted.
  Hashes are SHA-256 cut to 8 hex characters.
- `minify: true` is conservative: it removes HTML comments and collapses
  whitespace between tags (keeping `pre`, `textarea`, `script` and `style`
  as they are) and strips CSS comments and spaces. Text in elements that a
  stylesheet sets to `white-space: pre` outside `<pre>` loses its runs of
  spaces. JavaScript and JSON are not minified, and `serve` does not
  minify.
- Taxonomy and term pages are not paginated, and a taxonomy cannot use
  its own layout names; every taxonomy shares `term.html` and
  `taxonomy.html`.
- `page.related` scores pages only by how many tags and terms they share,
  not by their text, and comparing every pair of pages grows with the
  square of the page count.
- Menus are flat lists; a menu item cannot have children. Errors in
  `_data/menus` name the directory, not the file and line.
- `build` deletes the whole `_site` directory before writing, so files
  placed there by hand are lost.
- Layouts are found only as `_layouts/NAME.html`; includes only under
  `_includes/`.
- `build` writes into a hidden `.mortise-staging` directory and swaps it in
  for `_site` only after every file is written, so a failed write leaves
  the previous `_site` intact. The swap is two renames (`_site` to
  `.mortise-old`, then staging to `_site`), so a crash between them leaves no
  `_site` until the next build; `.mortise-old` is then deleted.
- Pages load and files are written on up to 16 threads. Rendering pages
  is still done on one thread.
- Directories starting with `.` (such as `.git`) and the top-level `_site`
  are not read at all, so files in them are invisible to the build.

## Languages

- Default-language pages live at the root; there is no `/en/` prefix for
  the default language, and a file in `en/` (the default's own code) is an
  ordinary page at `/en/...`.
- `site.nav` and other lists order titles by their bytes, so accented
  titles (`À propos`) sort after unaccented ones.
- Dates are formatted in English (`May 12, 2024`) in every language.
- The sitemap does not mark translations with `hreflang` links; templates
  can add `<link rel="alternate" hreflang>` from `page.translations`.
- Pages without a translation fall back to nothing: a language switcher
  should link to `site.languages` home pages when `page.translations` is
  empty.

## Versioned docs

- Every version is built on every build; there is no archive of prebuilt
  old versions.
- A version is a top-level directory. Posts, tags and feeds are not
  versioned, and `site.nav` still lists every version side by side; use
  `page.version_nav` for one version's pages.
- There is no `/latest/` alias for the newest version; link to it by name or
  with `page.latest_url`.
- Version names that look like numbers must be quoted in `versions:`.

## Fonts

- Only fonts with TrueType outlines (`glyf`) are subset; CFF-outline fonts
  (most `.otf` files) and WOFF2 files fail the build when listed.
- Characters come from the text of HTML pages. Text added by scripts, CSS
  `content:`, or attributes such as `title` and `placeholder` is not seen;
  list such characters under `fonts: keep:`. Printable ASCII is always kept.
- Glyph ids are kept, so tables such as `hmtx` and `GPOS` keep their full
  size; a subset is typically a third to a half of the original rather
  than a few kilobytes.
- Variable fonts keep all their variation data.

## Dev server

- `serve` listens on IPv4 loopback (`127.0.0.1`) only. Browsers that resolve
  `localhost` to `::1` first fall back to IPv4, but a client that only tries
  IPv6 cannot connect.
- Native file watching uses inotify on Linux, kqueue on macOS, and
  ReadDirectoryChangesW on Windows. Other systems, or a native backend that
  fails to start, fall back to polling modification times every 100 ms, and
  `serve` prints a warning saying so.
- On macOS, kqueue needs one open file descriptor per watched file and
  directory. `serve` raises its open-file limit to at most 10,240; a larger
  site can exhaust it, which makes the watcher fall back to polling.
- On Linux, each watched directory uses one inotify watch, counted against
  `fs.inotify.max_user_watches`.
- On Windows, a burst of changes that overflows the 64 KiB notification
  buffer is treated as "everything changed".
- Symbolic links inside the site are not followed by any watcher.
- Incremental rebuilds track dependencies per output: the page's own
  source, the layouts and includes it used, and whether any of its
  templates read `site.posts` or `site.pages`. Editing any page or post
  therefore re-renders every page that lists posts or pages, even if the
  edit did not change what that list shows.
- Changes to `_config.yml`, added or removed files, a changed permalink or
  draft flag, and watcher overflows trigger a full rebuild.
- Each incremental build shares memory with the one before it. After 64
  incremental builds in a row the server does one full build to release
  that memory.
- The server keeps every build in memory and never writes `_site`.
- An event stream whose browser tab has closed is only noticed and cleaned
  up at the next rebuild, when writing to it fails.
- The error overlay needs JavaScript and EventSource. Error locations come
  from the pipeline, so some errors (a missing layout, a duplicate output
  path) name a file without a line.
- Debouncing waits for 10 ms without new events after a change (at most
  100 ms) before rebuilding. When the only changes are files the site has
  not read yet, such as an editor's temporary file before it is renamed
  over the original, it waits up to 250 ms in all for more, so a new file
  shows up that much later. A tool that writes one existing file slowly
  over more than 10 ms, or renames a temporary file over 250 ms after
  writing it, can cause more than one rebuild.
- There is no HTTPS, compression, or caching; every response is sent with
  `cache-control: no-store`.
- Open pages reconnect to the event stream 100 ms after losing it, so a
  page notices a restarted server within about that long.

## Restart on rebuild

- `serve --restart-on-rebuild` runs the server from a copy of the binary in
  `.mortise-restart/` beside it, and copies it again on every restart. The
  server notices a new binary by polling its size and modified time every
  25 ms.
- On Windows a running program cannot be replaced, so the supervisor moves
  its own executable and DLLs into `.mortise-restart/` when it starts and
  puts copies back. Those moved files are deleted the next time it starts.
- Incremental linking on Windows can leave the rebuilt binary's modified
  time unchanged, which makes `zig build` skip installing it. `zig build
  dev` therefore copies the binary on every rebuild.
- Zig's own backend is used only on x86_64. Elsewhere `zig build dev` uses
  LLVM, so `-fincremental` is not available there.
- When stdout is redirected to a file, the supervisor and its servers can
  overwrite each other's output in that file. A terminal or a pipe shows
  every line.
- Only the Windows and Linux supervisors have been run; macOS is only
  compiled.
