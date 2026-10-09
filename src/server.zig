//! The development server: serves the last good build from memory on
//! localhost, rebuilds when sources change, and tells connected browsers to
//! reload over Server-Sent Events.
//!
//! Live reload protocol:
//!
//!   GET /__reload?since=N   text/event-stream. N is the build generation
//!                           the page was rendered from. The server sends
//!                           `reload` after every successful build newer
//!                           than N and `build-error` after a failed one.
//!
//! Every HTML response gets a small script, injected here and never by the
//! pipeline, that opens that stream. `mortise build` output stays clean.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const http = std.http;
const SiteDir = @import("SiteDir.zig");
const BuildArena = @import("BuildArena.zig");
const pipeline = @import("pipeline.zig");
const sitepath = @import("path.zig");
const Watcher = @import("watch.zig").Watcher;

pub const reload_path = "/__reload";

/// HTTP header buffer per connection. Large enough for any browser request.
const recv_buffer_len = 64 * 1024;
const send_buffer_len = 16 * 1024;

pub const Options = struct {
    /// 0 picks a free port.
    port: u16 = 4000,
    /// Where build results are logged. Null disables logging.
    log: ?*Io.Writer = null,
    /// Re-render only what a change affects. False rebuilds everything on
    /// every change, which the benchmark uses for comparison.
    incremental: bool = true,
    /// Build options, such as publishing drafts.
    build: pipeline.Options = .{},
};

/// One successful build, shared by every request that started while it was
/// current. Freed when the last user releases it.
const Snapshot = struct {
    arena: BuildArena,
    site: pipeline.Site,
    generation: u64,
    refs: usize,
    /// The build this one was incrementally derived from. Its memory is
    /// shared, so this snapshot holds a reference to it.
    parent: ?*Snapshot = null,
    /// Length of the parent chain.
    depth: usize = 0,
};

/// After this many incremental builds in a row, the next build starts from
/// scratch so the chain of shared arenas cannot grow without bound.
const max_chain = 64;

/// A copy of a failed build's diagnostic, owned by the server.
pub const Failure = struct {
    path: []const u8,
    line: usize,
    message: []const u8,
};

pub const Server = struct {
    io: Io,
    gpa: Allocator,
    src: SiteDir,
    listener: Io.net.Server,
    port: u16,
    log: ?*Io.Writer,
    incremental: bool,
    build_options: pipeline.Options,

    mutex: Io.Mutex = .init,
    /// Signaled whenever `generation` changes or the server stops.
    changed: Io.Condition = .init,
    snapshot: ?*Snapshot = null,
    /// Incremented after every build attempt, successful or not.
    generation: u64 = 0,
    /// The last build's error, or null if it succeeded.
    failure: ?Failure = null,
    stopping: bool = false,

    /// Changes not yet in a successful build, owned by `gpa`. A failed
    /// build keeps them so the next incremental build still covers them.
    pending: std.ArrayList([]const u8) = .empty,

    tasks: Io.Group = .init,
    /// Duration of the most recent build, successful or not.
    last_build_ns: i96 = 0,

    pub const InitError = Io.Dir.OpenError || Io.net.IpAddress.ListenError || Allocator.Error;

    /// Opens the site, binds to 127.0.0.1, and runs the first build. The
    /// server does not accept connections until `start` is called.
    pub fn init(gpa: Allocator, io: Io, site_root: []const u8, options: Options) InitError!*Server {
        const s = try gpa.create(Server);
        errdefer gpa.destroy(s);
        var src = try SiteDir.open(io, site_root);
        errdefer src.close();
        const address: Io.net.IpAddress = .{ .ip4 = .loopback(options.port) };
        var listener = try address.listen(io, .{ .reuse_address = true });
        errdefer listener.deinit(io);
        s.* = .{
            .io = io,
            .gpa = gpa,
            .src = src,
            .listener = listener,
            .port = listener.socket.address.getPort(),
            .log = options.log,
            .incremental = options.incremental,
            .build_options = options.build,
        };
        s.rebuild();
        return s;
    }

    /// Starts accepting connections in the background.
    pub fn start(s: *Server) Io.ConcurrentError!void {
        try s.tasks.concurrent(s.io, acceptLoop, .{s});
    }

    /// Blocks until the server's background tasks end, which for the CLI
    /// means until the process is interrupted.
    pub fn wait(s: *Server) void {
        s.tasks.await(s.io) catch {};
    }

    /// Stops accepting, ends every event stream, waits for connection
    /// handlers to finish, and frees the server.
    pub fn deinit(s: *Server) void {
        const io = s.io;
        s.mutex.lockUncancelable(io);
        s.stopping = true;
        s.changed.broadcast(io);
        s.mutex.unlock(io);
        // Wake the blocking accept with a connection of our own.
        const address: Io.net.IpAddress = .{ .ip4 = .loopback(s.port) };
        if (address.connect(io, .{ .mode = .stream })) |stream| stream.close(io) else |_| {}
        s.tasks.await(io) catch {};

        s.listener.deinit(io);
        if (s.snapshot) |snap| s.release(snap);
        s.clearFailure();
        s.clearPending();
        s.pending.deinit(s.gpa);
        s.src.close();
        s.gpa.destroy(s);
    }

    /// Rebuilds the whole site. On success the new build is served and
    /// browsers reload; on failure the previous build keeps being served and
    /// browsers are told about the error.
    pub fn rebuild(s: *Server) void {
        s.runBuild(false);
    }

    /// Rebuilds after the given source paths changed, re-rendering only
    /// what depends on them when the previous build allows it.
    pub fn rebuildChanged(s: *Server, changes: []const []const u8) void {
        for (changes) |c| {
            const known = for (s.pending.items) |p| {
                if (std.mem.eql(u8, p, c)) break true;
            } else false;
            if (known) continue;
            const owned = s.gpa.dupe(u8, c) catch return s.fullAfterOom();
            s.pending.append(s.gpa, owned) catch {
                s.gpa.free(owned);
                return s.fullAfterOom();
            };
        }
        s.runBuild(true);
    }

    fn fullAfterOom(s: *Server) void {
        s.clearPending();
        s.runBuild(false);
    }

    fn clearPending(s: *Server) void {
        for (s.pending.items) |p| s.gpa.free(p);
        s.pending.clearRetainingCapacity();
    }

    fn runBuild(s: *Server, incremental: bool) void {
        const io = s.io;
        const start_time = Io.Clock.Timestamp.now(io, .awake);

        // An incremental build reads the current snapshot, so hold it.
        const prev: ?*Snapshot = if (incremental) s.acquire() else null;
        var prev_kept = false;
        defer if (prev) |p| if (!prev_kept) s.release(p);

        const snap = s.gpa.create(Snapshot) catch return s.logLine("error: out of memory", .{});
        snap.* = .{ .arena = .init(s.gpa), .site = undefined, .generation = 0, .refs = 1 };
        const arena = snap.arena.begin();
        var diag: pipeline.Diagnostic = .{};
        const result = if (prev != null and prev.?.depth < max_chain)
            pipeline.rebuild(arena, s.src, &prev.?.site, s.pending.items, &diag)
        else
            pipeline.buildWith(arena, s.src, s.build_options, &diag);
        s.last_build_ns = start_time.durationTo(Io.Clock.Timestamp.now(io, .awake)).raw.nanoseconds;

        if (result) |site| {
            snap.site = site;
            if (!site.full) {
                // The new site shares memory with the previous one.
                snap.parent = prev;
                snap.depth = prev.?.depth + 1;
                prev_kept = true;
            }
            s.clearPending();
            s.mutex.lockUncancelable(io);
            const old = s.snapshot;
            s.generation += 1;
            snap.generation = s.generation;
            s.snapshot = snap;
            s.clearFailure();
            s.changed.broadcast(io);
            s.mutex.unlock(io);
            if (old) |o| s.release(o);
            const ms = @as(f64, @floatFromInt(s.last_build_ns)) / std.time.ns_per_ms;
            if (site.full) {
                s.logLine("Built {d} pages, {d} posts, {d} static files in {d:.1} ms", .{ site.pages, site.posts, site.static_files, ms });
            } else {
                s.logLine("Rebuilt {d} of {d} pages in {d:.1} ms", .{ site.rendered, site.pages + site.posts, ms });
            }
        } else |err| {
            const failure: ?Failure = switch (err) {
                error.BuildFailed => s.copyFailure(diag) catch null,
                error.OutOfMemory => null,
            };
            snap.arena.deinit();
            s.gpa.destroy(snap);
            s.mutex.lockUncancelable(io);
            s.clearFailure();
            s.failure = failure orelse .{ .path = "", .line = 0, .message = "" };
            s.generation += 1;
            s.changed.broadcast(io);
            s.mutex.unlock(io);
            switch (err) {
                error.BuildFailed => s.logLine("error: {f}", .{diag}),
                error.OutOfMemory => s.logLine("error: out of memory", .{}),
            }
        }
    }

    fn copyFailure(s: *Server, d: pipeline.Diagnostic) Allocator.Error!Failure {
        const path = try s.gpa.dupe(u8, d.path);
        errdefer s.gpa.free(path);
        return .{ .path = path, .line = d.line, .message = try s.gpa.dupe(u8, d.message) };
    }

    /// Caller holds the mutex (or is the only thread left).
    fn clearFailure(s: *Server) void {
        if (s.failure) |f| {
            s.gpa.free(f.path);
            s.gpa.free(f.message);
        }
        s.failure = null;
    }

    fn logLine(s: *Server, comptime fmt: []const u8, args: anytype) void {
        const w = s.log orelse return;
        w.print(fmt ++ "\n", args) catch {};
        w.flush() catch {};
    }

    fn acquire(s: *Server) ?*Snapshot {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        const snap = s.snapshot orelse return null;
        snap.refs += 1;
        return snap;
    }

    fn release(s: *Server, snapshot: *Snapshot) void {
        var snap = snapshot;
        while (true) {
            s.mutex.lockUncancelable(s.io);
            snap.refs -= 1;
            const last = snap.refs == 0;
            s.mutex.unlock(s.io);
            if (!last) return;
            // Freeing a snapshot drops its reference to the build it shared
            // memory with.
            const parent = snap.parent;
            snap.arena.deinit();
            s.gpa.destroy(snap);
            snap = parent orelse return;
        }
    }

    /// Rebuilds whenever `watcher` reports a change, until the server stops.
    /// Runs in the background; `deinit` waits for it.
    pub fn watch(s: *Server, watcher: *Watcher) Io.ConcurrentError!void {
        try s.tasks.concurrent(s.io, watchLoop, .{ s, watcher });
    }

    fn isStopping(s: *Server) bool {
        s.mutex.lockUncancelable(s.io);
        defer s.mutex.unlock(s.io);
        return s.stopping;
    }
};

/// How often the watch loop checks whether the server is stopping.
const watch_poll_ms = 100;

fn watchLoop(s: *Server, watcher: *Watcher) Io.Cancelable!void {
    var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena_state.deinit();
    while (!s.isStopping()) {
        _ = arena_state.reset(.retain_capacity);
        const changes = watcher.waitDebounced(arena_state.allocator(), watch_poll_ms, .{}) catch |err| {
            s.logLine("warning: file watcher failed: {s}", .{@errorName(err)});
            return;
        };
        if (changes.len == 0) continue;
        if (s.incremental) s.rebuildChanged(changes) else s.rebuild();
    }
}

fn acceptLoop(s: *Server) Io.Cancelable!void {
    const io = s.io;
    while (true) {
        const stream = s.listener.accept(io) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            else => {
                if (s.isStopping()) return;
                s.logLine("warning: accept failed: {s}", .{@errorName(err)});
                continue;
            },
        };
        if (s.isStopping()) {
            stream.close(io);
            return;
        }
        s.tasks.concurrent(io, handleConnection, .{ s, stream }) catch {
            // No thread available: serve this connection inline.
            handleConnection(s, stream) catch {};
        };
    }
}

fn handleConnection(s: *Server, stream: Io.net.Stream) Io.Cancelable!void {
    const io = s.io;
    defer stream.close(io);
    const buffers = s.gpa.alloc(u8, recv_buffer_len + send_buffer_len) catch return;
    defer s.gpa.free(buffers);
    var reader = stream.reader(io, buffers[0..recv_buffer_len]);
    var writer = stream.writer(io, buffers[recv_buffer_len..]);
    var server = http.Server.init(&reader.interface, &writer.interface);
    while (true) {
        var request = server.receiveHead() catch return;
        const keep_alive = handleRequest(s, &request) catch return;
        if (!keep_alive or !request.head.keep_alive) return;
    }
}

/// Serves one request. Returns whether the connection may be reused.
fn handleRequest(s: *Server, req: *http.Server.Request) !bool {
    if (req.head.method != .GET and req.head.method != .HEAD) {
        try req.respond("method not allowed\n", .{ .status = .method_not_allowed, .extra_headers = &.{
            .{ .name = "allow", .value = "GET, HEAD" },
        } });
        return true;
    }
    const target = req.head.target;
    const qmark = std.mem.indexOfScalar(u8, target, '?');
    const raw_path = target[0 .. qmark orelse target.len];
    const query = if (qmark) |q| target[q + 1 ..] else "";

    if (std.mem.eql(u8, raw_path, reload_path)) {
        try serveEvents(s, req, query);
        return false;
    }

    var arena_state: std.heap.ArenaAllocator = .init(s.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const snap = s.acquire() orelse {
        try serveNoBuild(s, req, arena);
        return true;
    };
    defer s.release(snap);

    const full_path = percentDecode(arena, raw_path) catch return respondText(req, .bad_request, "bad request\n");
    if (full_path.len == 0 or full_path[0] != '/') return respondText(req, .bad_request, "bad request\n");

    // With a baseurl such as `/blog`, the site lives under `/blog/`.
    const base = snap.site.baseurl;
    if (base.len > 0 and !std.mem.startsWith(u8, full_path, base)) {
        if (std.mem.eql(u8, full_path, "/")) return redirect(req, arena, base, "/");
        return respondText(req, .not_found, "not found\n");
    }
    const url_path = full_path[base.len..];
    if (url_path.len == 0) return redirect(req, arena, base, "/");
    if (url_path[0] != '/') return respondText(req, .not_found, "not found\n");

    const lookup = try std.fmt.allocPrint(arena, "{s}{s}", .{
        url_path[1..],
        if (url_path[url_path.len - 1] == '/') "index.html" else "",
    });
    const sp = sitepath.normalize(arena, lookup) catch return respondText(req, .not_found, "not found\n");

    if (snap.site.find(sp)) |out| {
        try serveOutput(s, req, arena, snap, out, .ok);
        return true;
    }
    // `/about` -> `/about/` when `about/index.html` exists.
    const dir_index = try std.fmt.allocPrint(arena, "{s}/index.html", .{sp});
    if (snap.site.find(dir_index) != null) return redirect(req, arena, full_path, "/");
    if (snap.site.find("404.html")) |page| {
        try serveOutput(s, req, arena, snap, page, .not_found);
        return true;
    }
    return respondText(req, .not_found, "not found\n");
}

/// Permanently redirects to `prefix` followed by `suffix`.
fn redirect(req: *http.Server.Request, arena: Allocator, prefix: []const u8, suffix: []const u8) !bool {
    const location = try std.mem.concat(arena, u8, &.{ prefix, suffix });
    try req.respond("", .{ .status = .moved_permanently, .extra_headers = &.{
        .{ .name = "location", .value = location },
        .{ .name = "cache-control", .value = "no-store" },
    } });
    return true;
}

fn respondText(req: *http.Server.Request, status: http.Status, body: []const u8) !bool {
    try req.respond(body, .{ .status = status, .extra_headers = &.{
        .{ .name = "content-type", .value = "text/plain; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-store" },
    } });
    return true;
}

fn serveOutput(s: *Server, req: *http.Server.Request, arena: Allocator, snap: *Snapshot, out: pipeline.Output, status: http.Status) !void {
    const body = switch (out.data) {
        .bytes => |b| b,
        .copy => s.src.readFile(arena, out.source) catch {
            _ = try respondText(req, .not_found, "not found\n");
            return;
        },
    };
    const ctype = contentType(out.path);
    const final = if (std.mem.startsWith(u8, ctype, "text/html"))
        try injectReloadScript(arena, body, snap.generation)
    else
        body;
    try req.respond(final, .{ .status = status, .extra_headers = &.{
        .{ .name = "content-type", .value = ctype },
        .{ .name = "cache-control", .value = "no-store" },
    } });
}

/// Shown when no build has succeeded yet, so there is nothing to serve.
fn serveNoBuild(s: *Server, req: *http.Server.Request, arena: Allocator) !void {
    s.mutex.lockUncancelable(s.io);
    const generation = s.generation;
    s.mutex.unlock(s.io);
    const page = try injectReloadScript(arena,
        \\<!doctype html><html><head><meta charset="utf-8"><title>Build failed</title></head>
        \\<body><p>The site has not built successfully yet. Fix the error and save; this page reloads on its own.</p></body></html>
    , generation);
    try req.respond(page, .{ .status = .service_unavailable, .extra_headers = &.{
        .{ .name = "content-type", .value = "text/html; charset=utf-8" },
        .{ .name = "cache-control", .value = "no-store" },
    } });
}

fn serveEvents(s: *Server, req: *http.Server.Request, query: []const u8) !void {
    const io = s.io;
    s.mutex.lockUncancelable(io);
    const since = parseSince(query) orelse s.generation;
    const initial = eventFor(s, s.gpa, since) catch |err| {
        s.mutex.unlock(io);
        return err;
    };
    var seen = s.generation;
    s.mutex.unlock(io);
    defer if (initial) |e| s.gpa.free(e);

    var body = try req.respondStreaming(&.{}, .{ .respond_options = .{ .extra_headers = &.{
        .{ .name = "content-type", .value = "text/event-stream" },
        .{ .name = "cache-control", .value = "no-store" },
    } } });
    try body.writer.writeAll("retry: 1000\n\n");
    if (initial) |e| try body.writer.writeAll(e);
    try body.flush();

    while (true) {
        s.mutex.lockUncancelable(io);
        while (!s.stopping and s.generation == seen) {
            s.changed.wait(io, &s.mutex) catch {
                s.mutex.unlock(io);
                return;
            };
        }
        if (s.stopping) {
            s.mutex.unlock(io);
            break;
        }
        seen = s.generation;
        const event = eventFor(s, s.gpa, seen - 1) catch null;
        s.mutex.unlock(io);
        const e = event orelse continue;
        defer s.gpa.free(e);
        try body.writer.writeAll(e);
        try body.flush();
    }
    // The server is stopping. The connection is about to be closed, so the
    // stream is not ended cleanly: the client may already be gone, and
    // EventSource reconnects either way.
}

/// The event a client that has seen `since` should get now, if any.
/// Caller holds the mutex.
fn eventFor(s: *Server, gpa: Allocator, since: u64) Allocator.Error!?[]u8 {
    if (s.failure) |f| {
        var aw: Io.Writer.Allocating = .init(gpa);
        errdefer aw.deinit();
        const w = &aw.writer;
        w.writeAll("event: build-error\ndata: {\"file\":") catch return error.OutOfMemory;
        writeJsonString(w, f.path) catch return error.OutOfMemory;
        w.print(",\"line\":{d},\"message\":", .{f.line}) catch return error.OutOfMemory;
        writeJsonString(w, f.message) catch return error.OutOfMemory;
        w.writeAll("}\n\n") catch return error.OutOfMemory;
        return try aw.toOwnedSlice();
    }
    if (s.generation != since) {
        return try std.fmt.allocPrint(gpa, "event: reload\ndata: {d}\n\n", .{s.generation});
    }
    return null;
}

fn parseSince(query: []const u8) ?u64 {
    var it = std.mem.splitScalar(u8, query, '&');
    while (it.next()) |pair| {
        if (std.mem.startsWith(u8, pair, "since=")) return std.fmt.parseInt(u64, pair["since=".len..], 10) catch null;
    }
    return null;
}

fn writeJsonString(w: *Io.Writer, s: []const u8) Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...8, 11, 12, 14...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// The script added to every HTML page the dev server sends.
/// It reloads the page after a successful rebuild and, after a failed one,
/// covers the page with an overlay showing the file, line, and message.
/// The overlay is built with textContent, so error text is never parsed as
/// HTML.
pub const reload_script_template =
    \\<script data-mortise-dev>(function(){
    \\var es=new EventSource("/__reload?since=GENERATION");
    \\es.addEventListener("reload",function(){location.reload();});
    \\es.addEventListener("build-error",function(e){show(JSON.parse(e.data));});
    \\function div(css,text){var d=document.createElement("div");d.style.cssText=css;d.textContent=text;return d;}
    \\function show(err){
    \\var el=document.getElementById("mortise-error-overlay");
    \\if(!el){el=document.createElement("div");el.id="mortise-error-overlay";el.setAttribute("role","alert");
    \\el.style.cssText="position:fixed;inset:0;z-index:2147483647;overflow:auto;padding:32px;background:rgba(24,24,28,.94);color:#f4f4f5;font:14px/1.5 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace";
    \\document.documentElement.appendChild(el);}
    \\el.textContent="";
    \\el.appendChild(div("color:#f87171;font-weight:700;font-size:16px;margin-bottom:12px","Build failed"));
    \\el.appendChild(div("color:#7dd3fc;margin-bottom:8px",err.file+(err.line?":"+err.line:"")));
    \\el.appendChild(div("white-space:pre-wrap",err.message));
    \\el.appendChild(div("margin-top:16px;color:#a1a1aa","Still serving the last successful build. Fix the error and save to reload."));
    \\}
    \\})();</script>
;

/// Inserts the reload script before the last `</body>`, or appends it.
pub fn injectReloadScript(arena: Allocator, html: []const u8, generation: u64) Allocator.Error![]const u8 {
    const marker = "GENERATION";
    const at = std.mem.indexOf(u8, reload_script_template, marker).?;
    const script = try std.fmt.allocPrint(arena, "{s}{d}{s}", .{
        reload_script_template[0..at], generation, reload_script_template[at + marker.len ..],
    });
    const pos = lastIndexOfIgnoreCase(html, "</body>") orelse html.len;
    return std.mem.concat(arena, u8, &.{ html[0..pos], script, html[pos..] });
}

fn lastIndexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (haystack.len < needle.len) return null;
    var i = haystack.len - needle.len + 1;
    while (i > 0) {
        i -= 1;
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return i;
    }
    return null;
}

fn percentDecode(arena: Allocator, s: []const u8) error{ OutOfMemory, BadEncoding }![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '%') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '%') {
            try out.append(arena, s[i]);
            continue;
        }
        if (i + 2 >= s.len) return error.BadEncoding;
        const byte = std.fmt.parseInt(u8, s[i + 1 .. i + 3], 16) catch return error.BadEncoding;
        if (byte == 0) return error.BadEncoding;
        try out.append(arena, byte);
        i += 2;
    }
    return out.items;
}

pub fn contentType(path: []const u8) []const u8 {
    const ext = sitepath.extension(path);
    const table = [_]struct { []const u8, []const u8 }{
        .{ ".html", "text/html; charset=utf-8" },
        .{ ".htm", "text/html; charset=utf-8" },
        .{ ".css", "text/css; charset=utf-8" },
        .{ ".js", "text/javascript; charset=utf-8" },
        .{ ".mjs", "text/javascript; charset=utf-8" },
        .{ ".json", "application/json" },
        .{ ".xml", "application/xml" },
        .{ ".txt", "text/plain; charset=utf-8" },
        .{ ".md", "text/plain; charset=utf-8" },
        .{ ".svg", "image/svg+xml" },
        .{ ".png", "image/png" },
        .{ ".jpg", "image/jpeg" },
        .{ ".jpeg", "image/jpeg" },
        .{ ".gif", "image/gif" },
        .{ ".webp", "image/webp" },
        .{ ".avif", "image/avif" },
        .{ ".ico", "image/x-icon" },
        .{ ".woff", "font/woff" },
        .{ ".woff2", "font/woff2" },
        .{ ".pdf", "application/pdf" },
        .{ ".wasm", "application/wasm" },
        .{ ".mp4", "video/mp4" },
        .{ ".webm", "video/webm" },
    };
    for (table) |entry| {
        if (std.ascii.eqlIgnoreCase(ext, entry[0])) return entry[1];
    }
    return "application/octet-stream";
}

// ---------------------------------------------------------------------------

const testing = std.testing;

test "injectReloadScript" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try injectReloadScript(a, "<html><BODY>x</BODY></html>", 7);
    try testing.expect(std.mem.indexOf(u8, out, "since=7") != null);
    try testing.expect(std.mem.endsWith(u8, out, "})();</script></BODY></html>"));
    const frag = try injectReloadScript(a, "<p>fragment</p>", 1);
    try testing.expect(std.mem.startsWith(u8, frag, "<p>fragment</p><script"));
}

test "percentDecode, parseSince, contentType" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    try testing.expectEqualStrings("/a b/", try percentDecode(arena.allocator(), "/a%20b/"));
    try testing.expectError(error.BadEncoding, percentDecode(arena.allocator(), "/a%2"));
    try testing.expectError(error.BadEncoding, percentDecode(arena.allocator(), "/%00"));
    try testing.expectEqual(@as(?u64, 12), parseSince("x=1&since=12"));
    try testing.expectEqual(@as(?u64, null), parseSince("since=abc"));
    try testing.expectEqualStrings("text/css; charset=utf-8", contentType("css/site.CSS"));
    try testing.expectEqualStrings("application/octet-stream", contentType("LICENSE"));
}

test "writeJsonString" {
    var buf: [64]u8 = undefined;
    var w: Io.Writer = .fixed(&buf);
    try writeJsonString(&w, "a\"b\\c\nd\x01");
    try testing.expectEqualStrings("\"a\\\"b\\\\c\\nd\\u0001\"", w.buffered());
}

/// A minimal HTTP client for tests: sends `request` and reads until
/// `needle` appears in the response or `timeout_ms` passes.
const TestClient = struct {
    io: Io,
    stream: Io.net.Stream,
    buf: [64 * 1024]u8 = undefined,
    len: usize = 0,

    fn connect(io: Io, port: u16) !TestClient {
        const address: Io.net.IpAddress = .{ .ip4 = .loopback(port) };
        return .{ .io = io, .stream = try address.connect(io, .{ .mode = .stream }) };
    }

    fn close(c: *TestClient) void {
        c.stream.close(c.io);
    }

    fn send(c: *TestClient, request: []const u8) !void {
        var wbuf: [1024]u8 = undefined;
        var w = c.stream.writer(c.io, &wbuf);
        try w.interface.writeAll(request);
        try w.interface.flush();
    }

    fn received(c: *const TestClient) []const u8 {
        return c.buf[0..c.len];
    }

    /// Reads until `needle` occurs at or after `from`. Returns false on
    /// timeout or end of stream.
    fn readUntil(c: *TestClient, from: usize, needle: []const u8, timeout_ms: u64) !bool {
        var watchdog = try c.io.concurrent(shutdownAfter, .{ c.io, c.stream, timeout_ms });
        defer watchdog.cancel(c.io) catch {};
        var rbuf: [0]u8 = .{};
        var r = c.stream.reader(c.io, &rbuf);
        while (std.mem.indexOfPos(u8, c.received(), from, needle) == null) {
            if (c.len == c.buf.len) return false;
            var vec = [_][]u8{c.buf[c.len..]};
            const n = r.interface.readVec(&vec) catch return false;
            if (n == 0) return false;
            c.len += n;
        }
        return true;
    }

    fn shutdownAfter(io: Io, stream: Io.net.Stream, ms: u64) Io.Cancelable!void {
        try io.sleep(.fromMilliseconds(@intCast(ms)), .awake);
        stream.shutdown(io, .both) catch {};
    }
};

fn testServerSite(io: Io, tmp: *testing.TmpDir) ![:0]u8 {
    const site = SiteDir.borrow(io, tmp.dir);
    try site.writeFile("_layouts/base.html", "<html><body>{{ content }}</body></html>");
    try site.writeFile("index.md", "---\nlayout: base\n---\nhello\n");
    try site.writeFile("about.md", "about\n");
    try site.writeFile("css/site.css", "body{}");
    return tmp.dir.realPathFileAlloc(io, ".", testing.allocator);
}

test "dev server serves pages with the reload script injected" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try testServerSite(io, &tmp);
    defer testing.allocator.free(root);

    const server = try Server.init(testing.allocator, io, root, .{ .port = 0 });
    defer server.deinit();
    try server.start();

    var c = try TestClient.connect(io, server.port);
    defer c.close();
    try c.send("GET / HTTP/1.1\r\nhost: localhost\r\n\r\n");
    try testing.expect(try c.readUntil(0, "</html>", 5000));
    try testing.expect(std.mem.startsWith(u8, c.received(), "HTTP/1.1 200 OK"));
    try testing.expect(std.mem.indexOf(u8, c.received(), "<body><p>hello</p>\n<script data-mortise-dev>") != null);
    try testing.expect(std.mem.indexOf(u8, c.received(), "/__reload?since=1") != null);

    // Same connection: keep-alive, a redirect, a static file, and a 404.
    var mark = c.len;
    try c.send("GET /about HTTP/1.1\r\nhost: localhost\r\n\r\n");
    try testing.expect(try c.readUntil(mark, "\r\n\r\n", 5000));
    try testing.expect(std.mem.indexOf(u8, c.received()[mark..], "301 Moved Permanently") != null);
    try testing.expect(std.mem.indexOf(u8, c.received()[mark..], "location: /about/") != null);

    mark = c.len;
    try c.send("GET /css/site.css HTTP/1.1\r\nhost: localhost\r\n\r\n");
    try testing.expect(try c.readUntil(mark, "body{}", 5000));
    try testing.expect(std.mem.indexOf(u8, c.received()[mark..], "text/css") != null);
    try testing.expect(std.mem.indexOf(u8, c.received()[mark..], "<script") == null);

    mark = c.len;
    try c.send("GET /missing/ HTTP/1.1\r\nhost: localhost\r\n\r\n");
    try testing.expect(try c.readUntil(mark, "not found", 5000));
    try testing.expect(std.mem.indexOf(u8, c.received()[mark..], "404 Not Found") != null);
}

test "live reload: saving a source file sends a reload event" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try testServerSite(io, &tmp);
    defer testing.allocator.free(root);

    const server = try Server.init(testing.allocator, io, root, .{ .port = 0 });
    defer server.deinit();
    var watcher = try Watcher.init(testing.allocator, io, root);
    defer watcher.deinit();
    try server.start();
    try server.watch(&watcher);

    var c = try TestClient.connect(io, server.port);
    defer c.close();
    try c.send("GET /__reload?since=1 HTTP/1.1\r\nhost: localhost\r\n\r\n");
    try testing.expect(try c.readUntil(0, "retry: 1000", 5000));
    try testing.expect(std.mem.indexOf(u8, c.received(), "text/event-stream") != null);

    const mark = c.len;
    try SiteDir.borrow(io, tmp.dir).writeFile("index.md", "---\nlayout: base\n---\nchanged\n");
    try testing.expect(try c.readUntil(mark, "event: reload\ndata: 2\n\n", 5000));

    // The new build is what gets served.
    var page = try TestClient.connect(io, server.port);
    defer page.close();
    try page.send("GET / HTTP/1.1\r\nhost: localhost\r\n\r\n");
    try testing.expect(try page.readUntil(0, "<p>changed</p>", 5000));
}

test "build errors reach the browser and the last good build keeps serving" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try testServerSite(io, &tmp);
    defer testing.allocator.free(root);
    const site = SiteDir.borrow(io, tmp.dir);

    const server = try Server.init(testing.allocator, io, root, .{ .port = 0 });
    defer server.deinit();
    var watcher = try Watcher.init(testing.allocator, io, root);
    defer watcher.deinit();
    try server.start();
    try server.watch(&watcher);

    var events = try TestClient.connect(io, server.port);
    defer events.close();
    try events.send("GET /__reload?since=1 HTTP/1.1\r\nhost: localhost\r\n\r\n");
    try testing.expect(try events.readUntil(0, "retry: 1000", 5000));

    // Break the page: a duplicate key on line 3 of index.md.
    var mark = events.len;
    try site.writeFile("index.md", "---\nlayout: base\nlayout: base\n---\nbroken\n");
    try testing.expect(try events.readUntil(mark, "event: build-error\ndata: {\"file\":\"index.md\",\"line\":3,\"message\":\"duplicate key 'layout'\"}\n\n", 5000));
    try testing.expect(std.mem.indexOf(u8, events.received()[mark..], "event: reload") == null);

    // The last good output is still served, with the overlay code in it.
    var page = try TestClient.connect(io, server.port);
    defer page.close();
    try page.send("GET / HTTP/1.1\r\nhost: localhost\r\n\r\n");
    try testing.expect(try page.readUntil(0, "</html>", 5000));
    try testing.expect(std.mem.indexOf(u8, page.received(), "<p>hello</p>") != null);
    try testing.expect(std.mem.indexOf(u8, page.received(), "mortise-error-overlay") != null);

    // A page opened while the build is broken learns about the error as soon
    // as its event stream connects.
    var late = try TestClient.connect(io, server.port);
    defer late.close();
    try late.send("GET /__reload?since=1 HTTP/1.1\r\nhost: localhost\r\n\r\n");
    try testing.expect(try late.readUntil(0, "event: build-error", 5000));

    // Fixing the error reloads the browser with the new content.
    mark = events.len;
    try site.writeFile("index.md", "---\nlayout: base\n---\nfixed\n");
    try testing.expect(try events.readUntil(mark, "event: reload", 5000));
    var fixed = try TestClient.connect(io, server.port);
    defer fixed.close();
    try fixed.send("GET / HTTP/1.1\r\nhost: localhost\r\n\r\n");
    try testing.expect(try fixed.readUntil(0, "<p>fixed</p>", 5000));
}

test "one atomic save causes exactly one rebuild" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try testServerSite(io, &tmp);
    defer testing.allocator.free(root);

    const server = try Server.init(testing.allocator, io, root, .{ .port = 0 });
    defer server.deinit();
    var watcher = try Watcher.init(testing.allocator, io, root);
    defer watcher.deinit();
    try server.start();
    try server.watch(&watcher);

    var events = try TestClient.connect(io, server.port);
    defer events.close();
    try events.send("GET /__reload?since=1 HTTP/1.1\r\nhost: localhost\r\n\r\n");
    try testing.expect(try events.readUntil(0, "retry: 1000", 5000));

    // Write a temporary file, then rename it over the original, as many
    // editors do.
    try tmp.dir.writeFile(io, .{ .sub_path = "index.md.tmp", .data = "---\nlayout: base\n---\nsaved\n" });
    try tmp.dir.rename("index.md.tmp", tmp.dir, "index.md", io);
    try testing.expect(try events.readUntil(0, "event: reload\ndata: 2\n", 5000));
    // Give any straggling events time to cause a second rebuild.
    try io.sleep(.fromMilliseconds(500), .awake);
    server.mutex.lockUncancelable(io);
    const generation = server.generation;
    const site = server.snapshot.?.site;
    server.mutex.unlock(io);
    try testing.expectEqual(@as(u64, 2), generation);
    // The rebuild was incremental: only the edited page was rendered.
    try testing.expect(!site.full);
    try testing.expectEqual(@as(usize, 1), site.rendered);
}

test "dev server serves a site with a baseurl under its prefix" {
    const io = testing.io;
    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const root = try testServerSite(io, &tmp);
    defer testing.allocator.free(root);
    try SiteDir.borrow(io, tmp.dir).writeFile("_config.yml", "baseurl: /blog\n");

    const server = try Server.init(testing.allocator, io, root, .{ .port = 0 });
    defer server.deinit();
    try server.start();

    var c = try TestClient.connect(io, server.port);
    defer c.close();
    try c.send("GET / HTTP/1.1\r\nhost: localhost\r\n\r\n");
    try testing.expect(try c.readUntil(0, "\r\n\r\n", 5000));
    try testing.expect(std.mem.indexOf(u8, c.received(), "location: /blog/") != null);

    var mark = c.len;
    try c.send("GET /blog/ HTTP/1.1\r\nhost: localhost\r\n\r\n");
    try testing.expect(try c.readUntil(mark, "<p>hello</p>", 5000));

    mark = c.len;
    try c.send("GET /blog/about HTTP/1.1\r\nhost: localhost\r\n\r\n");
    try testing.expect(try c.readUntil(mark, "location: /blog/about/", 5000));

    mark = c.len;
    try c.send("GET /css/site.css HTTP/1.1\r\nhost: localhost\r\n\r\n");
    try testing.expect(try c.readUntil(mark, "not found", 5000));
}
