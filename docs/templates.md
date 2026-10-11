# Templates

Mortise templates are HTML files with three kinds of tags:

| Tag            | Purpose                         |
| -------------- | ------------------------------- |
| `{{ ... }}`    | Output a value                  |
| `{% ... %}`    | Statements: `if`, `for`, `include` |
| `{# ... #}`    | Comments, removed from output   |

Layouts live in `_layouts/` and includes in `_includes/`.

## Output

```html
<h1>{{ page.title }}</h1>
{{ content }}
```

- Values are looked up by dotted path: `page.title`, `site.title`,
  `post.url`. A missing variable or field renders as nothing.
- Output is **HTML-escaped by default**: `&`, `<`, `>` and `"` are escaped.
- Values the site marks as HTML (the rendered page body in `content`) are
  written as-is.
- Numbers and booleans print as written (`3`, `1.5`, `true`). Outputting a
  list or an object is an error; loop over it or pick a field.
- Literals: `"double"` or `'single'` quoted strings, integers, `true`,
  `false`.

## Filters

Filters follow a `|` and run left to right: `{{ page.title | upper | raw }}`.
Arguments go in parentheses, separated by commas: `truncate(80, "...")`.
Filters also work on a loop's list:
`{% for post in site.posts | where("tags", "zig") | limit(5) %}`.
The filters are built in; there is no way to add more.

Text:

| Filter                | Effect                                                         |
| --------------------- | -------------------------------------------------------------- |
| `raw`                 | Mark a string as HTML so it is not escaped                     |
| `upper`, `lower`      | ASCII uppercase or lowercase                                   |
| `default("x")`        | Use `"x"` when the value is missing, `false`, `0`, empty       |
| `date`                | Format `YYYY-MM-DD` (time part ignored) as `January 5, 2024`   |
| `date("%Y-%m")`       | Format with `%Y` year, `%m` month (`01`), `%d` day (`05`), `%e` day (`5`), `%B` month name, `%b` short month name, `%%` |
| `slugify`             | `Hello, World!` → `hello-world`                                |
| `truncate(n)`         | At most `n` characters, cut at a word when one is near, then `…`; `truncate(n, "...")` picks the ending. HTML is stripped first |
| `strip_html`          | Remove tags, keeping the text                                  |
| `markdownify`         | Render a Markdown string to HTML                               |
| `word_count`          | Words in the text (HTML tags ignored)                          |
| `reading_time`        | Minutes to read at 200 words a minute, at least 1              |

Lists:

| Filter                     | Effect                                                    |
| -------------------------- | --------------------------------------------------------- |
| `where("key")`             | Items whose `key` is true (not missing, empty, `false`, `0`) |
| `where("key", value)`      | Items whose `key` equals `value`, or contains it when `key` is a list such as `tags` |
| `sort`, `sort("key")`      | Sort values, or objects by a field: numbers by value, strings by bytes, missing last |
| `group_by("key")`          | A list of `{ name, items }` groups, in the order first seen |
| `group_by("date", "%Y")`   | Group by a date formatted as in `date(...)`, such as by year |
| `limit(n)`                 | The first `n` items                                       |
| `reverse`                  | Reverse the list                                          |
| `first`, `last`            | One item                                                  |
| `join`, `join(", ")`       | Items as one string, separated by a space or the argument |
| `size`                     | Items in a list, fields in an object, or bytes in a string |

`key` may be a dotted path such as `"author.name"`.

Debugging and data:

| Filter  | Effect                                                                   |
| ------- | ------------------------------------------------------------------------ |
| `json`  | The value as compact JSON, with `<`, `>` and `&` escaped as `<` and so on, so it is safe inside `<script>`. Not for HTML attributes |
| `dump`  | The value as indented JSON in `<pre class="mortise-dump">`, to see what a template can read: `{{ page | dump }}` |

```html
{% for year in site.posts | group_by("date", "%Y") %}
<h2>{{ year.name }}</h2>
{% for post in year.items %}
<p><a href="{{ post.url }}">{{ post.title }}</a> · {{ post.content | reading_time }} min</p>
{% endfor %}
{% endfor %}
```

## Strict mode

In strict mode an undefined variable is an error instead of empty output,
so a typo such as `{{ page.titel }}` stops the build with its file and line:

```
_layouts/post.html:7: 'page.titel' is not defined (strict mode); guard it with {% if page.titel %} or add | default("")
```

- An output tag fails when its value is undefined, unless a `default`
  filter follows. Fields that only some pages set are written
  `{% if page.subtitle %}{{ page.subtitle }}{% endif %}` or
  `{{ page.subtitle | default("") }}`.
- A loop fails when its first name is unknown (`site` misspelled), but a
  loop over a missing field such as `page.tags` renders nothing.
- Conditions never fail.

`mortise serve` is strict by default, so mistakes show in the browser's
error overlay as you type; `mortise build` is not. Set `strict: true` or
`strict: false` in `_config.yml` to choose for both, or pass `--strict` or
`--no-strict` to one command. `site.baseurl` is always defined (as `""`
when unset).

## Conditionals

```html
{% if page.draft %}
  <p>Draft</p>
{% elif page.tags and page.layout != "home" %}
  ...
{% else %}
  ...
{% endif %}
```

- A value is false when it is missing, `false`, `0`, an empty string, or an
  empty list. Everything else is true.
- Comparisons: `==` and `!=`. Strings compare by content; integers and
  floats compare numerically.
- `not` negates one comparison. `and` binds tighter than `or`. There are no
  parentheses.

## Loops

```html
<ul>
{% for post in site.posts %}
  <li{% if loop.first %} class="first"{% endif %}>
    {{ loop.index }}. <a href="{{ post.url }}">{{ post.title }}</a>
  </li>
{% endfor %}
</ul>
```

- `loop.index` (from 1), `loop.index0` (from 0), `loop.first`, and
  `loop.last` are available inside the loop.
- Looping over a missing value renders nothing. Looping over anything other
  than a list is an error.
- List filters apply before looping: `{% for p in site.pages | sort("title") %}`.

## Pagination

A page whose frontmatter sets `paginate: N` is rendered once for every N
posts: page 1 at its own URL and page k at `<url>page/k/`, such as
`/page/2/`. Its URL must end in `/`. Each copy sees a `paginator`:

| Variable                 | Value                                       |
| ------------------------ | ------------------------------------------- |
| `paginator.posts`        | This page's posts, newest first             |
| `paginator.page`         | This page's number, from 1                  |
| `paginator.per_page`     | N                                           |
| `paginator.total_pages`  | Number of pages (at least 1)                |
| `paginator.total_posts`  | Number of posts                             |
| `paginator.previous_url` | URL of the previous page, or empty          |
| `paginator.next_url`     | URL of the next page, or empty              |

```html
---
paginate: 10
layout: base
---
{% for post in paginator.posts %}<a href="{{ post.url }}">{{ post.title }}</a>{% endfor %}
{% if paginator.next_url %}<a href="{{ paginator.next_url }}">Older</a>{% endif %}
```

## Navigation

Every page and post gets navigation variables, so layouts can build
wiki-style sidebars, breadcrumbs, and pagers:

| Variable           | Value                                                          |
| ------------------ | -------------------------------------------------------------- |
| `page.breadcrumbs` | Ancestor pages by URL, root first, each `{title, url}`         |
| `page.previous`    | Previous page in the same URL directory, or the older post     |
| `page.next`        | Next page in the same URL directory, or the newer post         |
| `site.nav`         | Every non-post page as a tree: `{title, url, children}`        |
| `site.apis`        | Every [OpenAPI page](openapi.md#site-wide-api-navigation)      |

Pages are ordered by a `weight` number in their frontmatter (lower first),
then by title. `nav: false` leaves a page out of `site.nav` and out of
previous/next; the home page is never in `site.nav`. A page's navigation
title is its `title`, else the last part of its URL.

```html
{% for item in site.nav %}
<a href="{{ item.url }}">{{ item.title }}</a>
{% for child in item.children %}<a href="{{ child.url }}">{{ child.title }}</a>{% endfor %}
{% endfor %}

{% for crumb in page.breadcrumbs %}<a href="{{ crumb.url }}">{{ crumb.title }}</a> › {% endfor %}{{ page.title }}

{% if page.next %}<a href="{{ page.next.url }}">Next: {{ page.next.title }}</a>{% endif %}
```

Templates cannot recurse, so a sidebar shows as many levels as its layout
loops over.

## Includes

```html
{% include "nav.html" %}
```

Includes are loaded from `_includes/` and see the same variables as the
template that includes them, including loop variables. Includes may nest up
to 32 levels deep.

## Whitespace control

A `-` just inside a tag delimiter removes all whitespace, including newlines,
on that side of the tag: `{%- for x in xs -%}`, `{{- value }}`.

## Errors

Syntax errors (an unclosed tag, an `if` without `endif`, an unknown filter)
and render errors (outputting a list, a missing include) stop the build and
name the template and line:

```
_layouts/post.html:12: unknown filter 'shout'; the built-in filters are raw, upper, lower, default, date, slugify, ...
```
