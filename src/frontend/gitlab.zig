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
const job_supported = [_][]const u8{ "script", "stage", "needs", "variables", "before_script", "image", "services", "parallel", "allow_failure", "extends", "after_script", "rules", "when" };
const unsafe_job_keys = [_][]const u8{};
const unsafe_root_keys = [_][]const u8{};
const include_unsupported_types = [_][]const u8{ "file", "project", "remote", "template", "component" };
const rule_keys = [_][]const u8{ "if", "when", "variables", "allow_failure", "changes", "exists" };

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

const RuleVars = struct {
    pairs: []const ir.EnvPair,

    fn get(self: RuleVars, name: []const u8) ?[]const u8 {
        var i = self.pairs.len;
        while (i > 0) {
            i -= 1;
            if (std.mem.eql(u8, self.pairs[i].name, name)) return self.pairs[i].value;
        }
        return null;
    }
};

fn buildRuleVars(alloc: std.mem.Allocator, predefined: []const ir.EnvPair, root_env: []const ir.EnvPair, local_vars: []const ir.EnvPair) !RuleVars {
    var out: std.ArrayList(ir.EnvPair) = .empty;
    try out.appendSlice(alloc, predefined);
    try out.appendSlice(alloc, root_env);
    try out.appendSlice(alloc, local_vars);
    return .{ .pairs = try out.toOwnedSlice(alloc) };
}

const RuleValue = union(enum) {
    scalar: ?[]const u8,
    regex: []const u8,
    boolean: bool,

    fn asScalar(self: RuleValue) ?[]const u8 {
        return switch (self) {
            .scalar => |s| s,
            .regex => |r| r,
            .boolean => |b| if (b) "true" else null,
        };
    }

    fn truthy(self: RuleValue) bool {
        return switch (self) {
            .scalar => |s| if (s) |v| v.len > 0 else false,
            .regex => true,
            .boolean => |b| b,
        };
    }
};

fn ruleValuesEqual(a: RuleValue, b: RuleValue) bool {
    const as = a.asScalar();
    const bs = b.asScalar();
    if (as == null or bs == null) return as == null and bs == null;
    return std.mem.eql(u8, as.?, bs.?);
}

const RuleParseError = error{BadExpr} || std.mem.Allocator.Error;

const RuleParser = struct {
    src: []const u8,
    pos: usize = 0,
    vars: RuleVars,
    diags: *yaml.Diags,
    node: yaml.Node,
    warned_regex: bool = false,

    fn warnRegexOnce(self: *RuleParser) !void {
        if (self.warned_regex) return;
        self.warned_regex = true;
        try warn(self.diags, self.node, "regex match in rules is not supported (treated as matching)", .{});
    }

    fn skipWs(self: *RuleParser) void {
        while (self.pos < self.src.len and (self.src[self.pos] == ' ' or self.src[self.pos] == '\t')) self.pos += 1;
    }

    fn atEnd(self: *RuleParser) bool {
        self.skipWs();
        return self.pos >= self.src.len;
    }

    fn peekByte(self: *RuleParser) ?u8 {
        self.skipWs();
        if (self.pos >= self.src.len) return null;
        return self.src[self.pos];
    }

    fn eatStr(self: *RuleParser, s: []const u8) bool {
        self.skipWs();
        if (self.pos + s.len <= self.src.len and std.mem.eql(u8, self.src[self.pos .. self.pos + s.len], s)) {
            self.pos += s.len;
            return true;
        }
        return false;
    }

    fn isIdentChar(c: u8) bool {
        return std.ascii.isAlphanumeric(c) or c == '_';
    }

    fn parseOr(self: *RuleParser) RuleParseError!bool {
        var v = try self.parseAnd();
        while (self.eatStr("||")) {
            const rhs = try self.parseAnd();
            v = v or rhs;
        }
        return v;
    }

    fn parseAnd(self: *RuleParser) RuleParseError!bool {
        var v = try self.parseCmp();
        while (self.eatStr("&&")) {
            const rhs = try self.parseCmp();
            v = v and rhs;
        }
        return v;
    }

    fn parseCmp(self: *RuleParser) RuleParseError!bool {
        const lhs = try self.parsePrimary();
        if (self.eatStr("==")) {
            const rhs = try self.parsePrimary();
            return ruleValuesEqual(lhs, rhs);
        } else if (self.eatStr("!=")) {
            const rhs = try self.parsePrimary();
            return !ruleValuesEqual(lhs, rhs);
        } else if (self.eatStr("=~")) {
            _ = try self.parsePrimary();
            try self.warnRegexOnce();
            return true;
        } else if (self.eatStr("!~")) {
            _ = try self.parsePrimary();
            try self.warnRegexOnce();
            return true;
        }
        return lhs.truthy();
    }

    fn parsePrimary(self: *RuleParser) RuleParseError!RuleValue {
        const c = self.peekByte() orelse return error.BadExpr;
        if (c == '(') {
            self.pos += 1;
            const inner = try self.parseOr();
            if (!self.eatStr(")")) return error.BadExpr;
            return .{ .boolean = inner };
        }
        if (c == '$') {
            self.pos += 1;
            const start = self.pos;
            while (self.pos < self.src.len and isIdentChar(self.src[self.pos])) self.pos += 1;
            if (self.pos == start) return error.BadExpr;
            return .{ .scalar = self.vars.get(self.src[start..self.pos]) };
        }
        if (c == '"' or c == '\'') {
            self.pos += 1;
            const start = self.pos;
            while (self.pos < self.src.len and self.src[self.pos] != c) self.pos += 1;
            if (self.pos >= self.src.len) return error.BadExpr;
            const value = self.src[start..self.pos];
            self.pos += 1;
            return .{ .scalar = value };
        }
        if (c == '/') {
            self.pos += 1;
            const start = self.pos;
            while (self.pos < self.src.len and self.src[self.pos] != '/') self.pos += 1;
            if (self.pos >= self.src.len) return error.BadExpr;
            const value = self.src[start..self.pos];
            self.pos += 1;
            return .{ .regex = value };
        }
        if (self.eatStr("null")) return .{ .scalar = null };
        return error.BadExpr;
    }
};

fn evalRuleIf(alloc: std.mem.Allocator, src: []const u8, vars: RuleVars, node: yaml.Node, diags: *yaml.Diags) !bool {
    _ = alloc;
    var p = RuleParser{ .src = src, .vars = vars, .diags = diags, .node = node };
    const result = p.parseOr() catch |err| switch (err) {
        error.BadExpr => {
            try warn(diags, node, "cannot evaluate rule expression '{s}' (treated as matching)", .{src});
            return true;
        },
        error.OutOfMemory => return error.OutOfMemory,
    };
    if (!p.atEnd()) {
        try warn(diags, node, "cannot evaluate rule expression '{s}' (treated as matching)", .{src});
        return true;
    }
    return result;
}

const RuleMatch = struct {
    when: []const u8 = "on_success",
    variables: []ir.EnvPair = &.{},
    allow_failure: ?bool = null,
};

const RulesOutcome = union(enum) {
    malformed,
    no_match,
    matched: RuleMatch,
};

fn evalRuleList(alloc: std.mem.Allocator, rules_node: yaml.Node, vars: RuleVars, diags: *yaml.Diags) !RulesOutcome {
    const items = switch (rules_node.data) {
        .seq => |s| s,
        else => {
            try diags.add(rules_node.line, rules_node.col, "'rules' must be a list of mappings", .{});
            return .malformed;
        },
    };
    for (items) |rule_node| {
        switch (rule_node.data) {
            .map => {},
            else => {
                try diags.add(rule_node.line, rule_node.col, "'rules' must be a list of mappings", .{});
                continue;
            },
        }
        var matched = true;
        if (rule_node.get("if")) |if_node| {
            const src = if_node.scalarOr("");
            matched = try evalRuleIf(alloc, src, vars, if_node, diags);
        }
        if (rule_node.get("changes")) |cnode| try warn(diags, cnode, "rule key 'changes' is not evaluated locally (treated as matching)", .{});
        if (rule_node.get("exists")) |enode| try warn(diags, enode, "rule key 'exists' is not evaluated locally (treated as matching)", .{});
        const rm = rule_node.data.map;
        var it = rm.iterator();
        while (it.next()) |entry| {
            if (!contains(&rule_keys, entry.key_ptr.*))
                try warn(diags, entry.value_ptr.*, "rule key '{s}' is not simulated (ignored)", .{entry.key_ptr.*});
        }
        if (!matched) continue;
        var result = RuleMatch{};
        if (rule_node.get("when")) |when_node| result.when = when_node.scalarOr("on_success");
        if (rule_node.get("variables")) |vnode| result.variables = try envPairs(alloc, vnode, diags);
        if (rule_node.get("allow_failure")) |afnode| switch (afnode.data) {
            .scalar => |v| result.allow_failure = std.ascii.eqlIgnoreCase(v, "true"),
            else => try warn(diags, afnode, "allow_failure forms other than boolean are not simulated (ignored)", .{}),
        };
        return .{ .matched = result };
    }
    return .no_match;
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

const Defaults = struct {
    image: ?yaml.Node = null,
    services: ?yaml.Node = null,
    before_script: ?[]const []const u8 = null,
    after_script: ?[]const []const u8 = null,
};

fn mergeNodes(alloc: std.mem.Allocator, base: yaml.Node, override: yaml.Node) !yaml.Node {
    const base_map = switch (base.data) {
        .map => |m| m,
        else => return override,
    };
    const override_map = switch (override.data) {
        .map => |m| m,
        else => return override,
    };
    var out: yaml.Map = .empty;
    var it = base_map.iterator();
    while (it.next()) |entry| try out.put(alloc, entry.key_ptr.*, entry.value_ptr.*);
    var it2 = override_map.iterator();
    while (it2.next()) |entry| {
        if (out.getPtr(entry.key_ptr.*)) |existing| {
            if (existing.data == .map and entry.value_ptr.data == .map) {
                const merged = try mergeNodes(alloc, existing.*, entry.value_ptr.*);
                existing.* = merged;
                continue;
            }
        }
        try out.put(alloc, entry.key_ptr.*, entry.value_ptr.*);
    }
    return .{ .line = override.line, .col = override.col, .data = .{ .map = out } };
}

fn resolveExtends(
    alloc: std.mem.Allocator,
    id: []const u8,
    node: yaml.Node,
    root_map: yaml.Map,
    templates: std.StringArrayHashMapUnmanaged(yaml.Node),
    visiting: *std.StringArrayHashMapUnmanaged(void),
    diags: *yaml.Diags,
) !yaml.Node {
    const extends_node = node.get("extends") orelse return node;
    var names: std.ArrayList([]const u8) = .empty;
    switch (extends_node.data) {
        .scalar => |value| try names.append(alloc, value),
        .seq => |items| for (items) |item| switch (item.data) {
            .scalar => |value| try names.append(alloc, value),
            else => {
                try diags.add(extends_node.line, extends_node.col, "'extends' must be a name or list of names", .{});
                return node;
            },
        },
        .map => {
            try diags.add(extends_node.line, extends_node.col, "'extends' must be a name or list of names", .{});
            return node;
        },
    }
    var merged: ?yaml.Node = null;
    for (names.items) |name| {
        if (visiting.contains(name)) {
            try diags.add(extends_node.line, extends_node.col, "circular 'extends' chain involving '{s}'", .{name});
            continue;
        }
        const target = templates.get(name) orelse root_map.get(name) orelse {
            try diags.add(extends_node.line, extends_node.col, "job '{s}' extends unknown job '{s}'", .{ id, name });
            continue;
        };
        try visiting.put(alloc, name, {});
        const resolved_target = try resolveExtends(alloc, name, target, root_map, templates, visiting, diags);
        _ = visiting.swapRemove(name);
        merged = if (merged) |m| try mergeNodes(alloc, m, resolved_target) else resolved_target;
    }
    const base = merged orelse return node;
    return try mergeNodes(alloc, base, node);
}

fn lowerJob(
    alloc: std.mem.Allocator,
    id: []const u8,
    node: yaml.Node,
    root_env: []const ir.EnvPair,
    defaults: Defaults,
    diags: *yaml.Diags,
) !?BaseJob {
    const stage = if (node.get("stage")) |stage_node| stage_node.scalarOr("") else "test";
    const script_node = node.get("script") orelse {
        try diags.add(node.line, node.col, "job '{s}' has no script", .{id});
        return .{ .job = .{ .id = id, .display_name = id, .steps = &.{}, .src_line = node.line }, .stage = "test", .explicit_needs = false, .combos = &.{} };
    };
    const script_lines = try scripts(alloc, script_node, "script", diags);
    if (script_lines.len == 0) try diags.add(script_node.line, script_node.col, "job '{s}' has an empty script", .{id});
    const before = if (node.get("before_script")) |local| try scripts(alloc, local, "before_script", diags) else defaults.before_script orelse &.{};
    var commands: std.ArrayList([]const u8) = .empty;
    try commands.appendSlice(alloc, before);
    try commands.appendSlice(alloc, script_lines);

    const job_vars = try envPairs(alloc, node.get("variables"), diags);
    const predefined = &[_]ir.EnvPair{
        .{ .name = "CI", .value = "true" },
        .{ .name = "GITLAB_CI", .value = "true" },
        .{ .name = "CI_PIPELINE_SOURCE", .value = "push" },
        .{ .name = "CI_JOB_NAME", .value = id },
        .{ .name = "CI_JOB_STAGE", .value = stage },
    };
    const rule_vars = try buildRuleVars(alloc, predefined, root_env, job_vars);

    var manual = false;
    var allow_failure_override: ?bool = null;
    var rule_extra_vars: []ir.EnvPair = &.{};

    if (node.get("rules")) |rules_node| {
        if (node.get("when")) |_| try warn(diags, node, "'when' is ignored when 'rules' is present", .{});
        const outcome = try evalRuleList(alloc, rules_node, rule_vars, diags);
        switch (outcome) {
            .malformed => {},
            .no_match => {
                try warn(diags, node, "job '{s}' excluded by rules (no rule matched)", .{id});
                return null;
            },
            .matched => |m| {
                if (std.mem.eql(u8, m.when, "never")) {
                    try warn(diags, node, "job '{s}' excluded by rules", .{id});
                    return null;
                } else if (std.mem.eql(u8, m.when, "manual")) {
                    manual = true;
                } else if (std.mem.eql(u8, m.when, "delayed")) {
                    try warn(diags, node, "delayed jobs run immediately in local simulation", .{});
                } else if (std.mem.eql(u8, m.when, "always")) {
                    try warn(diags, node, "when: always is treated as on_success locally", .{});
                }
                rule_extra_vars = m.variables;
                allow_failure_override = m.allow_failure;
            },
        }
    } else if (node.get("when")) |when_node| {
        const w = when_node.scalarOr("");
        if (std.mem.eql(u8, w, "never")) {
            try warn(diags, node, "job '{s}' excluded by when: never", .{id});
            return null;
        } else if (std.mem.eql(u8, w, "manual")) {
            manual = true;
        } else if (std.mem.eql(u8, w, "always")) {
            try warn(diags, node, "when: always is treated as on_success locally", .{});
        } else if (std.mem.eql(u8, w, "delayed")) {
            try warn(diags, node, "delayed jobs run immediately in local simulation", .{});
        } else if (!std.mem.eql(u8, w, "on_success")) {
            try diags.add(when_node.line, when_node.col, "invalid 'when' value '{s}'", .{w});
        }
    }

    var env: std.ArrayList(ir.EnvPair) = .empty;
    try env.appendSlice(alloc, root_env);
    try env.appendSlice(alloc, job_vars);
    try env.appendSlice(alloc, rule_extra_vars);
    try env.appendSlice(alloc, &.{
        .{ .name = "GITLAB_CI", .value = "true" },
        .{ .name = "CI_JOB_NAME", .value = id },
        .{ .name = "CI_JOB_STAGE", .value = stage },
    });

    var allow_failure = if (node.get("allow_failure")) |allow| switch (allow.data) {
        .scalar => |value| std.ascii.eqlIgnoreCase(value, "true"),
        else => blk: {
            try warn(diags, allow, "allow_failure forms other than boolean are not simulated (ignored)", .{});
            break :blk false;
        },
    } else false;
    if (allow_failure_override) |v| allow_failure = v;
    if (node.get("needs")) |needs| try warn(diags, needs, "needs artifact transfer is not simulated", .{});
    try checkJobKeys(node, diags);

    const after_script_node = node.get("after_script");
    const after: ?[]const []const u8 = if (after_script_node) |local| try scripts(alloc, local, "after_script", diags) else defaults.after_script;

    var steps_list: std.ArrayList(ir.Step) = .empty;
    try steps_list.append(alloc, .{
        .id = "script",
        .name = "script",
        .kind = .run,
        .script = try std.mem.join(alloc, "\n", commands.items),
        .continue_on_error = allow_failure,
        .src_line = script_node.line,
    });
    if (after) |lines| if (lines.len > 0) {
        const after_src_line = if (after_script_node) |n| n.line else node.line;
        try steps_list.append(alloc, .{
            .id = "after_script",
            .name = "after_script",
            .kind = .run,
            .script = try std.mem.join(alloc, "\n", lines),
            .cond = "always()",
            .continue_on_error = true,
            .src_line = after_src_line,
        });
    };
    const steps = try steps_list.toOwnedSlice(alloc);

    const image_node = node.get("image") orelse defaults.image;
    const services_node = node.get("services") orelse defaults.services;
    return .{
        .job = .{
            .id = id,
            .display_name = id,
            .needs = if (node.get("needs")) |needs| try needsList(alloc, needs, diags) else &.{},
            .env = try env.toOwnedSlice(alloc),
            .steps = steps,
            .src_line = node.line,
            .container_image = try imageName(image_node, diags),
            .services = try lowerServices(alloc, services_node, diags),
            .provider = .gitlab,
            .manual = manual,
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

fn stripKey(alloc: std.mem.Allocator, node: yaml.Node, key: []const u8) !yaml.Node {
    const m = switch (node.data) {
        .map => |value| value,
        else => return node,
    };
    var out: yaml.Map = .empty;
    var it = m.iterator();
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry.key_ptr.*, key)) continue;
        try out.put(alloc, entry.key_ptr.*, entry.value_ptr.*);
    }
    return .{ .line = node.line, .col = node.col, .data = .{ .map = out } };
}

fn resolveIncludePath(entry: yaml.Node, diags: *yaml.Diags) !?[]const u8 {
    switch (entry.data) {
        .scalar => |s| return s,
        .map => |m| {
            var it = m.iterator();
            while (it.next()) |kv| {
                if (contains(&include_unsupported_types, kv.key_ptr.*)) {
                    try warn(diags, entry, "include type '{s}' is not supported locally (ignored)", .{kv.key_ptr.*});
                    return null;
                }
            }
            const local_node = m.get("local") orelse {
                try diags.add(entry.line, entry.col, "'include' must be a path, mapping, or list", .{});
                return null;
            };
            var it2 = m.iterator();
            while (it2.next()) |kv| {
                if (!std.mem.eql(u8, kv.key_ptr.*, "local"))
                    try warn(diags, kv.value_ptr.*, "include key '{s}' is not simulated (ignored)", .{kv.key_ptr.*});
            }
            return local_node.scalarOr("");
        },
        .seq => {
            try diags.add(entry.line, entry.col, "'include' must be a path, mapping, or list", .{});
            return null;
        },
    }
}

fn expandIncludes(
    alloc: std.mem.Allocator,
    source_path: []const u8,
    root: yaml.Node,
    visited: *std.StringArrayHashMapUnmanaged(void),
    depth: u32,
    diags: *yaml.Diags,
) ParseError!yaml.Node {
    const root_map = switch (root.data) {
        .map => |m| m,
        else => return root,
    };
    const include_node = root_map.get("include") orelse return root;
    if (depth >= 32) {
        try diags.add(include_node.line, include_node.col, "include nesting too deep", .{});
        return root;
    }
    const dir = std.fs.path.dirname(source_path) orelse ".";
    var entries: std.ArrayList(yaml.Node) = .empty;
    switch (include_node.data) {
        .scalar, .map => try entries.append(alloc, include_node),
        .seq => |items| try entries.appendSlice(alloc, items),
    }
    var merged: ?yaml.Node = null;
    for (entries.items) |entry| {
        const rel_path = try resolveIncludePath(entry, diags) orelse continue;
        if (std.mem.indexOfScalar(u8, rel_path, '*') != null) {
            try warn(diags, entry, "wildcard includes are not supported (ignored)", .{});
            continue;
        }
        const stripped_path = if (rel_path.len > 0 and rel_path[0] == '/') rel_path[1..] else rel_path;
        const full_path = try std.fs.path.join(alloc, &.{ dir, stripped_path });
        const canonical = std.fs.path.resolve(alloc, &.{full_path}) catch full_path;
        if (visited.contains(canonical)) {
            try warn(diags, entry, "include '{s}' already processed (skipped)", .{rel_path});
            continue;
        }
        try visited.put(alloc, canonical, {});
        const text = std.fs.cwd().readFileAlloc(alloc, full_path, 4 * 1024 * 1024) catch {
            try diags.add(entry.line, entry.col, "cannot read include '{s}'", .{rel_path});
            continue;
        };
        var sub_diags = yaml.Diags.init(alloc);
        const sub_root = yaml.parse(alloc, text, &sub_diags) catch |err| {
            for (sub_diags.list.items) |d| try diags.add(d.line, d.col, "{s}: {s}", .{ rel_path, d.msg });
            return switch (err) {
                error.ParseFailed => error.ParseFailed,
                error.OutOfMemory => error.OutOfMemory,
            };
        };
        for (sub_diags.list.items) |d| try diags.add(d.line, d.col, "{s}: {s}", .{ rel_path, d.msg });
        const expanded_sub = try expandIncludes(alloc, full_path, sub_root, visited, depth + 1, diags);
        merged = if (merged) |m| try mergeNodes(alloc, m, expanded_sub) else expanded_sub;
    }
    const stripped_root = try stripKey(alloc, root, "include");
    return if (merged) |m| try mergeNodes(alloc, m, stripped_root) else stripped_root;
}

pub fn parsePipeline(alloc: std.mem.Allocator, source_path: []const u8, source: []const u8, diags: *yaml.Diags) ParseError!ir.Pipeline {
    const parsed_root = yaml.parse(alloc, source, diags) catch |err| return switch (err) {
        error.ParseFailed => error.ParseFailed,
        error.OutOfMemory => error.OutOfMemory,
    };
    switch (parsed_root.data) {
        .map => {},
        else => {
            try diags.add(parsed_root.line, parsed_root.col, "GitLab pipeline must be a mapping", .{});
            return error.ParseFailed;
        },
    }
    var visited_includes: std.StringArrayHashMapUnmanaged(void) = .empty;
    const main_canonical = std.fs.path.resolve(alloc, &.{source_path}) catch source_path;
    try visited_includes.put(alloc, main_canonical, {});
    const root = try expandIncludes(alloc, source_path, parsed_root, &visited_includes, 0, diags);
    const root_map = switch (root.data) {
        .map => |value| value,
        else => {
            try diags.add(root.line, root.col, "GitLab pipeline must be a mapping", .{});
            return error.ParseFailed;
        },
    };
    const stages = if (root.get("stages")) |node| try stringList(alloc, node, "stages", diags) else try alloc.dupe([]const u8, &default_stages);
    if (stages.len == 0) try diags.add(root.line, root.col, "'stages' must not be empty", .{});
    var root_env: []ir.EnvPair = try envPairs(alloc, root.get("variables"), diags);

    if (root.get("workflow")) |workflow_node| switch (workflow_node.data) {
        .map => {
            var wit = workflow_node.data.map.iterator();
            while (wit.next()) |entry| {
                if (!std.mem.eql(u8, entry.key_ptr.*, "rules"))
                    try warn(diags, entry.value_ptr.*, "workflow key '{s}' is not simulated (ignored)", .{entry.key_ptr.*});
            }
            if (workflow_node.get("rules")) |rules_node| {
                const wf_predefined = &[_]ir.EnvPair{
                    .{ .name = "CI", .value = "true" },
                    .{ .name = "GITLAB_CI", .value = "true" },
                    .{ .name = "CI_PIPELINE_SOURCE", .value = "push" },
                };
                const wf_vars = try buildRuleVars(alloc, wf_predefined, root_env, &.{});
                const outcome = try evalRuleList(alloc, rules_node, wf_vars, diags);
                switch (outcome) {
                    .malformed => {},
                    .no_match => try warn(diags, workflow_node, "no workflow rule matched — GitLab would skip this pipeline (running anyway)", .{}),
                    .matched => |m| {
                        if (std.mem.eql(u8, m.when, "never"))
                            try warn(diags, workflow_node, "workflow rules would skip this pipeline on GitLab (running anyway)", .{});
                        if (m.variables.len > 0) {
                            var combined: std.ArrayList(ir.EnvPair) = .empty;
                            try combined.appendSlice(alloc, root_env);
                            try combined.appendSlice(alloc, m.variables);
                            root_env = try combined.toOwnedSlice(alloc);
                        }
                    },
                }
            }
        },
        else => try diags.add(workflow_node.line, workflow_node.col, "'workflow' must be a mapping", .{}),
    };

    var defaults = Defaults{};
    if (root.get("default")) |def_node| switch (def_node.data) {
        .map => |m| {
            var dit = m.iterator();
            while (dit.next()) |entry| {
                const key = entry.key_ptr.*;
                if (std.mem.eql(u8, key, "image")) {
                    defaults.image = entry.value_ptr.*;
                } else if (std.mem.eql(u8, key, "services")) {
                    defaults.services = entry.value_ptr.*;
                } else if (std.mem.eql(u8, key, "before_script")) {
                    defaults.before_script = try scripts(alloc, entry.value_ptr.*, "before_script", diags);
                } else if (std.mem.eql(u8, key, "after_script")) {
                    defaults.after_script = try scripts(alloc, entry.value_ptr.*, "after_script", diags);
                } else {
                    try warn(diags, entry.value_ptr.*, "default key '{s}' is not simulated (ignored)", .{key});
                }
            }
        },
        else => try diags.add(def_node.line, def_node.col, "'default' must be a mapping", .{}),
    };
    if (defaults.image == null) if (root.get("image")) |node| {
        defaults.image = node;
    };
    if (defaults.services == null) if (root.get("services")) |node| {
        defaults.services = node;
    };
    if (root.get("before_script")) |node| defaults.before_script = try scripts(alloc, node, "before_script", diags);
    if (defaults.after_script == null) if (root.get("after_script")) |node| {
        defaults.after_script = try scripts(alloc, node, "after_script", diags);
    };

    for (root_keys) |key| if (root.get(key)) |node| {
        if (contains(&unsafe_root_keys, key))
            try diags.add(node.line, node.col, "global key '{s}' affects execution and is not supported", .{key})
        else if (!contains(&.{ "stages", "variables", "before_script", "after_script", "default", "image", "services", "workflow" }, key))
            try warn(diags, node, "global key '{s}' is not simulated (ignored)", .{key});
    };

    var templates: std.StringArrayHashMapUnmanaged(yaml.Node) = .empty;
    var tmpl_it = root_map.iterator();
    while (tmpl_it.next()) |entry| {
        const id = entry.key_ptr.*;
        if (contains(&root_keys, id)) continue;
        if (std.mem.startsWith(u8, id, ".")) try templates.put(alloc, id, entry.value_ptr.*);
    }

    var bases: std.ArrayList(BaseJob) = .empty;
    var it = root_map.iterator();
    while (it.next()) |entry| {
        const id = entry.key_ptr.*;
        if (contains(&root_keys, id)) continue;
        if (std.mem.startsWith(u8, id, ".")) continue;
        switch (entry.value_ptr.data) {
            .map => {
                var visiting: std.StringArrayHashMapUnmanaged(void) = .empty;
                const effective = try resolveExtends(alloc, id, entry.value_ptr.*, root_map, templates, &visiting, diags);
                if (try lowerJob(alloc, id, effective, root_env, defaults, diags)) |base| {
                    try bases.append(alloc, base);
                }
            },
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

test "'include' at root is still a hard diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\include:
        \\  - local: other.yml
        \\job:
        \\  script: echo ok
    ;
    try std.testing.expectError(error.ParseFailed, parsePipeline(a, ".gitlab-ci.yml", source, &diags));
    var found_include = false;
    for (diags.list.items) |diag| {
        if (std.mem.indexOf(u8, diag.msg, "include") != null and !std.mem.startsWith(u8, diag.msg, "warning: "))
            found_include = true;
    }
    try std.testing.expect(found_include);
}

test "extends merges template into job; job variables override on collision" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\.base:
        \\  image: node:18
        \\  variables:
        \\    SHARED: base
        \\    ONLY_BASE: keep
        \\job:
        \\  extends: .base
        \\  variables:
        \\    SHARED: job
        \\  script: echo hi
    ;
    const pipeline = try parsePipeline(a, ".gitlab-ci.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 1), pipeline.jobs.len);
    try std.testing.expectEqualStrings("node:18", pipeline.jobs[0].container_image);
    var shared: ?[]const u8 = null;
    var only_base: ?[]const u8 = null;
    for (pipeline.jobs[0].env) |e| {
        if (std.mem.eql(u8, e.name, "SHARED")) shared = e.value;
        if (std.mem.eql(u8, e.name, "ONLY_BASE")) only_base = e.value;
    }
    try std.testing.expectEqualStrings("job", shared.?);
    try std.testing.expectEqualStrings("keep", only_base.?);
}

test "extends list applies templates in order so later entries win" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\.a:
        \\  image: image-a
        \\.b:
        \\  image: image-b
        \\job:
        \\  extends: [.a, .b]
        \\  script: echo hi
    ;
    const pipeline = try parsePipeline(a, ".gitlab-ci.yml", source, &diags);
    try std.testing.expectEqualStrings("image-b", pipeline.jobs[0].container_image);
}

test "extends unknown target is a hard diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\job:
        \\  extends: .missing
        \\  script: echo hi
    ;
    try std.testing.expectError(error.ParseFailed, parsePipeline(a, ".gitlab-ci.yml", source, &diags));
    var found = false;
    for (diags.list.items) |diag| if (std.mem.indexOf(u8, diag.msg, "extends unknown job '.missing'") != null) {
        found = true;
    };
    try std.testing.expect(found);
}

test "circular extends chain is a hard diagnostic without crashing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\.a:
        \\  extends: .b
        \\  script: echo a
        \\.b:
        \\  extends: .a
        \\  script: echo b
        \\job:
        \\  extends: .a
        \\  script: echo job
    ;
    try std.testing.expectError(error.ParseFailed, parsePipeline(a, ".gitlab-ci.yml", source, &diags));
    var found = false;
    for (diags.list.items) |diag| if (std.mem.indexOf(u8, diag.msg, "circular 'extends' chain") != null) {
        found = true;
    };
    try std.testing.expect(found);
}

test "hidden template produces no job and emits no diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\.template:
        \\  image: node:18
        \\job:
        \\  script: echo hi
    ;
    const pipeline = try parsePipeline(a, ".gitlab-ci.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 1), pipeline.jobs.len);
    try std.testing.expectEqual(@as(usize, 0), diags.list.items.len);
}

test "default image and before_script are inherited; job image overrides default" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\default:
        \\  image: node:18
        \\  before_script:
        \\    - echo default-before
        \\a:
        \\  script: echo a
        \\b:
        \\  image: node:20
        \\  script: echo b
    ;
    const pipeline = try parsePipeline(a, ".gitlab-ci.yml", source, &diags);
    try std.testing.expectEqualStrings("node:18", pipeline.jobs[0].container_image);
    try std.testing.expectEqualStrings("echo default-before\necho a", pipeline.jobs[0].steps[0].script);
    try std.testing.expectEqualStrings("node:20", pipeline.jobs[1].container_image);
}

test "legacy root image is a default fallback; default.image takes precedence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\image: legacy:1
        \\a:
        \\  script: echo a
    ;
    const pipeline = try parsePipeline(a, ".gitlab-ci.yml", source, &diags);
    try std.testing.expectEqualStrings("legacy:1", pipeline.jobs[0].container_image);

    var diags2 = yaml.Diags.init(a);
    const source2 =
        \\image: legacy:1
        \\default:
        \\  image: preferred:1
        \\a:
        \\  script: echo a
    ;
    const pipeline2 = try parsePipeline(a, ".gitlab-ci.yml", source2, &diags2);
    try std.testing.expectEqualStrings("preferred:1", pipeline2.jobs[0].container_image);
}

test "after_script lowers to a second always() step; root after_script is inherited" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\a:
        \\  script: echo a
        \\  after_script:
        \\    - echo cleanup-a
        \\b:
        \\  script: echo b
    ;
    const pipeline = try parsePipeline(a, ".gitlab-ci.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 2), pipeline.jobs[0].steps.len);
    try std.testing.expectEqualStrings("always()", pipeline.jobs[0].steps[1].cond.?);
    try std.testing.expect(pipeline.jobs[0].steps[1].continue_on_error);
    try std.testing.expectEqual(@as(usize, 1), pipeline.jobs[1].steps.len);

    var diags2 = yaml.Diags.init(a);
    const source2 =
        \\after_script:
        \\  - echo root-cleanup
        \\a:
        \\  script: echo a
    ;
    const pipeline2 = try parsePipeline(a, ".gitlab-ci.yml", source2, &diags2);
    try std.testing.expectEqual(@as(usize, 2), pipeline2.jobs[0].steps.len);
    try std.testing.expectEqualStrings("echo root-cleanup", pipeline2.jobs[0].steps[1].script);
}

fn findEnv(env: []const ir.EnvPair, name: []const u8) ?[]const u8 {
    for (env) |e| if (std.mem.eql(u8, e.name, name)) return e.value;
    return null;
}

fn anyDiagContains(diags: *const yaml.Diags, needle: []const u8) bool {
    for (diags.list.items) |d| if (std.mem.indexOf(u8, d.msg, needle) != null) return true;
    return false;
}

test "rule if evaluator: equality, inequality, and/or, parens, truthiness, null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const node = yaml.Node{ .line = 1, .col = 1, .data = .{ .scalar = "" } };
    const vars = [_]ir.EnvPair{ .{ .name = "V", .value = "x" }, .{ .name = "EMPTY", .value = "" } };
    const rv = RuleVars{ .pairs = &vars };

    try std.testing.expect(try evalRuleIf(a, "$V == \"x\"", rv, node, &diags));
    try std.testing.expect(!(try evalRuleIf(a, "$V == \"y\"", rv, node, &diags)));
    try std.testing.expect(try evalRuleIf(a, "$V != \"y\"", rv, node, &diags));
    try std.testing.expect(try evalRuleIf(a, "$V == 'x'", rv, node, &diags));
    try std.testing.expect(try evalRuleIf(a, "$V", rv, node, &diags));
    try std.testing.expect(!(try evalRuleIf(a, "$EMPTY", rv, node, &diags)));
    try std.testing.expect(!(try evalRuleIf(a, "$MISSING", rv, node, &diags)));
    try std.testing.expect(try evalRuleIf(a, "$MISSING == null", rv, node, &diags));
    try std.testing.expect(try evalRuleIf(a, "$V == \"x\" && $EMPTY == \"\"", rv, node, &diags));
    try std.testing.expect(try evalRuleIf(a, "$V == \"y\" || $V == \"x\"", rv, node, &diags));
    try std.testing.expect(try evalRuleIf(a, "($V == \"y\" || $V == \"x\") && $EMPTY == \"\"", rv, node, &diags));
}

test "rule if evaluator: regex ops warn once and match; garbage expression warns and matches" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const node = yaml.Node{ .line = 1, .col = 1, .data = .{ .scalar = "" } };
    const vars = [_]ir.EnvPair{.{ .name = "V", .value = "x" }};
    const rv = RuleVars{ .pairs = &vars };

    const before = diags.list.items.len;
    try std.testing.expect(try evalRuleIf(a, "$V =~ /x/", rv, node, &diags));
    try std.testing.expect(diags.list.items.len > before);

    var diags2 = yaml.Diags.init(a);
    try std.testing.expect(try evalRuleIf(a, "$V !~ /y/", rv, node, &diags2));
    try std.testing.expect(diags2.list.items.len > 0);

    var diags3 = yaml.Diags.init(a);
    try std.testing.expect(try evalRuleIf(a, "$V ===", rv, node, &diags3));
    try std.testing.expect(diags3.list.items.len > 0);
}

test "job rules: first matching rule wins; later rules are not evaluated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\job:
        \\  script: echo ok
        \\  rules:
        \\    - if: '$CI == "true"'
        \\      when: on_success
        \\    - when: never
    ;
    const pipeline = try parsePipeline(a, ".gitlab-ci.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 1), pipeline.jobs.len);
}

test "job rules: no rule matches excludes the job with a warning" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\a:
        \\  script: echo a
        \\  rules:
        \\    - if: '$MISSING == "x"'
        \\b:
        \\  script: echo b
    ;
    const pipeline = try parsePipeline(a, ".gitlab-ci.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 1), pipeline.jobs.len);
    try std.testing.expectEqualStrings("b", pipeline.jobs[0].id);
    try std.testing.expect(anyDiagContains(&diags, "no rule matched"));
}

test "job rules: when: never in the matched rule excludes the job" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\a:
        \\  script: echo a
        \\  rules:
        \\    - when: never
        \\b:
        \\  script: echo b
    ;
    const pipeline = try parsePipeline(a, ".gitlab-ci.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 1), pipeline.jobs.len);
    try std.testing.expectEqualStrings("b", pipeline.jobs[0].id);
    try std.testing.expect(anyDiagContains(&diags, "excluded by rules"));
}

test "job rules: matched rule variables land in env and allow_failure override applies" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\job:
        \\  script: echo hi
        \\  variables:
        \\    BASE: v
        \\  allow_failure: false
        \\  rules:
        \\    - if: '$BASE == "v"'
        \\      when: on_success
        \\      variables:
        \\        EXTRA: yes
        \\      allow_failure: true
    ;
    const pipeline = try parsePipeline(a, ".gitlab-ci.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 1), pipeline.jobs.len);
    try std.testing.expectEqualStrings("yes", findEnv(pipeline.jobs[0].env, "EXTRA").?);
    try std.testing.expect(pipeline.jobs[0].steps[0].continue_on_error);
}

test "job rules: changes clause warns and is treated as matching" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\job:
        \\  script: echo hi
        \\  rules:
        \\    - changes: [file.txt]
    ;
    const pipeline = try parsePipeline(a, ".gitlab-ci.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 1), pipeline.jobs.len);
    try std.testing.expect(anyDiagContains(&diags, "not evaluated locally"));
}

test "top-level when: never excludes a job; when: manual sets Job.manual" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\a:
        \\  script: echo a
        \\  when: never
        \\b:
        \\  script: echo b
        \\  when: manual
    ;
    const pipeline = try parsePipeline(a, ".gitlab-ci.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 1), pipeline.jobs.len);
    try std.testing.expectEqualStrings("b", pipeline.jobs[0].id);
    try std.testing.expect(pipeline.jobs[0].manual);
}

test "rules and top-level when together: rules wins and when is ignored (warn)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\job:
        \\  script: echo hi
        \\  when: manual
        \\  rules:
        \\    - when: on_success
    ;
    const pipeline = try parsePipeline(a, ".gitlab-ci.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 1), pipeline.jobs.len);
    try std.testing.expect(!pipeline.jobs[0].manual);
    try std.testing.expect(anyDiagContains(&diags, "'when' is ignored when 'rules' is present"));
}

test "workflow when: never warns but jobs still lower" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\workflow:
        \\  rules:
        \\    - when: never
        \\job:
        \\  script: echo hi
    ;
    const pipeline = try parsePipeline(a, ".gitlab-ci.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 1), pipeline.jobs.len);
    try std.testing.expect(anyDiagContains(&diags, "workflow rules would skip this pipeline"));
}

test "workflow rule variables land in job env" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\workflow:
        \\  rules:
        \\    - if: '$CI == "true"'
        \\      variables:
        \\        WF: yes
        \\job:
        \\  script: echo hi
    ;
    const pipeline = try parsePipeline(a, ".gitlab-ci.yml", source, &diags);
    try std.testing.expectEqualStrings("yes", findEnv(pipeline.jobs[0].env, "WF").?);
}

test "workflow no rule matched warns but jobs still lower" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\workflow:
        \\  rules:
        \\    - if: '$MISSING == "x"'
        \\job:
        \\  script: echo hi
    ;
    const pipeline = try parsePipeline(a, ".gitlab-ci.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 1), pipeline.jobs.len);
    try std.testing.expect(anyDiagContains(&diags, "no workflow rule matched"));
}

test "only and except are recognized but not simulated; job stays" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\job:
        \\  script: echo hi
        \\  only:
        \\    - main
        \\  except:
        \\    - develop
    ;
    const pipeline = try parsePipeline(a, ".gitlab-ci.yml", source, &diags);
    try std.testing.expectEqual(@as(usize, 1), pipeline.jobs.len);
    try std.testing.expect(anyDiagContains(&diags, "'only' is recognized but not simulated"));
    try std.testing.expect(anyDiagContains(&diags, "'except' is recognized but not simulated"));
    for (diags.list.items) |diag| try std.testing.expect(std.mem.startsWith(u8, diag.msg, "warning: "));
}

test "include: scalar shorthand loads jobs from a local file" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "other.yml", .data = "a:\n  script: echo a\n" });
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    const main_path = try std.fs.path.join(a, &.{ dir_path, "main.yml" });
    var diags = yaml.Diags.init(a);
    const source =
        \\include: other.yml
        \\b:
        \\  script: echo b
    ;
    const pipeline = try parsePipeline(a, main_path, source, &diags);
    try std.testing.expectEqual(@as(usize, 2), pipeline.jobs.len);
    var found_a = false;
    var found_b = false;
    for (pipeline.jobs) |job| {
        if (std.mem.eql(u8, job.id, "a")) found_a = true;
        if (std.mem.eql(u8, job.id, "b")) found_b = true;
    }
    try std.testing.expect(found_a and found_b);
}

test "include: {local:} map form works; unsupported type map warns and is ignored" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "other.yml", .data = "a:\n  script: echo a\n" });
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    const main_path = try std.fs.path.join(a, &.{ dir_path, "main.yml" });
    var diags = yaml.Diags.init(a);
    const source =
        \\include:
        \\  - local: other.yml
        \\  - template: Some/Template.yml
        \\b:
        \\  script: echo b
    ;
    const pipeline = try parsePipeline(a, main_path, source, &diags);
    try std.testing.expectEqual(@as(usize, 2), pipeline.jobs.len);
    try std.testing.expect(anyDiagContains(&diags, "include type 'template' is not supported locally"));
}

test "include: main job wins on collision; include-only keys survive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "other.yml", .data =
        \\x:
        \\  stage: build
        \\  variables:
        \\    A: "1"
        \\  script: echo included
    });
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    const main_path = try std.fs.path.join(a, &.{ dir_path, "main.yml" });
    var diags = yaml.Diags.init(a);
    const source =
        \\stages: [build, test]
        \\include: other.yml
        \\x:
        \\  stage: test
        \\  script: echo main
    ;
    const pipeline = try parsePipeline(a, main_path, source, &diags);
    try std.testing.expectEqual(@as(usize, 1), pipeline.jobs.len);
    try std.testing.expectEqualStrings("test", findEnv(pipeline.jobs[0].env, "CI_JOB_STAGE").?);
    try std.testing.expectEqualStrings("echo main", pipeline.jobs[0].steps[0].script);
    try std.testing.expectEqualStrings("1", findEnv(pipeline.jobs[0].env, "A").?);
}

test "include: nested includes are expanded depth-first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "c.yml", .data = "c_job:\n  script: echo c\n" });
    try tmp.dir.writeFile(.{ .sub_path = "b.yml", .data = "include: c.yml\nb_job:\n  script: echo b\n" });
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    const main_path = try std.fs.path.join(a, &.{ dir_path, "main.yml" });
    var diags = yaml.Diags.init(a);
    const source =
        \\include: b.yml
        \\a_job:
        \\  script: echo a
    ;
    const pipeline = try parsePipeline(a, main_path, source, &diags);
    try std.testing.expectEqual(@as(usize, 3), pipeline.jobs.len);
    var found_c = false;
    for (pipeline.jobs) |job| if (std.mem.eql(u8, job.id, "c_job")) {
        found_c = true;
    };
    try std.testing.expect(found_c);
}

test "include: cycle between two files is deduped without hanging" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "a.yml", .data = "include: b.yml\na_job:\n  script: echo a\n" });
    try tmp.dir.writeFile(.{ .sub_path = "b.yml", .data = "include: a.yml\nb_job:\n  script: echo b\n" });
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    const main_path = try std.fs.path.join(a, &.{ dir_path, "a.yml" });
    const source = try tmp.dir.readFileAlloc(a, "a.yml", 4096);
    var diags = yaml.Diags.init(a);
    const pipeline = try parsePipeline(a, main_path, source, &diags);
    try std.testing.expect(anyDiagContains(&diags, "already processed"));
    var count_a: usize = 0;
    var count_b: usize = 0;
    for (pipeline.jobs) |job| {
        if (std.mem.eql(u8, job.id, "a_job")) count_a += 1;
        if (std.mem.eql(u8, job.id, "b_job")) count_b += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), count_a);
    try std.testing.expectEqual(@as(usize, 1), count_b);
}

test "include: missing file is a hard diagnostic; rest of pipeline still evaluated" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    const main_path = try std.fs.path.join(a, &.{ dir_path, "main.yml" });
    var diags = yaml.Diags.init(a);
    const source =
        \\include: missing.yml
        \\b:
        \\  script: echo b
    ;
    try std.testing.expectError(error.ParseFailed, parsePipeline(a, main_path, source, &diags));
    try std.testing.expect(anyDiagContains(&diags, "cannot read include"));
}

test "include: template defined in included file is usable via extends in main" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(.{ .sub_path = "templates.yml", .data = ".t:\n  image: node:18\n" });
    const dir_path = try tmp.dir.realpathAlloc(a, ".");
    const main_path = try std.fs.path.join(a, &.{ dir_path, "main.yml" });
    var diags = yaml.Diags.init(a);
    const source =
        \\include: templates.yml
        \\job:
        \\  extends: .t
        \\  script: echo hi
    ;
    const pipeline = try parsePipeline(a, main_path, source, &diags);
    try std.testing.expectEqual(@as(usize, 1), pipeline.jobs.len);
    try std.testing.expectEqualStrings("node:18", pipeline.jobs[0].container_image);
}
