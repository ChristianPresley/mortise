# mortise

Mortise is a static site generator written in pure Zig 0.16 with zero
third-party dependencies. Build Markdown and templates into plain HTML, with a
dev server that reloads your browser when you save. A simple alternative to
Jekyll and Hugo.

> **Status:** early development. The I/O and path layer is in place; the
> `build` and `serve` commands are not implemented yet.

## Requirements

- Zig **0.16.0** exactly (pinned in `build.zig.zon` and CI). Get it from
  <https://ziglang.org/download/>.
- Nothing else. Mortise has no third-party dependencies.

## Build and test

```sh
zig build            # builds zig-out/bin/mortise
zig build test       # runs every unit test
zig build run -- help
```

## Usage

```sh
mortise build        # build the site into the output directory
mortise serve        # dev server on localhost with live reload
mortise version
```

## Layout

| Path                 | Contents                                         |
| -------------------- | ------------------------------------------------ |
| `src/path.zig`       | Canonical, portable site paths                   |
| `src/SiteDir.zig`    | Filesystem access by site path through `std.Io` |
| `src/BuildArena.zig` | Arena-per-build allocation policy                |
| `src/markdown.zig`   | Markdown subset to HTML ([spec](docs/markdown.md)) |
| `src/main.zig`       | Command-line entry point                         |
| `docs/`              | Markdown subset spec and known limitations       |
| `test/`              | Fixture tests and their inputs                   |

See [docs/limitations.md](docs/limitations.md) for known limitations.
