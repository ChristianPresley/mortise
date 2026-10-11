// Mortise site search. Written to /search.js by `search: true`; loads
// /search-index.json on first use and searches it in the browser.
// Ctrl+K, Cmd+K or "/" opens the dialog; arrows move, Enter opens,
// Escape closes. The index format is described in src/search.zig.
(function () {
  "use strict";
  var me = document.currentScript;
  var indexUrl = me && me.dataset.index;
  var index = null, loading = null, dialog, input, list, active = 0, hits = [];

  var css =
    ".mt-search-button{display:inline-flex;align-items:center;gap:.5rem;padding:.25rem .6rem;border:1px solid var(--m-border,color-mix(in srgb,currentColor 25%,transparent));border-radius:6px;background:transparent;color:inherit;font:inherit;font-size:.85rem;cursor:pointer}" +
    ".mt-search-button kbd{font:600 .7rem ui-monospace,monospace;opacity:.7}" +
    "dialog.mt-search{width:min(40rem,calc(100vw - 2rem));max-height:70vh;margin:12vh auto auto;padding:0;border:1px solid var(--m-border,#ccc);border-radius:10px;background:var(--m-surface,Canvas);color:var(--m-text,CanvasText);box-shadow:0 20px 60px rgba(0,0,0,.35)}" +
    "dialog.mt-search::backdrop{background:rgba(0,0,0,.45)}" +
    ".mt-search input{box-sizing:border-box;width:100%;padding:.9rem 1rem;border:0;border-bottom:1px solid var(--m-border,#ccc);background:transparent;color:inherit;font:inherit;font-size:1.05rem;outline:none}" +
    ".mt-search ul{list-style:none;margin:0;padding:.4rem;max-height:calc(70vh - 4rem);overflow:auto}" +
    ".mt-search li a{display:block;padding:.55rem .7rem;border-radius:6px;color:inherit;text-decoration:none}" +
    ".mt-search li a[aria-selected=true]{background:color-mix(in srgb,var(--m-accent,#2563eb) 18%,transparent)}" +
    ".mt-search .t{display:block;font-weight:600}.mt-search .e{display:block;font-size:.85rem;opacity:.75}" +
    ".mt-search mark{background:color-mix(in srgb,var(--m-accent,#2563eb) 30%,transparent);color:inherit}" +
    ".mt-search .none{padding:.8rem 1rem;opacity:.7}";

  function words(s) {
    return (s.toLowerCase().match(/[a-z0-9\u0080-\uffff]+/g) || []).filter(function (w) {
      return w.length > 1 || /[0-9]/.test(w);
    });
  }

  function load() {
    if (!loading) loading = fetch(indexUrl).then(function (r) { return r.json(); }).then(function (j) {
      var n = 0;
      j.docs.forEach(function (d) { n += d[3]; });
      j.avg = j.docs.length ? n / j.docs.length : 1;
      index = j;
    });
    return loading;
  }

  // The first term at or after `prefix` in the sorted term list.
  function lower(prefix) {
    var lo = 0, hi = index.terms.length;
    while (lo < hi) {
      var mid = (lo + hi) >> 1;
      if (index.terms[mid][0] < prefix) lo = mid + 1; else hi = mid;
    }
    return lo;
  }

  function search(q) {
    var qs = words(q);
    if (!qs.length) return [];
    var N = index.docs.length, scores = null;
    for (var i = 0; i < qs.length; i++) {
      var w = qs[i], s = {};
      for (var t = lower(w); t < index.terms.length && index.terms[t][0].lastIndexOf(w, 0) === 0; t++) {
        var term = index.terms[t], df = (term.length - 1) / 2;
        // Exact words count fully; longer words that start with the query
        // count less the more they add.
        var exact = term[0] === w ? 1 : 0.7 * w.length / term[0].length;
        var idf = Math.log(1 + (N - df + 0.5) / (df + 0.5));
        for (var p = 1; p < term.length; p += 2) {
          var d = term[p], tf = term[p + 1], len = index.docs[d][3];
          var bm = idf * tf * 2.2 / (tf + 1.2 * (0.25 + 0.75 * len / index.avg));
          s[d] = Math.max(s[d] || 0, bm * exact);
        }
      }
      if (scores === null) scores = s;
      else for (var k in scores) scores[k] = k in s ? scores[k] + s[k] : -1;
    }
    var out = [];
    for (var key in scores) if (scores[key] > 0) out.push([+key, scores[key]]);
    out.sort(function (a, b) { return b[1] - a[1]; });
    return out.slice(0, 12).map(function (x) { return index.docs[x[0]]; });
  }

  function esc(s) {
    return s.replace(/[&<>"]/g, function (c) { return { "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]; });
  }

  function highlight(s, qs) {
    var html = esc(s);
    qs.forEach(function (w) {
      html = html.replace(new RegExp("(^|[^a-z0-9])(" + w.replace(/[.*+?^${}()|[\]\\]/g, "\\$&") + "[a-z0-9]*)", "gi"), "$1<mark>$2</mark>");
    });
    return html;
  }

  function render() {
    var q = input.value;
    hits = index ? search(q) : [];
    active = 0;
    var qs = words(q);
    if (!q.trim()) { list.innerHTML = ""; return; }
    if (!hits.length) { list.innerHTML = '<li class="none">No results for \u201c' + esc(q) + "\u201d</li>"; return; }
    list.innerHTML = hits.map(function (d, i) {
      return '<li><a href="' + esc(d[1]) + '" role="option" aria-selected="' + (i === 0) + '"><span class="t">' +
        highlight(d[0], qs) + '</span><span class="e">' + highlight(d[2], qs) + "</span></a></li>";
    }).join("");
  }

  function move(by) {
    var links = list.querySelectorAll("a");
    if (!links.length) return;
    links[active].setAttribute("aria-selected", "false");
    active = (active + by + links.length) % links.length;
    links[active].setAttribute("aria-selected", "true");
    links[active].scrollIntoView({ block: "nearest" });
  }

  function open() {
    if (!dialog) {
      var style = document.createElement("style");
      style.textContent = css;
      document.head.appendChild(style);
      dialog = document.createElement("dialog");
      dialog.className = "mt-search";
      dialog.innerHTML = '<input type="search" placeholder="Search" aria-label="Search" autocomplete="off"><ul role="listbox"></ul>';
      document.body.appendChild(dialog);
      input = dialog.querySelector("input");
      list = dialog.querySelector("ul");
      input.addEventListener("input", function () { load().then(render); });
      input.addEventListener("keydown", function (e) {
        if (e.key === "ArrowDown") { e.preventDefault(); move(1); }
        else if (e.key === "ArrowUp") { e.preventDefault(); move(-1); }
        else if (e.key === "Enter") {
          var a = list.querySelectorAll("a")[active];
          if (a) { e.preventDefault(); location.href = a.href; dialog.close(); }
        }
      });
      dialog.addEventListener("click", function (e) { if (e.target === dialog) dialog.close(); });
    }
    load().then(render);
    dialog.showModal();
    input.select();
  }

  document.addEventListener("keydown", function (e) {
    var typing = /^(INPUT|TEXTAREA|SELECT)$/.test(e.target.tagName) || e.target.isContentEditable;
    if ((e.key === "k" && (e.ctrlKey || e.metaKey)) || (e.key === "/" && !typing)) {
      e.preventDefault();
      open();
    }
  });
  document.querySelectorAll("[data-mt-search]").forEach(function (b) {
    b.hidden = false;
    b.addEventListener("click", open);
  });
})();
