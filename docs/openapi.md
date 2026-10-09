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
- For each operation: the method and path (with `{params}` marked), its
  summary and description (Markdown), a deprecation badge, parameters
  (shared path parameters first), the request body, and every response.
- For every request and response body: its media type, its schema as a
  field table, and an example: the document's `example` if it has one,
  otherwise one made from the schema (first enum value, `example`s of
  properties, or a placeholder per type and format).
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
