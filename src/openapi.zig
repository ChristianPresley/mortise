//! OpenAPI 3 reference pages, rendered at build time.
//!
//! Each `_api/NAME.json` OpenAPI 3.x document becomes a page at
//! `/api/NAME/` listing every operation grouped by tag: method and path,
//! summary and description, parameters, request body, responses, and an
//! example JSON body for each, plus the component schemas. `$ref`s to
//! `#/components/...` are followed and linked. The output is static HTML
//! with `mt-api` classes styled by mortise.css; there is no JavaScript.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;
const JsonValue = std.json.Value;
const markdown = @import("markdown.zig");
const highlight = @import("highlight.zig");
const escapeHtml = markdown.escapeHtml;

pub const dir_prefix = "_api/";

pub fn isSpec(path: []const u8) bool {
    return std.mem.startsWith(u8, path, dir_prefix) and std.mem.endsWith(u8, path, ".json") and
        std.mem.indexOfScalarPos(u8, path, dir_prefix.len, '/') == null;
}

pub const Diagnostic = struct { line: usize = 0, message: []const u8 = "" };
pub const Error = error{InvalidSpec} || Allocator.Error;

pub const Rendered = struct {
    title: []const u8,
    description: []const u8,
    /// The reference body.
    html: []const u8,
    /// A table of contents: tags and their operations.
    toc: []const u8,
};

const methods = [_][]const u8{ "get", "put", "post", "delete", "options", "head", "patch", "trace" };

const Op = struct {
    method: []const u8,
    path: []const u8,
    op: std.json.ObjectMap,
    /// Parameters shared by every operation on the path.
    path_params: ?[]const JsonValue,
    id: []const u8,
};

const Ctx = struct {
    arena: Allocator,
    root: std.json.ObjectMap,
    ids: std.StringHashMapUnmanaged(void) = .empty,

    fn uniqueId(c: *Ctx, base: []const u8) Allocator.Error![]const u8 {
        var id = base;
        var n: usize = 1;
        while (c.ids.contains(id)) : (n += 1) id = try std.fmt.allocPrint(c.arena, "{s}-{d}", .{ base, n });
        try c.ids.put(c.arena, id, {});
        return id;
    }

    /// Follows a local `$ref` (one level at a time, up to 16 deep).
    fn deref(c: *Ctx, v: JsonValue) JsonValue {
        var cur = v;
        var depth: usize = 0;
        while (depth < 16) : (depth += 1) {
            const ref = refOf(cur) orelse return cur;
            cur = c.lookup(ref) orelse return cur;
        }
        return cur;
    }

    fn lookup(c: *Ctx, ref: []const u8) ?JsonValue {
        if (!std.mem.startsWith(u8, ref, "#/")) return null;
        var cur: JsonValue = .{ .object = c.root };
        var it = std.mem.splitScalar(u8, ref[2..], '/');
        while (it.next()) |seg| {
            if (cur != .object) return null;
            cur = cur.object.get(seg) orelse return null;
        }
        return cur;
    }
};

fn refOf(v: JsonValue) ?[]const u8 {
    if (v != .object) return null;
    const r = v.object.get("$ref") orelse return null;
    return if (r == .string) r.string else null;
}

fn str(o: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = o.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn obj(o: std.json.ObjectMap, key: []const u8) ?std.json.ObjectMap {
    const v = o.get(key) orelse return null;
    return if (v == .object) v.object else null;
}

fn arr(o: std.json.ObjectMap, key: []const u8) ?[]const JsonValue {
    const v = o.get(key) orelse return null;
    return if (v == .array) v.array.items else null;
}

/// Parses and renders an OpenAPI 3 JSON document.
pub fn render(arena: Allocator, json: []const u8, diag: *Diagnostic) Error!Rendered {
    var scanner = std.json.Scanner.initCompleteInput(arena, json);
    var jd: std.json.Diagnostics = .{};
    scanner.enableDiagnostics(&jd);
    const doc = std.json.parseFromTokenSourceLeaky(JsonValue, arena, &scanner, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => {
            diag.* = .{ .line = @intCast(jd.getLine()), .message = std.fmt.allocPrint(arena, "invalid JSON ({s})", .{@errorName(err)}) catch "invalid JSON" };
            return error.InvalidSpec;
        },
    };
    if (doc != .object or str(doc.object, "openapi") == null or !std.mem.startsWith(u8, str(doc.object, "openapi").?, "3.")) {
        diag.* = .{ .line = 1, .message = "not an OpenAPI 3 document: expected \"openapi\": \"3.x\"" };
        return error.InvalidSpec;
    }
    const paths = obj(doc.object, "paths") orelse {
        diag.* = .{ .line = 1, .message = "an OpenAPI document needs \"paths\"" };
        return error.InvalidSpec;
    };

    var c: Ctx = .{ .arena = arena, .root = doc.object };
    const info = obj(doc.object, "info");
    const title = if (info) |i| str(i, "title") orelse "API reference" else "API reference";

    // Collect operations in document order, grouped by their first tag.
    var tag_names: std.ArrayList([]const u8) = .empty;
    if (arr(doc.object, "tags")) |tags| for (tags) |t| {
        if (t == .object) if (str(t.object, "name")) |n| try tag_names.append(arena, n);
    };
    var ops_by_tag: std.StringArrayHashMapUnmanaged(std.ArrayList(Op)) = .empty;
    for (tag_names.items) |n| try ops_by_tag.put(arena, n, .empty);
    var pit = paths.iterator();
    while (pit.next()) |pe| {
        if (pe.value_ptr.* != .object) continue;
        const item = pe.value_ptr.object;
        for (methods) |m| {
            const ov = item.get(m) orelse continue;
            if (ov != .object) continue;
            const tag = blk: {
                if (arr(ov.object, "tags")) |ts| if (ts.len > 0 and ts[0] == .string) break :blk ts[0].string;
                break :blk "Endpoints";
            };
            const gop = try ops_by_tag.getOrPut(arena, tag);
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            const base_id = if (str(ov.object, "operationId")) |id| try markdown.slugify(arena, id) else try markdown.slugify(arena, try std.fmt.allocPrint(arena, "{s} {s}", .{ m, pe.key_ptr.* }));
            try gop.value_ptr.append(arena, .{
                .method = m,
                .path = pe.key_ptr.*,
                .op = ov.object,
                .path_params = arr(item, "parameters"),
                .id = try c.uniqueId(base_id),
            });
        }
    }

    var aw: Writer.Allocating = .init(arena);
    var toc: Writer.Allocating = .init(arena);
    writeDoc(&c, &aw.writer, &toc.writer, doc.object, &ops_by_tag) catch return error.OutOfMemory;
    return .{
        .title = title,
        .description = if (info) |i| str(i, "description") orelse "" else "",
        .html = try aw.toOwnedSlice(),
        .toc = try toc.toOwnedSlice(),
    };
}

fn writeDoc(c: *Ctx, w: *Writer, toc: *Writer, root: std.json.ObjectMap, ops_by_tag: *std.StringArrayHashMapUnmanaged(std.ArrayList(Op))) !void {
    const arena = c.arena;
    try w.writeAll("<div class=\"mt-api\">\n");
    if (obj(root, "info")) |info| {
        try w.writeAll("<p class=\"mt-api-meta\">");
        if (str(info, "version")) |v| {
            try w.writeAll("<span class=\"mt-badge\">v");
            try escapeHtml(w, v);
            try w.writeAll("</span> ");
        }
        try w.writeAll("OpenAPI ");
        try escapeHtml(w, str(root, "openapi").?);
        try w.writeAll("</p>\n");
        if (str(info, "description")) |d| try w.writeAll(try markdown.toHtml(arena, d));
    }
    if (arr(root, "servers")) |servers| {
        try w.writeAll("<div class=\"mt-api-servers\"><span>Servers</span>");
        for (servers) |s| if (s == .object) if (str(s.object, "url")) |u| {
            try w.writeAll(" <code>");
            try escapeHtml(w, u);
            try w.writeAll("</code>");
        };
        try w.writeAll("</div>\n");
    }

    try toc.writeAll("<ul class=\"toc\">\n");
    var tit = ops_by_tag.iterator();
    while (tit.next()) |te| {
        const ops = te.value_ptr.items;
        if (ops.len == 0) continue;
        const tag_id = try c.uniqueId(try std.fmt.allocPrint(arena, "tag-{s}", .{try markdown.slugify(arena, te.key_ptr.*)}));
        try w.print("<h2 id=\"{s}\">", .{tag_id});
        try escapeHtml(w, te.key_ptr.*);
        try w.writeAll("</h2>\n");
        if (tagDescription(root, te.key_ptr.*)) |d| try w.writeAll(try markdown.toHtml(arena, d));
        try toc.print("<li><a href=\"#{s}\">", .{tag_id});
        try escapeHtml(toc, te.key_ptr.*);
        try toc.writeAll("</a>\n<ul>\n");
        for (ops) |op| {
            try writeOp(c, w, op);
            try toc.print("<li><a href=\"#{s}\"><span class=\"mt-method mt-method-{s}\">{s}</span> ", .{ op.id, op.method, op.method });
            try escapeHtml(toc, str(op.op, "summary") orelse op.path);
            try toc.writeAll("</a></li>\n");
        }
        try toc.writeAll("</ul>\n</li>\n");
    }

    if (obj(root, "components")) |comps| if (obj(comps, "schemas")) |schemas| {
        if (schemas.count() > 0) {
            try w.writeAll("<h2 id=\"schemas\">Schemas</h2>\n");
            try toc.writeAll("<li><a href=\"#schemas\">Schemas</a></li>\n");
            var sit = schemas.iterator();
            while (sit.next()) |se| {
                try w.print("<section class=\"mt-api-schema\" id=\"schema-{s}\">\n<h3>", .{try markdown.slugify(arena, se.key_ptr.*)});
                try escapeHtml(w, se.key_ptr.*);
                try w.writeAll("</h3>\n");
                const s = c.deref(se.value_ptr.*);
                if (s == .object) if (str(s.object, "description")) |d| try w.writeAll(try markdown.toHtml(arena, d));
                try writeSchemaTable(c, w, s);
                try w.writeAll("</section>\n");
            }
        }
    };
    try toc.writeAll("</ul>\n");
    try w.writeAll("</div>\n");
}

fn tagDescription(root: std.json.ObjectMap, name: []const u8) ?[]const u8 {
    const tags = arr(root, "tags") orelse return null;
    for (tags) |t| {
        if (t != .object) continue;
        const n = str(t.object, "name") orelse continue;
        if (std.mem.eql(u8, n, name)) return str(t.object, "description");
    }
    return null;
}

fn writeOp(c: *Ctx, w: *Writer, op: Op) !void {
    const arena = c.arena;
    const deprecated = if (op.op.get("deprecated")) |d| d == .bool and d.bool else false;
    try w.print("<section class=\"mt-api-op{s}\" id=\"{s}\">\n", .{ if (deprecated) " mt-api-deprecated" else "", op.id });
    try w.print("<h3 class=\"mt-api-endpoint\"><span class=\"mt-method mt-method-{s}\">{s}</span> <code class=\"mt-api-path\">", .{ op.method, op.method });
    try writePath(w, op.path);
    try w.writeAll("</code>");
    if (deprecated) try w.writeAll(" <span class=\"mt-badge\">deprecated</span>");
    try w.writeAll("</h3>\n");
    if (str(op.op, "summary")) |s| {
        try w.writeAll("<p class=\"mt-api-summary\">");
        try escapeHtml(w, s);
        try w.writeAll("</p>\n");
    }
    if (str(op.op, "description")) |d| try w.writeAll(try markdown.toHtml(arena, d));

    // Parameters: the path's shared ones, then the operation's.
    var params: std.ArrayList(std.json.ObjectMap) = .empty;
    for ([_]?[]const JsonValue{ op.path_params, arr(op.op, "parameters") }) |list| if (list) |ps| for (ps) |pv| {
        const p = c.deref(pv);
        if (p == .object) try params.append(arena, p.object);
    };
    if (params.items.len > 0) {
        try w.writeAll("<h4>Parameters</h4>\n<table class=\"mt-api-table\">\n<thead><tr><th>Name</th><th>In</th><th>Type</th><th>Description</th></tr></thead>\n<tbody>\n");
        for (params.items) |p| {
            try w.writeAll("<tr><td><code>");
            try escapeHtml(w, str(p, "name") orelse "");
            try w.writeAll("</code>");
            if (p.get("required")) |r| if (r == .bool and r.bool) try w.writeAll(" <span class=\"mt-api-required\">required</span>");
            try w.writeAll("</td><td>");
            try escapeHtml(w, str(p, "in") orelse "");
            try w.writeAll("</td><td>");
            if (p.get("schema")) |s| try writeType(c, w, s);
            try w.writeAll("</td><td>");
            if (str(p, "description")) |d| try writeInlineMarkdown(c, w, d);
            try w.writeAll("</td></tr>\n");
        }
        try w.writeAll("</tbody>\n</table>\n");
    }

    if (op.op.get("requestBody")) |rbv| {
        const rb = c.deref(rbv);
        if (rb == .object) {
            try w.writeAll("<h4>Request body");
            if (rb.object.get("required")) |r| if (r == .bool and r.bool) try w.writeAll(" <span class=\"mt-api-required\">required</span>");
            try w.writeAll("</h4>\n");
            if (str(rb.object, "description")) |d| try w.writeAll(try markdown.toHtml(arena, d));
            if (obj(rb.object, "content")) |content| try writeContent(c, w, content);
        }
    }

    if (obj(op.op, "responses")) |responses| {
        try w.writeAll("<h4>Responses</h4>\n");
        var rit = responses.iterator();
        while (rit.next()) |re| {
            const r = c.deref(re.value_ptr.*);
            const code = re.key_ptr.*;
            const class = switch (code[0]) {
                '2' => "2xx",
                '3' => "3xx",
                '4' => "4xx",
                '5' => "5xx",
                else => "other",
            };
            try w.print("<div class=\"mt-api-response mt-status-{s}\">\n<p><span class=\"mt-api-status\">", .{class});
            try escapeHtml(w, code);
            try w.writeAll("</span> ");
            if (r == .object) if (str(r.object, "description")) |d| try writeInlineMarkdown(c, w, d);
            try w.writeAll("</p>\n");
            if (r == .object) if (obj(r.object, "content")) |content| try writeContent(c, w, content);
            try w.writeAll("</div>\n");
        }
    }
    try w.writeAll("</section>\n");
}

/// Writes a path, marking `{params}`.
fn writePath(w: *Writer, path: []const u8) !void {
    var i: usize = 0;
    while (std.mem.indexOfScalarPos(u8, path, i, '{')) |open| {
        const close = std.mem.indexOfScalarPos(u8, path, open, '}') orelse break;
        try escapeHtml(w, path[i..open]);
        try w.writeAll("<span class=\"mt-api-param\">");
        try escapeHtml(w, path[open .. close + 1]);
        try w.writeAll("</span>");
        i = close + 1;
    }
    try escapeHtml(w, path[i..]);
}

/// Renders a one-paragraph description without its `<p>` wrapper.
fn writeInlineMarkdown(c: *Ctx, w: *Writer, text: []const u8) !void {
    const html = try markdown.toHtml(c.arena, text);
    const trimmed = std.mem.trimEnd(u8, html, "\n");
    if (std.mem.startsWith(u8, trimmed, "<p>") and std.mem.endsWith(u8, trimmed, "</p>") and
        std.mem.indexOf(u8, trimmed[3..], "<p>") == null)
    {
        try w.writeAll(trimmed[3 .. trimmed.len - 4]);
    } else try w.writeAll(html);
}

fn writeContent(c: *Ctx, w: *Writer, content: std.json.ObjectMap) !void {
    var it = content.iterator();
    while (it.next()) |e| {
        try w.writeAll("<p class=\"mt-api-media\"><code>");
        try escapeHtml(w, e.key_ptr.*);
        try w.writeAll("</code>");
        const media = if (e.value_ptr.* == .object) e.value_ptr.object else continue;
        const schema = media.get("schema");
        if (schema) |s| {
            try w.writeAll(" ");
            try writeType(c, w, s);
        }
        try w.writeAll("</p>\n");
        if (schema) |s| {
            const resolved = c.deref(s);
            if (resolved == .object and (resolved.object.get("properties") != null)) try writeSchemaTable(c, w, resolved);
        }
        // The example: given, or made from the schema.
        const example: ?JsonValue = media.get("example") orelse if (schema) |s| try exampleOf(c, s, 0) else null;
        if (example) |ex| {
            var aw: Writer.Allocating = .init(c.arena);
            std.json.Stringify.value(ex, .{ .whitespace = .indent_2 }, &aw.writer) catch return error.OutOfMemory;
            try w.writeAll("<div class=\"mt-code\">\n<div class=\"mt-code-title\">Example</div>\n<pre><code class=\"language-json\">");
            try highlight.write(w, "json", aw.written());
            try w.writeAll("</code></pre>\n</div>\n");
        }
    }
}

/// A short type label: `string`, `integer (int64)`, `array of Pet`, or a
/// link to a component schema.
fn writeType(c: *Ctx, w: *Writer, v: JsonValue) !void {
    if (refOf(v)) |ref| {
        const name = ref[(std.mem.lastIndexOfScalar(u8, ref, '/') orelse 0) + 1 ..];
        if (std.mem.startsWith(u8, ref, "#/components/schemas/")) {
            try w.print("<a class=\"mt-api-ref\" href=\"#schema-{s}\">", .{try markdown.slugify(c.arena, name)});
            try escapeHtml(w, name);
            return w.writeAll("</a>");
        }
        return writeType(c, w, c.deref(v));
    }
    if (v != .object) return w.writeAll("any");
    const o = v.object;
    for ([_][]const u8{ "oneOf", "anyOf", "allOf" }) |combo| if (arr(o, combo)) |alts| {
        for (alts, 0..) |alt, i| {
            if (i > 0) try w.writeAll(if (std.mem.eql(u8, combo, "allOf")) " &amp; " else " | ");
            try writeType(c, w, alt);
        }
        return;
    };
    const t = str(o, "type") orelse (if (o.get("properties") != null) "object" else "any");
    if (std.mem.eql(u8, t, "array")) {
        try w.writeAll("array of ");
        return if (o.get("items")) |items| writeType(c, w, items) else w.writeAll("any");
    }
    try w.print("<span class=\"mt-api-type\">{s}</span>", .{t});
    if (str(o, "format")) |f| {
        try w.writeAll(" <small>(");
        try escapeHtml(w, f);
        try w.writeAll(")</small>");
    }
    if (arr(o, "enum")) |values| {
        try w.writeAll(" <small>one of ");
        for (values, 0..) |ev, i| {
            if (i > 0) try w.writeAll(", ");
            try w.writeAll("<code>");
            var aw: Writer.Allocating = .init(c.arena);
            std.json.Stringify.value(ev, .{}, &aw.writer) catch return error.OutOfMemory;
            try escapeHtml(w, aw.written());
            try w.writeAll("</code>");
        }
        try w.writeAll("</small>");
    }
}

fn writeSchemaTable(c: *Ctx, w: *Writer, schema: JsonValue) !void {
    if (schema != .object) return;
    const props = obj(schema.object, "properties") orelse {
        try w.writeAll("<p>");
        try writeType(c, w, schema);
        return w.writeAll("</p>\n");
    };
    const required = arr(schema.object, "required") orelse &.{};
    try w.writeAll("<table class=\"mt-api-table\">\n<thead><tr><th>Field</th><th>Type</th><th>Description</th></tr></thead>\n<tbody>\n");
    var it = props.iterator();
    while (it.next()) |e| {
        try w.writeAll("<tr><td><code>");
        try escapeHtml(w, e.key_ptr.*);
        try w.writeAll("</code>");
        for (required) |r| if (r == .string and std.mem.eql(u8, r.string, e.key_ptr.*)) {
            try w.writeAll(" <span class=\"mt-api-required\">required</span>");
            break;
        };
        try w.writeAll("</td><td>");
        try writeType(c, w, e.value_ptr.*);
        try w.writeAll("</td><td>");
        const p = c.deref(e.value_ptr.*);
        if (refOf(e.value_ptr.*) == null and p == .object) if (str(p.object, "description")) |d| try writeInlineMarkdown(c, w, d);
        try w.writeAll("</td></tr>\n");
    }
    try w.writeAll("</tbody>\n</table>\n");
}

/// An example value made from a schema, for operations without one.
fn exampleOf(c: *Ctx, v: JsonValue, depth: usize) Allocator.Error!?JsonValue {
    if (depth > 6) return null;
    const s = c.deref(v);
    if (s != .object) return null;
    const o = s.object;
    if (o.get("example")) |ex| return ex;
    if (arr(o, "enum")) |values| if (values.len > 0) return values[0];
    for ([_][]const u8{ "oneOf", "anyOf", "allOf" }) |combo| if (arr(o, combo)) |alts| {
        if (alts.len > 0) return exampleOf(c, alts[0], depth + 1);
    };
    const t = str(o, "type") orelse (if (o.get("properties") != null) "object" else return null);
    if (std.mem.eql(u8, t, "object")) {
        var out: std.json.ObjectMap = .empty;
        if (obj(o, "properties")) |props| {
            var it = props.iterator();
            while (it.next()) |e| {
                if (try exampleOf(c, e.value_ptr.*, depth + 1)) |ex| try out.put(c.arena, e.key_ptr.*, ex);
            }
        }
        return .{ .object = out };
    }
    if (std.mem.eql(u8, t, "array")) {
        var list: std.json.Array = .init(c.arena);
        if (o.get("items")) |items| if (try exampleOf(c, items, depth + 1)) |ex| try list.append(ex);
        return .{ .array = list };
    }
    if (std.mem.eql(u8, t, "integer")) return .{ .integer = 0 };
    if (std.mem.eql(u8, t, "number")) return .{ .float = 0 };
    if (std.mem.eql(u8, t, "boolean")) return .{ .bool = true };
    if (std.mem.eql(u8, t, "string")) {
        const f = str(o, "format") orelse "";
        if (std.mem.eql(u8, f, "date-time")) return .{ .string = "2024-01-01T00:00:00Z" };
        if (std.mem.eql(u8, f, "date")) return .{ .string = "2024-01-01" };
        if (std.mem.eql(u8, f, "email")) return .{ .string = "user@example.com" };
        if (std.mem.eql(u8, f, "uuid")) return .{ .string = "3fa85f64-5717-4562-b3fc-2c963f66afa6" };
        return .{ .string = "string" };
    }
    return null;
}

const testing = std.testing;

const petstore =
    \\{
    \\  "openapi": "3.0.3",
    \\  "info": { "title": "Pets", "version": "1.2.0", "description": "A *pet* store." },
    \\  "servers": [{ "url": "https://api.example.com/v1" }],
    \\  "tags": [{ "name": "pets", "description": "Everything about pets." }],
    \\  "paths": {
    \\    "/pets/{petId}": {
    \\      "parameters": [{ "name": "petId", "in": "path", "required": true, "schema": { "type": "integer", "format": "int64" } }],
    \\      "get": {
    \\        "tags": ["pets"], "operationId": "getPet", "summary": "Get a pet",
    \\        "responses": {
    \\          "200": { "description": "The pet", "content": { "application/json": { "schema": { "$ref": "#/components/schemas/Pet" } } } },
    \\          "404": { "description": "Not found" }
    \\        }
    \\      },
    \\      "delete": { "summary": "Delete a pet", "deprecated": true, "responses": { "204": { "description": "Deleted" } } }
    \\    }
    \\  },
    \\  "components": { "schemas": { "Pet": {
    \\    "type": "object", "required": ["name"],
    \\    "properties": { "id": { "type": "integer" }, "name": { "type": "string", "description": "The **name**." }, "status": { "type": "string", "enum": ["available", "sold"] } }
    \\  } } }
    \\}
;

test "renders operations, parameters, responses, schemas, and examples" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    const r = try render(arena.allocator(), petstore, &diag);
    try testing.expectEqualStrings("Pets", r.title);
    const h = r.html;
    const expect = struct {
        fn has(html: []const u8, needle: []const u8) !void {
            if (std.mem.indexOf(u8, html, needle) == null) {
                std.debug.print("missing: {s}\n", .{needle});
                return error.TestExpectedSubstring;
            }
        }
    };
    try expect.has(h, "<span class=\"mt-badge\">v1.2.0</span> OpenAPI 3.0.3");
    try expect.has(h, "<h2 id=\"tag-pets\">pets</h2>");
    try expect.has(h, "<section class=\"mt-api-op\" id=\"getpet\">");
    try expect.has(h, "<span class=\"mt-method mt-method-get\">get</span> <code class=\"mt-api-path\">/pets/<span class=\"mt-api-param\">{petId}</span></code>");
    try expect.has(h, "<code>petId</code> <span class=\"mt-api-required\">required</span></td><td>path</td><td><span class=\"mt-api-type\">integer</span> <small>(int64)</small>");
    try expect.has(h, "<a class=\"mt-api-ref\" href=\"#schema-pet\">Pet</a>");
    try expect.has(h, "<span class=\"mt-api-status\">404</span> Not found");
    // Untagged operations are grouped under "Endpoints"; deprecation shows.
    try expect.has(h, "<h2 id=\"tag-endpoints\">Endpoints</h2>");
    try expect.has(h, "mt-api-deprecated");
    // The example is made from the schema, with the first enum value.
    try expect.has(h, "<span class=\"hl-string\">&quot;status&quot;</span>: <span class=\"hl-string\">&quot;available&quot;</span>");
    try expect.has(h, "<section class=\"mt-api-schema\" id=\"schema-pet\">");
    try expect.has(h, "The <strong>name</strong>.");
    try expect.has(r.toc, "<a href=\"#getpet\">");
}

test "invalid specs are reported" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    var diag: Diagnostic = .{};
    try testing.expectError(error.InvalidSpec, render(arena.allocator(), "{\n\"openapi\": \"2.0\"}", &diag));
    try testing.expect(std.mem.indexOf(u8, diag.message, "OpenAPI 3") != null);
    try testing.expectError(error.InvalidSpec, render(arena.allocator(), "{\n\"openapi\": \"3.0.0\",\n}", &diag));
    try testing.expectEqual(@as(usize, 3), diag.line);
    try testing.expect(isSpec("_api/pets.json") and !isSpec("_api/x/pets.json") and !isSpec("api/pets.json"));
}
