# Frontmatter

A content file may start with frontmatter: a block of settings between two
`---` lines. Mortise reads a restricted subset of YAML. Anything outside the
subset stops the build with an error naming the file and line.

```yaml
---
title: Hello, world
date: 2024-01-05
draft: false
weight: 3
tags: [zig, static sites]
author:
  name: Ada
  links:
    - https://example.com
---
The page body starts here.
```

## What is supported

| Construct     | Example                              | Notes                                      |
| ------------- | ------------------------------------ | ------------------------------------------ |
| Keys          | `title:`                             | Letters, digits, `_` and `-` only          |
| Plain strings | `title: Hello, world`                | May not contain `: ` or start with `{ & * ! \| > % @ `` ` ``` |
| Quoted        | `"a \"b\""`, `'it''s'`               | Double quotes allow `\" \\ \/ \n \t`       |
| Integers      | `42`, `-7`                           | 64-bit signed                              |
| Floats        | `1.5`                                | Digits on both sides of the dot            |
| Booleans      | `true`, `false`                      | `yes`/`no`/`on`/`off` are plain strings    |
| Flow lists    | `[a, "b c", 3]`                      | Items are scalars                          |
| Block lists   | `- item` lines indented under a key  | Items are scalars                          |
| Nested map    | `key:` then indented `k: v` lines    | One level; values are scalars or lists     |
| Comments      | `# note` on its own line or after ` ` | Inside quotes, `#` is text                |

Dates are strings. The site pipeline interprets the `date` key.

## What is rejected

- Tabs in indentation, indented top-level keys, and inconsistent
  indentation.
- Duplicate keys.
- A key with no value (`key:` with nothing under it). Use `""`.
- `null` and `~`. Leave the key out instead.
- Anchors (`&`), aliases (`*`), tags (`!`), and block scalars (`|`, `>`).
- Flow mappings (`{a: 1}`), mappings inside lists, lists inside lists, and
  nesting deeper than one level.
- A missing closing `---`.

Errors look like:

```
content/posts/hello.md:4: duplicate key 'title'
```
