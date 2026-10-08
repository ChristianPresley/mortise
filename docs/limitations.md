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
