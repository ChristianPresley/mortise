# OpenAPI reference pages

Put an OpenAPI 3 document in `_api/NAME.json` and every build turns it into
a page at `/api/NAME/`. The page is plain HTML rendered at build time: no
JavaScript and no request to any API.

The showcase's [`_api/pets.json`](../examples/showcase/_api/pets.json) is
a complete example.

## What the page shows

- The API's title, version, OpenAPI version, description, and servers.
- Operations grouped by their first tag, in the order of the document's
  `tags` list; untagged operations go under "Endpoints".
- Each operation as a card: a header bar with the method pill, the path
  (with `{params}` marked), and a deprecation badge; then the summary,
  description (Markdown), parameters (shared path parameters first), the
  request body's fields, and one row per response with its status, text,
  and type. Request and response examples sit in a dark column beside
  the details on wide screens and below them on narrow ones.
- Each example is the document's `example` if it has one, otherwise one
  made from the schema (first enum value, `example`s of properties, or a
  placeholder per type and format).
- A "Schemas" section with every `components.schemas` entry. Type names
  that are `$ref`s to schemas link to them.
- `page.toc` lists the tags and their operations, with method badges.

`$ref`s to `#/components/...` (schemas, parameters, request bodies,
responses) are followed. `oneOf`, `anyOf`, and `allOf` show as
alternatives (`A | B`) or combinations (`A & B`).

## Layout and styling

The page uses `_layouts/api.html` if the site has one, else
`_layouts/doc.html`, else no layout. Its `page.title` is the API's
`info.title` and `page.description` its description. Styles come from
`mortise.css` (classes start with `mt-api` and `mt-method`), so link it from
the layout as for the other [components](components.md).

## Site-wide API navigation

`site.apis` lists every API page, ordered by URL, so a layout can show all
of them in a sidebar or an overview page:

| Field         | Value                                                      |
| ------------- | ---------------------------------------------------------- |
| `title`       | `info.title`                                               |
| `url`         | The page's URL                                             |
| `version`     | `info.version`, or empty                                   |
| `description` | `info.description` rendered as HTML                        |
| `operations`  | Every operation: `{method, path, summary, tag, url, deprecated}` |
| `tags`        | The same operations grouped: `{name, operations}`          |

An operation's `url` links to its card on the page. `mortise.css` styles
a sidebar (`mt-api-nav`) and overview cards (`mt-api-cards`):

```html
<nav class="mt-api-nav">
{% for api in site.apis %}
<p class="mt-api-nav-api"><a href="{{ api.url }}">{{ api.title }}</a><small>v{{ api.version }}</small></p>
{% for tag in api.tags %}
<p class="mt-api-nav-tag">{{ tag.name }}</p>
{% for op in tag.operations %}
<a class="mt-api-nav-op" href="{{ op.url }}"><span class="mt-method mt-method-{{ op.method }}">{{ op.method }}</span>{{ op.summary }}</a>
{% endfor %}
{% endfor %}
{% endfor %}
</nav>
```

The showcase's `_layouts/api.html` and `api/index.html` use both.

## Errors

Invalid JSON fails the build with the file and line. A document that is not
OpenAPI 3 (`"openapi": "3.x"`) or has no `paths` fails with a message.

## Limitations

- JSON only. YAML specs need converting first, since Mortise's YAML subset
  cannot hold a whole OpenAPI document.
- Only local `$ref`s (`#/...`) are followed; references to other files are
  shown by name.
- Security schemes, callbacks, links, webhooks, and response headers are
  not shown.
- Generated examples use placeholders, not realistic data.
