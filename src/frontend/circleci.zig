const std = @import("std");
const yaml = @import("../yaml.zig");
const ir = @import("../ir.zig");

pub const ParseError = error{ ParseFailed, OutOfMemory };

const recognized_root_keys = [_][]const u8{ "version", "orbs", "parameters", "commands", "executors", "jobs", "workflows" };
const job_supported_keys = [_][]const u8{ "docker", "machine", "macos", "executor", "environment", "working_directory", "parallelism", "resource_class", "steps" };
const step_skip_keys = [_][]const u8{
    "store_artifacts",     "store_test_results", "persist_to_workspace", "attach_workspace",
    "save_cache",          "restore_cache",       "setup_remote_docker",  "add_ssh_keys",
};
const docker_entry_keys = [_][]const u8{ "image", "name", "environment", "auth", "entrypoint", "command", "user" };

fn contains(list: []const []const u8, value: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, value)) return true;
    return false;
}

fn warn(diags: *yaml.Diags, node: yaml.Node, comptime fmt: []const u8, args: anytype) !void {
    try diags.add(node.line, node.col, "warning: " ++ fmt, args);
}

fn warnAt(diags: *yaml.Diags, line: u32, col: u32, comptime fmt: []const u8, args: anytype) !void {
    try diags.add(line, col, "warning: " ++ fmt, args);
}

fn hasHardError(diags: *const yaml.Diags) bool {
    for (diags.list.items) |d| {
        if (!std.mem.startsWith(u8, d.msg, "warning: ")) return true;
    }
    return false;
}

fn envPairs(alloc: std.mem.Allocator, node: ?yaml.Node, diags: *yaml.Diags) ![]ir.EnvPair {
    var out: std.ArrayList(ir.EnvPair) = .empty;
    const n = node orelse return out.toOwnedSlice(alloc);
    switch (n.data) {
        .map => |m| {
            var it = m.iterator();
            while (it.next()) |entry| switch (entry.value_ptr.data) {
                .scalar => |value| try out.append(alloc, .{ .name = entry.key_ptr.*, .value = value }),
                else => try warn(diags, entry.value_ptr.*, "variable '{s}' attributes are not supported (ignored)", .{entry.key_ptr.*}),
            };
        },
        else => try diags.add(n.line, n.col, "'environment' must be a mapping", .{}),
    }
    return out.toOwnedSlice(alloc);
}

fn stringListSimple(alloc: std.mem.Allocator, node: yaml.Node, diags: *yaml.Diags) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    switch (node.data) {
        .scalar => |value| if (value.len > 0) try out.append(alloc, value),
        .seq => |items| for (items) |item| switch (item.data) {
            .scalar => |value| try out.append(alloc, value),
            else => try diags.add(item.line, item.col, "'requires' entries must be strings", .{}),
        },
        .map => try diags.add(node.line, node.col, "'requires' must be a string or list of strings", .{}),
    }
    return out.toOwnedSlice(alloc);
}

fn implicitServiceName(image: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, image, '/') orelse 0;
    const start = if (slash == 0) 0 else slash + 1;
    const tail = image[start..];
    const end = std.mem.indexOfAny(u8, tail, ":@") orelse tail.len;
    return tail[0..end];
}

fn nextStepId(alloc: std.mem.Allocator, counts: *std.StringArrayHashMapUnmanaged(u32), keyword: []const u8) ![]const u8 {
    const gop = try counts.getOrPut(alloc, keyword);
    if (!gop.found_existing) {
        gop.value_ptr.* = 1;
        return keyword;
    }
    const n = gop.value_ptr.*;
    gop.value_ptr.* += 1;
    return std.fmt.allocPrint(alloc, "{s}-{d}", .{ keyword, n });
}

const DockerParse = struct {
    image: []const u8 = "",
    services: []ir.Service = &.{},
};

fn lowerDockerList(alloc: std.mem.Allocator, node: yaml.Node, diags: *yaml.Diags) !DockerParse {
    const items = switch (node.data) {
        .seq => |s| s,
        else => {
            try diags.add(node.line, node.col, "'docker' must be a list", .{});
            return .{};
        },
    };
    var image: []const u8 = "";
    var services: std.ArrayList(ir.Service) = .empty;
    for (items, 0..) |entry, i| {
        if (entry.data != .map) {
            try diags.add(entry.line, entry.col, "docker entries must be mappings", .{});
            continue;
        }
        const image_node = entry.get("image") orelse {
            try diags.add(entry.line, entry.col, "docker entry requires 'image'", .{});
            continue;
        };
        const img = image_node.scalarOr("");
        var it = entry.data.map.iterator();
        while (it.next()) |kv| {
            if (!contains(&docker_entry_keys, kv.key_ptr.*))
                try warn(diags, kv.value_ptr.*, "docker key '{s}' is not simulated (ignored)", .{kv.key_ptr.*});
        }
        if (i == 0) {
            image = img;
        } else {
            var name: []const u8 = if (entry.get("name")) |n| n.scalarOr("") else "";
            if (name.len == 0) name = implicitServiceName(img);
            if (name.len == 0) name = try std.fmt.allocPrint(alloc, "svc-{d}", .{i + 1});
            try services.append(alloc, .{ .name = name, .image = img, .env = try envPairs(alloc, entry.get("environment"), diags) });
        }
    }
    return .{ .image = image, .services = try services.toOwnedSlice(alloc) };
}

const ExecutorMap = std.StringArrayHashMapUnmanaged([]const u8);

fn lowerExecutors(alloc: std.mem.Allocator, node: yaml.Node, diags: *yaml.Diags) !ExecutorMap {
    var out: ExecutorMap = .empty;
    if (node.data != .map) {
        try diags.add(node.line, node.col, "'executors' must be a mapping", .{});
        return out;
    }
    var it = node.data.map.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const def = entry.value_ptr.*;
        if (def.get("docker")) |docker_node| {
            const parsed = try lowerDockerList(alloc, docker_node, diags);
            try out.put(alloc, name, parsed.image);
        } else if (def.get("machine")) |mnode| {
            try warn(diags, mnode, "executor '{s}' type is not simulated (running natively)", .{name});
            try out.put(alloc, name, "");
        } else if (def.get("macos")) |mnode| {
            try warn(diags, mnode, "executor '{s}' type is not simulated (running natively)", .{name});
            try out.put(alloc, name, "");
        } else {
            try out.put(alloc, name, "");
        }
    }
    return out;
}

fn mapShell(raw: []const u8) ?[]const u8 {
    if (std.mem.indexOf(u8, raw, "pwsh") != null or std.mem.indexOf(u8, raw, "powershell") != null) return "pwsh";
    if (std.mem.indexOf(u8, raw, "bash") != null) return "bash";
    if (std.mem.indexOf(u8, raw, "sh") != null) return "sh";
    return null;
}

const StepCtx = struct {
    alloc: std.mem.Allocator,
    counts: *std.StringArrayHashMapUnmanaged(u32),
    diags: *yaml.Diags,
    default_workdir: ?[]const u8,
    templating_warned: *bool,
};

fn lowerRunStep(ctx: *StepCtx, node: yaml.Node, val: yaml.Node) !ir.Step {
    var name: []const u8 = "run";
    var command: []const u8 = "";
    var have_command = false;
    var shell: ?[]const u8 = null;
    var env: []ir.EnvPair = &.{};
    var workdir: ?[]const u8 = ctx.default_workdir;
    var cond: ?[]const u8 = null;
    var continue_on_error = false;

    switch (val.data) {
        .scalar => |s| {
            command = s;
            have_command = true;
        },
        .map => |m| {
            var it = m.iterator();
            while (it.next()) |entry| {
                const key = entry.key_ptr.*;
                const v = entry.value_ptr.*;
                if (std.mem.eql(u8, key, "command")) {
                    command = v.scalarOr("");
                    have_command = true;
                } else if (std.mem.eql(u8, key, "name")) {
                    name = v.scalarOr("run");
                } else if (std.mem.eql(u8, key, "shell")) {
                    const raw = v.scalarOr("");
                    if (mapShell(raw)) |sh| {
                        shell = sh;
                    } else {
                        try warn(ctx.diags, v, "shell '{s}' is not recognized (ignored)", .{raw});
                    }
                } else if (std.mem.eql(u8, key, "environment")) {
                    env = try envPairs(ctx.alloc, v, ctx.diags);
                } else if (std.mem.eql(u8, key, "working_directory")) {
                    workdir = v.scalarOr("");
                } else if (std.mem.eql(u8, key, "when")) {
                    const w = v.scalarOr("on_success");
                    if (std.mem.eql(u8, w, "always")) {
                        cond = "always()";
                        continue_on_error = true;
                    } else if (std.mem.eql(u8, w, "on_fail")) {
                        cond = "always()";
                        continue_on_error = true;
                        try warn(ctx.diags, v, "when: on_fail runs after any failure locally", .{});
                    }
                } else {
                    try warn(ctx.diags, v, "run key '{s}' is not simulated (ignored)", .{key});
                }
            }
        },
        .seq => try ctx.diags.add(val.line, val.col, "'run' must be a string or mapping", .{}),
    }

    if (!have_command) try ctx.diags.add(node.line, node.col, "run step requires 'command'", .{});
    if (!ctx.templating_warned.* and std.mem.indexOf(u8, command, "<<") != null) {
        try warn(ctx.diags, node, "templating '<< >>' is not evaluated (left literal)", .{});
        ctx.templating_warned.* = true;
    }

    const id = try nextStepId(ctx.alloc, ctx.counts, "run");
    return .{
        .id = id,
        .name = name,
        .kind = .run,
        .script = command,
        .shell = shell,
        .env = env,
        .workdir = workdir,
        .cond = cond,
        .continue_on_error = continue_on_error,
        .src_line = node.line,
    };
}

fn lowerSteps(ctx: *StepCtx, items: []yaml.Node, out: *std.ArrayList(ir.Step)) ParseError!void {
    for (items) |item| {
        switch (item.data) {
            .scalar => |s| {
                if (std.mem.eql(u8, s, "checkout")) {
                    try warn(ctx.diags, item, "checkout is not needed locally (skipped)", .{});
                } else {
                    try warn(ctx.diags, item, "step '{s}' is not supported (skipped)", .{s});
                }
            },
            .map => |m| {
                var it = m.iterator();
                const first = it.next() orelse continue;
                const key = first.key_ptr.*;
                const val = first.value_ptr.*;
                if (std.mem.eql(u8, key, "run")) {
                    try out.append(ctx.alloc, try lowerRunStep(ctx, item, val));
                } else if (std.mem.eql(u8, key, "checkout")) {
                    try warn(ctx.diags, item, "checkout is not needed locally (skipped)", .{});
                } else if (std.mem.eql(u8, key, "when") or std.mem.eql(u8, key, "unless")) {
                    try warn(ctx.diags, item, "conditional steps are not evaluated locally (steps run)", .{});
                    if (val.get("steps")) |nested| switch (nested.data) {
                        .seq => |nitems| try lowerSteps(ctx, nitems, out),
                        else => try ctx.diags.add(nested.line, nested.col, "'steps' must be a list", .{}),
                    };
                } else if (contains(&step_skip_keys, key)) {
                    try warn(ctx.diags, val, "'{s}' is not simulated (skipped)", .{key});
                } else {
                    try warn(ctx.diags, val, "step '{s}' is not supported (skipped)", .{key});
                }
            },
            .seq => try ctx.diags.add(item.line, item.col, "step entries must be strings or mappings", .{}),
        }
    }
}

fn checkJobKeys(node: yaml.Node, diags: *yaml.Diags) !void {
    if (node.data != .map) return;
    var it = node.data.map.iterator();
    while (it.next()) |entry| {
        if (contains(&job_supported_keys, entry.key_ptr.*)) continue;
        try warn(diags, entry.value_ptr.*, "job key '{s}' is not simulated (ignored)", .{entry.key_ptr.*});
    }
}

fn lowerJob(alloc: std.mem.Allocator, id: []const u8, node: yaml.Node, executors: ExecutorMap, diags: *yaml.Diags) ParseError!ir.Job {
    var container_image: []const u8 = "";
    var services: []ir.Service = &.{};
    var workdir: ?[]const u8 = null;

    if (node.get("docker")) |docker_node| {
        const parsed = try lowerDockerList(alloc, docker_node, diags);
        container_image = parsed.image;
        services = parsed.services;
    } else if (node.get("executor")) |executor_node| {
        const name: []const u8 = switch (executor_node.data) {
            .scalar => |s| s,
            .map => |m| blk: {
                const n = m.get("name") orelse {
                    try diags.add(executor_node.line, executor_node.col, "'executor' mapping requires 'name'", .{});
                    break :blk "";
                };
                break :blk n.scalarOr("");
            },
            .seq => blk: {
                try diags.add(executor_node.line, executor_node.col, "'executor' must be a string or mapping", .{});
                break :blk "";
            },
        };
        if (name.len > 0) {
            if (executors.get(name)) |image| {
                container_image = image;
            } else {
                try diags.add(executor_node.line, executor_node.col, "unknown executor '{s}'", .{name});
            }
        }
    } else if (node.get("machine")) |mnode| {
        try warn(diags, mnode, "job '{s}' does not use docker and runs natively (not simulated)", .{id});
    } else if (node.get("macos")) |mnode| {
        try warn(diags, mnode, "job '{s}' does not use docker and runs natively (not simulated)", .{id});
    }

    const job_env_user = try envPairs(alloc, node.get("environment"), diags);
    if (node.get("working_directory")) |wd_node| workdir = wd_node.scalarOr("");
    if (node.get("parallelism")) |p_node| try warn(diags, p_node, "parallelism is not simulated (running once)", .{});
    if (node.get("resource_class")) |rc_node| try warn(diags, rc_node, "job key 'resource_class' is not simulated (ignored)", .{});

    try checkJobKeys(node, diags);

    var env: std.ArrayList(ir.EnvPair) = .empty;
    try env.appendSlice(alloc, job_env_user);
    try env.appendSlice(alloc, &.{
        .{ .name = "CIRCLECI", .value = "true" },
        .{ .name = "CIRCLE_JOB", .value = id },
    });

    var steps_list: std.ArrayList(ir.Step) = .empty;
    var counts: std.StringArrayHashMapUnmanaged(u32) = .empty;
    var templating_warned = false;

    const steps_node = node.get("steps") orelse {
        try diags.add(node.line, node.col, "job '{s}' has no steps", .{id});
        return .{
            .id = id,
            .display_name = id,
            .env = try env.toOwnedSlice(alloc),
            .steps = &.{},
            .src_line = node.line,
            .container_image = container_image,
            .services = services,
            .provider = .circleci,
        };
    };
    const items: []yaml.Node = switch (steps_node.data) {
        .seq => |s| s,
        else => blk: {
            try diags.add(steps_node.line, steps_node.col, "job '{s}' steps must be a list", .{id});
            break :blk &[_]yaml.Node{};
        },
    };
    if (items.len == 0) try diags.add(steps_node.line, steps_node.col, "job '{s}' has no steps", .{id});

    var ctx = StepCtx{ .alloc = alloc, .counts = &counts, .diags = diags, .default_workdir = workdir, .templating_warned = &templating_warned };
    try lowerSteps(&ctx, items, &steps_list);

    return .{
        .id = id,
        .display_name = id,
        .env = try env.toOwnedSlice(alloc),
        .steps = try steps_list.toOwnedSlice(alloc),
        .src_line = node.line,
        .container_image = container_image,
        .services = services,
        .provider = .circleci,
    };
}

const WorkflowJobEntry = struct {
    id: []const u8,
    needs: [][]const u8,
};

fn lowerWorkflowJobsSeq(
    alloc: std.mem.Allocator,
    items: []yaml.Node,
    defined_ids: std.StringArrayHashMapUnmanaged(void),
    diags: *yaml.Diags,
) ParseError![]WorkflowJobEntry {
    var out: std.ArrayList(WorkflowJobEntry) = .empty;
    for (items) |item| {
        switch (item.data) {
            .scalar => |name| {
                if (!defined_ids.contains(name)) {
                    try diags.add(item.line, item.col, "workflow references unknown job '{s}'", .{name});
                    continue;
                }
                try out.append(alloc, .{ .id = name, .needs = &.{} });
            },
            .map => |m| {
                var it = m.iterator();
                const first = it.next() orelse continue;
                const name = first.key_ptr.*;
                const cfg = first.value_ptr.*;
                if (!defined_ids.contains(name)) {
                    try diags.add(item.line, item.col, "workflow references unknown job '{s}'", .{name});
                    continue;
                }
                var needs: [][]const u8 = &.{};
                switch (cfg.data) {
                    .map => |cm| {
                        var cit = cm.iterator();
                        while (cit.next()) |kv| {
                            const key = kv.key_ptr.*;
                            if (std.mem.eql(u8, key, "requires")) {
                                needs = try stringListSimple(alloc, kv.value_ptr.*, diags);
                            } else if (std.mem.eql(u8, key, "matrix")) {
                                try warn(diags, kv.value_ptr.*, "'{s}' is not evaluated locally (running once)", .{key});
                            } else {
                                try warn(diags, kv.value_ptr.*, "'{s}' is not evaluated locally", .{key});
                            }
                        }
                    },
                    .scalar => {},
                    .seq => try diags.add(cfg.line, cfg.col, "workflow job '{s}' configuration must be a mapping", .{name}),
                }
                try out.append(alloc, .{ .id = name, .needs = needs });
            },
            .seq => try diags.add(item.line, item.col, "workflow 'jobs' entries must be strings or mappings", .{}),
        }
    }
    return out.toOwnedSlice(alloc);
}

fn chooseWorkflow(
    alloc: std.mem.Allocator,
    root: yaml.Node,
    defined_ids: std.StringArrayHashMapUnmanaged(void),
    diags: *yaml.Diags,
) ParseError!?[]WorkflowJobEntry {
    const workflows_node = root.get("workflows") orelse return null;
    if (workflows_node.data != .map) {
        try diags.add(workflows_node.line, workflows_node.col, "'workflows' must be a mapping", .{});
        return null;
    }
    var chosen: ?[]WorkflowJobEntry = null;
    var it = workflows_node.data.map.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        if (std.mem.eql(u8, name, "version")) continue;
        const wf_node = entry.value_ptr.*;
        if (chosen == null) {
            const jobs_node = wf_node.get("jobs") orelse {
                try diags.add(wf_node.line, wf_node.col, "workflow '{s}' has no jobs", .{name});
                chosen = &[_]WorkflowJobEntry{};
                continue;
            };
            const items: []yaml.Node = switch (jobs_node.data) {
                .seq => |s| s,
                else => blk: {
                    try diags.add(jobs_node.line, jobs_node.col, "workflow 'jobs' must be a list", .{});
                    break :blk &[_]yaml.Node{};
                },
            };
            chosen = try lowerWorkflowJobsSeq(alloc, items, defined_ids, diags);
        } else {
            try warn(diags, wf_node, "workflow '{s}' ignored (only the first is simulated)", .{name});
        }
    }
    return chosen;
}

fn validate(alloc: std.mem.Allocator, jobs: []const ir.Job, diags: *yaml.Diags) !void {
    var ids: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (jobs) |job| try ids.put(alloc, job.id, {});
    for (jobs) |job| for (job.needs) |need| {
        if (!ids.contains(need)) try diags.add(job.src_line, 1, "job '{s}' needs unknown job '{s}'", .{ job.id, need });
    };

    const Color = enum { white, grey, black };
    var colors: std.StringArrayHashMapUnmanaged(Color) = .empty;
    for (ids.keys()) |id| try colors.put(alloc, id, .white);
    const Ctx = struct {
        jobs: []const ir.Job,
        colors: *std.StringArrayHashMapUnmanaged(Color),
        diags: *yaml.Diags,
        alloc: std.mem.Allocator,
        fn find(self: @This(), id: []const u8) ?ir.Job {
            for (self.jobs) |job| if (std.mem.eql(u8, job.id, id)) return job;
            return null;
        }
        fn visit(self: @This(), id: []const u8) !void {
            const color = self.colors.get(id) orelse return;
            if (color == .grey) {
                const job = self.find(id) orelse return;
                try self.diags.add(job.src_line, 1, "dependency cycle involving job '{s}'", .{id});
                return;
            }
            if (color == .black) return;
            try self.colors.put(self.alloc, id, .grey);
            if (self.find(id)) |job| for (job.needs) |need| try self.visit(need);
            try self.colors.put(self.alloc, id, .black);
        }
    };
    const ctx = Ctx{ .jobs = jobs, .colors = &colors, .diags = diags, .alloc = alloc };
    for (ids.keys()) |id| try ctx.visit(id);
}

pub fn parsePipeline(alloc: std.mem.Allocator, source_path: []const u8, source: []const u8, diags: *yaml.Diags) ParseError!ir.Pipeline {
    const root = yaml.parse(alloc, source, diags) catch |err| return switch (err) {
        error.ParseFailed => error.ParseFailed,
        error.OutOfMemory => error.OutOfMemory,
    };
    if (root.data != .map) {
        try diags.add(root.line, root.col, "CircleCI config must be a mapping", .{});
        return error.ParseFailed;
    }
    const root_map = root.data.map;

    var executors: ExecutorMap = .empty;
    if (root.get("executors")) |ex_node| executors = try lowerExecutors(alloc, ex_node, diags);

    var job_ids_order: std.ArrayList([]const u8) = .empty;
    var job_map: std.StringArrayHashMapUnmanaged(ir.Job) = .empty;
    const jobs_node = root.get("jobs");
    const workflows_present = root.get("workflows") != null;
    if (jobs_node == null and !workflows_present) {
        try diags.add(root.line, root.col, "config has no jobs", .{});
    }
    if (jobs_node) |jn| switch (jn.data) {
        .map => |jm| {
            var jit = jm.iterator();
            while (jit.next()) |entry| {
                const id = entry.key_ptr.*;
                switch (entry.value_ptr.data) {
                    .map => {
                        const job = try lowerJob(alloc, id, entry.value_ptr.*, executors, diags);
                        try job_map.put(alloc, id, job);
                        try job_ids_order.append(alloc, id);
                    },
                    else => try diags.add(entry.value_ptr.line, entry.value_ptr.col, "job '{s}' must be a mapping", .{id}),
                }
            }
        },
        else => try diags.add(jn.line, jn.col, "'jobs' must be a mapping", .{}),
    };

    var defined_ids: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (job_ids_order.items) |id| try defined_ids.put(alloc, id, {});

    var rit = root_map.iterator();
    while (rit.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "version")) continue;
        if (std.mem.eql(u8, key, "orbs")) {
            try warn(diags, entry.value_ptr.*, "orbs are not supported (jobs using orb steps will warn)", .{});
        } else if (std.mem.eql(u8, key, "parameters")) {
            try warn(diags, entry.value_ptr.*, "'parameters' is not simulated (ignored)", .{});
        } else if (std.mem.eql(u8, key, "commands")) {
            try warn(diags, entry.value_ptr.*, "reusable commands are not supported (invocations will warn)", .{});
        } else if (contains(&recognized_root_keys, key)) {
            continue;
        } else {
            try warn(diags, entry.value_ptr.*, "'{s}' is not simulated (ignored)", .{key});
        }
    }

    const chosen = try chooseWorkflow(alloc, root, defined_ids, diags);

    var final_jobs: std.ArrayList(ir.Job) = .empty;
    if (chosen) |entries| {
        var included: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (entries) |e| try included.put(alloc, e.id, {});
        for (entries) |e| {
            var job = job_map.get(e.id) orelse continue;
            job.needs = e.needs;
            try final_jobs.append(alloc, job);
        }
        for (job_ids_order.items) |id| {
            if (!included.contains(id)) {
                const job = job_map.get(id).?;
                try warnAt(diags, job.src_line, 1, "job '{s}' not in the simulated workflow (skipped)", .{id});
            }
        }
    } else {
        for (job_ids_order.items) |id| try final_jobs.append(alloc, job_map.get(id).?);
    }

    try validate(alloc, final_jobs.items, diags);
    if (hasHardError(diags)) return error.ParseFailed;

    return .{ .name = "circleci", .source_path = source_path, .jobs = try final_jobs.toOwnedSlice(alloc) };
}

test "two jobs with workflow requires produce needs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\jobs:
        \\  build:
        \\    docker:
        \\      - image: node:18
        \\    steps:
        \\      - run: echo build
        \\  test:
        \\    docker:
        \\      - image: node:18
        \\    steps:
        \\      - run: echo test
        \\workflows:
        \\  main:
        \\    jobs:
        \\      - build
        \\      - test:
        \\          requires: [build]
    ;
    const pipeline = try parsePipeline(a, ".circleci/config.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 2), pipeline.jobs.len);
    try std.testing.expectEqualStrings("build", pipeline.jobs[1].needs[0]);
}

test "workflow scalar entries include jobs with no needs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\jobs:
        \\  build:
        \\    docker:
        \\      - image: node:18
        \\    steps:
        \\      - run: echo build
        \\workflows:
        \\  main:
        \\    jobs:
        \\      - build
    ;
    const pipeline = try parsePipeline(a, ".circleci/config.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 1), pipeline.jobs.len);
    try std.testing.expectEqual(@as(usize, 0), pipeline.jobs[0].needs.len);
}

test "job not referenced by the chosen workflow is dropped and warns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\jobs:
        \\  build:
        \\    docker:
        \\      - image: node:18
        \\    steps:
        \\      - run: echo build
        \\  unused:
        \\    docker:
        \\      - image: node:18
        \\    steps:
        \\      - run: echo unused
        \\workflows:
        \\  main:
        \\    jobs:
        \\      - build
    ;
    const pipeline = try parsePipeline(a, ".circleci/config.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 1), pipeline.jobs.len);
    var found = false;
    for (diags.list.items) |d| if (std.mem.indexOf(u8, d.msg, "not in the simulated workflow") != null) {
        found = true;
    };
    try std.testing.expect(found);
}

test "no workflows section includes all jobs with no needs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\jobs:
        \\  build:
        \\    docker:
        \\      - image: node:18
        \\    steps:
        \\      - run: echo build
        \\  test:
        \\    docker:
        \\      - image: node:18
        \\    steps:
        \\      - run: echo test
    ;
    const pipeline = try parsePipeline(a, ".circleci/config.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 2), pipeline.jobs.len);
    for (pipeline.jobs) |job| try std.testing.expectEqual(@as(usize, 0), job.needs.len);
}

test "docker image and secondary service with environment" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\jobs:
        \\  build:
        \\    docker:
        \\      - image: node:18
        \\      - image: redis:7
        \\        environment:
        \\          MODE: test
        \\    steps:
        \\      - run: echo build
    ;
    const pipeline = try parsePipeline(a, ".circleci/config.yml", source, &diags);
    try std.testing.expectEqualStrings("node:18", pipeline.jobs[0].container_image);
    try std.testing.expectEqualStrings("redis", pipeline.jobs[0].services[0].name);
    try std.testing.expectEqualStrings("redis:7", pipeline.jobs[0].services[0].image);
    try std.testing.expectEqualStrings("MODE", pipeline.jobs[0].services[0].env[0].name);
}

test "executor lookup resolves job container image" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\executors:
        \\  node-exec:
        \\    docker:
        \\      - image: node:20
        \\jobs:
        \\  build:
        \\    executor: node-exec
        \\    steps:
        \\      - run: echo build
    ;
    const pipeline = try parsePipeline(a, ".circleci/config.yml", source, &diags);
    try std.testing.expectEqualStrings("node:20", pipeline.jobs[0].container_image);
}

test "unknown executor is a hard diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\jobs:
        \\  build:
        \\    executor: ghost
        \\    steps:
        \\      - run: echo build
    ;
    try std.testing.expectError(error.ParseFailed, parsePipeline(a, ".circleci/config.yml", source, &diags));
    var found = false;
    for (diags.list.items) |d| if (std.mem.indexOf(u8, d.msg, "unknown executor 'ghost'") != null) {
        found = true;
    };
    try std.testing.expect(found);
}

test "run scalar and run map with name, environment, and working_directory" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\jobs:
        \\  build:
        \\    docker:
        \\      - image: node:18
        \\    steps:
        \\      - run: echo scalar
        \\      - run:
        \\          name: my step
        \\          command: echo mapped
        \\          environment:
        \\            FOO: bar
        \\          working_directory: /app
    ;
    const pipeline = try parsePipeline(a, ".circleci/config.yml", source, &diags);
    const steps = pipeline.jobs[0].steps;
    try std.testing.expectEqualStrings("echo scalar", steps[0].script);
    try std.testing.expectEqualStrings("my step", steps[1].name);
    try std.testing.expectEqualStrings("echo mapped", steps[1].script);
    try std.testing.expectEqualStrings("FOO", steps[1].env[0].name);
    try std.testing.expectEqualStrings("/app", steps[1].workdir.?);
}

test "shell key maps bash values to our bash shell" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\jobs:
        \\  build:
        \\    docker:
        \\      - image: node:18
        \\    steps:
        \\      - run:
        \\          command: echo hi
        \\          shell: /bin/bash -eo pipefail
    ;
    const pipeline = try parsePipeline(a, ".circleci/config.yml", source, &diags);
    try std.testing.expectEqualStrings("bash", pipeline.jobs[0].steps[0].shell.?);
}

test "run when always sets cond and continue_on_error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\jobs:
        \\  build:
        \\    docker:
        \\      - image: node:18
        \\    steps:
        \\      - run:
        \\          command: echo cleanup
        \\          when: always
    ;
    const pipeline = try parsePipeline(a, ".circleci/config.yml", source, &diags);
    const step = pipeline.jobs[0].steps[0];
    try std.testing.expectEqualStrings("always()", step.cond.?);
    try std.testing.expect(step.continue_on_error);
}

test "store_artifacts step warns and is skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\jobs:
        \\  build:
        \\    docker:
        \\      - image: node:18
        \\    steps:
        \\      - run: echo build
        \\      - store_artifacts:
        \\          path: out
    ;
    const pipeline = try parsePipeline(a, ".circleci/config.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 1), pipeline.jobs[0].steps.len);
    var found = false;
    for (diags.list.items) |d| if (std.mem.indexOf(u8, d.msg, "'store_artifacts' is not simulated (skipped)") != null) {
        found = true;
    };
    try std.testing.expect(found);
}

test "when-wrapper lowers nested steps and warns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\jobs:
        \\  build:
        \\    docker:
        \\      - image: node:18
        \\    steps:
        \\      - when:
        \\          condition: true
        \\          steps:
        \\            - run: echo nested
    ;
    const pipeline = try parsePipeline(a, ".circleci/config.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 1), pipeline.jobs[0].steps.len);
    try std.testing.expectEqualStrings("echo nested", pipeline.jobs[0].steps[0].script);
    var found = false;
    for (diags.list.items) |d| if (std.mem.indexOf(u8, d.msg, "conditional steps are not evaluated locally") != null) {
        found = true;
    };
    try std.testing.expect(found);
}

test "templating markers warn once per job" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\jobs:
        \\  build:
        \\    docker:
        \\      - image: node:18
        \\    steps:
        \\      - run: echo << parameters.foo >>
        \\      - run: echo << parameters.bar >>
    ;
    _ = try parsePipeline(a, ".circleci/config.yml", source, &diags);
    var count: usize = 0;
    for (diags.list.items) |d| if (std.mem.indexOf(u8, d.msg, "templating '<< >>' is not evaluated") != null) {
        count += 1;
    };
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "empty steps list is a hard diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\jobs:
        \\  build:
        \\    docker:
        \\      - image: node:18
        \\    steps: []
    ;
    try std.testing.expectError(error.ParseFailed, parsePipeline(a, ".circleci/config.yml", source, &diags));
    var found = false;
    for (diags.list.items) |d| if (std.mem.indexOf(u8, d.msg, "has no steps") != null) {
        found = true;
    };
    try std.testing.expect(found);
}

test "requires referencing a job outside the workflow is a hard diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\jobs:
        \\  build:
        \\    docker:
        \\      - image: node:18
        \\    steps:
        \\      - run: echo build
        \\  test:
        \\    docker:
        \\      - image: node:18
        \\    steps:
        \\      - run: echo test
        \\workflows:
        \\  main:
        \\    jobs:
        \\      - build:
        \\          requires: [test]
    ;
    try std.testing.expectError(error.ParseFailed, parsePipeline(a, ".circleci/config.yml", source, &diags));
    var found = false;
    for (diags.list.items) |d| if (std.mem.indexOf(u8, d.msg, "needs unknown job 'test'") != null) {
        found = true;
    };
    try std.testing.expect(found);
}

test "dependency cycle between two jobs is a hard diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\jobs:
        \\  a:
        \\    docker:
        \\      - image: node:18
        \\    steps:
        \\      - run: echo a
        \\  b:
        \\    docker:
        \\      - image: node:18
        \\    steps:
        \\      - run: echo b
        \\workflows:
        \\  main:
        \\    jobs:
        \\      - a:
        \\          requires: [b]
        \\      - b:
        \\          requires: [a]
    ;
    try std.testing.expectError(error.ParseFailed, parsePipeline(a, ".circleci/config.yml", source, &diags));
    var found = false;
    for (diags.list.items) |d| if (std.mem.indexOf(u8, d.msg, "cycle") != null) {
        found = true;
    };
    try std.testing.expect(found);
}
