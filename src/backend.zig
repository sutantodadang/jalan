//! Backend interface: job-scoped execution vtable. `native()` is the first
//! (and, for phase 2 task 2, only) implementation — it forwards to the
//! existing subprocess-based step runner in `backend/native.zig`.
const std = @import("std");
const ir = @import("ir.zig");

pub const StepOutcome = struct {
    exit_code: i32,
    stdout: []u8,
    stderr: []u8,
    outputs: []ir.EnvPair,
};

pub const JobHandle = struct {
    container_id: []const u8 = "",
    network_id: []const u8 = "",
    service_ids: []const []const u8 = &.{},
    workspace: []const u8 = "",
};

pub const LogFn = *const fn (line: []const u8) void;

/// Which concrete backend a `Backend` value wraps. `runUses` (in
/// `actions/runner.zig`) needs this to decide things the vtable alone can't
/// express: whether `docker://` container actions are even possible
/// (`runContainerAction` is only non-null for `.docker`, but the marker is
/// cheaper to branch on than an optional-fn null check at every call site),
/// whether a local JS action is allowed to run inside a container (`.docker`
/// + a workspace-relative action, vs. a remote one — phase 2.1), and whether
/// `setup-node`/`setup-python`/`setup-go` should be intercepted as nix
/// package installs (`.nix` only).
pub const Kind = enum { native, docker, nix };

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
};

var native_ctx: u8 = 0;

const native_vtable = Backend.VTable{
    .setupJob = nativeSetup,
    .runStep = nativeRun,
    .teardownJob = nativeTeardown,
};

pub fn native() Backend {
    return .{ .ctx = @ptrCast(&native_ctx), .vtable = &native_vtable, .kind = .native };
}

fn nativeSetup(_: *anyopaque, _: std.mem.Allocator, _: ir.Job, workspace_abs: []const u8, _: ?LogFn) anyerror!JobHandle {
    return .{ .workspace = workspace_abs };
}
fn nativeRun(_: *anyopaque, alloc: std.mem.Allocator, _: *JobHandle, step: ir.Step, env: []const ir.EnvPair, workdir: ?[]const u8, err_msg: *?[]const u8) anyerror!StepOutcome {
    return native_impl.runStep(alloc, step, env, workdir, err_msg);
}
fn nativeTeardown(_: *anyopaque, _: std.mem.Allocator, _: *JobHandle) void {}

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
