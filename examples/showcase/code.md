---
title: Code
layout: doc
weight: 3
---
# Code blocks

Fenced code takes options after the language: a `title`, line ranges to
mark in braces, and `lineNumbers`.

## Title, marked lines, and line numbers

```zig title="src/main.zig" {4-5} lineNumbers
const std = @import("std");

pub fn main() !void {
    const name = "Mortise";
    std.debug.print("Hello, {s}!\n", .{name});
}
```

## A file name only

```json title="_data/nav.json"
[{ "title": "Home", "url": "/" }]
```

## Diffs

```diff title="_config.yml"
@@ settings @@
 title: Mortise Showcase
-description: A plain site
+description: Every Mortise feature on one small site
+url: https://example.com
```

## Code groups

One example in several forms, as tabs. No JavaScript: the tabs are radio
buttons styled with CSS.

:::code-group
```sh title="Linux and macOS"
zig build -Doptimize=ReleaseFast
./zig-out/bin/mortise serve my-site
```

```sh title="Windows"
zig build -Doptimize=ReleaseFast
zig-out\bin\mortise.exe serve my-site
```

```zig title="build.zig"
const exe = b.addExecutable(.{ .name = "mortise", .root_module = mod });
```
:::

## Tabs

Tabs hold any Markdown.

::::tabs
:::tab Overview
Mortise builds **Markdown** and templates into plain HTML.
:::
:::tab Install
1. Install Zig 0.16.0.
2. Run `zig build`.
:::
:::tab Status
> [!TIP]
> Every feature here was checked in a browser.
:::
::::
