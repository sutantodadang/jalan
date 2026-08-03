const std = @import("std");
const yaml = @import("../yaml.zig");
const ir = @import("../ir.zig");

pub const ParseError = error{ ParseFailed, OutOfMemory };

fn contains(list: []const []const u8, value: []const u8) bool {
    for (list) |item| if (std.mem.eql(u8, item, value)) return true;
    return false;
}

fn warn(diags: *yaml.Diags, node: yaml.Node, comptime fmt: []const u8, args: anytype) !void {
    try diags.add(node.line, node.col, "warning: " ++ fmt, args);
}

fn hasHardError(diags: *const yaml.Diags) bool {
    for (diags.list.items) |d| {
        if (!std.mem.startsWith(u8, d.msg, "warning: ")) return true;
    }
    return false;
}

fn stringList(alloc: std.mem.Allocator, node: yaml.Node, field: []const u8, diags: *yaml.Diags) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    switch (node.data) {
        .scalar => |value| if (value.len > 0) try out.append(alloc, value),
        .seq => |items| for (items) |item| switch (item.data) {
            .scalar => |value| try out.append(alloc, value),
            else => try diags.add(item.line, item.col, "'{s}' entries must be strings", .{field}),
        },
        .map => try diags.add(node.line, node.col, "'{s}' must be a string or list of strings", .{field}),
    }
    return out.toOwnedSlice(alloc);
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
        else => try diags.add(n.line, n.col, "'variables' must be a mapping", .{}),
    }
    return out.toOwnedSlice(alloc);
}

fn imageName(node: ?yaml.Node, diags: *yaml.Diags) ![]const u8 {
    const n = node orelse return "";
    return switch (n.data) {
        .scalar => |value| value,
        .map => |m| blk: {
            var it = m.iterator();
            while (it.next()) |entry| {
                if (!std.mem.eql(u8, entry.key_ptr.*, "name"))
                    try warn(diags, entry.value_ptr.*, "image key '{s}' is not simulated (ignored)", .{entry.key_ptr.*});
            }
            const name = n.get("name") orelse {
                try diags.add(n.line, n.col, "image mapping requires 'name'", .{});
                break :blk "";
            };
            break :blk name.scalarOr("");
        },
        .seq => blk: {
            try diags.add(n.line, n.col, "'image' must be a string or mapping", .{});
            break :blk "";
        },
    };
}

fn sanitizeId(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (name) |c| {
        if (c == ' ') {
            try out.append(alloc, '-');
        } else {
            const lc = std.ascii.toLower(c);
            if (std.ascii.isAlphanumeric(lc) or lc == '_' or lc == '-') try out.append(alloc, lc);
        }
    }
    return out.toOwnedSlice(alloc);
}

fn allocJobId(alloc: std.mem.Allocator, used: *std.StringArrayHashMapUnmanaged(void), counter: *u32, raw_name: []const u8) ![]const u8 {
    var base = try sanitizeId(alloc, raw_name);
    if (base.len == 0) {
        counter.* += 1;
        base = try std.fmt.allocPrint(alloc, "step-{d}", .{counter.*});
    }
    if (!used.contains(base)) {
        try used.put(alloc, base, {});
        return base;
    }
    var n: u32 = 2;
    while (true) : (n += 1) {
        const candidate = try std.fmt.allocPrint(alloc, "{s}-{d}", .{ base, n });
        if (!used.contains(candidate)) {
            try used.put(alloc, candidate, {});
            return candidate;
        }
    }
}

const ServiceDef = struct { image: []const u8, env: []ir.EnvPair };
const ServiceDefs = std.StringArrayHashMapUnmanaged(ServiceDef);

fn parseDefinitions(alloc: std.mem.Allocator, node: yaml.Node, diags: *yaml.Diags) !ServiceDefs {
    var out: ServiceDefs = .empty;
    const m = switch (node.data) {
        .map => |v| v,
        else => {
            try diags.add(node.line, node.col, "'definitions' must be a mapping", .{});
            return out;
        },
    };
    var it = m.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "services")) {
            const sm = switch (entry.value_ptr.data) {
                .map => |v| v,
                else => {
                    try diags.add(entry.value_ptr.line, entry.value_ptr.col, "'definitions.services' must be a mapping", .{});
                    continue;
                },
            };
            var sit = sm.iterator();
            while (sit.next()) |se| {
                const svc_name = se.key_ptr.*;
                const svc_node = se.value_ptr.*;
                const svm = switch (svc_node.data) {
                    .map => |v| v,
                    else => {
                        try diags.add(svc_node.line, svc_node.col, "service '{s}' must be a mapping", .{svc_name});
                        continue;
                    },
                };
                const image = try imageName(svm.get("image"), diags);
                const env = try envPairs(alloc, svm.get("variables"), diags);
                var svit = svm.iterator();
                while (svit.next()) |sve| {
                    if (!contains(&.{ "image", "variables" }, sve.key_ptr.*))
                        try warn(diags, sve.value_ptr.*, "service key '{s}' is not simulated (ignored)", .{sve.key_ptr.*});
                }
                try out.put(alloc, svc_name, .{ .image = image, .env = env });
            }
        } else if (std.mem.eql(u8, key, "caches")) {
            try warn(diags, entry.value_ptr.*, "custom caches are not simulated", .{});
        } else {
            try warn(diags, entry.value_ptr.*, "definitions key '{s}' is not simulated (ignored)", .{key});
        }
    }
    return out;
}

const PipelineChoice = struct { node: yaml.Node };

fn pickPipeline(pipelines_node: yaml.Node, diags: *yaml.Diags) !?PipelineChoice {
    const pm = switch (pipelines_node.data) {
        .map => |v| v,
        else => {
            try diags.add(pipelines_node.line, pipelines_node.col, "'pipelines' must be a mapping", .{});
            return null;
        },
    };
    const sections = [_][]const u8{ "branches", "tags", "pull-requests", "custom" };
    if (pm.get("default")) |def_node| {
        for (sections) |sec| {
            if (pm.get(sec)) |_| try warn(diags, pipelines_node, "pipeline '{s}' is not simulated (only one pipeline runs locally)", .{sec});
        }
        return .{ .node = def_node };
    }
    for (sections) |sec| {
        const sec_node = pm.get(sec) orelse continue;
        const sm = switch (sec_node.data) {
            .map => |v| v,
            else => {
                try diags.add(sec_node.line, sec_node.col, "'{s}' must be a mapping", .{sec});
                continue;
            },
        };
        var it = sm.iterator();
        const first = it.next() orelse continue;
        try warn(diags, pipelines_node, "no default pipeline — simulating '{s}' '{s}'", .{ sec, first.key_ptr.* });
        for (sections) |other| {
            if (std.mem.eql(u8, other, sec)) continue;
            if (pm.get(other)) |_| try warn(diags, pipelines_node, "pipeline '{s}' is not simulated (only one pipeline runs locally)", .{other});
        }
        return .{ .node = first.value_ptr.* };
    }
    return null;
}

const step_ignored_warn_keys = [_][]const u8{ "deployment", "size", "max-time", "clone", "oidc" };
const step_known_keys = [_][]const u8{
    "name", "script", "after-script", "image", "services", "caches", "artifacts",
    "trigger", "condition", "deployment", "size", "max-time", "clone", "runs-on", "oidc",
};

fn lowerStep(
    alloc: std.mem.Allocator,
    step_node: yaml.Node,
    needs: []const []const u8,
    default_image: []const u8,
    defs: *const ServiceDefs,
    predefined_env: []const ir.EnvPair,
    used_ids: *std.StringArrayHashMapUnmanaged(void),
    step_counter: *u32,
    diags: *yaml.Diags,
    stage_ctx: ?[]const u8,
) !?ir.Job {
    const sm = switch (step_node.data) {
        .map => |v| v,
        else => {
            try diags.add(step_node.line, step_node.col, "'step' must be a mapping", .{});
            return null;
        },
    };
    const name_node = sm.get("name");
    const raw_name = if (name_node) |n| n.scalarOr("") else "";
    const id = try allocJobId(alloc, used_ids, step_counter, raw_name);
    const base_display = if (raw_name.len > 0) raw_name else id;
    const display_name = if (stage_ctx) |sc| try std.fmt.allocPrint(alloc, "{s}: {s}", .{ sc, base_display }) else base_display;

    const script_node = sm.get("script") orelse {
        try diags.add(step_node.line, step_node.col, "step '{s}' has no script", .{id});
        return null;
    };
    const script_lines = try stringList(alloc, script_node, "script", diags);
    if (script_lines.len == 0) {
        try diags.add(script_node.line, script_node.col, "step '{s}' has no script", .{id});
        return null;
    }

    var steps_list: std.ArrayList(ir.Step) = .empty;
    try steps_list.append(alloc, .{
        .id = "script",
        .name = "script",
        .kind = .run,
        .script = try std.mem.join(alloc, "\n", script_lines),
        .src_line = script_node.line,
    });
    if (sm.get("after-script")) |as_node| {
        const as_lines = try stringList(alloc, as_node, "after-script", diags);
        if (as_lines.len > 0) {
            try steps_list.append(alloc, .{
                .id = "after-script",
                .name = "after-script",
                .kind = .run,
                .script = try std.mem.join(alloc, "\n", as_lines),
                .cond = "always()",
                .continue_on_error = true,
                .src_line = as_node.line,
            });
        }
    }

    var image = default_image;
    if (sm.get("image")) |img_node| image = try imageName(img_node, diags);

    var services: std.ArrayList(ir.Service) = .empty;
    if (sm.get("services")) |svc_node| switch (svc_node.data) {
        .seq => |items| for (items) |item| switch (item.data) {
            .scalar => |name| {
                if (defs.get(name)) |def| {
                    try services.append(alloc, .{ .name = name, .image = def.image, .env = def.env });
                } else if (std.mem.eql(u8, name, "docker")) {
                    try warn(diags, item, "the built-in docker service is not simulated", .{});
                } else {
                    try diags.add(item.line, item.col, "unknown service '{s}'", .{name});
                }
            },
            else => try diags.add(item.line, item.col, "'services' entries must be strings", .{}),
        },
        else => try diags.add(svc_node.line, svc_node.col, "'services' must be a list", .{}),
    };

    var manual = false;
    if (sm.get("trigger")) |t_node| {
        if (std.mem.eql(u8, t_node.scalarOr(""), "manual")) manual = true;
    }

    var runs_on: []const u8 = "";
    if (sm.get("runs-on")) |ro_node| {
        const parts = try stringList(alloc, ro_node, "runs-on", diags);
        runs_on = try std.mem.join(alloc, ", ", parts);
    }

    if (sm.get("caches")) |c| try warn(diags, c, "caches are not simulated", .{});
    if (sm.get("artifacts")) |a| try warn(diags, a, "artifact transfer is not simulated", .{});
    if (sm.get("condition")) |c| try warn(diags, c, "conditions are not evaluated locally (step runs)", .{});
    for (step_ignored_warn_keys) |k| if (sm.get(k)) |n| try warn(diags, n, "step key '{s}' is not simulated (ignored)", .{k});

    var it = sm.iterator();
    while (it.next()) |entry| {
        if (!contains(&step_known_keys, entry.key_ptr.*))
            try warn(diags, entry.value_ptr.*, "step key '{s}' is not simulated (ignored)", .{entry.key_ptr.*});
    }

    var env: std.ArrayList(ir.EnvPair) = .empty;
    try env.appendSlice(alloc, predefined_env);

    return .{
        .id = id,
        .display_name = display_name,
        .runs_on = runs_on,
        .needs = try alloc.dupe([]const u8, needs),
        .env = try env.toOwnedSlice(alloc),
        .steps = try steps_list.toOwnedSlice(alloc),
        .src_line = step_node.line,
        .container_image = image,
        .services = try services.toOwnedSlice(alloc),
        .provider = .bitbucket,
        .manual = manual,
    };
}

fn lowerPipelineItems(
    alloc: std.mem.Allocator,
    items: []yaml.Node,
    default_image: []const u8,
    defs: *const ServiceDefs,
    predefined_env: []const ir.EnvPair,
    diags: *yaml.Diags,
    jobs: *std.ArrayList(ir.Job),
    used_ids: *std.StringArrayHashMapUnmanaged(void),
    step_counter: *u32,
) !void {
    var prev_needs: [][]const u8 = &.{};
    for (items) |item| {
        const m = switch (item.data) {
            .map => |v| v,
            else => {
                try diags.add(item.line, item.col, "pipeline item must be a mapping", .{});
                continue;
            },
        };
        if (m.get("step")) |step_node| {
            const job = try lowerStep(alloc, step_node, prev_needs, default_image, defs, predefined_env, used_ids, step_counter, diags, null) orelse continue;
            const job_id = job.id;
            try jobs.append(alloc, job);
            prev_needs = try alloc.dupe([]const u8, &.{job_id});
        } else if (m.get("parallel")) |par_node| {
            var member_ids: std.ArrayList([]const u8) = .empty;
            const step_nodes: []yaml.Node = switch (par_node.data) {
                .seq => |s| s,
                .map => |pm| blk: {
                    if (pm.get("fail-fast")) |ff| try warn(diags, ff, "'fail-fast' is not simulated (ignored)", .{});
                    const steps_node = pm.get("steps") orelse {
                        try diags.add(par_node.line, par_node.col, "'parallel' requires 'steps'", .{});
                        break :blk &.{};
                    };
                    break :blk switch (steps_node.data) {
                        .seq => |s| s,
                        else => blk2: {
                            try diags.add(steps_node.line, steps_node.col, "'parallel.steps' must be a list", .{});
                            break :blk2 &.{};
                        },
                    };
                },
                .scalar => blk: {
                    try diags.add(par_node.line, par_node.col, "'parallel' must be a list or mapping", .{});
                    break :blk &.{};
                },
            };
            for (step_nodes) |step_item| {
                const sm = switch (step_item.data) {
                    .map => |v| v,
                    else => {
                        try diags.add(step_item.line, step_item.col, "'parallel' entries must be 'step' mappings", .{});
                        continue;
                    },
                };
                const step_node2 = sm.get("step") orelse {
                    try diags.add(step_item.line, step_item.col, "'parallel' entries must be 'step' mappings", .{});
                    continue;
                };
                const job = try lowerStep(alloc, step_node2, prev_needs, default_image, defs, predefined_env, used_ids, step_counter, diags, null) orelse continue;
                const job_id = job.id;
                try jobs.append(alloc, job);
                try member_ids.append(alloc, job_id);
            }
            prev_needs = try member_ids.toOwnedSlice(alloc);
        } else if (m.get("stage")) |stage_node| {
            const sm = switch (stage_node.data) {
                .map => |v| v,
                else => {
                    try diags.add(stage_node.line, stage_node.col, "'stage' must be a mapping", .{});
                    continue;
                },
            };
            if (sm.get("condition")) |c| try warn(diags, c, "'condition' is not simulated (ignored)", .{});
            if (sm.get("trigger")) |t| try warn(diags, t, "'trigger' is not simulated (ignored)", .{});
            const name_node = sm.get("name");
            const stage_name = if (name_node) |n| n.scalarOr("") else "";
            const steps_node = sm.get("steps") orelse {
                try diags.add(stage_node.line, stage_node.col, "'stage' requires 'steps'", .{});
                continue;
            };
            const step_items: []yaml.Node = switch (steps_node.data) {
                .seq => |s| s,
                else => {
                    try diags.add(steps_node.line, steps_node.col, "'stage.steps' must be a list", .{});
                    continue;
                },
            };
            var chain_needs = prev_needs;
            var last_id: ?[]const u8 = null;
            for (step_items) |si| {
                const sim = switch (si.data) {
                    .map => |v| v,
                    else => {
                        try diags.add(si.line, si.col, "'stage' steps must be 'step' mappings", .{});
                        continue;
                    },
                };
                const step_node3 = sim.get("step") orelse {
                    try diags.add(si.line, si.col, "'stage' steps must be 'step' mappings", .{});
                    continue;
                };
                const job = try lowerStep(alloc, step_node3, chain_needs, default_image, defs, predefined_env, used_ids, step_counter, diags, stage_name) orelse continue;
                const job_id = job.id;
                try jobs.append(alloc, job);
                chain_needs = try alloc.dupe([]const u8, &.{job_id});
                last_id = job_id;
            }
            if (last_id) |id| prev_needs = try alloc.dupe([]const u8, &.{id});
        } else if (m.get("variables")) |vnode| {
            try warn(diags, vnode, "custom pipeline variables are not available locally (skipped)", .{});
        } else {
            try diags.add(item.line, item.col, "pipeline item must contain 'step', 'parallel', 'stage', or 'variables'", .{});
        }
    }
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
            for (self.jobs) |j| if (std.mem.eql(u8, j.id, id)) return j;
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

const root_known_keys = [_][]const u8{ "image", "definitions", "pipelines", "options", "clone" };

pub fn parsePipeline(alloc: std.mem.Allocator, source_path: []const u8, source: []const u8, diags: *yaml.Diags) ParseError!ir.Pipeline {
    const parsed_root = yaml.parse(alloc, source, diags) catch |err| return switch (err) {
        error.ParseFailed => error.ParseFailed,
        error.OutOfMemory => error.OutOfMemory,
    };
    const root_map = switch (parsed_root.data) {
        .map => |m| m,
        else => {
            try diags.add(parsed_root.line, parsed_root.col, "Bitbucket pipeline must be a mapping", .{});
            return error.ParseFailed;
        },
    };

    var default_image: []const u8 = "";
    if (parsed_root.get("image")) |img| default_image = try imageName(img, diags);

    var services_defs: ServiceDefs = .empty;
    if (parsed_root.get("definitions")) |defs_node| services_defs = try parseDefinitions(alloc, defs_node, diags);

    if (parsed_root.get("options")) |n| try warn(diags, n, "'options' is not simulated (ignored)", .{});
    if (parsed_root.get("clone")) |n| try warn(diags, n, "'clone' is not simulated (ignored)", .{});

    var rit = root_map.iterator();
    while (rit.next()) |entry| {
        if (!contains(&root_known_keys, entry.key_ptr.*))
            try warn(diags, entry.value_ptr.*, "root key '{s}' is not simulated (ignored)", .{entry.key_ptr.*});
    }

    const pipelines_node = parsed_root.get("pipelines") orelse {
        try diags.add(parsed_root.line, parsed_root.col, "no pipelines defined", .{});
        return error.ParseFailed;
    };

    const choice = try pickPipeline(pipelines_node, diags) orelse {
        try diags.add(pipelines_node.line, pipelines_node.col, "no pipelines defined", .{});
        return error.ParseFailed;
    };

    const items: []yaml.Node = switch (choice.node.data) {
        .seq => |s| s,
        else => {
            try diags.add(choice.node.line, choice.node.col, "pipeline must be a list", .{});
            return error.ParseFailed;
        },
    };

    var jobs: std.ArrayList(ir.Job) = .empty;
    var used_ids: std.StringArrayHashMapUnmanaged(void) = .empty;
    var step_counter: u32 = 0;
    const predefined_env = &[_]ir.EnvPair{
        .{ .name = "BITBUCKET_BUILD_NUMBER", .value = "1" },
        .{ .name = "BITBUCKET_BRANCH", .value = "main" },
    };
    try lowerPipelineItems(alloc, items, default_image, &services_defs, predefined_env, diags, &jobs, &used_ids, &step_counter);

    if (jobs.items.len == 0) try diags.add(choice.node.line, choice.node.col, "pipeline has no jobs", .{});

    try validate(alloc, jobs.items, diags);
    if (hasHardError(diags)) return error.ParseFailed;

    return .{ .name = "bitbucket", .source_path = source_path, .jobs = try jobs.toOwnedSlice(alloc) };
}

test "default pipeline: two steps become two chained jobs, script lines joined with newlines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\pipelines:
        \\  default:
        \\    - step:
        \\        name: Build
        \\        script:
        \\          - echo one
        \\          - echo two
        \\    - step:
        \\        name: Test
        \\        script:
        \\          - echo test
    ;
    const pipeline = try parsePipeline(a, "bitbucket-pipelines.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 2), pipeline.jobs.len);
    try std.testing.expectEqualStrings("build", pipeline.jobs[0].id);
    try std.testing.expectEqualStrings("echo one\necho two", pipeline.jobs[0].steps[0].script);
    try std.testing.expectEqualStrings("test", pipeline.jobs[1].id);
    try std.testing.expectEqualStrings("build", pipeline.jobs[1].needs[0]);
}

test "step name sanitization drops punctuation and duplicate ids get suffixed" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\pipelines:
        \\  default:
        \\    - step:
        \\        name: Build!!
        \\        script: [echo a]
        \\    - step:
        \\        name: Build!!
        \\        script: [echo b]
    ;
    const pipeline = try parsePipeline(a, "bitbucket-pipelines.yml", source, &diags);
    try std.testing.expectEqualStrings("build", pipeline.jobs[0].id);
    try std.testing.expectEqualStrings("build-2", pipeline.jobs[1].id);
}

test "parallel bare list fans out from previous job and fans back in" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\pipelines:
        \\  default:
        \\    - step:
        \\        name: Setup
        \\        script: [echo setup]
        \\    - parallel:
        \\        - step:
        \\            name: A
        \\            script: [echo a]
        \\        - step:
        \\            name: B
        \\            script: [echo b]
        \\    - step:
        \\        name: Finish
        \\        script: [echo finish]
    ;
    const pipeline = try parsePipeline(a, "bitbucket-pipelines.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 4), pipeline.jobs.len);
    try std.testing.expectEqualStrings("setup", pipeline.jobs[1].needs[0]);
    try std.testing.expectEqualStrings("setup", pipeline.jobs[2].needs[0]);
    try std.testing.expectEqual(@as(usize, 2), pipeline.jobs[3].needs.len);
    try std.testing.expectEqualStrings("a", pipeline.jobs[3].needs[0]);
    try std.testing.expectEqualStrings("b", pipeline.jobs[3].needs[1]);
}

test "parallel mapping form with fail-fast warns but both steps still run" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\pipelines:
        \\  default:
        \\    - parallel:
        \\        steps:
        \\          - step:
        \\              name: A
        \\              script: [echo a]
        \\          - step:
        \\              name: B
        \\              script: [echo b]
        \\        fail-fast: true
    ;
    const pipeline = try parsePipeline(a, "bitbucket-pipelines.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 2), pipeline.jobs.len);
    var found = false;
    for (diags.list.items) |d| if (std.mem.indexOf(u8, d.msg, "fail-fast") != null) {
        found = true;
    };
    try std.testing.expect(found);
}

test "stage groups its steps sequentially and chains with neighboring items" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\pipelines:
        \\  default:
        \\    - step:
        \\        name: Setup
        \\        script: [echo setup]
        \\    - stage:
        \\        name: Build and Test
        \\        steps:
        \\          - step:
        \\              name: Compile
        \\              script: [echo compile]
        \\          - step:
        \\              name: Run Tests
        \\              script: [echo test]
        \\    - step:
        \\        name: Deploy
        \\        script: [echo deploy]
    ;
    const pipeline = try parsePipeline(a, "bitbucket-pipelines.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 4), pipeline.jobs.len);
    try std.testing.expectEqualStrings("compile", pipeline.jobs[1].id);
    try std.testing.expectEqualStrings("Build and Test: Compile", pipeline.jobs[1].display_name);
    try std.testing.expectEqualStrings("setup", pipeline.jobs[1].needs[0]);
    try std.testing.expectEqualStrings("run-tests", pipeline.jobs[2].id);
    try std.testing.expectEqualStrings("compile", pipeline.jobs[2].needs[0]);
    try std.testing.expectEqualStrings("run-tests", pipeline.jobs[3].needs[0]);
}

test "after-script becomes a second step with always() and continue_on_error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\pipelines:
        \\  default:
        \\    - step:
        \\        name: Test
        \\        script: [echo test]
        \\        after-script:
        \\          - echo cleanup
    ;
    const pipeline = try parsePipeline(a, "bitbucket-pipelines.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 2), pipeline.jobs[0].steps.len);
    try std.testing.expectEqualStrings("after-script", pipeline.jobs[0].steps[1].id);
    try std.testing.expectEqualStrings("always()", pipeline.jobs[0].steps[1].cond.?);
    try std.testing.expect(pipeline.jobs[0].steps[1].continue_on_error);
}

test "root image applies by default and a step image overrides it" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\image: node:18
        \\pipelines:
        \\  default:
        \\    - step:
        \\        name: Default
        \\        script: [echo default]
        \\    - step:
        \\        name: Custom
        \\        image: node:20
        \\        script: [echo custom]
    ;
    const pipeline = try parsePipeline(a, "bitbucket-pipelines.yml", source, &diags);
    try std.testing.expectEqualStrings("node:18", pipeline.jobs[0].container_image);
    try std.testing.expectEqualStrings("node:20", pipeline.jobs[1].container_image);
}

test "step services resolve against definitions with variables" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\definitions:
        \\  services:
        \\    redis:
        \\      image: redis:7
        \\      variables:
        \\        MODE: cache
        \\pipelines:
        \\  default:
        \\    - step:
        \\        name: Test
        \\        services: [redis]
        \\        script: [echo test]
    ;
    const pipeline = try parsePipeline(a, "bitbucket-pipelines.yml", source, &diags);
    try std.testing.expectEqualStrings("redis", pipeline.jobs[0].services[0].name);
    try std.testing.expectEqualStrings("redis:7", pipeline.jobs[0].services[0].image);
    try std.testing.expectEqualStrings("MODE", pipeline.jobs[0].services[0].env[0].name);
}

test "unknown service reference is a hard error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\pipelines:
        \\  default:
        \\    - step:
        \\        name: Test
        \\        services: [ghost]
        \\        script: [echo test]
    ;
    try std.testing.expectError(error.ParseFailed, parsePipeline(a, "bitbucket-pipelines.yml", source, &diags));
    var found = false;
    for (diags.list.items) |d| if (std.mem.indexOf(u8, d.msg, "unknown service 'ghost'") != null) {
        found = true;
    };
    try std.testing.expect(found);
}

test "builtin docker service is skipped with a warning, not an error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\pipelines:
        \\  default:
        \\    - step:
        \\        name: Test
        \\        services: [docker]
        \\        script: [echo test]
    ;
    const pipeline = try parsePipeline(a, "bitbucket-pipelines.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 0), pipeline.jobs[0].services.len);
    var found = false;
    for (diags.list.items) |d| if (std.mem.indexOf(u8, d.msg, "built-in docker service") != null) {
        found = true;
    };
    try std.testing.expect(found);
}

test "trigger: manual marks the job manual" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\pipelines:
        \\  default:
        \\    - step:
        \\        name: Deploy
        \\        trigger: manual
        \\        script: [echo deploy]
    ;
    const pipeline = try parsePipeline(a, "bitbucket-pipelines.yml", source, &diags);
    try std.testing.expect(pipeline.jobs[0].manual);
}

test "branches-only file (no default) picks the first branch pipeline and warns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\pipelines:
        \\  branches:
        \\    main:
        \\      - step:
        \\          name: Build
        \\          script: [echo build]
        \\  tags:
        \\    v1:
        \\      - step:
        \\          name: Release
        \\          script: [echo release]
    ;
    const pipeline = try parsePipeline(a, "bitbucket-pipelines.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 1), pipeline.jobs.len);
    try std.testing.expectEqualStrings("build", pipeline.jobs[0].id);
    var found_default = false;
    var found_other = false;
    for (diags.list.items) |d| {
        if (std.mem.indexOf(u8, d.msg, "no default pipeline") != null) found_default = true;
        if (std.mem.indexOf(u8, d.msg, "'tags'") != null) found_other = true;
    }
    try std.testing.expect(found_default and found_other);
}

test "no pipelines defined is a hard error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source = "image: node:18\n";
    try std.testing.expectError(error.ParseFailed, parsePipeline(a, "bitbucket-pipelines.yml", source, &diags));
    var found = false;
    for (diags.list.items) |d| if (std.mem.indexOf(u8, d.msg, "no pipelines defined") != null) {
        found = true;
    };
    try std.testing.expect(found);
}

test "empty script is a hard error" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\pipelines:
        \\  default:
        \\    - step:
        \\        name: Test
        \\        script: []
    ;
    try std.testing.expectError(error.ParseFailed, parsePipeline(a, "bitbucket-pipelines.yml", source, &diags));
    var found = false;
    for (diags.list.items) |d| if (std.mem.indexOf(u8, d.msg, "has no script") != null) {
        found = true;
    };
    try std.testing.expect(found);
}
