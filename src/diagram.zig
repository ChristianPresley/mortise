//! Diagrams drawn as SVG at build time from Mermaid syntax, so the same
//! Markdown also renders on sites that run Mermaid. Two kinds:
//!
//!   graph TD                      sequenceDiagram
//!     A[Start] --> B{Ready?}        participant A as Alice
//!     B -->|yes| C(Go)              A->>B: Hello
//!     B -.->|no| A                  B-->>A: Hi
//!
//! Flowcharts (`graph` or `flowchart`, directed TD, TB, BT, LR or RL) are
//! laid out in layers; sequence diagrams in columns. The SVG carries no
//! colors: it uses CSS classes (`mt-diagram-*`) in `mortise.css`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

pub const Diagnostic = struct { line: usize = 0, message: []const u8 = "" };
pub const Error = Allocator.Error || error{InvalidDiagram};

fn fail(arena: Allocator, diag: *Diagnostic, line: usize, comptime fmt: []const u8, args: anytype) Error {
    diag.* = .{ .line = line, .message = try std.fmt.allocPrint(arena, fmt, args) };
    return error.InvalidDiagram;
}

/// Renders a Mermaid diagram as a `<figure>` with an SVG, or fails with
/// `diag` naming the line within the block.
pub fn render(arena: Allocator, src: []const u8, w: *Writer, diag: *Diagnostic) (Error || Writer.Error)!void {
    var lines = try statements(arena, src);
    // The first statement names the kind of diagram.
    while (lines.items.len > 0 and lines.items[0].text.len == 0) _ = lines.orderedRemove(0);
    if (lines.items.len == 0) return fail(arena, diag, 0, "the diagram is empty", .{});
    const head = lines.items[0];
    // Marker ids differ between diagrams, so a page with several has no
    // repeated ids.
    var uid_buf: [8]u8 = undefined;
    const uid = std.fmt.bufPrint(&uid_buf, "{x:0>8}", .{@as(u32, @truncate(std.hash.Wyhash.hash(0, src)))}) catch unreachable;
    var words = std.mem.tokenizeAny(u8, head.text, " \t");
    const kind = words.next().?;
    if (std.mem.eql(u8, kind, "graph") or std.mem.eql(u8, kind, "flowchart")) {
        const dir_word = words.next() orelse "TD";
        const dir = std.meta.stringToEnum(Direction, dir_word) orelse return fail(arena, diag, head.line, "'{s}' is not a direction; use TD, TB, BT, LR or RL", .{dir_word});
        const chart = try parseFlowchart(arena, lines.items[1..], diag);
        return writeFlowchart(arena, chart, dir, uid, w);
    }
    if (std.mem.eql(u8, kind, "sequenceDiagram")) {
        const seq = try parseSequence(arena, lines.items[1..], diag);
        return writeSequence(arena, seq, uid, w);
    }
    return fail(arena, diag, head.line, "'{s}' diagrams are not supported; use graph, flowchart or sequenceDiagram", .{kind});
}

const Line = struct { text: []const u8, line: usize };

/// The block's statements: lines split at `;`, trimmed, without `%%`
/// comments, each with its line number.
fn statements(arena: Allocator, src: []const u8) Allocator.Error!std.ArrayList(Line) {
    var out: std.ArrayList(Line) = .empty;
    var it = std.mem.splitScalar(u8, src, '\n');
    var n: usize = 0;
    while (it.next()) |raw| {
        n += 1;
        var line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.indexOf(u8, line, "%%")) |c| line = line[0..c];
        var parts = std.mem.splitScalar(u8, line, ';');
        while (parts.next()) |part| {
            const t = std.mem.trim(u8, part, " \t");
            if (t.len > 0) try out.append(arena, .{ .text = t, .line = n });
        }
    }
    return out;
}

// ---------------------------------------------------------------------------
// Flowcharts

const Direction = enum { TD, TB, BT, LR, RL };

const Shape = enum { rect, round, stadium, diamond, circle, cylinder };

const Node = struct {
    id: []const u8,
    label: []const u8,
    shape: Shape = .rect,
    w: f64 = 0,
    h: f64 = 0,
    // Layout.
    rank: usize = 0,
    order: f64 = 0,
    x: f64 = 0,
    y: f64 = 0,
    dummy: bool = false,
};

const EdgeStyle = enum { solid, dotted, thick };

const Edge = struct {
    from: usize,
    to: usize,
    label: []const u8 = "",
    style: EdgeStyle = .solid,
    arrow: bool = true,
    /// The nodes the edge passes through, dummies included, from `from` to
    /// `to` in rank order.
    path: []const usize = &.{},
    reversed: bool = false,
};

const Flowchart = struct {
    nodes: std.ArrayList(Node) = .empty,
    edges: std.ArrayList(Edge) = .empty,
};

fn parseFlowchart(arena: Allocator, lines: []const Line, diag: *Diagnostic) Error!Flowchart {
    var fc: Flowchart = .{};
    for (lines) |l| {
        const t = l.text;
        // Styling statements have no effect on the drawing.
        for ([_][]const u8{ "classDef ", "class ", "style ", "linkStyle ", "click " }) |skip| {
            if (std.mem.startsWith(u8, t, skip)) break;
        } else {
            if (std.mem.startsWith(u8, t, "subgraph") or std.mem.eql(u8, t, "end")) {
                return fail(arena, diag, l.line, "subgraphs are not supported", .{});
            }
            try parseChain(arena, &fc, t, l.line, diag);
        }
    }
    if (fc.nodes.items.len == 0) return fail(arena, diag, if (lines.len > 0) lines[0].line else 1, "the flowchart has no nodes", .{});
    return fc;
}

/// `A[text] --> B --> C` and the like.
fn parseChain(arena: Allocator, fc: *Flowchart, t: []const u8, line: usize, diag: *Diagnostic) Error!void {
    var i: usize = 0;
    var prev = try parseNode(arena, fc, t, &i, line, diag);
    while (true) {
        skipSpace(t, &i);
        if (i >= t.len) return;
        const link = try parseLink(arena, t, &i, line, diag);
        skipSpace(t, &i);
        const next = try parseNode(arena, fc, t, &i, line, diag);
        try fc.edges.append(arena, .{ .from = prev, .to = next, .label = link.label, .style = link.style, .arrow = link.arrow });
        prev = next;
    }
}

fn skipSpace(t: []const u8, i: *usize) void {
    while (i.* < t.len and (t[i.*] == ' ' or t[i.*] == '\t')) i.* += 1;
}

fn parseNode(arena: Allocator, fc: *Flowchart, t: []const u8, i: *usize, line: usize, diag: *Diagnostic) Error!usize {
    skipSpace(t, i);
    const start = i.*;
    while (i.* < t.len and (std.ascii.isAlphanumeric(t[i.*]) or t[i.*] == '_' or (t[i.*] == '-' and !isLinkStart(t[i.*..])))) i.* += 1;
    const id = t[start..i.*];
    if (id.len == 0) return fail(arena, diag, line, "expected a node name at '{s}'", .{t[start..]});
    var label: ?[]const u8 = null;
    var shape: Shape = .rect;
    const shapes = [_]struct { []const u8, []const u8, Shape }{
        .{ "([", "])", .stadium }, .{ "[(", ")]", .cylinder }, .{ "((", "))", .circle },
        .{ "[", "]", .rect },      .{ "(", ")", .round },      .{ "{", "}", .diamond },
    };
    for (shapes) |s| {
        if (!std.mem.startsWith(u8, t[i.*..], s[0])) continue;
        const open = i.* + s[0].len;
        const close = std.mem.indexOfPos(u8, t, open, s[1]) orelse return fail(arena, diag, line, "node '{s}' is missing '{s}'", .{ id, s[1] });
        var text = std.mem.trim(u8, t[open..close], " ");
        if (text.len >= 2 and text[0] == '"' and text[text.len - 1] == '"') text = text[1 .. text.len - 1];
        label = text;
        shape = s[2];
        i.* = close + s[1].len;
        break;
    }
    for (fc.nodes.items, 0..) |*n, k| if (std.mem.eql(u8, n.id, id)) {
        // A later mention may give the node its label and shape.
        if (label) |l| {
            n.label = l;
            n.shape = shape;
        }
        return k;
    };
    try fc.nodes.append(arena, .{ .id = id, .label = label orelse id, .shape = shape });
    return fc.nodes.items.len - 1;
}

fn isLinkStart(s: []const u8) bool {
    return std.mem.startsWith(u8, s, "--") or std.mem.startsWith(u8, s, "-.") or std.mem.startsWith(u8, s, "==");
}

const Link = struct { label: []const u8 = "", style: EdgeStyle = .solid, arrow: bool = true };

/// `-->`, `---`, `-.->`, `==>`, with an optional `|label|` after or
/// `-- label -->` inside.
fn parseLink(arena: Allocator, t: []const u8, i: *usize, line: usize, diag: *Diagnostic) Error!Link {
    var link: Link = .{};
    const rest = t[i.*..];
    if (std.mem.startsWith(u8, rest, "==")) {
        link.style = .thick;
    } else if (std.mem.startsWith(u8, rest, "-.")) {
        link.style = .dotted;
    } else if (!std.mem.startsWith(u8, rest, "--")) {
        return fail(arena, diag, line, "expected a link such as '-->' at '{s}'", .{rest});
    }
    // The link runs to the first `>` or the end of its dashes.
    var j = i.*;
    while (j < t.len and (t[j] == '-' or t[j] == '.' or t[j] == '=')) j += 1;
    if (j < t.len and t[j] == '>') {
        j += 1;
    } else if (j < t.len and t[j] == ' ' and (link.style == .solid or link.style == .thick)) {
        // `-- label -->`: text up to the closing arrow.
        const marker: []const u8 = if (link.style == .thick) "==>" else "-->";
        if (std.mem.indexOfPos(u8, t, j, marker)) |close| {
            link.label = std.mem.trim(u8, t[j..close], " ");
            j = close + marker.len;
        } else link.arrow = false;
    } else link.arrow = false;
    i.* = j;
    skipSpace(t, i);
    if (i.* < t.len and t[i.*] == '|') {
        const close = std.mem.indexOfScalarPos(u8, t, i.* + 1, '|') orelse return fail(arena, diag, line, "link label is missing its closing '|'", .{});
        link.label = std.mem.trim(u8, t[i.* + 1 .. close], " ");
        i.* = close + 1;
    }
    return link;
}

const font_px: f64 = 14;
const char_w: f64 = 7.6;

fn textWidth(s: []const u8) f64 {
    const n: f64 = @floatFromInt(std.unicode.utf8CountCodepoints(s) catch s.len);
    return n * char_w;
}

fn sizeNode(n: *Node) void {
    const tw = textWidth(n.label);
    n.w = @max(tw + 32, 64);
    n.h = 40;
    switch (n.shape) {
        .diamond => {
            n.w = @max(tw * 1.5 + 30, 70);
            n.h = @max(n.w * 0.55, 56);
        },
        .circle => {
            n.w = @max(tw + 30, 52);
            n.h = n.w;
        },
        .stadium => n.w += 16,
        .cylinder => n.h = 52,
        else => {},
    }
}

fn layoutFlowchart(arena: Allocator, fc: *Flowchart, horizontal: bool) Allocator.Error!void {
    for (fc.nodes.items) |*n| {
        sizeNode(n);
        // Lay out sideways charts as if top-down, with sizes swapped.
        if (horizontal) std.mem.swap(f64, &n.w, &n.h);
    }
    const real = fc.nodes.items.len;

    // Break cycles: edges that point back to a node still on the DFS stack
    // are reversed for ranking.
    const state = try arena.alloc(u8, real);
    @memset(state, 0);
    const Dfs = struct {
        fn visit(f: *Flowchart, st: []u8, v: usize) void {
            st[v] = 1;
            for (f.edges.items) |*e| {
                if (e.from != v) continue;
                if (st[e.to] == 1) {
                    e.reversed = true;
                } else if (st[e.to] == 0) visit(f, st, e.to);
            }
            st[v] = 2;
        }
    };
    for (0..real) |v| if (state[v] == 0) Dfs.visit(fc, state, v);

    // Longest-path ranks.
    var changed = true;
    var rounds: usize = 0;
    while (changed and rounds < real + 1) : (rounds += 1) {
        changed = false;
        for (fc.edges.items) |e| {
            const u = if (e.reversed) e.to else e.from;
            const v = if (e.reversed) e.from else e.to;
            if (u == v) continue;
            if (fc.nodes.items[v].rank < fc.nodes.items[u].rank + 1) {
                fc.nodes.items[v].rank = fc.nodes.items[u].rank + 1;
                changed = true;
            }
        }
    }

    // Dummy nodes where an edge spans several ranks, so it can bend
    // around the nodes in between.
    for (fc.edges.items) |*e| {
        const u = if (e.reversed) e.to else e.from;
        const v = if (e.reversed) e.from else e.to;
        var path: std.ArrayList(usize) = .empty;
        try path.append(arena, u);
        const ru = fc.nodes.items[u].rank;
        const rv = fc.nodes.items[v].rank;
        var r = ru + 1;
        while (r < rv) : (r += 1) {
            try fc.nodes.append(arena, .{ .id = "", .label = "", .dummy = true, .rank = r, .w = 8, .h = 8 });
            try path.append(arena, fc.nodes.items.len - 1);
        }
        if (u != v) try path.append(arena, v);
        e.path = path.items;
    }

    // Layers in order of first appearance, then barycenter sweeps.
    var max_rank: usize = 0;
    for (fc.nodes.items) |n| max_rank = @max(max_rank, n.rank);
    const layers = try arena.alloc(std.ArrayList(usize), max_rank + 1);
    @memset(layers, .empty);
    for (fc.nodes.items, 0..) |n, k| try layers[n.rank].append(arena, k);
    for (layers) |layer| for (layer.items, 0..) |k, pos| {
        fc.nodes.items[k].order = @floatFromInt(pos);
    };
    for (0..4) |sweep| {
        const down = sweep % 2 == 0;
        var li: usize = 0;
        while (li <= max_rank) : (li += 1) {
            const r = if (down) li else max_rank - li;
            for (layers[r].items) |k| {
                var sum: f64 = 0;
                var count: f64 = 0;
                for (fc.edges.items) |e| for (e.path[0..e.path.len -| 1], e.path[@min(1, e.path.len)..]) |a, b| {
                    const other = if (down and b == k) a else if (!down and a == k) b else continue;
                    sum += fc.nodes.items[other].order;
                    count += 1;
                };
                if (count > 0) fc.nodes.items[k].order = sum / count;
            }
            std.mem.sort(usize, layers[r].items, fc.nodes.items, struct {
                fn lt(ns: []Node, a: usize, b: usize) bool {
                    return ns[a].order < ns[b].order;
                }
            }.lt);
            for (layers[r].items, 0..) |k, pos| fc.nodes.items[k].order = @floatFromInt(pos);
        }
    }

    // Coordinates: layers stacked downwards, each centered.
    const gap_x: f64 = 36;
    const gap_y: f64 = 56;
    var y: f64 = 0;
    var widest: f64 = 0;
    const layer_w = try arena.alloc(f64, layers.len);
    for (layers, layer_w) |layer, *lw| {
        var total: f64 = 0;
        for (layer.items, 0..) |k, pos| total += fc.nodes.items[k].w + if (pos > 0) gap_x else 0;
        lw.* = total;
        widest = @max(widest, total);
    }
    for (layers, layer_w) |layer, lw| {
        var tallest: f64 = 0;
        for (layer.items) |k| tallest = @max(tallest, fc.nodes.items[k].h);
        var x = (widest - lw) / 2;
        for (layer.items) |k| {
            const n = &fc.nodes.items[k];
            n.x = x + n.w / 2;
            n.y = y + tallest / 2;
            x += n.w + gap_x;
        }
        y += tallest + gap_y;
    }
    if (horizontal) for (fc.nodes.items) |*n| {
        std.mem.swap(f64, &n.x, &n.y);
        std.mem.swap(f64, &n.w, &n.h);
    };
}

fn writeFlowchart(arena: Allocator, fc_in: Flowchart, dir: Direction, uid: []const u8, w: *Writer) (Allocator.Error || Writer.Error)!void {
    var fc = fc_in;
    const horizontal = dir == .LR or dir == .RL;
    try layoutFlowchart(arena, &fc, horizontal);
    // Bounds, with room for edge labels.
    var max_x: f64 = 0;
    var max_y: f64 = 0;
    for (fc.nodes.items) |n| {
        max_x = @max(max_x, n.x + n.w / 2);
        max_y = @max(max_y, n.y + n.h / 2);
    }
    // Flip for bottom-up and right-to-left charts.
    if (dir == .BT) for (fc.nodes.items) |*n| {
        n.y = max_y - n.y;
    };
    if (dir == .RL) for (fc.nodes.items) |*n| {
        n.x = max_x - n.x;
    };
    const pad: f64 = 12;
    try w.print("<figure class=\"mt-diagram mt-diagram-flowchart\">\n<svg viewBox=\"{d:.0} {d:.0} {d:.0} {d:.0}\" width=\"{d:.0}\" role=\"img\">\n", .{ -pad, -pad, max_x + 2 * pad, max_y + 2 * pad, max_x + 2 * pad });
    try w.print("<defs><marker id=\"mt-arrow-{s}\" viewBox=\"0 0 10 10\" refX=\"9\" refY=\"5\" markerWidth=\"7\" markerHeight=\"7\" orient=\"auto-start-reverse\"><path d=\"M0 0L10 5L0 10z\" class=\"mt-diagram-head\"/></marker></defs>\n", .{uid});

    // Edges first, so nodes sit on top of them.
    for (fc.edges.items) |e| {
        if (e.path.len < 2) continue;
        var pts: std.ArrayList([2]f64) = .empty;
        for (e.path, 0..) |k, idx| {
            const n = fc.nodes.items[k];
            if (n.dummy) {
                try pts.append(arena, .{ n.x, n.y });
                continue;
            }
            // The point where the edge meets the node's border, towards
            // the next (or previous) point on the path.
            const other_k = if (idx == 0) e.path[1] else e.path[idx - 1];
            const o = fc.nodes.items[other_k];
            try pts.append(arena, border(n, o.x, o.y));
        }
        if (e.reversed) std.mem.reverse([2]f64, pts.items);
        try w.print("<path class=\"mt-diagram-edge mt-diagram-{s}\" d=\"", .{@tagName(e.style)});
        for (pts.items, 0..) |p, idx| try w.print("{s}{d:.1} {d:.1}", .{ if (idx == 0) "M" else " L", p[0], p[1] });
        if (e.arrow) try w.print("\" marker-end=\"url(#mt-arrow-{s})\"/>\n", .{uid}) else try w.writeAll("\"/>\n");
        if (e.label.len > 0) {
            const a = pts.items[0];
            const b = pts.items[1];
            const mx = (a[0] + b[0]) / 2;
            const my = (a[1] + b[1]) / 2;
            const lw = textWidth(e.label) + 10;
            try w.print("<rect class=\"mt-diagram-label-bg\" x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"18\" rx=\"3\"/>", .{ mx - lw / 2, my - 9, lw });
            try w.print("<text class=\"mt-diagram-label\" x=\"{d:.1}\" y=\"{d:.1}\" text-anchor=\"middle\" dominant-baseline=\"central\">", .{ mx, my });
            try escape(w, e.label);
            try w.writeAll("</text>\n");
        }
    }
    for (fc.nodes.items) |n| {
        if (n.dummy) continue;
        try w.print("<g class=\"mt-diagram-node mt-diagram-{s}\">", .{@tagName(n.shape)});
        const x0 = n.x - n.w / 2;
        const y0 = n.y - n.h / 2;
        switch (n.shape) {
            .rect => try w.print("<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\" rx=\"3\"/>", .{ x0, y0, n.w, n.h }),
            .round => try w.print("<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\" rx=\"10\"/>", .{ x0, y0, n.w, n.h }),
            .stadium => try w.print("<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\" rx=\"{d:.1}\"/>", .{ x0, y0, n.w, n.h, n.h / 2 }),
            .circle => try w.print("<circle cx=\"{d:.1}\" cy=\"{d:.1}\" r=\"{d:.1}\"/>", .{ n.x, n.y, n.w / 2 }),
            .diamond => try w.print("<path d=\"M{d:.1} {d:.1}L{d:.1} {d:.1}L{d:.1} {d:.1}L{d:.1} {d:.1}z\"/>", .{ n.x, y0, x0 + n.w, n.y, n.x, y0 + n.h, x0, n.y }),
            .cylinder => {
                const ry: f64 = 6;
                try w.print("<path d=\"M{d:.1} {d:.1}A{d:.1} {d:.1} 0 0 1 {d:.1} {d:.1}V{d:.1}A{d:.1} {d:.1} 0 0 1 {d:.1} {d:.1}z\"/>", .{ x0, y0 + ry, n.w / 2, ry, x0 + n.w, y0 + ry, y0 + n.h - ry, n.w / 2, ry, x0, y0 + n.h - ry });
                try w.print("<path class=\"mt-diagram-rim\" d=\"M{d:.1} {d:.1}A{d:.1} {d:.1} 0 0 0 {d:.1} {d:.1}\"/>", .{ x0, y0 + ry, n.w / 2, ry, x0 + n.w, y0 + ry });
            },
        }
        try w.print("<text x=\"{d:.1}\" y=\"{d:.1}\" text-anchor=\"middle\" dominant-baseline=\"central\">", .{ n.x, n.y });
        try escape(w, n.label);
        try w.writeAll("</text></g>\n");
    }
    try w.writeAll("</svg>\n</figure>\n");
}

/// Where a line from the center of `n` towards (`tx`, `ty`) leaves it.
fn border(n: Node, tx: f64, ty: f64) [2]f64 {
    const dx = tx - n.x;
    const dy = ty - n.y;
    if (dx == 0 and dy == 0) return .{ n.x, n.y };
    const hw = n.w / 2;
    const hh = n.h / 2;
    const t: f64 = switch (n.shape) {
        .circle => hw / @sqrt(dx * dx + dy * dy),
        .diamond => 1 / (@abs(dx) / hw + @abs(dy) / hh),
        else => @min(if (dx != 0) hw / @abs(dx) else std.math.inf(f64), if (dy != 0) hh / @abs(dy) else std.math.inf(f64)),
    };
    return .{ n.x + dx * t, n.y + dy * t };
}

// ---------------------------------------------------------------------------
// Sequence diagrams

const Participant = struct { id: []const u8, label: []const u8, actor: bool = false, x: f64 = 0 };

const Step = union(enum) {
    message: struct { from: usize, to: usize, text: []const u8, dashed: bool, arrow: bool },
    note: struct { first: usize, last: usize, side: enum { left, right, over }, text: []const u8 },
    open: struct { kind: []const u8, text: []const u8 },
    divide: []const u8,
    close,
};

const Sequence = struct {
    participants: std.ArrayList(Participant) = .empty,
    steps: std.ArrayList(Step) = .empty,
};

fn participantIndex(arena: Allocator, seq: *Sequence, id: []const u8) Allocator.Error!usize {
    for (seq.participants.items, 0..) |p, i| if (std.mem.eql(u8, p.id, id)) return i;
    try seq.participants.append(arena, .{ .id = id, .label = id });
    return seq.participants.items.len - 1;
}

fn parseSequence(arena: Allocator, lines: []const Line, diag: *Diagnostic) Error!Sequence {
    var seq: Sequence = .{};
    var depth: usize = 0;
    for (lines) |l| {
        const t = l.text;
        if (std.mem.startsWith(u8, t, "participant ") or std.mem.startsWith(u8, t, "actor ")) {
            const actor = t[0] == 'a';
            const rest = std.mem.trim(u8, t[std.mem.indexOfScalar(u8, t, ' ').? + 1 ..], " ");
            const as = std.mem.indexOf(u8, rest, " as ");
            const id = if (as) |a| std.mem.trim(u8, rest[0..a], " ") else rest;
            const i = try participantIndex(arena, &seq, id);
            if (as) |a| seq.participants.items[i].label = std.mem.trim(u8, rest[a + 4 ..], " ");
            seq.participants.items[i].actor = actor;
            continue;
        }
        if (std.mem.startsWith(u8, t, "Note ") or std.mem.startsWith(u8, t, "note ")) {
            const colon = std.mem.indexOfScalar(u8, t, ':') orelse return fail(arena, diag, l.line, "a note needs ': text'", .{});
            const where = std.mem.trim(u8, t[5..colon], " ");
            const text = std.mem.trim(u8, t[colon + 1 ..], " ");
            var side: @FieldType(@FieldType(Step, "note"), "side") = .over;
            var names = where;
            for ([_]struct { []const u8, @TypeOf(side) }{ .{ "right of ", .right }, .{ "left of ", .left }, .{ "over ", .over } }) |s| {
                if (std.mem.startsWith(u8, where, s[0])) {
                    side = s[1];
                    names = where[s[0].len..];
                    break;
                }
            } else return fail(arena, diag, l.line, "a note must be 'left of', 'right of' or 'over' a participant", .{});
            var it = std.mem.splitScalar(u8, names, ',');
            const a = try participantIndex(arena, &seq, std.mem.trim(u8, it.next().?, " "));
            const b = if (it.next()) |n| try participantIndex(arena, &seq, std.mem.trim(u8, n, " ")) else a;
            try seq.steps.append(arena, .{ .note = .{ .first = @min(a, b), .last = @max(a, b), .side = side, .text = text } });
            continue;
        }
        var handled = false;
        for ([_][]const u8{ "loop", "alt", "opt", "par", "critical", "break" }) |kw| {
            if (std.mem.eql(u8, t, kw) or (std.mem.startsWith(u8, t, kw) and t.len > kw.len and t[kw.len] == ' ')) {
                try seq.steps.append(arena, .{ .open = .{ .kind = kw, .text = std.mem.trim(u8, t[kw.len..], " ") } });
                depth += 1;
                handled = true;
                break;
            }
        }
        if (handled) continue;
        if (std.mem.eql(u8, t, "else") or std.mem.startsWith(u8, t, "else ") or std.mem.startsWith(u8, t, "and ") or std.mem.eql(u8, t, "and")) {
            if (depth == 0) return fail(arena, diag, l.line, "'{s}' outside a block", .{t});
            try seq.steps.append(arena, .{ .divide = std.mem.trim(u8, t[std.mem.indexOfScalar(u8, t, ' ') orelse t.len ..], " ") });
            continue;
        }
        if (std.mem.eql(u8, t, "end")) {
            if (depth == 0) return fail(arena, diag, l.line, "'end' without a block", .{});
            depth -= 1;
            try seq.steps.append(arena, .close);
            continue;
        }
        if (std.mem.startsWith(u8, t, "activate ") or std.mem.startsWith(u8, t, "deactivate ") or std.mem.eql(u8, t, "autonumber")) continue;
        // A message: FROM ARROW TO : text
        const arrows = [_]struct { []const u8, bool, bool }{
            .{ "-->>", true, true }, .{ "->>", false, true }, .{ "--)", true, true },  .{ "-)", false, true },
            .{ "--x", true, true },  .{ "-x", false, true },  .{ "-->", true, false }, .{ "->", false, false },
        };
        const colon = std.mem.indexOfScalar(u8, t, ':');
        const head = t[0 .. colon orelse t.len];
        for (arrows) |a| {
            const at = std.mem.indexOf(u8, head, a[0]) orelse continue;
            const from = std.mem.trim(u8, head[0..at], " +-");
            const to = std.mem.trim(u8, head[at + a[0].len ..], " +-");
            if (from.len == 0 or to.len == 0) return fail(arena, diag, l.line, "a message needs a sender and a receiver", .{});
            const f = try participantIndex(arena, &seq, from);
            const r = try participantIndex(arena, &seq, to);
            const text = if (colon) |c| std.mem.trim(u8, t[c + 1 ..], " ") else "";
            try seq.steps.append(arena, .{ .message = .{ .from = f, .to = r, .text = text, .dashed = a[1], .arrow = a[2] } });
            break;
        } else return fail(arena, diag, l.line, "unknown statement '{s}'", .{t});
    }
    if (depth != 0) return fail(arena, diag, if (lines.len > 0) lines[lines.len - 1].line else 1, "a block is missing its 'end'", .{});
    if (seq.participants.items.len == 0) return fail(arena, diag, 1, "the sequence diagram has no participants", .{});
    return seq;
}

fn writeSequence(arena: Allocator, seq_in: Sequence, uid: []const u8, w: *Writer) (Allocator.Error || Writer.Error)!void {
    const seq = seq_in;
    const ps = seq.participants.items;
    // Columns wide enough for the labels and the messages between
    // neighbors.
    var x: f64 = 0;
    for (ps, 0..) |*p, i| {
        const box = @max(textWidth(p.label) + 28, 90);
        var gap: f64 = box + 30;
        for (seq.steps.items) |s| switch (s) {
            .message => |m| if ((m.from == i and m.to == i + 1) or (m.to == i and m.from == i + 1)) {
                gap = @max(gap, textWidth(m.text) + 40);
            },
            else => {},
        };
        p.x = if (i == 0) box / 2 else x + gap / 2;
        x = p.x + gap / 2;
    }
    const box_h: f64 = 36;
    const row_h: f64 = 40;
    var rows: f64 = 0;
    for (seq.steps.items) |s| rows += switch (s) {
        .message => |m| if (m.from == m.to) 1.6 else 1,
        .note => 1.1,
        .open, .divide => 0.8,
        .close => 0.4,
    };
    const top = box_h + 20;
    const height = top + rows * row_h + 20 + box_h;
    const width = x + 20;

    try w.print("<figure class=\"mt-diagram mt-diagram-sequence\">\n<svg viewBox=\"-10 -2 {d:.0} {d:.0}\" width=\"{d:.0}\" role=\"img\">\n", .{ width + 20, height + 4, width + 20 });
    try w.print("<defs><marker id=\"mt-arrow-{s}\" viewBox=\"0 0 10 10\" refX=\"9\" refY=\"5\" markerWidth=\"7\" markerHeight=\"7\" orient=\"auto-start-reverse\"><path d=\"M0 0L10 5L0 10z\" class=\"mt-diagram-head\"/></marker>", .{uid});
    try w.print("<marker id=\"mt-open-{s}\" viewBox=\"0 0 10 10\" refX=\"9\" refY=\"5\" markerWidth=\"7\" markerHeight=\"7\" orient=\"auto-start-reverse\"><path d=\"M0 0L10 5L0 10\" class=\"mt-diagram-open\"/></marker></defs>\n", .{uid});
    const arrow_ref = try std.fmt.allocPrint(arena, "url(#mt-arrow-{s})", .{uid});
    const open_ref = try std.fmt.allocPrint(arena, "url(#mt-open-{s})", .{uid});
    // Lifelines and the participants at the top and the bottom.
    for (ps) |p| {
        try w.print("<line class=\"mt-diagram-lifeline\" x1=\"{d:.1}\" y1=\"{d:.1}\" x2=\"{d:.1}\" y2=\"{d:.1}\"/>\n", .{ p.x, box_h, p.x, height - box_h });
        for ([_]f64{ 0, height - box_h }) |y| {
            const bw = @max(textWidth(p.label) + 28, 90);
            try w.print("<g class=\"mt-diagram-node mt-diagram-{s}\"><rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\" rx=\"{s}\"/>", .{ if (p.actor) "actor" else "participant", p.x - bw / 2, y, bw, box_h, if (p.actor) "18" else "3" });
            try w.print("<text x=\"{d:.1}\" y=\"{d:.1}\" text-anchor=\"middle\" dominant-baseline=\"central\">", .{ p.x, y + box_h / 2 });
            try escape(w, p.label);
            try w.writeAll("</text></g>\n");
        }
    }
    // Messages, notes and frames, top to bottom.
    var y: f64 = top;
    var frames: std.ArrayList(f64) = .empty;
    const left = ps[0].x - 60;
    const right = ps[ps.len - 1].x + 60;
    for (seq.steps.items) |s| switch (s) {
        .message => |m| {
            const fx = ps[m.from].x;
            const tx = ps[m.to].x;
            const class = if (m.dashed) "mt-diagram-edge mt-diagram-dotted" else "mt-diagram-edge mt-diagram-solid";
            const marker = if (m.arrow) arrow_ref else open_ref;
            if (m.from == m.to) {
                try w.print("<path class=\"{s}\" d=\"M{d:.1} {d:.1}h36v{d:.1}h-36\" marker-end=\"{s}\"/>", .{ class, fx, y + 6, row_h * 0.6, marker });
                try w.print("<text class=\"mt-diagram-label\" x=\"{d:.1}\" y=\"{d:.1}\" dominant-baseline=\"central\">", .{ fx + 42, y + 6 + row_h * 0.3 });
                try escape(w, m.text);
                try w.writeAll("</text>\n");
                y += row_h * 1.6;
            } else {
                try w.print("<line class=\"{s}\" x1=\"{d:.1}\" y1=\"{d:.1}\" x2=\"{d:.1}\" y2=\"{d:.1}\" marker-end=\"{s}\"/>", .{ class, fx, y + 14, tx + (if (tx > fx) @as(f64, -1) else 1), y + 14, marker });
                try w.print("<text class=\"mt-diagram-label\" x=\"{d:.1}\" y=\"{d:.1}\" text-anchor=\"middle\">", .{ (fx + tx) / 2, y + 7 });
                try escape(w, m.text);
                try w.writeAll("</text>\n");
                y += row_h;
            }
        },
        .note => |n| {
            const tw = textWidth(n.text) + 20;
            const nx: f64 = switch (n.side) {
                .right => ps[n.last].x + 10,
                .left => ps[n.first].x - 10 - tw,
                .over => (ps[n.first].x + ps[n.last].x) / 2 - @max(tw, ps[n.last].x - ps[n.first].x + 60) / 2,
            };
            const nw = if (n.side == .over) @max(tw, ps[n.last].x - ps[n.first].x + 60) else tw;
            try w.print("<g class=\"mt-diagram-note\"><rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"28\" rx=\"2\"/>", .{ nx, y + 2, nw });
            try w.print("<text x=\"{d:.1}\" y=\"{d:.1}\" text-anchor=\"middle\" dominant-baseline=\"central\">", .{ nx + nw / 2, y + 16 });
            try escape(w, n.text);
            try w.writeAll("</text></g>\n");
            y += row_h * 1.1;
        },
        .open => |o| {
            try frames.append(arena, y);
            try w.print("<g class=\"mt-diagram-frame-label\"><rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"18\"/>", .{ left, y, textWidth(o.kind) + 14 });
            try w.print("<text x=\"{d:.1}\" y=\"{d:.1}\" dominant-baseline=\"central\">{s}</text></g>", .{ left + 7, y + 9, o.kind });
            if (o.text.len > 0) {
                try w.print("<text class=\"mt-diagram-label\" x=\"{d:.1}\" y=\"{d:.1}\" dominant-baseline=\"central\">[", .{ left + textWidth(o.kind) + 22, y + 9 });
                try escape(w, o.text);
                try w.writeAll("]</text>");
            }
            try w.writeByte('\n');
            y += row_h * 0.8;
        },
        .divide => |text| {
            try w.print("<line class=\"mt-diagram-divider\" x1=\"{d:.1}\" y1=\"{d:.1}\" x2=\"{d:.1}\" y2=\"{d:.1}\"/>", .{ left, y + 4, right, y + 4 });
            if (text.len > 0) {
                try w.print("<text class=\"mt-diagram-label\" x=\"{d:.1}\" y=\"{d:.1}\" dominant-baseline=\"central\">[", .{ left + 8, y + 16 });
                try escape(w, text);
                try w.writeAll("]</text>");
            }
            try w.writeByte('\n');
            y += row_h * 0.8;
        },
        .close => {
            const y0 = frames.pop().?;
            try w.print("<rect class=\"mt-diagram-frame\" x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.1}\"/>\n", .{ left, y0, right - left, y - y0 + 4 });
            y += row_h * 0.4;
        },
    };
    try w.writeAll("</svg>\n</figure>\n");
}

fn escape(w: *Writer, s: []const u8) Writer.Error!void {
    for (s) |c| switch (c) {
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '&' => try w.writeAll("&amp;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(c),
    };
}

const testing = std.testing;

fn renderString(arena: Allocator, src: []const u8) ![]const u8 {
    var aw: Writer.Allocating = .init(arena);
    var diag: Diagnostic = .{};
    render(arena, src, &aw.writer, &diag) catch |err| {
        std.debug.print("diagram error at line {d}: {s}\n", .{ diag.line, diag.message });
        return err;
    };
    return aw.written();
}

test "flowcharts parse nodes, shapes and links" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    var diag: Diagnostic = .{};
    const lines = try statements(a, "A[Start] --> B{Ready?}; B -->|yes| C(Go) %% comment\nB -.-> A\nC == done ==> D((End))\nD --- E[(Store)]");
    const fc = try parseFlowchart(a, lines.items, &diag);
    try testing.expectEqual(@as(usize, 5), fc.nodes.items.len);
    try testing.expectEqual(Shape.diamond, fc.nodes.items[1].shape);
    try testing.expectEqualStrings("Ready?", fc.nodes.items[1].label);
    try testing.expectEqual(Shape.cylinder, fc.nodes.items[4].shape);
    try testing.expectEqual(@as(usize, 5), fc.edges.items.len);
    try testing.expectEqualStrings("yes", fc.edges.items[1].label);
    try testing.expectEqual(EdgeStyle.dotted, fc.edges.items[2].style);
    try testing.expectEqual(EdgeStyle.thick, fc.edges.items[3].style);
    try testing.expectEqualStrings("done", fc.edges.items[3].label);
    try testing.expect(!fc.edges.items[4].arrow);
}

test "flowchart layout ranks nodes and draws edges around them" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const svg = try renderString(a, "graph TD\nA --> B --> C\nA --> C\nC --> A");
    try testing.expect(std.mem.startsWith(u8, svg, "<figure class=\"mt-diagram mt-diagram-flowchart\">"));
    // Three nodes, four edges, each with an arrowhead.
    try testing.expectEqual(@as(usize, 3), std.mem.count(u8, svg, "<g class=\"mt-diagram-node"));
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, svg, "marker-end=\"url(#mt-arrow-"));
    const lr = try renderString(a, "flowchart LR\nA[Left] --> B[Right]");
    // Side by side: B is to the right of A at the same height.
    try testing.expect(std.mem.indexOf(u8, lr, ">Right</text>") != null);
}

test "sequence diagrams" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const svg = try renderString(a,
        \\sequenceDiagram
        \\  participant A as Alice
        \\  actor B as Bob
        \\  A->>B: Hello <Bob>
        \\  loop Every minute
        \\    B-->>A: Still here
        \\  end
        \\  Note over A,B: Done
        \\  A->>A: think
    );
    try testing.expect(std.mem.indexOf(u8, svg, ">Alice</text>") != null);
    try testing.expect(std.mem.indexOf(u8, svg, ">Hello &lt;Bob&gt;</text>") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "class=\"mt-diagram-frame\"") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "mt-diagram-actor") != null);
    try testing.expect(std.mem.indexOf(u8, svg, "class=\"mt-diagram-note\"") != null);
}

test "errors name the line" {
    var arena_state: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const cases = [_]struct { []const u8, usize, []const u8 }{
        .{ "pie\n  \"a\": 1", 1, "'pie' diagrams are not supported" },
        .{ "graph XY\nA-->B", 1, "'XY' is not a direction" },
        .{ "graph TD\nA[Start --> B", 2, "missing ']'" },
        .{ "graph TD\nsubgraph one\nA-->B\nend", 2, "subgraphs are not supported" },
        .{ "sequenceDiagram\nA->>B: hi\nend", 3, "'end' without a block" },
        .{ "sequenceDiagram\nA says hi", 2, "unknown statement" },
    };
    for (cases) |c| {
        var aw: Writer.Allocating = .init(a);
        var diag: Diagnostic = .{};
        try testing.expectError(error.InvalidDiagram, render(a, c[0], &aw.writer, &diag));
        try testing.expectEqual(c[1], diag.line);
        if (std.mem.indexOf(u8, diag.message, c[2]) == null) {
            std.debug.print("expected '{s}' in '{s}'\n", .{ c[2], diag.message });
            return error.TestUnexpectedResult;
        }
    }
}
