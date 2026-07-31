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

/// Default image used when neither `container:` nor a config image-map
/// entry supplies one. Chosen because it ships `bash`, `sh`, and `python`,
/// covering every shell this backend supports.
pub const default_image = "node:20-bookworm-slim";

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

/// Converts a Windows-style absolute path (`C:\Users\x`) into the
/// forward-slash form Docker Desktop's Linux daemon expects for bind-mount
/// sources (`/c/Users/x`). No-op on non-Windows hosts and on paths that
/// don't look like a drive-letter path.
fn toBindSource(alloc: std.mem.Allocator, path: []const u8) ![]const u8 {
    if (builtin.os.tag != .windows) return path;
    if (path.len < 2 or path[1] != ':') return path;
    var out: std.ArrayList(u8) = .empty;
    try out.append(alloc, '/');
    try out.append(alloc, std.ascii.toLower(path[0]));
    for (path[2..]) |ch| try out.append(alloc, if (ch == '\\') '/' else ch);
    return out.toOwnedSlice(alloc);
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

/// Builds the JSON body for `POST /containers/create`: the sleep-infinity
/// long-lived container that job steps get exec'd into.
fn buildContainerCreateSpec(alloc: std.mem.Allocator, image: []const u8, env: []const []const u8, workspace_abs: []const u8, network_id: ?[]const u8) ![]u8 {
    const bind_source = try toBindSource(alloc, workspace_abs);
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(alloc, "{\"Image\":");
    try jsonStrAppend(&out, alloc, image);
    try out.appendSlice(alloc, ",\"Cmd\":[\"sleep\",\"infinity\"],\"Env\":[");
    for (env, 0..) |kv, i| {
        if (i > 0) try out.append(alloc, ',');
        try jsonStrAppend(&out, alloc, kv);
    }
    try out.appendSlice(alloc, "],\"HostConfig\":{\"Binds\":[");
    const bind = try std.fmt.allocPrint(alloc, "{s}:/github/workspace", .{bind_source});
    try jsonStrAppend(&out, alloc, bind);
    try out.append(alloc, ']');
    if (network_id) |nid| {
        try out.appendSlice(alloc, ",\"NetworkMode\":");
        try jsonStrAppend(&out, alloc, nid);
    }
    try out.appendSlice(alloc, "},\"WorkingDir\":\"/github/workspace\"}");
    return out.toOwnedSlice(alloc);
}

/// Parses `k=v` lines (as written to `GITHUB_OUTPUT`) into `ir.EnvPair`s.
/// Same shape as `backend/native.zig`'s inline parser.
fn parseOutputs(alloc: std.mem.Allocator, data: []const u8) ![]ir.EnvPair {
    var outputs: std.ArrayList(ir.EnvPair) = .empty;
    var it = std.mem.splitScalar(u8, data, '\n');
    while (it.next()) |line| {
        const l = std.mem.trim(u8, line, " \r");
        if (std.mem.indexOfScalar(u8, l, '=')) |eq| {
            if (eq > 0) try outputs.append(alloc, .{ .name = l[0..eq], .value = l[eq + 1 ..] });
        }
    }
    return outputs.toOwnedSlice(alloc);
}

pub const DockerBackend = struct {
    client: client.Client,
    cfg: config.Config = .{},

    pub fn backend(self: *DockerBackend) backend_iface.Backend {
        return .{ .ctx = @ptrCast(self), .vtable = &vtable };
    }
};

const vtable = backend_iface.Backend.VTable{
    .setupJob = setup,
    .runStep = run,
    .teardownJob = teardown,
};

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

    const container_env = try formatEnvPairs(alloc, job.env, &.{ "CI=true", "GITHUB_ACTIONS=true", "JALAN=true" });
    const spec = try buildContainerCreateSpec(alloc, image, container_env, workspace_abs, null);
    const id = client.containerCreate(alloc, self.client, spec, null, &err) catch |e| {
        if (log) |l| if (err) |m| l(m);
        return e;
    };
    client.containerStart(alloc, self.client, id, &err) catch |e| {
        if (log) |l| if (err) |m| l(m);
        return e;
    };

    return .{ .container_id = id, .workspace = workspace_abs };
}

fn run(ctx: *anyopaque, alloc: std.mem.Allocator, handle: *backend_iface.JobHandle, step: ir.Step, env: []const ir.EnvPair, workdir: ?[]const u8, err_msg: *?[]const u8) anyerror!backend_iface.StepOutcome {
    const self: *DockerBackend = @ptrCast(@alignCast(ctx));
    const safe_id = try sanitizeStepId(alloc, step.id);
    const script_name = try std.fmt.allocPrint(alloc, "step-{s}.sh", .{safe_id});
    const script_path = try std.fmt.allocPrint(alloc, "/tmp/{s}", .{script_name});
    const out_path = try std.fmt.allocPrint(alloc, "/tmp/out-{s}.txt", .{safe_id});

    const argv = shellArgv(alloc, step.shell, script_path) catch {
        err_msg.* = try std.fmt.allocPrint(alloc, "shell '{s}' not available in linux containers", .{step.shell orelse "bash"});
        return error.SpawnFailed;
    };

    var err: ?[]const u8 = null;
    const tar_bytes = try client.tarSingleFile(alloc, script_name, step.script, 0o755);
    client.putArchive(alloc, self.client, handle.container_id, "/tmp", tar_bytes, &err) catch |e| {
        err_msg.* = err;
        return e;
    };

    const github_output = try std.fmt.allocPrint(alloc, "GITHUB_OUTPUT={s}", .{out_path});
    const exec_env = try formatEnvPairs(alloc, env, &.{github_output});

    const exec_result = client.execRun(alloc, self.client, handle.container_id, argv, exec_env, workdir, &err) catch |e| {
        err_msg.* = err;
        if (e == error.ExecTimeout) return error.SpawnFailed;
        return e;
    };

    var outputs: []ir.EnvPair = &.{};
    var cat_err: ?[]const u8 = null;
    const cat_result: ?client.ExecResult = client.execRun(alloc, self.client, handle.container_id, &.{ "cat", out_path }, &.{}, null, &cat_err) catch null;
    if (cat_result) |cr| outputs = try parseOutputs(alloc, cr.stdout);

    return .{
        .exit_code = exec_result.exit_code,
        .stdout = exec_result.stdout,
        .stderr = exec_result.stderr,
        .outputs = outputs,
    };
}

fn teardown(ctx: *anyopaque, alloc: std.mem.Allocator, handle: *backend_iface.JobHandle) void {
    const self: *DockerBackend = @ptrCast(@alignCast(ctx));
    if (handle.container_id.len > 0) {
        var err: ?[]const u8 = null;
        client.containerRemove(alloc, self.client, handle.container_id, &err) catch {};
    }
    if (handle.network_id.len > 0) {
        var err: ?[]const u8 = null;
        client.networkRemove(alloc, self.client, handle.network_id, &err) catch {};
    }
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
    const spec = try buildContainerCreateSpec(a, "node:20-bookworm-slim", &.{"CI=true"}, "/home/user/proj", null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"Image\":\"node:20-bookworm-slim\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"Cmd\":[\"sleep\",\"infinity\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "/home/user/proj:/github/workspace") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"CI=true\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, spec, "\"WorkingDir\":\"/github/workspace\"") != null);
}

test "parseOutputs parses k=v lines, ignores blanks and malformed lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const outs = try parseOutputs(a, "k=v\n\nbad-line\nver=1.2\r\n");
    try std.testing.expectEqual(@as(usize, 2), outs.len);
    try std.testing.expectEqualStrings("k", outs[0].name);
    try std.testing.expectEqualStrings("v", outs[0].value);
    try std.testing.expectEqualStrings("ver", outs[1].name);
    try std.testing.expectEqualStrings("1.2", outs[1].value);
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
    const s1 = ir.Step{ .id = "a", .name = "a", .kind = .run, .script = "echo one > /tmp/marker && echo \"k=v\" >> \"$GITHUB_OUTPUT\"" };
    const o1 = try b.runStep(a, &h, s1, &.{}, null, &em);
    try std.testing.expectEqual(@as(i32, 0), o1.exit_code);
    try std.testing.expectEqualStrings("k", o1.outputs[0].name);
    const s2 = ir.Step{ .id = "b", .name = "b", .kind = .run, .script = "cat /tmp/marker" };
    const o2 = try b.runStep(a, &h, s2, &.{}, null, &em);
    try std.testing.expect(std.mem.indexOf(u8, o2.stdout, "one") != null);
}
