//! Nix backend: runs job steps inside `nix shell` with a configurable
//! package set. `services:`/`container:` aren't supported here (that's the
//! docker backend's job) — `setupJob` just warns and skips them.
const std = @import("std");
const builtin = @import("builtin");
const ir = @import("../ir.zig");
const config = @import("../config.zig");
const backend_iface = @import("../backend.zig");

/// Packages used when `Config.nix_packages` is empty. `bash` + `coreutils`
/// cover the shell/script step this backend runs; `nodejs_22` mirrors the
/// docker backend's default image so `uses:` actions relying on Node work
/// out of the box.
pub const default_packages = [_][]const u8{ "bash", "coreutils", "nodejs_22" };

/// Spawns `nix --version`; exit 0 means nix is on PATH and usable. Any spawn
/// error (nix missing, PATH issue, etc.) is treated as unavailable. Callers
/// (the CLI, before constructing `NixBackend`) should check this once up
/// front — the backend itself assumes availability and doesn't re-check.
pub fn nixAvailable(alloc: std.mem.Allocator) bool {
    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = &.{ "nix", "--version" },
    }) catch return false;
    return result.term == .Exited and result.term.Exited == 0;
}

/// Pure argv builder: `["nix", "shell"] ++ ["nixpkgs#<p>", ...] ++
/// ["--command"] ++ shell_cmd`. `packages` empty falls back to
/// `default_packages`. No I/O, no allocation beyond the returned slice.
pub fn buildArgv(alloc: std.mem.Allocator, packages: []const []const u8, shell_cmd: []const []const u8) ![]const []const u8 {
    return buildArgvImpl(alloc, packages, shell_cmd, false);
}

/// Same as `buildArgv` but inserts `--extra-experimental-features
/// "nix-command flakes"` right after `shell` (flags must precede
/// `--command`). Used for the one-shot retry when a first attempt fails
/// because those features aren't enabled in the user's nix.conf.
fn buildArgvExperimental(alloc: std.mem.Allocator, packages: []const []const u8, shell_cmd: []const []const u8) ![]const []const u8 {
    return buildArgvImpl(alloc, packages, shell_cmd, true);
}

fn buildArgvImpl(alloc: std.mem.Allocator, packages: []const []const u8, shell_cmd: []const []const u8, experimental: bool) ![]const []const u8 {
    const pkgs = if (packages.len > 0) packages else &default_packages;
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(alloc, "nix");
    try argv.append(alloc, "shell");
    if (experimental) {
        try argv.append(alloc, "--extra-experimental-features");
        try argv.append(alloc, "nix-command flakes");
    }
    for (pkgs) |p| {
        try argv.append(alloc, try std.fmt.allocPrint(alloc, "nixpkgs#{s}", .{p}));
    }
    try argv.append(alloc, "--command");
    try argv.appendSlice(alloc, shell_cmd);
    return argv.toOwnedSlice(alloc);
}

pub const NixBackend = struct {
    cfg: config.Config = .{},

    pub fn backend(self: *NixBackend) backend_iface.Backend {
        return .{ .ctx = @ptrCast(self), .vtable = &vtable, .kind = .nix };
    }
};

const vtable = backend_iface.Backend.VTable{
    .setupJob = setup,
    .runStep = run,
    .teardownJob = teardown,
    .openShell = openShell,
    .cacheIdentity = cacheIdentity,
};

fn cacheIdentity(ctx: *anyopaque, alloc: std.mem.Allocator, _: ir.Job, handle: *backend_iface.JobHandle, _: ir.Step) anyerror![]const u8 {
    const self: *NixBackend = @ptrCast(@alignCast(ctx));
    const packages = try effectivePackages(alloc, self.cfg.nix_packages, handle.nix_packages);
    return std.fmt.allocPrint(alloc, "derivations:{s};host:{s}", .{
        try resolvedPackageIdentity(alloc, packages),
        try backend_iface.hostEnvironmentIdentity(alloc),
    });
}

/// Resolve each registry package to its immutable Nix store output path.
/// Failure disables caching for the step (the caller treats identity errors
/// as a miss), which is safer than keying mutable `nixpkgs#name` references.
fn resolvedPackageIdentity(alloc: std.mem.Allocator, packages: []const []const u8) ![]const u8 {
    var paths: std.ArrayList([]const u8) = .empty;
    for (packages) |package| {
        const installable = try std.fmt.allocPrint(alloc, "nixpkgs#{s}.outPath", .{package});
        const normal = [_][]const u8{ "nix", "eval", "--raw", installable };
        var result = try std.process.Child.run(.{ .allocator = alloc, .argv = &normal });
        if (result.term != .Exited or result.term.Exited != 0) {
            const experimental = [_][]const u8{ "nix", "--extra-experimental-features", "nix-command flakes", "eval", "--raw", installable };
            result = try std.process.Child.run(.{ .allocator = alloc, .argv = &experimental });
        }
        if (result.term != .Exited or result.term.Exited != 0) return error.NixIdentityUnavailable;
        const path = std.mem.trim(u8, result.stdout, " \t\r\n");
        if (path.len == 0) return error.NixIdentityUnavailable;
        try paths.append(alloc, path);
    }
    return std.mem.join(alloc, ",", paths.items);
}

fn setup(_: *anyopaque, _: std.mem.Allocator, job: ir.Job, workspace_abs: []const u8, log: ?backend_iface.LogFn) anyerror!backend_iface.JobHandle {
    if (job.services.len > 0 or job.container_image.len > 0) {
        if (log) |l| l("services/container require the docker backend — skipped");
    }
    return .{ .workspace = workspace_abs };
}

fn teardown(_: *anyopaque, _: std.mem.Allocator, _: *backend_iface.JobHandle) void {}

fn openShell(ctx: *anyopaque, alloc: std.mem.Allocator, handle: *backend_iface.JobHandle, workdir: ?[]const u8, env: []const ir.EnvPair) anyerror!void {
    const self: *NixBackend = @ptrCast(@alignCast(ctx));
    const packages = try effectivePackages(alloc, self.cfg.nix_packages, handle.nix_packages);
    var env_map = try std.process.getEnvMap(alloc);
    for (env) |pair| try env_map.put(pair.name, pair.value);

    const argv = try buildArgv(alloc, packages, &.{"bash"});
    const code = try spawnInteractive(alloc, argv, workdir, &env_map);
    if (code != 0) {
        const retry_argv = try buildArgvExperimental(alloc, packages, &.{"bash"});
        _ = try spawnInteractive(alloc, retry_argv, workdir, &env_map);
    }
}

fn spawnInteractive(alloc: std.mem.Allocator, argv: []const []const u8, workdir: ?[]const u8, env_map: *const std.process.EnvMap) !i32 {
    var child = std.process.Child.init(argv, alloc);
    child.cwd = workdir;
    child.env_map = env_map;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    try child.spawn();
    const term = try child.wait();
    return switch (term) {
        .Exited => |code| @intCast(code),
        else => -1,
    };
}

fn containsPkg(list: []const []const u8, name: []const u8) bool {
    for (list) |p| if (std.mem.eql(u8, p, name)) return true;
    return false;
}

/// Pure merge: `cfg_packages` (or `default_packages` when empty) plus any
/// `handle_packages` not already in that set — dedupes so a step that runs
/// after two different `setup-*` interceptions (or a `setup-*` whose package
/// happens to already be in `cfg_packages`) doesn't pass `nix shell` the
/// same `nixpkgs#foo` argument twice. `handle_packages` come from
/// `JobHandle.nix_packages` (see its doc comment) — kept out of `cfg` itself
/// since `cfg` is shared across parallel jobs.
pub fn effectivePackages(alloc: std.mem.Allocator, cfg_packages: []const []const u8, handle_packages: []const []const u8) ![]const []const u8 {
    const base = if (cfg_packages.len > 0) cfg_packages else &default_packages;
    var out: std.ArrayList([]const u8) = .empty;
    try out.appendSlice(alloc, base);
    for (handle_packages) |p| {
        if (!containsPkg(out.items, p)) try out.append(alloc, p);
    }
    return out.toOwnedSlice(alloc);
}

/// Mirrors `backend/native.zig`'s `runStep`: write the step script to
/// `.jalan/tmp`, build an env map (inherited + step env + CI markers +
/// GITHUB_OUTPUT), spawn, parse `GITHUB_OUTPUT` back into `outputs`, clean up
/// temp files. Only the argv differs (`nix shell ... --command bash
/// <script>` instead of a bare shell invocation) plus the experimental-
/// features retry. ~30 lines of duplication vs. native, acceptable for phase
/// 2 — a shared helper is a good follow-up once a third backend needs it.
fn run(ctx: *anyopaque, alloc: std.mem.Allocator, handle: *backend_iface.JobHandle, step: ir.Step, env: []const ir.EnvPair, workdir: ?[]const u8, err_msg: *?[]const u8) anyerror!backend_iface.StepOutcome {
    const self: *NixBackend = @ptrCast(@alignCast(ctx));
    const packages = effectivePackages(alloc, self.cfg.nix_packages, handle.nix_packages) catch return error.OutOfMemory;

    std.fs.cwd().makePath(".jalan/tmp") catch {
        err_msg.* = "cannot create .jalan/tmp";
        return error.SpawnFailed;
    };
    var rand_buf: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_buf);
    const tag = std.fmt.bytesToHex(rand_buf, .lower);
    const script_path = std.fmt.allocPrint(alloc, ".jalan/tmp/step-{s}.sh", .{tag}) catch return error.OutOfMemory;
    const output_path = std.fmt.allocPrint(alloc, ".jalan/tmp/out-{s}.txt", .{tag}) catch return error.OutOfMemory;
    std.fs.cwd().writeFile(.{ .sub_path = script_path, .data = step.script }) catch {
        err_msg.* = "cannot write step script";
        return error.SpawnFailed;
    };
    std.fs.cwd().writeFile(.{ .sub_path = output_path, .data = "" }) catch {};
    defer std.fs.cwd().deleteFile(script_path) catch {};
    defer std.fs.cwd().deleteFile(output_path) catch {};

    var env_map = std.process.getEnvMap(alloc) catch return error.OutOfMemory;
    for (env) |p| env_map.put(p.name, p.value) catch return error.OutOfMemory;
    env_map.put("CI", "true") catch return error.OutOfMemory;
    env_map.put("GITHUB_ACTIONS", "true") catch return error.OutOfMemory;
    env_map.put("JALAN", "true") catch return error.OutOfMemory;
    const abs_output = std.fs.cwd().realpathAlloc(alloc, output_path) catch |e| {
        err_msg.* = std.fmt.allocPrint(
            alloc,
            "cannot resolve output path '{s}': {s}",
            .{ output_path, @errorName(e) },
        ) catch null;
        return error.SpawnFailed;
    };
    env_map.put("GITHUB_OUTPUT", abs_output) catch return error.OutOfMemory;

    const abs_script = std.fs.cwd().realpathAlloc(alloc, script_path) catch |e| {
        err_msg.* = std.fmt.allocPrint(
            alloc,
            "cannot resolve script path '{s}': {s}",
            .{ script_path, @errorName(e) },
        ) catch null;
        return error.SpawnFailed;
    };

    const shell_cmd: []const []const u8 = &.{ "bash", abs_script };
    const argv = buildArgv(alloc, packages, shell_cmd) catch return error.OutOfMemory;

    var result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = argv,
        .cwd = workdir,
        .env_map = &env_map,
        .max_output_bytes = 16 * 1024 * 1024,
    }) catch |e| {
        return spawnFailed(alloc, err_msg, e);
    };

    var code: i32 = switch (result.term) {
        .Exited => |c| @intCast(c),
        else => -1,
    };

    if (code != 0 and std.mem.indexOf(u8, result.stderr, "experimental") != null) {
        const retry_argv = buildArgvExperimental(alloc, packages, shell_cmd) catch return error.OutOfMemory;
        result = std.process.Child.run(.{
            .allocator = alloc,
            .argv = retry_argv,
            .cwd = workdir,
            .env_map = &env_map,
            .max_output_bytes = 16 * 1024 * 1024,
        }) catch |e| {
            return spawnFailed(alloc, err_msg, e);
        };
        code = switch (result.term) {
            .Exited => |c| @intCast(c),
            else => -1,
        };
    }

    var outputs: std.ArrayList(ir.EnvPair) = .empty;
    if (std.fs.cwd().readFileAlloc(alloc, output_path, 1024 * 1024) catch null) |data| {
        var it = std.mem.splitScalar(u8, data, '\n');
        while (it.next()) |line| {
            const l = std.mem.trim(u8, line, " \r");
            if (std.mem.indexOfScalar(u8, l, '=')) |eq| {
                if (eq > 0) outputs.append(alloc, .{
                    .name = l[0..eq],
                    .value = l[eq + 1 ..],
                }) catch return error.OutOfMemory;
            }
        }
    }
    return .{
        .exit_code = code,
        .stdout = result.stdout,
        .stderr = result.stderr,
        .outputs = outputs.toOwnedSlice(alloc) catch return error.OutOfMemory,
    };
}

fn spawnFailed(alloc: std.mem.Allocator, err_msg: *?[]const u8, e: anyerror) anyerror {
    const suffix = if (builtin.os.tag == .windows) " — Nix requires WSL2 on Windows" else "";
    err_msg.* = std.fmt.allocPrint(
        alloc,
        "nix not found or failed to spawn ({s}){s}",
        .{ @errorName(e), suffix },
    ) catch null;
    return error.SpawnFailed;
}

test "buildArgv: explicit packages produce exact argv" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try buildArgv(a, &.{ "nodejs_22", "git" }, &.{ "echo", "hi" });
    try std.testing.expectEqual(@as(usize, 7), argv.len);
    try std.testing.expectEqualStrings("nix", argv[0]);
    try std.testing.expectEqualStrings("shell", argv[1]);
    try std.testing.expectEqualStrings("nixpkgs#nodejs_22", argv[2]);
    try std.testing.expectEqualStrings("nixpkgs#git", argv[3]);
    try std.testing.expectEqualStrings("--command", argv[4]);
    try std.testing.expectEqualStrings("echo", argv[5]);
    try std.testing.expectEqualStrings("hi", argv[6]);
}

test "buildArgv: empty packages fall back to default_packages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const argv = try buildArgv(a, &.{}, &.{ "bash", "-c", "true" });
    try std.testing.expectEqual(@as(usize, 2 + default_packages.len + 1 + 3), argv.len);
    try std.testing.expectEqualStrings("nixpkgs#bash", argv[2]);
    try std.testing.expectEqualStrings("nixpkgs#coreutils", argv[3]);
    try std.testing.expectEqualStrings("nixpkgs#nodejs_22", argv[4]);
    try std.testing.expectEqualStrings("--command", argv[5]);
}

test "effectivePackages: cfg + handle packages merge into buildArgv, deduped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const merged = try effectivePackages(a, &.{"bash"}, &.{"python3"});
    try std.testing.expectEqual(@as(usize, 2), merged.len);
    try std.testing.expectEqualStrings("bash", merged[0]);
    try std.testing.expectEqualStrings("python3", merged[1]);

    const argv = try buildArgv(a, merged, &.{ "echo", "hi" });
    var saw_bash = false;
    var saw_python = false;
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, "nixpkgs#bash")) saw_bash = true;
        if (std.mem.eql(u8, arg, "nixpkgs#python3")) saw_python = true;
    }
    try std.testing.expect(saw_bash);
    try std.testing.expect(saw_python);
}

test "effectivePackages: handle package already in cfg is not duplicated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const merged = try effectivePackages(a, &.{ "bash", "python3" }, &.{"python3"});
    try std.testing.expectEqual(@as(usize, 2), merged.len);
}

test "effectivePackages: empty cfg falls back to default_packages before merging" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const merged = try effectivePackages(a, &.{}, &.{"python3"});
    try std.testing.expectEqual(@as(usize, default_packages.len + 1), merged.len);
    try std.testing.expectEqualStrings("python3", merged[merged.len - 1]);
}

test "setupJob warns and skips when job has services or container" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var nb = NixBackend{};
    const b = nb.backend();
    const Capture = struct {
        var msg: ?[]const u8 = null;
        fn log(line: []const u8) void {
            msg = line;
        }
    };
    var services = [_]ir.Service{.{ .name = "redis", .image = "redis:7" }};
    var handle = try b.setupJob(a, .{ .id = "j", .display_name = "j", .steps = &.{}, .services = &services }, "/tmp/ws", Capture.log);
    defer b.teardownJob(a, &handle);
    try std.testing.expect(Capture.msg != null);
    try std.testing.expect(std.mem.indexOf(u8, Capture.msg.?, "docker backend") != null);
    try std.testing.expectEqualStrings("/tmp/ws", handle.workspace);
}

test "nix backend runs an echo step through the vtable (skips without nix)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    if (!nixAvailable(a)) return error.SkipZigTest;
    var nb = NixBackend{};
    const b = nb.backend();
    const cwd = try std.fs.cwd().realpathAlloc(a, ".");
    var handle = try b.setupJob(a, .{ .id = "j", .display_name = "j", .steps = &.{} }, cwd, null);
    defer b.teardownJob(a, &handle);
    var err_msg: ?[]const u8 = null;
    const step = ir.Step{ .id = "s", .name = "s", .kind = .run, .script = "echo via-nix" };
    const out = try b.runStep(a, &handle, step, &.{}, null, &err_msg);
    try std.testing.expectEqual(@as(i32, 0), out.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, out.stdout, "via-nix") != null);
}
