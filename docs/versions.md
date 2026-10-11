# Versioned documentation

Documentation for several releases can live side by side. Put each
version in a directory and list the directories in `_config.yml`, newest
first:

```yaml
versions: [v2, v1]        # numbers need quotes: ['2.0', '1.0']
```

```
v2/index.md        /v2/          the newest version
v2/install.md      /v2/install/
v2/plugins.md      /v2/plugins/
v1/index.md        /v1/
v1/install.md      /v1/install/
about.md           /about/       not in any version
```

Each version's pages are ordinary pages; a version is just the directory
they are in. Pages with the same path in two versions are the same page
in each.

## In templates

Pages inside a version directory get:

| Variable           | Value                                                          |
| ------------------ | -------------------------------------------------------------- |
| `page.version`     | The version's name, such as `v1`                               |
| `page.versions`    | The page in every version, newest first, each `{name, url, current, latest}`. A version without the page links to that version's home page. |
| `page.latest_url`  | This page in the newest version, or the newest version's home  |
| `page.outdated`    | Whether the page belongs to an older version                   |
| `page.version_nav` | `site.nav` for the page's version only: `{title, url, children}` |

and every page sees `site.versions`, each `{name, url, latest}`.

```html
{% if page.outdated %}
<p>You are reading the docs for {{ page.version }}.
<a href="{{ page.latest_url }}">See this page for the latest version.</a></p>
{% endif %}

<nav>{% for v in page.versions %}<a href="{{ v.url }}"{% if v.current %} class="current"{% endif %}>{{ v.name }}</a>{% endfor %}</nav>

<ul>{% for item in page.version_nav %}<li><a href="{{ item.url }}">{{ item.title }}</a></li>{% endfor %}</ul>
```

[`examples/versioned/`](../examples/versioned) shows a version switcher,
an outdated-version notice, and a sidebar for each version.
