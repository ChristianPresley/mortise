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
There are five built-ins and no way to add more.

| Filter         | Effect                                                      |
| -------------- | ----------------------------------------------------------- |
| `raw`          | Mark a string as HTML so it is not escaped                  |
| `upper`        | ASCII uppercase                                              |
| `lower`        | ASCII lowercase                                              |
| `default("x")` | Use `"x"` when the value is missing, `false`, `0`, empty    |
| `date`         | Format `YYYY-MM-DD` (time part ignored) as `January 5, 2024` |

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
_layouts/post.html:12: unknown filter 'shout'; the built-in filters are raw, upper, lower, default, date
```
