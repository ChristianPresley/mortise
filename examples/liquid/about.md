---
layout: page
title: About
---
{% assign first = site.posts | last %}
These notes started on {{ first.date | date_to_long_string: "ordinal" }} with
[{{ first.title }}]({% post_url 2024-03-02-sharpening-chisels %}). There are
{{ site.posts.size }} so far; the [tags page]({% link tags.html %}) sorts them.

{% case site.posts.size %}
{% when 0 %}Nothing yet.
{% when 1, 2 %}A small start.
{% else %}Enough to browse.
{% endcase %}

## How this site is built

Every page is Liquid, the way Jekyll writes it: `assign`, `capture`, `case`,
`tablerow`, `forloop`, Jekyll's `include` with arguments, `{% raw %}{% link %}{% endraw %}`
and `{% raw %}{% post_url %}{% endraw %}`, and filters such as `where`,
`group_by_exp` and `date_to_long_string`. The workshop's cut list is computed
by a template:

{% highlight python linenos %}
cuts = [{% for i in (1..4) %}{{ i | times: 600 }}{% unless forloop.last %}, {% endunless %}{% endfor %}]  # mm
for n, length in enumerate(cuts, 1):
    print(f"board {n}: {length} mm")
{% endhighlight %}

{% capture boards %}{% for i in (1..4) %}{{ i | times: 600 }}{% unless forloop.last %}, {% endunless %}{% endfor %}{% endcapture -%}
Boards cut at {{ boards }} mm make {{ boards | split: ", " | size }} lengths.
