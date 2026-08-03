//! Azure Pipelines frontend: lowers `azure-pipelines.yml` into the shared IR.
//!
//! Local-first philosophy: unsupported Azure features warn and keep the
//! pipeline runnable rather than failing the parse. Only genuinely malformed
//! or unresolvable structure (missing steps, unknown dependsOn, cycles, ...)
//! is a hard diagnostic.
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

fn stringList(alloc: std.mem.Allocator, node: yaml.Node, diags: *yaml.Diags) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    switch (node.data) {
        .scalar => |v| if (v.len > 0) try out.append(alloc, v),
        .seq => |items| for (items) |item| switch (item.data) {
            .scalar => |v| try out.append(alloc, v),
            else => try diags.add(item.line, item.col, "list entries must be strings", .{}),
        },
        .map => try diags.add(node.line, node.col, "expected a string or a list of strings", .{}),
    }
    return out.toOwnedSlice(alloc);
}

fn envPairsSimple(alloc: std.mem.Allocator, node: ?yaml.Node) ![]ir.EnvPair {
    var out: std.ArrayList(ir.EnvPair) = .empty;
    if (node) |n| switch (n.data) {
        .map => |m| {
            var it = m.iterator();
            while (it.next()) |e| try out.append(alloc, .{ .name = e.key_ptr.*, .value = e.value_ptr.*.scalarOr("") });
        },
        else => {},
    };
    return out.toOwnedSlice(alloc);
}

/// `variables:` at root/stage/job level. Map form `{NAME: value}` or list
/// form (`- name: X` / `value: Y` pairs, `- group: G`, `- template:`).
fn parseVariables(alloc: std.mem.Allocator, node: ?yaml.Node, diags: *yaml.Diags) ![]ir.EnvPair {
    var out: std.ArrayList(ir.EnvPair) = .empty;
    const n = node orelse return out.toOwnedSlice(alloc);
    switch (n.data) {
        .map => |m| {
            var it = m.iterator();
            while (it.next()) |e| switch (e.value_ptr.data) {
                .scalar => |v| try out.append(alloc, .{ .name = e.key_ptr.*, .value = v }),
                else => try warn(diags, e.value_ptr.*, "variable '{s}' attributes are not supported (ignored)", .{e.key_ptr.*}),
            };
        },
        .seq => |items| for (items) |item| switch (item.data) {
            .map => {
                if (item.get("group")) |_| {
                    try warn(diags, item, "variable groups are not available locally", .{});
                    continue;
                }
                if (item.get("template")) |_| {
                    try warn(diags, item, "templates are not supported (skipped)", .{});
                    continue;
                }
                const name_node = item.get("name") orelse {
                    try diags.add(item.line, item.col, "variable entry requires 'name'", .{});
                    continue;
                };
                const value = if (item.get("value")) |v| v.scalarOr("") else "";
                try out.append(alloc, .{ .name = name_node.scalarOr(""), .value = value });
            },
            else => try diags.add(item.line, item.col, "'variables' list entries must be mappings", .{}),
        },
        .scalar => try diags.add(n.line, n.col, "'variables' must be a mapping or list", .{}),
    }
    return out.toOwnedSlice(alloc);
}

fn poolRunsOn(node: ?yaml.Node) []const u8 {
    const n = node orelse return "";
    return switch (n.data) {
        .scalar => |s| s,
        .map => if (n.get("vmImage")) |v| v.scalarOr("") else if (n.get("name")) |v| v.scalarOr("") else "",
        .seq => "",
    };
}

fn containerImage(node: ?yaml.Node) []const u8 {
    const n = node orelse return "";
    return switch (n.data) {
        .scalar => |s| s,
        .map => if (n.get("image")) |img| img.scalarOr("") else "",
        .seq => "",
    };
}

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '.';
}

/// Rewrites `$(NAME)` macros in a step script before storing it. Shell
/// scripts (bash/sh/no explicit shell) get `${NAME}`; pwsh/powershell get
/// `$env:NAME`. Names containing a dot (predefined Azure variables such as
/// `Build.SourcesDirectory`) are left literal with a warning — jalan has no
/// runtime standing in for the Azure agent context.
fn rewriteMacros(alloc: std.mem.Allocator, script: []const u8, shell: ?[]const u8, node: yaml.Node, diags: *yaml.Diags) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const is_ps = shell != null and (std.mem.eql(u8, shell.?, "pwsh") or std.mem.eql(u8, shell.?, "powershell"));
    var i: usize = 0;
    while (i < script.len) {
        if (script[i] == '$' and i + 1 < script.len and script[i + 1] == '(') {
            const start = i + 2;
            var j = start;
            if (j < script.len and isIdentStart(script[j])) {
                j += 1;
                while (j < script.len and isIdentChar(script[j])) j += 1;
                if (j < script.len and script[j] == ')') {
                    const name = script[start..j];
                    if (std.mem.indexOfScalar(u8, name, '.') != null) {
                        try warn(diags, node, "predefined variable '$({s})' is not available (left literal)", .{name});
                        try out.appendSlice(alloc, script[i .. j + 1]);
                    } else if (is_ps) {
                        try out.appendSlice(alloc, "$env:");
                        try out.appendSlice(alloc, name);
                    } else {
                        try out.appendSlice(alloc, "${");
                        try out.appendSlice(alloc, name);
                        try out.append(alloc, '}');
                    }
                    i = j + 1;
                    continue;
                }
            }
        }
        try out.append(alloc, script[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

const StepCounts = std.StringArrayHashMapUnmanaged(u32);

fn nextDefaultId(alloc: std.mem.Allocator, counts: *StepCounts, key: []const u8) ![]const u8 {
    const prev = counts.get(key) orelse 0;
    const n = prev + 1;
    try counts.put(alloc, key, n);
    if (n == 1) return key;
    return try std.fmt.allocPrint(alloc, "{s}-{d}", .{ key, n });
}

fn sanitizeId(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (raw) |c| if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-') try out.append(alloc, c);
    return out.toOwnedSlice(alloc);
}

const step_known_keys = [_][]const u8{
    "script", "bash", "pwsh", "powershell", "displayName", "name", "env",
    "workingDirectory", "condition", "continueOnError", "failOnStderr",
    "retryCountOnTaskFailure", "timeoutInMinutes",
};

fn lowerAzureStep(alloc: std.mem.Allocator, node: yaml.Node, counts: *StepCounts, diags: *yaml.Diags) !?ir.Step {
    switch (node.data) {
        .map => {},
        else => {
            try warn(diags, node, "step is not supported (skipped)", .{});
            return null;
        },
    }

    var key: []const u8 = "";
    var shell: ?[]const u8 = null;
    var script_node: ?yaml.Node = null;
    if (node.get("script")) |s| {
        key = "script";
        script_node = s;
    } else if (node.get("bash")) |s| {
        key = "bash";
        shell = "bash";
        script_node = s;
    } else if (node.get("pwsh")) |s| {
        key = "pwsh";
        shell = "pwsh";
        script_node = s;
    } else if (node.get("powershell")) |s| {
        key = "powershell";
        shell = "powershell";
        script_node = s;
    } else if (node.get("checkout")) |_| {
        try warn(diags, node, "checkout is not needed locally (skipped)", .{});
        return null;
    } else if (node.get("task")) |t| {
        try warn(diags, node, "task '{s}' is not supported (skipped)", .{t.scalarOr("")});
        return null;
    } else if (node.get("template")) |_| {
        try warn(diags, node, "templates are not supported (skipped)", .{});
        return null;
    } else if (node.get("publish")) |_| {
        try warn(diags, node, "'publish' is not simulated (skipped)", .{});
        return null;
    } else if (node.get("download")) |_| {
        try warn(diags, node, "'download' is not simulated (skipped)", .{});
        return null;
    } else {
        try warn(diags, node, "step is not supported (skipped)", .{});
        return null;
    }

    const sn = script_node.?;
    const raw_script = sn.scalarOr("");

    const default_id = try nextDefaultId(alloc, counts, key);
    const id = if (node.get("name")) |n| try sanitizeId(alloc, n.scalarOr("")) else default_id;

    const first_nl = std.mem.indexOfScalar(u8, raw_script, '\n') orelse raw_script.len;
    const default_name = raw_script[0..@min(first_nl, 60)];
    const name = if (node.get("displayName")) |d| d.scalarOr(default_name) else default_name;

    var cond: ?[]const u8 = null;
    if (node.get("condition")) |c| {
        const v = c.scalarOr("");
        if (std.mem.indexOf(u8, v, "always()") != null) {
            cond = "always()";
        } else if (v.len > 0) {
            try warn(diags, c, "step condition is not evaluated locally (step runs)", .{});
        }
    }

    const continue_on_error = if (node.get("continueOnError")) |c| std.mem.eql(u8, c.scalarOr(""), "true") else false;
    const workdir: ?[]const u8 = if (node.get("workingDirectory")) |w| w.scalarOr("") else null;

    if (node.get("failOnStderr")) |v| try warn(diags, v, "step key 'failOnStderr' is not simulated (ignored)", .{});
    if (node.get("retryCountOnTaskFailure")) |v| try warn(diags, v, "step key 'retryCountOnTaskFailure' is not simulated (ignored)", .{});
    if (node.get("timeoutInMinutes")) |v| try warn(diags, v, "step key 'timeoutInMinutes' is not simulated (ignored)", .{});

    switch (node.data) {
        .map => |m| {
            var it = m.iterator();
            while (it.next()) |e| {
                if (!contains(&step_known_keys, e.key_ptr.*))
                    try warn(diags, e.value_ptr.*, "step key '{s}' is not simulated (ignored)", .{e.key_ptr.*});
            }
        },
        else => {},
    }

    const rewritten = try rewriteMacros(alloc, raw_script, shell, sn, diags);

    return .{
        .id = id,
        .name = name,
        .kind = .run,
        .script = rewritten,
        .shell = shell,
        .env = try envPairsSimple(alloc, node.get("env")),
        .workdir = workdir,
        .cond = cond,
        .continue_on_error = continue_on_error,
        .src_line = node.line,
    };
}

const MatrixLabel = struct { label: []const u8, vars: []ir.EnvPair };

const BaseJob = struct {
    stage: []const u8,
    bare_id: []const u8,
    job: ir.Job,
    labels: []MatrixLabel,
};

const known_job_keys = [_][]const u8{
    "job", "deployment", "dependsOn", "variables", "steps", "pool",
    "container", "strategy", "condition", "continueOnError",
    "timeoutInMinutes", "workspace", "services",
};

fn lowerOneJob(
    alloc: std.mem.Allocator,
    stage_name: []const u8,
    bare_id: []const u8,
    is_deployment: bool,
    node: yaml.Node,
    root_vars: []const ir.EnvPair,
    stage_vars: []const ir.EnvPair,
    root_pool: []const u8,
    stage_ids: *const std.StringArrayHashMapUnmanaged(void),
    diags: *yaml.Diags,
) !BaseJob {
    if (is_deployment) try warn(diags, node, "deployment jobs run as normal jobs (strategy ignored)", .{});

    var needs: std.ArrayList([]const u8) = .empty;
    if (node.get("dependsOn")) |dn| {
        const names = try stringList(alloc, dn, diags);
        for (names) |nm| {
            if (stage_ids.contains(nm)) {
                try needs.append(alloc, nm);
            } else {
                try diags.add(dn.line, dn.col, "job '{s}' depends on unknown job '{s}'", .{ bare_id, nm });
            }
        }
    }

    const job_vars = try parseVariables(alloc, node.get("variables"), diags);

    var steps_node: ?yaml.Node = node.get("steps");
    if (is_deployment) {
        if (node.get("strategy")) |strat| if (strat.get("runOnce")) |ro| if (ro.get("deploy")) |dep| if (dep.get("steps")) |s| {
            steps_node = s;
        };
    }
    var steps_list: std.ArrayList(ir.Step) = .empty;
    var step_counts: StepCounts = .empty;
    if (steps_node) |sn| switch (sn.data) {
        .seq => |items| for (items) |item| {
            if (try lowerAzureStep(alloc, item, &step_counts, diags)) |st| try steps_list.append(alloc, st);
        },
        else => try diags.add(sn.line, sn.col, "'steps' must be a sequence", .{}),
    } else {
        try diags.add(node.line, node.col, "job '{s}' has no steps", .{bare_id});
    }

    var runs_on: []const u8 = root_pool;
    if (node.get("pool")) |p| runs_on = poolRunsOn(p);

    const container_image = containerImage(node.get("container"));

    var labels: std.ArrayList(MatrixLabel) = .empty;
    if (node.get("strategy")) |strat| {
        if (strat.get("matrix")) |matrix_node| switch (matrix_node.data) {
            .map => |mm| {
                var it = mm.iterator();
                while (it.next()) |e| {
                    const vars = try envPairsSimple(alloc, e.value_ptr.*);
                    try labels.append(alloc, .{ .label = e.key_ptr.*, .vars = vars });
                }
            },
            else => try diags.add(matrix_node.line, matrix_node.col, "'matrix' must be a mapping", .{}),
        };
        if (strat.get("maxParallel")) |mp| try warn(diags, mp, "strategy key 'maxParallel' is not simulated (ignored)", .{});
        switch (strat.data) {
            .map => |sm| {
                var sit = sm.iterator();
                while (sit.next()) |e| {
                    const k = e.key_ptr.*;
                    if (std.mem.eql(u8, k, "matrix") or std.mem.eql(u8, k, "maxParallel")) continue;
                    if (is_deployment and std.mem.eql(u8, k, "runOnce")) continue;
                    try warn(diags, e.value_ptr.*, "strategy key '{s}' is not simulated (ignored)", .{k});
                }
            },
            else => {},
        }
    }

    if (node.get("condition")) |_| try warn(diags, node, "job conditions are not evaluated locally (job runs)", .{});

    const continue_all = if (node.get("continueOnError")) |c| std.mem.eql(u8, c.scalarOr(""), "true") else false;
    if (continue_all) for (steps_list.items) |*s| {
        s.continue_on_error = true;
    };

    if (node.get("timeoutInMinutes")) |v| try warn(diags, v, "job key 'timeoutInMinutes' is not simulated (ignored)", .{});
    if (node.get("workspace")) |v| try warn(diags, v, "job key 'workspace' is not simulated (ignored)", .{});
    if (node.get("services")) |_| try warn(diags, node, "job services are not simulated", .{});

    switch (node.data) {
        .map => |m| {
            var it = m.iterator();
            while (it.next()) |e| {
                if (!contains(&known_job_keys, e.key_ptr.*))
                    try warn(diags, e.value_ptr.*, "job key '{s}' is not simulated (ignored)", .{e.key_ptr.*});
            }
        },
        else => {},
    }

    var env: std.ArrayList(ir.EnvPair) = .empty;
    try env.appendSlice(alloc, &[_]ir.EnvPair{
        .{ .name = "TF_BUILD", .value = "True" },
        .{ .name = "AGENT_JOBNAME", .value = bare_id },
    });
    try env.appendSlice(alloc, root_vars);
    try env.appendSlice(alloc, stage_vars);
    try env.appendSlice(alloc, job_vars);

    return .{
        .stage = stage_name,
        .bare_id = bare_id,
        .job = .{
            .id = bare_id,
            .display_name = bare_id,
            .runs_on = runs_on,
            .needs = try needs.toOwnedSlice(alloc),
            .env = try env.toOwnedSlice(alloc),
            .steps = try steps_list.toOwnedSlice(alloc),
            .src_line = node.line,
            .container_image = container_image,
            .provider = .azure,
        },
        .labels = try labels.toOwnedSlice(alloc),
    };
}

const JobEntry = struct { node: yaml.Node, override_id: ?[]const u8 = null };

fn lowerStageJobs(
    alloc: std.mem.Allocator,
    stage_name: []const u8,
    entries: []const JobEntry,
    root_vars: []const ir.EnvPair,
    stage_vars: []const ir.EnvPair,
    root_pool: []const u8,
    bases: *std.ArrayList(BaseJob),
    diags: *yaml.Diags,
) !void {
    const bare_ids = try alloc.alloc([]const u8, entries.len);
    const is_deploy = try alloc.alloc(bool, entries.len);
    const valid_entry = try alloc.alloc(bool, entries.len);
    var stage_ids: std.StringArrayHashMapUnmanaged(void) = .empty;

    for (entries, 0..) |entry, i| {
        switch (entry.node.data) {
            .map => {},
            else => {
                try diags.add(entry.node.line, entry.node.col, "job entry must be a mapping", .{});
                bare_ids[i] = "";
                is_deploy[i] = false;
                valid_entry[i] = false;
                continue;
            },
        }
        valid_entry[i] = true;
        var deploy = false;
        var bare: []const u8 = "";
        if (entry.override_id) |o| {
            bare = o;
        } else if (entry.node.get("deployment")) |n| {
            deploy = true;
            const v = n.scalarOr("");
            bare = if (v.len > 0) v else try std.fmt.allocPrint(alloc, "job-{d}", .{i + 1});
        } else if (entry.node.get("job")) |n| {
            const v = n.scalarOr("");
            bare = if (v.len > 0) v else try std.fmt.allocPrint(alloc, "job-{d}", .{i + 1});
        } else {
            try diags.add(entry.node.line, entry.node.col, "job entry must have a 'job' or 'deployment' key", .{});
            bare = try std.fmt.allocPrint(alloc, "job-{d}", .{i + 1});
        }
        bare_ids[i] = bare;
        is_deploy[i] = deploy;
        try stage_ids.put(alloc, bare, {});
    }

    for (entries, 0..) |entry, i| {
        if (!valid_entry[i]) continue;
        const base = try lowerOneJob(alloc, stage_name, bare_ids[i], is_deploy[i], entry.node, root_vars, stage_vars, root_pool, &stage_ids, diags);
        try bases.append(alloc, base);
    }
}

const StageDef = struct {
    name: []const u8,
    depends_on: [][]const u8,
    variables: []ir.EnvPair,
    entries: []JobEntry,
    src_line: u32,
};

const known_stage_keys = [_][]const u8{ "stage", "dependsOn", "variables", "jobs" };

fn validateBases(alloc: std.mem.Allocator, bases: []const BaseJob, diags: *yaml.Diags) !void {
    var ids: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (bases) |b| try ids.put(alloc, b.job.id, {});
    for (bases) |b| for (b.job.needs) |need| {
        if (!ids.contains(need)) try diags.add(b.job.src_line, 1, "job '{s}' needs unknown job '{s}'", .{ b.job.id, need });
    };

    const Color = enum { white, grey, black };
    var colors: std.StringArrayHashMapUnmanaged(Color) = .empty;
    for (ids.keys()) |id| try colors.put(alloc, id, .white);
    const Ctx = struct {
        bases: []const BaseJob,
        colors: *std.StringArrayHashMapUnmanaged(Color),
        diags: *yaml.Diags,
        alloc: std.mem.Allocator,
        fn find(self: @This(), id: []const u8) ?ir.Job {
            for (self.bases) |b| if (std.mem.eql(u8, b.job.id, id)) return b.job;
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
            if (self.find(id)) |job| for (job.needs) |n| try self.visit(n);
            try self.colors.put(self.alloc, id, .black);
        }
    };
    const ctx = Ctx{ .bases = bases, .colors = &colors, .diags = diags, .alloc = alloc };
    for (ids.keys()) |id| try ctx.visit(id);
}

pub fn parsePipeline(alloc: std.mem.Allocator, source_path: []const u8, source: []const u8, diags: *yaml.Diags) ParseError!ir.Pipeline {
    const root = yaml.parse(alloc, source, diags) catch |err| return switch (err) {
        error.ParseFailed => error.ParseFailed,
        error.OutOfMemory => error.OutOfMemory,
    };
    switch (root.data) {
        .map => {},
        else => {
            try diags.add(root.line, root.col, "Azure pipeline must be a mapping", .{});
            return error.ParseFailed;
        },
    }

    const pipeline_name = if (root.get("name")) |n| n.scalarOr("azure") else "azure";
    const root_vars = try parseVariables(alloc, root.get("variables"), diags);
    const root_pool = poolRunsOn(root.get("pool"));

    const recognized_root_keys = [_][]const u8{
        "trigger", "pr", "schedules", "resources", "parameters",
        "pool",    "name", "variables", "stages", "jobs", "steps",
    };
    switch (root.data) {
        .map => |m| {
            var it = m.iterator();
            while (it.next()) |e| {
                if (!contains(&recognized_root_keys, e.key_ptr.*))
                    try warn(diags, e.value_ptr.*, "'{s}' is not simulated (ignored)", .{e.key_ptr.*});
            }
        },
        else => {},
    }
    for ([_][]const u8{ "trigger", "pr", "schedules", "resources", "parameters" }) |k| {
        if (root.get(k)) |n| try warn(diags, n, "'{s}' is not simulated (ignored)", .{k});
    }

    var stage_defs: std.ArrayList(StageDef) = .empty;
    if (root.get("stages")) |stages_node| {
        switch (stages_node.data) {
            .seq => |items| for (items, 0..) |snode, i| {
                const stage_name = if (snode.get("stage")) |sn| sn.scalarOr("") else "";
                if (stage_name.len == 0) try diags.add(snode.line, snode.col, "stage entry missing 'stage' name", .{});

                var depends_on: [][]const u8 = &.{};
                if (snode.get("dependsOn")) |dn| {
                    depends_on = try stringList(alloc, dn, diags);
                } else if (i > 0) {
                    depends_on = try alloc.dupe([]const u8, &[_][]const u8{stage_defs.items[i - 1].name});
                }

                const stage_vars = try parseVariables(alloc, snode.get("variables"), diags);

                var entries: std.ArrayList(JobEntry) = .empty;
                if (snode.get("jobs")) |jn| switch (jn.data) {
                    .seq => |jitems| for (jitems) |jnode| try entries.append(alloc, .{ .node = jnode }),
                    else => try diags.add(jn.line, jn.col, "'jobs' must be a list of mappings", .{}),
                } else {
                    try diags.add(snode.line, snode.col, "stage '{s}' has no jobs", .{stage_name});
                }

                switch (snode.data) {
                    .map => |sm| {
                        var sit = sm.iterator();
                        while (sit.next()) |e| {
                            if (!contains(&known_stage_keys, e.key_ptr.*))
                                try warn(diags, e.value_ptr.*, "stage key '{s}' is not simulated (ignored)", .{e.key_ptr.*});
                        }
                    },
                    else => {},
                }

                try stage_defs.append(alloc, .{
                    .name = stage_name,
                    .depends_on = depends_on,
                    .variables = stage_vars,
                    .entries = try entries.toOwnedSlice(alloc),
                    .src_line = snode.line,
                });
            },
            else => try diags.add(stages_node.line, stages_node.col, "'stages' must be a list of mappings", .{}),
        }
    } else if (root.get("jobs")) |jobs_node| {
        var entries: std.ArrayList(JobEntry) = .empty;
        switch (jobs_node.data) {
            .seq => |items| for (items) |jnode| try entries.append(alloc, .{ .node = jnode }),
            else => try diags.add(jobs_node.line, jobs_node.col, "'jobs' must be a list of mappings", .{}),
        }
        try stage_defs.append(alloc, .{ .name = "", .depends_on = &.{}, .variables = &.{}, .entries = try entries.toOwnedSlice(alloc), .src_line = jobs_node.line });
    } else if (root.get("steps")) |steps_node| {
        var synth_map: yaml.Map = .empty;
        try synth_map.put(alloc, "steps", steps_node);
        const synth_node = yaml.Node{ .line = steps_node.line, .col = steps_node.col, .data = .{ .map = synth_map } };
        var entries: std.ArrayList(JobEntry) = .empty;
        try entries.append(alloc, .{ .node = synth_node, .override_id = "job" });
        try stage_defs.append(alloc, .{ .name = "", .depends_on = &.{}, .variables = &.{}, .entries = try entries.toOwnedSlice(alloc), .src_line = steps_node.line });
    } else {
        try diags.add(root.line, root.col, "azure pipeline has no 'stages', 'jobs', or 'steps'", .{});
    }

    var stage_name_set: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (stage_defs.items) |sd| try stage_name_set.put(alloc, sd.name, {});
    for (stage_defs.items) |*sd| {
        var valid: std.ArrayList([]const u8) = .empty;
        for (sd.depends_on) |dep| {
            if (stage_name_set.contains(dep)) {
                try valid.append(alloc, dep);
            } else {
                try diags.add(sd.src_line, 1, "stage '{s}' depends on unknown stage '{s}'", .{ sd.name, dep });
            }
        }
        sd.depends_on = try valid.toOwnedSlice(alloc);
    }

    var bases: std.ArrayList(BaseJob) = .empty;
    for (stage_defs.items) |sd| {
        try lowerStageJobs(alloc, sd.name, sd.entries, root_vars, sd.variables, root_pool, &bases, diags);
    }
    if (bases.items.len == 0) try diags.add(root.line, root.col, "pipeline has no jobs", .{});

    var counts: std.StringArrayHashMapUnmanaged(u32) = .empty;
    for (bases.items) |b| {
        const prev = counts.get(b.bare_id) orelse 0;
        try counts.put(alloc, b.bare_id, prev + 1);
    }
    for (bases.items) |*b| {
        const c = counts.get(b.bare_id) orelse 0;
        const final_id = if (c > 1) try std.fmt.allocPrint(alloc, "{s}-{s}", .{ b.stage, b.bare_id }) else b.bare_id;
        b.job.id = final_id;
        b.job.display_name = final_id;
        for (b.job.needs, 0..) |need, ni| {
            const nc = counts.get(need) orelse 0;
            b.job.needs[ni] = if (nc > 1) try std.fmt.allocPrint(alloc, "{s}-{s}", .{ b.stage, need }) else need;
        }
    }

    for (stage_defs.items) |sd| {
        if (sd.depends_on.len == 0) continue;
        for (bases.items) |*b| {
            if (!std.mem.eql(u8, b.stage, sd.name)) continue;
            for (sd.depends_on) |dep_stage| {
                for (bases.items) |other| {
                    if (!std.mem.eql(u8, other.stage, dep_stage)) continue;
                    var already = false;
                    for (b.job.needs) |n| if (std.mem.eql(u8, n, other.job.id)) {
                        already = true;
                    };
                    if (!already) {
                        var list: std.ArrayList([]const u8) = .empty;
                        try list.appendSlice(alloc, b.job.needs);
                        try list.append(alloc, other.job.id);
                        b.job.needs = try list.toOwnedSlice(alloc);
                    }
                }
            }
        }
    }

    try validateBases(alloc, bases.items, diags);
    if (hasHardError(diags)) return error.ParseFailed;

    var jobs: std.ArrayList(ir.Job) = .empty;
    for (bases.items) |b| {
        if (b.labels.len == 0) {
            try jobs.append(alloc, b.job);
            continue;
        }
        for (b.labels) |label| {
            var j = b.job;
            var env: std.ArrayList(ir.EnvPair) = .empty;
            try env.appendSlice(alloc, j.env);
            try env.appendSlice(alloc, label.vars);
            j.env = try env.toOwnedSlice(alloc);
            j.matrix = label.vars;
            j.display_name = try std.fmt.allocPrint(alloc, "{s} ({s})", .{ b.job.id, label.label });
            try jobs.append(alloc, j);
        }
    }

    return .{ .name = pipeline_name, .source_path = source_path, .jobs = try jobs.toOwnedSlice(alloc) };
}

test "steps-only shape lowers to a single implicit job in a single implicit stage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\steps:
        \\  - script: echo hi
    ;
    const p = try parsePipeline(a, "azure-pipelines.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 1), p.jobs.len);
    try std.testing.expectEqualStrings("job", p.jobs[0].id);
    try std.testing.expectEqualStrings("echo hi", p.jobs[0].steps[0].script);
}

test "jobs shape: dependsOn wires needs, absent dependsOn means parallel" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\jobs:
        \\  - job: a
        \\    steps:
        \\      - script: echo a
        \\  - job: b
        \\    dependsOn: a
        \\    steps:
        \\      - script: echo b
        \\  - job: c
        \\    steps:
        \\      - script: echo c
    ;
    const p = try parsePipeline(a, "azure-pipelines.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 3), p.jobs.len);
    try std.testing.expectEqual(@as(usize, 0), p.jobs[0].needs.len);
    try std.testing.expectEqualStrings("a", p.jobs[1].needs[0]);
    try std.testing.expectEqual(@as(usize, 0), p.jobs[2].needs.len);
}

test "stages: implicit sequential dependency and explicit empty dependsOn" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\stages:
        \\  - stage: build
        \\    jobs:
        \\      - job: b
        \\        steps:
        \\          - script: echo build
        \\  - stage: test
        \\    jobs:
        \\      - job: t
        \\        steps:
        \\          - script: echo test
        \\  - stage: lint
        \\    dependsOn: []
        \\    jobs:
        \\      - job: l
        \\        steps:
        \\          - script: echo lint
    ;
    const p = try parsePipeline(a, "azure-pipelines.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 3), p.jobs.len);
    var t_job: ?ir.Job = null;
    var l_job: ?ir.Job = null;
    for (p.jobs) |j| {
        if (std.mem.eql(u8, j.id, "t")) t_job = j;
        if (std.mem.eql(u8, j.id, "l")) l_job = j;
    }
    try std.testing.expectEqualStrings("b", t_job.?.needs[0]);
    try std.testing.expectEqual(@as(usize, 0), l_job.?.needs.len);
}

test "cross-stage needs fan out to every job of the depended-on stage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\stages:
        \\  - stage: s1
        \\    jobs:
        \\      - job: a
        \\        steps:
        \\          - script: echo a
        \\      - job: b
        \\        steps:
        \\          - script: echo b
        \\  - stage: s2
        \\    jobs:
        \\      - job: c
        \\        steps:
        \\          - script: echo c
    ;
    const p = try parsePipeline(a, "azure-pipelines.yml", source, &diags);
    var c_job: ?ir.Job = null;
    for (p.jobs) |j| if (std.mem.eql(u8, j.id, "c")) {
        c_job = j;
    };
    try std.testing.expectEqual(@as(usize, 2), c_job.?.needs.len);
    var has_a = false;
    var has_b = false;
    for (c_job.?.needs) |n| {
        if (std.mem.eql(u8, n, "a")) has_a = true;
        if (std.mem.eql(u8, n, "b")) has_b = true;
    }
    try std.testing.expect(has_a and has_b);
}

test "script/bash/pwsh steps map to the expected shell" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\steps:
        \\  - script: echo plain
        \\  - bash: echo bash
        \\  - pwsh: echo pwsh
    ;
    const p = try parsePipeline(a, "azure-pipelines.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 3), p.jobs[0].steps.len);
    try std.testing.expect(p.jobs[0].steps[0].shell == null);
    try std.testing.expectEqualStrings("bash", p.jobs[0].steps[1].shell.?);
    try std.testing.expectEqualStrings("pwsh", p.jobs[0].steps[2].shell.?);
}

test "displayName, env, workingDirectory, always() condition, and continueOnError lower correctly" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\steps:
        \\  - script: echo hi
        \\    displayName: say hi
        \\    workingDirectory: sub
        \\    continueOnError: true
        \\    env:
        \\      FOO: bar
        \\    condition: always()
    ;
    const p = try parsePipeline(a, "azure-pipelines.yml", source, &diags);
    const s = p.jobs[0].steps[0];
    try std.testing.expectEqualStrings("say hi", s.name);
    try std.testing.expectEqualStrings("sub", s.workdir.?);
    try std.testing.expect(s.continue_on_error);
    try std.testing.expectEqualStrings("FOO", s.env[0].name);
    try std.testing.expectEqualStrings("always()", s.cond.?);
}

test "checkout and task steps warn and are skipped, not lowered as run steps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\steps:
        \\  - checkout: self
        \\  - task: Npm@1
        \\  - script: echo hi
    ;
    const p = try parsePipeline(a, "azure-pipelines.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 1), p.jobs[0].steps.len);
    var checkout_warn = false;
    var task_warn = false;
    for (diags.list.items) |d| {
        if (std.mem.indexOf(u8, d.msg, "checkout is not needed locally") != null) checkout_warn = true;
        if (std.mem.indexOf(u8, d.msg, "task 'Npm@1' is not supported") != null) task_warn = true;
    }
    try std.testing.expect(checkout_warn and task_warn);
}

test "strategy matrix expands one job per label with env and satisfies dependents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\jobs:
        \\  - job: build
        \\    strategy:
        \\      matrix:
        \\        linux:
        \\          IMAGE: ubuntu
        \\        mac:
        \\          IMAGE: macos
        \\    steps:
        \\      - script: echo $(IMAGE)
        \\  - job: test
        \\    dependsOn: build
        \\    steps:
        \\      - script: echo test
    ;
    const p = try parsePipeline(a, "azure-pipelines.yml", source, &diags);
    var build_count: usize = 0;
    var test_job: ?ir.Job = null;
    for (p.jobs) |j| {
        if (std.mem.eql(u8, j.id, "build")) build_count += 1;
        if (std.mem.eql(u8, j.id, "test")) test_job = j;
    }
    try std.testing.expectEqual(@as(usize, 2), build_count);
    try std.testing.expectEqualStrings("build", test_job.?.needs[0]);
    var linux_found = false;
    for (p.jobs) |j| {
        if (std.mem.eql(u8, j.id, "build") and std.mem.eql(u8, j.display_name, "build (linux)")) {
            linux_found = true;
            try std.testing.expectEqualStrings("IMAGE", j.matrix[0].name);
            try std.testing.expectEqualStrings("ubuntu", j.matrix[0].value);
        }
    }
    try std.testing.expect(linux_found);
}

test "variables: map form, list form, and group warns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\variables:
        \\  ROOT: root
        \\jobs:
        \\  - job: j
        \\    variables:
        \\      - name: X
        \\        value: "1"
        \\      - group: shared
        \\    steps:
        \\      - script: echo hi
    ;
    const p = try parsePipeline(a, "azure-pipelines.yml", source, &diags);
    var root_found = false;
    var x_found = false;
    for (p.jobs[0].env) |e| {
        if (std.mem.eql(u8, e.name, "ROOT")) root_found = true;
        if (std.mem.eql(u8, e.name, "X")) {
            x_found = true;
            try std.testing.expectEqualStrings("1", e.value);
        }
    }
    try std.testing.expect(root_found and x_found);
    var group_warn = false;
    for (diags.list.items) |d| if (std.mem.indexOf(u8, d.msg, "variable groups are not available locally") != null) {
        group_warn = true;
    };
    try std.testing.expect(group_warn);
}

test "macro rewrite: bash gets ${X}, pwsh gets $env:X" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\steps:
        \\  - bash: echo $(X)
        \\  - pwsh: echo $(X)
    ;
    const p = try parsePipeline(a, "azure-pipelines.yml", source, &diags);
    try std.testing.expectEqualStrings("echo ${X}", p.jobs[0].steps[0].script);
    try std.testing.expectEqualStrings("echo $env:X", p.jobs[0].steps[1].script);
}

test "predefined dotted variable macros warn and are left literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\steps:
        \\  - script: echo $(Build.SourcesDirectory)
    ;
    const p = try parsePipeline(a, "azure-pipelines.yml", source, &diags);
    try std.testing.expectEqualStrings("echo $(Build.SourcesDirectory)", p.jobs[0].steps[0].script);
    var found = false;
    for (diags.list.items) |d| if (std.mem.indexOf(u8, d.msg, "predefined variable '$(Build.SourcesDirectory)' is not available") != null) {
        found = true;
    };
    try std.testing.expect(found);
}

test "duplicate bare job names across stages get a deterministic stage prefix" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\stages:
        \\  - stage: s1
        \\    jobs:
        \\      - job: build
        \\        steps:
        \\          - script: echo one
        \\  - stage: s2
        \\    dependsOn: []
        \\    jobs:
        \\      - job: build
        \\        steps:
        \\          - script: echo two
    ;
    const p = try parsePipeline(a, "azure-pipelines.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 2), p.jobs.len);
    try std.testing.expectEqualStrings("s1-build", p.jobs[0].id);
    try std.testing.expectEqualStrings("s2-build", p.jobs[1].id);
}

test "unknown dependsOn is a hard diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\jobs:
        \\  - job: a
        \\    dependsOn: ghost
        \\    steps:
        \\      - script: echo a
    ;
    try std.testing.expectError(error.ParseFailed, parsePipeline(a, "azure-pipelines.yml", source, &diags));
    var found = false;
    for (diags.list.items) |d| if (std.mem.indexOf(u8, d.msg, "depends on unknown job 'ghost'") != null) {
        found = true;
    };
    try std.testing.expect(found);
}

test "job without steps is a hard diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\jobs:
        \\  - job: a
        \\    pool:
        \\      vmImage: ubuntu-latest
    ;
    try std.testing.expectError(error.ParseFailed, parsePipeline(a, "azure-pipelines.yml", source, &diags));
    var found = false;
    for (diags.list.items) |d| if (std.mem.indexOf(u8, d.msg, "job 'a' has no steps") != null) {
        found = true;
    };
    try std.testing.expect(found);
}
