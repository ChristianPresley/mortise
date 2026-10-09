---
title: Components
layout: doc
---
# Components

Mortise turns a few extra Markdown forms into styled components. Their
styles come from `mortise.css`, which the build writes whenever a page
uses one. Version :badge[new] · press :kbd[Ctrl] + :kbd[S] to save and watch
this page reload.

## Callouts

> [!NOTE]
> Callouts use GitHub's alert syntax, so they read well there too.

> [!TIP]
> Run `mortise serve` and edit this file to see changes in moments.

> [!IMPORTANT]
> Every component is plain HTML and CSS. No JavaScript is added.

> [!WARNING]
> `build` replaces `_site` on every run.

> [!CAUTION]
> Pages marked `draft: true` are only published with `--drafts`.

## Cards in a grid

::::grid
:::card Fast
Incremental rebuilds re-render only the pages a change affects.
:::
:::card Portable
One binary for Linux, macOS, and Windows, with native file watching.
:::
:::card Dependency-free
Everything is written in Zig on top of the standard library.
:::
::::

:::card A single card
Cards can hold any Markdown: **bold text**, `code`, and lists.

- one
- two
:::

## Buttons

:::actions
[Get started](/docs/) [Browse tags](/tags/) [Read the feed](/feed.xml)
:::

## Steps

:::steps
1. Create a site with `mortise new my-site`.
2. Run `mortise serve my-site` and open the printed address.
3. Edit Markdown in `my-site/` and watch the browser reload.
:::

## Details

:::details What does "Mortise" mean?
A mortise is a hole cut into wood to receive a tenon. Here, Markdown is
the tenon and your templates are the mortise.
:::

:::details Can I nest components?
Yes. Give the outer container more colons than the inner ones, as the
grid above does with `::::grid`.
:::

## Figure

:::figure The Mortise logo, as an SVG image with a caption.
![Mortise logo](/images/logo.svg)
:::
