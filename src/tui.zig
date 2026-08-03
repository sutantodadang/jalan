//! A deliberately plain, line-oriented interactive view. It works over SSH
//! and terminals that do not support cursor control.
const std = @import("std");
const debug = @import("debug.zig");
const engine = @import("engine.zig");
const ir = @import("ir.zig");

pub fn isInteractive() bool {
    return std.fs.File.stdin().isTty() and std.fs.File.stdout().isTty();
}

pub const Command = union(enum) {
    continue_,
    skip,
    abort,
    shell,
    retry,
    toggle_env,
    toggle_workdir,
    watch_add: []const u8,
    watch_remove: []const u8,
    up,
    down,
    logs,
    quit,
    invalid,
};

/// Parse a single line without doing I/O, so command behavior stays testable.
pub fn parseCommand(line: []const u8) Command {
    const cmd = std.mem.trim(u8, line, " \t\r\n");
    if (cmd.len == 0 or eq(cmd, "c") or eq(cmd, "continue")) return .continue_;
    if (eq(cmd, "s") or eq(cmd, "skip")) return .skip;
    if (eq(cmd, "a") or eq(cmd, "abort")) return .abort;
    if (eq(cmd, "sh") or eq(cmd, "shell")) return .shell;
    if (eq(cmd, "r") or eq(cmd, "retry")) return .retry;
    if (eq(cmd, "e") or eq(cmd, "env")) return .toggle_env;
    if (eq(cmd, "w") or eq(cmd, "workdir")) return .toggle_workdir;
    if (eq(cmd, "j")) return .down;
    if (eq(cmd, "k")) return .up;
    if (eq(cmd, "l") or eq(cmd, "logs")) return .logs;
    if (eq(cmd, "q") or eq(cmd, "quit")) return .quit;
    if (cmd[0] == '+' or cmd[0] == '-') {
        const key = std.mem.trim(u8, cmd[1..], " \t");
        if (key.len == 0) return .invalid;
        return if (cmd[0] == '+') .{ .watch_add = key } else .{ .watch_remove = key };
    }
    return .invalid;
}

pub const ViewState = struct {
    selected_job: usize = 0,
    show_env: bool = false,
    show_workdir: bool = false,
};

/// The small pure state-reducer seam used by both interactive views.
pub fn reduceSelection(selected: *usize, command: Command, len: usize) bool {
    if (len == 0) {
        selected.* = 0;
        return false;
    }
    switch (command) {
        .up => selected.* = if (selected.* == 0) len - 1 else selected.* - 1,
        .down => selected.* = (selected.* + 1) % len,
        else => return false,
    }
    return true;
}

pub const Session = struct {
    alloc: std.mem.Allocator,
    pipeline: ir.Pipeline,
    watches: std.ArrayList([]const u8) = .empty,
    view: ViewState = .{},
    selected_step: usize = 0,
    show_logs: bool = false,
    prompt_job: usize = std.math.maxInt(usize),
    prompt_step: []const u8 = "",

    pub fn init(_: std.mem.Allocator, pipeline: ir.Pipeline) Session {
        // Prompts run on engine worker threads while the caller arena can be
        // active elsewhere. The OS page allocator is thread-safe; Session
        // mutations themselves remain serialized by the engine prompt mutex.
        return .{ .alloc = std.heap.page_allocator, .pipeline = pipeline };
    }

    pub fn deinit(self: *Session) void {
        for (self.watches.items) |key| self.alloc.free(key);
        self.watches.deinit(self.alloc);
    }

    pub fn prompt(ctx: ?*anyopaque, state: debug.PromptState) debug.PromptCmd {
        const self: *Session = @ptrCast(@alignCast(ctx orelse return .continue_));
        if (self.prompt_job != state.job_index or !std.mem.eql(u8, self.prompt_step, state.step_id)) {
            self.prompt_job = state.job_index;
            self.prompt_step = state.step_id;
            self.view.selected_job = state.job_index;
        }
        var input_buf: [512]u8 = undefined;
        while (true) {
            self.printPrompt(state);
            const command = switch (readCommand(&input_buf)) {
                .eof => return .continue_,
                .command => |value| value,
            };
            switch (command) {
                .continue_ => return .continue_,
                .skip => if (state.kind == .breakpoint) return .skip,
                .abort => return .abort,
                .shell => if (state.kind == .breakpoint) return .shell,
                .retry => if (state.kind == .failure) return .retry,
                .toggle_env => self.view.show_env = !self.view.show_env,
                .toggle_workdir => self.view.show_workdir = !self.view.show_workdir,
                .watch_add => |key| self.addWatch(key),
                .watch_remove => |key| self.removeWatch(key),
                .up, .down => _ = reduceSelection(&self.view.selected_job, command, self.pipeline.jobs.len),
                else => {},
            }
        }
    }

    /// Show the completed report until the user quits. EOF is also a quit.
    pub fn finish(self: *Session, report: engine.Report) !u8 {
        var input_buf: [512]u8 = undefined;
        while (true) {
            const text = try renderReport(self.alloc, report, self.selected_step, self.show_logs);
            defer self.alloc.free(text);
            write(text);
            const command = switch (readCommand(&input_buf)) {
                .eof => break,
                .command => |value| value,
            };
            switch (command) {
                .quit => break,
                .logs => self.show_logs = !self.show_logs,
                .up, .down => _ = reduceSelection(&self.selected_step, command, stepCount(report)),
                else => {},
            }
        }
        return if (report.ok()) 0 else 1;
    }

    fn printPrompt(self: *Session, state: debug.PromptState) void {
        const text = renderPrompt(self.alloc, self.pipeline, state, self.view, self.watches.items) catch return;
        defer self.alloc.free(text);
        write(text);
    }

    fn addWatch(self: *Session, key: []const u8) void {
        for (self.watches.items) |existing| if (std.mem.eql(u8, existing, key)) return;
        const copy = self.alloc.dupe(u8, key) catch return;
        self.watches.append(self.alloc, copy) catch self.alloc.free(copy);
    }

    fn removeWatch(self: *Session, key: []const u8) void {
        for (self.watches.items, 0..) |existing, i| {
            if (!std.mem.eql(u8, existing, key)) continue;
            self.alloc.free(existing);
            _ = self.watches.orderedRemove(i);
            return;
        }
    }
};

/// Deterministic prompt renderer: state comes from the engine and watch values
/// are already secret-masked by that boundary.
pub fn renderPrompt(
    alloc: std.mem.Allocator,
    pipeline: ir.Pipeline,
    state: debug.PromptState,
    view: ViewState,
    watches: []const []const u8,
) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    const w = out.writer(alloc);
    try w.print("\n[{s}] {s}/{s} step {d}: {s}\n", .{ @tagName(state.kind), state.job_name, state.job_id, state.step_index + 1, state.step_name });
    try w.print("workspace: {s}\n", .{state.workspace});
    if (view.show_workdir) try w.print("workdir: {s}\n", .{state.workdir orelse state.workspace});
    try w.writeAll("DAG:\n");
    for (pipeline.jobs, 0..) |job, i| {
        try w.print("{s} {s}", .{ if (i == view.selected_job) ">" else " ", job.id });
        if (job.needs.len > 0) {
            try w.writeAll(" <- ");
            for (job.needs, 0..) |need, ni| {
                if (ni != 0) try w.writeAll(", ");
                try w.writeAll(need);
            }
        }
        try w.writeByte('\n');
    }
    for (watches) |key| try w.print("watch {s}={s}\n", .{ key, envValue(state.effective_env, key) orelse "<unset>" });
    if (view.show_env) for (state.effective_env) |pair| try w.print("env {s}={s}\n", .{ pair.name, pair.value });
    if (state.kind == .failure)
        try w.writeAll("c continue; r retry; a abort; e env; w workdir; + KEY/- KEY watch; j/k select\n> ")
    else
        try w.writeAll("c continue; s skip; a abort; sh shell; e env; w workdir; + KEY/- KEY watch; j/k select\n> ");
    return out.toOwnedSlice(alloc);
}

/// Deterministic final-view renderer, kept separate from stdin/stdout for tests.
pub fn renderReport(alloc: std.mem.Allocator, report: engine.Report, selected_step: usize, show_logs: bool) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(alloc);
    const w = out.writer(alloc);
    var flat: usize = 0;
    try w.writeAll("\nreport:\n");
    for (report.jobs) |job| {
        try w.print("{s} {s}\n", .{ @tagName(job.status), job.display_name });
        if (job.status == .failed and job.infra_reason != null) {
            // Backend SETUP failed before any step ran — every step below
            // stays "(skipped, exit 0)" with no explanation otherwise.
            try w.print("  (backend setup failed: {s})\n", .{job.infra_reason.?});
        }
        for (job.steps) |step| {
            const selected = flat == selected_step;
            try w.print("{s} {s} ({s}, exit {d})\n", .{ if (selected) ">" else " ", step.name, @tagName(step.status), step.exit_code });
            if (step.status == .failed) {
                if (firstLine(step.stderr) orelse firstLine(step.stdout)) |reason|
                    try w.print("    reason: {s}\n", .{reason});
            }
            if (selected and show_logs) {
                if (step.stdout.len > 0) try w.print("stdout:\n{s}\n", .{step.stdout});
                if (step.stderr.len > 0) try w.print("stderr:\n{s}\n", .{step.stderr});
            }
            flat += 1;
        }
    }
    try w.writeAll("j/k select; l logs; q quit\n> ");
    return out.toOwnedSlice(alloc);
}

/// First non-empty line of `text`, or null (used for a one-line failure
/// reason in the report — e.g. a spawn-failure `err_msg` like "bash not
/// found ..." stored verbatim in the step's stderr).
fn firstLine(text: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len > 0) return line;
    }
    return null;
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

fn envValue(env: []const ir.EnvPair, key: []const u8) ?[]const u8 {
    for (env) |pair| if (std.ascii.eqlIgnoreCase(pair.name, key)) return pair.value;
    return null;
}

fn stepCount(report: engine.Report) usize {
    var count: usize = 0;
    for (report.jobs) |job| count += job.steps.len;
    return count;
}

const ReadResult = union(enum) { command: Command, eof };

fn readCommand(buf: *[512]u8) ReadResult {
    const reader = std.fs.File.stdin().deprecatedReader();
    const line = reader.readUntilDelimiterOrEof(buf, '\n') catch |err| {
        if (err != error.StreamTooLong) return .eof;
        while (true) {
            const byte = reader.readByte() catch break;
            if (byte == '\n') break;
        }
        return .{ .command = .invalid };
    };
    return if (line) |value| .{ .command = parseCommand(value) } else .eof;
}

fn write(bytes: []const u8) void {
    std.fs.File.stdout().deprecatedWriter().writeAll(bytes) catch {};
}

test "parseCommand maps engine and TUI commands" {
    try std.testing.expectEqual(Command.continue_, parseCommand(" c "));
    try std.testing.expectEqual(Command.skip, parseCommand("skip"));
    try std.testing.expectEqual(Command.abort, parseCommand("a"));
    try std.testing.expectEqual(Command.shell, parseCommand("sh"));
    try std.testing.expectEqual(Command.retry, parseCommand("r"));
    try std.testing.expectEqual(Command.toggle_env, parseCommand("e"));
    try std.testing.expectEqual(Command.toggle_workdir, parseCommand("w"));
    try std.testing.expectEqual(Command.up, parseCommand("k"));
    try std.testing.expectEqual(Command.down, parseCommand("j"));
    try std.testing.expectEqual(Command.logs, parseCommand("l"));
    try std.testing.expectEqual(Command.quit, parseCommand("q"));
    try std.testing.expectEqual(Command.invalid, parseCommand("+"));
}

test "parseCommand preserves watch keys" {
    switch (parseCommand("+ TOKEN")) {
        .watch_add => |key| try std.testing.expectEqualStrings("TOKEN", key),
        else => return error.TestUnexpectedResult,
    }
    switch (parseCommand("- TOKEN")) {
        .watch_remove => |key| try std.testing.expectEqualStrings("TOKEN", key),
        else => return error.TestUnexpectedResult,
    }
}

test "selection reducer wraps" {
    var selected: usize = 0;
    try std.testing.expect(reduceSelection(&selected, .up, 3));
    try std.testing.expectEqual(@as(usize, 2), selected);
    try std.testing.expect(reduceSelection(&selected, .down, 3));
    try std.testing.expectEqual(@as(usize, 0), selected);
}

test "renderers show DAG, masked watch, and selected logs" {
    var steps = [_]ir.Step{.{ .id = "s", .name = "compile", .kind = .run, .script = "true" }};
    var no_steps = [_]ir.Step{};
    var needs = [_][]const u8{"build"};
    var jobs = [_]ir.Job{
        .{ .id = "build", .display_name = "Build", .steps = &steps },
        .{ .id = "test", .display_name = "Test", .needs = &needs, .steps = &no_steps },
    };
    const pipeline = ir.Pipeline{ .name = "CI", .source_path = "ci.yml", .jobs = &jobs };
    const env = [_]ir.EnvPair{.{ .name = "env.token", .value = "***" }};
    const state = debug.PromptState{
        .kind = .breakpoint,
        .job_index = 0,
        .job_id = "build",
        .job_name = "Build",
        .step_id = "s",
        .step_name = "compile",
        .step_index = 0,
        .workspace = "work",
        .workdir = "work/sub",
        .effective_env = &env,
    };
    const prompt = try renderPrompt(std.testing.allocator, pipeline, state, .{ .show_workdir = true }, &.{"env.TOKEN"});
    defer std.testing.allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "test <- build") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "watch env.TOKEN=***") != null);

    var failure_state = state;
    failure_state.kind = .failure;
    const failure_prompt = try renderPrompt(std.testing.allocator, pipeline, failure_state, .{}, &.{});
    defer std.testing.allocator.free(failure_prompt);
    try std.testing.expect(std.mem.indexOf(u8, failure_prompt, "r retry") != null);
    try std.testing.expect(std.mem.indexOf(u8, failure_prompt, "s skip") == null);

    var result_steps = [_]engine.StepResult{.{ .name = "compile", .status = .failed, .exit_code = 1, .duration_ms = 1, .stdout = "out", .stderr = "err" }};
    var result_jobs = [_]engine.JobResult{.{ .job_index = 0, .display_name = "Build", .status = .failed, .steps = &result_steps }};
    const report = engine.Report{ .jobs = &result_jobs };
    const rendered = try renderReport(std.testing.allocator, report, 0, true);
    defer std.testing.allocator.free(rendered);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "stdout:\nout") != null);
    try std.testing.expect(std.mem.indexOf(u8, rendered, "stderr:\nerr") != null);
}
