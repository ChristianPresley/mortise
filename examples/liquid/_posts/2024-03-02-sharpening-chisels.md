---
title: Sharpening chisels
tags: [tools, edges]
category: sharpening
featured: true
---
A chisel is only as good as its edge. I hone at 30 degrees on a 1000 grit
stone, then 6000, then strop on leather loaded with compound.

{% assign grits = "1000,6000,8000" | split: "," %}
The progression: {{ grits | join: " → " }}. That is {{ grits.size }} stones,
and {{ grits | last | divided_by: grits.first }}× finer at the end.
