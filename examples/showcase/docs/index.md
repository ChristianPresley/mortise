---
title: Docs
layout: doc
weight: 1
---
# Markdown reference

## Text

Text can be *emphasized*, **strong**, ***both***, ~~struck~~, or `code`.
A line ending in two spaces  
breaks, and so does one ending in a backslash\
like this.

## Lists

1. First
2. Second
   - nested *bullet*
   - another
3. Third

## Table

| Feature        | Where            | Status |
| :------------- | :--------------: | -----: |
| Tables         | GitHub style     |   done |
| Strikethrough  | `~~text~~`       |   done |
| Highlighting   | fenced code      |   done |

## Code

```zig
const std = @import("std");

pub fn main() !void {
    // Print a greeting.
    std.debug.print("Hello, {s}!\n", .{"Mortise"});
}
```

```json
{ "title": "Home", "url": "/", "draft": false, "weight": 3 }
```

---

Images work too: ![the Mortise logo](/images/logo.svg "Logo")
