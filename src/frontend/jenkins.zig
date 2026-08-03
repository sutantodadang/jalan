//! Jenkins declarative pipeline frontend: tokenizes and parses a Jenkinsfile
//! into the shared IR. No Groovy evaluation: scripted constructs are warned
//! about and skipped (see `warn`). Mirrors the style of frontend/gitlab.zig.
const std = @import("std");
const yaml = @import("../yaml.zig");
const ir = @import("../ir.zig");
const groovy_ast = @import("../groovy/ast.zig");
const groovy_interp = @import("../groovy/interp.zig");

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
    // Set right after tokenizing an ident "script" that is immediately
    // followed (modulo whitespace/comments) by '{': tells the NEXT call to
    // nextToken() (which will produce that '{' symbol) to also raw-skip the
    // block's entire interior at the byte level rather than tokenizing it.
    // `script { ... }` bodies are arbitrary Groovy, which this declarative
    // tokenizer's limited character set (see `symbol_chars`) cannot lex --
    // they're re-parsed by the Groovy front end at lowering time instead,
    // using the byte range this produces (see Stmt.block_start/block_end).
    pending_script_open: bool = false,

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

    /// Non-consuming lookahead: does the next significant (non-ws,
    /// non-comment) character start with '{'? Used to detect `script {`.
    fn peekIsOpenBrace(self: *Tokenizer) bool {
        var i = self.pos;
        while (i < self.src.len) {
            const c = self.src[i];
            if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
                i += 1;
                continue;
            }
            if (c == '/' and i + 1 < self.src.len and self.src[i + 1] == '/') {
                while (i < self.src.len and self.src[i] != '\n') i += 1;
                continue;
            }
            if (c == '/' and i + 1 < self.src.len and self.src[i + 1] == '*') {
                i += 2;
                while (i + 1 < self.src.len and !(self.src[i] == '*' and self.src[i + 1] == '/')) i += 1;
                i = @min(i + 2, self.src.len);
                continue;
            }
            break;
        }
        return i < self.src.len and self.src[i] == '{';
    }

    /// Raw byte-level skip of a `script { ... }` body: advances `self.pos`
    /// from just after the opening '{' (already consumed by the caller) to
    /// exactly the matching '}' (left unconsumed, so the caller's normal
    /// symbol tokenizing produces it). Tracks brace depth while skipping over
    /// comments and string literals so braces inside them don't miscount.
    /// Never fails on characters this tokenizer wouldn't otherwise accept --
    /// that's the point: the interior is arbitrary Groovy, re-parsed later by
    /// the Groovy front end from the recorded byte range.
    fn skipScriptBody(self: *Tokenizer) ParseError!void {
        var depth: usize = 1;
        while (true) {
            if (self.pos >= self.src.len) {
                try self.diags.add(self.line, self.col, "unterminated 'script' block", .{});
                return error.ParseFailed;
            }
            const c = self.src[self.pos];
            if (c == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '/') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') _ = self.advance();
                continue;
            }
            if (c == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '*') {
                self.advance2();
                while (self.pos < self.src.len and !(self.src[self.pos] == '*' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '/')) _ = self.advance();
                if (self.pos < self.src.len) self.advance2();
                continue;
            }
            if (c == '\'' or c == '"') {
                const quote = c;
                _ = self.advance();
                var triple = false;
                if (self.pos + 1 < self.src.len and self.src[self.pos] == quote and self.src[self.pos + 1] == quote) {
                    triple = true;
                    self.advance2();
                }
                while (self.pos < self.src.len) {
                    const sc = self.src[self.pos];
                    if (sc == '\\' and self.pos + 1 < self.src.len) {
                        self.advance2();
                        continue;
                    }
                    if (triple) {
                        if (sc == quote and self.pos + 2 < self.src.len and self.src[self.pos + 1] == quote and self.src[self.pos + 2] == quote) {
                            self.advance2();
                            _ = self.advance();
                            break;
                        }
                        _ = self.advance();
                        continue;
                    }
                    if (sc == quote) {
                        _ = self.advance();
                        break;
                    }
                    if (sc == '\n') break;
                    _ = self.advance();
                }
                continue;
            }
            if (c == '{') {
                depth += 1;
                _ = self.advance();
                continue;
            }
            if (c == '}') {
                depth -= 1;
                if (depth == 0) return;
                _ = self.advance();
                continue;
            }
            _ = self.advance();
        }
    }

    fn nextToken(self: *Tokenizer) ParseError!Token {
        try self.skipWsAndComments();
        const line = self.line;
        const col = self.col;
        if (self.pos >= self.src.len) return .{ .kind = .eof, .text = "", .line = line, .col = col };
        const c = self.src[self.pos];
        if (self.pending_script_open and c == '{') {
            self.pending_script_open = false;
            const brace_pos = self.pos;
            _ = self.advance();
            const brace_text = self.src[brace_pos .. brace_pos + 1];
            try self.skipScriptBody();
            return .{ .kind = .symbol, .text = brace_text, .line = line, .col = col };
        }
        if (isIdentStart(c)) {
            const start = self.pos;
            while (self.pos < self.src.len and isIdentChar(self.src[self.pos])) _ = self.advance();
            const text = self.src[start..self.pos];
            if (std.mem.eql(u8, text, "script") and self.peekIsOpenBrace()) {
                self.pending_script_open = true;
            }
            return .{ .kind = .ident, .text = text, .line = line, .col = col };
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
    // Byte offsets into the original source, just inside the block's braces
    // (i.e. `source[block_start..block_end]` is the raw text between `{` and
    // `}`, exclusive of both). Only meaningful when `block != null`. Used to
    // re-parse `script { ... }` bodies as Groovy at lowering time.
    block_start: usize = 0,
    block_end: usize = 0,
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
    source: []const u8 = &.{},

    /// Byte offset of a symbol token within `source`. Only valid for symbol
    /// tokens: their `.text` is always a 1-byte slice of `source` itself
    /// (unlike string tokens, which are copied into freshly allocated
    /// buffers), so pointer subtraction recovers the offset.
    fn byteOffset(self: *Parser, tok: Token) usize {
        return @intFromPtr(tok.text.ptr) - @intFromPtr(self.source.ptr);
    }

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
        var block_start: usize = 0;
        var block_end: usize = 0;
        if (self.checkSymbol('{')) {
            const open_tok = self.advance();
            block_start = self.byteOffset(open_tok) + 1;
            block = try self.parseStmtList('}');
            block_end = self.byteOffset(self.peek());
            try self.expectSymbol('}');
        }
        return .{
            .name = head.text,
            .args = try args.toOwnedSlice(self.alloc),
            .named = try named.toOwnedSlice(self.alloc),
            .block = block,
            .block_start = block_start,
            .block_end = block_end,
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
    var p = Parser{ .toks = toks, .alloc = alloc, .diags = diags, .source = source };
    return p.parseRoot();
}

/// Cheap pre-check to route a Jenkinsfile to the declarative or scripted
/// lowering path without running the (possibly failing) declarative parser
/// on genuinely scripted sources. Manually skims whitespace/comments and
/// looks at the very first identifier token: declarative Jenkinsfiles always
/// open with `pipeline { ... }`; anything else (`node { ... }`, bare
/// statements, etc.) is scripted Groovy.
fn firstTopLevelIdentIsPipeline(source: []const u8) bool {
    var i: usize = 0;
    while (i < source.len) {
        const c = source[i];
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            i += 1;
            continue;
        }
        if (c == '/' and i + 1 < source.len and source[i + 1] == '/') {
            while (i < source.len and source[i] != '\n') i += 1;
            continue;
        }
        if (c == '/' and i + 1 < source.len and source[i + 1] == '*') {
            i += 2;
            while (i + 1 < source.len and !(source[i] == '*' and source[i + 1] == '/')) i += 1;
            i = @min(i + 2, source.len);
            continue;
        }
        break;
    }
    if (i >= source.len or !isIdentStart(source[i])) return false;
    const start = i;
    while (i < source.len and isIdentChar(source[i])) i += 1;
    return std.mem.eql(u8, source[start..i], "pipeline");
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
    source: []const u8,
    declarative_env: []const ir.EnvPair,
) ParseError![]ir.Step {
    var out: std.ArrayList(ir.Step) = .empty;
    for (block) |s| try lowerOneStep(alloc, s, workdir, env, counts, &out, diags, source, declarative_env);
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
    source: []const u8,
    declarative_env: []const ir.EnvPair,
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
            const inner = try lowerSteps(alloc, children, inner_workdir, env, counts, diags, source, declarative_env);
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
            const inner = try lowerSteps(alloc, children, workdir, merged, counts, diags, source, declarative_env);
            try out.appendSlice(alloc, inner);
        }
        return;
    }
    if (std.mem.eql(u8, s.name, "script")) {
        try lowerScriptBlock(alloc, s, workdir, env, counts, out, diags, source, declarative_env);
        return;
    }
    if (std.mem.eql(u8, s.name, "checkout")) {
        try warn(diags, s.line, s.col, "checkout is not needed locally (skipped)", .{});
        return;
    }
    if (std.mem.eql(u8, s.name, "timeout") or std.mem.eql(u8, s.name, "retry")) {
        try warn(diags, s.line, s.col, "'{s}' is not simulated (inner steps run)", .{s.name});
        if (s.block) |children| {
            const inner = try lowerSteps(alloc, children, workdir, env, counts, diags, source, declarative_env);
            try out.appendSlice(alloc, inner);
        }
        return;
    }
    try warn(diags, s.line, s.col, "step '{s}' is not supported (skipped)", .{s.name});
}

/// Executes a declarative `script { ... }` step block as real Groovy: the raw
/// source between the braces is re-parsed and run through the same Lowering
/// host used for scripted pipelines (mode = .script_block), so `sh`/`echo`/etc
/// calls append steps directly into the enclosing job's step list `out`.
/// `stage`/`node`/`parallel` are disallowed inside a script block (declarative
/// stage structure is already fixed by the surrounding DSL).
fn lowerScriptBlock(
    alloc: std.mem.Allocator,
    s: Stmt,
    workdir: ?[]const u8,
    env: []const ir.EnvPair,
    counts: *std.StringArrayHashMapUnmanaged(u32),
    out: *std.ArrayList(ir.Step),
    diags: *yaml.Diags,
    source: []const u8,
    declarative_env: []const ir.EnvPair,
) ParseError!void {
    const raw = source[s.block_start..s.block_end];
    const stmts = try groovy_ast.parse(alloc, raw, diags);

    const lowering = try alloc.create(Lowering);
    lowering.* = .{
        .alloc = alloc,
        .diags = diags,
        .mode = .script_block,
        .out_steps = out,
        .step_counts = counts,
    };
    if (workdir) |wd| try lowering.workdir_stack.append(alloc, wd);

    const host = groovy_interp.Host{ .ctx = @ptrCast(lowering), .call = hostCall };
    const interp = try groovy_interp.Interp.init(alloc, diags, host);
    try seedGlobals(alloc, interp, env, declarative_env);

    _ = interp.run(stmts) catch |e| switch (e) {
        error.EvalFailed => return error.ParseFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

/// Seeds the Groovy globals (`env`, `params`, `currentBuild`) available to
/// scripted/`script{}` bodies. `env` is pre-populated with BUILD_NUMBER/
/// JOB_NAME plus any declarative pipeline/stage `environment{}` pairs and
/// step-local (withEnv) pairs, so `env.FOO` reads inside Groovy see the same
/// values the declarative side already computed. `env` wins over
/// `declarative_env` on key collision (mirrors the engine's "step env wins"
/// precedence).
fn seedGlobals(alloc: std.mem.Allocator, interp: *groovy_interp.Interp, env: []const ir.EnvPair, declarative_env: []const ir.EnvPair) !void {
    const env_map = try alloc.create(groovy_interp.ValueMap);
    env_map.* = .{};
    try env_map.put(alloc, "BUILD_NUMBER", .{ .string = "1" });
    try env_map.put(alloc, "JOB_NAME", .{ .string = "pipeline" });
    for (declarative_env) |p| try env_map.put(alloc, p.name, .{ .string = p.value });
    for (env) |p| try env_map.put(alloc, p.name, .{ .string = p.value });
    try interp.setGlobal("env", .{ .map = env_map });

    const params_map = try alloc.create(groovy_interp.ValueMap);
    params_map.* = .{};
    try interp.setGlobal("params", .{ .map = params_map });

    const cb_map = try alloc.create(groovy_interp.ValueMap);
    cb_map.* = .{};
    try cb_map.put(alloc, "result", .{ .string = "SUCCESS" });
    try interp.setGlobal("currentBuild", .{ .map = cb_map });

    // `checkout scm` is idiomatic Jenkins syntax referencing the implicit
    // per-job SCM config global; its value is never inspected (checkout is
    // always warned-and-skipped), so any placeholder works.
    try interp.setGlobal("scm", .{ .nul = {} });
}

const StageCtx = struct {
    env: []const ir.EnvPair,
    agent: AgentResult,
};

fn lowerPostBucket(alloc: std.mem.Allocator, existing: []ir.Step, body: []const Stmt, diags: *yaml.Diags, source: []const u8) ![]ir.Step {
    var counts: std.StringArrayHashMapUnmanaged(u32) = .empty;
    const s = try lowerSteps(alloc, body, null, &.{}, &counts, diags, source, &.{});
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
    source: []const u8,
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
            const child_ids = try lowerStage(alloc, child, needs, .{ .env = local_env.items, .agent = local_agent }, pipeline_name, false, jobs, seen_names, diags, source);
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
                    post_always = try lowerPostBucket(alloc, post_always, pc.block orelse &.{}, diags, source);
                } else if (std.mem.eql(u8, pc.name, "success")) {
                    post_success = try lowerPostBucket(alloc, post_success, pc.block orelse &.{}, diags, source);
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
    const steps = try lowerSteps(alloc, steps_stmt.?.block orelse &.{}, null, &.{}, &counts, diags, source, local_env.items);

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
    source: []const u8,
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
        const ids = try lowerStage(alloc, c, prev_needs, .{ .env = pipeline_env, .agent = pipeline_agent }, pipeline_name, true, &jobs, &seen_names, diags, source);
        if (ids.len > 0) prev_needs = ids;
    }
    return jobs.toOwnedSlice(alloc);
}

/// Entry point: routes to the declarative or scripted lowering path based on
/// the source's first top-level identifier (see `firstTopLevelIdentIsPipeline`).
pub fn parsePipeline(alloc: std.mem.Allocator, source_path: []const u8, source: []const u8, diags: *yaml.Diags) ParseError!ir.Pipeline {
    if (firstTopLevelIdentIsPipeline(source)) {
        return parseDeclarative(alloc, source_path, source, diags);
    }
    return parseScripted(alloc, source_path, source, diags);
}

fn parseDeclarative(alloc: std.mem.Allocator, source_path: []const u8, source: []const u8, diags: *yaml.Diags) ParseError!ir.Pipeline {
    const top = try parseTop(alloc, source, diags);
    const is_pipeline = top.len == 1 and std.mem.eql(u8, top[0].name, "pipeline") and top[0].block != null;
    if (!is_pipeline) {
        const line: u32 = if (top.len > 0) top[0].line else 1;
        const col: u32 = if (top.len > 0) top[0].col else 1;
        try diags.add(line, col, "Jenkinsfile must contain a single declarative 'pipeline' block", .{});
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
        jobs = try lowerStages(alloc, ss, pipeline_env.items, pipeline_agent, pipeline_name, diags, source);
    } else {
        try diags.add(pipeline_stmt.line, pipeline_stmt.col, "pipeline has no stages", .{});
    }

    if (hasHardError(diags)) return error.ParseFailed;

    return .{ .name = pipeline_name, .source_path = source_path, .jobs = jobs };
}

// ---------------------------------------------------------------------------
// Scripted pipeline lowering: `node { stage('X') { sh '...' } ... }` runs
// through the Groovy interpreter (src/groovy/interp.zig) with a Host that
// lowers each recognized DSL call directly to IR. Also backs declarative
// `script { ... }` step blocks (see `lowerScriptBlock` above), which share
// the same Host/dispatch but append into an existing job's step list instead
// of building jobs of their own.
// ---------------------------------------------------------------------------

const LowerMode = enum { scripted, script_block };

const Lowering = struct {
    alloc: std.mem.Allocator,
    diags: *yaml.Diags,
    mode: LowerMode,

    // .scripted: jobs are built up here as `stage`/implicit-`main` blocks close.
    jobs: std.ArrayList(ir.Job) = .empty,
    prev_needs: [][]const u8 = &.{},
    cur_stage_id: ?[]const u8 = null,
    cur_steps: std.ArrayList(ir.Step) = .empty,
    cur_runs_on: []const u8 = "",
    node_depth: u32 = 0,
    in_parallel_branch: bool = false,
    stage_name_counts: std.StringArrayHashMapUnmanaged(u32) = .empty,

    // .script_block: steps append directly into the enclosing declarative job.
    out_steps: ?*std.ArrayList(ir.Step) = null,

    // Shared context stacks (both modes).
    workdir_stack: std.ArrayList([]const u8) = .empty,
    with_env_stack: std.ArrayList([]const ir.EnvPair) = .empty,
    // Pointer so declarative `script{}` blocks share the enclosing job's
    // counter — step ids must stay unique across both lowering paths.
    step_counts: *std.StringArrayHashMapUnmanaged(u32),

    fn currentWorkdir(self: *Lowering) ?[]const u8 {
        if (self.workdir_stack.items.len == 0) return null;
        return self.workdir_stack.items[self.workdir_stack.items.len - 1];
    }

    fn snapshotEnv(self: *Lowering, interp: *groovy_interp.Interp) ![]ir.EnvPair {
        var out: std.ArrayList(ir.EnvPair) = .empty;
        if (interp.getGlobal("env")) |v| {
            if (v == .map) {
                var it = v.map.iterator();
                while (it.next()) |entry| {
                    const val_str = try interp.toStr(entry.value_ptr.*);
                    try out.append(self.alloc, .{ .name = entry.key_ptr.*, .value = val_str });
                }
            }
        }
        for (self.with_env_stack.items) |frame| try out.appendSlice(self.alloc, frame);
        return out.toOwnedSlice(self.alloc);
    }

    fn appendStep(self: *Lowering, step: ir.Step) !void {
        switch (self.mode) {
            .scripted => {
                if (self.cur_stage_id == null) {
                    self.cur_stage_id = try self.uniqueStageName("main", step.src_line, 1);
                    self.cur_steps = .empty;
                }
                try self.cur_steps.append(self.alloc, step);
            },
            .script_block => try self.out_steps.?.append(self.alloc, step),
        }
    }

    fn predefinedEnv(self: *Lowering) ![]ir.EnvPair {
        var out: std.ArrayList(ir.EnvPair) = .empty;
        try out.append(self.alloc, .{ .name = "BUILD_NUMBER", .value = "1" });
        try out.append(self.alloc, .{ .name = "JOB_NAME", .value = "pipeline" });
        return out.toOwnedSlice(self.alloc);
    }

    /// Deduplicates stage/branch job ids: first use of a name passes through
    /// unchanged; repeats are suffixed "-2", "-3", ... with a warning.
    fn uniqueStageName(self: *Lowering, name: []const u8, line: u32, col: u32) ![]const u8 {
        const gop = try self.stage_name_counts.getOrPut(self.alloc, name);
        if (!gop.found_existing) {
            gop.value_ptr.* = 1;
            return name;
        }
        gop.value_ptr.* += 1;
        const n = gop.value_ptr.*;
        const suffixed = try std.fmt.allocPrint(self.alloc, "{s}-{d}", .{ name, n });
        try warn(self.diags, line, col, "duplicate stage name '{s}' (renamed to '{s}')", .{ name, suffixed });
        return suffixed;
    }

    /// Finalizes whatever stage is currently open (explicit or the lazily
    /// created implicit "main") into a Job, chains `prev_needs` onto it, and
    /// clears the current-stage state.
    fn commitCurrentStage(self: *Lowering) !void {
        const id = self.cur_stage_id orelse return;
        try self.jobs.append(self.alloc, .{
            .id = id,
            .display_name = id,
            .runs_on = self.cur_runs_on,
            .needs = self.prev_needs,
            .env = try self.predefinedEnv(),
            .steps = try self.cur_steps.toOwnedSlice(self.alloc),
            .provider = .jenkins,
        });
        const needs = try self.alloc.alloc([]const u8, 1);
        needs[0] = id;
        self.prev_needs = needs;
        self.cur_stage_id = null;
        self.cur_steps = .empty;
    }
};

fn trailingClosure(args: []groovy_interp.Value) ?groovy_interp.ClosureVal {
    if (args.len == 0) return null;
    return switch (args[args.len - 1]) {
        .closure => |c| c,
        else => null,
    };
}

fn hostCall(ctx: *anyopaque, interp: *groovy_interp.Interp, name: []const u8, args: []groovy_interp.Value, named: []const groovy_interp.NamedArg, line: u32, col: u32) groovy_interp.InterpError!groovy_interp.Value {
    const self: *Lowering = @ptrCast(@alignCast(ctx));
    const diags = self.diags;
    const nul = groovy_interp.Value{ .nul = {} };

    if (self.mode == .script_block and (std.mem.eql(u8, name, "stage") or std.mem.eql(u8, name, "node") or std.mem.eql(u8, name, "parallel"))) {
        try diags.add(line, col, "groovy: '{s}' is not allowed inside script blocks", .{name});
        return error.EvalFailed;
    }

    if (std.mem.eql(u8, name, "node")) {
        const closure = trailingClosure(args);
        const label_count: usize = if (closure != null) args.len - 1 else args.len;
        var label: []const u8 = "";
        if (label_count >= 1 and args[0] == .string) label = args[0].string;
        if (self.node_depth > 0) {
            try warn(diags, line, col, "nested node blocks are not supported (inner runs in same context)", .{});
        }
        self.node_depth += 1;
        const prev_runs_on = self.cur_runs_on;
        if (label.len > 0) self.cur_runs_on = label;
        defer {
            self.node_depth -= 1;
            self.cur_runs_on = prev_runs_on;
        }
        if (closure) |c| _ = try interp.callClosure(c, &.{});
        return nul;
    }

    if (std.mem.eql(u8, name, "stage")) {
        const closure = trailingClosure(args);
        const name_count: usize = if (closure != null) args.len - 1 else args.len;
        if (name_count == 0) {
            try diags.add(line, col, "stage requires a name", .{});
            return error.EvalFailed;
        }
        const stage_name = try interp.toStr(args[0]);
        if (self.in_parallel_branch) {
            try warn(diags, line, col, "nested stage inside parallel branch is flattened", .{});
            if (closure) |c| _ = try interp.callClosure(c, &.{});
            return nul;
        }
        if (self.cur_stage_id != null) try self.commitCurrentStage();
        self.cur_stage_id = try self.uniqueStageName(stage_name, line, col);
        self.cur_steps = .empty;
        if (closure) |c| _ = try interp.callClosure(c, &.{});
        try self.commitCurrentStage();
        return nul;
    }

    if (std.mem.eql(u8, name, "parallel")) {
        if (self.cur_stage_id != null) try self.commitCurrentStage();
        const base_needs = self.prev_needs;
        const Branch = struct { name: []const u8, closure: groovy_interp.ClosureVal };
        var branches: std.ArrayList(Branch) = .empty;
        for (named) |n| {
            if (std.mem.eql(u8, n.name, "failFast")) {
                try warn(diags, line, col, "parallel(failFast:) is not simulated (ignored)", .{});
                continue;
            }
            if (n.value != .closure) {
                try warn(diags, line, col, "parallel branch '{s}' is not a closure (ignored)", .{n.name});
                continue;
            }
            try branches.append(self.alloc, .{ .name = n.name, .closure = n.value.closure });
        }
        for (args) |a| {
            if (a == .map) {
                var it = a.map.iterator();
                while (it.next()) |entry| {
                    if (entry.value_ptr.* != .closure) continue;
                    try branches.append(self.alloc, .{ .name = entry.key_ptr.*, .closure = entry.value_ptr.*.closure });
                }
            }
        }
        var branch_ids: std.ArrayList([]const u8) = .empty;
        for (branches.items) |b| {
            const id = try self.uniqueStageName(b.name, line, col);
            self.cur_stage_id = id;
            self.cur_steps = .empty;
            const prev_in_parallel = self.in_parallel_branch;
            self.in_parallel_branch = true;
            _ = try interp.callClosure(b.closure, &.{});
            self.in_parallel_branch = prev_in_parallel;
            try self.jobs.append(self.alloc, .{
                .id = id,
                .display_name = id,
                .runs_on = self.cur_runs_on,
                .needs = base_needs,
                .env = try self.predefinedEnv(),
                .steps = try self.cur_steps.toOwnedSlice(self.alloc),
                .provider = .jenkins,
            });
            try branch_ids.append(self.alloc, id);
            self.cur_stage_id = null;
            self.cur_steps = .empty;
        }
        self.prev_needs = try branch_ids.toOwnedSlice(self.alloc);
        return nul;
    }

    if (std.mem.eql(u8, name, "sh") or std.mem.eql(u8, name, "bat") or
        std.mem.eql(u8, name, "powershell") or std.mem.eql(u8, name, "pwsh"))
    {
        var script: ?[]const u8 = null;
        for (args) |a| if (a == .string) {
            script = a.string;
        };
        var return_stdout = false;
        var return_status = false;
        for (named) |n| {
            if (std.mem.eql(u8, n.name, "script")) {
                script = try interp.toStr(n.value);
            } else if (std.mem.eql(u8, n.name, "returnStdout")) {
                return_stdout = groovy_interp.truthy(n.value);
            } else if (std.mem.eql(u8, n.name, "returnStatus")) {
                return_status = groovy_interp.truthy(n.value);
            } else {
                try warn(diags, line, col, "{s} argument '{s}' is ignored", .{ name, n.name });
            }
        }
        if (script == null) {
            try diags.add(line, col, "'{s}' requires a script argument", .{name});
            return error.EvalFailed;
        }
        const shell: ?[]const u8 = if (std.mem.eql(u8, name, "bat"))
            "cmd"
        else if (std.mem.eql(u8, name, "powershell") or std.mem.eql(u8, name, "pwsh"))
            "pwsh"
        else
            null;
        const id = try nextStepId(self.alloc, self.step_counts, name);
        try self.appendStep(.{
            .id = id,
            .name = id,
            .kind = .run,
            .script = script.?,
            .shell = shell,
            .env = try self.snapshotEnv(interp),
            .workdir = self.currentWorkdir(),
            .src_line = line,
        });
        if (return_stdout or return_status) {
            try warn(diags, line, col, "{s} with returnStdout/returnStatus is not available at lowering time (empty result)", .{name});
        }
        if (return_stdout) return .{ .string = "" };
        if (return_status) return .{ .int = 0 };
        return nul;
    }

    if (std.mem.eql(u8, name, "echo") or std.mem.eql(u8, name, "println")) {
        const text = if (args.len > 0) try interp.toStr(args[0]) else "";
        const id = try nextStepId(self.alloc, self.step_counts, "echo");
        try self.appendStep(.{
            .id = id,
            .name = id,
            .kind = .run,
            .script = try std.fmt.allocPrint(self.alloc, "echo {s}", .{text}),
            .env = try self.snapshotEnv(interp),
            .workdir = self.currentWorkdir(),
            .src_line = line,
        });
        return nul;
    }

    if (std.mem.eql(u8, name, "sleep")) {
        var time_val: []const u8 = "0";
        if (args.len > 0) time_val = try interp.toStr(args[0]);
        for (named) |n| if (std.mem.eql(u8, n.name, "time")) {
            time_val = try interp.toStr(n.value);
        };
        const id = try nextStepId(self.alloc, self.step_counts, "sleep");
        try self.appendStep(.{
            .id = id,
            .name = id,
            .kind = .run,
            .script = try std.fmt.allocPrint(self.alloc, "sleep {s}", .{time_val}),
            .env = try self.snapshotEnv(interp),
            .workdir = self.currentWorkdir(),
            .src_line = line,
        });
        return nul;
    }

    if (std.mem.eql(u8, name, "error")) {
        const msg = if (args.len > 0) try interp.toStr(args[0]) else "";
        const id = try nextStepId(self.alloc, self.step_counts, "error");
        try self.appendStep(.{
            .id = id,
            .name = id,
            .kind = .run,
            .script = try std.fmt.allocPrint(self.alloc, "echo {s}; exit 1", .{msg}),
            .env = try self.snapshotEnv(interp),
            .workdir = self.currentWorkdir(),
            .src_line = line,
        });
        return nul;
    }

    if (std.mem.eql(u8, name, "dir")) {
        const closure = trailingClosure(args);
        var path: []const u8 = "";
        if (args.len >= 1 and args[0] == .string) path = args[0].string;
        const parent = self.currentWorkdir();
        const joined = if (parent) |p| (if (path.len > 0) try std.fs.path.join(self.alloc, &.{ p, path }) else p) else path;
        try self.workdir_stack.append(self.alloc, joined);
        if (closure) |c| _ = try interp.callClosure(c, &.{});
        _ = self.workdir_stack.pop();
        return nul;
    }

    if (std.mem.eql(u8, name, "withEnv")) {
        const closure = trailingClosure(args);
        var pairs: std.ArrayList(ir.EnvPair) = .empty;
        if (args.len >= 1 and args[0] == .list) {
            for (args[0].list.items) |it| {
                const raw = try interp.toStr(it);
                if (std.mem.indexOfScalar(u8, raw, '=')) |eq| {
                    try pairs.append(self.alloc, .{ .name = raw[0..eq], .value = raw[eq + 1 ..] });
                } else {
                    try warn(diags, line, col, "withEnv entry '{s}' is malformed (ignored)", .{raw});
                }
            }
        }
        try self.with_env_stack.append(self.alloc, try pairs.toOwnedSlice(self.alloc));
        if (closure) |c| _ = try interp.callClosure(c, &.{});
        _ = self.with_env_stack.pop();
        return nul;
    }

    const skip_names = [_][]const u8{ "input", "checkout", "properties", "archiveArtifacts", "junit", "stash", "unstash", "build", "emailext" };
    for (skip_names) |kw| if (std.mem.eql(u8, name, kw)) {
        try warn(diags, line, col, "'{s}' is not supported (skipped)", .{name});
        return nul;
    };

    const sim_names = [_][]const u8{ "timeout", "retry", "catchError", "ansiColor", "withCredentials" };
    for (sim_names) |kw| if (std.mem.eql(u8, name, kw)) {
        const closure = trailingClosure(args);
        if (closure) |c| {
            try warn(diags, line, col, "'{s}' is not simulated (inner steps run)", .{name});
            if (std.mem.eql(u8, name, "withCredentials")) {
                try warn(diags, line, col, "credentials are unavailable in withCredentials (skipped)", .{});
            }
            _ = try interp.callClosure(c, &.{});
        } else {
            try warn(diags, line, col, "'{s}' is not supported (skipped)", .{name});
        }
        return nul;
    };

    try warn(diags, line, col, "step '{s}' is not supported (skipped)", .{name});
    return nul;
}

fn parseScripted(alloc: std.mem.Allocator, source_path: []const u8, source: []const u8, diags: *yaml.Diags) ParseError!ir.Pipeline {
    const stmts = try groovy_ast.parse(alloc, source, diags);

    const scripted_counts = try alloc.create(std.StringArrayHashMapUnmanaged(u32));
    scripted_counts.* = .empty;
    const lowering = try alloc.create(Lowering);
    lowering.* = .{ .alloc = alloc, .diags = diags, .mode = .scripted, .step_counts = scripted_counts };

    const host = groovy_interp.Host{ .ctx = @ptrCast(lowering), .call = hostCall };
    const interp = try groovy_interp.Interp.init(alloc, diags, host);
    try seedGlobals(alloc, interp, &.{}, &.{});

    _ = interp.run(stmts) catch |e| switch (e) {
        error.EvalFailed => return error.ParseFailed,
        error.OutOfMemory => return error.OutOfMemory,
    };

    if (lowering.cur_stage_id != null) try lowering.commitCurrentStage();

    if (hasHardError(diags)) return error.ParseFailed;

    var total_steps: usize = 0;
    for (lowering.jobs.items) |j| total_steps += j.steps.len;
    if (total_steps == 0) {
        try diags.add(1, 1, "scripted pipeline produced no steps", .{});
        return error.ParseFailed;
    }

    return .{ .name = "pipeline", .source_path = source_path, .jobs = try lowering.jobs.toOwnedSlice(alloc) };
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

test "checkout warns and is skipped; declarative script { } step runs for real" {
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
        \\                script { sh 'from-script' }
        \\                sh 'echo after'
        \\            }
        \\        }
        \\    }
        \\}
    ;
    const pipeline = try parsePipeline(a, "Jenkinsfile", source, &diags);
    try std.testing.expectEqual(@as(usize, 2), pipeline.jobs[0].steps.len);
    try std.testing.expectEqualStrings("from-script", pipeline.jobs[0].steps[0].script);
    try std.testing.expectEqualStrings("echo after", pipeline.jobs[0].steps[1].script);
    var checkout_warn = false;
    for (diags.list.items) |d| if (std.mem.indexOf(u8, d.msg, "checkout") != null) {
        checkout_warn = true;
    };
    try std.testing.expect(checkout_warn);
}

test "declarative script { } supports a for-loop; nested stage() inside script is rejected" {
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
        \\                script { for (i in 1..2) { sh "s${i}" } }
        \\            }
        \\        }
        \\    }
        \\}
    ;
    const pipeline = try parsePipeline(a, "Jenkinsfile", source, &diags);
    try std.testing.expectEqual(@as(usize, 2), pipeline.jobs[0].steps.len);
    try std.testing.expectEqualStrings("s1", pipeline.jobs[0].steps[0].script);
    try std.testing.expectEqualStrings("s2", pipeline.jobs[0].steps[1].script);

    var diags2 = yaml.Diags.init(a);
    const bad_source =
        \\pipeline {
        \\    agent any
        \\    stages {
        \\        stage('Build') {
        \\            steps { script { stage('x') {} } }
        \\        }
        \\    }
        \\}
    ;
    try std.testing.expectError(error.ParseFailed, parsePipeline(a, "Jenkinsfile", bad_source, &diags2));
    var found = false;
    for (diags2.list.items) |d| if (std.mem.indexOf(u8, d.msg, "not allowed inside script blocks") != null) {
        found = true;
    };
    try std.testing.expect(found);
}

test "scripted: node + two stages + sh lower to two jobs with sequential needs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\node {
        \\    stage('Build') { sh 'echo build' }
        \\    stage('Test') { sh 'echo test' }
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
}

test "scripted: steps before any stage() open an implicit 'main' job" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\node {
        \\    sh 'echo hi'
        \\}
    ;
    const pipeline = try parsePipeline(a, "Jenkinsfile", source, &diags);
    try std.testing.expectEqual(@as(usize, 1), pipeline.jobs.len);
    try std.testing.expectEqualStrings("main", pipeline.jobs[0].id);
    try std.testing.expectEqualStrings("echo hi", pipeline.jobs[0].steps[0].script);
}

test "scripted: for-in loop over a range renders interpolated scripts" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\node {
        \\    stage('Build') {
        \\        for (i in 1..3) { sh "echo ${i}" }
        \\    }
        \\}
    ;
    const pipeline = try parsePipeline(a, "Jenkinsfile", source, &diags);
    try std.testing.expectEqual(@as(usize, 3), pipeline.jobs[0].steps.len);
    try std.testing.expectEqualStrings("echo 1", pipeline.jobs[0].steps[0].script);
    try std.testing.expectEqualStrings("echo 2", pipeline.jobs[0].steps[1].script);
    try std.testing.expectEqualStrings("echo 3", pipeline.jobs[0].steps[2].script);
}

test "scripted: a def closure invoked inside a stage lands its step in that stage" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\def deploy = { sh 'd' }
        \\node {
        \\    stage('D') { deploy() }
        \\}
    ;
    const pipeline = try parsePipeline(a, "Jenkinsfile", source, &diags);
    const d = findJob(pipeline, "D").?;
    try std.testing.expectEqual(@as(usize, 1), d.steps.len);
    try std.testing.expectEqualStrings("d", d.steps[0].script);
}

test "scripted: env.FOO assignment between steps only affects later steps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\node {
        \\    stage('Build') {
        \\        sh 'echo first'
        \\        env.FOO = 'x'
        \\        sh 'echo second'
        \\    }
        \\}
    ;
    const pipeline = try parsePipeline(a, "Jenkinsfile", source, &diags);
    const job = pipeline.jobs[0];
    try std.testing.expect(findEnv(job.steps[0].env, "FOO") == null);
    try std.testing.expectEqualStrings("x", findEnv(job.steps[1].env, "FOO").?);
}

test "scripted: dir() sets workdir, withEnv() sets step env" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\node {
        \\    stage('Build') {
        \\        dir('sub') { sh 'a' }
        \\        withEnv(['A=1']) { sh 'b' }
        \\    }
        \\}
    ;
    const pipeline = try parsePipeline(a, "Jenkinsfile", source, &diags);
    const job = pipeline.jobs[0];
    try std.testing.expectEqualStrings("sub", job.steps[0].workdir.?);
    try std.testing.expectEqualStrings("1", findEnv(job.steps[1].env, "A").?);
}

test "scripted: parallel() between stages fans out and fans back in" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\node {
        \\    stage('A') { sh 'echo a' }
        \\    parallel(b1: { sh 'echo b1' }, b2: { sh 'echo b2' })
        \\    stage('C') { sh 'echo c' }
        \\}
    ;
    const pipeline = try parsePipeline(a, "Jenkinsfile", source, &diags);
    const b1 = findJob(pipeline, "b1").?;
    const b2 = findJob(pipeline, "b2").?;
    const c = findJob(pipeline, "C").?;
    try std.testing.expectEqualStrings("A", b1.needs[0]);
    try std.testing.expectEqualStrings("A", b2.needs[0]);
    try std.testing.expectEqual(@as(usize, 2), c.needs.len);
    try std.testing.expectEqualStrings("b1", c.needs[0]);
    try std.testing.expectEqualStrings("b2", c.needs[1]);
}

test "scripted: sh(script:, returnStdout: true) warns but still creates the step" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\node {
        \\    stage('Build') {
        \\        def out = sh(script: 'x', returnStdout: true)
        \\        echo "got:${out}"
        \\    }
        \\}
    ;
    const pipeline = try parsePipeline(a, "Jenkinsfile", source, &diags);
    const job = pipeline.jobs[0];
    try std.testing.expectEqual(@as(usize, 2), job.steps.len);
    try std.testing.expectEqualStrings("x", job.steps[0].script);
    try std.testing.expectEqualStrings("echo got:", job.steps[1].script);
    var found_warn = false;
    for (diags.list.items) |d| if (std.mem.indexOf(u8, d.msg, "returnStdout") != null) {
        found_warn = true;
    };
    try std.testing.expect(found_warn);
}

test "scripted: error('msg') lowers to a step whose script contains exit 1" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\node {
        \\    stage('Build') { error('boom') }
        \\}
    ;
    const pipeline = try parsePipeline(a, "Jenkinsfile", source, &diags);
    try std.testing.expect(std.mem.indexOf(u8, pipeline.jobs[0].steps[0].script, "exit 1") != null);
}

test "scripted: checkout warns skipped; timeout() runs its inner steps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\node {
        \\    stage('Build') {
        \\        checkout scm
        \\        timeout(10) { sh 'x' }
        \\    }
        \\}
    ;
    const pipeline = try parsePipeline(a, "Jenkinsfile", source, &diags);
    try std.testing.expectEqual(@as(usize, 1), pipeline.jobs[0].steps.len);
    try std.testing.expectEqualStrings("x", pipeline.jobs[0].steps[0].script);
    var checkout_warn = false;
    for (diags.list.items) |d| if (std.mem.indexOf(u8, d.msg, "checkout") != null) {
        checkout_warn = true;
    };
    try std.testing.expect(checkout_warn);
}

test "scripted: a Groovy syntax error surfaces as ParseFailed with a 'groovy: ' diag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const source =
        \\node {
        \\    sh 'echo hi'
        \\    if (
        \\}
    ;
    try std.testing.expectError(error.ParseFailed, parsePipeline(a, "Jenkinsfile", source, &diags));
    var found = false;
    for (diags.list.items) |d| if (std.mem.startsWith(u8, d.msg, "groovy: ")) {
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
