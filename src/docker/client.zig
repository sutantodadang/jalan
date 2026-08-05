//! Transport layer for the Docker Engine API: connects to the daemon's
//! Unix socket (or Windows named pipe) and drives src/docker/http.zig's
//! request writer / response parser over it.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("../config.zig");
const backend = @import("../backend.zig");
const http = @import("http.zig");

pub const api_prefix = "/v1.43";

pub const Client = struct { socket_path: []const u8 };

pub const Conn = struct {
    file: std.fs.File,
    pub fn close(self: Conn) void {
        self.file.close();
    }
};

// Total time budget (wall clock) to keep retrying a busy Windows named pipe
// before giving up and surfacing the original error.
const windows_pipe_retry_budget_ms: i64 = 30_000;
// Per-wait timeout passed to WaitNamedPipeW: how long it blocks for a pipe
// instance to free up before we loop around and try opening again.
const windows_pipe_wait_timeout_ms: u32 = 2000;
// Fallback pause when WaitNamedPipeW itself can't be used (path conversion
// failed) or reports no luck, so the retry loop doesn't spin hot.
const windows_pipe_sleep_ns: u64 = 50 * std.time.ns_per_ms;

// std.os.windows.kernel32 doesn't bind this — declare it locally, mirroring
// the SetConsoleOutputCP/SetConsoleCP externs in main.zig (same calling
// convention style).
extern "kernel32" fn WaitNamedPipeW(lpNamedPipeName: [*:0]const u16, nTimeOut: u32) callconv(.winapi) c_int;

/// Which `connect()` failures are worth retrying rather than surfacing
/// immediately. Under parallel job setup (several worker threads dialing the
/// daemon at once — e.g. one job's HTTP calls racing another job's slow
/// `docker pull`), a Windows named pipe reports busy/unavailable, which Zig
/// surfaces as `error.NoDevice` or `error.PipeBusy` depending on the exact
/// Win32 code path (see std/os/windows.zig: NO_MEDIA_IN_DEVICE and
/// PIPE_NOT_AVAILABLE both map to NoDevice; PIPE_BUSY maps to PipeBusy).
/// Deliberately does NOT include AccessDenied: unlike the other two, Windows
/// doesn't document that as a *transient* busy-pipe signal, so treating it
/// as retryable risked masking a real permissions failure.
fn isRetryablePipeError(err: anyerror) bool {
    return switch (err) {
        error.NoDevice, error.PipeBusy => true,
        else => false,
    };
}

/// Generic busy-resource retry driver: calls `attempt`, and while it fails
/// with a retryable error (per `isRetryablePipeError`) and the elapsed time
/// (per `nowMs`) is still under `budget_ms`, calls `waitFn` and tries again.
/// `Ctx`/`T` are generic and `nowMs`/`waitFn` are injected so this is
/// unit-testable without a real named pipe: a fake `attempt` can fail N times
/// then succeed, a fake clock can fast-forward past the budget, etc. (see
/// tests below). The real Windows path instantiates this with `T = std.fs.File`.
fn retryBusyResource(
    comptime Ctx: type,
    comptime T: type,
    ctx: Ctx,
    attempt: *const fn (Ctx) anyerror!T,
    nowMs: *const fn () i64,
    waitFn: *const fn (Ctx) void,
    budget_ms: i64,
) !T {
    const start = nowMs();
    while (true) {
        return attempt(ctx) catch |err| {
            if (!isRetryablePipeError(err)) return err;
            if (nowMs() - start >= budget_ms) return err;
            waitFn(ctx);
            continue;
        };
    }
}

const WindowsPipeCtx = struct { socket_path: []const u8 };

fn windowsPipeAttempt(ctx: WindowsPipeCtx) anyerror!std.fs.File {
    return std.fs.openFileAbsolute(ctx.socket_path, .{ .mode = .read_write });
}

fn windowsPipeWait(ctx: WindowsPipeCtx) void {
    // Pipe paths (`\\.\pipe\...`) are short; a fixed stack buffer avoids
    // needing an allocator here (`connect` doesn't take one). On conversion
    // failure, just fall back to a short sleep-retry rather than failing the
    // whole connect attempt over a path-encoding edge case.
    var wbuf: [260]u16 = undefined;
    const wlen = std.unicode.utf8ToUtf16Le(wbuf[0 .. wbuf.len - 1], ctx.socket_path) catch {
        std.Thread.sleep(windows_pipe_sleep_ns);
        return;
    };
    wbuf[wlen] = 0;
    const wpath: [:0]const u16 = wbuf[0..wlen :0];
    if (WaitNamedPipeW(wpath.ptr, windows_pipe_wait_timeout_ms) == 0) {
        // WaitNamedPipeW itself errored/timed out (returns 0 = FALSE) — its
        // return doesn't guarantee a slot is actually free anyway, so either
        // way just fall back to a short sleep before the next open attempt.
        std.Thread.sleep(windows_pipe_sleep_ns);
    }
}

fn connectWindows(socket_path: []const u8) !std.fs.File {
    return retryBusyResource(
        WindowsPipeCtx,
        std.fs.File,
        .{ .socket_path = socket_path },
        &windowsPipeAttempt,
        &std.time.milliTimestamp,
        &windowsPipeWait,
        windows_pipe_retry_budget_ms,
    );
}

pub fn connect(c: Client) !Conn {
    if (builtin.os.tag == .windows) {
        const f = try connectWindows(c.socket_path);
        return .{ .file = f };
    } else {
        const stream = try std.net.connectUnixSocket(c.socket_path);
        return .{ .file = .{ .handle = stream.handle } };
    }
}

pub fn request(alloc: std.mem.Allocator, c: Client, req: http.Request) !http.Response {
    const conn = try connect(c);
    defer conn.close();
    const raw = try http.writeRequest(alloc, req);
    try conn.file.writeAll(raw);
    var buf: [4096]u8 = undefined;
    var file_reader = conn.file.reader(&buf);
    return http.parseResponse(alloc, &file_reader.interface);
}

pub fn ping(alloc: std.mem.Allocator, c: Client) bool {
    const resp = request(alloc, c, .{ .method = "GET", .path = "/_ping" }) catch return false;
    if (resp.status != 200) return false;
    const info = request(alloc, c, .{ .method = "GET", .path = api_prefix ++ "/info" }) catch return false;
    if (info.status != 200) return false;
    const parsed = std.json.parseFromSliceLeaky(struct { OSType: []const u8 }, alloc, info.body, .{ .ignore_unknown_fields = true }) catch return false;
    return std.mem.eql(u8, parsed.OSType, "linux");
}

/// Parses a `DOCKER_HOST`-style value into a local socket/pipe path.
/// Supports `unix://` (Unix domain socket path, passed through as-is) and
/// `npipe://` (Windows named pipe; the `//./pipe/...` remainder uses forward
/// slashes, which get converted to backslashes to form a real pipe path like
/// `\\.\pipe\docker_engine`). Any other scheme (e.g. `tcp://`) is not a local
/// socket, so returns null. Needs an allocator because the npipe branch
/// builds a new backslash-converted string.
pub fn socketFromEnvValue(alloc: std.mem.Allocator, v: []const u8) ?[]const u8 {
    const unix_prefix = "unix://";
    const npipe_prefix = "npipe://";
    if (std.mem.startsWith(u8, v, unix_prefix)) {
        return v[unix_prefix.len..];
    }
    if (std.mem.startsWith(u8, v, npipe_prefix)) {
        const rest = v[npipe_prefix.len..];
        const buf = alloc.alloc(u8, rest.len) catch return null;
        for (rest, 0..) |ch, i| buf[i] = if (ch == '/') '\\' else ch;
        return buf;
    }
    return null;
}

pub fn detectSocket(alloc: std.mem.Allocator, cfg: config.Config) ?[]const u8 {
    if (cfg.docker_socket) |s| return s;
    if (std.process.getEnvVarOwned(alloc, "DOCKER_HOST") catch null) |v| {
        if (socketFromEnvValue(alloc, v)) |s| return s;
    }
    return if (builtin.os.tag == .windows) "\\\\.\\pipe\\docker_engine" else "/var/run/docker.sock";
}

/// Extracts a human-readable message from a Docker daemon error body
/// (`{"message":"..."}`); falls back to the raw body if it doesn't parse.
fn daemonErrorMessage(alloc: std.mem.Allocator, body: []const u8) []const u8 {
    const parsed = std.json.parseFromSliceLeaky(struct { message: []const u8 }, alloc, body, .{ .ignore_unknown_fields = true }) catch return body;
    return parsed.message;
}

/// Sends `req` and treats any non-2xx status as a Docker API error, capturing
/// the daemon's message into `err`. Callers that need to treat a specific
/// non-2xx status as a non-error case (e.g. `imageExists`'s 404) should call
/// `request` directly instead.
fn apiCall(alloc: std.mem.Allocator, c: Client, req: http.Request, err: *?[]const u8) !http.Response {
    const resp = try request(alloc, c, req);
    if (resp.status >= 300) {
        err.* = daemonErrorMessage(alloc, resp.body);
        return error.DockerApi;
    }
    return resp;
}

/// Minimal percent-encoding for a URL query-string value: keeps
/// alphanumerics and a handful of safe punctuation marks (including `/`,
/// since container paths are usually multi-segment), escapes everything
/// else as `%XX`.
fn urlEncode(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |ch| {
        const safe = std.ascii.isAlphanumeric(ch) or switch (ch) {
            '-', '_', '.', '~', '/' => true,
            else => false,
        };
        if (safe) {
            try out.append(alloc, ch);
        } else {
            try out.print(alloc, "%{X:0>2}", .{ch});
        }
    }
    return out.toOwnedSlice(alloc);
}

/// Splits an image reference like `busybox:latest` into name/tag. A `:` is
/// only treated as the tag separator when nothing after it contains a `/`,
/// so registry host:port prefixes (`myregistry:5000/image`) aren't
/// misparsed. Defaults to `latest` when no tag is present.
fn splitImageRef(image: []const u8) struct { name: []const u8, tag: []const u8 } {
    if (std.mem.lastIndexOfScalar(u8, image, ':')) |i| {
        const after = image[i + 1 ..];
        if (std.mem.indexOfScalar(u8, after, '/') == null) {
            return .{ .name = image[0..i], .tag = after };
        }
    }
    return .{ .name = image, .tag = "latest" };
}

/// `GET {prefix}/images/{name}/json`: true on 200, false on 404, error on
/// anything else (404 is an expected outcome here, not an API error).
pub fn imageExists(alloc: std.mem.Allocator, c: Client, image: []const u8, err: *?[]const u8) !bool {
    const path = try std.fmt.allocPrint(alloc, "{s}/images/{s}/json", .{ api_prefix, image });
    const resp = try request(alloc, c, .{ .method = "GET", .path = path });
    if (resp.status == 200) return true;
    if (resp.status == 404) return false;
    err.* = daemonErrorMessage(alloc, resp.body);
    return error.DockerApi;
}

/// Resolve an image reference (including a mutable tag) to Docker's immutable
/// content ID. Cache keys use this only after setup has ensured the image is
/// present locally.
pub fn imageIdentity(alloc: std.mem.Allocator, c: Client, image: []const u8, err: *?[]const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(alloc, "{s}/images/{s}/json", .{ api_prefix, image });
    const resp = try apiCall(alloc, c, .{ .method = "GET", .path = path }, err);
    const parsed = std.json.parseFromSliceLeaky(struct { Id: []const u8 }, alloc, resp.body, .{ .ignore_unknown_fields = true }) catch return error.DockerApi;
    return parsed.Id;
}

/// `POST {prefix}/images/create?fromImage=<name>&tag=<tag>`: body is a
/// stream of JSON-lines progress events. Reads the full body, then emits one
/// log line per unique `status` string (in first-seen order).
pub fn imagePull(alloc: std.mem.Allocator, c: Client, image: []const u8, log: ?backend.LogFn, err: *?[]const u8) !void {
    const ref = splitImageRef(image);
    const path = try std.fmt.allocPrint(alloc, "{s}/images/create?fromImage={s}&tag={s}", .{ api_prefix, ref.name, ref.tag });
    const resp = try apiCall(alloc, c, .{ .method = "POST", .path = path }, err);

    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var lines = std.mem.splitScalar(u8, resp.body, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = std.json.parseFromSliceLeaky(struct { status: ?[]const u8 = null }, alloc, line, .{ .ignore_unknown_fields = true }) catch continue;
        const status = parsed.status orelse continue;
        if (seen.contains(status)) continue;
        try seen.put(alloc, status, {});
        if (log) |l| l(status);
    }
}

/// `POST {prefix}/containers/create[?name=<name>]`: returns the new
/// container's id, parsed from `{"Id":"..."}`.
pub fn containerCreate(alloc: std.mem.Allocator, c: Client, spec_json: []const u8, name: ?[]const u8, err: *?[]const u8) ![]const u8 {
    const path = if (name) |n|
        try std.fmt.allocPrint(alloc, "{s}/containers/create?name={s}", .{ api_prefix, n })
    else
        try std.fmt.allocPrint(alloc, "{s}/containers/create", .{api_prefix});
    const resp = try apiCall(alloc, c, .{
        .method = "POST",
        .path = path,
        .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .body = spec_json,
    }, err);
    const parsed = std.json.parseFromSliceLeaky(struct { Id: []const u8 }, alloc, resp.body, .{ .ignore_unknown_fields = true }) catch return error.DockerApi;
    return parsed.Id;
}

/// `POST {prefix}/containers/{id}/start`.
pub fn containerStart(alloc: std.mem.Allocator, c: Client, id: []const u8, err: *?[]const u8) !void {
    const path = try std.fmt.allocPrint(alloc, "{s}/containers/{s}/start", .{ api_prefix, id });
    _ = try apiCall(alloc, c, .{ .method = "POST", .path = path }, err);
}

/// `DELETE {prefix}/containers/{id}?force=true`.
pub fn containerRemove(alloc: std.mem.Allocator, c: Client, id: []const u8, err: *?[]const u8) !void {
    const path = try std.fmt.allocPrint(alloc, "{s}/containers/{s}?force=true", .{ api_prefix, id });
    _ = try apiCall(alloc, c, .{ .method = "DELETE", .path = path }, err);
}

/// Poll container state until it exits. The Engine's streaming `/wait`
/// response can keep raw named-pipe connections open indefinitely on some
/// Docker Desktop versions, so inspect polling is more robust. This remains
/// unbounded because jalan has no configured step/action timeout yet and a
/// legitimate container action may run for longer than a minute.
pub fn containerWait(alloc: std.mem.Allocator, c: Client, id: []const u8, err: *?[]const u8) !i32 {
    while (true) {
        const state = try containerState(alloc, c, id, err);
        if (!state.running) return state.exit_code;
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }
}

const ContainerState = struct { running: bool, exit_code: i32 };

/// One bounded inspect poll. All request/JSON allocations die before this
/// returns, so an unbounded container wait has constant memory usage.
fn containerState(_: std.mem.Allocator, c: Client, id: []const u8, err: *?[]const u8) !ContainerState {
    var poll_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer poll_arena.deinit();
    const a = poll_arena.allocator();
    const path = try std.fmt.allocPrint(a, "{s}/containers/{s}/json", .{ api_prefix, id });
    var poll_err: ?[]const u8 = null;
    const resp = apiCall(a, c, .{ .method = "GET", .path = path }, &poll_err) catch |e| {
        err.* = "docker container inspect failed";
        return e;
    };
    const parsed = std.json.parseFromSliceLeaky(struct {
        State: struct { Running: bool = true, ExitCode: i32 = -1 },
    }, a, resp.body, .{ .ignore_unknown_fields = true }) catch {
        err.* = "invalid docker container inspect response";
        return error.DockerApi;
    };
    return .{ .running = parsed.State.Running, .exit_code = parsed.State.ExitCode };
}

/// `POST {prefix}/networks/create`: returns the new network's id.
pub fn networkCreate(alloc: std.mem.Allocator, c: Client, name: []const u8, err: *?[]const u8) ![]const u8 {
    const path = try std.fmt.allocPrint(alloc, "{s}/networks/create", .{api_prefix});
    const body = try std.fmt.allocPrint(alloc, "{{\"Name\":\"{s}\"}}", .{name});
    const resp = try apiCall(alloc, c, .{
        .method = "POST",
        .path = path,
        .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .body = body,
    }, err);
    const parsed = std.json.parseFromSliceLeaky(struct { Id: []const u8 }, alloc, resp.body, .{ .ignore_unknown_fields = true }) catch return error.DockerApi;
    return parsed.Id;
}

/// `DELETE {prefix}/networks/{id}`.
pub fn networkRemove(alloc: std.mem.Allocator, c: Client, id: []const u8, err: *?[]const u8) !void {
    const path = try std.fmt.allocPrint(alloc, "{s}/networks/{s}", .{ api_prefix, id });
    _ = try apiCall(alloc, c, .{ .method = "DELETE", .path = path }, err);
}

/// Pure parse of a `GET {prefix}/containers/{id}/json` body down to the
/// container's health status. `null` means the image has no `HEALTHCHECK`
/// configured (no `State.Health` object at all) — the caller should treat
/// that as "nothing to wait for", not as an error.
fn parseHealthStatus(alloc: std.mem.Allocator, body: []const u8) !?[]const u8 {
    const Parsed = struct {
        State: struct {
            Health: ?struct { Status: []const u8 } = null,
        } = .{},
    };
    const parsed = std.json.parseFromSliceLeaky(Parsed, alloc, body, .{ .ignore_unknown_fields = true }) catch return error.DockerApi;
    if (parsed.State.Health) |h| return h.Status;
    return null;
}

/// `GET {prefix}/containers/{id}/json`, returning just the health status
/// (`.State.Health.Status`), or `null` if the container has no health check
/// configured at all.
pub fn containerInspectHealth(alloc: std.mem.Allocator, c: Client, id: []const u8, err: *?[]const u8) !?[]const u8 {
    const path = try std.fmt.allocPrint(alloc, "{s}/containers/{s}/json", .{ api_prefix, id });
    const resp = try apiCall(alloc, c, .{ .method = "GET", .path = path }, err);
    return parseHealthStatus(alloc, resp.body);
}

/// `GET {prefix}/containers/{id}/logs?stdout=1&stderr=1`: raw response body
/// for a non-tty container is Docker's multiplexed stdout/stderr stream
/// (same frame format as `execRun`'s attach stream) — pass the result to
/// `demuxFrames` to split it. Used for one-shot `docker://` actions, whose
/// output isn't available via `exec` (there's no long-lived container to
/// exec into — the action *is* the container's own entrypoint/cmd).
pub fn containerLogs(alloc: std.mem.Allocator, c: Client, id: []const u8, err: *?[]const u8) ![]u8 {
    const path = try std.fmt.allocPrint(alloc, "{s}/containers/{s}/logs?stdout=1&stderr=1", .{ api_prefix, id });
    const resp = try apiCall(alloc, c, .{ .method = "GET", .path = path }, err);
    return resp.body;
}

test "parseHealthStatus: no Health object returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const status = try parseHealthStatus(a, "{\"State\":{\"Running\":true}}");
    try std.testing.expectEqual(@as(?[]const u8, null), status);
}

test "parseHealthStatus: Health present returns Status" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const status = try parseHealthStatus(a, "{\"State\":{\"Health\":{\"Status\":\"healthy\"}}}");
    try std.testing.expectEqualStrings("healthy", status.?);
}

/// `PUT {prefix}/containers/{id}/archive?path=<url-encoded>`: uploads a tar
/// stream (see `tarSingleFile`) to be extracted at `path_in_container`.
pub fn putArchive(alloc: std.mem.Allocator, c: Client, id: []const u8, path_in_container: []const u8, tar_bytes: []const u8, err: *?[]const u8) !void {
    const encoded_path = try urlEncode(alloc, path_in_container);
    const path = try std.fmt.allocPrint(alloc, "{s}/containers/{s}/archive?path={s}", .{ api_prefix, id, encoded_path });
    _ = try apiCall(alloc, c, .{
        .method = "PUT",
        .path = path,
        .headers = &.{.{ .name = "Content-Type", .value = "application/x-tar" }},
        .body = tar_bytes,
    }, err);
}

/// Writes one 512-byte ustar header into `hdr` for an entry named `name`
/// with the given `mode`, `size`, and `typeflag` ('0' regular file, '5'
/// directory). Fields: octal mode/uid/gid/size/mtime, a space-blanked
/// checksum field while the checksum itself is computed, then ustar magic
/// ("ustar\x00" + version "00"). Names up to 100 bytes go straight into the
/// name field (bytes 0..100). Longer names use ustar's ``prefix`` extension:
/// split at the '/' that leaves the smallest possible tail (so the tail is
/// as close to the 100-byte limit as the split allows, keeping the head —
/// which must fit in the 155-byte prefix field at bytes 345..500 — as short
/// as possible); reconstructed by readers as `prefix + "/" + name`. Returns
/// `error.TarNameTooLong` when no split satisfies both field limits (e.g. a
/// path segment longer than 100 bytes on its own).
fn tarWriteHeader(hdr: *[512]u8, name: []const u8, mode: u32, size: usize, typeflag: u8) !void {
    @memset(hdr, 0);
    if (name.len <= 100) {
        @memcpy(hdr[0..name.len], name);
    } else {
        // Smallest slash index that still keeps the tail (everything after
        // it) within the 100-byte name field.
        const min_slash: usize = if (name.len > 101) name.len - 101 else 0;
        var chosen: ?usize = null;
        var search_from: usize = 0;
        while (std.mem.indexOfScalarPos(u8, name, search_from, '/')) |slash| {
            if (slash >= min_slash) {
                chosen = slash;
                break;
            }
            search_from = slash + 1;
        }
        const slash = chosen orelse return error.TarNameTooLong;
        const head = name[0..slash];
        const tail = name[slash + 1 ..];
        if (head.len > 155 or tail.len > 100) return error.TarNameTooLong;
        @memcpy(hdr[0..tail.len], tail);
        @memcpy(hdr[345 .. 345 + head.len], head);
    }
    _ = std.fmt.bufPrint(hdr[100..108], "{o:0>7}", .{mode}) catch unreachable;
    _ = std.fmt.bufPrint(hdr[108..116], "{o:0>7}", .{0}) catch unreachable; // uid
    _ = std.fmt.bufPrint(hdr[116..124], "{o:0>7}", .{0}) catch unreachable; // gid
    _ = std.fmt.bufPrint(hdr[124..136], "{o:0>11}", .{size}) catch unreachable;
    _ = std.fmt.bufPrint(hdr[136..148], "{o:0>11}", .{0}) catch unreachable; // mtime
    @memset(hdr[148..156], ' '); // checksum placeholder
    hdr[156] = typeflag;
    @memcpy(hdr[257..263], "ustar\x00");
    @memcpy(hdr[263..265], "00");
    var sum: usize = 0;
    for (hdr) |b| sum += b;
    _ = std.fmt.bufPrint(hdr[148..155], "{o:0>6}\x00", .{sum}) catch unreachable;
}

/// Builds a minimal ustar archive containing a single file: a 512-byte
/// header, the content padded to a 512-byte boundary, and two trailing
/// 512-byte zero blocks (end-of-archive marker).
pub fn tarSingleFile(alloc: std.mem.Allocator, name: []const u8, contents: []const u8, mode: u32) ![]u8 {
    const n_blocks = (contents.len + 511) / 512;
    const total = 512 + n_blocks * 512 + 1024;
    const buf = try alloc.alloc(u8, total);
    @memset(buf, 0);
    try tarWriteHeader(buf[0..512], name, mode, contents.len, '0');
    @memcpy(buf[512 .. 512 + contents.len], contents);
    return buf;
}

/// Builds a ustar archive of an entire directory tree, rooted under
/// `root_name` — extracting the result into `/tmp/jalan-actions` (see
/// `stageActionDir` in `backend/docker.zig`) produces
/// `/tmp/jalan-actions/<root_name>/...`, mirroring the action's own on-disk
/// layout so its `runs.main` path resolves the same way it would on a real
/// GitHub-hosted runner. Emits a leading directory entry for `root_name`
/// itself, then one entry per walked file/directory (tar entry names always
/// use '/' regardless of the host path separator — tar is a Unix format, and
/// `std.fs.path.join`'s walker output uses the host separator on Windows).
/// Files are capped at 50MB each (action distributions don't ship anything
/// larger; a runaway read shouldn't exhaust host memory) — exceeding that
/// surfaces `error.FileTooBig`. Symlinks and other non-file/non-directory
/// entries are skipped silently: action dists don't rely on them, and
/// preserving them through Docker's archive-extract endpoint has its own
/// portability quirks not worth taking on here.
pub fn tarDirectory(alloc: std.mem.Allocator, abs_dir: []const u8, root_name: []const u8) ![]u8 {
    const max_file_bytes: usize = 50 * 1024 * 1024;
    const zero_block = [_]u8{0} ** 512;

    var out: std.ArrayList(u8) = .empty;
    var hdr: [512]u8 = undefined;

    try tarWriteHeader(&hdr, root_name, 0o755, 0, '5');
    try out.appendSlice(alloc, &hdr);

    var dir = try std.fs.openDirAbsolute(abs_dir, .{ .iterate = true });
    defer dir.close();
    var walker = try dir.walk(alloc);
    defer walker.deinit();

    while (try walker.next()) |entry| {
        switch (entry.kind) {
            .file, .directory => {},
            else => continue,
        }
        const rel = try alloc.alloc(u8, entry.path.len);
        for (entry.path, 0..) |ch, i| rel[i] = if (ch == '\\') '/' else ch;
        const tar_name = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ root_name, rel });

        if (entry.kind == .directory) {
            try tarWriteHeader(&hdr, tar_name, 0o755, 0, '5');
            try out.appendSlice(alloc, &hdr);
            continue;
        }

        const contents = try entry.dir.readFileAlloc(alloc, entry.basename, max_file_bytes);
        try tarWriteHeader(&hdr, tar_name, 0o755, contents.len, '0');
        try out.appendSlice(alloc, &hdr);
        try out.appendSlice(alloc, contents);
        const pad = (512 - (contents.len % 512)) % 512;
        if (pad > 0) try out.appendSlice(alloc, zero_block[0..pad]);
    }

    try out.appendSlice(alloc, &zero_block);
    try out.appendSlice(alloc, &zero_block);
    return out.toOwnedSlice(alloc);
}

/// Appends a JSON-quoted, escaped copy of `s` to `out`. Copied from
/// `ir.jsonStr` rather than imported, since this module doesn't otherwise
/// depend on the pipeline IR.
fn jsonStrAppend(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try out.append(alloc, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(alloc, "\\\""),
        '\\' => try out.appendSlice(alloc, "\\\\"),
        '\n' => try out.appendSlice(alloc, "\\n"),
        '\r' => try out.appendSlice(alloc, "\\r"),
        '\t' => try out.appendSlice(alloc, "\\t"),
        else => if (c < 0x20) {
            try out.appendSlice(alloc, try std.fmt.allocPrint(alloc, "\\u{x:0>4}", .{c}));
        } else try out.append(alloc, c),
    };
    try out.append(alloc, '"');
}

/// Splits a Docker attach/exec multiplexed stream into stdout/stderr.
/// Frame format: `[stream_type u8, 0,0,0, size u32 big-endian, payload...]`.
/// Type 1 -> stdout, 2 -> stderr, 0 (stdin) is ignored. A truncated trailing
/// frame just keeps whatever was already parsed.
pub fn demuxFrames(alloc: std.mem.Allocator, body: []const u8) !struct { stdout: []u8, stderr: []u8 } {
    var out: std.ArrayList(u8) = .empty;
    var errs: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i + 8 <= body.len) {
        const kind = body[i];
        const size = std.mem.readInt(u32, body[i + 4 ..][0..4], .big);
        i += 8;
        const end = @min(i + size, body.len);
        switch (kind) {
            1 => try out.appendSlice(alloc, body[i..end]),
            2 => try errs.appendSlice(alloc, body[i..end]),
            else => {},
        }
        i = end;
    }
    return .{ .stdout = try out.toOwnedSlice(alloc), .stderr = try errs.toOwnedSlice(alloc) };
}

pub const ExecResult = struct { exit_code: i32, stdout: []u8, stderr: []u8 };

/// Pure poll-decision helper for `execRun`'s exit-code loop, factored out so
/// it's unit-testable without a daemon. Given the latest exec-inspect
/// response fields and whether the poll budget is exhausted, decides:
/// - once `running` is false: the reported `code`, or `-1` if Docker gave no
///   `ExitCode` (an unexpected-but-possible shape — `-1` signals
///   "unknown/failed", not the misleading default of `0`/success);
/// - while `running` is still true and the poll budget is exhausted:
///   `error.ExecTimeout`, so a hung exec can't silently report exit 0;
/// - while `running` is still true and there's budget left: `null`, telling
///   the caller to sleep and poll again.
fn resolveExit(running: bool, code: ?i32, exhausted: bool) !?i32 {
    if (!running) return code orelse -1;
    if (exhausted) return error.ExecTimeout;
    return null;
}

test "resolveExit: running=false with code returns the code" {
    try std.testing.expectEqual(@as(?i32, 7), try resolveExit(false, 7, false));
}

test "resolveExit: running=false with no ExitCode returns -1, not 0" {
    try std.testing.expectEqual(@as(?i32, -1), try resolveExit(false, null, false));
}

test "resolveExit: running=true and exhausted returns error.ExecTimeout" {
    try std.testing.expectError(error.ExecTimeout, resolveExit(true, null, true));
}

test "resolveExit: running=true with budget left returns null (keep polling)" {
    try std.testing.expectEqual(@as(?i32, null), try resolveExit(true, null, false));
}

/// Runs `cmd` inside an already-running container via the Docker exec API:
/// `POST {prefix}/containers/{id}/exec` to create, `POST {prefix}/exec/{id}/start`
/// to run it (the response body is the raw multiplexed stdout/stderr stream,
/// demuxed with `demuxFrames`), then polls `GET {prefix}/exec/{id}/json` (up
/// to 50x100ms while `Running`) for the exit code via `resolveExit`. If the
/// exec is still `Running` after the full poll budget, returns
/// `error.ExecTimeout` (with `err.*` set) rather than reporting a fabricated
/// success — a hung exec must not read as exit code 0 downstream.
pub fn execRun(alloc: std.mem.Allocator, c: Client, container_id: []const u8, cmd: []const []const u8, env: []const []const u8, workdir: ?[]const u8, err: *?[]const u8) !ExecResult {
    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(alloc, "{\"AttachStdout\":true,\"AttachStderr\":true,\"Cmd\":[");
    for (cmd, 0..) |arg, i| {
        if (i > 0) try body.append(alloc, ',');
        try jsonStrAppend(&body, alloc, arg);
    }
    try body.appendSlice(alloc, "],\"Env\":[");
    for (env, 0..) |kv, i| {
        if (i > 0) try body.append(alloc, ',');
        try jsonStrAppend(&body, alloc, kv);
    }
    try body.append(alloc, ']');
    if (workdir) |wd| {
        try body.appendSlice(alloc, ",\"WorkingDir\":");
        try jsonStrAppend(&body, alloc, wd);
    }
    try body.append(alloc, '}');

    const create_path = try std.fmt.allocPrint(alloc, "{s}/containers/{s}/exec", .{ api_prefix, container_id });
    const create_resp = try apiCall(alloc, c, .{
        .method = "POST",
        .path = create_path,
        .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .body = try body.toOwnedSlice(alloc),
    }, err);
    const created = std.json.parseFromSliceLeaky(struct { Id: []const u8 }, alloc, create_resp.body, .{ .ignore_unknown_fields = true }) catch return error.DockerApi;
    const eid = created.Id;

    const start_path = try std.fmt.allocPrint(alloc, "{s}/exec/{s}/start", .{ api_prefix, eid });
    const start_resp = try apiCall(alloc, c, .{
        .method = "POST",
        .path = start_path,
        .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .body = "{\"Detach\":false,\"Tty\":false}",
    }, err);
    const demuxed = try demuxFrames(alloc, start_resp.body);

    const inspect_path = try std.fmt.allocPrint(alloc, "{s}/exec/{s}/json", .{ api_prefix, eid });
    const max_poll_attempts: usize = 50;
    var exit_code: i32 = -1;
    var attempt: usize = 0;
    while (attempt < max_poll_attempts) : (attempt += 1) {
        const inspect_resp = try apiCall(alloc, c, .{ .method = "GET", .path = inspect_path }, err);
        const parsed = std.json.parseFromSliceLeaky(struct { ExitCode: ?i32 = null, Running: bool = false }, alloc, inspect_resp.body, .{ .ignore_unknown_fields = true }) catch return error.DockerApi;
        const exhausted = attempt == max_poll_attempts - 1;
        const resolved = resolveExit(parsed.Running, parsed.ExitCode, exhausted) catch |e| {
            err.* = try std.fmt.allocPrint(alloc, "exec still running after 5s poll window", .{});
            return e;
        };
        if (resolved) |code| {
            exit_code = code;
            break;
        }
        std.Thread.sleep(100 * std.time.ns_per_ms);
    }

    return .{ .exit_code = exit_code, .stdout = demuxed.stdout, .stderr = demuxed.stderr };
}

fn execIsRunning(_: std.mem.Allocator, c: Client, exec_id: []const u8, err: *?[]const u8) !bool {
    var poll_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer poll_arena.deinit();
    const alloc = poll_arena.allocator();
    const inspect_path = try std.fmt.allocPrint(alloc, "{s}/exec/{s}/json", .{ api_prefix, exec_id });
    var poll_err: ?[]const u8 = null;
    const resp = apiCall(alloc, c, .{ .method = "GET", .path = inspect_path }, &poll_err) catch |e| {
        err.* = "docker exec inspect failed";
        return e;
    };
    const parsed = std.json.parseFromSliceLeaky(struct { Running: bool = false }, alloc, resp.body, .{ .ignore_unknown_fields = true }) catch {
        err.* = "invalid docker exec inspect response";
        return error.DockerApi;
    };
    return parsed.Running;
}

extern "kernel32" fn PeekNamedPipe(
    handle: std.os.windows.HANDLE,
    buffer: ?*anyopaque,
    buffer_size: std.os.windows.DWORD,
    bytes_read: ?*std.os.windows.DWORD,
    bytes_available: ?*std.os.windows.DWORD,
    bytes_left: ?*std.os.windows.DWORD,
) callconv(.winapi) std.os.windows.BOOL;

/// Returns null once Docker has closed the hijacked named pipe.
fn windowsPipeAvailable(file: std.fs.File) !?usize {
    var available: std.os.windows.DWORD = 0;
    if (PeekNamedPipe(file.handle, null, 0, null, &available, null) == 0) {
        return switch (std.os.windows.GetLastError()) {
            .BROKEN_PIPE, .HANDLE_EOF => null,
            else => |win_err| std.os.windows.unexpectedError(win_err),
        };
    }
    return available;
}

fn readUpgradeHeader(alloc: std.mem.Allocator, file: std.fs.File) ![]u8 {
    var header: std.ArrayList(u8) = .empty;
    var one: [1]u8 = undefined;
    while (header.items.len < 64 * 1024) {
        const n = try file.read(&one);
        if (n == 0) return error.DockerApi;
        try header.append(alloc, one[0]);
        if (std.mem.endsWith(u8, header.items, "\r\n\r\n") or std.mem.endsWith(u8, header.items, "\n\n"))
            return header.toOwnedSlice(alloc);
    }
    return error.DockerApi;
}

/// Interactive Docker exec over an HTTP-hijacked connection. Docker's TTY
/// stream is unframed, so stdout/stderr can be copied directly. Input stays
/// line-oriented (matching jalan's debugger); after each line we inspect the
/// exec so an `exit` command returns control to the failure prompt.
pub fn execInteractive(
    alloc: std.mem.Allocator,
    c: Client,
    container_id: []const u8,
    cmd: []const []const u8,
    env: []const []const u8,
    workdir: ?[]const u8,
    err: *?[]const u8,
) !void {
    var body: std.ArrayList(u8) = .empty;
    try body.appendSlice(alloc, "{\"AttachStdin\":true,\"AttachStdout\":true,\"AttachStderr\":true,\"Tty\":true,\"Cmd\":[");
    for (cmd, 0..) |arg, i| {
        if (i > 0) try body.append(alloc, ',');
        try jsonStrAppend(&body, alloc, arg);
    }
    try body.appendSlice(alloc, "],\"Env\":[");
    for (env, 0..) |kv, i| {
        if (i > 0) try body.append(alloc, ',');
        try jsonStrAppend(&body, alloc, kv);
    }
    try body.append(alloc, ']');
    if (workdir) |wd| {
        try body.appendSlice(alloc, ",\"WorkingDir\":");
        try jsonStrAppend(&body, alloc, wd);
    }
    try body.append(alloc, '}');

    const create_path = try std.fmt.allocPrint(alloc, "{s}/containers/{s}/exec", .{ api_prefix, container_id });
    const create_resp = try apiCall(alloc, c, .{
        .method = "POST",
        .path = create_path,
        .headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .body = try body.toOwnedSlice(alloc),
    }, err);
    const created = std.json.parseFromSliceLeaky(struct { Id: []const u8 }, alloc, create_resp.body, .{ .ignore_unknown_fields = true }) catch return error.DockerApi;

    const conn = try connect(c);
    defer conn.close();
    const start_path = try std.fmt.allocPrint(alloc, "{s}/exec/{s}/start", .{ api_prefix, created.Id });
    const raw = try http.writeRequest(alloc, .{
        .method = "POST",
        .path = start_path,
        .headers = &.{
            .{ .name = "Content-Type", .value = "application/json" },
            .{ .name = "Connection", .value = "Upgrade" },
            .{ .name = "Upgrade", .value = "tcp" },
        },
        .body = "{\"Detach\":false,\"Tty\":true}",
    });
    try conn.file.writeAll(raw);
    const header = try readUpgradeHeader(alloc, conn.file);
    if (!std.mem.startsWith(u8, header, "HTTP/1.1 101") and !std.mem.startsWith(u8, header, "HTTP/1.1 200")) {
        err.* = "docker exec stream upgrade failed";
        return error.DockerApi;
    }

    // Windows' async poller currently logs ERROR_HANDLE_EOF as an unexpected
    // error for named pipes. Peek/read the Docker pipe there instead: the
    // synchronous ReadFile wrapper handles both HANDLE_EOF and BROKEN_PIPE as
    // a clean zero-byte read. Interactive input is a TTY-only operation.
    if (builtin.os.tag == .windows) {
        const Input = enum { stdin };
        const stdin = std.fs.File.stdin();
        var input_poller = std.Io.poll(alloc, Input, .{ .stdin = stdin });
        defer input_poller.deinit();
        var docker_buf: [4096]u8 = undefined;
        while (try execIsRunning(alloc, c, created.Id, err)) {
            const available = (try windowsPipeAvailable(conn.file)) orelse break;
            if (available > 0) {
                const n = try conn.file.read(docker_buf[0..@min(available, docker_buf.len)]);
                if (n == 0) break;
                try std.fs.File.stdout().writeAll(docker_buf[0..n]);
            }
            if (stdin.isTty()) {
                _ = try input_poller.pollTimeout(25 * std.time.ns_per_ms);
                const from_stdin = input_poller.reader(.stdin).buffered();
                if (from_stdin.len > 0) {
                    try conn.file.writeAll(from_stdin);
                    input_poller.reader(.stdin).toss(from_stdin.len);
                }
            } else {
                std.Thread.sleep(25 * std.time.ns_per_ms);
            }
        }
        // Flush bytes Docker queued immediately before marking the exec done.
        while (((try windowsPipeAvailable(conn.file)) orelse 0) > 0) {
            const available = (try windowsPipeAvailable(conn.file)) orelse break;
            const n = try conn.file.read(docker_buf[0..@min(available, docker_buf.len)]);
            if (n == 0) break;
            try std.fs.File.stdout().writeAll(docker_buf[0..n]);
        }
        return;
    }

    // Poll stdin and the hijacked Docker stream together. This preserves raw
    // terminal control bytes and, critically, checks remote completion even
    // while the user is not typing, so a shell that exits asynchronously
    // cannot leave jalan blocked on the next stdin line.
    const Stream = enum { stdin, docker };
    var poller = std.Io.poll(alloc, Stream, .{ .stdin = std.fs.File.stdin(), .docker = conn.file });
    defer poller.deinit();
    while (true) {
        const alive = try poller.pollTimeout(50 * std.time.ns_per_ms);
        const from_docker = poller.reader(.docker).buffered();
        if (from_docker.len > 0) {
            try std.fs.File.stdout().writeAll(from_docker);
            poller.reader(.docker).toss(from_docker.len);
        }
        const from_stdin = poller.reader(.stdin).buffered();
        if (from_stdin.len > 0) {
            try conn.file.writeAll(from_stdin);
            poller.reader(.stdin).toss(from_stdin.len);
        }
        if (!alive or !(try execIsRunning(alloc, c, created.Id, err))) break;
    }
}

test "detectSocket precedence: config over default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const cfg = config.Config{ .docker_socket = "/tmp/custom.sock" };
    try std.testing.expectEqualStrings("/tmp/custom.sock", detectSocket(a, cfg).?);

    const default_socket = detectSocket(a, config.Config{}).?;
    if (builtin.os.tag == .windows) {
        try std.testing.expect(std.mem.indexOf(u8, default_socket, "docker_engine") != null);
    } else {
        try std.testing.expectEqualStrings("/var/run/docker.sock", default_socket);
    }
}

test "ping against live daemon (skips when absent)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const c = Client{ .socket_path = detectSocket(a, config.Config{}).? };
    if (!ping(a, c)) return error.SkipZigTest;
}

test "socketFromEnvValue parses DOCKER_HOST schemes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try std.testing.expectEqualStrings("/x/y.sock", socketFromEnvValue(a, "unix:///x/y.sock").?);
    try std.testing.expectEqualStrings("\\\\.\\pipe\\p", socketFromEnvValue(a, "npipe:////./pipe/p").?);
    try std.testing.expect(socketFromEnvValue(a, "tcp://127.0.0.1:2375") == null);
}

test "isRetryablePipeError: classifies busy-pipe errors, not others" {
    try std.testing.expect(isRetryablePipeError(error.NoDevice));
    try std.testing.expect(isRetryablePipeError(error.PipeBusy));
    try std.testing.expect(!isRetryablePipeError(error.AccessDenied));
    try std.testing.expect(!isRetryablePipeError(error.FileNotFound));
}

// Test seam for `retryBusyResource`: no real named pipes, just fake
// attempt/clock/wait functions driven by module-level counters (function
// pointers can't close over local state in Zig).
const RetryTestCtx = struct {};
var retry_test_attempts: usize = 0;
var retry_test_fail_count: usize = 0;
var retry_test_wait_calls: usize = 0;
var retry_test_clock_ms: i64 = 0;

fn retryTestAttempt(_: RetryTestCtx) anyerror!i32 {
    retry_test_attempts += 1;
    if (retry_test_attempts <= retry_test_fail_count) return error.PipeBusy;
    return 42;
}

fn retryTestNowMs() i64 {
    return retry_test_clock_ms;
}

fn retryTestWait(_: RetryTestCtx) void {
    retry_test_wait_calls += 1;
    retry_test_clock_ms += 100; // simulate elapsed time without a real sleep
}

test "retryBusyResource: retries a retryable error until it succeeds" {
    retry_test_attempts = 0;
    retry_test_fail_count = 3;
    retry_test_wait_calls = 0;
    retry_test_clock_ms = 0;

    const result = try retryBusyResource(RetryTestCtx, i32, .{}, &retryTestAttempt, &retryTestNowMs, &retryTestWait, 10_000);
    try std.testing.expectEqual(@as(i32, 42), result);
    try std.testing.expectEqual(@as(usize, 4), retry_test_attempts);
    try std.testing.expectEqual(@as(usize, 3), retry_test_wait_calls);
}

test "retryBusyResource: gives up once the time budget is exhausted, returns original error" {
    retry_test_attempts = 0;
    retry_test_fail_count = std.math.maxInt(usize); // never succeeds
    retry_test_wait_calls = 0;
    retry_test_clock_ms = 0;

    try std.testing.expectError(error.PipeBusy, retryBusyResource(RetryTestCtx, i32, .{}, &retryTestAttempt, &retryTestNowMs, &retryTestWait, 250));
    try std.testing.expect(retry_test_wait_calls >= 2);
}

test "retryBusyResource: non-retryable error returns immediately without waiting" {
    retry_test_wait_calls = 0;

    const AlwaysFail = struct {
        fn attempt(_: RetryTestCtx) anyerror!i32 {
            return error.AccessDenied;
        }
    };
    try std.testing.expectError(error.AccessDenied, retryBusyResource(RetryTestCtx, i32, .{}, &AlwaysFail.attempt, &retryTestNowMs, &retryTestWait, 10_000));
    try std.testing.expectEqual(@as(usize, 0), retry_test_wait_calls);
}

test "tarSingleFile produces valid ustar header" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tar = try tarSingleFile(a, "script.sh", "echo hi\n", 0o755);
    try std.testing.expectEqual(@as(usize, 512 * 4), tar.len); // header + 1 content block + 2 zero blocks
    try std.testing.expectEqualStrings("script.sh", std.mem.sliceTo(tar[0..100], 0));
    // size field (octal, offset 124, 12 bytes)
    try std.testing.expectEqualStrings("00000000010", std.mem.sliceTo(tar[124..136], 0)[0..11]);
    // checksum validates: recompute with checksum field as spaces
    var sum: usize = 0;
    for (tar[0..512], 0..) |b, i| sum += if (i >= 148 and i < 156) @as(usize, ' ') else b;
    const stored = try std.fmt.parseInt(usize, std.mem.trim(u8, std.mem.sliceTo(tar[148..156], 0), " "), 8);
    try std.testing.expectEqual(sum, stored);
}

test "tarWriteHeader splits long names into ustar prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 4 path segments of 40 bytes each (plus separators) puts the name over
    // 100 bytes but well within the 100+155 ustar-prefix budget.
    const seg = "a" ** 40;
    const name = try std.fmt.allocPrint(a, "{s}/{s}/{s}/{s}", .{ seg, seg, seg, seg });
    try std.testing.expect(name.len > 100);
    var hdr: [512]u8 = undefined;
    try tarWriteHeader(&hdr, name, 0o755, 0, '0');
    const tail = std.mem.sliceTo(hdr[0..100], 0);
    const head = std.mem.sliceTo(hdr[345..500], 0);
    try std.testing.expect(tail.len <= 100);
    try std.testing.expect(head.len <= 155);
    const rebuilt = try std.fmt.allocPrint(a, "{s}/{s}", .{ head, tail });
    try std.testing.expectEqualStrings(name, rebuilt);
    // checksum must not be left at zero (it's computed over real header bytes).
    var sum: usize = 0;
    for (hdr) |b| sum += b;
    try std.testing.expect(sum != 0);
}

test "tarWriteHeader: name over the ustar prefix budget errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A single 200-byte segment (no '/' to split on within the tail budget)
    // can never fit name(100)+prefix(155).
    const name = try alloc0(a, 200);
    var hdr: [512]u8 = undefined;
    try std.testing.expectError(error.TarNameTooLong, tarWriteHeader(&hdr, name, 0o755, 0, '0'));
}

fn alloc0(alloc: std.mem.Allocator, n: usize) ![]u8 {
    const buf = try alloc.alloc(u8, n);
    @memset(buf, 'x');
    return buf;
}

test "tarDirectory emits dir+file entries and ends with two zero blocks" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("sub");
    try tmp.dir.writeFile(.{ .sub_path = "sub/hello.txt", .data = "hi\n" });
    const abs_dir = try tmp.dir.realpathAlloc(a, ".");

    const tar = try tarDirectory(a, abs_dir, "root");

    // End-of-archive marker: last two 512-byte blocks are all zero.
    try std.testing.expect(tar.len >= 1024);
    const trailer = tar[tar.len - 1024 ..];
    for (trailer) |b| try std.testing.expectEqual(@as(u8, 0), b);

    // Walk 512-byte headers until the zero trailer, collecting entry names.
    var found_root_dir = false;
    var found_sub_dir = false;
    var found_file = false;
    var i: usize = 0;
    while (i + 512 <= tar.len - 1024) {
        const hdr = tar[i .. i + 512];
        const name = std.mem.sliceTo(hdr[0..100], 0);
        const typeflag = hdr[156];
        const size_str = std.mem.trim(u8, std.mem.sliceTo(hdr[124..136], 0), " ");
        const size = std.fmt.parseInt(usize, size_str, 8) catch 0;
        if (std.mem.eql(u8, name, "root") and typeflag == '5') found_root_dir = true;
        if (std.mem.eql(u8, name, "root/sub") and typeflag == '5') found_sub_dir = true;
        if (std.mem.eql(u8, name, "root/sub/hello.txt") and typeflag == '0') {
            found_file = true;
            try std.testing.expectEqual(@as(usize, 3), size);
        }
        const n_blocks = (size + 511) / 512;
        i += 512 + n_blocks * 512;
    }
    try std.testing.expect(found_root_dir);
    try std.testing.expect(found_sub_dir);
    try std.testing.expect(found_file);
}

test "docker end-to-end: pull tiny image, create, start, wait, remove (skips without daemon)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = Client{ .socket_path = detectSocket(a, .{}).? };
    if (!ping(a, c)) return error.SkipZigTest;
    var err: ?[]const u8 = null;
    if (!try imageExists(a, c, "busybox:latest", &err)) try imagePull(a, c, "busybox:latest", null, &err);
    const id = try containerCreate(a, c,
        \\{"Image":"busybox:latest","Cmd":["true"]}
    , null, &err);
    defer containerRemove(a, c, id, &err) catch {};
    try containerStart(a, c, id, &err);
    const code = try containerWait(a, c, id, &err);
    try std.testing.expectEqual(@as(i32, 0), code);
}

test "demuxFrames splits stdout and stderr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // frame: type=1 "out\n", type=2 "err\n"
    const body = [_]u8{ 1, 0, 0, 0, 0, 0, 0, 4 } ++ "out\n".* ++ [_]u8{ 2, 0, 0, 0, 0, 0, 0, 4 } ++ "err\n".*;
    const r = try demuxFrames(a, &body);
    try std.testing.expectEqualStrings("out\n", r.stdout);
    try std.testing.expectEqualStrings("err\n", r.stderr);
}

test "exec in live container captures output and exit code (skips without daemon)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = Client{ .socket_path = detectSocket(a, .{}).? };
    if (!ping(a, c)) return error.SkipZigTest;
    var err: ?[]const u8 = null;
    if (!try imageExists(a, c, "busybox:latest", &err)) try imagePull(a, c, "busybox:latest", null, &err);
    const id = try containerCreate(a, c,
        \\{"Image":"busybox:latest","Cmd":["sleep","30"]}
    , null, &err);
    defer containerRemove(a, c, id, &err) catch {};
    try containerStart(a, c, id, &err);
    const r = try execRun(a, c, id, &.{ "sh", "-c", "echo hi; echo bad >&2; exit 7" }, &.{}, null, &err);
    try std.testing.expectEqual(@as(i32, 7), r.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "hi") != null);
    try std.testing.expect(std.mem.indexOf(u8, r.stderr, "bad") != null);
}

test "interactive exec observes remote exit without waiting for stdin (skips without daemon)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const c = Client{ .socket_path = detectSocket(a, .{}).? };
    if (!ping(a, c)) return error.SkipZigTest;
    var err: ?[]const u8 = null;
    if (!try imageExists(a, c, "busybox:latest", &err)) try imagePull(a, c, "busybox:latest", null, &err);
    const id = try containerCreate(a, c,
        \\{"Image":"busybox:latest","Cmd":["sleep","30"]}
    , null, &err);
    defer containerRemove(a, c, id, &err) catch {};
    try containerStart(a, c, id, &err);
    try execInteractive(a, c, id, &.{ "sh", "-c", "exit 0" }, &.{}, null, &err);
}
