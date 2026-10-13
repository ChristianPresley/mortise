# Benchmarks

## Save-to-reload latency

`reload_latency.zig` measures how long a save takes to reach a connected
browser as a reload event.

```sh
zig build bench                  # 1000 pages, 30 runs, incremental rebuilds
zig build bench -- 5000 50       # PAGES RUNS
zig build bench -- 1000 30 --full  # rebuild everything on every change
```

It generates a site of N Markdown posts (each with frontmatter, a layout
chain, an include, lists, emphasis, links, and a code block) plus an index
page that lists every post, then starts the dev server and the native file
watcher exactly as `mortise serve` does. A Server-Sent Events client
connects to `/__reload`. For each run the benchmark rewrites one post and
times from the end of the write until the client has read the `reload`
event. That covers the watcher notification, the debounce window, the
rebuild, and event delivery: everything between a save and the browser
starting to reload, except the browser's own page load.

Editing a post is a realistic worst case for incremental rebuilds: the post
changes and so does `site.posts`, so the index page that lists all posts is
re-rendered too.

The benchmark always builds with `-OReleaseFast`.

## Results

Target: under 100 ms for a 1,000-page site. All runs on the development
machine (AMD Ryzen 7 9800X3D), 30 runs each.

| Milestone | Date       | Platform     | Watcher               | Rebuilds    | Pages | Initial build | Median  | p95     | Max     |
| --------- | ---------- | ------------ | --------------------- | ----------- | ----- | ------------- | ------- | ------- | ------- |
| 6         | 2026-10-08 | Linux (WSL2) | inotify               | full        | 1000  | 16.7 ms       | 20.7 ms | 21.7 ms | 23.0 ms |
| 7         | 2026-10-08 | Windows 11   | ReadDirectoryChangesW | full        | 1000  | 40.8 ms       | 53.3 ms | 58.6 ms | 59.5 ms |
| 9         | 2026-10-08 | Linux (WSL2) | inotify               | incremental | 1000  | 16.3 ms       | 10.7 ms | 11.0 ms | 11.0 ms |
| 9         | 2026-10-08 | Linux (WSL2) | inotify               | full        | 1000  | 12.7 ms       | 20.1 ms | 20.8 ms | 24.5 ms |
| 9         | 2026-10-08 | Linux (WSL2) | inotify               | incremental | 5000  | 71.9 ms       | 13.3 ms | 14.2 ms | 14.2 ms |
| 9         | 2026-10-08 | Windows 11   | ReadDirectoryChangesW | incremental | 1000  | 36.7 ms       | 16.2 ms | 17.0 ms | 17.2 ms |
| 9         | 2026-10-08 | Windows 11   | ReadDirectoryChangesW | full        | 1000  | 37.7 ms       | 52.6 ms | 54.4 ms | 54.6 ms |

Notes:

- About 10 ms of every sample is the debounce quiet window, which waits for
  the rest of a save's events before rebuilding. With incremental rebuilds
  that window is most of the latency.
- The Linux numbers were measured under WSL2 on the Linux filesystem (not
  `/mnt/c`).
- Windows full builds are slower than Linux on the same machine because
  each file read and write costs more there.
- macOS (kqueue) is covered by CI tests but has not been benchmarked: there
  is no Mac in the development setup.

## Full builds

`build_time.zig` times complete builds of a large generated site, the way
`mortise build` runs them: read every source, render every page, and write
`_site/`.

```sh
zig build bench-build                # 10,000 posts, 5 runs
zig build bench-build -- 1000 5      # PAGES RUNS
```

Each post has frontmatter with a title and two tags, a few paragraphs with
emphasis and links, a list, a heading and a code block, under a two-layout
chain; the site also has a paginated home page and a page per tag. The
benchmark writes the same site for Hugo (`zig-out/bench-build/hugo`, with
equivalent Go templates) and times `hugo` too when it is on the `PATH`,
each run into an empty `public/` as a fresh checkout builds. Removing
Hugo's old output is not timed; Mortise's write time includes replacing
the previous `_site`.

Pages load in parallel, and output files are written and the previous
`_site` deleted by up to 16 workers. Builds are deterministic: the same
sources give byte-identical output and, when several pages are broken, the
same error, whatever order the threads ran in.

### Results

Development machine (AMD Ryzen 7 9800X3D, 16 threads), median of 5 runs,
2026-10-11. "Build" is reading and rendering; "write" is writing `_site`
and removing the previous one.

| Platform     | Posts  | Outputs | Build  | Write   | Total   | Pages/s |
| ------------ | ------ | ------- | ------ | ------- | ------- | ------- |
| Linux (WSL2) | 1,000  | 1,112   | 17 ms  | 172 ms  | 189 ms  | 5,300   |
| Linux (WSL2) | 10,000 | 11,012  | 175 ms | 1.71 s  | 1.89 s  | 5,300   |
| Windows 11   | 10,000 | 11,012  | 186 ms | 8.84 s  | 9.03 s  | 1,100   |

Before this work the same 10,000-post build took 16 s on Windows (0.8 to
2 s of it building) and about 10 s on Linux with one writer.

Notes:

- Writing files dominates. On Windows each new file costs far more than on
  Linux, mostly in the file system and real-time virus scanning, and
  parallel writing helps much less there.

### Against Hugo

Hugo 0.167.0 (the release binaries for Windows and Linux, checked against
the release's SHA-256 sums), same machine, median of 5 runs, 2026-10-12.
Mortise's times include replacing the previous `_site`; Hugo's start from
an empty `public/`. Hugo writes 10,111 files for the 10,000-post site and
Mortise 11,014.

| Platform     | Posts  | Mortise | Hugo    | Mortise is |
| ------------ | ------ | ------- | ------- | ---------- |
| Linux (WSL2) | 1,000  | 169 ms  | 535 ms  | 3.2× faster |
| Linux (WSL2) | 10,000 | 1.76 s  | 4.83 s  | 2.7× faster |
| Windows 11   | 10,000 | 12.7 s  | 7.3 s   | 1.7× slower |

On Linux, Mortise renders the 10,000 posts in about 0.25 s and writes them
in 1.5 s. On Windows its rendering is the same, but writing takes 12.5 s
(longer than on 2026-10-11, with other programs running). Part of that is
deleting the previous `_site`: removing Hugo's 10,111 output files on the
same machine took 3.4 s, and Mortise does that on every build, where Hugo's
build here did not. Hugo writing into its existing `public/` instead took
6.8 s.

### `build --in-place`

The benchmark also times `mortise build --in-place`, which writes into
`_site` itself and leaves files that already hold the right bytes alone:
first into an empty `_site`, then 5 rebuilds with nothing changed, then
one after a post's title changed. Same machine, 2026-10-12.

| Platform     | Posts  | Staged rebuild | Empty `_site` | Unchanged | One post changed |
| ------------ | ------ | -------------- | ------------- | --------- | ---------------- |
| Linux (WSL2) | 1,000  | 170 ms         | 150 ms        | 41 ms     | 39 ms            |
| Linux (WSL2) | 10,000 | 1.70 s         | 1.52 s        | 389 ms    | 394 ms           |
| Windows 11   | 10,000 | 12.7 s         | 11.2 s        | 1.32 s    | 1.33 s           |

On Windows a rebuild with little changed is about ten times faster this
way, and five times faster than Hugo's build into an empty `public/`.
Profiling showed why: on this machine each new file costs about 0.4 ms,
each new folder 0.25 ms and each deletion 0.9 ms, and more writer threads
do not help, while reading an existing file and comparing it costs about
0.08 ms.
