//! Line-oriented Phase 3 debugger primitives. The engine owns breakpoint
//! behavior; this module keeps selector matching and prompt parsing pure and
//! provides the real stdin reader used outside tests.
const std = @import("std");
const backend_mod = @import("backend.zig");
const ir = @import("ir.zig");

pub const Breakpoint = struct {
    job_id: []const u8,
    /// Step id or decimal zero-based index.
    step: []const u8,
};

pub const PromptKind = enum { breakpoint, failure };

/// Per-job status for the TUI's DAG panel, kept separate from
/// `engine.JobStatus` (which only exists once a job finishes): `pending`
/// covers a job that hasn't started or hasn't finished (this codebase
/// doesn't track an in-between "started" flag per job), `running` marks the
/// job that owns the currently-open prompt. ASCII-only glyphs — safe even if
/// a terminal is left at a non-UTF-8 codepage.
pub const JobDagStatus = enum { pending, running, success, failed, skipped };

pub fn dagGlyph(status: JobDagStatus) u8 {
    return switch (status) {
        .pending => '.',
        .running => '>',
        .success => 'v',
        .failed => 'x',
        .skipped => '-',
    };
}

/// Snapshot supplied to injected/UI prompts. Slices remain valid for the
/// duration of the callback; values in `effective_env` are already masked.
pub const PromptState = struct {
    kind: PromptKind,
    job_index: usize,
    job_id: []const u8,
    job_name: []const u8,
    step_id: []const u8,
    step_name: []const u8,
    step_index: usize,
    workspace: []const u8,
    workdir: ?[]const u8,
    effective_env: []const ir.EnvPair,
    // Parallel to the pipeline's job list; empty when the caller hasn't
    // threaded job state in (e.g. direct unit tests of makePromptState).
    job_statuses: []const JobDagStatus = &.{},
};

pub fn matches(bp: Breakpoint, job_id: []const u8, step_id: []const u8, index: usize) bool {
    if (!std.mem.eql(u8, bp.job_id, job_id)) return false;
    if (std.mem.eql(u8, bp.step, step_id)) return true;
    const wanted = std.fmt.parseUnsigned(usize, bp.step, 10) catch return false;
    return wanted == index;
}

pub const PromptCmd = enum {
    continue_,
    skip,
    env,
    workdir,
    shell,
    abort,
    retry,
    invalid,
};

pub fn parseCmd(line: []const u8) PromptCmd {
    const cmd = std.mem.trim(u8, line, " \t\r\n");
    if (cmd.len == 0 or std.mem.eql(u8, cmd, "c") or std.ascii.eqlIgnoreCase(cmd, "continue")) return .continue_;
    if (std.mem.eql(u8, cmd, "s") or std.ascii.eqlIgnoreCase(cmd, "skip")) return .skip;
    if (std.mem.eql(u8, cmd, "e") or std.ascii.eqlIgnoreCase(cmd, "env")) return .env;
    if (std.mem.eql(u8, cmd, "w") or std.ascii.eqlIgnoreCase(cmd, "workdir")) return .workdir;
    if (std.mem.eql(u8, cmd, "sh") or std.ascii.eqlIgnoreCase(cmd, "shell")) return .shell;
    if (std.mem.eql(u8, cmd, "a") or std.ascii.eqlIgnoreCase(cmd, "abort")) return .abort;
    if (std.mem.eql(u8, cmd, "r") or std.ascii.eqlIgnoreCase(cmd, "retry")) return .retry;
    return .invalid;
}

pub fn isTty() bool {
    return std.fs.File.stdin().isTty();
}

pub const PromptFn = *const fn (ctx: ?*anyopaque, state: PromptState) PromptCmd;

/// Read one command from stdin. EOF/read errors are treated as continue so a
/// disappearing terminal cannot wedge an otherwise non-interactive run.
pub fn promptOnce(_: ?*anyopaque, _: PromptState) PromptCmd {
    var buf: [256]u8 = undefined;
    const line = std.fs.File.stdin().deprecatedReader().readUntilDelimiterOrEof(&buf, '\n') catch return .continue_;
    return parseCmd(line orelse return .continue_);
}

/// Dispatch an interactive shell through the selected backend. `false`
/// means the backend deliberately has no shell implementation.
pub fn shell(
    alloc: std.mem.Allocator,
    backend: backend_mod.Backend,
    handle: *backend_mod.JobHandle,
    workdir: ?[]const u8,
    env: []const ir.EnvPair,
) !bool {
    if (backend.vtable.openShell == null) return false;
    try backend.openShell(alloc, handle, workdir, env);
    return true;
}

test "parseCmd accepts breakpoint commands and rejects unknown input" {
    const cases = [_]struct { text: []const u8, want: PromptCmd }{
        .{ .text = "", .want = .continue_ },
        .{ .text = " c ", .want = .continue_ },
        .{ .text = "s", .want = .skip },
        .{ .text = "env", .want = .env },
        .{ .text = "w", .want = .workdir },
        .{ .text = "sh", .want = .shell },
        .{ .text = "a", .want = .abort },
        .{ .text = "r", .want = .retry },
        .{ .text = "wat", .want = .invalid },
    };
    for (cases) |case| try std.testing.expectEqual(case.want, parseCmd(case.text));
}

test "dagGlyph: one ASCII glyph per DAG status" {
    try std.testing.expectEqual(@as(u8, '.'), dagGlyph(.pending));
    try std.testing.expectEqual(@as(u8, '>'), dagGlyph(.running));
    try std.testing.expectEqual(@as(u8, 'v'), dagGlyph(.success));
    try std.testing.expectEqual(@as(u8, 'x'), dagGlyph(.failed));
    try std.testing.expectEqual(@as(u8, '-'), dagGlyph(.skipped));
}

test "matches accepts step id or index in the selected job" {
    try std.testing.expect(matches(.{ .job_id = "build", .step = "compile" }, "build", "compile", 2));
    try std.testing.expect(matches(.{ .job_id = "build", .step = "2" }, "build", "compile", 2));
    try std.testing.expect(!matches(.{ .job_id = "test", .step = "2" }, "build", "compile", 2));
    try std.testing.expect(!matches(.{ .job_id = "build", .step = "3" }, "build", "compile", 2));
}
