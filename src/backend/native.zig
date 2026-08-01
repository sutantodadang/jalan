//! Native shell backend: executes pipeline steps as real subprocesses.
const std = @import("std");
const ir = @import("../ir.zig");
const builtin = @import("builtin");

pub const StepOutcome = @import("../backend.zig").StepOutcome;

pub const RunError = error{ SpawnFailed, OutOfMemory };

const Shell = struct { name: []const u8, ext: []const u8, argv_prefix: []const []const u8 };

fn shellTable(name: []const u8) ?Shell {
    const shells = [_]Shell{
        .{ .name = "bash", .ext = ".sh", .argv_prefix = &.{ "bash", "-eo", "pipefail" } },
        .{ .name = "sh", .ext = ".sh", .argv_prefix = &.{ "sh", "-e" } },
        .{ .name = "pwsh", .ext = ".ps1", .argv_prefix = &.{ "pwsh", "-NoProfile", "-File" } },
        .{ .name = "powershell", .ext = ".ps1", .argv_prefix = &.{ "powershell", "-NoProfile", "-File" } },
        .{ .name = "cmd", .ext = ".cmd", .argv_prefix = &.{ "cmd", "/d", "/c" } },
        .{ .name = "python", .ext = ".py", .argv_prefix = &.{"python"} },
    };
    for (shells) |s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

fn whereExe(alloc: std.mem.Allocator, exe: []const u8) ?[]const u8 {
    if (builtin.os.tag == .windows) {
        const r = std.process.Child.run(.{ .allocator = alloc, .argv = &.{ "where", exe } }) catch return null;
        if (r.term == .Exited and r.term.Exited == 0) {
            var it = std.mem.splitScalar(u8, r.stdout, '\n');
            while (it.next()) |line| {
                const t = std.mem.trim(u8, line, " \r\n");
                if (t.len == 0) continue;
                if (std.ascii.indexOfIgnoreCase(t, "\\Program Files\\WindowsApps\\") != null) continue;
                // `where` may return packaged WindowsApps paths before the
                // per-user app alias. Some package directories are listed but
                // deny traversal to ordinary processes; skip those candidates
                // instead of handing Child.spawn a guaranteed AccessDenied.
                std.fs.cwd().access(t, .{}) catch continue;
                return t;
            }
        }
        return null;
    }
    const cmd = std.fmt.allocPrint(alloc, "command -v {s}", .{exe}) catch return null;
    const r = std.process.Child.run(.{ .allocator = alloc, .argv = &.{ "sh", "-c", cmd } }) catch return null;
    if (r.term == .Exited and r.term.Exited == 0) {
        const t = std.mem.trim(u8, r.stdout, " \r\n");
        if (t.len > 0) return t;
    }
    return null;
}

fn onPath(alloc: std.mem.Allocator, exe: []const u8) bool {
    return whereExe(alloc, exe) != null;
}

fn gitBashExe(alloc: std.mem.Allocator, name: []const u8) ?[]const u8 {
    if (builtin.os.tag != .windows) return null;
    const env_names = [_][]const u8{ "ProgramFiles", "LOCALAPPDATA", "ProgramW6432" };
    const rels = [_][]const u8{ "", "\\Programs" };
    for (env_names) |env_name| {
        const base = std.process.getEnvVarOwned(alloc, env_name) catch continue;
        for (rels) |rel| {
            const p = std.fmt.allocPrint(alloc, "{s}{s}\\Git\\bin\\{s}.exe", .{ base, rel, name }) catch continue;
            std.fs.cwd().access(p, .{}) catch continue;
            return p;
        }
    }
    return null;
}

fn resolveExe(alloc: std.mem.Allocator, name: []const u8) []const u8 {
    if (whereExe(alloc, name)) |p| return p;
    if (gitBashExe(alloc, name)) |p| return p;
    return name;
}

fn defaultShell(alloc: std.mem.Allocator) Shell {
    if (builtin.os.tag == .windows) {
        if (onPath(alloc, "pwsh")) return shellTable("pwsh").?;
        if (onPath(alloc, "powershell")) return shellTable("powershell").?;
        return shellTable("cmd").?;
    }
    if (onPath(alloc, "bash")) return shellTable("bash").?;
    return shellTable("sh").?;
}

pub fn runStep(
    alloc: std.mem.Allocator,
    step: ir.Step,
    env: []const ir.EnvPair,
    workdir: ?[]const u8,
    err_msg: *?[]const u8,
) RunError!StepOutcome {
    const shell = if (step.shell) |name|
        shellTable(name) orelse {
            err_msg.* = std.fmt.allocPrint(alloc, "unknown shell '{s}'", .{name}) catch null;
            return error.SpawnFailed;
        }
    else
        defaultShell(alloc);

    std.fs.cwd().makePath(".jalan/tmp") catch {
        err_msg.* = "cannot create .jalan/tmp";
        return error.SpawnFailed;
    };
    var rand_buf: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_buf);
    const tag = std.fmt.bytesToHex(rand_buf, .lower);
    const script_path = std.fmt.allocPrint(alloc, ".jalan/tmp/step-{s}{s}", .{ tag, shell.ext }) catch return error.OutOfMemory;
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

    var argv: std.ArrayList([]const u8) = .empty;
    argv.append(alloc, resolveExe(alloc, shell.name)) catch return error.OutOfMemory;
    for (shell.argv_prefix[1..]) |a| argv.append(alloc, a) catch return error.OutOfMemory;
    const abs_script = std.fs.cwd().realpathAlloc(alloc, script_path) catch |e| {
        err_msg.* = std.fmt.allocPrint(
            alloc,
            "cannot resolve script path '{s}': {s}",
            .{ script_path, @errorName(e) },
        ) catch null;
        return error.SpawnFailed;
    };
    argv.append(alloc, abs_script) catch return error.OutOfMemory;

    const result = std.process.Child.run(.{
        .allocator = alloc,
        .argv = argv.items,
        .cwd = workdir,
        .env_map = &env_map,
        .max_output_bytes = 16 * 1024 * 1024,
    }) catch |e| {
        err_msg.* = std.fmt.allocPrint(
            alloc,
            "{s} not found or failed to spawn ({s}) — install it or set shell:",
            .{ shell.name, @errorName(e) },
        ) catch null;
        return error.SpawnFailed;
    };

    const code: i32 = switch (result.term) {
        .Exited => |c| @intCast(c),
        else => -1,
    };
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

/// Spawn the platform default shell with inherited stdio so the user can
/// inspect and modify the same workspace/environment as the failed step.
pub fn openShell(alloc: std.mem.Allocator, workdir: ?[]const u8, env: []const ir.EnvPair) RunError!void {
    const shell = defaultShell(alloc);
    var env_map = std.process.getEnvMap(alloc) catch return error.OutOfMemory;
    for (env) |pair| env_map.put(pair.name, pair.value) catch return error.OutOfMemory;

    var child = std.process.Child.init(&.{resolveExe(alloc, shell.name)}, alloc);
    child.cwd = workdir;
    child.env_map = &env_map;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    child.spawn() catch return error.SpawnFailed;
    _ = child.wait() catch return error.SpawnFailed;
}

test "run echo step captures stdout and exit code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const step = ir.Step{ .id = "s", .name = "s", .kind = .run, .script = "echo hello-jalan" };
    var err_msg: ?[]const u8 = null;
    const out = try runStep(a, step, &.{}, null, &err_msg);
    try std.testing.expectEqual(@as(i32, 0), out.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, out.stdout, "hello-jalan") != null);
}

test "failing step returns nonzero exit code" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const step = ir.Step{ .id = "s", .name = "s", .kind = .run, .script = "exit 3" };
    var err_msg: ?[]const u8 = null;
    const out = try runStep(a, step, &.{}, null, &err_msg);
    try std.testing.expectEqual(@as(i32, 3), out.exit_code);
}

test "step outputs parsed from GITHUB_OUTPUT" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const script = if (builtin.os.tag == .windows)
        "echo ver=1.2 >> \"%GITHUB_OUTPUT%\""
    else
        "echo \"ver=1.2\" >> \"$GITHUB_OUTPUT\"";
    const shell: ?[]const u8 = if (builtin.os.tag == .windows) "cmd" else null;
    const step = ir.Step{ .id = "s", .name = "s", .kind = .run, .script = script, .shell = shell };
    var err_msg: ?[]const u8 = null;
    const out = try runStep(a, step, &.{}, null, &err_msg);
    try std.testing.expectEqualStrings("ver", out.outputs[0].name);
    try std.testing.expectEqualStrings("1.2", std.mem.trim(u8, out.outputs[0].value, " "));
}

test "step with workdir set resolves script and output paths correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.fs.cwd().makePath(".jalan/tmp/wdtest");
    const step = ir.Step{ .id = "s", .name = "s", .kind = .run, .script = "echo from-workdir" };
    var err_msg: ?[]const u8 = null;
    const out = try runStep(a, step, &.{}, ".jalan/tmp/wdtest", &err_msg);
    try std.testing.expectEqual(@as(i32, 0), out.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, out.stdout, "from-workdir") != null);
}
