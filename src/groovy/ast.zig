//! Groovy lexer + parser producing an AST for the CI-relevant subset of
//! Groovy used inside Jenkinsfiles (scripted blocks, shared libraries).
//! No evaluation here — see part B (interpreter) for that. Arena memory:
//! nothing is freed. Mirrors the tokenizer/parser style of frontend/jenkins.zig.
const std = @import("std");
const yaml = @import("../yaml.zig");

pub const ParseError = error{ ParseFailed, OutOfMemory };

pub const Node = struct { data: Data, line: u32, col: u32 };

pub const GPart = union(enum) { raw: []const u8, expr: *Node };

pub const MapEntry = struct { key: *Node, value: *Node };

pub const Param = struct { name: []const u8 };

pub const BinOp = enum { add, sub, mul, div, mod, eq, neq, lt, gt, le, ge, and_, or_, in_op, concat_shift };
pub const UnOp = enum { not, neg };
pub const AssignOp = enum { assign, add_assign, sub_assign };

pub const Data = union(enum) {
    null_lit,
    bool_lit: bool,
    int_lit: i64,
    float_lit: f64,
    str_lit: []const u8,
    gstring: []GPart,
    list_lit: []*Node,
    map_lit: []MapEntry,
    range: struct { from: *Node, to: *Node, inclusive: bool },
    ident: []const u8,
    binary: struct { op: BinOp, lhs: *Node, rhs: *Node },
    unary: struct { op: UnOp, operand: *Node },
    ternary: struct { cond: *Node, then: *Node, els: *Node },
    elvis: struct { lhs: *Node, rhs: *Node },
    index: struct { object: *Node, key: *Node },
    field: struct { object: *Node, name: []const u8 },
    call: struct { callee: ?*Node, name: []const u8, args: []*Node, named: []MapEntry },
    closure: struct { params: []Param, body: []*Node },
    assign: struct { target: *Node, op: AssignOp, value: *Node },
    var_decl: struct { name: []const u8, value: ?*Node },
    if_stmt: struct { cond: *Node, then_body: []*Node, else_body: ?[]*Node },
    while_stmt: struct { cond: *Node, body: []*Node },
    for_in: struct { var_name: []const u8, iterable: *Node, body: []*Node },
    try_stmt: struct { body: []*Node, catch_param: ?[]const u8, catch_body: ?[]*Node, finally_body: ?[]*Node },
    ret: ?*Node,
    brk,
    cont,
};

// ---------------------------------------------------------------------------
// Tokenizer
// ---------------------------------------------------------------------------

const TokKind = enum { ident, int_lit, float_lit, sq_string, dq_string, newline, symbol, eof };

const Token = struct {
    kind: TokKind,
    text: []const u8,
    line: u32,
    col: u32,
};

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_';
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

const multi_ops = [_][]const u8{ "..<", "==", "!=", "<=", ">=", "&&", "||", "+=", "-=", "?:", "?.", "->", "..", "<<" };
const single_chars = "!+-*/%=?:.,()[]{};<>";

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
            if (c == ' ' or c == '\t' or c == '\r') {
                _ = self.advance();
                continue;
            }
            if (c == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '/') {
                while (self.pos < self.src.len and self.src[self.pos] != '\n') _ = self.advance();
                continue;
            }
            if (c == '/' and self.pos + 1 < self.src.len and self.src[self.pos + 1] == '*') {
                const sl = self.line;
                const sc = self.col;
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
                    try self.diags.add(sl, sc, "groovy: unterminated block comment", .{});
                    return error.ParseFailed;
                }
                continue;
            }
            break;
        }
    }

    /// Scans raw content between (possibly triple) quotes. Escaped chars are
    /// skipped opaquely (not interpreted) so an escaped quote never
    /// terminates the string early; actual unescaping happens afterward.
    fn scanRaw(self: *Tokenizer, quote: u8, triple: bool, start_line: u32, start_col: u32) ParseError![]const u8 {
        const start = self.pos;
        while (true) {
            if (self.pos >= self.src.len) {
                try self.diags.add(start_line, start_col, "groovy: unterminated string literal", .{});
                return error.ParseFailed;
            }
            const c = self.src[self.pos];
            if (c == '\\' and self.pos + 1 < self.src.len) {
                self.advance2();
                continue;
            }
            if (triple) {
                if (c == quote and self.pos + 3 <= self.src.len and self.src[self.pos + 1] == quote and self.src[self.pos + 2] == quote) {
                    const text = self.src[start..self.pos];
                    _ = self.advance();
                    _ = self.advance();
                    _ = self.advance();
                    return text;
                }
                _ = self.advance();
                continue;
            }
            if (c == quote) {
                const text = self.src[start..self.pos];
                _ = self.advance();
                return text;
            }
            if (c == '\n') {
                try self.diags.add(start_line, start_col, "groovy: unterminated string literal", .{});
                return error.ParseFailed;
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
        if (c == '\n') {
            _ = self.advance();
            return .{ .kind = .newline, .text = "\n", .line = line, .col = col };
        }
        if (isIdentStart(c)) {
            const start = self.pos;
            while (self.pos < self.src.len and isIdentChar(self.src[self.pos])) _ = self.advance();
            return .{ .kind = .ident, .text = self.src[start..self.pos], .line = line, .col = col };
        }
        if (std.ascii.isDigit(c)) {
            const start = self.pos;
            while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) _ = self.advance();
            var kind: TokKind = .int_lit;
            if (self.pos < self.src.len and self.src[self.pos] == '.' and self.pos + 1 < self.src.len and std.ascii.isDigit(self.src[self.pos + 1])) {
                kind = .float_lit;
                _ = self.advance();
                while (self.pos < self.src.len and std.ascii.isDigit(self.src[self.pos])) _ = self.advance();
            }
            return .{ .kind = kind, .text = self.src[start..self.pos], .line = line, .col = col };
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
            const raw = try self.scanRaw(quote, triple, line, col);
            if (quote == '\'') {
                const text = try unescapeSingle(self.alloc, raw);
                return .{ .kind = .sq_string, .text = text, .line = line, .col = col };
            }
            return .{ .kind = .dq_string, .text = raw, .line = line, .col = col };
        }
        inline for (multi_ops) |op| {
            if (self.pos + op.len <= self.src.len and std.mem.eql(u8, self.src[self.pos .. self.pos + op.len], op)) {
                var i: usize = 0;
                while (i < op.len) : (i += 1) _ = self.advance();
                return .{ .kind = .symbol, .text = op, .line = line, .col = col };
            }
        }
        if (std.mem.indexOfScalar(u8, single_chars, c) != null) {
            _ = self.advance();
            return .{ .kind = .symbol, .text = self.src[self.pos - 1 .. self.pos], .line = line, .col = col };
        }
        try self.diags.add(line, col, "groovy: unexpected character '{c}'", .{c});
        return error.ParseFailed;
    }
};

fn unescapeSingle(alloc: std.mem.Allocator, raw: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, raw, '\\') == null) return raw;
    var buf: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < raw.len) {
        const c = raw[i];
        if (c == '\\' and i + 1 < raw.len) {
            const n = raw[i + 1];
            switch (n) {
                '\'' => {
                    try buf.append(alloc, '\'');
                    i += 2;
                },
                '\\' => {
                    try buf.append(alloc, '\\');
                    i += 2;
                },
                'n' => {
                    try buf.append(alloc, '\n');
                    i += 2;
                },
                't' => {
                    try buf.append(alloc, '\t');
                    i += 2;
                },
                'r' => {
                    try buf.append(alloc, '\r');
                    i += 2;
                },
                else => {
                    try buf.append(alloc, c);
                    i += 1;
                },
            }
            continue;
        }
        try buf.append(alloc, c);
        i += 1;
    }
    return buf.toOwnedSlice(alloc);
}

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

fn tokIsOp(t: Token, s: []const u8) bool {
    return t.kind == .symbol and std.mem.eql(u8, t.text, s);
}

const reserved_kw = [_][]const u8{
    "def", "if", "else", "while", "for", "in", "return", "break", "continue",
    "true", "false", "null", "try", "catch", "finally", "new",
};

fn isReservedKw(text: []const u8) bool {
    for (reserved_kw) |k| if (std.mem.eql(u8, text, k)) return true;
    return false;
}

fn isKw(t: Token, kw: []const u8) bool {
    return t.kind == .ident and std.mem.eql(u8, t.text, kw);
}

// ---------------------------------------------------------------------------
// Parser
// ---------------------------------------------------------------------------

const CallArgs = struct { args: []*Node, named: []MapEntry };

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

    fn checkOp(self: *Parser, s: []const u8) bool {
        return tokIsOp(self.peek(), s);
    }

    fn expectOp(self: *Parser, s: []const u8) ParseError!void {
        if (self.checkOp(s)) {
            _ = self.advance();
            return;
        }
        const t = self.peek();
        try self.diags.add(t.line, t.col, "groovy: expected '{s}'", .{s});
        return error.ParseFailed;
    }

    fn skipNL(self: *Parser) void {
        while (self.peek().kind == .newline) _ = self.advance();
    }

    fn skipSeparators(self: *Parser) void {
        while (self.peek().kind == .newline or self.checkOp(";")) _ = self.advance();
    }

    fn makeNode(self: *Parser, data: Data, line: u32, col: u32) ParseError!*Node {
        const n = try self.alloc.create(Node);
        n.* = .{ .data = data, .line = line, .col = col };
        return n;
    }

    // -- top level / statement lists ----------------------------------

    fn parseStmtList(self: *Parser, closing: ?[]const u8) ParseError![]*Node {
        var stmts: std.ArrayList(*Node) = .empty;
        while (true) {
            self.skipSeparators();
            if (self.atEnd()) break;
            if (closing) |c| {
                if (self.checkOp(c)) break;
            }
            const start = self.pos;
            const stmt = try self.parseStmt();
            try stmts.append(self.alloc, stmt);
            if (self.pos == start) {
                const t = self.peek();
                try self.diags.add(t.line, t.col, "groovy: parser made no progress at unexpected token", .{});
                return error.ParseFailed;
            }
        }
        if (closing) |c| {
            if (!self.checkOp(c)) {
                const t = self.peek();
                try self.diags.add(t.line, t.col, "groovy: unexpected end of input, expected '{s}'", .{c});
                return error.ParseFailed;
            }
        }
        return stmts.toOwnedSlice(self.alloc);
    }

    fn parseStmt(self: *Parser) ParseError!*Node {
        const t = self.peek();
        if (t.kind == .ident) {
            if (isKw(t, "def")) return self.parseDef();
            if (isKw(t, "if")) return self.parseIf();
            if (isKw(t, "while")) return self.parseWhile();
            if (isKw(t, "for")) return self.parseFor();
            if (isKw(t, "return")) return self.parseReturn();
            if (isKw(t, "break")) {
                _ = self.advance();
                return self.makeNode(.brk, t.line, t.col);
            }
            if (isKw(t, "continue")) {
                _ = self.advance();
                return self.makeNode(.cont, t.line, t.col);
            }
            if (isKw(t, "try")) return self.parseTry();
            if (isKw(t, "new")) {
                try self.diags.add(t.line, t.col, "groovy: 'new' is not supported", .{});
                return error.ParseFailed;
            }
        }
        if (self.looksLikeCommandStart()) return self.parseCommandCall();
        return self.parseExprStmt();
    }

    fn looksLikeCommandStart(self: *Parser) bool {
        const t0 = self.peek();
        if (t0.kind != .ident or isReservedKw(t0.text)) return false;
        const t1 = self.peekAt(1);
        switch (t1.kind) {
            .sq_string, .dq_string, .int_lit, .float_lit => return true,
            .ident => {
                if (isReservedKw(t1.text)) {
                    return std.mem.eql(u8, t1.text, "true") or std.mem.eql(u8, t1.text, "false") or std.mem.eql(u8, t1.text, "null");
                }
                return true;
            },
            // Note: '[' is deliberately excluded here even though the spec's
            // trigger list mentions it — without whitespace tracking in the
            // token stream, `m['k']` (index access) and `foo [1,2]` (command
            // syntax with a list arg) are indistinguishable, and index access
            // is the far more common / required form.
            .symbol => return std.mem.eql(u8, t1.text, "-") or std.mem.eql(u8, t1.text, "!"),
            else => return false,
        }
    }

    fn parseCommandCall(self: *Parser) ParseError!*Node {
        const name_tok = self.advance();
        const r = try self.parseCallArgs(false);
        var args = r.args;
        if (self.checkOp("{")) {
            const closure = try self.parseClosure();
            args = try appendNode(self.alloc, args, closure);
        }
        return self.makeNode(.{ .call = .{ .callee = null, .name = name_tok.text, .args = args, .named = r.named } }, name_tok.line, name_tok.col);
    }

    fn parseExprStmt(self: *Parser) ParseError!*Node {
        const t = self.peek();
        var expr = try self.parseExpr();
        if (self.checkOp("=") or self.checkOp("+=") or self.checkOp("-=")) {
            const op_tok = self.advance();
            const op: AssignOp = if (std.mem.eql(u8, op_tok.text, "=")) .assign else if (std.mem.eql(u8, op_tok.text, "+=")) .add_assign else .sub_assign;
            switch (expr.data) {
                .ident, .field, .index => {},
                else => {
                    try self.diags.add(t.line, t.col, "groovy: invalid assignment target", .{});
                    return error.ParseFailed;
                },
            }
            self.skipNL();
            const value = try self.parseExpr();
            expr = try self.makeNode(.{ .assign = .{ .target = expr, .op = op, .value = value } }, t.line, t.col);
        }
        return expr;
    }

    // -- statements -----------------------------------------------------

    fn parseDef(self: *Parser) ParseError!*Node {
        const kw = self.advance();
        self.skipNL();
        const name_tok = self.peek();
        if (name_tok.kind != .ident) {
            try self.diags.add(name_tok.line, name_tok.col, "groovy: expected identifier after 'def'", .{});
            return error.ParseFailed;
        }
        _ = self.advance();
        if (self.checkOp("(")) {
            _ = self.advance();
            self.skipNL();
            var params: std.ArrayList(Param) = .empty;
            if (!self.checkOp(")")) {
                while (true) {
                    const p_tok = self.peek();
                    if (p_tok.kind != .ident) {
                        try self.diags.add(p_tok.line, p_tok.col, "groovy: expected parameter name", .{});
                        return error.ParseFailed;
                    }
                    _ = self.advance();
                    try params.append(self.alloc, .{ .name = p_tok.text });
                    self.skipNL();
                    if (self.checkOp(",")) {
                        _ = self.advance();
                        self.skipNL();
                        continue;
                    }
                    break;
                }
            }
            self.skipNL();
            try self.expectOp(")");
            self.skipNL();
            try self.expectOp("{");
            self.skipNL();
            const body = try self.parseStmtList("}");
            try self.expectOp("}");
            const param_slice = try params.toOwnedSlice(self.alloc);
            const closure_node = try self.makeNode(.{ .closure = .{ .params = param_slice, .body = body } }, kw.line, kw.col);
            return self.makeNode(.{ .var_decl = .{ .name = name_tok.text, .value = closure_node } }, kw.line, kw.col);
        }
        var value: ?*Node = null;
        if (self.checkOp("=")) {
            _ = self.advance();
            self.skipNL();
            value = try self.parseExpr();
        }
        return self.makeNode(.{ .var_decl = .{ .name = name_tok.text, .value = value } }, kw.line, kw.col);
    }

    fn parseIf(self: *Parser) ParseError!*Node {
        const kw = self.advance();
        self.skipNL();
        try self.expectOp("(");
        self.skipNL();
        const cond = try self.parseExpr();
        self.skipNL();
        try self.expectOp(")");
        self.skipNL();
        try self.expectOp("{");
        self.skipNL();
        const then_body = try self.parseStmtList("}");
        try self.expectOp("}");
        var else_body: ?[]*Node = null;
        self.skipNL();
        if (isKw(self.peek(), "else")) {
            _ = self.advance();
            self.skipNL();
            if (isKw(self.peek(), "if")) {
                const nested = try self.parseIf();
                const arr = try self.alloc.alloc(*Node, 1);
                arr[0] = nested;
                else_body = arr;
            } else {
                try self.expectOp("{");
                self.skipNL();
                const b = try self.parseStmtList("}");
                try self.expectOp("}");
                else_body = b;
            }
        }
        return self.makeNode(.{ .if_stmt = .{ .cond = cond, .then_body = then_body, .else_body = else_body } }, kw.line, kw.col);
    }

    fn parseWhile(self: *Parser) ParseError!*Node {
        const kw = self.advance();
        self.skipNL();
        try self.expectOp("(");
        self.skipNL();
        const cond = try self.parseExpr();
        self.skipNL();
        try self.expectOp(")");
        self.skipNL();
        try self.expectOp("{");
        self.skipNL();
        const body = try self.parseStmtList("}");
        try self.expectOp("}");
        return self.makeNode(.{ .while_stmt = .{ .cond = cond, .body = body } }, kw.line, kw.col);
    }

    fn parseFor(self: *Parser) ParseError!*Node {
        const kw = self.advance();
        self.skipNL();
        try self.expectOp("(");
        self.skipNL();
        const name_tok = self.peek();
        if (name_tok.kind != .ident) {
            try self.diags.add(name_tok.line, name_tok.col, "groovy: expected loop variable name", .{});
            return error.ParseFailed;
        }
        _ = self.advance();
        self.skipNL();
        if (!isKw(self.peek(), "in")) {
            const t = self.peek();
            try self.diags.add(t.line, t.col, "groovy: expected 'in' in for loop", .{});
            return error.ParseFailed;
        }
        _ = self.advance();
        self.skipNL();
        const iterable = try self.parseExpr();
        self.skipNL();
        try self.expectOp(")");
        self.skipNL();
        try self.expectOp("{");
        self.skipNL();
        const body = try self.parseStmtList("}");
        try self.expectOp("}");
        return self.makeNode(.{ .for_in = .{ .var_name = name_tok.text, .iterable = iterable, .body = body } }, kw.line, kw.col);
    }

    fn parseReturn(self: *Parser) ParseError!*Node {
        const kw = self.advance();
        const t = self.peek();
        const has_value = !(t.kind == .newline or t.kind == .eof or tokIsOp(t, ";") or tokIsOp(t, "}"));
        var value: ?*Node = null;
        if (has_value) value = try self.parseExpr();
        return self.makeNode(.{ .ret = value }, kw.line, kw.col);
    }

    fn parseTry(self: *Parser) ParseError!*Node {
        const kw = self.advance();
        self.skipNL();
        try self.expectOp("{");
        self.skipNL();
        const body = try self.parseStmtList("}");
        try self.expectOp("}");
        var catch_param: ?[]const u8 = null;
        var catch_body: ?[]*Node = null;
        var finally_body: ?[]*Node = null;
        self.skipNL();
        if (isKw(self.peek(), "catch")) {
            _ = self.advance();
            self.skipNL();
            try self.expectOp("(");
            self.skipNL();
            const first = self.peek();
            if (first.kind != .ident) {
                try self.diags.add(first.line, first.col, "groovy: expected catch parameter", .{});
                return error.ParseFailed;
            }
            _ = self.advance();
            var name = first.text;
            self.skipNL();
            if (self.peek().kind == .ident) {
                name = self.advance().text;
                self.skipNL();
            }
            try self.expectOp(")");
            self.skipNL();
            try self.expectOp("{");
            self.skipNL();
            const cb = try self.parseStmtList("}");
            try self.expectOp("}");
            catch_param = name;
            catch_body = cb;
        }
        self.skipNL();
        if (isKw(self.peek(), "finally")) {
            _ = self.advance();
            self.skipNL();
            try self.expectOp("{");
            self.skipNL();
            const fb = try self.parseStmtList("}");
            try self.expectOp("}");
            finally_body = fb;
        }
        return self.makeNode(.{ .try_stmt = .{ .body = body, .catch_param = catch_param, .catch_body = catch_body, .finally_body = finally_body } }, kw.line, kw.col);
    }

    // -- closures ---------------------------------------------------------

    fn tryParseClosureParams(self: *Parser) ParseError!?[]Param {
        const start = self.pos;
        if (self.peek().kind != .ident) return null;
        var params: std.ArrayList(Param) = .empty;
        while (true) {
            if (self.peek().kind != .ident) {
                self.pos = start;
                return null;
            }
            try params.append(self.alloc, .{ .name = self.advance().text });
            self.skipNL();
            if (self.checkOp(",")) {
                _ = self.advance();
                self.skipNL();
                continue;
            }
            break;
        }
        if (self.checkOp("->")) {
            _ = self.advance();
            return try params.toOwnedSlice(self.alloc);
        }
        self.pos = start;
        return null;
    }

    fn parseClosure(self: *Parser) ParseError!*Node {
        const start_tok = self.peek();
        try self.expectOp("{");
        self.skipNL();
        const maybe_params = try self.tryParseClosureParams();
        self.skipNL();
        const params: []Param = maybe_params orelse &.{};
        const body = try self.parseStmtList("}");
        try self.expectOp("}");
        return self.makeNode(.{ .closure = .{ .params = params, .body = body } }, start_tok.line, start_tok.col);
    }

    // -- call args ----------------------------------------------------

    fn parseCallArgs(self: *Parser, in_parens: bool) ParseError!CallArgs {
        var args: std.ArrayList(*Node) = .empty;
        var named: std.ArrayList(MapEntry) = .empty;
        if (in_parens and self.checkOp(")")) {
            return .{ .args = &.{}, .named = &.{} };
        }
        while (true) {
            const t0 = self.peek();
            const t1 = self.peekAt(1);
            if (t0.kind == .ident and tokIsOp(t1, ":")) {
                _ = self.advance();
                _ = self.advance();
                self.skipNL();
                const val = try self.parseExpr();
                const key_node = try self.makeNode(.{ .ident = t0.text }, t0.line, t0.col);
                try named.append(self.alloc, .{ .key = key_node, .value = val });
            } else {
                const val = try self.parseExpr();
                try args.append(self.alloc, val);
            }
            self.skipNL();
            if (self.checkOp(",")) {
                _ = self.advance();
                self.skipNL();
                continue;
            }
            break;
        }
        return .{ .args = try args.toOwnedSlice(self.alloc), .named = try named.toOwnedSlice(self.alloc) };
    }

    fn appendNode(alloc: std.mem.Allocator, existing: []*Node, item: *Node) ParseError![]*Node {
        var list: std.ArrayList(*Node) = .empty;
        try list.appendSlice(alloc, existing);
        try list.append(alloc, item);
        return list.toOwnedSlice(alloc);
    }

    // -- expressions: precedence chain --------------------------------
    // ternary/elvis -> || -> && -> equality -> relational -> range ->
    // additive -> multiplicative -> unary -> postfix

    fn parseExpr(self: *Parser) ParseError!*Node {
        return self.parseTernary();
    }

    fn parseTernary(self: *Parser) ParseError!*Node {
        const left = try self.parseOr();
        if (self.checkOp("?")) {
            const t = self.advance();
            self.skipNL();
            const then_e = try self.parseTernary();
            self.skipNL();
            try self.expectOp(":");
            self.skipNL();
            const else_e = try self.parseTernary();
            return self.makeNode(.{ .ternary = .{ .cond = left, .then = then_e, .els = else_e } }, t.line, t.col);
        }
        if (self.checkOp("?:")) {
            const t = self.advance();
            self.skipNL();
            const rhs = try self.parseTernary();
            return self.makeNode(.{ .elvis = .{ .lhs = left, .rhs = rhs } }, t.line, t.col);
        }
        return left;
    }

    fn parseOr(self: *Parser) ParseError!*Node {
        var left = try self.parseAnd();
        while (self.checkOp("||")) {
            const t = self.advance();
            self.skipNL();
            const rhs = try self.parseAnd();
            left = try self.makeNode(.{ .binary = .{ .op = .or_, .lhs = left, .rhs = rhs } }, t.line, t.col);
        }
        return left;
    }

    fn parseAnd(self: *Parser) ParseError!*Node {
        var left = try self.parseEquality();
        while (self.checkOp("&&")) {
            const t = self.advance();
            self.skipNL();
            const rhs = try self.parseEquality();
            left = try self.makeNode(.{ .binary = .{ .op = .and_, .lhs = left, .rhs = rhs } }, t.line, t.col);
        }
        return left;
    }

    fn parseEquality(self: *Parser) ParseError!*Node {
        var left = try self.parseRelational();
        while (self.checkOp("==") or self.checkOp("!=")) {
            const t = self.advance();
            const op: BinOp = if (std.mem.eql(u8, t.text, "==")) .eq else .neq;
            self.skipNL();
            const rhs = try self.parseRelational();
            left = try self.makeNode(.{ .binary = .{ .op = op, .lhs = left, .rhs = rhs } }, t.line, t.col);
        }
        return left;
    }

    fn parseRelational(self: *Parser) ParseError!*Node {
        var left = try self.parseRange();
        while (true) {
            if (self.checkOp("<") or self.checkOp(">") or self.checkOp("<=") or self.checkOp(">=")) {
                const t = self.advance();
                const op: BinOp = if (std.mem.eql(u8, t.text, "<"))
                    .lt
                else if (std.mem.eql(u8, t.text, ">"))
                    .gt
                else if (std.mem.eql(u8, t.text, "<="))
                    .le
                else
                    .ge;
                self.skipNL();
                const rhs = try self.parseRange();
                left = try self.makeNode(.{ .binary = .{ .op = op, .lhs = left, .rhs = rhs } }, t.line, t.col);
                continue;
            }
            if (isKw(self.peek(), "in")) {
                const t = self.advance();
                self.skipNL();
                const rhs = try self.parseRange();
                left = try self.makeNode(.{ .binary = .{ .op = .in_op, .lhs = left, .rhs = rhs } }, t.line, t.col);
                continue;
            }
            break;
        }
        return left;
    }

    fn parseRange(self: *Parser) ParseError!*Node {
        const left = try self.parseAdditive();
        if (self.checkOp("..<")) {
            const t = self.advance();
            self.skipNL();
            const rhs = try self.parseAdditive();
            return self.makeNode(.{ .range = .{ .from = left, .to = rhs, .inclusive = false } }, t.line, t.col);
        }
        if (self.checkOp("..")) {
            const t = self.advance();
            self.skipNL();
            const rhs = try self.parseAdditive();
            return self.makeNode(.{ .range = .{ .from = left, .to = rhs, .inclusive = true } }, t.line, t.col);
        }
        return left;
    }

    fn parseAdditive(self: *Parser) ParseError!*Node {
        var left = try self.parseMultiplicative();
        while (self.checkOp("+") or self.checkOp("-") or self.checkOp("<<")) {
            const t = self.advance();
            const op: BinOp = if (std.mem.eql(u8, t.text, "+")) .add else if (std.mem.eql(u8, t.text, "-")) .sub else .concat_shift;
            self.skipNL();
            const rhs = try self.parseMultiplicative();
            left = try self.makeNode(.{ .binary = .{ .op = op, .lhs = left, .rhs = rhs } }, t.line, t.col);
        }
        return left;
    }

    fn parseMultiplicative(self: *Parser) ParseError!*Node {
        var left = try self.parseUnary();
        while (self.checkOp("*") or self.checkOp("/") or self.checkOp("%")) {
            const t = self.advance();
            const op: BinOp = if (std.mem.eql(u8, t.text, "*")) .mul else if (std.mem.eql(u8, t.text, "/")) .div else .mod;
            self.skipNL();
            const rhs = try self.parseUnary();
            left = try self.makeNode(.{ .binary = .{ .op = op, .lhs = left, .rhs = rhs } }, t.line, t.col);
        }
        return left;
    }

    fn parseUnary(self: *Parser) ParseError!*Node {
        if (self.checkOp("!")) {
            const t = self.advance();
            const operand = try self.parseUnary();
            return self.makeNode(.{ .unary = .{ .op = .not, .operand = operand } }, t.line, t.col);
        }
        if (self.checkOp("-")) {
            const t = self.advance();
            const operand = try self.parseUnary();
            return self.makeNode(.{ .unary = .{ .op = .neg, .operand = operand } }, t.line, t.col);
        }
        return self.parsePostfix();
    }

    fn parsePostfix(self: *Parser) ParseError!*Node {
        var node = try self.parsePrimary();
        while (true) {
            if (self.checkOp(".") or self.checkOp("?.")) {
                _ = self.advance();
                self.skipNL();
                const name_tok = self.peek();
                if (name_tok.kind != .ident) {
                    try self.diags.add(name_tok.line, name_tok.col, "groovy: expected name after '.'", .{});
                    return error.ParseFailed;
                }
                _ = self.advance();
                if (self.checkOp("(")) {
                    _ = self.advance();
                    self.skipNL();
                    const r = try self.parseCallArgs(true);
                    self.skipNL();
                    try self.expectOp(")");
                    var args = r.args;
                    if (self.checkOp("{")) {
                        const closure = try self.parseClosure();
                        args = try appendNode(self.alloc, args, closure);
                    }
                    node = try self.makeNode(.{ .call = .{ .callee = node, .name = name_tok.text, .args = args, .named = r.named } }, name_tok.line, name_tok.col);
                } else if (self.checkOp("{")) {
                    const closure = try self.parseClosure();
                    const args = try self.alloc.alloc(*Node, 1);
                    args[0] = closure;
                    node = try self.makeNode(.{ .call = .{ .callee = node, .name = name_tok.text, .args = args, .named = &.{} } }, name_tok.line, name_tok.col);
                } else {
                    node = try self.makeNode(.{ .field = .{ .object = node, .name = name_tok.text } }, name_tok.line, name_tok.col);
                }
                continue;
            }
            if (self.checkOp("[")) {
                const br = self.advance();
                self.skipNL();
                const key = try self.parseExpr();
                self.skipNL();
                try self.expectOp("]");
                node = try self.makeNode(.{ .index = .{ .object = node, .key = key } }, br.line, br.col);
                continue;
            }
            if (node.data == .ident and self.checkOp("(")) {
                const nm = node.data.ident;
                const line = node.line;
                const col = node.col;
                _ = self.advance();
                self.skipNL();
                const r = try self.parseCallArgs(true);
                self.skipNL();
                try self.expectOp(")");
                var args = r.args;
                if (self.checkOp("{")) {
                    const closure = try self.parseClosure();
                    args = try appendNode(self.alloc, args, closure);
                }
                node = try self.makeNode(.{ .call = .{ .callee = null, .name = nm, .args = args, .named = r.named } }, line, col);
                continue;
            }
            if (node.data == .ident and self.checkOp("{")) {
                const nm = node.data.ident;
                const line = node.line;
                const col = node.col;
                const closure = try self.parseClosure();
                const args = try self.alloc.alloc(*Node, 1);
                args[0] = closure;
                node = try self.makeNode(.{ .call = .{ .callee = null, .name = nm, .args = args, .named = &.{} } }, line, col);
                continue;
            }
            break;
        }
        return node;
    }

    fn parsePrimary(self: *Parser) ParseError!*Node {
        const t = self.peek();
        switch (t.kind) {
            .int_lit => {
                _ = self.advance();
                const v = std.fmt.parseInt(i64, t.text, 10) catch {
                    try self.diags.add(t.line, t.col, "groovy: invalid integer literal '{s}'", .{t.text});
                    return error.ParseFailed;
                };
                return self.makeNode(.{ .int_lit = v }, t.line, t.col);
            },
            .float_lit => {
                _ = self.advance();
                const v = std.fmt.parseFloat(f64, t.text) catch {
                    try self.diags.add(t.line, t.col, "groovy: invalid float literal '{s}'", .{t.text});
                    return error.ParseFailed;
                };
                return self.makeNode(.{ .float_lit = v }, t.line, t.col);
            },
            .sq_string => {
                _ = self.advance();
                return self.makeNode(.{ .str_lit = t.text }, t.line, t.col);
            },
            .dq_string => {
                _ = self.advance();
                const data = try self.buildGString(t.text, t.line, t.col);
                return self.makeNode(data, t.line, t.col);
            },
            .ident => {
                if (std.mem.eql(u8, t.text, "true")) {
                    _ = self.advance();
                    return self.makeNode(.{ .bool_lit = true }, t.line, t.col);
                }
                if (std.mem.eql(u8, t.text, "false")) {
                    _ = self.advance();
                    return self.makeNode(.{ .bool_lit = false }, t.line, t.col);
                }
                if (std.mem.eql(u8, t.text, "null")) {
                    _ = self.advance();
                    return self.makeNode(.null_lit, t.line, t.col);
                }
                if (std.mem.eql(u8, t.text, "new")) {
                    try self.diags.add(t.line, t.col, "groovy: 'new' is not supported", .{});
                    return error.ParseFailed;
                }
                _ = self.advance();
                return self.makeNode(.{ .ident = t.text }, t.line, t.col);
            },
            .symbol => {
                if (std.mem.eql(u8, t.text, "(")) {
                    _ = self.advance();
                    self.skipNL();
                    const inner = try self.parseExpr();
                    self.skipNL();
                    try self.expectOp(")");
                    return inner;
                }
                if (std.mem.eql(u8, t.text, "[")) return self.parseListOrMap();
                if (std.mem.eql(u8, t.text, "{")) return self.parseClosure();
                try self.diags.add(t.line, t.col, "groovy: unexpected token '{s}'", .{t.text});
                return error.ParseFailed;
            },
            else => {
                try self.diags.add(t.line, t.col, "groovy: expected an expression", .{});
                return error.ParseFailed;
            },
        }
    }

    fn parseListOrMap(self: *Parser) ParseError!*Node {
        const br = self.advance();
        self.skipNL();
        if (self.checkOp(":")) {
            const save = self.pos;
            _ = self.advance();
            if (self.checkOp("]")) {
                _ = self.advance();
                return self.makeNode(.{ .map_lit = &.{} }, br.line, br.col);
            }
            self.pos = save;
        }
        if (self.checkOp("]")) {
            _ = self.advance();
            return self.makeNode(.{ .list_lit = &.{} }, br.line, br.col);
        }
        const t0 = self.peek();
        const t1 = self.peekAt(1);
        const is_map = (t0.kind == .sq_string or t0.kind == .dq_string or t0.kind == .ident) and tokIsOp(t1, ":");
        if (is_map) {
            var entries: std.ArrayList(MapEntry) = .empty;
            while (true) {
                const kt = self.peek();
                var key: *Node = undefined;
                if (kt.kind == .sq_string) {
                    _ = self.advance();
                    key = try self.makeNode(.{ .str_lit = kt.text }, kt.line, kt.col);
                } else if (kt.kind == .dq_string) {
                    _ = self.advance();
                    const d = try self.buildGString(kt.text, kt.line, kt.col);
                    key = try self.makeNode(d, kt.line, kt.col);
                } else if (kt.kind == .ident) {
                    _ = self.advance();
                    key = try self.makeNode(.{ .ident = kt.text }, kt.line, kt.col);
                } else {
                    try self.diags.add(kt.line, kt.col, "groovy: expected map key", .{});
                    return error.ParseFailed;
                }
                self.skipNL();
                try self.expectOp(":");
                self.skipNL();
                const val = try self.parseExpr();
                try entries.append(self.alloc, .{ .key = key, .value = val });
                self.skipNL();
                if (self.checkOp(",")) {
                    _ = self.advance();
                    self.skipNL();
                    continue;
                }
                break;
            }
            self.skipNL();
            try self.expectOp("]");
            return self.makeNode(.{ .map_lit = try entries.toOwnedSlice(self.alloc) }, br.line, br.col);
        }
        var items: std.ArrayList(*Node) = .empty;
        while (true) {
            const it = try self.parseExpr();
            try items.append(self.alloc, it);
            self.skipNL();
            if (self.checkOp(",")) {
                _ = self.advance();
                self.skipNL();
                continue;
            }
            break;
        }
        self.skipNL();
        try self.expectOp("]");
        return self.makeNode(.{ .list_lit = try items.toOwnedSlice(self.alloc) }, br.line, br.col);
    }

    // -- GString interpolation ------------------------------------------

    fn parseSubExpr(self: *Parser, src: []const u8, line: u32, col: u32) ParseError!*Node {
        const toks = try tokenize(self.alloc, src, self.diags);
        var sub = Parser{ .toks = toks, .alloc = self.alloc, .diags = self.diags };
        const node = try sub.parseExpr();
        sub.skipNL();
        if (!sub.atEnd()) {
            try self.diags.add(line, col, "groovy: malformed interpolation expression", .{});
            return error.ParseFailed;
        }
        return node;
    }

    fn buildGString(self: *Parser, raw: []const u8, line: u32, col: u32) ParseError!Data {
        var parts: std.ArrayList(GPart) = .empty;
        var buf: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < raw.len) {
            const c = raw[i];
            if (c == '\\' and i + 1 < raw.len) {
                const n = raw[i + 1];
                switch (n) {
                    '"' => {
                        try buf.append(self.alloc, '"');
                        i += 2;
                    },
                    '\\' => {
                        try buf.append(self.alloc, '\\');
                        i += 2;
                    },
                    '$' => {
                        try buf.append(self.alloc, '$');
                        i += 2;
                    },
                    'n' => {
                        try buf.append(self.alloc, '\n');
                        i += 2;
                    },
                    't' => {
                        try buf.append(self.alloc, '\t');
                        i += 2;
                    },
                    'r' => {
                        try buf.append(self.alloc, '\r');
                        i += 2;
                    },
                    else => {
                        try buf.append(self.alloc, c);
                        i += 1;
                    },
                }
                continue;
            }
            if (c == '$' and i + 1 < raw.len and raw[i + 1] == '{') {
                if (buf.items.len > 0) {
                    try parts.append(self.alloc, .{ .raw = try buf.toOwnedSlice(self.alloc) });
                    buf = .empty;
                }
                var depth: usize = 1;
                var j = i + 2;
                while (j < raw.len and depth > 0) {
                    if (raw[j] == '{') depth += 1 else if (raw[j] == '}') {
                        depth -= 1;
                        if (depth == 0) break;
                    }
                    j += 1;
                }
                if (depth != 0) {
                    try self.diags.add(line, col, "groovy: unterminated interpolation in string", .{});
                    return error.ParseFailed;
                }
                const inner_src = raw[i + 2 .. j];
                const expr_node = try self.parseSubExpr(inner_src, line, col);
                try parts.append(self.alloc, .{ .expr = expr_node });
                i = j + 1;
                continue;
            }
            if (c == '$' and i + 1 < raw.len and isIdentStart(raw[i + 1])) {
                if (buf.items.len > 0) {
                    try parts.append(self.alloc, .{ .raw = try buf.toOwnedSlice(self.alloc) });
                    buf = .empty;
                }
                var k = i + 1;
                while (k < raw.len and isIdentChar(raw[k])) k += 1;
                var node = try self.makeNode(.{ .ident = raw[i + 1 .. k] }, line, col);
                i = k;
                while (i + 1 < raw.len and raw[i] == '.' and isIdentStart(raw[i + 1])) {
                    var k2 = i + 1;
                    while (k2 < raw.len and isIdentChar(raw[k2])) k2 += 1;
                    node = try self.makeNode(.{ .field = .{ .object = node, .name = raw[i + 1 .. k2] } }, line, col);
                    i = k2;
                }
                try parts.append(self.alloc, .{ .expr = node });
                continue;
            }
            try buf.append(self.alloc, c);
            i += 1;
        }
        if (buf.items.len > 0) try parts.append(self.alloc, .{ .raw = try buf.toOwnedSlice(self.alloc) });
        return Data{ .gstring = try parts.toOwnedSlice(self.alloc) };
    }
};

pub fn parse(alloc: std.mem.Allocator, source: []const u8, diags: *yaml.Diags) ParseError![]*Node {
    const toks = try tokenize(alloc, source, diags);
    var p = Parser{ .toks = toks, .alloc = alloc, .diags = diags };
    const stmts = try p.parseStmtList(null);
    if (!p.atEnd()) {
        const t = p.peek();
        try diags.add(t.line, t.col, "groovy: unexpected token '{s}'", .{t.text});
        return error.ParseFailed;
    }
    return stmts;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

fn parseOne(alloc: std.mem.Allocator, source: []const u8, diags: *yaml.Diags) !*Node {
    const stmts = try parse(alloc, source, diags);
    try std.testing.expectEqual(@as(usize, 1), stmts.len);
    return stmts[0];
}

test "int, float, bool, and null literals" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const n1 = try parseOne(a, "42", &diags);
    try std.testing.expectEqual(@as(i64, 42), n1.data.int_lit);
    const n2 = try parseOne(a, "3.14", &diags);
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), n2.data.float_lit, 0.0001);
    const n3 = try parseOne(a, "true", &diags);
    try std.testing.expect(n3.data.bool_lit);
    const n4 = try parseOne(a, "null", &diags);
    try std.testing.expect(n4.data == .null_lit);
}

test "single-quoted string with escapes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const n = try parseOne(a, "'it\\'s a \\ttest\\n'", &diags);
    try std.testing.expectEqualStrings("it's a \ttest\n", n.data.str_lit);
}

test "GString with expr interpolation and $ident / $ident.prop shorthand" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const n = try parseOne(a, "\"sum=${1+2} name=$name obj=$obj.prop\"", &diags);
    const parts = n.data.gstring;
    try std.testing.expectEqual(@as(usize, 6), parts.len);
    try std.testing.expectEqualStrings("sum=", parts[0].raw);
    try std.testing.expect(parts[1].expr.data == .binary);
    try std.testing.expectEqualStrings(" name=", parts[2].raw);
    try std.testing.expectEqualStrings("name", parts[3].expr.data.ident);
    try std.testing.expectEqualStrings(" obj=", parts[4].raw);
    try std.testing.expectEqualStrings("prop", parts[5].expr.data.field.name);
}

test "triple-quoted multiline strings, single and GString" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const n1 = try parseOne(a, "'''line1\nline2'''", &diags);
    try std.testing.expectEqualStrings("line1\nline2", n1.data.str_lit);
    const n2 = try parseOne(a, "\"\"\"hi ${1+1}\nbye\"\"\"", &diags);
    const parts = n2.data.gstring;
    try std.testing.expectEqualStrings("hi ", parts[0].raw);
    try std.testing.expectEqualStrings("\nbye", parts[2].raw);
}

test "list and map literals with bare-word and string keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const list = try parseOne(a, "[1, 2, 3]", &diags);
    try std.testing.expectEqual(@as(usize, 3), list.data.list_lit.len);
    const map = try parseOne(a, "[a: 1, 'b': 2]", &diags);
    try std.testing.expectEqual(@as(usize, 2), map.data.map_lit.len);
    try std.testing.expectEqualStrings("a", map.data.map_lit[0].key.data.ident);
    try std.testing.expectEqualStrings("b", map.data.map_lit[1].key.data.str_lit);
}

test "ranges inclusive and exclusive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const r1 = try parseOne(a, "1..5", &diags);
    try std.testing.expect(r1.data.range.inclusive);
    const r2 = try parseOne(a, "1..<5", &diags);
    try std.testing.expect(!r2.data.range.inclusive);
}

test "operator precedence: multiplicative before additive, and before or" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const n1 = try parseOne(a, "1+2*3", &diags);
    try std.testing.expectEqual(BinOp.add, n1.data.binary.op);
    try std.testing.expectEqual(BinOp.mul, n1.data.binary.rhs.data.binary.op);
    const n2 = try parseOne(a, "a || b && c", &diags);
    try std.testing.expectEqual(BinOp.or_, n2.data.binary.op);
    try std.testing.expectEqual(BinOp.and_, n2.data.binary.rhs.data.binary.op);
}

test "unary not, ternary, and elvis" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const n1 = try parseOne(a, "!x", &diags);
    try std.testing.expectEqual(UnOp.not, n1.data.unary.op);
    const n2 = try parseOne(a, "a ? b : c", &diags);
    try std.testing.expect(n2.data == .ternary);
    const n3 = try parseOne(a, "a ?: b", &diags);
    try std.testing.expect(n3.data == .elvis);
}

test "assignment and += on ident" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const n1 = try parseOne(a, "x = 5", &diags);
    try std.testing.expectEqual(AssignOp.assign, n1.data.assign.op);
    const n2 = try parseOne(a, "x += 1", &diags);
    try std.testing.expectEqual(AssignOp.add_assign, n2.data.assign.op);
}

test "def with and without initializer, and function-def desugar" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const n1 = try parseOne(a, "def x", &diags);
    try std.testing.expect(n1.data.var_decl.value == null);
    const n2 = try parseOne(a, "def x = 5", &diags);
    try std.testing.expectEqual(@as(i64, 5), n2.data.var_decl.value.?.data.int_lit);
    const n3 = try parseOne(a, "def f(a, b) { return a+b }", &diags);
    try std.testing.expectEqualStrings("f", n3.data.var_decl.name);
    const closure = n3.data.var_decl.value.?;
    try std.testing.expectEqual(@as(usize, 2), closure.data.closure.params.len);
    try std.testing.expectEqualStrings("a", closure.data.closure.params[0].name);
    try std.testing.expectEqual(@as(usize, 1), closure.data.closure.body.len);
    try std.testing.expect(closure.data.closure.body[0].data == .ret);
}

test "if / else-if / else chain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const n = try parseOne(a,
        \\if (a) { x = 1 } else if (b) { x = 2 } else { x = 3 }
    , &diags);
    try std.testing.expect(n.data == .if_stmt);
    const else_body = n.data.if_stmt.else_body.?;
    try std.testing.expectEqual(@as(usize, 1), else_body.len);
    try std.testing.expect(else_body[0].data == .if_stmt);
    try std.testing.expect(else_body[0].data.if_stmt.else_body != null);
}

test "while loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const n = try parseOne(a, "while (x < 10) { x += 1 }", &diags);
    try std.testing.expect(n.data == .while_stmt);
    try std.testing.expectEqual(@as(usize, 1), n.data.while_stmt.body.len);
}

test "for-in over range and over list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const n1 = try parseOne(a, "for (i in 1..3) { echo i }", &diags);
    try std.testing.expectEqualStrings("i", n1.data.for_in.var_name);
    try std.testing.expect(n1.data.for_in.iterable.data == .range);
    const n2 = try parseOne(a, "for (x in [1,2,3]) { echo x }", &diags);
    try std.testing.expect(n2.data.for_in.iterable.data == .list_lit);
}

test "try/catch/finally" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const n = try parseOne(a,
        \\try { risky() } catch (Exception e) { handle() } finally { cleanup() }
    , &diags);
    try std.testing.expect(n.data == .try_stmt);
    try std.testing.expectEqualStrings("e", n.data.try_stmt.catch_param.?);
    try std.testing.expect(n.data.try_stmt.finally_body != null);
}

test "closures: implicit it and explicit params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const n1 = try parseOne(a, "{ it * 2 }", &diags);
    try std.testing.expectEqual(@as(usize, 0), n1.data.closure.params.len);
    const n2 = try parseOne(a, "{ a, b -> a + b }", &diags);
    try std.testing.expectEqual(@as(usize, 2), n2.data.closure.params.len);
}

test "call forms: foo(), foo(1,2), recv.m(x), chained a.b.c(d)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const n1 = try parseOne(a, "foo()", &diags);
    try std.testing.expectEqualStrings("foo", n1.data.call.name);
    try std.testing.expectEqual(@as(usize, 0), n1.data.call.args.len);
    const n2 = try parseOne(a, "foo(1,2)", &diags);
    try std.testing.expectEqual(@as(usize, 2), n2.data.call.args.len);
    const n3 = try parseOne(a, "recv.m(x)", &diags);
    try std.testing.expect(n3.data.call.callee != null);
    try std.testing.expectEqualStrings("m", n3.data.call.name);
    const n4 = try parseOne(a, "a.b.c(d)", &diags);
    try std.testing.expectEqualStrings("c", n4.data.call.name);
    try std.testing.expect(n4.data.call.callee.?.data == .field);
}

test "command syntax call and named args" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const n1 = try parseOne(a, "sh 'ls'", &diags);
    try std.testing.expectEqualStrings("sh", n1.data.call.name);
    try std.testing.expectEqual(@as(usize, 1), n1.data.call.args.len);
    const n2 = try parseOne(a, "sh script: 'x', returnStdout: true", &diags);
    try std.testing.expectEqual(@as(usize, 2), n2.data.call.named.len);
    try std.testing.expectEqualStrings("script", n2.data.call.named[0].key.data.ident);
}

test "trailing closures: foo { }, foo(args) { }, recv.foo { }" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const n1 = try parseOne(a, "foo { it * 2 }", &diags);
    try std.testing.expectEqual(@as(usize, 1), n1.data.call.args.len);
    try std.testing.expect(n1.data.call.args[0].data == .closure);
    const n2 = try parseOne(a, "foo(1) { it * 2 }", &diags);
    try std.testing.expectEqual(@as(usize, 2), n2.data.call.args.len);
    const n3 = try parseOne(a, "recv.foo { it }", &diags);
    try std.testing.expect(n3.data.call.callee != null);
    try std.testing.expect(n3.data.call.args[0].data == .closure);
}

test "index access and << append operator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const n1 = try parseOne(a, "m['k']", &diags);
    try std.testing.expect(n1.data == .index);
    const n2 = try parseOne(a, "list << x", &diags);
    try std.testing.expectEqual(BinOp.concat_shift, n2.data.binary.op);
}

test "statement separation by newline and semicolon, continuation after operator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const stmts1 = try parse(a, "x = 1\ny = 2; z = 3", &diags);
    try std.testing.expectEqual(@as(usize, 3), stmts1.len);
    const n = try parseOne(a, "x = 1 +\n    2", &diags);
    try std.testing.expectEqual(BinOp.add, n.data.assign.value.data.binary.op);
}

test "line and block comments are skipped" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    const stmts = try parse(a,
        \\// leading comment
        \\x = 1 /* inline */
        \\y = 2
    , &diags);
    try std.testing.expectEqual(@as(usize, 2), stmts.len);
}

test "unterminated string fails to parse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    try std.testing.expectError(error.ParseFailed, parse(a, "x = 'abc", &diags));
}

test "unbalanced brace fails to parse without hanging" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    try std.testing.expectError(error.ParseFailed, parse(a, "if (x) { y = 1", &diags));
    try std.testing.expectError(error.ParseFailed, parse(a, "x = 1 }", &diags));
}

test "'new' is rejected with a diag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    try std.testing.expectError(error.ParseFailed, parse(a, "def x = new Foo()", &diags));
    var found = false;
    for (diags.list.items) |d| if (std.mem.indexOf(u8, d.msg, "'new' is not supported") != null) {
        found = true;
    };
    try std.testing.expect(found);
}
