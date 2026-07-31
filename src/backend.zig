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

pub const Backend = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        setupJob: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, job: ir.Job, workspace_abs: []const u8, log: ?LogFn) anyerror!JobHandle,
        runStep: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, handle: *JobHandle, step: ir.Step, env: []const ir.EnvPair, workdir: ?[]const u8, err_msg: *?[]const u8) anyerror!StepOutcome,
        teardownJob: *const fn (ctx: *anyopaque, alloc: std.mem.Allocator, handle: *JobHandle) void,
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
};

var native_ctx: u8 = 0;

const native_vtable = Backend.VTable{
    .setupJob = nativeSetup,
    .runStep = nativeRun,
    .teardownJob = nativeTeardown,
};

pub fn native() Backend {
    return .{ .ctx = @ptrCast(&native_ctx), .vtable = &native_vtable };
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
