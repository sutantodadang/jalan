//! Backend interface: job-scoped execution vtable. `native()` is the first
//! (and, for phase 2 task 2, only) implementation — it forwards to the
//! existing subprocess-based step runner in `backend/native.zig`.
const std = @import("std");
const builtin = @import("builtin");
const ir = @import("ir.zig");

pub const StepOutcome = struct {
    exit_code: i32,
    stdout: []const u8,
    stderr: []const u8,
    outputs: []const ir.EnvPair,
};

pub const JobHandle = struct {
    container_id: []const u8 = "",
    network_id: []const u8 = "",
    service_ids: []const []const u8 = &.{},
    workspace: []const u8 = "",
    /// Immutable execution identity prepared by backends whose runtime is
    /// resolved during setup (for example Docker image IDs).
    cache_identity: []const u8 = "",
    provider: ir.Provider = .github_actions,
    /// Extra nix packages this job needs on top of `NixBackend.cfg`'s own
    /// (`Config.nix_packages`/`default_packages`) — populated by `runUses`'s
    /// `setup-node`/`setup-python`/`setup-go` interception on the nix
    /// backend. Per-job and arena-allocated, never written into `cfg`:
    /// `cfg` is shared across parallel jobs (see `RunOptions.exec_backend`),
    /// so mutating it from one job's step would leak into every other job
    /// running concurrently.
    nix_packages: []const []const u8 = &.{},
    /// Extra `PATH` prepends accumulated from prior steps' `GITHUB_PATH`
    /// writes in this job (e.g. a remote `setup-go` action installing a
    /// toolchain under `/opt/hostedtoolcache/...`). Populated by the docker
    /// backend's `runStep` after each step, consumed by the next step's
    /// shell prologue (`buildPrologue` in `backend/docker.zig`). Per-job and
    /// arena-allocated — same ownership pattern as `nix_packages`, never
    /// written back into anything shared across jobs.
    extra_paths: []const []const u8 = &.{},
    /// Extra environment variables accumulated from prior steps' `GITHUB_ENV`
    /// writes in this job, mirroring `extra_paths` above but for `NAME=value`
    /// exports rather than `PATH` entries. Same per-job, arena-allocated,
    /// docker-only ownership as `extra_paths`.
    extra_env: []const ir.EnvPair = &.{},
};

pub const LogFn = *const fn (line: []const u8) void;

/// Which concrete backend a `Backend` value wraps. `runUses` (in
/// `actions/runner.zig`) needs this to decide things the vtable alone can't
/// express: whether `docker://` container actions are even possible
/// (`runContainerAction` is only non-null for `.docker`, but the marker is
/// cheaper to branch on than an optional-fn null check at every call site),
/// whether a local JS action is allowed to run inside a container (`.docker`
/// + a workspace-relative action, resolved on the host filesystem, vs. a
/// remote one, tar-staged into the container via `stageActionDir`), and whether
/// `setup-node`/`setup-python`/`setup-go` should be intercepted as nix
/// package installs (`.nix` only).
pub const Kind = enum { native, docker, nix };

pub fn hostEnvironmentIdentity(alloc: std.mem.Allocator) ![]const u8 {
    var env = try std.process.getEnvMap(alloc);
    defer env.deinit();
    var pairs: std.ArrayList(ir.EnvPair) = .empty;
    var it = env.hash_map.iterator();
    while (it.next()) |entry|
        try pairs.append(alloc, .{ .name = entry.key_ptr.*, .value = entry.value_ptr.* });
    std.mem.sort(ir.EnvPair, pairs.items, {}, struct {
        fn less(_: void, a: ir.EnvPair, b: ir.EnvPair) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.less);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    for (pairs.items) |pair| {
        hash.update(pair.name);
        hash.update(&.{0});
        hash.update(pair.value);
        hash.update(&.{0});
    }
    var digest: [32]u8 = undefined;
    hash.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return alloc.dupe(u8, &hex);
}

pub const Backend = struct {
    ctx: *anyopaque,
    vtable: *const VTable,
    kind: Kind,

    pub const VTable = struct {
        setupJob: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, job: ir.Job, workspace_abs: []const u8, log: ?LogFn) anyerror!JobHandle,
        runStep: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, handle: *JobHandle, step: ir.Step, env: []const ir.EnvPair, workdir: ?[]const u8, err_msg: *?[]const u8) anyerror!StepOutcome,
        teardownJob: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, handle: *JobHandle) void,
        /// One-shot `docker://` action execution (create, start, wait, collect
        /// logs, remove). Optional: only `DockerBackend` implements it —
        /// native/nix leave this `null`, and `runUses` checks for that before
        /// calling it, warning + skipping `docker_image`-kind actions instead
        /// of dispatching into a backend that can't run them.
        runContainerAction: ?*const fn (ctx: *anyopaque, alloc: std.mem.Allocator, handle: *JobHandle, image: []const u8, cmd_args: []const []const u8, env_pairs: []const ir.EnvPair, err_msg: *?[]const u8) anyerror!StepOutcome = null,
        /// Open an interactive shell in the live job environment. Optional
        /// so custom/fake backends can explicitly decline debugger shells.
        openShell: ?*const fn (ctx: *anyopaque, alloc: std.mem.Allocator, handle: *JobHandle, workdir: ?[]const u8, env: []const ir.EnvPair) anyerror!void = null,
        /// Stable identity of the effective execution environment used by
        /// cache keys (selected Docker image, effective Nix packages, etc.).
        cacheIdentity: ?*const fn (ctx: *anyopaque, alloc: std.mem.Allocator, job: ir.Job, handle: *JobHandle, step: ir.Step) anyerror![]const u8 = null,
        /// Stages a host-side directory (a remote action's fetched/cached
        /// files) into the job's execution environment so a subsequent
        /// `node`/script invocation inside the container can reach it,
        /// returning the container-side absolute path it landed at. Docker
        /// only — `runUses` (`actions/runner.zig`) checks this is non-null
        /// before calling it, same pattern as `runContainerAction`; native
        /// and nix run `node` on the host, where the cache dir is already
        /// reachable, so they leave this `null`.
        stageActionDir: ?*const fn (ctx: *anyopaque, alloc: std.mem.Allocator, handle: *JobHandle, host_dir: []const u8, name: []const u8, err_msg: *?[]const u8) anyerror![]const u8 = null,
    };

    pub fn setupJob(self: Backend, alloc: std.mem.Allocator, job: ir.Job, workspace_abs: []const u8, log: ?LogFn) !JobHandle {
        return self.vtable.setupJob(self.ctx, alloc, job, workspace_abs, log);
    }
    pub fn runStep(self: Backend, alloc: std.mem.Allocator, handle: *JobHandle, step: ir.Step, env: []const ir.EnvPair, workdir: ?[]const u8, err_msg: *?[]const u8) !StepOutcome {
        return self.vtable.runStep(self.ctx, alloc, handle, step, env, workdir, err_msg);
    }
    pub fn teardownJob(self: Backend, alloc: std.mem.Allocator, handle: *JobHandle) void {
        self.vtable.teardownJob(self.ctx, alloc, handle);
    }
    /// Callers must check `self.vtable.runContainerAction != null` first
    /// (this asserts non-null rather than silently no-oping) — `runUses` is
    /// the one caller and it always checks before calling.
    pub fn runContainerAction(self: Backend, alloc: std.mem.Allocator, handle: *JobHandle, image: []const u8, cmd_args: []const []const u8, env_pairs: []const ir.EnvPair, err_msg: *?[]const u8) !StepOutcome {
        return self.vtable.runContainerAction.?(self.ctx, alloc, handle, image, cmd_args, env_pairs, err_msg);
    }
    pub fn openShell(self: Backend, alloc: std.mem.Allocator, handle: *JobHandle, workdir: ?[]const u8, env: []const ir.EnvPair) !void {
        return self.vtable.openShell.?(self.ctx, alloc, handle, workdir, env);
    }
    pub fn cacheIdentity(self: Backend, alloc: std.mem.Allocator, job: ir.Job, handle: *JobHandle, step: ir.Step) ![]const u8 {
        if (self.vtable.cacheIdentity) |identity| return identity(self.ctx, alloc, job, handle, step);
        return @tagName(self.kind);
    }
    /// Callers must check `self.vtable.stageActionDir != null` first (this
    /// asserts non-null rather than silently no-oping) — `runUses` is the one
    /// caller and it always checks before calling.
    pub fn stageActionDir(self: Backend, alloc: std.mem.Allocator, handle: *JobHandle, host_dir: []const u8, name: []const u8, err_msg: *?[]const u8) ![]const u8 {
        return self.vtable.stageActionDir.?(self.ctx, alloc, handle, host_dir, name, err_msg);
    }
};

var native_ctx: u8 = 0;

const native_vtable = Backend.VTable{
    .setupJob = nativeSetup,
    .runStep = nativeRun,
    .teardownJob = nativeTeardown,
    .openShell = nativeOpenShell,
    .cacheIdentity = nativeCacheIdentity,
};

pub fn native() Backend {
    return .{ .ctx = @ptrCast(&native_ctx), .vtable = &native_vtable, .kind = .native };
}

fn nativeSetup(_: *anyopaque, _: std.mem.Allocator, job: ir.Job, workspace_abs: []const u8, _: ?LogFn) anyerror!JobHandle {
    return .{ .workspace = workspace_abs, .provider = job.provider };
}
fn nativeRun(_: *anyopaque, alloc: std.mem.Allocator, handle: *JobHandle, step: ir.Step, env: []const ir.EnvPair, workdir: ?[]const u8, err_msg: *?[]const u8) anyerror!StepOutcome {
    return native_impl.runStepForProvider(alloc, handle.provider, step, env, workdir, err_msg);
}
fn nativeTeardown(_: *anyopaque, _: std.mem.Allocator, _: *JobHandle) void {}
fn nativeOpenShell(_: *anyopaque, alloc: std.mem.Allocator, _: *JobHandle, workdir: ?[]const u8, env: []const ir.EnvPair) anyerror!void {
    return native_impl.openShell(alloc, workdir, env);
}
fn nativeCacheIdentity(_: *anyopaque, alloc: std.mem.Allocator, _: ir.Job, _: *JobHandle, _: ir.Step) anyerror![]const u8 {
    return std.fmt.allocPrint(alloc, "{s}-{s}-{s}", .{
        @tagName(builtin.os.tag),
        @tagName(builtin.cpu.arch),
        try hostEnvironmentIdentity(alloc),
    });
}

const native_impl = @import("backend/native.zig");

test "native backend runs a step through the vtable" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const b = native();
    const cwd = try std.fs.cwd().realpathAlloc(a, ".");
    var handle = try b.setupJob(a, .{ .id = "j", .display_name = "j", .steps = &.{} }, cwd, null);
    defer b.teardownJob(a, &handle);
    var err_msg: ?[]const u8 = null;
    const step = ir.Step{ .id = "s", .name = "s", .kind = .run, .script = "echo via-vtable" };
    const out = try b.runStep(a, &handle, step, &.{}, null, &err_msg);
    try std.testing.expectEqual(@as(i32, 0), out.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, out.stdout, "via-vtable") != null);
}
