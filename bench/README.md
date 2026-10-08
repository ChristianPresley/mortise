# Benchmarks

## Save-to-reload latency

`reload_latency.zig` measures how long a save takes to reach a connected
browser as a reload event.

```sh
zig build bench                  # 1000 pages, 30 runs
zig build bench -- 5000 50       # PAGES RUNS
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

The benchmark always builds with `-OReleaseFast`.

## Results

Target: under 100 ms for a 1,000-page site.

| Milestone | Date       | Platform                         | Watcher  | Pages | Full build | Median  | p95     | Max     |
| --------- | ---------- | -------------------------------- | -------- | ----- | ---------- | ------- | ------- | ------- |
| 6         | 2026-10-08 | Linux (WSL2), Ryzen 7 9800X3D     | inotify  | 1000  | 16.7 ms    | 20.7 ms | 21.7 ms | 23.0 ms |
| 7         | 2026-10-08 | Windows 11, Ryzen 7 9800X3D       | ReadDirectoryChangesW | 1000 | 40.8 ms | 53.3 ms | 58.6 ms | 59.5 ms |

Notes:

- Milestones 6 and 7 rebuild the whole site on every change. About 10 ms of each
  sample is the debounce quiet window, which waits for the rest of a save's
  events before rebuilding.
- The Linux numbers were measured under WSL2 on the development machine, on
  the Linux filesystem (not `/mnt/c`).
- Windows full builds are slower than Linux on the same machine because
  each file read and write costs more there; the rebuild dominates the
  Windows numbers.
- macOS (kqueue) is covered by CI tests but has not been benchmarked: there
  is no Mac in the development setup.
