//! Translation emitters: render an `ir.Pipeline` into provider config text.
//! Each target gets one `fn emitX(w: *Writer, p: ir.Pipeline) !void` so new
//! targets slot in without touching the shared infrastructure below.
const std = @import("std");
const ir = @import("ir.zig");

pub const Target = enum {
    gha,
    gitlab,
    jenkins,
    circleci,
    azure,
    bitbucket,

    pub fn fromName(name: []const u8) ?Target {
        if (std.mem.eql(u8, name, "gha") or std.mem.eql(u8, name, "github") or std.mem.eql(u8, name, "github-actions")) return .gha;
        if (std.mem.eql(u8, name, "gitlab")) return .gitlab;
        if (std.mem.eql(u8, name, "jenkins")) return .jenkins;
        if (std.mem.eql(u8, name, "circleci")) return .circleci;
        if (std.mem.eql(u8, name, "azure") or std.mem.eql(u8, name, "azure-pipelines")) return .azure;
        if (std.mem.eql(u8, name, "bitbucket")) return .bitbucket;
        return null;
    }
};

pub const EmitError = error{OutOfMemory};

pub fn emit(alloc: std.mem.Allocator, p: ir.Pipeline, target: Target) EmitError![]const u8 {
    var w = Writer{ .alloc = alloc };
    switch (target) {
        .gha => try emitGha(&w, p),
        .gitlab => try emitGitlab(&w, p),
        .jenkins => try emitJenkins(&w, p),
        .circleci => try emitCircleci(&w, p),
        .azure => try emitAzure(&w, p),
        .bitbucket => try emitBitbucket(&w, p),
    }
    return w.buf.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Shared infrastructure
// ---------------------------------------------------------------------------

/// Minimal indent-tracking text builder. Both the YAML targets (indent =
/// nesting) and the Jenkinsfile target (indent is cosmetic only, braces do
/// the real structuring) share this.
pub const Writer = struct {
    alloc: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    indent_level: u32 = 0,

    fn writeIndent(self: *Writer) !void {
        var i: u32 = 0;
        while (i < self.indent_level) : (i += 1) try self.buf.appendSlice(self.alloc, "  ");
    }

    /// Formatted, indented line with trailing newline.
    pub fn line(self: *Writer, comptime fmt: []const u8, args: anytype) !void {
        try self.writeIndent();
        try self.buf.appendSlice(self.alloc, try std.fmt.allocPrint(self.alloc, fmt, args));
        try self.buf.append(self.alloc, '\n');
    }

    /// Already-formatted, indented line with trailing newline (no format args).
    pub fn raw(self: *Writer, text: []const u8) !void {
        try self.writeIndent();
        try self.buf.appendSlice(self.alloc, text);
        try self.buf.append(self.alloc, '\n');
    }

    pub fn blank(self: *Writer) !void {
        try self.buf.append(self.alloc, '\n');
    }

    pub fn indentIn(self: *Writer) void {
        self.indent_level += 1;
    }

    pub fn indentOut(self: *Writer) void {
        self.indent_level -= 1;
    }
};

/// Groups job indices into dependency levels: level 0 = jobs with no needs;
/// level N = jobs whose needs all sit in levels < N with at least one in
/// N-1. IR DAGs are validated acyclic by the frontends; if an unexpected
/// cycle sneaks through, whatever is left over is dumped into one final
/// level instead of looping forever.
pub fn topoLevels(alloc: std.mem.Allocator, jobs: []const ir.Job) ![][]usize {
    var id_index: std.StringArrayHashMapUnmanaged(usize) = .empty;
    for (jobs, 0..) |j, i| try id_index.put(alloc, j.id, i);

    var level_of: []?usize = try alloc.alloc(?usize, jobs.len);
    @memset(level_of, null);

    var remaining: std.ArrayList(usize) = .empty;
    for (0..jobs.len) |i| try remaining.append(alloc, i);

    var levels: std.ArrayList([]usize) = .empty;

    while (remaining.items.len > 0) {
        var this_level: std.ArrayList(usize) = .empty;
        var next_remaining: std.ArrayList(usize) = .empty;
        for (remaining.items) |i| {
            var all_placed = true;
            for (jobs[i].needs) |need_id| {
                const need_idx = id_index.get(need_id) orelse continue;
                if (level_of[need_idx] == null) {
                    all_placed = false;
                    break;
                }
            }
            if (all_placed) {
                try this_level.append(alloc, i);
            } else {
                try next_remaining.append(alloc, i);
            }
        }
        if (this_level.items.len == 0) {
            // Cycle (or dangling need): stop making progress, dump the rest
            // into one final level rather than spinning forever.
            try levels.append(alloc, try remaining.toOwnedSlice(alloc));
            break;
        }
        const this_level_idx = levels.items.len;
        for (this_level.items) |i| level_of[i] = this_level_idx;
        try levels.append(alloc, try this_level.toOwnedSlice(alloc));
        remaining = next_remaining;
    }
    return levels.toOwnedSlice(alloc);
}

/// Plain iff every char is in `[A-Za-z0-9_./-]` and the string is non-empty;
/// otherwise quoted. Note: this repo's `yaml.zig` single-quote scalars do
/// NOT unescape doubled `''` (see `parseValueText`), so — unlike the usual
/// YAML convention — quoted output here uses double quotes with backslash
/// escaping, which `yaml.zig`'s `unescapeDouble` does handle correctly. This
/// is the one deviation from the literal "single-quoted, doubled" wording
/// discussed for this feature: it is required for genuine round-trip safety
/// against this repo's parser.
fn isPlainSafe(s: []const u8) bool {
    if (s.len == 0) return false;
    for (s) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '.' or c == '/' or c == '-')) return false;
    }
    return true;
}

fn quoteScalar(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (isPlainSafe(s)) return s;
    var out: std.ArrayList(u8) = .empty;
    try out.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => try out.append(alloc, c),
        }
    }
    try out.append(alloc, '"');
    return out.toOwnedSlice(alloc);
}

/// Emits a YAML block scalar (`key: |` + indented lines). Assumes `text`
/// has no blank lines (this repo's `yaml.zig` tokenizer drops blank source
/// lines entirely before block-scalar reassembly, so callers avoid them).
fn writeBlockScalar(w: *Writer, key: []const u8, text: []const u8) !void {
    try w.line("{s}: |", .{key});
    w.indentIn();
    defer w.indentOut();
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |ln| try w.line("{s}", .{ln});
}

fn writeNeedsList(w: *Writer, needs: []const []const u8, id_map: *const std.StringArrayHashMapUnmanaged([]const u8)) !void {
    const alloc = w.alloc;
    var parts: std.ArrayList(u8) = .empty;
    try parts.append(alloc, '[');
    for (needs, 0..) |n, i| {
        if (i > 0) try parts.appendSlice(alloc, ", ");
        const mapped = id_map.get(n) orelse n;
        try parts.appendSlice(alloc, try quoteScalar(alloc, mapped));
    }
    try parts.append(alloc, ']');
    try w.line("needs: {s}", .{try parts.toOwnedSlice(alloc)});
}

/// Names injected by the *source* frontend (GitLab/Jenkins/CircleCI/Azure/
/// Bitbucket predefined variables) rather than genuine user config — these
/// are dropped from translated `env`/`variables` blocks so the target
/// doesn't carry another provider's predefined-variable noise.
fn isPredefinedEnvName(name: []const u8) bool {
    const prefixes = [_][]const u8{ "CI_", "GITLAB_", "BITBUCKET_", "CIRCLE", "AGENT_" };
    for (prefixes) |p| if (std.mem.startsWith(u8, name, p)) return true;
    const exact = [_][]const u8{ "TF_BUILD", "BUILD_NUMBER", "JOB_NAME" };
    for (exact) |e| if (std.mem.eql(u8, name, e)) return true;
    return false;
}

/// Job env minus predefined-provider names and minus pairs that just
/// duplicate a matrix combo pair (name AND value match).
fn filteredEnv(alloc: std.mem.Allocator, job: ir.Job) ![]ir.EnvPair {
    var out: std.ArrayList(ir.EnvPair) = .empty;
    outer: for (job.env) |e| {
        if (isPredefinedEnvName(e.name)) continue;
        for (job.matrix) |m| {
            if (std.mem.eql(u8, m.name, e.name) and std.mem.eql(u8, m.value, e.value)) continue :outer;
        }
        try out.append(alloc, e);
    }
    return out.toOwnedSlice(alloc);
}

fn sanitizeGhaId(alloc: std.mem.Allocator, id: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (id) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '-';
        try out.append(alloc, if (ok) c else '-');
    }
    var result: []const u8 = try out.toOwnedSlice(alloc);
    if (result.len == 0) result = "job";
    if (!(std.ascii.isAlphabetic(result[0]) or result[0] == '_'))
        result = try std.fmt.allocPrint(alloc, "job-{s}", .{result});
    return result;
}

fn buildGhaIdMap(alloc: std.mem.Allocator, jobs: []const ir.Job) !std.StringArrayHashMapUnmanaged([]const u8) {
    var map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    for (jobs) |job| try map.put(alloc, job.id, try sanitizeGhaId(alloc, job.id));
    return map;
}

const gitlab_reserved_keys = [_][]const u8{
    "stages", "variables", "include", "workflow", "default",
    "image",  "services",  "cache",   "spec",     "before_script",
    "after_script",
};

fn sanitizeGitlabId(alloc: std.mem.Allocator, id: []const u8) ![]const u8 {
    for (gitlab_reserved_keys) |r| {
        if (std.mem.eql(u8, r, id)) return std.fmt.allocPrint(alloc, "{s}-job", .{id});
    }
    return id;
}

fn buildGitlabIdMap(alloc: std.mem.Allocator, jobs: []const ir.Job) !std.StringArrayHashMapUnmanaged([]const u8) {
    var map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    for (jobs) |job| try map.put(alloc, job.id, try sanitizeGitlabId(alloc, job.id));
    return map;
}

/// Escapes a value for a Groovy single-quoted (non-triple) string literal.
/// This repo's Jenkinsfile tokenizer processes `\\`, `\'`, `\"`, `\n`, `\t`
/// escapes for regular (non-triple) quoted strings, so those are the ones
/// worth emitting; anything else passes through raw.
fn groovyEscapeSingle(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        switch (c) {
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\'' => try out.appendSlice(alloc, "\\'"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            else => try out.append(alloc, c),
        }
    }
    return out.toOwnedSlice(alloc);
}

fn uniqueName(alloc: std.mem.Allocator, seen: *std.StringArrayHashMapUnmanaged(u32), name: []const u8) ![]const u8 {
    const gop = try seen.getOrPut(alloc, name);
    if (!gop.found_existing) {
        gop.value_ptr.* = 1;
        return name;
    }
    gop.value_ptr.* += 1;
    return std.fmt.allocPrint(alloc, "{s}-{d}", .{ name, gop.value_ptr.* });
}

// ---------------------------------------------------------------------------
// GitHub Actions
// ---------------------------------------------------------------------------

fn emitGha(w: *Writer, p: ir.Pipeline) !void {
    const alloc = w.alloc;
    try w.line("# jalan: translated from {s}", .{p.source_path});
    try w.line("name: {s}", .{try quoteScalar(alloc, p.name)});
    try w.blank();
    try w.raw("on: workflow_dispatch");
    try w.blank();
    try w.raw("jobs:");
    w.indentIn();

    var id_map = try buildGhaIdMap(alloc, p.jobs);

    for (p.jobs) |job| {
        const sid = id_map.get(job.id).?;
        try w.line("{s}:", .{sid});
        w.indentIn();
        if (!std.mem.eql(u8, job.display_name, job.id))
            try w.line("name: {s}", .{try quoteScalar(alloc, job.display_name)});
        const runs_on = if (job.runs_on.len > 0) job.runs_on else "ubuntu-latest";
        try w.line("runs-on: {s}", .{try quoteScalar(alloc, runs_on)});
        if (job.container_image.len > 0)
            try w.line("container: {s}", .{try quoteScalar(alloc, job.container_image)});
        if (job.services.len > 0) {
            try w.raw("services:");
            w.indentIn();
            for (job.services) |svc| {
                try w.line("{s}:", .{try quoteScalar(alloc, svc.name)});
                w.indentIn();
                try w.line("image: {s}", .{try quoteScalar(alloc, svc.image)});
                if (svc.env.len > 0) {
                    try w.raw("env:");
                    w.indentIn();
                    for (svc.env) |e| try w.line("{s}: {s}", .{ e.name, try quoteScalar(alloc, e.value) });
                    w.indentOut();
                }
                w.indentOut();
            }
            w.indentOut();
        }
        if (job.needs.len > 0) try writeNeedsList(w, job.needs, &id_map);
        const fenv = try filteredEnv(alloc, job);
        if (fenv.len > 0) {
            try w.raw("env:");
            w.indentIn();
            for (fenv) |e| try w.line("{s}: {s}", .{ e.name, try quoteScalar(alloc, e.value) });
            w.indentOut();
        }
        if (job.manual)
            try w.raw("# jalan: manual job in the source; runs like a normal job here");
        try w.raw("steps:");
        w.indentIn();
        for (job.steps) |step| try emitGhaStep(w, step);
        w.indentOut();
        w.indentOut();
    }
    w.indentOut();
}

fn emitGhaStep(w: *Writer, step: ir.Step) !void {
    const alloc = w.alloc;
    try w.line("- name: {s}", .{try quoteScalar(alloc, step.name)});
    w.indentIn();
    switch (step.kind) {
        .run => {
            if (std.mem.indexOfScalar(u8, step.script, '\n') != null) {
                try writeBlockScalar(w, "run", step.script);
            } else {
                try w.line("run: {s}", .{try quoteScalar(alloc, step.script)});
            }
            if (step.shell) |sh| try w.line("shell: {s}", .{try quoteScalar(alloc, sh)});
        },
        .uses => {
            try w.line("uses: {s}", .{try quoteScalar(alloc, step.uses_ref)});
            if (step.with.len > 0) {
                try w.raw("with:");
                w.indentIn();
                for (step.with) |pair| try w.line("{s}: {s}", .{ pair.name, try quoteScalar(alloc, pair.value) });
                w.indentOut();
            }
        },
    }
    if (step.env.len > 0) {
        try w.raw("env:");
        w.indentIn();
        for (step.env) |e| try w.line("{s}: {s}", .{ e.name, try quoteScalar(alloc, e.value) });
        w.indentOut();
    }
    if (step.workdir) |wd| try w.line("working-directory: {s}", .{try quoteScalar(alloc, wd)});
    if (step.cond) |c| if (std.mem.eql(u8, c, "always()")) try w.raw("if: always()");
    if (step.continue_on_error) try w.raw("continue-on-error: true");
    w.indentOut();
}

// ---------------------------------------------------------------------------
// GitLab
// ---------------------------------------------------------------------------

fn emitGitlab(w: *Writer, p: ir.Pipeline) !void {
    const alloc = w.alloc;
    try w.line("# jalan: translated from {s}", .{p.source_path});

    const levels = try topoLevels(alloc, p.jobs);
    var level_of_job: []usize = try alloc.alloc(usize, p.jobs.len);
    for (levels, 0..) |lvl, li| for (lvl) |idx| {
        level_of_job[idx] = li;
    };

    try w.raw("stages:");
    w.indentIn();
    for (0..levels.len) |li| try w.line("- s{d}", .{li + 1});
    w.indentOut();
    try w.blank();

    var id_map = try buildGitlabIdMap(alloc, p.jobs);

    for (p.jobs, 0..) |job, ji| {
        const sid = id_map.get(job.id).?;
        try w.line("{s}:", .{sid});
        w.indentIn();
        try w.line("stage: s{d}", .{level_of_job[ji] + 1});
        if (job.needs.len > 0) try writeNeedsList(w, job.needs, &id_map);
        if (job.container_image.len > 0)
            try w.line("image: {s}", .{try quoteScalar(alloc, job.container_image)});

        var dropped_service_env = false;
        for (job.services) |svc| {
            if (svc.env.len > 0) dropped_service_env = true;
        }
        if (job.services.len > 0) {
            if (dropped_service_env)
                try w.raw("# jalan: service variables are dropped (not simulated in GitLab translation)");
            try w.raw("services:");
            w.indentIn();
            for (job.services) |svc| try w.line("- {s}", .{try quoteScalar(alloc, svc.image)});
            w.indentOut();
        }

        var vars: std.ArrayList(ir.EnvPair) = .empty;
        try vars.appendSlice(alloc, try filteredEnv(alloc, job));

        var notes: std.ArrayList([]const u8) = .empty;
        var main_lines: std.ArrayList([]const u8) = .empty;
        var after_lines: std.ArrayList([]const u8) = .empty;
        var job_allow_failure = false;

        for (job.steps) |step| {
            const is_always = if (step.cond) |c| std.mem.eql(u8, c, "always()") else false;
            var target: *std.ArrayList([]const u8) = if (is_always) &after_lines else &main_lines;

            if (!is_always and step.continue_on_error) job_allow_failure = true;

            if (step.workdir) |wd| {
                try notes.append(alloc, try std.fmt.allocPrint(alloc, "# jalan: step workdir '{s}' folded into script", .{wd}));
                try target.append(alloc, try std.fmt.allocPrint(alloc, "cd '{s}'", .{wd}));
            }

            for (step.env) |e| {
                var existing_idx: ?usize = null;
                for (vars.items, 0..) |v, vi| {
                    if (std.mem.eql(u8, v.name, e.name)) {
                        existing_idx = vi;
                        break;
                    }
                }
                if (existing_idx) |vi| {
                    if (!std.mem.eql(u8, vars.items[vi].value, e.value))
                        try notes.append(alloc, try std.fmt.allocPrint(alloc, "# jalan: step env '{s}' conflicts with job variables (skipped)", .{e.name}));
                } else {
                    try vars.append(alloc, e);
                }
            }

            if (step.kind == .uses) {
                try notes.append(alloc, try std.fmt.allocPrint(alloc, "# jalan: GitHub action '{s}' has no GitLab equivalent (dropped)", .{step.uses_ref}));
                try target.append(alloc, try std.fmt.allocPrint(alloc, "echo 'jalan: skipped action {s}'", .{step.uses_ref}));
            } else {
                var it = std.mem.splitScalar(u8, step.script, '\n');
                while (it.next()) |ln| {
                    if (ln.len == 0) continue;
                    try target.append(alloc, ln);
                }
            }
        }

        if (main_lines.items.len == 0) {
            try notes.append(alloc, "# jalan: no script steps; placeholder inserted");
            try main_lines.append(alloc, "true");
        }

        for (notes.items) |note| try w.raw(note);

        if (vars.items.len > 0) {
            try w.raw("variables:");
            w.indentIn();
            for (vars.items) |v| try w.line("{s}: {s}", .{ v.name, try quoteScalar(alloc, v.value) });
            w.indentOut();
        }

        try w.raw("script:");
        w.indentIn();
        for (main_lines.items) |ln| try w.line("- {s}", .{try quoteScalar(alloc, ln)});
        w.indentOut();

        if (after_lines.items.len > 0) {
            try w.raw("after_script:");
            w.indentIn();
            for (after_lines.items) |ln| try w.line("- {s}", .{try quoteScalar(alloc, ln)});
            w.indentOut();
        }

        if (job_allow_failure) try w.raw("allow_failure: true");
        if (job.manual) try w.raw("when: manual");

        w.indentOut();
        try w.blank();
    }
}

// ---------------------------------------------------------------------------
// Jenkins (declarative Jenkinsfile)
// ---------------------------------------------------------------------------

fn emitJenkins(w: *Writer, p: ir.Pipeline) !void {
    const alloc = w.alloc;
    try w.line("// jalan: translated from {s}", .{p.source_path});
    try w.raw("pipeline {");
    w.indentIn();
    try w.raw("agent any");
    try w.raw("stages {");
    w.indentIn();

    const levels = try topoLevels(alloc, p.jobs);
    var seen_names: std.StringArrayHashMapUnmanaged(u32) = .empty;

    for (levels, 0..) |lvl, li| {
        if (lvl.len == 1) {
            try emitJenkinsStage(w, p.jobs[lvl[0]], &seen_names);
        } else {
            const base_name = try std.fmt.allocPrint(alloc, "parallel-{d}", .{li + 1});
            const pname = try uniqueName(alloc, &seen_names, base_name);
            try w.line("stage('{s}') {{", .{try groovyEscapeSingle(alloc, pname)});
            w.indentIn();
            try w.raw("parallel {");
            w.indentIn();
            for (lvl) |idx| try emitJenkinsStage(w, p.jobs[idx], &seen_names);
            w.indentOut();
            try w.raw("}");
            w.indentOut();
            try w.raw("}");
        }
    }

    w.indentOut();
    try w.raw("}");
    w.indentOut();
    try w.raw("}");
}

fn emitJenkinsStage(w: *Writer, job: ir.Job, seen_names: *std.StringArrayHashMapUnmanaged(u32)) !void {
    const alloc = w.alloc;
    const name = try uniqueName(alloc, seen_names, job.display_name);
    try w.line("stage('{s}') {{", .{try groovyEscapeSingle(alloc, name)});
    w.indentIn();

    if (job.container_image.len > 0) {
        try w.raw("agent {");
        w.indentIn();
        try w.raw("docker {");
        w.indentIn();
        try w.line("image '{s}'", .{try groovyEscapeSingle(alloc, job.container_image)});
        w.indentOut();
        try w.raw("}");
        w.indentOut();
        try w.raw("}");
    }

    const fenv = try filteredEnv(alloc, job);
    if (fenv.len > 0) {
        try w.raw("environment {");
        w.indentIn();
        for (fenv) |e| try w.line("{s} = '{s}'", .{ e.name, try groovyEscapeSingle(alloc, e.value) });
        w.indentOut();
        try w.raw("}");
    }

    if (job.manual) try w.raw("// jalan: manual in source");

    var post_always: std.ArrayList(ir.Step) = .empty;

    try w.raw("steps {");
    w.indentIn();
    for (job.steps) |step| {
        const is_always = if (step.cond) |c| std.mem.eql(u8, c, "always()") else false;
        if (is_always) {
            try post_always.append(alloc, step);
            continue;
        }
        try emitJenkinsStep(w, step);
    }
    w.indentOut();
    try w.raw("}");

    if (post_always.items.len > 0) {
        try w.raw("post {");
        w.indentIn();
        try w.raw("always {");
        w.indentIn();
        for (post_always.items) |step| try emitJenkinsStep(w, step);
        w.indentOut();
        try w.raw("}");
        w.indentOut();
        try w.raw("}");
    }

    w.indentOut();
    try w.raw("}");
}

/// sh/bat/powershell script bodies are always wrapped in Groovy triple-
/// double-quoted strings (`"""..."""`). This repo's Jenkinsfile tokenizer
/// (frontend/jenkins.zig Tokenizer.scanString) does zero escape processing
/// once it detects a triple-quote opener — the content between the open and
/// close `"""` is copied byte-for-byte until the next literal `"""` run.
/// That makes triple-double-quote the single robust choice for arbitrary
/// script content (single/double quotes, backslashes, `$`, newlines all
/// pass through unchanged); the one thing it cannot represent is a script
/// that itself contains a literal `"""` run, which is not handled here.
fn emitJenkinsStep(w: *Writer, step: ir.Step) !void {
    const alloc = w.alloc;
    if (step.kind == .uses) {
        try w.line("// jalan: GitHub action '{s}' skipped", .{step.uses_ref});
        try w.line("echo 'jalan: skipped action {s}'", .{try groovyEscapeSingle(alloc, step.uses_ref)});
        return;
    }
    const keyword: []const u8 = if (step.shell) |sh| blk: {
        if (std.mem.eql(u8, sh, "cmd")) break :blk "bat";
        if (std.mem.eql(u8, sh, "pwsh") or std.mem.eql(u8, sh, "powershell")) break :blk "powershell";
        break :blk "sh";
    } else "sh";

    if (step.workdir) |wd| {
        try w.line("dir('{s}') {{", .{try groovyEscapeSingle(alloc, wd)});
        w.indentIn();
        try w.line("{s} \"\"\"{s}\"\"\"", .{ keyword, step.script });
        w.indentOut();
        try w.raw("}");
    } else {
        try w.line("{s} \"\"\"{s}\"\"\"", .{ keyword, step.script });
    }
}

// ---------------------------------------------------------------------------
// CircleCI
// ---------------------------------------------------------------------------

fn sanitizeCircleciId(alloc: std.mem.Allocator, id: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (id) |c| {
        const lc = std.ascii.toLower(c);
        const ok = std.ascii.isAlphanumeric(lc) or lc == '-';
        try out.append(alloc, if (ok) lc else '-');
    }
    var result: []const u8 = try out.toOwnedSlice(alloc);
    if (result.len == 0) result = "job";
    return result;
}

fn buildCircleciIdMap(alloc: std.mem.Allocator, jobs: []const ir.Job) !std.StringArrayHashMapUnmanaged([]const u8) {
    var seen: std.StringArrayHashMapUnmanaged(u32) = .empty;
    var map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    for (jobs) |job| {
        const sanitized = try sanitizeCircleciId(alloc, job.id);
        const uniq = try uniqueName(alloc, &seen, sanitized);
        try map.put(alloc, job.id, uniq);
    }
    return map;
}

fn emitCircleci(w: *Writer, p: ir.Pipeline) !void {
    const alloc = w.alloc;
    try w.line("# jalan: translated from {s}", .{p.source_path});
    try w.raw("version: 2.1");
    try w.blank();
    try w.raw("jobs:");
    w.indentIn();

    var id_map = try buildCircleciIdMap(alloc, p.jobs);

    for (p.jobs) |job| {
        const sid = id_map.get(job.id).?;
        try w.line("{s}:", .{sid});
        w.indentIn();

        try w.raw("docker:");
        w.indentIn();
        const image = if (job.container_image.len > 0) job.container_image else "cimg/base:stable";
        try w.line("- image: {s}", .{try quoteScalar(alloc, image)});
        for (job.services) |svc| {
            try w.line("- image: {s}", .{try quoteScalar(alloc, svc.image)});
            if (svc.env.len > 0) {
                w.indentIn();
                try w.raw("environment:");
                w.indentIn();
                for (svc.env) |e| try w.line("{s}: {s}", .{ e.name, try quoteScalar(alloc, e.value) });
                w.indentOut();
                w.indentOut();
            }
        }
        w.indentOut();

        const fenv = try filteredEnv(alloc, job);
        if (fenv.len > 0) {
            try w.raw("environment:");
            w.indentIn();
            for (fenv) |e| try w.line("{s}: {s}", .{ e.name, try quoteScalar(alloc, e.value) });
            w.indentOut();
        }

        try w.raw("steps:");
        w.indentIn();
        for (job.steps) |step| try emitCircleciStep(w, step);
        w.indentOut();

        w.indentOut();
    }
    w.indentOut();

    try w.blank();
    try w.raw("workflows:");
    w.indentIn();
    try w.raw("translated:");
    w.indentIn();
    try w.raw("jobs:");
    w.indentIn();
    for (p.jobs) |job| {
        const sid = id_map.get(job.id).?;
        if (job.needs.len > 0) {
            try w.line("- {s}:", .{sid});
            // A bare `- key:` list item (no inline value) nests its child map
            // two indent levels deeper than the item itself: one level just
            // gets back to the `key:` column (the "- " ate two columns), a
            // second is needed to be genuinely nested under it.
            w.indentIn();
            w.indentIn();
            var parts: std.ArrayList(u8) = .empty;
            try parts.append(alloc, '[');
            for (job.needs, 0..) |n, i| {
                if (i > 0) try parts.appendSlice(alloc, ", ");
                const mapped = id_map.get(n) orelse n;
                try parts.appendSlice(alloc, try quoteScalar(alloc, mapped));
            }
            try parts.append(alloc, ']');
            try w.line("requires: {s}", .{try parts.toOwnedSlice(alloc)});
            w.indentOut();
            w.indentOut();
        } else {
            try w.line("- {s}", .{sid});
        }
        if (job.manual)
            try w.raw("# jalan: manual jobs need 'type: approval' in CircleCI (not simulated here)");
    }
    w.indentOut();
    w.indentOut();
    w.indentOut();
}

fn emitCircleciStep(w: *Writer, step: ir.Step) !void {
    const alloc = w.alloc;
    if (step.kind == .uses) {
        try w.line("# jalan: GitHub action '{s}' has no CircleCI equivalent (skipped)", .{step.uses_ref});
        try w.raw("- run:");
        w.indentIn();
        w.indentIn();
        try w.line("name: {s}", .{try quoteScalar(alloc, try std.fmt.allocPrint(alloc, "skipped action {s}", .{step.uses_ref}))});
        try w.line("command: {s}", .{try quoteScalar(alloc, try std.fmt.allocPrint(alloc, "echo 'jalan: skipped action {s}'", .{step.uses_ref}))});
        w.indentOut();
        w.indentOut();
        return;
    }

    const is_always = if (step.cond) |c| std.mem.eql(u8, c, "always()") else false;

    var notes: std.ArrayList([]const u8) = .empty;
    if (step.continue_on_error and !is_always)
        try notes.append(alloc, "# jalan: continue-on-error is not simulated (CircleCI has no per-step allow-fail)");

    var shell_key: ?[]const u8 = null;
    if (step.shell) |sh| {
        if (std.mem.eql(u8, sh, "bash")) {
            shell_key = "bash";
        } else if (std.mem.eql(u8, sh, "pwsh") or std.mem.eql(u8, sh, "powershell")) {
            shell_key = "pwsh";
        } else if (std.mem.eql(u8, sh, "sh")) {
            shell_key = "sh";
        } else if (std.mem.eql(u8, sh, "cmd")) {
            try notes.append(alloc, "# jalan: cmd shell has no CircleCI equivalent (omitted)");
        }
    }
    for (notes.items) |note| try w.raw(note);

    try w.raw("- run:");
    w.indentIn();
    w.indentIn();
    try w.line("name: {s}", .{try quoteScalar(alloc, step.name)});
    if (std.mem.indexOfScalar(u8, step.script, '\n') != null) {
        try writeBlockScalar(w, "command", step.script);
    } else {
        try w.line("command: {s}", .{try quoteScalar(alloc, step.script)});
    }
    if (shell_key) |sh| try w.line("shell: {s}", .{sh});
    if (step.env.len > 0) {
        try w.raw("environment:");
        w.indentIn();
        for (step.env) |e| try w.line("{s}: {s}", .{ e.name, try quoteScalar(alloc, e.value) });
        w.indentOut();
    }
    if (step.workdir) |wd| try w.line("working_directory: {s}", .{try quoteScalar(alloc, wd)});
    if (is_always) try w.raw("when: always");
    w.indentOut();
    w.indentOut();
}

// ---------------------------------------------------------------------------
// Azure Pipelines
// ---------------------------------------------------------------------------

fn sanitizeAzureId(alloc: std.mem.Allocator, id: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (id) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_';
        try out.append(alloc, if (ok) c else '_');
    }
    var result: []const u8 = try out.toOwnedSlice(alloc);
    if (result.len == 0) result = "job";
    return result;
}

fn uniqueUnderscoreName(alloc: std.mem.Allocator, seen: *std.StringArrayHashMapUnmanaged(u32), name: []const u8) ![]const u8 {
    const gop = try seen.getOrPut(alloc, name);
    if (!gop.found_existing) {
        gop.value_ptr.* = 1;
        return name;
    }
    gop.value_ptr.* += 1;
    return std.fmt.allocPrint(alloc, "{s}_{d}", .{ name, gop.value_ptr.* });
}

fn buildAzureIdMap(alloc: std.mem.Allocator, jobs: []const ir.Job) !std.StringArrayHashMapUnmanaged([]const u8) {
    var seen: std.StringArrayHashMapUnmanaged(u32) = .empty;
    var map: std.StringArrayHashMapUnmanaged([]const u8) = .empty;
    for (jobs) |job| {
        const sanitized = try sanitizeAzureId(alloc, job.id);
        const uniq = try uniqueUnderscoreName(alloc, &seen, sanitized);
        try map.put(alloc, job.id, uniq);
    }
    return map;
}

fn writeDependsOnList(w: *Writer, needs: []const []const u8, id_map: *const std.StringArrayHashMapUnmanaged([]const u8)) !void {
    const alloc = w.alloc;
    var parts: std.ArrayList(u8) = .empty;
    try parts.append(alloc, '[');
    for (needs, 0..) |n, i| {
        if (i > 0) try parts.appendSlice(alloc, ", ");
        const mapped = id_map.get(n) orelse n;
        try parts.appendSlice(alloc, try quoteScalar(alloc, mapped));
    }
    try parts.append(alloc, ']');
    try w.line("dependsOn: {s}", .{try parts.toOwnedSlice(alloc)});
}

fn emitAzure(w: *Writer, p: ir.Pipeline) !void {
    const alloc = w.alloc;
    try w.line("# jalan: translated from {s}", .{p.source_path});
    try w.line("name: {s}", .{try quoteScalar(alloc, p.name)});
    try w.blank();
    try w.raw("jobs:");
    w.indentIn();

    var id_map = try buildAzureIdMap(alloc, p.jobs);

    for (p.jobs) |job| {
        const sid = id_map.get(job.id).?;
        try w.line("- job: {s}", .{sid});
        w.indentIn();
        if (!std.mem.eql(u8, job.display_name, job.id))
            try w.line("displayName: {s}", .{try quoteScalar(alloc, job.display_name)});
        if (job.needs.len > 0) try writeDependsOnList(w, job.needs, &id_map);

        const fenv = try filteredEnv(alloc, job);
        if (fenv.len > 0) {
            try w.raw("variables:");
            w.indentIn();
            for (fenv) |e| try w.line("{s}: {s}", .{ e.name, try quoteScalar(alloc, e.value) });
            w.indentOut();
        }
        if (job.container_image.len > 0)
            try w.line("container: {s}", .{try quoteScalar(alloc, job.container_image)});
        if (job.runs_on.len > 0) {
            try w.raw("pool:");
            w.indentIn();
            try w.line("vmImage: {s}", .{try quoteScalar(alloc, job.runs_on)});
            w.indentOut();
        }
        if (job.services.len > 0)
            try w.raw("# jalan: job services are dropped (not simulated in Azure translation)");
        if (job.manual)
            try w.raw("# jalan: manual job in the source; runs like a normal job here");

        try w.raw("steps:");
        w.indentIn();
        for (job.steps) |step| try emitAzureStep(w, step);
        w.indentOut();

        w.indentOut();
    }
    w.indentOut();
}

fn emitAzureStep(w: *Writer, step: ir.Step) !void {
    const alloc = w.alloc;
    if (step.kind == .uses) {
        try w.line("# jalan: GitHub action '{s}' has no Azure equivalent (skipped)", .{step.uses_ref});
        const cmd = try std.fmt.allocPrint(alloc, "echo 'jalan: skipped action {s}'", .{step.uses_ref});
        try w.line("- script: {s}", .{try quoteScalar(alloc, cmd)});
        w.indentIn();
        try w.line("displayName: {s}", .{try quoteScalar(alloc, try std.fmt.allocPrint(alloc, "skipped action {s}", .{step.uses_ref}))});
        w.indentOut();
        return;
    }

    var keyword: []const u8 = "script";
    if (step.shell) |sh| {
        if (std.mem.eql(u8, sh, "bash")) {
            keyword = "bash";
        } else if (std.mem.eql(u8, sh, "pwsh")) {
            keyword = "pwsh";
        } else if (std.mem.eql(u8, sh, "powershell")) {
            keyword = "powershell";
        } else if (std.mem.eql(u8, sh, "cmd")) {
            try w.raw("# jalan: cmd has no dedicated Azure step (emitted as script)");
        }
    }

    if (std.mem.indexOfScalar(u8, step.script, '\n') != null) {
        try w.line("- {s}: |", .{keyword});
        w.indentIn();
        var it = std.mem.splitScalar(u8, step.script, '\n');
        while (it.next()) |ln| try w.line("{s}", .{ln});
        w.indentOut();
    } else {
        try w.line("- {s}: {s}", .{ keyword, try quoteScalar(alloc, step.script) });
    }

    w.indentIn();
    try w.line("displayName: {s}", .{try quoteScalar(alloc, step.name)});
    if (step.env.len > 0) {
        try w.raw("env:");
        w.indentIn();
        for (step.env) |e| try w.line("{s}: {s}", .{ e.name, try quoteScalar(alloc, e.value) });
        w.indentOut();
    }
    if (step.workdir) |wd| try w.line("workingDirectory: {s}", .{try quoteScalar(alloc, wd)});
    if (step.cond) |c| if (std.mem.eql(u8, c, "always()")) try w.raw("condition: always()");
    if (step.continue_on_error) try w.raw("continueOnError: true");
    w.indentOut();
}

// ---------------------------------------------------------------------------
// Bitbucket Pipelines
// ---------------------------------------------------------------------------

fn shellEscapeSingleQuoted(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (s) |c| {
        if (c == '\'') {
            try out.appendSlice(alloc, "'\\''");
        } else {
            try out.append(alloc, c);
        }
    }
    return out.toOwnedSlice(alloc);
}

fn mostCommonImage(alloc: std.mem.Allocator, jobs: []const ir.Job) ![]const u8 {
    var counts: std.StringArrayHashMapUnmanaged(u32) = .empty;
    var order: std.ArrayList([]const u8) = .empty;
    for (jobs) |job| {
        if (job.container_image.len == 0) continue;
        const gop = try counts.getOrPut(alloc, job.container_image);
        if (!gop.found_existing) {
            gop.value_ptr.* = 0;
            try order.append(alloc, job.container_image);
        }
        gop.value_ptr.* += 1;
    }
    var best: []const u8 = "";
    var best_count: u32 = 0;
    for (order.items) |img| {
        const c = counts.get(img).?;
        if (c > best_count) {
            best_count = c;
            best = img;
        }
    }
    return best;
}

fn collectServices(alloc: std.mem.Allocator, jobs: []const ir.Job) ![]ir.Service {
    var seen: std.StringArrayHashMapUnmanaged(void) = .empty;
    var out: std.ArrayList(ir.Service) = .empty;
    for (jobs) |job| for (job.services) |svc| {
        if (seen.contains(svc.name)) continue;
        try seen.put(alloc, svc.name, {});
        try out.append(alloc, svc);
    };
    return out.toOwnedSlice(alloc);
}

/// True if any non-first level's jobs need exactly the full set of jobs in
/// the immediately preceding level (bitbucket's structural sequential/
/// parallel shape can only express that one relationship exactly).
fn bitbucketNeedsApproximated(alloc: std.mem.Allocator, jobs: []const ir.Job, levels: []const []usize) !bool {
    for (levels, 0..) |lvl, li| {
        if (li == 0) continue;
        var prev_ids: std.StringArrayHashMapUnmanaged(void) = .empty;
        for (levels[li - 1]) |idx| try prev_ids.put(alloc, jobs[idx].id, {});
        for (lvl) |idx| {
            const job = jobs[idx];
            var matches = job.needs.len == prev_ids.count();
            if (matches) for (job.needs) |n| {
                if (!prev_ids.contains(n)) {
                    matches = false;
                    break;
                }
            };
            if (!matches) return true;
        }
    }
    return false;
}

fn emitBitbucket(w: *Writer, p: ir.Pipeline) !void {
    const alloc = w.alloc;
    try w.line("# jalan: translated from {s}", .{p.source_path});

    const root_image = try mostCommonImage(alloc, p.jobs);
    if (root_image.len > 0) try w.line("image: {s}", .{try quoteScalar(alloc, root_image)});

    const services = try collectServices(alloc, p.jobs);
    if (services.len > 0) {
        try w.raw("definitions:");
        w.indentIn();
        try w.raw("services:");
        w.indentIn();
        for (services) |svc| {
            try w.line("{s}:", .{try quoteScalar(alloc, svc.name)});
            w.indentIn();
            try w.line("image: {s}", .{try quoteScalar(alloc, svc.image)});
            if (svc.env.len > 0) {
                try w.raw("variables:");
                w.indentIn();
                for (svc.env) |e| try w.line("{s}: {s}", .{ e.name, try quoteScalar(alloc, e.value) });
                w.indentOut();
            }
            w.indentOut();
        }
        w.indentOut();
        w.indentOut();
    }

    const levels = try topoLevels(alloc, p.jobs);
    if (try bitbucketNeedsApproximated(alloc, p.jobs, levels))
        try w.raw("# jalan: dependency edges approximated by sequential stages");

    try w.raw("pipelines:");
    w.indentIn();
    try w.raw("default:");
    w.indentIn();

    for (levels) |lvl| {
        if (lvl.len == 1) {
            try w.raw("- step:");
            w.indentIn();
            w.indentIn();
            try emitBitbucketStepBody(w, p.jobs[lvl[0]], root_image);
            w.indentOut();
            w.indentOut();
        } else {
            try w.raw("- parallel:");
            w.indentIn();
            w.indentIn();
            try w.raw("steps:");
            w.indentIn();
            for (lvl) |idx| {
                try w.raw("- step:");
                w.indentIn();
                w.indentIn();
                try emitBitbucketStepBody(w, p.jobs[idx], root_image);
                w.indentOut();
                w.indentOut();
            }
            w.indentOut();
            w.indentOut();
            w.indentOut();
        }
    }

    w.indentOut();
    w.indentOut();
}

fn emitBitbucketStepBody(w: *Writer, job: ir.Job, root_image: []const u8) !void {
    const alloc = w.alloc;

    var notes: std.ArrayList([]const u8) = .empty;
    var main_lines: std.ArrayList([]const u8) = .empty;
    var after_lines: std.ArrayList([]const u8) = .empty;

    const fenv = try filteredEnv(alloc, job);
    if (fenv.len > 0) {
        try notes.append(alloc, "# jalan: job env exported via shell 'export' at the start of the script");
        for (fenv) |e|
            try main_lines.append(alloc, try std.fmt.allocPrint(alloc, "export {s}='{s}'", .{ e.name, try shellEscapeSingleQuoted(alloc, e.value) }));
    }

    for (job.steps) |step| {
        const is_always = if (step.cond) |c| std.mem.eql(u8, c, "always()") else false;
        var target: *std.ArrayList([]const u8) = if (is_always) &after_lines else &main_lines;

        if (!is_always and step.continue_on_error)
            try notes.append(alloc, "# jalan: continue-on-error is not simulated (Bitbucket has no per-step allow-fail)");

        if (step.workdir) |wd| {
            try notes.append(alloc, try std.fmt.allocPrint(alloc, "# jalan: step workdir '{s}' folded into script", .{wd}));
            try target.append(alloc, try std.fmt.allocPrint(alloc, "cd '{s}'", .{wd}));
        }

        if (step.kind == .uses) {
            try notes.append(alloc, try std.fmt.allocPrint(alloc, "# jalan: GitHub action '{s}' has no Bitbucket equivalent (dropped)", .{step.uses_ref}));
            try target.append(alloc, try std.fmt.allocPrint(alloc, "echo 'jalan: skipped action {s}'", .{step.uses_ref}));
        } else {
            var it = std.mem.splitScalar(u8, step.script, '\n');
            while (it.next()) |ln| {
                if (ln.len == 0) continue;
                try target.append(alloc, ln);
            }
        }
    }

    if (main_lines.items.len == 0) {
        try notes.append(alloc, "# jalan: no script steps; placeholder inserted");
        try main_lines.append(alloc, "true");
    }

    for (notes.items) |note| try w.raw(note);

    try w.line("name: {s}", .{try quoteScalar(alloc, job.display_name)});
    if (job.container_image.len > 0 and !std.mem.eql(u8, job.container_image, root_image))
        try w.line("image: {s}", .{try quoteScalar(alloc, job.container_image)});
    if (job.services.len > 0) {
        try w.raw("services:");
        w.indentIn();
        for (job.services) |svc| try w.line("- {s}", .{try quoteScalar(alloc, svc.name)});
        w.indentOut();
    }
    try w.raw("script:");
    w.indentIn();
    for (main_lines.items) |ln| try w.line("- {s}", .{try quoteScalar(alloc, ln)});
    w.indentOut();
    if (after_lines.items.len > 0) {
        try w.raw("after-script:");
        w.indentIn();
        for (after_lines.items) |ln| try w.line("- {s}", .{try quoteScalar(alloc, ln)});
        w.indentOut();
    }
    if (job.manual) try w.raw("trigger: manual");
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;
const yaml = @import("yaml.zig");
const gha_frontend = @import("frontend/gha.zig");
const gitlab_frontend = @import("frontend/gitlab.zig");
const jenkins_frontend = @import("frontend/jenkins.zig");
const circleci_frontend = @import("frontend/circleci.zig");
const azure_frontend = @import("frontend/azure.zig");
const bitbucket_frontend = @import("frontend/bitbucket.zig");

fn arenaAlloc() std.heap.ArenaAllocator {
    return std.heap.ArenaAllocator.init(testing.allocator);
}

test "topoLevels: chain a->b->c produces 3 levels" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    var steps = [_]ir.Step{.{ .id = "s", .name = "s", .kind = .run, .script = "echo hi" }};
    var needs_b = [_][]const u8{"a"};
    var needs_c = [_][]const u8{"b"};
    var jobs = [_]ir.Job{
        .{ .id = "a", .display_name = "a", .steps = &steps },
        .{ .id = "b", .display_name = "b", .needs = &needs_b, .steps = &steps },
        .{ .id = "c", .display_name = "c", .needs = &needs_c, .steps = &steps },
    };
    const levels = try topoLevels(a, &jobs);
    try testing.expectEqual(@as(usize, 3), levels.len);
    try testing.expectEqual(@as(usize, 1), levels[0].len);
    try testing.expectEqual(@as(usize, 0), levels[0][0]);
    try testing.expectEqual(@as(usize, 2), levels[2][0]);
}

test "topoLevels: diamond a->(b,c)->d produces 3 levels with paired middle" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    var steps = [_]ir.Step{.{ .id = "s", .name = "s", .kind = .run, .script = "echo hi" }};
    var needs_bc = [_][]const u8{"a"};
    var needs_d = [_][]const u8{ "b", "c" };
    var jobs = [_]ir.Job{
        .{ .id = "a", .display_name = "a", .steps = &steps },
        .{ .id = "b", .display_name = "b", .needs = &needs_bc, .steps = &steps },
        .{ .id = "c", .display_name = "c", .needs = &needs_bc, .steps = &steps },
        .{ .id = "d", .display_name = "d", .needs = &needs_d, .steps = &steps },
    };
    const levels = try topoLevels(a, &jobs);
    try testing.expectEqual(@as(usize, 3), levels.len);
    try testing.expectEqual(@as(usize, 2), levels[1].len);
}

test "gha: two-job pipeline emits needs, runs-on, if: always()" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    var build_steps = [_]ir.Step{.{ .id = "build", .name = "build", .kind = .run, .script = "echo build" }};
    var test_steps = [_]ir.Step{
        .{ .id = "test", .name = "test", .kind = .run, .script = "echo test" },
        .{ .id = "cleanup", .name = "cleanup", .kind = .run, .script = "echo cleanup", .cond = "always()" },
    };
    var needs = [_][]const u8{"build"};
    var jobs = [_]ir.Job{
        .{ .id = "build", .display_name = "build", .runs_on = "ubuntu-latest", .steps = &build_steps },
        .{ .id = "test", .display_name = "test", .needs = &needs, .steps = &test_steps },
    };
    const p = ir.Pipeline{ .name = "CI", .source_path = "x.yml", .jobs = &jobs };
    const out = try emit(a, p, .gha);
    try testing.expect(std.mem.indexOf(u8, out, "needs: [build]") != null);
    try testing.expect(std.mem.indexOf(u8, out, "runs-on: ubuntu-latest") != null);
    try testing.expect(std.mem.indexOf(u8, out, "if: always()") != null);

    var diags = yaml.Diags.init(a);
    const p2 = try gha_frontend.parseWorkflow(a, "out.yml", out, &diags);
    for (diags.list.items) |d| try testing.expect(std.mem.startsWith(u8, d.msg, "warning: "));
    try testing.expectEqual(@as(usize, 2), p2.jobs.len);
    try testing.expectEqualStrings("build", p2.jobs[1].needs[0]);
    try testing.expectEqualStrings("echo build", p2.jobs[0].steps[0].script);
    try testing.expectEqualStrings("echo test", p2.jobs[1].steps[0].script);
}

test "gha: uses step emits uses: and with:" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    var with_pairs = [_]ir.EnvPair{.{ .name = "ref", .value = "main" }};
    var steps = [_]ir.Step{.{ .id = "checkout", .name = "checkout", .kind = .uses, .script = "", .uses_ref = "actions/checkout@v4", .with = &with_pairs }};
    var jobs = [_]ir.Job{.{ .id = "build", .display_name = "build", .steps = &steps }};
    const p = ir.Pipeline{ .name = "CI", .source_path = "x.yml", .jobs = &jobs };
    const out = try emit(a, p, .gha);
    try testing.expect(std.mem.indexOf(u8, out, "actions/checkout@v4") != null);
    try testing.expect(std.mem.indexOf(u8, out, "with:") != null);
    try testing.expect(std.mem.indexOf(u8, out, "ref: main") != null);

    var diags = yaml.Diags.init(a);
    const p2 = try gha_frontend.parseWorkflow(a, "out.yml", out, &diags);
    try testing.expectEqual(ir.StepKind.uses, p2.jobs[0].steps[0].kind);
    try testing.expectEqualStrings("actions/checkout@v4", p2.jobs[0].steps[0].uses_ref);
}

test "gha: multi-line script round-trips byte-identical through block scalar" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    const script = "echo one\necho two\necho three";
    var steps = [_]ir.Step{.{ .id = "s", .name = "s", .kind = .run, .script = script }};
    var jobs = [_]ir.Job{.{ .id = "build", .display_name = "build", .steps = &steps }};
    const p = ir.Pipeline{ .name = "CI", .source_path = "x.yml", .jobs = &jobs };
    const out = try emit(a, p, .gha);
    try testing.expect(std.mem.indexOf(u8, out, "run: |") != null);

    var diags = yaml.Diags.init(a);
    const p2 = try gha_frontend.parseWorkflow(a, "out.yml", out, &diags);
    try testing.expectEqualStrings(script, p2.jobs[0].steps[0].script);
}

test "env filtering: predefined names dropped, user vars kept" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    var env = [_]ir.EnvPair{
        .{ .name = "CI_JOB_NAME", .value = "build" },
        .{ .name = "GITLAB_CI", .value = "true" },
        .{ .name = "BUILD_NUMBER", .value = "1" },
        .{ .name = "USER_VAR", .value = "keep-me" },
    };
    var steps = [_]ir.Step{.{ .id = "s", .name = "s", .kind = .run, .script = "echo hi" }};
    const job = ir.Job{ .id = "build", .display_name = "build", .env = &env, .steps = &steps };
    const out = try filteredEnv(a, job);
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("USER_VAR", out[0].name);
}

test "gitlab: round-trip preserves job count, needs, after_script, manual, allow_failure" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    var build_steps = [_]ir.Step{.{ .id = "s", .name = "s", .kind = .run, .script = "echo build", .continue_on_error = true }};
    var test_steps = [_]ir.Step{
        .{ .id = "s", .name = "s", .kind = .run, .script = "echo test" },
        .{ .id = "after", .name = "after", .kind = .run, .script = "echo cleanup", .cond = "always()" },
    };
    var needs = [_][]const u8{"build"};
    var jobs = [_]ir.Job{
        .{ .id = "build", .display_name = "build", .steps = &build_steps },
        .{ .id = "test", .display_name = "test", .needs = &needs, .steps = &test_steps, .manual = true },
    };
    const p = ir.Pipeline{ .name = "CI", .source_path = ".gitlab-ci.yml", .jobs = &jobs };
    const out = try emit(a, p, .gitlab);

    var diags = yaml.Diags.init(a);
    const p2 = try gitlab_frontend.parsePipeline(a, "out.yml", out, &diags);
    try testing.expectEqual(@as(usize, 2), p2.jobs.len);
    try testing.expectEqualStrings("build", p2.jobs[1].needs[0]);
    try testing.expect(p2.jobs[1].manual);
    try testing.expect(p2.jobs[0].steps[0].continue_on_error);

    var found_after = false;
    for (p2.jobs[1].steps) |st| {
        if (std.mem.indexOf(u8, st.script, "echo cleanup") != null and st.cond != null and std.mem.eql(u8, st.cond.?, "always()"))
            found_after = true;
    }
    try testing.expect(found_after);
}

test "gitlab: uses step dropped with note and echo placeholder" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    var steps = [_]ir.Step{.{ .id = "checkout", .name = "checkout", .kind = .uses, .script = "", .uses_ref = "actions/checkout@v4" }};
    var jobs = [_]ir.Job{.{ .id = "build", .display_name = "build", .steps = &steps }};
    const p = ir.Pipeline{ .name = "CI", .source_path = ".gitlab-ci.yml", .jobs = &jobs };
    const out = try emit(a, p, .gitlab);
    try testing.expect(std.mem.indexOf(u8, out, "has no GitLab equivalent") != null);
    try testing.expect(std.mem.indexOf(u8, out, "skipped action actions/checkout@v4") != null);

    var diags = yaml.Diags.init(a);
    const p2 = try gitlab_frontend.parsePipeline(a, "out.yml", out, &diags);
    try testing.expectEqual(@as(usize, 1), p2.jobs.len);
}

test "jenkins: round-trip preserves job count and scripts" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    var build_steps = [_]ir.Step{.{ .id = "s", .name = "s", .kind = .run, .script = "echo build" }};
    var test_steps = [_]ir.Step{
        .{ .id = "s", .name = "s", .kind = .run, .script = "echo test" },
        .{ .id = "after", .name = "after", .kind = .run, .script = "echo cleanup", .cond = "always()" },
    };
    var needs = [_][]const u8{"build"};
    var jobs = [_]ir.Job{
        .{ .id = "build", .display_name = "build", .steps = &build_steps },
        .{ .id = "test", .display_name = "test", .needs = &needs, .steps = &test_steps },
    };
    const p = ir.Pipeline{ .name = "CI", .source_path = "Jenkinsfile", .jobs = &jobs };
    const out = try emit(a, p, .jenkins);

    var diags = yaml.Diags.init(a);
    const p2 = try jenkins_frontend.parsePipeline(a, "out", out, &diags);
    try testing.expectEqual(@as(usize, 2), p2.jobs.len);

    var found_build = false;
    var found_post_always = false;
    for (p2.jobs) |j| {
        for (j.steps) |st| {
            if (std.mem.indexOf(u8, st.script, "echo build") != null) found_build = true;
            if (std.mem.indexOf(u8, st.script, "echo cleanup") != null and st.cond != null and std.mem.eql(u8, st.cond.?, "always()"))
                found_post_always = true;
        }
    }
    try testing.expect(found_build);
    try testing.expect(found_post_always);
}

test "jenkins: parallel level produces one job per branch" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    var steps_a = [_]ir.Step{.{ .id = "s", .name = "s", .kind = .run, .script = "echo a" }};
    var steps_b = [_]ir.Step{.{ .id = "s", .name = "s", .kind = .run, .script = "echo b" }};
    var jobs = [_]ir.Job{
        .{ .id = "a", .display_name = "a", .steps = &steps_a },
        .{ .id = "b", .display_name = "b", .steps = &steps_b },
    };
    const p = ir.Pipeline{ .name = "CI", .source_path = "Jenkinsfile", .jobs = &jobs };
    const out = try emit(a, p, .jenkins);
    try testing.expect(std.mem.indexOf(u8, out, "parallel {") != null);

    var diags = yaml.Diags.init(a);
    const p2 = try jenkins_frontend.parsePipeline(a, "out", out, &diags);
    try testing.expectEqual(@as(usize, 2), p2.jobs.len);
}

test "jenkins: bat/powershell shell mapping and quote-safe script" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    var steps = [_]ir.Step{
        .{ .id = "s1", .name = "s1", .kind = .run, .script = "echo cmd-step", .shell = "cmd" },
        .{ .id = "s2", .name = "s2", .kind = .run, .script = "echo pwsh-step", .shell = "pwsh" },
        .{ .id = "s3", .name = "s3", .kind = .run, .script = "echo 'it has a quote'" },
    };
    var jobs = [_]ir.Job{.{ .id = "build", .display_name = "build", .steps = &steps }};
    const p = ir.Pipeline{ .name = "CI", .source_path = "Jenkinsfile", .jobs = &jobs };
    const out = try emit(a, p, .jenkins);
    try testing.expect(std.mem.indexOf(u8, out, "bat \"\"\"echo cmd-step\"\"\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, "powershell \"\"\"echo pwsh-step\"\"\"") != null);

    var diags = yaml.Diags.init(a);
    const p2 = try jenkins_frontend.parsePipeline(a, "out", out, &diags);
    var found_quote = false;
    for (p2.jobs[0].steps) |st| {
        if (std.mem.indexOf(u8, st.script, "echo 'it has a quote'") != null) found_quote = true;
    }
    try testing.expect(found_quote);
}

test "Target.fromName resolves known aliases" {
    try testing.expectEqual(Target.gha, Target.fromName("gha").?);
    try testing.expectEqual(Target.gha, Target.fromName("github-actions").?);
    try testing.expectEqual(Target.gitlab, Target.fromName("gitlab").?);
    try testing.expectEqual(Target.azure, Target.fromName("azure-pipelines").?);
    try testing.expectEqual(@as(?Target, null), Target.fromName("nonsense"));
}

test "circleci: round-trip preserves jobs, requires, when-always, service env, uses placeholder" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    var svc_env = [_]ir.EnvPair{.{ .name = "MODE", .value = "cache" }};
    var services = [_]ir.Service{.{ .name = "redis", .image = "redis:7", .env = &svc_env }};
    var build_steps = [_]ir.Step{
        .{ .id = "s1", .name = "build", .kind = .run, .script = "echo build" },
        .{ .id = "s2", .name = "checkout", .kind = .uses, .script = "", .uses_ref = "actions/checkout@v4" },
        .{ .id = "s3", .name = "cleanup", .kind = .run, .script = "echo cleanup", .cond = "always()" },
    };
    var test_steps = [_]ir.Step{.{ .id = "s", .name = "test", .kind = .run, .script = "echo test" }};
    var needs = [_][]const u8{"build"};
    var jobs = [_]ir.Job{
        .{ .id = "build", .display_name = "build", .container_image = "node:18", .services = &services, .steps = &build_steps },
        .{ .id = "test", .display_name = "test", .needs = &needs, .steps = &test_steps },
    };
    const p = ir.Pipeline{ .name = "CI", .source_path = ".circleci/config.yml", .jobs = &jobs };
    const out = try emit(a, p, .circleci);

    var diags = yaml.Diags.init(a);
    const p2 = try circleci_frontend.parsePipeline(a, "out.yml", out, &diags);
    for (diags.list.items) |d| try testing.expect(std.mem.startsWith(u8, d.msg, "warning: "));
    try testing.expectEqual(@as(usize, 2), p2.jobs.len);
    try testing.expectEqualStrings("build", p2.jobs[1].needs[0]);
    try testing.expectEqualStrings("redis", p2.jobs[0].services[0].name);
    try testing.expectEqualStrings("MODE", p2.jobs[0].services[0].env[0].name);

    var found_always = false;
    var found_uses = false;
    for (p2.jobs[0].steps) |st| {
        if (std.mem.indexOf(u8, st.script, "echo cleanup") != null and st.cond != null and std.mem.eql(u8, st.cond.?, "always()"))
            found_always = true;
        if (std.mem.indexOf(u8, st.script, "skipped action actions/checkout@v4") != null) found_uses = true;
    }
    try testing.expect(found_always);
    try testing.expect(found_uses);
}

test "circleci: bash and pwsh shells round-trip" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    var steps = [_]ir.Step{
        .{ .id = "s1", .name = "s1", .kind = .run, .script = "echo bash-step", .shell = "bash" },
        .{ .id = "s2", .name = "s2", .kind = .run, .script = "echo pwsh-step", .shell = "pwsh" },
    };
    var jobs = [_]ir.Job{.{ .id = "build", .display_name = "build", .steps = &steps }};
    const p = ir.Pipeline{ .name = "CI", .source_path = ".circleci/config.yml", .jobs = &jobs };
    const out = try emit(a, p, .circleci);

    var diags = yaml.Diags.init(a);
    const p2 = try circleci_frontend.parsePipeline(a, "out.yml", out, &diags);
    try testing.expectEqualStrings("bash", p2.jobs[0].steps[0].shell.?);
    try testing.expectEqualStrings("pwsh", p2.jobs[0].steps[1].shell.?);
}

test "circleci and azure: manual jobs emit a not-simulated note instead of a hard failure" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    var steps = [_]ir.Step{.{ .id = "s", .name = "s", .kind = .run, .script = "echo hi" }};
    var jobs = [_]ir.Job{.{ .id = "deploy", .display_name = "deploy", .manual = true, .steps = &steps }};
    const p = ir.Pipeline{ .name = "CI", .source_path = "x.yml", .jobs = &jobs };

    const circleci_out = try emit(a, p, .circleci);
    try testing.expect(std.mem.indexOf(u8, circleci_out, "not simulated here") != null);
    var diags1 = yaml.Diags.init(a);
    _ = try circleci_frontend.parsePipeline(a, "out.yml", circleci_out, &diags1);

    const azure_out = try emit(a, p, .azure);
    try testing.expect(std.mem.indexOf(u8, azure_out, "manual job in the source") != null);
    var diags2 = yaml.Diags.init(a);
    _ = try azure_frontend.parsePipeline(a, "out.yml", azure_out, &diags2);
}

test "azure: round-trip preserves jobs, dependsOn, shells, condition, continueOnError, container" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    var build_steps = [_]ir.Step{
        .{ .id = "s1", .name = "Build Step", .kind = .run, .script = "echo build", .shell = "bash" },
        .{ .id = "s2", .name = "ps", .kind = .run, .script = "echo pwsh-step", .shell = "pwsh" },
    };
    var test_steps = [_]ir.Step{
        .{ .id = "s3", .name = "test", .kind = .run, .script = "echo test" },
        .{ .id = "s4", .name = "cleanup", .kind = .run, .script = "echo cleanup", .cond = "always()", .continue_on_error = true },
    };
    var needs = [_][]const u8{"build"};
    var jobs = [_]ir.Job{
        .{ .id = "build", .display_name = "Build Job", .container_image = "node:18", .steps = &build_steps },
        .{ .id = "test", .display_name = "test", .needs = &needs, .steps = &test_steps },
    };
    const p = ir.Pipeline{ .name = "CI", .source_path = "azure-pipelines.yml", .jobs = &jobs };
    const out = try emit(a, p, .azure);

    var diags = yaml.Diags.init(a);
    const p2 = try azure_frontend.parsePipeline(a, "out.yml", out, &diags);
    for (diags.list.items) |d| try testing.expect(std.mem.startsWith(u8, d.msg, "warning: "));
    try testing.expectEqual(@as(usize, 2), p2.jobs.len);
    try testing.expectEqualStrings("build", p2.jobs[1].needs[0]);
    try testing.expectEqualStrings("node:18", p2.jobs[0].container_image);
    try testing.expectEqualStrings("Build Step", p2.jobs[0].steps[0].name);
    try testing.expectEqualStrings("bash", p2.jobs[0].steps[0].shell.?);
    try testing.expectEqualStrings("pwsh", p2.jobs[0].steps[1].shell.?);

    var found_cond = false;
    var found_continue = false;
    for (p2.jobs[1].steps) |st| {
        if (st.cond != null and std.mem.eql(u8, st.cond.?, "always()")) found_cond = true;
        if (st.continue_on_error) found_continue = true;
    }
    try testing.expect(found_cond);
    try testing.expect(found_continue);
}

test "circleci: cmd shell has no equivalent and is omitted with a note" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    var steps = [_]ir.Step{.{ .id = "s", .name = "s", .kind = .run, .script = "echo hi", .shell = "cmd" }};
    var jobs = [_]ir.Job{.{ .id = "build", .display_name = "build", .steps = &steps }};
    const p = ir.Pipeline{ .name = "CI", .source_path = ".circleci/config.yml", .jobs = &jobs };
    const out = try emit(a, p, .circleci);
    try testing.expect(std.mem.indexOf(u8, out, "cmd shell has no CircleCI equivalent") != null);
    try testing.expect(std.mem.indexOf(u8, out, "shell: cmd") == null);

    var diags = yaml.Diags.init(a);
    const p2 = try circleci_frontend.parsePipeline(a, "out.yml", out, &diags);
    try testing.expectEqual(@as(usize, 1), p2.jobs.len);
}

test "azure: workingDirectory and step env round-trip, job services drop with a note" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    var env = [_]ir.EnvPair{.{ .name = "FOO", .value = "bar" }};
    var services = [_]ir.Service{.{ .name = "redis", .image = "redis:7" }};
    var steps = [_]ir.Step{.{ .id = "s", .name = "s", .kind = .run, .script = "echo hi", .env = &env, .workdir = "sub" }};
    var jobs = [_]ir.Job{.{ .id = "build", .display_name = "build", .services = &services, .steps = &steps }};
    const p = ir.Pipeline{ .name = "CI", .source_path = "azure-pipelines.yml", .jobs = &jobs };
    const out = try emit(a, p, .azure);
    try testing.expect(std.mem.indexOf(u8, out, "job services are dropped") != null);

    var diags = yaml.Diags.init(a);
    const p2 = try azure_frontend.parsePipeline(a, "out.yml", out, &diags);
    try testing.expectEqualStrings("sub", p2.jobs[0].steps[0].workdir.?);
    try testing.expectEqualStrings("FOO", p2.jobs[0].steps[0].env[0].name);
}

test "bitbucket: root image is the most common, differing step image overrides it" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    var steps_a = [_]ir.Step{.{ .id = "s", .name = "s", .kind = .run, .script = "echo a" }};
    var steps_b = [_]ir.Step{.{ .id = "s", .name = "s", .kind = .run, .script = "echo b" }};
    var needs_b = [_][]const u8{"a"};
    var jobs = [_]ir.Job{
        .{ .id = "a", .display_name = "a", .container_image = "node:18", .steps = &steps_a },
        .{ .id = "b", .display_name = "b", .container_image = "node:20", .needs = &needs_b, .steps = &steps_b },
    };
    const p = ir.Pipeline{ .name = "CI", .source_path = "bitbucket-pipelines.yml", .jobs = &jobs };
    const out = try emit(a, p, .bitbucket);

    var diags = yaml.Diags.init(a);
    const p2 = try bitbucket_frontend.parsePipeline(a, "out.yml", out, &diags);
    try testing.expectEqualStrings("node:18", p2.jobs[0].container_image);
    try testing.expectEqualStrings("node:20", p2.jobs[1].container_image);
}

test "bitbucket: continue-on-error and uses steps emit notes, uses becomes an echo placeholder" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    var steps = [_]ir.Step{
        .{ .id = "s1", .name = "s1", .kind = .run, .script = "echo hi", .continue_on_error = true },
        .{ .id = "s2", .name = "s2", .kind = .uses, .script = "", .uses_ref = "actions/checkout@v4" },
    };
    var jobs = [_]ir.Job{.{ .id = "build", .display_name = "build", .steps = &steps }};
    const p = ir.Pipeline{ .name = "CI", .source_path = "bitbucket-pipelines.yml", .jobs = &jobs };
    const out = try emit(a, p, .bitbucket);
    try testing.expect(std.mem.indexOf(u8, out, "continue-on-error is not simulated") != null);
    try testing.expect(std.mem.indexOf(u8, out, "has no Bitbucket equivalent") != null);

    var diags = yaml.Diags.init(a);
    const p2 = try bitbucket_frontend.parsePipeline(a, "out.yml", out, &diags);
    try testing.expect(std.mem.indexOf(u8, p2.jobs[0].steps[0].script, "skipped action actions/checkout@v4") != null);
}

test "bitbucket: chain of jobs round-trips as sequential steps with reconstructed needs" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    var steps_a = [_]ir.Step{.{ .id = "s", .name = "s", .kind = .run, .script = "echo a" }};
    var steps_b = [_]ir.Step{.{ .id = "s", .name = "s", .kind = .run, .script = "echo b" }};
    var steps_c = [_]ir.Step{.{ .id = "s", .name = "s", .kind = .run, .script = "echo c" }};
    var needs_b = [_][]const u8{"a"};
    var needs_c = [_][]const u8{"b"};
    var jobs = [_]ir.Job{
        .{ .id = "a", .display_name = "a", .steps = &steps_a },
        .{ .id = "b", .display_name = "b", .needs = &needs_b, .steps = &steps_b },
        .{ .id = "c", .display_name = "c", .needs = &needs_c, .steps = &steps_c },
    };
    const p = ir.Pipeline{ .name = "CI", .source_path = "bitbucket-pipelines.yml", .jobs = &jobs };
    const out = try emit(a, p, .bitbucket);

    var diags = yaml.Diags.init(a);
    const p2 = try bitbucket_frontend.parsePipeline(a, "out.yml", out, &diags);
    for (diags.list.items) |d| try testing.expect(std.mem.startsWith(u8, d.msg, "warning: "));
    try testing.expectEqual(@as(usize, 3), p2.jobs.len);
    try testing.expectEqualStrings("a", p2.jobs[1].needs[0]);
    try testing.expectEqualStrings("b", p2.jobs[2].needs[0]);
    try testing.expect(std.mem.indexOf(u8, out, "dependency edges approximated") == null);
}

test "bitbucket: parallel level round-trips to shared needs, after-script, manual, exported env" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    var env = [_]ir.EnvPair{.{ .name = "FOO", .value = "bar" }};
    var steps_a = [_]ir.Step{.{ .id = "s", .name = "s", .kind = .run, .script = "echo setup" }};
    var steps_b = [_]ir.Step{
        .{ .id = "s", .name = "s", .kind = .run, .script = "echo b" },
        .{ .id = "after", .name = "after", .kind = .run, .script = "echo cleanup", .cond = "always()" },
    };
    var steps_c = [_]ir.Step{.{ .id = "s", .name = "s", .kind = .run, .script = "echo c" }};
    var needs_bc = [_][]const u8{"setup"};
    var jobs = [_]ir.Job{
        .{ .id = "setup", .display_name = "setup", .steps = &steps_a },
        .{ .id = "b", .display_name = "b", .needs = &needs_bc, .env = &env, .steps = &steps_b, .manual = true },
        .{ .id = "c", .display_name = "c", .needs = &needs_bc, .steps = &steps_c },
    };
    const p = ir.Pipeline{ .name = "CI", .source_path = "bitbucket-pipelines.yml", .jobs = &jobs };
    const out = try emit(a, p, .bitbucket);
    try testing.expect(std.mem.indexOf(u8, out, "- parallel:") != null);

    var diags = yaml.Diags.init(a);
    const p2 = try bitbucket_frontend.parsePipeline(a, "out.yml", out, &diags);
    try testing.expectEqual(@as(usize, 3), p2.jobs.len);
    try testing.expectEqualStrings("setup", p2.jobs[1].needs[0]);
    try testing.expectEqualStrings("setup", p2.jobs[2].needs[0]);
    try testing.expect(p2.jobs[1].manual);

    var found_after = false;
    var found_export = false;
    for (p2.jobs[1].steps) |st| {
        if (std.mem.indexOf(u8, st.script, "echo cleanup") != null and st.cond != null and std.mem.eql(u8, st.cond.?, "always()"))
            found_after = true;
        if (std.mem.indexOf(u8, st.script, "export FOO='bar'") != null) found_export = true;
    }
    try testing.expect(found_after);
    try testing.expect(found_export);
}

test "bitbucket: diamond DAG needs no approximation note, skip-level edge does" {
    var arena = arenaAlloc();
    defer arena.deinit();
    const a = arena.allocator();
    var steps = [_]ir.Step{.{ .id = "s", .name = "s", .kind = .run, .script = "echo hi" }};
    var needs_bc = [_][]const u8{"a"};
    var needs_d = [_][]const u8{ "b", "c" };
    var diamond_jobs = [_]ir.Job{
        .{ .id = "a", .display_name = "a", .steps = &steps },
        .{ .id = "b", .display_name = "b", .needs = &needs_bc, .steps = &steps },
        .{ .id = "c", .display_name = "c", .needs = &needs_bc, .steps = &steps },
        .{ .id = "d", .display_name = "d", .needs = &needs_d, .steps = &steps },
    };
    const diamond_p = ir.Pipeline{ .name = "CI", .source_path = "bitbucket-pipelines.yml", .jobs = &diamond_jobs };
    const diamond_out = try emit(a, diamond_p, .bitbucket);
    try testing.expect(std.mem.indexOf(u8, diamond_out, "dependency edges approximated") == null);

    var needs_c_only = [_][]const u8{"a"};
    var skip_jobs = [_]ir.Job{
        .{ .id = "a", .display_name = "a", .steps = &steps },
        .{ .id = "b", .display_name = "b", .steps = &steps },
        .{ .id = "c", .display_name = "c", .needs = &needs_c_only, .steps = &steps },
    };
    const skip_p = ir.Pipeline{ .name = "CI", .source_path = "bitbucket-pipelines.yml", .jobs = &skip_jobs };
    const skip_out = try emit(a, skip_p, .bitbucket);
    try testing.expect(std.mem.indexOf(u8, skip_out, "dependency edges approximated") != null);
}
