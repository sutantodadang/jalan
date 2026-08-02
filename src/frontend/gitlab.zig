const std = @import("std");
const yaml = @import("../yaml.zig");
const ir = @import("../ir.zig");

pub const ParseError = error{ ParseFailed, OutOfMemory };

const default_stages = [_][]const u8{ ".pre", "build", "test", "deploy", ".post" };
const root_keys = [_][]const u8{ "stages", "variables", "before_script", "after_script", "default", "include", "workflow", "image", "services", "cache", "spec" };
const job_keys = [_][]const u8{
    "script",        "stage",     "needs", "variables",      "before_script", "image",    "services", "parallel", "allow_failure",
    "after_script",  "artifacts", "cache", "dependencies",   "rules",         "only",     "except",   "tags",     "extends",
    "interruptible", "timeout",   "retry", "resource_group", "trigger",       "coverage", "release",  "when",     "environment",
};
const job_supported = [_][]const u8{ "script", "stage", "needs", "variables", "before_script", "image", "services", "parallel", "allow_failure" };
const unsafe_job_keys = [_][]const u8{ "rules", "only", "except", "when", "extends", "after_script" };
const unsafe_root_keys = [_][]const u8{ "workflow", "default", "include", "image", "services", "after_script" };

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

fn scripts(alloc: std.mem.Allocator, node: ?yaml.Node, field: []const u8, diags: *yaml.Diags) ![][]const u8 {
    const n = node orelse return alloc.alloc([]const u8, 0);
    return stringList(alloc, n, field, diags);
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

fn implicitServiceName(image: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, image, '/') orelse 0;
    const start = if (slash == 0) 0 else slash + 1;
    const tail = image[start..];
    const end = std.mem.indexOfAny(u8, tail, ":@") orelse tail.len;
    return tail[0..end];
}

fn firstAlias(alias: []const u8) []const u8 {
    return std.mem.trim(u8, alias[0 .. std.mem.indexOfAny(u8, alias, ", ") orelse alias.len], " ");
}

fn lowerServices(alloc: std.mem.Allocator, node: ?yaml.Node, diags: *yaml.Diags) ![]ir.Service {
    var out: std.ArrayList(ir.Service) = .empty;
    const n = node orelse return out.toOwnedSlice(alloc);
    switch (n.data) {
        .seq => |items| for (items) |item| switch (item.data) {
            .scalar => |image| try out.append(alloc, .{ .name = implicitServiceName(image), .image = image }),
            .map => |m| {
                var it = m.iterator();
                while (it.next()) |entry| {
                    if (!contains(&.{ "name", "alias", "variables" }, entry.key_ptr.*))
                        try warn(diags, entry.value_ptr.*, "service key '{s}' is not simulated (ignored)", .{entry.key_ptr.*});
                }
                const image_node = item.get("name") orelse {
                    try diags.add(item.line, item.col, "service mapping requires 'name'", .{});
                    continue;
                };
                const image = image_node.scalarOr("");
                var name = if (item.get("alias")) |alias| alias.scalarOr("") else implicitServiceName(image);
                if (std.mem.indexOfAny(u8, name, ", ") != null) {
                    try warn(diags, item.get("alias").?, "multiple service aliases are not supported; using the first", .{});
                    name = firstAlias(name);
                }
                try out.append(alloc, .{ .name = name, .image = image, .env = try envPairs(alloc, item.get("variables"), diags) });
            },
            .seq => try diags.add(item.line, item.col, "nested 'services' lists are not supported", .{}),
        },
        else => try diags.add(n.line, n.col, "'services' must be a list", .{}),
    }
    return out.toOwnedSlice(alloc);
}

fn needsList(alloc: std.mem.Allocator, node: yaml.Node, diags: *yaml.Diags) ![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    switch (node.data) {
        .scalar => |value| if (value.len > 0) try out.append(alloc, value),
        .seq => |items| for (items) |item| switch (item.data) {
            .scalar => |value| try out.append(alloc, value),
            .map => {
                const job = item.get("job") orelse {
                    try diags.add(item.line, item.col, "needs mapping requires 'job'", .{});
                    continue;
                };
                try out.append(alloc, job.scalarOr(""));
                try warn(diags, item, "needs metadata and artifact transfer are not simulated", .{});
            },
            .seq => try diags.add(item.line, item.col, "nested 'needs' lists are not supported", .{}),
        },
        .map => try diags.add(node.line, node.col, "'needs' must be a string or list", .{}),
    }
    return out.toOwnedSlice(alloc);
}

const ComboList = []const []ir.EnvPair;

fn expandMatrixRow(alloc: std.mem.Allocator, row: yaml.Node, diags: *yaml.Diags) !ComboList {
    const m = switch (row.data) {
        .map => |value| value,
        else => {
            try diags.add(row.line, row.col, "parallel matrix rows must be mappings", .{});
            return alloc.alloc([]ir.EnvPair, 0);
        },
    };
    var combos: std.ArrayList([]ir.EnvPair) = .empty;
    try combos.append(alloc, try alloc.alloc(ir.EnvPair, 0));
    var it = m.iterator();
    while (it.next()) |entry| {
        const values = try stringList(alloc, entry.value_ptr.*, "parallel matrix axis", diags);
        if (values.len == 0) {
            try diags.add(entry.value_ptr.line, entry.value_ptr.col, "matrix axis '{s}' has no values", .{entry.key_ptr.*});
            continue;
        }
        var next: std.ArrayList([]ir.EnvPair) = .empty;
        for (combos.items) |combo| for (values) |value| {
            var copy = try alloc.alloc(ir.EnvPair, combo.len + 1);
            @memcpy(copy[0..combo.len], combo);
            copy[combo.len] = .{ .name = entry.key_ptr.*, .value = value };
            try next.append(alloc, copy);
        };
        combos = next;
    }
    return combos.toOwnedSlice(alloc);
}

fn matrixCombos(alloc: std.mem.Allocator, node: ?yaml.Node, diags: *yaml.Diags) !ComboList {
    const parallel = node orelse return alloc.alloc([]ir.EnvPair, 0);
    const matrix = switch (parallel.data) {
        .scalar => {
            try warn(diags, parallel, "numeric parallel jobs are not simulated (running once)", .{});
            return alloc.alloc([]ir.EnvPair, 0);
        },
        .map => parallel.get("matrix") orelse {
            try warn(diags, parallel, "parallel configuration without matrix is not simulated (running once)", .{});
            return alloc.alloc([]ir.EnvPair, 0);
        },
        .seq => {
            try diags.add(parallel.line, parallel.col, "'parallel' must be a number or mapping", .{});
            return alloc.alloc([]ir.EnvPair, 0);
        },
    };
    var out: std.ArrayList([]ir.EnvPair) = .empty;
    switch (matrix.data) {
        .seq => |rows| for (rows) |row| try out.appendSlice(alloc, try expandMatrixRow(alloc, row, diags)),
        .map => try out.appendSlice(alloc, try expandMatrixRow(alloc, matrix, diags)),
        .scalar => try diags.add(matrix.line, matrix.col, "'parallel:matrix' must be a list of mappings", .{}),
    }
    return out.toOwnedSlice(alloc);
}

fn checkJobKeys(node: yaml.Node, diags: *yaml.Diags) !void {
    const m = switch (node.data) {
        .map => |value| value,
        else => return,
    };
    var it = m.iterator();
    while (it.next()) |entry| {
        if (contains(&job_supported, entry.key_ptr.*)) continue;
        if (contains(&unsafe_job_keys, entry.key_ptr.*)) {
            try diags.add(entry.value_ptr.line, entry.value_ptr.col, "job key '{s}' affects execution and is not supported", .{entry.key_ptr.*});
            continue;
        }
        const wording: []const u8 = if (contains(&job_keys, entry.key_ptr.*)) "is recognized but not simulated" else "is not supported";
        try warn(diags, entry.value_ptr.*, "job key '{s}' {s} (ignored)", .{ entry.key_ptr.*, wording });
    }
}

const BaseJob = struct {
    job: ir.Job,
    stage: []const u8,
    explicit_needs: bool,
    combos: ComboList,
};

fn lowerJob(
    alloc: std.mem.Allocator,
    id: []const u8,
    node: yaml.Node,
    root_env: []const ir.EnvPair,
    root_before: []const []const u8,
    diags: *yaml.Diags,
) !BaseJob {
    const stage = if (node.get("stage")) |stage_node| stage_node.scalarOr("") else "test";
    const script_node = node.get("script") orelse {
        try diags.add(node.line, node.col, "job '{s}' has no script", .{id});
        return .{ .job = .{ .id = id, .display_name = id, .steps = &.{}, .src_line = node.line }, .stage = "test", .explicit_needs = false, .combos = &.{} };
    };
    const script_lines = try scripts(alloc, script_node, "script", diags);
    if (script_lines.len == 0) try diags.add(script_node.line, script_node.col, "job '{s}' has an empty script", .{id});
    const before = if (node.get("before_script")) |local| try scripts(alloc, local, "before_script", diags) else root_before;
    var commands: std.ArrayList([]const u8) = .empty;
    try commands.appendSlice(alloc, before);
    try commands.appendSlice(alloc, script_lines);

    var env: std.ArrayList(ir.EnvPair) = .empty;
    try env.appendSlice(alloc, root_env);
    try env.appendSlice(alloc, try envPairs(alloc, node.get("variables"), diags));
    try env.appendSlice(alloc, &.{
        .{ .name = "GITLAB_CI", .value = "true" },
        .{ .name = "CI_JOB_NAME", .value = id },
        .{ .name = "CI_JOB_STAGE", .value = stage },
    });

    const allow_failure = if (node.get("allow_failure")) |allow| switch (allow.data) {
        .scalar => |value| std.ascii.eqlIgnoreCase(value, "true"),
        else => blk: {
            try warn(diags, allow, "allow_failure forms other than boolean are not simulated (ignored)", .{});
            break :blk false;
        },
    } else false;
    if (node.get("needs")) |needs| try warn(diags, needs, "needs artifact transfer is not simulated", .{});
    try checkJobKeys(node, diags);

    var steps = try alloc.alloc(ir.Step, 1);
    steps[0] = .{
        .id = "script",
        .name = "script",
        .kind = .run,
        .script = try std.mem.join(alloc, "\n", commands.items),
        .continue_on_error = allow_failure,
        .src_line = script_node.line,
    };
    return .{
        .job = .{
            .id = id,
            .display_name = id,
            .needs = if (node.get("needs")) |needs| try needsList(alloc, needs, diags) else &.{},
            .env = try env.toOwnedSlice(alloc),
            .steps = steps,
            .src_line = node.line,
            .container_image = try imageName(node.get("image"), diags),
            .services = try lowerServices(alloc, node.get("services"), diags),
            .provider = .gitlab,
        },
        .stage = stage,
        .explicit_needs = node.get("needs") != null,
        .combos = try matrixCombos(alloc, node.get("parallel"), diags),
    };
}

fn stageIndex(stages: []const []const u8, name: []const u8) ?usize {
    for (stages, 0..) |stage, i| if (std.mem.eql(u8, stage, name)) return i;
    return null;
}

fn materializeStageNeeds(alloc: std.mem.Allocator, bases: []BaseJob, stages: []const []const u8, diags: *yaml.Diags) !void {
    for (bases, 0..) |*base, i| {
        const current = stageIndex(stages, base.stage) orelse {
            try diags.add(base.job.src_line, 1, "job '{s}' uses unknown stage '{s}'", .{ base.job.id, base.stage });
            continue;
        };
        if (base.explicit_needs) continue;
        var needs: std.ArrayList([]const u8) = .empty;
        for (bases, 0..) |other, j| {
            if (i == j) continue;
            const prior = stageIndex(stages, other.stage) orelse continue;
            if (prior < current) try needs.append(alloc, other.job.id);
        }
        base.job.needs = try needs.toOwnedSlice(alloc);
    }
}

fn validate(alloc: std.mem.Allocator, bases: []const BaseJob, diags: *yaml.Diags) !void {
    var ids: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (bases) |base| try ids.put(alloc, base.job.id, {});
    for (bases) |base| for (base.job.needs) |need| {
        if (!ids.contains(need)) try diags.add(base.job.src_line, 1, "job '{s}' needs unknown job '{s}'", .{ base.job.id, need });
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
            for (self.bases) |base| if (std.mem.eql(u8, base.job.id, id)) return base.job;
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
    const ctx = Ctx{ .bases = bases, .colors = &colors, .diags = diags, .alloc = alloc };
    for (ids.keys()) |id| try ctx.visit(id);
}

fn appendExpanded(alloc: std.mem.Allocator, jobs: *std.ArrayList(ir.Job), base: BaseJob) !void {
    if (base.combos.len == 0) {
        try jobs.append(alloc, base.job);
        return;
    }
    for (base.combos) |combo| {
        var job = base.job;
        var env: std.ArrayList(ir.EnvPair) = .empty;
        try env.appendSlice(alloc, job.env);
        try env.appendSlice(alloc, combo);
        job.env = try env.toOwnedSlice(alloc);
        job.matrix = combo;
        var values: std.ArrayList([]const u8) = .empty;
        for (combo) |pair| try values.append(alloc, pair.value);
        job.display_name = try std.fmt.allocPrint(alloc, "{s} ({s})", .{ job.id, try std.mem.join(alloc, ", ", values.items) });
        try jobs.append(alloc, job);
    }
}

pub fn parsePipeline(alloc: std.mem.Allocator, source_path: []const u8, source: []const u8, diags: *yaml.Diags) ParseError!ir.Pipeline {
    const root = yaml.parse(alloc, source, diags) catch |err| return switch (err) {
        error.ParseFailed => error.ParseFailed,
        error.OutOfMemory => error.OutOfMemory,
    };
    const root_map = switch (root.data) {
        .map => |value| value,
        else => {
            try diags.add(root.line, root.col, "GitLab pipeline must be a mapping", .{});
            return error.ParseFailed;
        },
    };
    const stages = if (root.get("stages")) |node| try stringList(alloc, node, "stages", diags) else try alloc.dupe([]const u8, &default_stages);
    if (stages.len == 0) try diags.add(root.line, root.col, "'stages' must not be empty", .{});
    const root_env = try envPairs(alloc, root.get("variables"), diags);
    const root_before = if (root.get("before_script")) |node| try scripts(alloc, node, "before_script", diags) else &.{};

    for (root_keys) |key| if (root.get(key)) |node| {
        if (contains(&unsafe_root_keys, key))
            try diags.add(node.line, node.col, "global key '{s}' affects execution and is not supported", .{key})
        else if (!contains(&.{ "stages", "variables", "before_script" }, key))
            try warn(diags, node, "global key '{s}' is not simulated (ignored)", .{key});
    };

    var bases: std.ArrayList(BaseJob) = .empty;
    var it = root_map.iterator();
    while (it.next()) |entry| {
        const id = entry.key_ptr.*;
        if (contains(&root_keys, id)) continue;
        if (std.mem.startsWith(u8, id, ".")) {
            try warn(diags, entry.value_ptr.*, "hidden job/template '{s}' is not supported (ignored)", .{id});
            continue;
        }
        switch (entry.value_ptr.data) {
            .map => try bases.append(alloc, try lowerJob(alloc, id, entry.value_ptr.*, root_env, root_before, diags)),
            else => try diags.add(entry.value_ptr.line, entry.value_ptr.col, "job '{s}' must be a mapping", .{id}),
        }
    }
    if (bases.items.len == 0) try diags.add(root.line, root.col, "pipeline has no jobs", .{});
    try materializeStageNeeds(alloc, bases.items, stages, diags);
    try validate(alloc, bases.items, diags);
    if (hasHardError(diags)) return error.ParseFailed;

    var jobs: std.ArrayList(ir.Job) = .empty;
    for (bases.items) |base| try appendExpanded(alloc, &jobs, base);
    return .{ .name = source_path, .source_path = source_path, .jobs = try jobs.toOwnedSlice(alloc) };
}

pub fn parseWorkflow(alloc: std.mem.Allocator, source_path: []const u8, source: []const u8, diags: *yaml.Diags) ParseError!ir.Pipeline {
    return parsePipeline(alloc, source_path, source, diags);
}

test "lowers stages, scripts, variables, image, services, and allow_failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\stages: [build, test]
        \\variables:
        \\  ROOT: root
        \\before_script:
        \\  - echo root
        \\build:
        \\  stage: build
        \\  script: echo build
        \\test:
        \\  stage: test
        \\  variables:
        \\    LOCAL: local
        \\  image:
        \\    name: node:22
        \\  services:
        \\    - name: redis:7
        \\      alias: cache
        \\      variables:
        \\        MODE: test
        \\  allow_failure: true
        \\  script:
        \\    - echo test
    ;
    const pipeline = try parsePipeline(a, ".gitlab-ci.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 2), pipeline.jobs.len);
    try std.testing.expectEqualStrings("build", pipeline.jobs[1].needs[0]);
    try std.testing.expectEqualStrings("echo root\necho test", pipeline.jobs[1].steps[0].script);
    try std.testing.expectEqualStrings("ROOT", pipeline.jobs[1].env[0].name);
    try std.testing.expectEqualStrings("LOCAL", pipeline.jobs[1].env[1].name);
    try std.testing.expectEqualStrings("GITLAB_CI", pipeline.jobs[1].env[2].name);
    try std.testing.expectEqualStrings("CI_JOB_NAME", pipeline.jobs[1].env[3].name);
    try std.testing.expectEqualStrings("test", pipeline.jobs[1].env[4].value);
    try std.testing.expectEqualStrings("node:22", pipeline.jobs[1].container_image);
    try std.testing.expectEqualStrings("cache", pipeline.jobs[1].services[0].name);
    try std.testing.expect(pipeline.jobs[1].steps[0].continue_on_error);
}

test "explicit empty needs bypasses stage barrier and local before_script clears global" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\stages: [build, test]
        \\before_script: [echo root]
        \\build:
        \\  stage: build
        \\  script: echo build
        \\lint:
        \\  stage: test
        \\  needs: []
        \\  before_script: []
        \\  script: echo lint
    ;
    const pipeline = try parsePipeline(a, ".gitlab-ci.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 0), pipeline.jobs[1].needs.len);
    try std.testing.expectEqualStrings("echo lint", pipeline.jobs[1].steps[0].script);
}

test "parallel matrix expands rows and injects env" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\matrix:
        \\  script: echo $OS-$ARCH
        \\  parallel:
        \\    matrix:
        \\      - OS: [linux, mac]
        \\        ARCH: [x64, arm64]
    ;
    const pipeline = try parsePipeline(a, ".gitlab-ci.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 4), pipeline.jobs.len);
    try std.testing.expectEqualStrings("OS", pipeline.jobs[0].matrix[0].name);
    try std.testing.expectEqualStrings("ARCH", pipeline.jobs[3].env[4].name);
    try std.testing.expectEqualStrings("arm64", pipeline.jobs[3].env[4].value);
}

test "unknown stages, dangling needs, and cycles are hard diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\stages: [build]
        \\a:
        \\  stage: missing
        \\  needs: [b, ghost]
        \\  script: echo a
        \\b:
        \\  stage: build
        \\  needs: a
        \\  script: echo b
    ;
    try std.testing.expectError(error.ParseFailed, parsePipeline(a, ".gitlab-ci.yml", source, &diags));
    var stage = false;
    var dangling = false;
    var cycle = false;
    for (diags.list.items) |diag| {
        if (std.mem.indexOf(u8, diag.msg, "unknown stage") != null) stage = true;
        if (std.mem.indexOf(u8, diag.msg, "unknown job 'ghost'") != null) dangling = true;
        if (std.mem.indexOf(u8, diag.msg, "cycle") != null) cycle = true;
    }
    try std.testing.expect(stage and dangling and cycle);
}

test "unsupported job features warn without hiding the job" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\job:
        \\  script: echo ok
        \\  artifacts:
        \\    paths: [out]
        \\  tags: [docker]
        \\  unknown_key: value
    ;
    const pipeline = try parsePipeline(a, ".gitlab-ci.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 1), pipeline.jobs.len);
    try std.testing.expectEqual(@as(usize, 3), diags.list.items.len);
    for (diags.list.items) |diag| try std.testing.expect(std.mem.startsWith(u8, diag.msg, "warning: "));
}

test "execution gates and inherited execution config are hard diagnostics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\workflow:
        \\  rules:
        \\    - when: never
        \\job:
        \\  script: echo unsafe
        \\  rules:
        \\    - when: never
        \\  after_script: cleanup
    ;
    try std.testing.expectError(error.ParseFailed, parsePipeline(a, ".gitlab-ci.yml", source, &diags));
    try std.testing.expect(diags.list.items.len >= 3);
    for (diags.list.items) |diag| try std.testing.expect(!std.mem.startsWith(u8, diag.msg, "warning: "));
}
