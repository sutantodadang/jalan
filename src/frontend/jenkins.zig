//! Jenkins declarative pipeline frontend: tokenizes and parses a Jenkinsfile
//! into the shared IR. No Groovy evaluation: scripted constructs are warned
//! about and skipped (see `warn`). Mirrors the style of frontend/gitlab.zig.
const std = @import("std");
const yaml = @import("../yaml.zig");
const ir = @import("../ir.zig");

pub const ParseError = error{ ParseFailed, OutOfMemory };

fn warn(diags: *yaml.Diags, line: u32, col: u32, comptime fmt: []const u8, args: anytype) !void {
    try diags.add(line, col, "warning: " ++ fmt, args);
}

fn hasHardError(diags: *const yaml.Diags) bool {
    for (diags.list.items) |d| {
        if (!std.mem.startsWith(u8, d.msg, "warning: ")) return true;
    }
    return false;
}

// ---------------------------------------------------------------------------
// Tokenizer
// ---------------------------------------------------------------------------

const TokKind = enum { ident, string, number, symbol, eof };

const Token = struct {
    kind: TokKind,
    text: []const u8,
    line: u32,
    col: u32,
};

const symbol_chars = "{}()=,:[]";

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

const Tokenizer = struct {
    src: []const u8,
    pos: usize = 0,
    line: u32 = 1,
    col: u32 = 1,
    alloc: std.mem.Allocator,
    diags: *yaml.Diags,

    fn advance(self: *Tokenizer) u8 {
        const c = self.src[self.pos];
        self.pos += 1;
        if (c == '\n') {
            self.line += 1;
            self.col = 1;
        } else {
            self.col += 1;
        }
        return c;
    }

    fn advance2(self: *Tokenizer) void {
        _ = self.advance();
        _ = self.advance();
    }

    fn skipWsAndComments(self: *Tokenizer) ParseError!void {
        while (self.pos < self.src.len) {
            const c = self.src[self.pos];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                _ = self.advance();
                continue;
            }
            if (c == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '/') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') _ = self.advance();
                continue;
            }
            if (c == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '*') {
                const start_line = self.line;
                const start_col = self.col;
                self.advance2();
                var closed = false;
                while (self.pos < self.src.len) {
                    if (self.src[self.pos] == '*' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '/') {
                        self.advance2();
                        closed = true;
                        break;
                    }
                    _ = self.advance();
                }
                if (!closed) {
                    try self.diags.add(start_line, start_col, "unterminated block comment", .{});
                    return error.ParseFailed;
                }
                continue;
            }
            break;
        }
    }

    fn scanString(self: *Tokenizer, quote: u8, triple: bool, start_line: u32, start_col: u32) ParseError![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        while (true) {
            if (self.pos >= self.src.len) {
                try self.diags.add(start_line, start_col, "unterminated string literal", .{});
                return error.ParseFailed;
            }
            const c = self.src[self.pos];
            if (triple) {
                if (c == quote and self.pos + 3 <= self.src.len and self.src[self.pos + 1] == quote and self.src[self.pos + 2] == quote) {
                    _ = self.advance();
                    _ = self.advance();
                    _ = self.advance();
                    break;
                }
                try buf.append(self.alloc, c);
                _ = self.advance();
                continue;
            }
            if (c == quote) {
                _ = self.advance();
                break;
            }
            if (c == '\n') {
                try self.diags.add(start_line, start_col, "unterminated string literal", .{});
                return error.ParseFailed;
            }
            if (c == '\\' and self.pos + 1 < self.src.len) {
                const n = self.src[self.pos + 1];
                switch (n) {
                    '\'' => {
                        try buf.append(self.alloc, '\'');
                        self.advance2();
                    },
                    '"' => {
                        try buf.append(self.alloc, '"');
                        self.advance2();
                    },
                    '\\' => {
                        try buf.append(self.alloc, '\\');
                        self.advance2();
                    },
                    'n' => {
                        try buf.append(self.alloc, '\n');
                        self.advance2();
                    },
                    't' => {
                        try buf.append(self.alloc, '\t');
                        self.advance2();
                    },
                    else => {
                        try buf.append(self.alloc, c);
                        _ = self.advance();
                    },
                }
                continue;
            }
            try buf.append(self.alloc, c);
            _ = self.advance();
        }
        return buf.toOwnedSlice(self.alloc);
    }

    fn nextToken(self: *Tokenizer) ParseError!Token {
        try self.skipWsAndComments();
        const line = self.line;
        const col = self.col;
        if (self.pos >= self.src.len) return .{ .kind = .eof, .text = "", .line = line, .col = col };
        const c = self.src[self.pos];
        if (isIdentStart(c)) {
            const start = self.pos;
            while (self.pos < self.src.len and isIdentChar(self.src[self.pos])) _ = self.advance();
            return .{ .kind = .ident, .text = self.src[start..self.pos], .line = line, .col = col };
        }
        if (std.ascii.isDigit(c)) {
            const start = self.pos;
            while (self.pos < self.src.len and (std.ascii.isDigit(self.src[self.pos]) or self.src[self.pos] == '.')) _ = self.advance();
            return .{ .kind = .number, .text = self.src[start..self.pos], .line = line, .col = col };
        }
        if (c == '\'' or c == '"') {
            const quote = c;
            var triple = false;
            if (self.pos + 3 <= self.src.len and self.src[self.pos + 1] == quote and self.src[self.pos + 2] == quote) {
                triple = true;
                _ = self.advance();
                _ = self.advance();
                _ = self.advance();
            } else {
                _ = self.advance();
            }
            const text = try self.scanString(quote, triple, line, col);
            return .{ .kind = .string, .text = text, .line = line, .col = col };
        }
        if (std.mem.indexOfScalar(u8, symbol_chars, c) != null) {
            _ = self.advance();
            return .{ .kind = .symbol, .text = self.src[self.pos - 1 .. self.pos], .line = line, .col = col };
        }
        try self.diags.add(line, col, "unexpected character '{c}'", .{c});
        return error.ParseFailed;
    }
};

fn tokenize(alloc: std.mem.Allocator, src: []const u8, diags: *yaml.Diags) ParseError![]Token {
    var toks: std.ArrayList(Token) = .empty;
    var tz = Tokenizer{ .src = src, .alloc = alloc, .diags = diags };
    while (true) {
        const t = try tz.nextToken();
        try toks.append(alloc, t);
        if (t.kind == .eof) break;
    }
    return toks.toOwnedSlice(alloc);
}

// ---------------------------------------------------------------------------
// Parser: generic statement tree
// ---------------------------------------------------------------------------

const Arg = union(enum) {
    str: []const u8,
    ident: []const u8,
    num: []const u8,
    boolean: bool,
    list: []Arg,
};

const Named = struct { name: []const u8, value: Arg };

const Stmt = struct {
    name: []const u8,
    args: []Arg = &.{},
    named: []Named = &.{},
    block: ?[]Stmt = null,
    assign: ?[]const u8 = null,
    rhs_call: ?[]const u8 = null,
    line: u32,
    col: u32,
};

fn argToStr(arg: Arg) []const u8 {
    return switch (arg) {
        .str => |s| s,
        .ident => |s| s,
        .num => |s| s,
        .boolean => |b| if (b) "true" else "false",
        .list => "",
    };
}

fn literalToStr(lit: Arg) []const u8 {
    return argToStr(lit);
}

const Parser = struct {
    toks: []const Token,
    pos: usize = 0,
    alloc: std.mem.Allocator,
    diags: *yaml.Diags,

    fn peek(self: *Parser) Token {
        return self.toks[self.pos];
    }

    fn peekAt(self: *Parser, offset: usize) Token {
        const i = self.pos + offset;
        if (i >= self.toks.len) return self.toks[self.toks.len - 1];
        return self.toks[i];
    }

    fn advance(self: *Parser) Token {
        const t = self.toks[self.pos];
        if (t.kind != .eof) self.pos += 1;
        return t;
    }

    fn atEnd(self: *Parser) bool {
        return self.peek().kind == .eof;
    }

    fn checkSymbol(self: *Parser, sym: u8) bool {
        const t = self.peek();
        return t.kind == .symbol and t.text.len == 1 and t.text[0] == sym;
    }

    fn expectSymbol(self: *Parser, sym: u8) ParseError!void {
        if (self.checkSymbol(sym)) {
            _ = self.advance();
            return;
        }
        const t = self.peek();
        try self.diags.add(t.line, t.col, "expected '{c}'", .{sym});
        return error.ParseFailed;
    }

    fn isLiteralStart(self: *Parser) bool {
        const t = self.peek();
        return t.kind == .string or t.kind == .number or t.kind == .ident or
            (t.kind == .symbol and t.text.len == 1 and t.text[0] == '[');
    }

    fn parseLiteral(self: *Parser) ParseError!Arg {
        const t = self.peek();
        if (t.kind == .symbol and t.text.len == 1 and t.text[0] == '[') {
            _ = self.advance();
            var items: std.ArrayList(Arg) = .empty;
            if (!self.checkSymbol(']')) {
                while (true) {
                    try items.append(self.alloc, try self.parseLiteral());
                    if (self.checkSymbol(',')) {
                        _ = self.advance();
                        continue;
                    }
                    break;
                }
            }
            try self.expectSymbol(']');
            return .{ .list = try items.toOwnedSlice(self.alloc) };
        }
        switch (t.kind) {
            .string => {
                _ = self.advance();
                return .{ .str = t.text };
            },
            .number => {
                _ = self.advance();
                return .{ .num = t.text };
            },
            .ident => {
                _ = self.advance();
                if (std.mem.eql(u8, t.text, "true")) return .{ .boolean = true };
                if (std.mem.eql(u8, t.text, "false")) return .{ .boolean = false };
                return .{ .ident = t.text };
            },
            else => {
                try self.diags.add(t.line, t.col, "expected a value", .{});
                return error.ParseFailed;
            },
        }
    }

    fn parseArgList(self: *Parser, args: *std.ArrayList(Arg), named: *std.ArrayList(Named)) ParseError!void {
        if (self.checkSymbol(')')) return;
        while (true) {
            if (self.peek().kind == .ident and self.peekAt(1).kind == .symbol and self.peekAt(1).text[0] == ':') {
                const name_tok = self.advance();
                _ = self.advance(); // ':'
                const val = try self.parseLiteral();
                try named.append(self.alloc, .{ .name = name_tok.text, .value = val });
            } else {
                try args.append(self.alloc, try self.parseLiteral());
            }
            if (self.checkSymbol(',')) {
                _ = self.advance();
                continue;
            }
            break;
        }
    }

    fn parseStmt(self: *Parser) ParseError!Stmt {
        const head = self.peek();
        if (head.kind != .ident) {
            try self.diags.add(head.line, head.col, "expected a statement", .{});
            return error.ParseFailed;
        }
        _ = self.advance();

        if (self.checkSymbol('=')) {
            _ = self.advance();
            const rhs = self.peek();
            if (rhs.kind == .ident and self.peekAt(1).kind == .symbol and self.peekAt(1).text[0] == '(') {
                _ = self.advance(); // call name
                _ = self.advance(); // '('
                var args: std.ArrayList(Arg) = .empty;
                var named: std.ArrayList(Named) = .empty;
                try self.parseArgList(&args, &named);
                try self.expectSymbol(')');
                return .{
                    .name = head.text,
                    .rhs_call = rhs.text,
                    .args = try args.toOwnedSlice(self.alloc),
                    .named = try named.toOwnedSlice(self.alloc),
                    .line = head.line,
                    .col = head.col,
                };
            }
            const lit = try self.parseLiteral();
            return .{ .name = head.text, .assign = literalToStr(lit), .line = head.line, .col = head.col };
        }

        var args: std.ArrayList(Arg) = .empty;
        var named: std.ArrayList(Named) = .empty;
        if (self.checkSymbol('(')) {
            _ = self.advance();
            try self.parseArgList(&args, &named);
            try self.expectSymbol(')');
        } else if (self.isLiteralStart()) {
            try args.append(self.alloc, try self.parseLiteral());
            while (self.checkSymbol(',')) {
                _ = self.advance();
                try args.append(self.alloc, try self.parseLiteral());
            }
        }
        var block: ?[]Stmt = null;
        if (self.checkSymbol('{')) {
            _ = self.advance();
            block = try self.parseStmtList('}');
            try self.expectSymbol('}');
        }
        return .{
            .name = head.text,
            .args = try args.toOwnedSlice(self.alloc),
            .named = try named.toOwnedSlice(self.alloc),
            .block = block,
            .line = head.line,
            .col = head.col,
        };
    }

    fn parseStmtList(self: *Parser, closing: u8) ParseError![]Stmt {
        var stmts: std.ArrayList(Stmt) = .empty;
        while (!self.checkSymbol(closing) and !self.atEnd()) {
            try stmts.append(self.alloc, try self.parseStmt());
        }
        if (self.atEnd() and !self.checkSymbol(closing)) {
            const t = self.peek();
            try self.diags.add(t.line, t.col, "unexpected end of file, expected '{c}'", .{closing});
            return error.ParseFailed;
        }
        return stmts.toOwnedSlice(self.alloc);
    }

    fn parseRoot(self: *Parser) ParseError![]Stmt {
        var stmts: std.ArrayList(Stmt) = .empty;
        while (!self.atEnd()) {
            try stmts.append(self.alloc, try self.parseStmt());
        }
        return stmts.toOwnedSlice(self.alloc);
    }
};

fn parseTop(alloc: std.mem.Allocator, source: []const u8, diags: *yaml.Diags) ParseError![]Stmt {
    const toks = try tokenize(alloc, source, diags);
    var p = Parser{ .toks = toks, .alloc = alloc, .diags = diags };
    return p.parseRoot();
}

// ---------------------------------------------------------------------------
// Lowering: declarative semantics -> IR
// ---------------------------------------------------------------------------

const AgentResult = struct {
    image: []const u8 = "",
    runs_on: []const u8 = "",
};

fn lowerAgent(stmt: Stmt, diags: *yaml.Diags) !AgentResult {
    var res = AgentResult{};
    if (stmt.args.len >= 1 and stmt.block == null) {
        const v = argToStr(stmt.args[0]);
        if (std.mem.eql(u8, v, "any") or std.mem.eql(u8, v, "none")) return res;
        try warn(diags, stmt.line, stmt.col, "agent '{s}' is not supported (using native)", .{v});
        return res;
    }
    if (stmt.block) |children| {
        for (children) |c| {
            if (std.mem.eql(u8, c.name, "label")) {
                if (c.args.len > 0) res.runs_on = argToStr(c.args[0]);
            } else if (std.mem.eql(u8, c.name, "docker")) {
                if (c.args.len > 0) {
                    res.image = argToStr(c.args[0]);
                } else if (c.block) |dc| {
                    for (dc) |img_stmt| {
                        if (std.mem.eql(u8, img_stmt.name, "image") and img_stmt.args.len > 0) {
                            res.image = argToStr(img_stmt.args[0]);
                        } else {
                            try warn(diags, img_stmt.line, img_stmt.col, "'{s}' is not simulated (ignored)", .{img_stmt.name});
                        }
                    }
                }
            } else if (std.mem.eql(u8, c.name, "dockerfile")) {
                try warn(diags, c.line, c.col, "dockerfile agents are not supported (using native)", .{});
            } else {
                try warn(diags, c.line, c.col, "agent option '{s}' is not supported (ignored)", .{c.name});
            }
        }
    }
    return res;
}

fn lowerEnvironment(alloc: std.mem.Allocator, stmt: Stmt, diags: *yaml.Diags) ![]ir.EnvPair {
    var out: std.ArrayList(ir.EnvPair) = .empty;
    const children = stmt.block orelse &.{};
    for (children) |c| {
        if (c.rhs_call) |call_name| {
            if (std.mem.eql(u8, call_name, "credentials")) {
                try warn(diags, c.line, c.col, "credentials() is not supported (variable '{s}' unset)", .{c.name});
            } else {
                try warn(diags, c.line, c.col, "'{s}()' is not supported (variable '{s}' unset)", .{ call_name, c.name });
            }
            continue;
        }
        if (c.assign) |val| {
            try out.append(alloc, .{ .name = c.name, .value = val });
        } else {
            try diags.add(c.line, c.col, "invalid environment entry '{s}'", .{c.name});
        }
    }
    return out.toOwnedSlice(alloc);
}

fn rewriteInterp(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOf(u8, s, "${") == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    const prefixes = [_][]const u8{ "env.", "params." };
    while (i < s.len) {
        if (s[i] == '$' and i + 1 < s.len and s[i + 1] == '{') {
            const start = i + 2;
            var matched = false;
            for (prefixes) |prefix| {
                if (start + prefix.len <= s.len and std.mem.eql(u8, s[start .. start + prefix.len], prefix)) {
                    const name_start = start + prefix.len;
                    var k = name_start;
                    while (k < s.len and isIdentChar(s[k])) k += 1;
                    if (k > name_start and k < s.len and s[k] == '}') {
                        try out.appendSlice(alloc, "${");
                        try out.appendSlice(alloc, s[name_start..k]);
                        try out.append(alloc, '}');
                        i = k + 1;
                        matched = true;
                        break;
                    }
                }
            }
            if (matched) continue;
            try out.append(alloc, s[i]);
            i += 1;
            continue;
        }
        try out.append(alloc, s[i]);
        i += 1;
    }
    return out.toOwnedSlice(alloc);
}

fn mergeEnv(alloc: std.mem.Allocator, base: []const ir.EnvPair, extra: []const ir.EnvPair) ![]ir.EnvPair {
    if (extra.len == 0) return alloc.dupe(ir.EnvPair, base);
    var out: std.ArrayList(ir.EnvPair) = .empty;
    try out.appendSlice(alloc, base);
    try out.appendSlice(alloc, extra);
    return out.toOwnedSlice(alloc);
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

fn lowerSteps(
    alloc: std.mem.Allocator,
    block: []const Stmt,
    workdir: ?[]const u8,
    env: []const ir.EnvPair,
    counts: *std.StringArrayHashMapUnmanaged(u32),
    diags: *yaml.Diags,
) ParseError![]ir.Step {
    var out: std.ArrayList(ir.Step) = .empty;
    for (block) |s| try lowerOneStep(alloc, s, workdir, env, counts, &out, diags);
    return out.toOwnedSlice(alloc);
}

fn lowerOneStep(
    alloc: std.mem.Allocator,
    s: Stmt,
    workdir: ?[]const u8,
    env: []const ir.EnvPair,
    counts: *std.StringArrayHashMapUnmanaged(u32),
    out: *std.ArrayList(ir.Step),
    diags: *yaml.Diags,
) ParseError!void {
    if (std.mem.eql(u8, s.name, "sh") or std.mem.eql(u8, s.name, "bat") or
        std.mem.eql(u8, s.name, "powershell") or std.mem.eql(u8, s.name, "pwsh"))
    {
        var script: ?[]const u8 = null;
        if (s.args.len > 0) script = argToStr(s.args[0]);
        for (s.named) |n| {
            if (std.mem.eql(u8, n.name, "script")) {
                script = argToStr(n.value);
            } else {
                try warn(diags, s.line, s.col, "{s} argument '{s}' is ignored", .{ s.name, n.name });
            }
        }
        if (script == null) {
            try diags.add(s.line, s.col, "'{s}' requires a script argument", .{s.name});
            return;
        }
        const shell: ?[]const u8 = if (std.mem.eql(u8, s.name, "bat"))
            "cmd"
        else if (std.mem.eql(u8, s.name, "powershell") or std.mem.eql(u8, s.name, "pwsh"))
            "pwsh"
        else
            null;
        const id = try nextStepId(alloc, counts, s.name);
        try out.append(alloc, .{
            .id = id,
            .name = id,
            .kind = .run,
            .script = try rewriteInterp(alloc, script.?),
            .shell = shell,
            .env = try alloc.dupe(ir.EnvPair, env),
            .workdir = workdir,
            .src_line = s.line,
        });
        return;
    }
    if (std.mem.eql(u8, s.name, "echo")) {
        const text = if (s.args.len > 0) argToStr(s.args[0]) else "";
        const id = try nextStepId(alloc, counts, s.name);
        try out.append(alloc, .{
            .id = id,
            .name = id,
            .kind = .run,
            .script = try std.fmt.allocPrint(alloc, "echo {s}", .{try rewriteInterp(alloc, text)}),
            .env = try alloc.dupe(ir.EnvPair, env),
            .workdir = workdir,
            .src_line = s.line,
        });
        return;
    }
    if (std.mem.eql(u8, s.name, "sleep")) {
        var time_val: []const u8 = "0";
        if (s.args.len > 0) time_val = argToStr(s.args[0]);
        for (s.named) |n| if (std.mem.eql(u8, n.name, "time")) {
            time_val = argToStr(n.value);
        };
        const id = try nextStepId(alloc, counts, s.name);
        try out.append(alloc, .{
            .id = id,
            .name = id,
            .kind = .run,
            .script = try std.fmt.allocPrint(alloc, "sleep {s}", .{time_val}),
            .env = try alloc.dupe(ir.EnvPair, env),
            .workdir = workdir,
            .src_line = s.line,
        });
        return;
    }
    if (std.mem.eql(u8, s.name, "dir")) {
        var inner_workdir = workdir;
        if (s.args.len > 0) {
            if (workdir != null) {
                try warn(diags, s.line, s.col, "nested dir is not supported (ignored)", .{});
            } else {
                inner_workdir = argToStr(s.args[0]);
            }
        }
        if (s.block) |children| {
            const inner = try lowerSteps(alloc, children, inner_workdir, env, counts, diags);
            try out.appendSlice(alloc, inner);
        }
        return;
    }
    if (std.mem.eql(u8, s.name, "withEnv")) {
        var pairs: std.ArrayList(ir.EnvPair) = .empty;
        if (s.args.len > 0) {
            switch (s.args[0]) {
                .list => |items| for (items) |it| {
                    const raw = argToStr(it);
                    if (std.mem.indexOfScalar(u8, raw, '=')) |eq| {
                        try pairs.append(alloc, .{ .name = raw[0..eq], .value = raw[eq + 1 ..] });
                    } else {
                        try warn(diags, s.line, s.col, "withEnv entry '{s}' is malformed (ignored)", .{raw});
                    }
                },
                else => try warn(diags, s.line, s.col, "withEnv requires a list argument (ignored)", .{}),
            }
        }
        const merged = try mergeEnv(alloc, env, pairs.items);
        if (s.block) |children| {
            const inner = try lowerSteps(alloc, children, workdir, merged, counts, diags);
            try out.appendSlice(alloc, inner);
        }
        return;
    }
    if (std.mem.eql(u8, s.name, "script")) {
        try warn(diags, s.line, s.col, "scripted 'script' blocks are not supported (skipped)", .{});
        return;
    }
    if (std.mem.eql(u8, s.name, "checkout")) {
        try warn(diags, s.line, s.col, "checkout is not needed locally (skipped)", .{});
        return;
    }
    if (std.mem.eql(u8, s.name, "timeout") or std.mem.eql(u8, s.name, "retry")) {
        try warn(diags, s.line, s.col, "'{s}' is not simulated (inner steps run)", .{s.name});
        if (s.block) |children| {
            const inner = try lowerSteps(alloc, children, workdir, env, counts, diags);
            try out.appendSlice(alloc, inner);
        }
        return;
    }
    try warn(diags, s.line, s.col, "step '{s}' is not supported (skipped)", .{s.name});
}

const StageCtx = struct {
    env: []const ir.EnvPair,
    agent: AgentResult,
};

fn lowerPostBucket(alloc: std.mem.Allocator, existing: []ir.Step, body: []const Stmt, diags: *yaml.Diags) ![]ir.Step {
    var counts: std.StringArrayHashMapUnmanaged(u32) = .empty;
    const s = try lowerSteps(alloc, body, null, &.{}, &counts, diags);
    var tmp: std.ArrayList(ir.Step) = .empty;
    try tmp.appendSlice(alloc, existing);
    try tmp.appendSlice(alloc, s);
    return tmp.toOwnedSlice(alloc);
}

fn lowerStage(
    alloc: std.mem.Allocator,
    stmt: Stmt,
    needs: [][]const u8,
    ctx: StageCtx,
    pipeline_name: []const u8,
    allow_parallel: bool,
    jobs: *std.ArrayList(ir.Job),
    seen_names: *std.StringArrayHashMapUnmanaged(void),
    diags: *yaml.Diags,
) ParseError![][]const u8 {
    if (stmt.args.len == 0) {
        try diags.add(stmt.line, stmt.col, "stage requires a name", .{});
        return &.{};
    }
    const name = argToStr(stmt.args[0]);
    if (seen_names.contains(name)) {
        try diags.add(stmt.line, stmt.col, "duplicate stage name '{s}'", .{name});
    } else {
        try seen_names.put(alloc, name, {});
    }

    const body = stmt.block orelse &.{};
    var local_env: std.ArrayList(ir.EnvPair) = .empty;
    try local_env.appendSlice(alloc, ctx.env);
    var local_agent = ctx.agent;
    var parallel_stmt: ?Stmt = null;
    var steps_stmt: ?Stmt = null;
    var post_stmt: ?Stmt = null;
    var when_seen = false;

    for (body) |c| {
        if (std.mem.eql(u8, c.name, "environment")) {
            try local_env.appendSlice(alloc, try lowerEnvironment(alloc, c, diags));
        } else if (std.mem.eql(u8, c.name, "agent")) {
            const a = try lowerAgent(c, diags);
            if (a.image.len > 0) local_agent.image = a.image;
            if (a.runs_on.len > 0) local_agent.runs_on = a.runs_on;
        } else if (std.mem.eql(u8, c.name, "steps")) {
            steps_stmt = c;
        } else if (std.mem.eql(u8, c.name, "parallel")) {
            parallel_stmt = c;
        } else if (std.mem.eql(u8, c.name, "when")) {
            when_seen = true;
        } else if (std.mem.eql(u8, c.name, "post")) {
            post_stmt = c;
        } else if (std.mem.eql(u8, c.name, "input")) {
            try warn(diags, c.line, c.col, "input gates are not simulated (stage runs)", .{});
        } else {
            try warn(diags, c.line, c.col, "'{s}' is not simulated (ignored)", .{c.name});
        }
    }
    if (when_seen) try warn(diags, stmt.line, stmt.col, "'when' conditions are not evaluated locally (stage runs)", .{});

    if (parallel_stmt) |ps| {
        if (!allow_parallel) {
            try warn(diags, stmt.line, stmt.col, "nested parallel is not supported (skipped)", .{});
            return &.{};
        }
        if (steps_stmt != null) {
            try diags.add(stmt.line, stmt.col, "stage '{s}' cannot have both 'parallel' and 'steps'", .{name});
        }
        var ids: std.ArrayList([]const u8) = .empty;
        const children = ps.block orelse &.{};
        for (children) |child| {
            if (!std.mem.eql(u8, child.name, "stage")) {
                try warn(diags, child.line, child.col, "'{s}' is not simulated (ignored)", .{child.name});
                continue;
            }
            const child_ids = try lowerStage(alloc, child, needs, .{ .env = local_env.items, .agent = local_agent }, pipeline_name, false, jobs, seen_names, diags);
            try ids.appendSlice(alloc, child_ids);
        }
        return ids.toOwnedSlice(alloc);
    }

    if (steps_stmt == null) {
        try diags.add(stmt.line, stmt.col, "stage '{s}' has no steps", .{name});
        return &.{};
    }

    var post_always: []ir.Step = &.{};
    var post_success: []ir.Step = &.{};
    if (post_stmt) |ps| {
        if (ps.block) |post_children| {
            for (post_children) |pc| {
                if (std.mem.eql(u8, pc.name, "always") or std.mem.eql(u8, pc.name, "cleanup")) {
                    post_always = try lowerPostBucket(alloc, post_always, pc.block orelse &.{}, diags);
                } else if (std.mem.eql(u8, pc.name, "success")) {
                    post_success = try lowerPostBucket(alloc, post_success, pc.block orelse &.{}, diags);
                } else {
                    try warn(diags, pc.line, pc.col, "post '{s}' is not simulated (ignored)", .{pc.name});
                }
            }
        }
    }
    for (post_always) |*st| {
        st.cond = "always()";
        st.continue_on_error = true;
    }

    var counts: std.StringArrayHashMapUnmanaged(u32) = .empty;
    const steps = try lowerSteps(alloc, steps_stmt.?.block orelse &.{}, null, &.{}, &counts, diags);

    var all_steps: std.ArrayList(ir.Step) = .empty;
    try all_steps.appendSlice(alloc, steps);
    try all_steps.appendSlice(alloc, post_always);
    try all_steps.appendSlice(alloc, post_success);

    var final_env: std.ArrayList(ir.EnvPair) = .empty;
    try final_env.append(alloc, .{ .name = "BUILD_NUMBER", .value = "1" });
    try final_env.append(alloc, .{ .name = "JOB_NAME", .value = pipeline_name });
    try final_env.appendSlice(alloc, local_env.items);

    try jobs.append(alloc, .{
        .id = name,
        .display_name = name,
        .runs_on = local_agent.runs_on,
        .needs = needs,
        .env = try final_env.toOwnedSlice(alloc),
        .steps = try all_steps.toOwnedSlice(alloc),
        .container_image = local_agent.image,
        .provider = .jenkins,
        .src_line = stmt.line,
    });

    var out_ids: std.ArrayList([]const u8) = .empty;
    try out_ids.append(alloc, name);
    return out_ids.toOwnedSlice(alloc);
}

fn lowerStages(
    alloc: std.mem.Allocator,
    stages_stmt: Stmt,
    pipeline_env: []const ir.EnvPair,
    pipeline_agent: AgentResult,
    pipeline_name: []const u8,
    diags: *yaml.Diags,
) ParseError![]ir.Job {
    var jobs: std.ArrayList(ir.Job) = .empty;
    var seen_names: std.StringArrayHashMapUnmanaged(void) = .empty;
    var prev_needs: [][]const u8 = &.{};
    const children = stages_stmt.block orelse &.{};
    if (children.len == 0) {
        try diags.add(stages_stmt.line, stages_stmt.col, "pipeline has no stages", .{});
        return jobs.toOwnedSlice(alloc);
    }
    for (children) |c| {
        if (!std.mem.eql(u8, c.name, "stage")) {
            try warn(diags, c.line, c.col, "'{s}' is not simulated (ignored)", .{c.name});
            continue;
        }
        const ids = try lowerStage(alloc, c, prev_needs, .{ .env = pipeline_env, .agent = pipeline_agent }, pipeline_name, true, &jobs, &seen_names, diags);
        if (ids.len > 0) prev_needs = ids;
    }
    return jobs.toOwnedSlice(alloc);
}

pub fn parsePipeline(alloc: std.mem.Allocator, source_path: []const u8, source: []const u8, diags: *yaml.Diags) ParseError!ir.Pipeline {
    const top = try parseTop(alloc, source, diags);
    const is_pipeline = top.len == 1 and std.mem.eql(u8, top[0].name, "pipeline") and top[0].block != null;
    if (!is_pipeline) {
        var hint = false;
        for (top) |s| if (std.mem.eql(u8, s.name, "node")) {
            hint = true;
        };
        const line: u32 = if (top.len > 0) top[0].line else 1;
        const col: u32 = if (top.len > 0) top[0].col else 1;
        if (hint) {
            try diags.add(line, col, "Jenkinsfile must contain a single declarative 'pipeline' block (scripted pipelines are not supported)", .{});
        } else {
            try diags.add(line, col, "Jenkinsfile must contain a single declarative 'pipeline' block", .{});
        }
        return error.ParseFailed;
    }

    const pipeline_stmt = top[0];
    const body = pipeline_stmt.block.?;

    var pipeline_agent = AgentResult{};
    var pipeline_env: std.ArrayList(ir.EnvPair) = .empty;
    var stages_stmt: ?Stmt = null;

    for (body) |c| {
        if (std.mem.eql(u8, c.name, "agent")) {
            pipeline_agent = try lowerAgent(c, diags);
        } else if (std.mem.eql(u8, c.name, "environment")) {
            try pipeline_env.appendSlice(alloc, try lowerEnvironment(alloc, c, diags));
        } else if (std.mem.eql(u8, c.name, "stages")) {
            stages_stmt = c;
        } else if (std.mem.eql(u8, c.name, "post")) {
            try warn(diags, c.line, c.col, "pipeline-level post is not simulated (ignored)", .{});
        } else if (std.mem.eql(u8, c.name, "options") or std.mem.eql(u8, c.name, "parameters") or
            std.mem.eql(u8, c.name, "triggers") or std.mem.eql(u8, c.name, "tools"))
        {
            try warn(diags, c.line, c.col, "'{s}' is not simulated (ignored)", .{c.name});
        } else {
            try warn(diags, c.line, c.col, "'{s}' is not supported (ignored)", .{c.name});
        }
    }

    const pipeline_name = "pipeline";
    var jobs: []ir.Job = &.{};
    if (stages_stmt) |ss| {
        jobs = try lowerStages(alloc, ss, pipeline_env.items, pipeline_agent, pipeline_name, diags);
    } else {
        try diags.add(pipeline_stmt.line, pipeline_stmt.col, "pipeline has no stages", .{});
    }

    if (hasHardError(diags)) return error.ParseFailed;

    return .{ .name = pipeline_name, .source_path = source_path, .jobs = jobs };
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn findJob(pipeline: ir.Pipeline, id: []const u8) ?ir.Job {
    for (pipeline.jobs) |j| if (std.mem.eql(u8, j.id, id)) return j;
    return null;
}

fn findEnv(pairs: []const ir.EnvPair, name: []const u8) ?[]const u8 {
    var i = pairs.len;
    var result: ?[]const u8 = null;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, pairs[i].name, name)) {
            result = pairs[i].value;
            break;
        }
    }
    return result;
}

test "two sequential stages produce jobs with sequential needs and provider metadata" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\pipeline {
        \\    agent any
        \\    stages {
        \\        stage('Build') {
        \\            steps { sh 'echo build' }
        \\        }
        \\        stage('Test') {
        \\            steps { sh 'echo test' }
        \\        }
        \\    }
        \\}
    ;
    const pipeline = try parsePipeline(a, "Jenkinsfile", source, &diags);
    try std.testing.expectEqual(@as(usize, 2), pipeline.jobs.len);
    try std.testing.expectEqualStrings("Build", pipeline.jobs[0].id);
    try std.testing.expectEqualStrings("Test", pipeline.jobs[1].id);
    try std.testing.expectEqual(@as(usize, 1), pipeline.jobs[1].needs.len);
    try std.testing.expectEqualStrings("Build", pipeline.jobs[1].needs[0]);
    try std.testing.expectEqual(ir.Provider.jenkins, pipeline.jobs[0].provider);
    try std.testing.expectEqualStrings("1", findEnv(pipeline.jobs[0].env, "BUILD_NUMBER").?);
    try std.testing.expectEqualStrings("pipeline", findEnv(pipeline.jobs[0].env, "JOB_NAME").?);
}

test "parallel stages fan out from and fan back into sequential stages" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\pipeline {
        \\    agent any
        \\    stages {
        \\        stage('A') { steps { sh 'echo a' } }
        \\        stage('Fanout') {
        \\            parallel {
        \\                stage('B1') { steps { sh 'echo b1' } }
        \\                stage('B2') { steps { sh 'echo b2' } }
        \\            }
        \\        }
        \\        stage('C') { steps { sh 'echo c' } }
        \\    }
        \\}
    ;
    const pipeline = try parsePipeline(a, "Jenkinsfile", source, &diags);
    try std.testing.expectEqual(@as(usize, 4), pipeline.jobs.len);
    const b1 = findJob(pipeline, "B1").?;
    const b2 = findJob(pipeline, "B2").?;
    const c = findJob(pipeline, "C").?;
    try std.testing.expectEqualStrings("A", b1.needs[0]);
    try std.testing.expectEqualStrings("A", b2.needs[0]);
    try std.testing.expectEqual(@as(usize, 2), c.needs.len);
    try std.testing.expectEqualStrings("B1", c.needs[0]);
    try std.testing.expectEqualStrings("B2", c.needs[1]);
}

test "environment cascades pipeline then stage with stage winning on collision" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\pipeline {
        \\    agent any
        \\    environment { A = 'pipeline-val' }
        \\    stages {
        \\        stage('Build') {
        \\            environment { A = 'stage-val' }
        \\            steps { sh 'echo hi' }
        \\        }
        \\    }
        \\}
    ;
    const pipeline = try parsePipeline(a, "Jenkinsfile", source, &diags);
    const job = pipeline.jobs[0];
    try std.testing.expectEqualStrings("stage-val", findEnv(job.env, "A").?);
}

test "docker agent image at pipeline level with stage-level override, and label sets runs_on" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\pipeline {
        \\    agent { docker { image 'node:18' } }
        \\    stages {
        \\        stage('Build') {
        \\            agent { docker { image 'node:20' } }
        \\            steps { sh 'echo hi' }
        \\        }
        \\        stage('Test') {
        \\            agent { label 'linux-x64' }
        \\            steps { sh 'echo hi' }
        \\        }
        \\    }
        \\}
    ;
    const pipeline = try parsePipeline(a, "Jenkinsfile", source, &diags);
    const build = findJob(pipeline, "Build").?;
    const test_job = findJob(pipeline, "Test").?;
    try std.testing.expectEqualStrings("node:20", build.container_image);
    try std.testing.expectEqualStrings("node:18", test_job.container_image);
    try std.testing.expectEqualStrings("linux-x64", test_job.runs_on);
}

test "sh accepts single, double, triple-quoted, and script: named form; returnStdout warns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\pipeline {
        \\    agent any
        \\    stages {
        \\        stage('Build') {
        \\            steps {
        \\                sh 'echo single'
        \\                sh "echo double"
        \\                sh '''echo triple'''
        \\                sh(script: 'echo named', returnStdout: true)
        \\            }
        \\        }
        \\    }
        \\}
    ;
    const pipeline = try parsePipeline(a, "Jenkinsfile", source, &diags);
    const job = pipeline.jobs[0];
    try std.testing.expectEqual(@as(usize, 4), job.steps.len);
    try std.testing.expectEqualStrings("echo single", job.steps[0].script);
    try std.testing.expectEqualStrings("echo double", job.steps[1].script);
    try std.testing.expectEqualStrings("echo triple", job.steps[2].script);
    try std.testing.expectEqualStrings("echo named", job.steps[3].script);
    var found_warn = false;
    for (diags.list.items) |d| if (std.mem.indexOf(u8, d.msg, "returnStdout") != null) {
        found_warn = true;
    };
    try std.testing.expect(found_warn);
}

test "bat maps to cmd shell, powershell/pwsh map to pwsh shell" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\pipeline {
        \\    agent any
        \\    stages {
        \\        stage('Build') {
        \\            steps {
        \\                bat 'dir'
        \\                powershell 'Get-ChildItem'
        \\                pwsh 'Get-ChildItem'
        \\            }
        \\        }
        \\    }
        \\}
    ;
    const pipeline = try parsePipeline(a, "Jenkinsfile", source, &diags);
    const job = pipeline.jobs[0];
    try std.testing.expectEqualStrings("cmd", job.steps[0].shell.?);
    try std.testing.expectEqualStrings("pwsh", job.steps[1].shell.?);
    try std.testing.expectEqualStrings("pwsh", job.steps[2].shell.?);
}

test "echo step lowers to an echo script" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\pipeline {
        \\    agent any
        \\    stages {
        \\        stage('Build') { steps { echo 'hello there' } }
        \\    }
        \\}
    ;
    const pipeline = try parsePipeline(a, "Jenkinsfile", source, &diags);
    try std.testing.expectEqualStrings("echo hello there", pipeline.jobs[0].steps[0].script);
}

test "dir sets workdir on inner steps; withEnv sets env on inner steps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\pipeline {
        \\    agent any
        \\    stages {
        \\        stage('Build') {
        \\            steps {
        \\                dir('subdir') {
        \\                    sh 'echo in-subdir'
        \\                }
        \\                withEnv(['FOO=bar', 'BAZ=qux']) {
        \\                    sh 'echo with-env'
        \\                }
        \\            }
        \\        }
        \\    }
        \\}
    ;
    const pipeline = try parsePipeline(a, "Jenkinsfile", source, &diags);
    const job = pipeline.jobs[0];
    try std.testing.expectEqualStrings("subdir", job.steps[0].workdir.?);
    try std.testing.expectEqualStrings("FOO", job.steps[1].env[0].name);
    try std.testing.expectEqualStrings("bar", job.steps[1].env[0].value);
    try std.testing.expectEqualStrings("BAZ", job.steps[1].env[1].name);
    try std.testing.expectEqualStrings("qux", job.steps[1].env[1].value);
}

test "stage post always appends a step with always() cond and continue_on_error; post failure warns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\pipeline {
        \\    agent any
        \\    stages {
        \\        stage('Build') {
        \\            steps { sh 'echo build' }
        \\            post {
        \\                always { sh 'echo cleanup' }
        \\                failure { sh 'echo notify' }
        \\            }
        \\        }
        \\    }
        \\}
    ;
    const pipeline = try parsePipeline(a, "Jenkinsfile", source, &diags);
    const job = pipeline.jobs[0];
    try std.testing.expectEqual(@as(usize, 2), job.steps.len);
    try std.testing.expectEqualStrings("always()", job.steps[1].cond.?);
    try std.testing.expect(job.steps[1].continue_on_error);
    var found_warn = false;
    for (diags.list.items) |d| if (std.mem.indexOf(u8, d.msg, "post 'failure'") != null) {
        found_warn = true;
    };
    try std.testing.expect(found_warn);
}

test "when block warns but the stage still runs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\pipeline {
        \\    agent any
        \\    stages {
        \\        stage('Build') {
        \\            when { branch 'main' }
        \\            steps { sh 'echo build' }
        \\        }
        \\    }
        \\}
    ;
    const pipeline = try parsePipeline(a, "Jenkinsfile", source, &diags);
    try std.testing.expectEqual(@as(usize, 1), pipeline.jobs.len);
    var found_warn = false;
    for (diags.list.items) |d| if (std.mem.indexOf(u8, d.msg, "'when'") != null) {
        found_warn = true;
    };
    try std.testing.expect(found_warn);
}

test "credentials() in environment warns and leaves the variable unset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\pipeline {
        \\    agent any
        \\    environment { TOKEN = credentials('my-token') }
        \\    stages {
        \\        stage('Build') { steps { sh 'echo build' } }
        \\    }
        \\}
    ;
    const pipeline = try parsePipeline(a, "Jenkinsfile", source, &diags);
    try std.testing.expect(findEnv(pipeline.jobs[0].env, "TOKEN") == null);
    var found_warn = false;
    for (diags.list.items) |d| if (std.mem.indexOf(u8, d.msg, "credentials()") != null) {
        found_warn = true;
    };
    try std.testing.expect(found_warn);
}

test "${env.X} and ${params.Y} rewrite to ${X} and ${Y} in sh scripts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\pipeline {
        \\    agent any
        \\    stages {
        \\        stage('Build') { steps { sh 'echo ${env.FOO} ${params.BAR} ${OTHER}' } }
        \\    }
        \\}
    ;
    const pipeline = try parsePipeline(a, "Jenkinsfile", source, &diags);
    try std.testing.expectEqualStrings("echo ${FOO} ${BAR} ${OTHER}", pipeline.jobs[0].steps[0].script);
}

test "scripted 'script' block warns and is skipped; checkout warns and is skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\pipeline {
        \\    agent any
        \\    stages {
        \\        stage('Build') {
        \\            steps {
        \\                checkout scm
        \\                script { x = 1 }
        \\                sh 'echo after'
        \\            }
        \\        }
        \\    }
        \\}
    ;
    const pipeline = try parsePipeline(a, "Jenkinsfile", source, &diags);
    try std.testing.expectEqual(@as(usize, 1), pipeline.jobs[0].steps.len);
    try std.testing.expectEqualStrings("echo after", pipeline.jobs[0].steps[0].script);
    var checkout_warn = false;
    var script_warn = false;
    for (diags.list.items) |d| {
        if (std.mem.indexOf(u8, d.msg, "checkout") != null) checkout_warn = true;
        if (std.mem.indexOf(u8, d.msg, "scripted 'script'") != null) script_warn = true;
    }
    try std.testing.expect(checkout_warn and script_warn);
}

test "top-level 'node' block is rejected with a scripted-pipeline hint" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\node {
        \\    sh 'echo hi'
        \\}
    ;
    try std.testing.expectError(error.ParseFailed, parsePipeline(a, "Jenkinsfile", source, &diags));
    var found = false;
    for (diags.list.items) |d| if (std.mem.indexOf(u8, d.msg, "scripted pipelines are not supported") != null) {
        found = true;
    };
    try std.testing.expect(found);
}

test "missing stages is a hard parse failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\pipeline {
        \\    agent any
        \\}
    ;
    try std.testing.expectError(error.ParseFailed, parsePipeline(a, "Jenkinsfile", source, &diags));
}

test "duplicate stage names are a hard parse failure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\pipeline {
        \\    agent any
        \\    stages {
        \\        stage('Build') { steps { sh 'echo 1' } }
        \\        stage('Build') { steps { sh 'echo 2' } }
        \\    }
        \\}
    ;
    try std.testing.expectError(error.ParseFailed, parsePipeline(a, "Jenkinsfile", source, &diags));
}

test "unbalanced braces fail to parse without crashing or hanging" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\pipeline {
        \\    agent any
        \\    stages {
        \\        stage('Build') { steps { sh 'echo 1' }
        \\    }
        \\}
    ;
    try std.testing.expectError(error.ParseFailed, parsePipeline(a, "Jenkinsfile", source, &diags));
}

test "line and block comments are skipped by the tokenizer" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\// top comment
        \\pipeline {
        \\    /* block
        \\       comment */
        \\    agent any // trailing
        \\    stages {
        \\        stage('Build') {
        \\            steps { sh 'echo build' } // step comment
        \\        }
        \\    }
        \\}
    ;
    const pipeline = try parsePipeline(a, "Jenkinsfile", source, &diags);
    try std.testing.expectEqual(@as(usize, 1), pipeline.jobs.len);
    try std.testing.expectEqualStrings("echo build", pipeline.jobs[0].steps[0].script);
}
