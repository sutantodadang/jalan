//! Docker backend: runs job steps inside a long-lived container per job.
//! setupJob creates + starts a `sleep infinity` container on the job's
//! image; runStep uploads the step script via a tar archive and execs it;
//! teardownJob removes the container (best-effort).
const std = @import("std");
const builtin = @import("builtin");
const ir = @import("../ir.zig");
const config = @import("../config.zig");
const backend_iface = @import("../backend.zig");
const client = @import("../docker/client.zig");
const resolve = @import("../actions/resolve.zig");

/// Default image used when neither `container:` nor a config image-map
/// entry supplies one. Chosen because it ships `bash`, `sh`, and `python`
/// (covering every shell this backend supports) plus `node` for JS actions.
/// Deliberately NOT the `-slim` variant: slim lacks `ca-certificates` (so
/// every TLS connection a toolchain makes — `go mod download`, `pip`,
/// `cargo` — dies with "certificate signed by unknown authority"; node
/// itself was immune because it bundles its own Mozilla root store, which
/// made the failure look selective) and lacks `gcc` (Go 1.20+ silently
/// defaults `CGO_ENABLED=0` without a C compiler, breaking `go test
/// -race`). The full image matches what GitHub's own runners provide far
/// more closely, at the cost of a bigger first pull.
pub const default_image = "node:20-bookworm";

/// Pure precedence: job `container:` image > `cfg.imageFor(runs_on)` >
/// `default_image`. Never touches the network or emits diagnostics — the
/// windows-*/macos-* "not available" warning is the caller's job (it needs
/// a `log` sink, which this function doesn't have).
pub fn imageFor(cfg: config.Config, job: ir.Job) []const u8 {
    if (job.container_image.len > 0) return job.container_image;
    if (cfg.imageFor(job.runs_on)) |img| return img;
    return default_image;
}

fn isNonLinuxRunner(runs_on: []const u8) bool {
    return std.mem.startsWith(u8, runs_on, "windows") or std.mem.startsWith(u8, runs_on, "macos");
}

/// Appends a JSON-quoted, escaped copy of `s` to `out`. Copied from
/// `docker/client.zig`'s private helper of the same name (itself copied
/// from `ir.jsonStr`) since neither is `pub`.
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

/// Bind-mount source for `workspace_abs`. We call the Engine API raw (no
/// `docker` CLI in between), and Docker Desktop's daemon translates host
/// paths itself — a native Windows path (`C:\Users\x`) is what the CLI
/// itself sends over the wire, so it passes through unchanged here (just
/// normalized to backslashes, in case a caller handed us a mixed-separator
/// path). Live verification pending — Docker Desktop was down during
/// development; revisit if bind mounts fail against a real daemon.
fn toBindSource(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (builtin.os.tag != .windows) return path;
    var out = try alloc.alloc(u8, path.len);
    for (path, 0..) |ch, i| out[i] = if (ch == '/') '\\' else ch;
    return out;
}

/// Best-effort host directory for the shared tool cache
/// (`%LOCALAPPDATA%\jalan\toolcache` on Windows — a sibling of
/// `resolve.cacheRoot()`'s `...\jalan\actions`), bind-mounted into every job
/// container at `/opt/hostedtoolcache` so `setup-go`/`setup-node`-style
/// actions persist downloaded toolchains across runs instead of
/// re-downloading into a throwaway container every time. Returns `null` on
/// ANY failure (env var missing, `makePath` failure) — the toolcache mount is
/// a performance nicety, never a reason to fail job setup; the caller logs a
/// warning and proceeds without the mount.
fn toolcacheHostDir(alloc: std.mem.Allocator) ?[]const u8 {
    const actions_root = resolve.cacheRoot(alloc) catch return null;
    const jalan_root = std.fs.path.dirname(actions_root) orelse return null;
    const dir = std.fs.path.join(alloc, &.{ jalan_root, "toolcache" }) catch return null;
    std.fs.cwd().makePath(dir) catch return null;
    return dir;
}

/// Replaces path-unsafe characters in a step id with `-`, so it's safe to
/// splice into a container-side file name (`step-<id>.sh`).
fn sanitizeStepId(alloc: std.mem.Allocator, id: []const u8) ![]const u8 {
    const out = try alloc.alloc(u8, id.len);
    for (id, 0..) |c, i| {
        out[i] = if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_') c else '-';
    }
    return out;
}

const ShellError = error{UnsupportedShell};

/// Maps a step's `shell:` name to the argv used to invoke `script_path`
/// inside the (Linux) container. `null` defaults to bash — safe for
/// `default_image`, which ships it, but a caller-supplied image without
/// bash would fail here same as native backend would without bash on PATH.
fn shellArgv(alloc: std.mem.Allocator, shell: ?[]const u8, script_path: []const u8) (error{OutOfMemory} || ShellError)![]const []const u8 {
    const name = shell orelse "bash";
    if (std.mem.eql(u8, name, "bash")) return alloc.dupe([]const u8, &.{ "bash", script_path });
    if (std.mem.eql(u8, name, "sh")) return alloc.dupe([]const u8, &.{ "sh", script_path });
    if (std.mem.eql(u8, name, "python")) return alloc.dupe([]const u8, &.{ "python", script_path });
    return error.UnsupportedShell;
}

fn formatEnvPairs(alloc: std.mem.Allocator, pairs: []const ir.EnvPair, extra: []const []const u8) ![]const []const u8 {
    var out = try alloc.alloc([]const u8, pairs.len + extra.len);
    for (pairs, 0..) |p, i| out[i] = try std.fmt.allocPrint(alloc, "{s}={s}", .{ p.name, p.value });
    for (extra, 0..) |e, i| out[pairs.len + i] = e;
    return out;
}

/// Builds the JSON body for `POST /containers/create`. Shared by the
/// long-lived job container (sleep-infinity, workspace bind mount, joins
/// `network_id` with no alias of its own) and per-job service containers
/// (image's own default command, no bind, joins `network_id` under
/// `aliases` so the job container can reach it by service name).
///
/// - `cmd` null means "use the image's own ENTRYPOINT/CMD" (services);
///   non-null overrides it (job container: `&.{"sleep","infinity"}`).
/// - `workspace_abs` null skips the `Binds`/`WorkingDir` workspace mount
///   (services don't need the repo checked out into them).
/// - `network_id` non-null sets `HostConfig.NetworkMode` so the container
///   actually joins that network at creation time.
/// - `aliases` non-empty (only meaningful alongside `network_id`) adds
///   `NetworkingConfig.EndpointsConfig.<network_id>.Aliases`, the DNS names
///   other containers on the network can reach this one by.
/// - `extra_binds` are additional already-formatted `"src:dst"` bind strings
///   (e.g. the host toolcache directory mounted at `/opt/hostedtoolcache`),
///   emitted after the workspace bind. `Binds` is emitted even when
///   `workspace_abs` is null as long as `extra_binds` is non-empty, though in
///   practice only the job container passes any — service containers always
///   pass `&.{}`.
fn buildContainerCreateSpec(
    alloc: std.mem.Allocator,
    image: []const u8,
    cmd: ?[]const []const u8,
    env: []const []const u8,
    workspace_abs: ?[]const u8,
    network_id: ?[]const u8,
    aliases: []const []const u8,
    extra_binds: []const []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, "{\"Image\":");
    try jsonStrAppend(&out, alloc, image);
    if (cmd) |c| {
        try out.appendSlice(alloc, ",\"Cmd\":[");
        for (c, 0..) |arg, i| {
            if (i > 0) try out.append(alloc, ',');
            try jsonStrAppend(&out, alloc, arg);
        }
        try out.append(alloc, ']');
    }
    try out.appendSlice(alloc, ",\"Env\":[");
    for (env, 0..) |kv, i| {
        if (i > 0) try out.append(alloc, ',');
        try jsonStrAppend(&out, alloc, kv);
    }
    try out.append(alloc, ']');

    try out.appendSlice(alloc, ",\"HostConfig\":{");
    var host_field_written = false;
    if (workspace_abs != null or extra_binds.len > 0) {
        try out.appendSlice(alloc, "\"Binds\":[");
        var wrote_bind = false;
        if (workspace_abs) |ws| {
            const bind_source = try toBindSource(alloc, ws);
            const bind = try std.fmt.allocPrint(alloc, "{s}:/github/workspace", .{bind_source});
            try jsonStrAppend(&out, alloc, bind);
            wrote_bind = true;
        }
        for (extra_binds) |b| {
            if (wrote_bind) try out.append(alloc, ',');
            try jsonStrAppend(&out, alloc, b);
            wrote_bind = true;
        }
        try out.append(alloc, ']');
        host_field_written = true;
    }
    if (network_id) |nid| {
        if (host_field_written) try out.append(alloc, ',');
        try out.appendSlice(alloc, "\"NetworkMode\":");
        try jsonStrAppend(&out, alloc, nid);
    }
    try out.append(alloc, '}');

    if (workspace_abs != null) {
        try out.appendSlice(alloc, ",\"WorkingDir\":\"/github/workspace\"");
    }

    if (network_id) |nid| {
        if (aliases.len > 0) {
            try out.appendSlice(alloc, ",\"NetworkingConfig\":{\"EndpointsConfig\":{");
            try jsonStrAppend(&out, alloc, nid);
            try out.appendSlice(alloc, ":{\"Aliases\":[");
            for (aliases, 0..) |al, i| {
                if (i > 0) try out.append(alloc, ',');
                try jsonStrAppend(&out, alloc, al);
            }
            try out.appendSlice(alloc, "]}}}");
        }
    }
    try out.append(alloc, '}');
    return out.toOwnedSlice(alloc);
}

/// Parses the GitHub Actions kv file format: plain `k=v` lines plus the
/// heredoc form `k<<DELIM\n...lines...\nDELIM` (what `@actions/core` writes
/// for multiline values — `setup-go`, `setup-node`, etc. use it for every
/// output/env write that isn't a single short token). Used for both
/// `GITHUB_OUTPUT` and `GITHUB_ENV`, since both files share this format.
///
/// Heredoc detection: a line containing `<<` where the part before `<<` is
/// non-empty and contains no `=` is treated as `name<<DELIM`; every
/// subsequent line is collected as the value until one exactly matches
/// `DELIM`, joined with `\n`. An unterminated heredoc (no matching delimiter
/// before EOF) is handled leniently: the value is whatever was collected up
/// to the end of the file, rather than erroring the whole parse over one
/// malformed entry. Anything else falls back to the plain `k=v` split on the
/// first `=`.
fn parseKvFile(alloc: std.mem.Allocator, data: []const u8) ![]ir.EnvPair {
    var outputs: std.ArrayList(ir.EnvPair) = .empty;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \r");
        if (line.len == 0) continue;
        if (std.mem.indexOf(u8, line, "<<")) |marker| {
            const name = line[0..marker];
            const delim = std.mem.trim(u8, line[marker + 2 ..], " \r");
            if (name.len == 0 or std.mem.indexOfScalar(u8, name, '=') != null) {
                // Not actually a heredoc header (e.g. a `k=v<<x` value) — fall
                // through to the plain k=v handling below.
            } else {
                var value: std.ArrayList(u8) = .empty;
                var first = true;
                while (lines.next()) |body_line| {
                    const trimmed = std.mem.trim(u8, body_line, "\r");
                    if (std.mem.eql(u8, trimmed, delim)) break;
                    if (!first) try value.append(alloc, '\n');
                    try value.appendSlice(alloc, body_line);
                    first = false;
                }
                try outputs.append(alloc, .{ .name = name, .value = try value.toOwnedSlice(alloc) });
                continue;
            }
        }
        if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
            if (eq > 0) try outputs.append(alloc, .{ .name = line[0..eq], .value = line[eq + 1 ..] });
        }
    }
    return outputs.toOwnedSlice(alloc);
}

/// Builds the shell prologue prepended to every bash/sh step script: `mkdir`
/// for the runner-managed directories, plus `export`s accumulated from prior
/// steps' `GITHUB_PATH`/`GITHUB_ENV` writes (see `JobHandle.extra_paths` /
/// `.extra_env`). Pure — no I/O — so it's testable without a container.
/// `PATH` entries are joined into one `export PATH='a':'b':"$PATH"` line
/// (prepended, matching GitHub Actions' own semantics: newer `GITHUB_PATH`
/// writes should win over the image's baseline `PATH`); each env pair gets
/// its own `export NAME='value'` line. Single-quoted values are escaped by
/// replacing `'` with `'\''` (the standard POSIX-shell single-quote escape).
/// A `NAME` outside `[A-Za-z0-9_]` is skipped rather than risking shell
/// injection through an action-supplied variable name.
fn buildPrologue(alloc: std.mem.Allocator, extra_paths: []const []const u8, extra_env: []const ir.EnvPair) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, "mkdir -p /tmp/runner-temp /opt/hostedtoolcache\n");
    // `@actions/core`'s file commands refuse to run when the target file
    // doesn't exist yet ("Missing file at path: ...") — the real runner
    // pre-creates GITHUB_OUTPUT/GITHUB_ENV/GITHUB_PATH before every step,
    // so do the same. The vars are always set by `run()`'s exec env.
    try out.appendSlice(alloc, "touch \"$GITHUB_OUTPUT\" \"$GITHUB_ENV\" \"$GITHUB_PATH\"\n");
    // GitHub's runner images have passwordless sudo and workflows lean on it
    // (`sudo apt-get install ...`); job containers here already run as root
    // and typically ship no `sudo` binary, so those steps die with exit 127.
    // Define a passthrough function only when the real binary is absent —
    // an image that ships sudo keeps its own.
    try out.appendSlice(alloc, "command -v sudo >/dev/null 2>&1 || sudo() { \"$@\"; }\n");

    if (extra_paths.len > 0) {
        var joined: std.ArrayList(u8) = .empty;
        for (extra_paths, 0..) |p, i| {
            if (i > 0) try joined.append(alloc, ':');
            try joined.appendSlice(alloc, p);
        }
        try out.appendSlice(alloc, "export PATH=");
        try appendShellSingleQuoted(&out, alloc, joined.items);
        try out.appendSlice(alloc, ":\"$PATH\"\n");
    }

    for (extra_env) |pair| {
        if (!isSafeEnvName(pair.name)) continue;
        try out.appendSlice(alloc, "export ");
        try out.appendSlice(alloc, pair.name);
        try out.append(alloc, '=');
        try appendShellSingleQuoted(&out, alloc, pair.value);
        try out.append(alloc, '\n');
    }

    return out.toOwnedSlice(alloc);
}

fn isSafeEnvName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_')) return false;
    }
    return true;
}

/// Appends `s` to `out` as a single-quoted POSIX shell word: `'` characters
/// inside `s` are escaped as `'\''` (close quote, literal escaped quote,
/// reopen quote) since single quotes admit no escape sequences of their own.
fn appendShellSingleQuoted(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) !void {
    try out.append(alloc, '\'');
    for (s) |c| {
        if (c == '\'') {
            try out.appendSlice(alloc, "'\\''");
        } else {
            try out.append(alloc, c);
        }
    }
    try out.append(alloc, '\'');
}

pub const DockerBackend = struct {
    client: client.Client,
    cfg: config.Config = .{},

    pub fn backend(self: *DockerBackend) backend_iface.Backend {
        return .{ .ctx = @ptrCast(self), .vtable = &vtable, .kind = .docker };
    }
};

const vtable = backend_iface.Backend.VTable{
    .setupJob = setup,
    .runStep = run,
    .teardownJob = teardown,
    .runContainerAction = runContainerAction,
    .openShell = openShell,
    .cacheIdentity = cacheIdentity,
    .stageActionDir = stageActionDir,
};

/// Stages a remote action's host-cached directory into the job container so
/// a subsequent `node <path>` invocation (see `runner.zig`'s `runNodeAction`)
/// can find it: tars `host_dir` (via `client.tarDirectory`, rooted under
/// `name`) and `putArchive`s it into `/tmp/jalan-actions`, creating that
/// directory first if needed. Returns the container-side path the action's
/// files landed at (`/tmp/jalan-actions/<name>`), which the caller joins with
/// `action.yml`'s `runs.main`.
fn stageActionDir(ctx: *anyopaque, alloc: std.mem.Allocator, handle: *backend_iface.JobHandle, host_dir: []const u8, name: []const u8, err_msg: *?[]const u8) anyerror![]const u8 {
    const self: *DockerBackend = @ptrCast(@alignCast(ctx));
    var mkdir_err: ?[]const u8 = null;
    _ = client.execRun(alloc, self.client, handle.container_id, &.{ "mkdir", "-p", "/tmp/jalan-actions" }, &.{}, null, &mkdir_err) catch |e| {
        err_msg.* = mkdir_err;
        return e;
    };

    const tar = try client.tarDirectory(alloc, host_dir, name);
    var put_err: ?[]const u8 = null;
    client.putArchive(alloc, self.client, handle.container_id, "/tmp/jalan-actions", tar, &put_err) catch |e| {
        err_msg.* = put_err;
        return e;
    };

    return std.fmt.allocPrint(alloc, "/tmp/jalan-actions/{s}", .{name});
}

fn cacheIdentity(ctx: *anyopaque, alloc: std.mem.Allocator, _: ir.Job, handle: *backend_iface.JobHandle, step: ir.Step) anyerror![]const u8 {
    const self: *DockerBackend = @ptrCast(@alignCast(ctx));
    if (std.mem.startsWith(u8, step.uses_ref, "docker://")) {
        var err: ?[]const u8 = null;
        const action_id = try client.imageIdentity(alloc, self.client, step.uses_ref["docker://".len..], &err);
        return std.fmt.allocPrint(alloc, "{s};action:{s}", .{ handle.cache_identity, action_id });
    }
    return handle.cache_identity;
}

/// Best-effort teardown of whatever service containers + network got
/// created before a later step in `setup` failed (or during normal
/// `teardownJob`). Errors are swallowed — this only runs when something has
/// already gone wrong (or the job is ending), and a cleanup failure
/// shouldn't mask the original error or crash teardown.
fn cleanupServicesAndNetwork(alloc: std.mem.Allocator, c: client.Client, service_ids: []const []const u8, network_id: []const u8) void {
    for (service_ids) |sid| {
        var e: ?[]const u8 = null;
        client.containerRemove(alloc, c, sid, &e) catch {};
    }
    if (network_id.len > 0) {
        var e: ?[]const u8 = null;
        client.networkRemove(alloc, c, network_id, &e) catch {};
    }
}

/// Polls a just-started service container's health status. No `HEALTHCHECK`
/// configured (`containerInspectHealth` returns `null`) means there's
/// nothing to wait for — proceed immediately. Otherwise polls at 1s
/// intervals for up to 60 attempts; a container that never reports
/// `"healthy"` logs a warning and is left running rather than failing the
/// job (some images take longer than 60s, or never report healthy under a
/// constrained CI runner — that's a warning, not a hard failure).
///
/// A transient inspect error (e.g. a momentary daemon hiccup) does NOT abort
/// the wait — it's treated as "keep polling", same as an unhealthy status,
/// since bailing out on the first API blip would silently skip the health
/// gate. Logged once (not once per attempt, to avoid spamming up to 60
/// identical lines) via `warned_error`; the 60-attempt timeout branch stays
/// the terminal warning either way.
fn waitForHealth(alloc: std.mem.Allocator, c: client.Client, id: []const u8, name: []const u8, log: ?backend_iface.LogFn) void {
    var warned_error = false;
    var attempt: usize = 0;
    while (attempt < 60) : (attempt += 1) {
        // `err` is scoped per-attempt so a stale error from a prior failed
        // attempt can't be mistaken for the current attempt's outcome.
        var err: ?[]const u8 = null;
        var had_error = false;
        const status = client.containerInspectHealth(alloc, c, id, &err) catch blk: {
            had_error = true;
            break :blk null;
        };
        if (had_error) {
            if (!warned_error) {
                warned_error = true;
                if (log) |l| {
                    if (std.fmt.allocPrint(alloc, "service '{s}' health inspect error \xe2\x80\x94 retrying", .{name}) catch null) |msg| l(msg);
                }
            }
        } else if (status == null) {
            // Succeeded, and no `State.Health` object at all (image has no
            // HEALTHCHECK) -> nothing to wait for.
            return;
        } else if (std.mem.eql(u8, status.?, "healthy")) {
            return;
        }
        if (attempt + 1 < 60) std.Thread.sleep(std.time.ns_per_s);
    }
    if (log) |l| {
        const msg = std.fmt.allocPrint(alloc, "service '{s}' not healthy after 60s \xe2\x80\x94 continuing", .{name}) catch return;
        l(msg);
    }
}

fn setup(ctx: *anyopaque, alloc: std.mem.Allocator, job: ir.Job, workspace_abs: []const u8, log: ?backend_iface.LogFn) anyerror!backend_iface.JobHandle {
    const self: *DockerBackend = @ptrCast(@alignCast(ctx));
    const image = imageFor(self.cfg, job);

    if (isNonLinuxRunner(job.runs_on) and job.container_image.len == 0 and self.cfg.imageFor(job.runs_on) == null) {
        if (log) |l| l(try std.fmt.allocPrint(alloc, "warning: {s} containers are not available \xe2\x80\x94 using linux image {s}", .{ job.runs_on, image }));
    }

    var err: ?[]const u8 = null;
    const exists = client.imageExists(alloc, self.client, image, &err) catch |e| {
        if (log) |l| if (err) |m| l(m);
        return e;
    };
    if (!exists) {
        client.imagePull(alloc, self.client, image, log, &err) catch |e| {
            if (log) |l| if (err) |m| l(m);
            return e;
        };
    }

    var runtime_hash = std.crypto.hash.sha2.Sha256.init(.{});
    const image_id = try client.imageIdentity(alloc, self.client, image, &err);
    runtime_hash.update("job\x00");
    runtime_hash.update(image_id);
    runtime_hash.update(&.{0});

    var network_id: []const u8 = "";
    var service_ids: std.ArrayList([]const u8) = .empty;

    if (job.services.len > 0) {
        const net_name = try std.fmt.allocPrint(alloc, "jalan-{s}-{x:0>8}", .{ try sanitizeStepId(alloc, job.id), std.crypto.random.int(u32) });
        network_id = client.networkCreate(alloc, self.client, net_name, &err) catch |e| {
            if (log) |l| if (err) |m| l(m);
            return e;
        };

        for (job.services) |svc| {
            const svc_exists = client.imageExists(alloc, self.client, svc.image, &err) catch |e| {
                if (log) |l| if (err) |m| l(m);
                cleanupServicesAndNetwork(alloc, self.client, service_ids.items, network_id);
                return e;
            };
            if (!svc_exists) {
                client.imagePull(alloc, self.client, svc.image, log, &err) catch |e| {
                    if (log) |l| if (err) |m| l(m);
                    cleanupServicesAndNetwork(alloc, self.client, service_ids.items, network_id);
                    return e;
                };
            }
            const service_image_id = client.imageIdentity(alloc, self.client, svc.image, &err) catch |e| {
                if (log) |l| if (err) |m| l(m);
                cleanupServicesAndNetwork(alloc, self.client, service_ids.items, network_id);
                return e;
            };
            runtime_hash.update("service\x00");
            runtime_hash.update(svc.name);
            runtime_hash.update(&.{0});
            runtime_hash.update(service_image_id);
            runtime_hash.update(&.{0});
            for (svc.env) |pair| {
                runtime_hash.update(pair.name);
                runtime_hash.update(&.{0});
                runtime_hash.update(pair.value);
                runtime_hash.update(&.{0});
            }
            const svc_env = try formatEnvPairs(alloc, svc.env, &.{});
            const svc_spec = try buildContainerCreateSpec(alloc, svc.image, null, svc_env, null, network_id, &.{svc.name}, &.{});
            const svc_id = client.containerCreate(alloc, self.client, svc_spec, null, &err) catch |e| {
                if (log) |l| if (err) |m| l(m);
                cleanupServicesAndNetwork(alloc, self.client, service_ids.items, network_id);
                return e;
            };
            try service_ids.append(alloc, svc_id);
            client.containerStart(alloc, self.client, svc_id, &err) catch |e| {
                if (log) |l| if (err) |m| l(m);
                cleanupServicesAndNetwork(alloc, self.client, service_ids.items, network_id);
                return e;
            };
            waitForHealth(alloc, self.client, svc_id, svc.name, log);
        }
    }

    const container_env = if (job.provider == .github_actions)
        try formatEnvPairs(alloc, job.env, &.{ "CI=true", "GITHUB_ACTIONS=true", "JALAN=true" })
    else
        try formatEnvPairs(alloc, job.env, &.{ "CI=true", "JALAN=true" });
    const job_network: ?[]const u8 = if (network_id.len > 0) network_id else null;

    var extra_binds: []const []const u8 = &.{};
    if (toolcacheHostDir(alloc)) |tc| {
        // Heap-allocate the one-element slice: `&.{bind}` would point at a
        // stack temporary scoped to this block, dangling by the time
        // `buildContainerCreateSpec` reads it below.
        const binds = try alloc.alloc([]const u8, 1);
        binds[0] = try std.fmt.allocPrint(alloc, "{s}:/opt/hostedtoolcache", .{try toBindSource(alloc, tc)});
        extra_binds = binds;
    } else if (log) |l| {
        l("warning: could not prepare host tool cache dir \xe2\x80\x94 setup-* actions will re-download toolchains every run");
    }

    const spec = try buildContainerCreateSpec(alloc, image, &.{ "sleep", "infinity" }, container_env, workspace_abs, job_network, &.{}, extra_binds);
    const id = client.containerCreate(alloc, self.client, spec, null, &err) catch |e| {
        if (log) |l| if (err) |m| l(m);
        cleanupServicesAndNetwork(alloc, self.client, service_ids.items, network_id);
        return e;
    };
    client.containerStart(alloc, self.client, id, &err) catch |e| {
        if (log) |l| if (err) |m| l(m);
        var cleanup_err: ?[]const u8 = null;
        client.containerRemove(alloc, self.client, id, &cleanup_err) catch {};
        cleanupServicesAndNetwork(alloc, self.client, service_ids.items, network_id);
        return e;
    };

    var runtime_digest: [32]u8 = undefined;
    runtime_hash.final(&runtime_digest);
    const runtime_hex = std.fmt.bytesToHex(runtime_digest, .lower);
    return .{
        .container_id = id,
        .workspace = workspace_abs,
        .network_id = network_id,
        .service_ids = try service_ids.toOwnedSlice(alloc),
        .cache_identity = try std.fmt.allocPrint(alloc, "runtime:{s}", .{&runtime_hex}),
    };
}

fn run(ctx: *anyopaque, alloc: std.mem.Allocator, handle: *backend_iface.JobHandle, step: ir.Step, env: []const ir.EnvPair, workdir: ?[]const u8, err_msg: *?[]const u8) anyerror!backend_iface.StepOutcome {
    const self: *DockerBackend = @ptrCast(@alignCast(ctx));
    const safe_id = try sanitizeStepId(alloc, step.id);
    const script_name = try std.fmt.allocPrint(alloc, "step-{s}.sh", .{safe_id});
    const script_path = try std.fmt.allocPrint(alloc, "/tmp/{s}", .{script_name});
    const out_path = try std.fmt.allocPrint(alloc, "/tmp/out-{s}.txt", .{safe_id});
    const github_env_path = try std.fmt.allocPrint(alloc, "/tmp/env-{s}.txt", .{safe_id});
    const github_path_path = try std.fmt.allocPrint(alloc, "/tmp/path-{s}.txt", .{safe_id});

    const argv = shellArgv(alloc, step.shell, script_path) catch {
        err_msg.* = try std.fmt.allocPrint(alloc, "shell '{s}' not available in linux containers", .{step.shell orelse "bash"});
        return error.SpawnFailed;
    };

    // The PATH/ENV-export prologue only makes sense for the shells that
    // actually source it as shell code; a python step's script is uploaded
    // unchanged.
    const shell_name = step.shell orelse "bash";
    const wants_prologue = std.mem.eql(u8, shell_name, "bash") or std.mem.eql(u8, shell_name, "sh");
    const script_body = if (wants_prologue)
        try std.fmt.allocPrint(alloc, "{s}{s}", .{ try buildPrologue(alloc, handle.extra_paths, handle.extra_env), step.script })
    else
        step.script;

    var err: ?[]const u8 = null;
    const tar_bytes = try client.tarSingleFile(alloc, script_name, script_body, 0o755);
    client.putArchive(alloc, self.client, handle.container_id, "/tmp", tar_bytes, &err) catch |e| {
        err_msg.* = err;
        return e;
    };

    const github_output = try std.fmt.allocPrint(alloc, "GITHUB_OUTPUT={s}", .{out_path});
    const github_env_var = try std.fmt.allocPrint(alloc, "GITHUB_ENV={s}", .{github_env_path});
    const github_path_var = try std.fmt.allocPrint(alloc, "GITHUB_PATH={s}", .{github_path_path});
    const exec_env = try formatEnvPairs(alloc, env, &.{
        github_output,
        github_env_var,
        github_path_var,
        "RUNNER_TEMP=/tmp/runner-temp",
        "RUNNER_TOOL_CACHE=/opt/hostedtoolcache",
        "GITHUB_WORKSPACE=/github/workspace",
    });

    const exec_result = client.execRun(alloc, self.client, handle.container_id, argv, exec_env, workdir, &err) catch |e| {
        err_msg.* = err;
        if (e == error.ExecTimeout) return error.SpawnFailed;
        return e;
    };

    var outputs: []ir.EnvPair = &.{};
    var cat_err: ?[]const u8 = null;
    const cat_result: ?client.ExecResult = client.execRun(alloc, self.client, handle.container_id, &.{ "cat", out_path }, &.{}, null, &cat_err) catch null;
    if (cat_result) |cr| outputs = try parseKvFile(alloc, cr.stdout);

    // Propagate this step's GITHUB_PATH/GITHUB_ENV writes to the *next* step
    // in this job (mirrors `nixSetupIntercept`'s per-job `nix_packages`
    // accumulation in `actions/runner.zig`). Both cats are best-effort — a
    // step that never touched either file just gets an empty/failed `cat`,
    // same as the GITHUB_OUTPUT read above, and `handle.*` is left unchanged
    // in that case.
    var path_cat_err: ?[]const u8 = null;
    if (client.execRun(alloc, self.client, handle.container_id, &.{ "cat", github_path_path }, &.{}, null, &path_cat_err) catch null) |pr| {
        var list: std.ArrayList([]const u8) = .empty;
        try list.appendSlice(alloc, handle.extra_paths);
        var lines = std.mem.splitScalar(u8, pr.stdout, '\n');
        while (lines.next()) |raw_line| {
            const p = std.mem.trim(u8, raw_line, " \r");
            if (p.len == 0) continue;
            if (!containsPathStr(list.items, p)) try list.append(alloc, p);
        }
        handle.extra_paths = try list.toOwnedSlice(alloc);
    }

    var env_cat_err: ?[]const u8 = null;
    if (client.execRun(alloc, self.client, handle.container_id, &.{ "cat", github_env_path }, &.{}, null, &env_cat_err) catch null) |er| {
        const new_pairs = try parseKvFile(alloc, er.stdout);
        if (new_pairs.len > 0) {
            var list: std.ArrayList(ir.EnvPair) = .empty;
            try list.appendSlice(alloc, handle.extra_env);
            for (new_pairs) |np| {
                var replaced = false;
                for (list.items) |*existing| {
                    if (std.mem.eql(u8, existing.name, np.name)) {
                        existing.value = np.value;
                        replaced = true;
                        break;
                    }
                }
                if (!replaced) try list.append(alloc, np);
            }
            handle.extra_env = try list.toOwnedSlice(alloc);
        }
    }

    return .{
        .exit_code = exec_result.exit_code,
        .stdout = exec_result.stdout,
        .stderr = exec_result.stderr,
        .outputs = outputs,
    };
}

fn containsPathStr(list: []const []const u8, s: []const u8) bool {
    for (list) |x| if (std.mem.eql(u8, x, s)) return true;
    return false;
}

fn openShell(ctx: *anyopaque, alloc: std.mem.Allocator, handle: *backend_iface.JobHandle, workdir: ?[]const u8, env: []const ir.EnvPair) anyerror!void {
    const self: *DockerBackend = @ptrCast(@alignCast(ctx));
    const exec_env = try formatEnvPairs(alloc, env, &.{});
    var err: ?[]const u8 = null;
    client.execInteractive(
        alloc,
        self.client,
        handle.container_id,
        &.{ "sh", "-c", "command -v bash >/dev/null 2>&1 && exec bash || exec sh" },
        exec_env,
        workdir,
        &err,
    ) catch |e| {
        if (err) |msg| std.debug.print("docker shell: {s}\n", .{msg});
        return e;
    };
}

/// One-shot `docker://` action: pull (if needed), create (with `cmd_args` as
/// `Cmd` when non-empty — empty means "use the image's own ENTRYPOINT/CMD",
/// `env_pairs` as `Env`, joining `handle.network_id` when the job has one, no
/// workspace bind — a `docker://` action gets its inputs via env, not a
/// mounted repo), start, wait for exit, collect logs (`exec` doesn't apply
/// here: there's no long-lived container to exec into, the container's own
/// entrypoint *is* the action), remove. Mirrors `setup`/`run`'s
/// create-then-start shape but is a single-container, run-to-completion flow
/// rather than a long-lived job container.
fn runContainerAction(ctx: *anyopaque, alloc: std.mem.Allocator, handle: *backend_iface.JobHandle, image: []const u8, cmd_args: []const []const u8, env_pairs: []const ir.EnvPair, err_msg: *?[]const u8) anyerror!backend_iface.StepOutcome {
    const self: *DockerBackend = @ptrCast(@alignCast(ctx));
    var err: ?[]const u8 = null;

    const exists = client.imageExists(alloc, self.client, image, &err) catch |e| {
        err_msg.* = err;
        return e;
    };
    if (!exists) {
        client.imagePull(alloc, self.client, image, null, &err) catch |e| {
            err_msg.* = err;
            return e;
        };
    }

    const cmd: ?[]const []const u8 = if (cmd_args.len > 0) cmd_args else null;
    const env_strs = try formatEnvPairs(alloc, env_pairs, &.{});
    const network_id: ?[]const u8 = if (handle.network_id.len > 0) handle.network_id else null;
    const spec = try buildContainerCreateSpec(alloc, image, cmd, env_strs, null, network_id, &.{}, &.{});

    const id = client.containerCreate(alloc, self.client, spec, null, &err) catch |e| {
        err_msg.* = err;
        return e;
    };
    client.containerStart(alloc, self.client, id, &err) catch |e| {
        err_msg.* = err;
        var cleanup_err: ?[]const u8 = null;
        client.containerRemove(alloc, self.client, id, &cleanup_err) catch {};
        return e;
    };
    const exit_code = client.containerWait(alloc, self.client, id, &err) catch |e| {
        err_msg.* = err;
        var cleanup_err: ?[]const u8 = null;
        client.containerRemove(alloc, self.client, id, &cleanup_err) catch {};
        return e;
    };
    const log_bytes = client.containerLogs(alloc, self.client, id, &err) catch |e| {
        err_msg.* = err;
        var cleanup_err: ?[]const u8 = null;
        client.containerRemove(alloc, self.client, id, &cleanup_err) catch {};
        return e;
    };
    const demuxed = try client.demuxFrames(alloc, log_bytes);

    var cleanup_err: ?[]const u8 = null;
    client.containerRemove(alloc, self.client, id, &cleanup_err) catch {};

    return .{ .exit_code = exit_code, .stdout = demuxed.stdout, .stderr = demuxed.stderr, .outputs = &.{} };
}

fn teardown(ctx: *anyopaque, alloc: std.mem.Allocator, handle: *backend_iface.JobHandle) void {
    const self: *DockerBackend = @ptrCast(@alignCast(ctx));
    if (handle.container_id.len > 0) {
        var err: ?[]const u8 = null;
        client.containerRemove(alloc, self.client, handle.container_id, &err) catch {};
    }
    cleanupServicesAndNetwork(alloc, self.client, handle.service_ids, handle.network_id);
}

test "imageFor: container_image beats cfg map beats default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var pairs = [_]config.ImagePair{.{ .runs_on = "ubuntu-latest", .image = "cfg-image:tag" }};
    const cfg = config.Config{ .image_map = &pairs };

    // 1. container_image wins even when cfg map also matches.
    const job_container = ir.Job{ .id = "j", .display_name = "j", .runs_on = "ubuntu-latest", .steps = &.{}, .container_image = "explicit:tag" };
    try std.testing.expectEqualStrings("explicit:tag", imageFor(cfg, job_container));

    // 2. cfg map wins when no container_image is set.
    const job_cfg = ir.Job{ .id = "j", .display_name = "j", .runs_on = "ubuntu-latest", .steps = &.{} };
    try std.testing.expectEqualStrings("cfg-image:tag", imageFor(cfg, job_cfg));

    // 3. default wins when neither is set (same default regardless of OS).
    const job_default = ir.Job{ .id = "j", .display_name = "j", .runs_on = "windows-latest", .steps = &.{} };
    try std.testing.expectEqualStrings(default_image, imageFor(cfg, job_default));
    _ = a;
}

test "shellArgv maps known shells, rejects unavailable ones" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bash_argv = try shellArgv(a, null, "/tmp/s.sh");
    try std.testing.expectEqualStrings("bash", bash_argv[0]);
    try std.testing.expectEqualStrings("/tmp/s.sh", bash_argv[1]);

    const explicit_bash = try shellArgv(a, "bash", "/tmp/s.sh");
    try std.testing.expectEqualStrings("bash", explicit_bash[0]);

    const sh_argv = try shellArgv(a, "sh", "/tmp/s.sh");
    try std.testing.expectEqualStrings("sh", sh_argv[0]);

    const py_argv = try shellArgv(a, "python", "/tmp/s.py");
    try std.testing.expectEqualStrings("python", py_argv[0]);

    try std.testing.expectError(error.UnsupportedShell, shellArgv(a, "pwsh", "/tmp/s.ps1"));
    try std.testing.expectError(error.UnsupportedShell, shellArgv(a, "powershell", "/tmp/s.ps1"));
    try std.testing.expectError(error.UnsupportedShell, shellArgv(a, "cmd", "/tmp/s.cmd"));
    try std.testing.expectError(error.UnsupportedShell, shellArgv(a, "fish", "/tmp/s.fish"));
}

test "toBindSource: windows path passes through unchanged (Docker Desktop translates it), unix path always unchanged" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (builtin.os.tag == .windows) {
        try std.testing.expectEqualStrings("C:\\Users\\x\\proj", try toBindSource(a, "C:\\Users\\x\\proj"));
        // mixed separators get normalized to backslash, not converted to /c/ form.
        try std.testing.expectEqualStrings("C:\\Users\\x\\proj", try toBindSource(a, "C:/Users/x/proj"));
    } else {
        try std.testing.expectEqualStrings("/home/user/proj", try toBindSource(a, "/home/user/proj"));
    }
}

test "sanitizeStepId replaces unsafe characters with dashes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("step-1", try sanitizeStepId(a, "step-1"));
    try std.testing.expectEqualStrings("a_b-c", try sanitizeStepId(a, "a_b-c"));
    try std.testing.expectEqualStrings("a-b---c-", try sanitizeStepId(a, "a b/./c!"));
}

test "buildContainerCreateSpec embeds image, workspace bind, and env" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const workspace = "/home/user/proj";
    const spec = try buildContainerCreateSpec(a, "node:20-bookworm-slim", &.{ "sleep", "infinity" }, &.{"CI=true"}, workspace, null, &.{}, &.{});
    const raw_bind = try std.fmt.allocPrint(a, "{s}:/github/workspace", .{try toBindSource(a, workspace)});
    // jsonStrAppend escapes backslashes (Windows bind sources can contain
    // them); build the same escaped form so this assertion works on both OSes.
    var escaped: std.ArrayList(u8) = .empty;
    for (raw_bind) |c| {
        if (c == '\\') try escaped.appendSlice(a, "\\\\") else try escaped.append(a, c);
    }
    const expected_bind = try escaped.toOwnedSlice(a);
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"Image\":\"node:20-bookworm-slim\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"Cmd\":[\"sleep\",\"infinity\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, expected_bind) != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"CI=true\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"WorkingDir\":\"/github/workspace\"") != null);
}

test "buildContainerCreateSpec includes NetworkMode and Aliases when network_id and aliases are set" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const spec = try buildContainerCreateSpec(a, "redis:7-alpine", null, &.{}, null, "net123", &.{"redis"}, &.{});
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"NetworkMode\":\"net123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"NetworkingConfig\":{\"EndpointsConfig\":{\"net123\":{\"Aliases\":[\"redis\"]}}}") != null);
    // service spec: no Cmd override (uses image default), no workspace bind.
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"Cmd\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"Binds\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"WorkingDir\"") == null);
}

test "buildContainerCreateSpec: job container with services sets both Binds and NetworkMode" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const workspace = "/home/user/proj";
    const spec = try buildContainerCreateSpec(a, "node:20-bookworm-slim", &.{ "sleep", "infinity" }, &.{"CI=true"}, workspace, "net123", &.{}, &.{});
    const raw_bind = try std.fmt.allocPrint(a, "{s}:/github/workspace", .{try toBindSource(a, workspace)});
    var escaped: std.ArrayList(u8) = .empty;
    for (raw_bind) |c| {
        if (c == '\\') try escaped.appendSlice(a, "\\\\") else try escaped.append(a, c);
    }
    const expected_bind = try escaped.toOwnedSlice(a);
    try std.testing.expect(std.mem.indexOf(u8, spec, expected_bind) != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"NetworkMode\":\"net123\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"WorkingDir\":\"/github/workspace\"") != null);
    // job container itself has no service alias.
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"NetworkingConfig\"") == null);
}

test "parseKvFile parses k=v lines, ignores blanks and malformed lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const outs = try parseKvFile(a, "k=v\n\nbad-line\nver=1.2\r\n");
    try std.testing.expectEqual(@as(usize, 2), outs.len);
    try std.testing.expectEqualStrings("k", outs[0].name);
    try std.testing.expectEqualStrings("v", outs[0].value);
    try std.testing.expectEqualStrings("ver", outs[1].name);
    try std.testing.expectEqualStrings("1.2", outs[1].value);
}

test "parseKvFile: heredoc single-line value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const outs = try parseKvFile(a, "GOROOT<<EOF_abc123\n/opt/hostedtoolcache/go/1.22.0/x64\nEOF_abc123\n");
    try std.testing.expectEqual(@as(usize, 1), outs.len);
    try std.testing.expectEqualStrings("GOROOT", outs[0].name);
    try std.testing.expectEqualStrings("/opt/hostedtoolcache/go/1.22.0/x64", outs[0].value);
}

test "parseKvFile: heredoc multiline value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const outs = try parseKvFile(a, "NOTES<<EOF\nline one\nline two\nEOF\n");
    try std.testing.expectEqual(@as(usize, 1), outs.len);
    try std.testing.expectEqualStrings("NOTES", outs[0].name);
    try std.testing.expectEqualStrings("line one\nline two", outs[0].value);
}

test "parseKvFile: mixed plain and heredoc entries in one file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const outs = try parseKvFile(a, "plain=1\nBODY<<D\nfirst\nsecond\nD\nother=2\n");
    try std.testing.expectEqual(@as(usize, 3), outs.len);
    try std.testing.expectEqualStrings("plain", outs[0].name);
    try std.testing.expectEqualStrings("1", outs[0].value);
    try std.testing.expectEqualStrings("BODY", outs[1].name);
    try std.testing.expectEqualStrings("first\nsecond", outs[1].value);
    try std.testing.expectEqualStrings("other", outs[2].name);
    try std.testing.expectEqualStrings("2", outs[2].value);
}

test "buildPrologue: exports PATH and env vars with single-quote escaping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const paths = [_][]const u8{"/opt/hostedtoolcache/go/1.22.0/x64/bin"};
    const envs = [_]ir.EnvPair{.{ .name = "GOROOT", .value = "/opt/x" }};
    const out = try buildPrologue(a, &paths, &envs);
    try std.testing.expect(std.mem.indexOf(u8, out, "mkdir -p /tmp/runner-temp /opt/hostedtoolcache\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "export PATH='/opt/hostedtoolcache/go/1.22.0/x64/bin':\"$PATH\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "export GOROOT='/opt/x'\n") != null);
}

test "buildPrologue: escapes embedded single quotes in env values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const envs = [_]ir.EnvPair{.{ .name = "MSG", .value = "it's ok" }};
    const out = try buildPrologue(a, &.{}, &envs);
    try std.testing.expect(std.mem.indexOf(u8, out, "export MSG='it'\\''s ok'\n") != null);
}

test "buildPrologue: skips unsafe env var names" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const envs = [_]ir.EnvPair{.{ .name = "bad name;rm -rf", .value = "x" }};
    const out = try buildPrologue(a, &.{}, &envs);
    try std.testing.expect(std.mem.indexOf(u8, out, "export bad") == null);
}

test "docker backend runs a two-step job sharing filesystem (skips without daemon)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cl = client.Client{ .socket_path = client.detectSocket(a, .{}).? };
    if (!client.ping(a, cl)) return error.SkipZigTest;
    var db = DockerBackend{ .client = cl, .cfg = .{ .image_map = @constCast(&[_]config.ImagePair{.{ .runs_on = "ubuntu-latest", .image = "busybox:latest" }}) } };
    const b = db.backend();
    const cwd = try std.fs.cwd().realpathAlloc(a, ".");
    var h = try b.setupJob(a, .{ .id = "j", .display_name = "j", .runs_on = "ubuntu-latest", .steps = &.{} }, cwd, null);
    defer b.teardownJob(a, &h);
    var em: ?[]const u8 = null;
    // busybox has sh only — force sh; default image node:20-bookworm-slim has bash.
    const s1 = ir.Step{ .id = "a", .name = "a", .kind = .run, .shell = "sh", .script = "echo one > /tmp/marker && echo \"k=v\" >> \"$GITHUB_OUTPUT\"" };
    const o1 = try b.runStep(a, &h, s1, &.{}, null, &em);
    try std.testing.expectEqual(@as(i32, 0), o1.exit_code);
    try std.testing.expectEqualStrings("k", o1.outputs[0].name);
    const s2 = ir.Step{ .id = "b", .name = "b", .kind = .run, .shell = "sh", .script = "cat /tmp/marker" };
    const o2 = try b.runStep(a, &h, s2, &.{}, null, &em);
    try std.testing.expect(std.mem.indexOf(u8, o2.stdout, "one") != null);
}

test "phase 3 docker snapshot cache and restore parity (skips without daemon)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const engine_mod = @import("../engine.zig");
    const manifest_mod = @import("../snap/manifest.zig");
    const restore_mod = @import("../snap/restore.zig");

    const cl = client.Client{ .socket_path = client.detectSocket(a, .{}).? };
    if (!client.ping(a, cl)) return error.SkipZigTest;
    var db = DockerBackend{ .client = cl, .cfg = .{ .image_map = @constCast(&[_]config.ImagePair{.{ .runs_on = "ubuntu-latest", .image = "busybox:latest" }}) } };
    const b = db.backend();

    const base = ".jalan/tmp/phase3-docker";
    std.fs.cwd().deleteTree(base) catch {};
    defer std.fs.cwd().deleteTree(base) catch {};
    const workspace = try std.fmt.allocPrint(a, "{s}/workspace", .{base});
    try std.fs.cwd().makePath(workspace);
    const workspace_abs = try std.fs.cwd().realpathAlloc(a, workspace);
    const store_root = try std.fmt.allocPrint(a, "{s}/store", .{base});

    var steps = [_]ir.Step{
        .{ .id = "write", .name = "write", .kind = .run, .shell = "sh", .script = "echo executed > marker.txt; echo 'value=ok' >> \"$GITHUB_OUTPUT\"" },
        .{ .id = "consume", .name = "consume", .kind = .run, .shell = "sh", .script = "echo '${{ steps.write.outputs.value }}' > seen.txt" },
    };
    var jobs = [_]ir.Job{.{ .id = "j", .display_name = "j", .runs_on = "ubuntu-latest", .steps = &steps }};
    const pipeline = ir.Pipeline{ .name = "phase3-docker", .source_path = "testdata/workflows/phase3-docker.yml", .jobs = &jobs };

    const first = try engine_mod.run(a, pipeline, .{
        .exec_backend = b,
        .snapshot = true,
        .cache = true,
        .store_root = store_root,
        .workspace_abs = workspace_abs,
        .run_id = "docker-phase3-1",
        .max_parallel = 1,
    });
    try std.testing.expect(first.ok());
    try std.testing.expectEqualStrings("ok\n", try std.fs.cwd().readFileAlloc(a, try std.fmt.allocPrint(a, "{s}/seen.txt", .{workspace}), 1 << 20));

    // Restore the pre-first-step snapshot: both files disappear on the host,
    // and therefore from the next container's bind-mounted workspace.
    const manifest = try manifest_mod.load(a, store_root, "snapshots/docker-phase3-1/j/000-write.json");
    try restore_mod.restore(a, store_root, workspace_abs, manifest, null);

    const Capture = struct {
        var hits: std.atomic.Value(usize) = .init(0);
        fn log(line: []const u8) void {
            if (std.mem.indexOf(u8, line, "(cached)") != null) _ = hits.fetchAdd(1, .monotonic);
        }
    };
    Capture.hits.store(0, .release);
    const second = try engine_mod.run(a, pipeline, .{
        .exec_backend = b,
        .snapshot = true,
        .cache = true,
        .store_root = store_root,
        .workspace_abs = workspace_abs,
        .run_id = "docker-phase3-2",
        .max_parallel = 1,
        .log = Capture.log,
    });
    try std.testing.expect(second.ok());
    try std.testing.expectEqual(@as(usize, 2), Capture.hits.load(.acquire));
    try std.testing.expectEqualStrings("executed\n", try std.fs.cwd().readFileAlloc(a, try std.fmt.allocPrint(a, "{s}/marker.txt", .{workspace}), 1 << 20));
    try std.testing.expectEqualStrings("ok\n", try std.fs.cwd().readFileAlloc(a, try std.fmt.allocPrint(a, "{s}/seen.txt", .{workspace}), 1 << 20));
}

test "docker backend service is reachable by DNS alias on the job network (skips without daemon)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cl = client.Client{ .socket_path = client.detectSocket(a, .{}).? };
    if (!client.ping(a, cl)) return error.SkipZigTest;
    var db = DockerBackend{ .client = cl, .cfg = .{ .image_map = @constCast(&[_]config.ImagePair{.{ .runs_on = "ubuntu-latest", .image = "busybox:latest" }}) } };
    const b = db.backend();
    const cwd = try std.fs.cwd().realpathAlloc(a, ".");
    var services = [_]ir.Service{.{ .name = "redis", .image = "redis:7-alpine" }};
    var h = try b.setupJob(a, .{ .id = "svc-job", .display_name = "svc-job", .runs_on = "ubuntu-latest", .steps = &.{}, .services = &services }, cwd, null);
    defer b.teardownJob(a, &h);
    try std.testing.expect(h.network_id.len > 0);
    try std.testing.expectEqual(@as(usize, 1), h.service_ids.len);
    var em: ?[]const u8 = null;
    const s = ir.Step{ .id = "dns", .name = "dns", .kind = .run, .shell = "sh", .script = "ping -c 1 redis" };
    const o = try b.runStep(a, &h, s, &.{}, null, &em);
    if (o.exit_code != 0) std.debug.print("dns probe failed: stdout={s} stderr={s} error={s}\n", .{ o.stdout, o.stderr, em orelse "" });
    try std.testing.expectEqual(@as(i32, 0), o.exit_code);
}

test "runContainerAction: one-shot docker:// container returns exit code and demuxed logs (skips without daemon)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cl = client.Client{ .socket_path = client.detectSocket(a, .{}).? };
    if (!client.ping(a, cl)) return error.SkipZigTest;
    var err: ?[]const u8 = null;
    if (!try client.imageExists(a, cl, "busybox:latest", &err)) try client.imagePull(a, cl, "busybox:latest", null, &err);
    var db = DockerBackend{ .client = cl };
    const b = db.backend();
    try std.testing.expectEqual(backend_iface.Kind.docker, b.kind);
    var handle = backend_iface.JobHandle{};
    var err_msg: ?[]const u8 = null;
    const out = try b.runContainerAction(a, &handle, "busybox:latest", &.{ "sh", "-c", "echo hi; echo bad >&2; exit 7" }, &.{}, &err_msg);
    try std.testing.expectEqual(@as(i32, 7), out.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, out.stdout, "hi") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.stderr, "bad") != null);
}
