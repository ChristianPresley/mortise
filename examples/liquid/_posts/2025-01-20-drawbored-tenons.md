---
title: "Drawbored tenons"
tags: [joinery]
category: joinery
---
Offset the peg hole in the tenon by a millimetre toward the shoulder. The peg
pulls the joint tight as it goes in, and the joint stays tight "without glue".

{% for step in (1..3) %}{{ forloop.index }}. {% cycle "Bore the mortise cheek.", "Mark through, then offset.", "Drive a tapered peg." %}
{% endfor %}
