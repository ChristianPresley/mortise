---
title: Data files drive the navigation
layout: post
tags: [templates]
categories: [guides]
---
The links at the top of every page come from the `main` menu:
`_data/menus/main.json` lists most of them, and the About page joins with
`menu: [main, footer]` in its frontmatter. The header include loops over
`page.menus.main`, whose `active` and `in_section` flags mark the current
section.
