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
- **The CI bootstrap step.** CI has to download Zig before any Zig code can
  run, so one workflow step uses the runner's shell (`curl`, a checksum
  check, and `tar` or `unzip`). Every other check (the exact Zig version,
  the empty dependency table) is enforced by `build.zig`.

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
  paths, but they collide on the default case-insensitive filesystems of
  Windows and macOS. Mortise does not detect the collision yet.
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
  posts.

## Templates

- Five built-in filters and no custom filters.
- Conditions support `==`, `!=`, `not`, `and` and `or`, without parentheses
  or ordering comparisons (`<`, `>`).
- Missing variables render as nothing instead of failing, so a typo in a
  variable name produces empty output rather than an error.
- `upper` and `lower` change ASCII letters only.

## Site pipeline

- Posts must be Markdown files in `_posts/` named `YYYY-MM-DD-slug.md`,
  even when frontmatter sets a `date` that overrides the file name's.
- Frontmatter dates are calendar dates. A time after the date is accepted
  and ignored; there are no time zones.
- Markdown content is not run through the template engine, so template tags
  inside a `.md` file appear literally.
- `baseurl` is added to page URLs only. Links to static files in templates
  must add it themselves, as in `{{ site.baseurl }}/css/site.css`, and
  Markdown links are written out exactly as authored.
- `build` deletes the whole `_site` directory before writing, so files
  placed there by hand are lost.
- Layouts are found only as `_layouts/NAME.html`; includes only under
  `_includes/`.
- Nothing is written if the build fails, but a failure while writing can
  leave `_site` partly written.

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
  100 ms) before rebuilding. A tool that writes one file slowly over more
  than 10 ms can cause more than one rebuild.
- There is no HTTPS, compression, or caching; every response is sent with
  `cache-control: no-store`.
