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
