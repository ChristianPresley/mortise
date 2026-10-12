# Liquid

Mortise reads Liquid, the template language of Shopify and Jekyll, so a
Jekyll site's layouts, includes and pages build with few or no changes.
Liquid syntax works in every Mortise template; `liquid: true` in
`_config.yml` also makes Mortise behave as Liquid and Jekyll do where they
differ from Mortise.

```yaml
liquid: true
```

[`examples/liquid`](../examples/liquid) is a small blog written this way.

## What `liquid: true` changes

| | Mortise (default) | `liquid: true` |
| --- | --- | --- |
| Output | HTML-escaped unless marked as HTML | Written as it is; use `escape` where needed |
| False values | `nil`, `false`, `0`, `""`, `[]` | Only `nil` and `false` |
| `a and b or c` | `(a and b) or c` | `a and (b or c)`: Liquid groups from the right |
| Markdown bodies | Plain Markdown | Liquid runs first, then Markdown, as in Jekyll |
| HTML in Markdown | Escaped | Passed through, as kramdown does |
| `{# ... #}` | A comment | Plain text |
| `"a\"b"` | Backslash escapes | No escapes, as in Liquid |
| `serve` | Strict by default | Lax by default; `strict: true` still works |
| `site.time` | Not set | The build's time, `2024-01-05 10:30:00 +0000` |
| Lists in output | An error | Items joined, as Liquid writes them |
| Floats | `2` | `2.0`, `1.0e+20`, as Ruby writes them |

Filters that both define follow Liquid and Jekyll in Liquid mode:
`truncate` counts the ellipsis and does not look for a word boundary,
`date` takes any strftime format and passes through text that is not a
date, `default` keeps `0`, `size` and `slice` count characters,
`strip_html` drops scripts, styles and comments, `sort` and `where`
behave as Jekyll's, and `slugify` takes Jekyll's modes.

## Tags

| Tag | |
| --- | --- |
| `{% if %}`, `{% elsif %}`, `{% else %}` | Mortise's `elif` works too |
| `{% unless %}` | `if` with the condition negated |
| `{% case x %}{% when 1, 2 %}{% when "a" or "b" %}{% else %}{% endcase %}` | |
| `{% for x in list limit: 2 offset: 1 reversed %}` | `offset: continue`, `{% else %}` for an empty list, `{% break %}`, `{% continue %}` |
| `{% for i in (1..n) %}` | Ranges, up to 100,000 numbers |
| `{% tablerow x in list cols: 3 %}` | Table cells, with `tablerowloop` |
| `{% assign x = value \| filter %}` | |
| `{% capture x %}...{% endcapture %}` | |
| `{% increment n %}`, `{% decrement n %}` | Counters separate from `assign` |
| `{% cycle "odd", "even" %}`, `{% cycle "group": ... %}` | |
| `{% raw %}...{% endraw %}` | Text that is not parsed |
| `{% comment %}...{% endcomment %}`, `{% # note %}` | Comments; block comments nest |
| `{% liquid ... %}` | One statement per line; `echo` writes a value |
| `{% echo value \| filter %}` | |
| `{% include 'name' %}` | Shares variables; `with x`, `for list`, `as`, `key: value` |
| `{% render 'name', key: value %}` | Sees only its arguments and `site`/`page` |
| `{% include file.html key=value %}` | Jekyll's: arguments are `include.key`; the name may hold `{{ variables }}` |
| `{% include_relative file.md %}` | Relative to the file holding the tag |
| `{% highlight lang linenos %}` | Jekyll's markup, highlighted where Mortise knows the language |
| `{% link path/to/page.md %}` | The URL of a page, post or file |
| `{% post_url 2024-01-05-title %}` | The URL of a post |

Names without an extension, as `{% render 'card' %}` writes them, are
looked up as `_includes/card`, then `card.liquid`, then `card.html`.

Inside loops, `forloop` has `index`, `index0`, `rindex`, `rindex0`,
`first`, `last`, `length`, `name` and `parentloop`. Mortise's `loop` is the
same object.

## Expressions

- Comparisons: `==`, `!=`, `<>`, `<`, `>`, `<=`, `>=` and `contains`
  (a substring, a list item, or an object key).
- Literals: strings, whole and decimal numbers, `true`, `false`, `nil`,
  `empty` and `blank` (`x == empty`, `x == blank`), and ranges `(1..5)`.
- Lookups: `page.title`, `list[0]`, `list[-1]`, `hash["key"]`,
  `hash[variable]`, and `.size`, `.first` and `.last` on lists.
- Filter arguments: `| truncate: 20, "..."` and options such as
  `| default: "x", allow_false: true`. Mortise's `truncate(20)` also works.

## Filters

All of Liquid's standard filters:

`abs` `append` `at_least` `at_most` `base64_decode` `base64_encode`
`base64_url_safe_decode` `base64_url_safe_encode` `capitalize` `ceil`
`compact` `concat` `date` `default` `divided_by` `downcase` `escape`
`escape_once` `find` `find_index` `first` `floor` `has` `join` `last`
`lstrip` `map` `minus` `modulo` `newline_to_br` `plus` `prepend` `reject`
`remove` `remove_first` `remove_last` `replace` `replace_first`
`replace_last` `reverse` `round` `rstrip` `size` `slice` `sort`
`sort_natural` `split` `strip` `strip_html` `strip_newlines` `sum` `times`
`truncate` `truncatewords` `uniq` `upcase` `url_decode` `url_encode`
`where`

And Jekyll's:

`absolute_url` `array_to_sentence_string` `cgi_escape`
`date_to_long_string` `date_to_rfc822` `date_to_string`
`date_to_xml_schema` `find_exp` `group_by` `group_by_exp` `inspect`
`jsonify` `markdownify` `normalize_whitespace` `number_of_words` `pop`
`push` `relative_url` `sample` `shift` `slugify` `smartify` `to_integer`
`unshift` `uri_escape` `where_exp` `xml_escape`

Mortise's own filters (`asset`, `sri`, `json`, `dump`, `reading_time` and
the rest in [templates.md](templates.md#filters)) work in Liquid templates
too.

Dates may be `2024-01-05`, `2024-01-05 14:30:00 +0100`, ISO 8601 with `T`
and `Z`, `Fri, 05 Jan 2024 14:30:00 GMT`, `Jan 5, 2024`, a Unix timestamp,
or `"now"`/`"today"`. Formats follow Ruby's `strftime`, with its flags
(`%-d`, `%^b`, `%3N`, `%:z`).

## Jekyll sites

Most of a Jekyll site carries over:

- `_layouts/`, `_includes/`, `_posts/`, `_data/` and `{{ content }}`.
- `page.title`, `page.url`, `page.date`, `page.tags`, `page.excerpt`,
  `site.posts`, `site.pages`, `site.data`, `site.time` and your
  `_config.yml` values.
- Liquid in Markdown pages and posts, before Markdown, so `{% link %}`,
  `{% include %}` and `{{ site.baseurl }}` work in posts. Other pages see a
  post's `content` and `excerpt` after its Liquid ran.
- HTML in Markdown pages and posts, and in `markdownify`: blocks such as
  `<figure>` or `<div>`, inline tags such as `<kbd>` and `<abbr>`, and
  references such as `&nbsp;`. See [markdown.md](markdown.md#raw-html).
- Front matter defaults, below.

### Front matter defaults

A `defaults:` list in `_config.yml` gives front matter values to the files
each entry's `scope` matches, as in Jekyll:

```yaml
defaults:
  - scope:
      path: ""          # every file; or a folder such as "notes"
      type: posts       # posts or pages; leave out for both
    values:
      layout: post
      author: Ada
  - scope:
      path: "docs/*/index.md"
    values:
      layout: docs
```

- `path` matches a folder and everything in it, or a single file. With
  `*`, it is a pattern for the whole path, and `*` matches within one
  folder name.
- When several entries match a file, the one with the longer `path` wins,
  then one with a `type` over one without, then the later one. Mappings
  are merged key by key.
- A file's own front matter wins over every default; a mapping in it is
  merged with the defaults' mapping.
- Defaults apply to pages and posts, which have front matter; files copied
  unchanged get none.
- Values may nest as deeply as YAML allows, and `null` sets nothing.
  `defaults:` is read with Mortise's full YAML reader; the rest of
  `_config.yml` keeps to the [frontmatter subset](frontmatter.md).

`defaults:` needs `liquid: true`. Mortise sites give fields defaults with
`default:` rules in [`_schemas/`](frontmatter.md) files instead.

Mortise's page URLs already include `baseurl`, so `relative_url` leaves a
URL that starts with it alone, and `{{ site.baseurl }}{{ page.url }}`
writes it twice; use `{{ page.url }}` or `{{ page.url | relative_url }}`.

What differs is listed in [limitations.md](limitations.md#liquid).
