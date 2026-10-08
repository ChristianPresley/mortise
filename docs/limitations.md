# Known limitations

This list grows with each milestone. Anything Mortise does not handle, or
handles differently from what a user might expect, belongs here.

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

## Templates

- Five built-in filters and no custom filters.
- Conditions support `==`, `!=`, `not`, `and` and `or`, without parentheses
  or ordering comparisons (`<`, `>`).
- Missing variables render as nothing instead of failing, so a typo in a
  variable name produces empty output rather than an error.
- `upper` and `lower` change ASCII letters only.

## Site pipeline

- Posts must be Markdown files in `_posts/` named `YYYY-MM-DD-slug.md`.
  Their URL always uses the date from the file name, even when frontmatter
  sets a different `date`.
- Markdown content is not run through the template engine, so template tags
  inside a `.md` file appear literally.
- There is no `baseurl` setting: sites are assumed to be served from the
  root of their domain.
- `build` deletes the whole `_site` directory before writing, so files
  placed there by hand are lost.
- Layouts are found only as `_layouts/NAME.html`; includes only under
  `_includes/`.
- Nothing is written if the build fails, but a failure while writing can
  leave `_site` partly written.
