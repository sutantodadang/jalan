const std = @import("std");

test "parse comparison of path and string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ast = try parseExpr(a, "github.ref == 'refs/heads/main'");
    try std.testing.expectEqual(Op.eq, ast.binary.op);
    try std.testing.expectEqualStrings("github.ref", ast.binary.lhs.path);
    try std.testing.expectEqualStrings("refs/heads/main", ast.binary.rhs.lit_str);
}

test "parse function call and logic ops" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ast = try parseExpr(a, "!contains(github.ref, 'wip') && matrix.node != 14");
    try std.testing.expectEqual(Op.land, ast.binary.op);
    try std.testing.expectEqualStrings("contains", ast.binary.lhs.unary_not.call.name);
}

test "unbalanced paren is BadExpr" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.BadExpr, parseExpr(arena.allocator(), "(a == 'b'"));
}

test "eval comparison against env" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = Env{};
    try env.put(a, "github.ref", "refs/heads/main");
    const ast = try parseExpr(a, "github.ref == 'refs/heads/main'");
    const v = try eval(a, ast, &env);
    try std.testing.expect(v.boolean);
}

test "unknown path is null and falsy; string 'false' is truthy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = Env{};
    try env.put(a, "env.flag", "false");
    const v1 = try eval(a, try parseExpr(a, "env.missing"), &env);
    try std.testing.expect(!v1.truthy());
    const v2 = try eval(a, try parseExpr(a, "env.flag"), &env);
    try std.testing.expect(v2.truthy());
}

test "functions contains and format" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = Env{};
    try env.put(a, "matrix.os", "ubuntu-latest");
    const v = try eval(a, try parseExpr(a, "contains(matrix.os, 'ubuntu')"), &env);
    try std.testing.expect(v.boolean);
    const f = try eval(a, try parseExpr(a, "format('os={0}', matrix.os)"), &env);
    try std.testing.expectEqualStrings("os=ubuntu-latest", f.string);
}

test "interpolate replaces multiple expressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var env = Env{};
    try env.put(a, "matrix.node", "18");
    try env.put(a, "env.NAME", "jalan");
    const out = try interpolate(a, "build ${{ env.NAME }} on node ${{ matrix.node }}", &env);
    try std.testing.expectEqualStrings("build jalan on node 18", out);
}

pub const Op = enum { eq, neq, land, lor };

pub const Ast = union(enum) {
    lit_null,
    lit_bool: bool,
    lit_num: f64,
    lit_str: []const u8,
    path: []const u8,
    call: struct { name: []const u8, args: []Ast },
    unary_not: *Ast,
    binary: struct { op: Op, lhs: *Ast, rhs: *Ast },
};

pub const ExprError = error{ BadExpr, OutOfMemory };

const P = struct {
    alloc: std.mem.Allocator,
    src: []const u8,
    i: usize = 0,

    fn skipWs(self: *P) void {
        while (self.i < self.src.len and self.src[self.i] == ' ') self.i += 1;
    }
    fn eat(self: *P, s: []const u8) bool {
        self.skipWs();
        if (std.mem.startsWith(u8, self.src[self.i..], s)) {
            self.i += s.len;
            return true;
        }
        return false;
    }
    fn box(self: *P, node: Ast) ExprError!*Ast {
        const p = try self.alloc.create(Ast);
        p.* = node;
        return p;
    }

    fn parseOr(self: *P) ExprError!Ast {
        var lhs = try self.parseAnd();
        while (self.eat("||")) {
            const l = try self.box(lhs);
            const r = try self.box(try self.parseAnd());
            lhs = .{ .binary = .{ .op = .lor, .lhs = l, .rhs = r } };
        }
        return lhs;
    }
    fn parseAnd(self: *P) ExprError!Ast {
        var lhs = try self.parseEq();
        while (self.eat("&&")) {
            const l = try self.box(lhs);
            const r = try self.box(try self.parseEq());
            lhs = .{ .binary = .{ .op = .land, .lhs = l, .rhs = r } };
        }
        return lhs;
    }
    fn parseEq(self: *P) ExprError!Ast {
        var lhs = try self.parseUnary();
        while (true) {
            if (self.eat("==")) {
                const l = try self.box(lhs);
                const r = try self.box(try self.parseUnary());
                lhs = .{ .binary = .{ .op = .eq, .lhs = l, .rhs = r } };
            } else if (self.eat("!=")) {
                const l = try self.box(lhs);
                const r = try self.box(try self.parseUnary());
                lhs = .{ .binary = .{ .op = .neq, .lhs = l, .rhs = r } };
            } else return lhs;
        }
    }
    fn parseUnary(self: *P) ExprError!Ast {
        self.skipWs();
        if (self.i < self.src.len and self.src[self.i] == '!' and
            (self.i + 1 >= self.src.len or self.src[self.i + 1] != '='))
        {
            self.i += 1;
            return .{ .unary_not = try self.box(try self.parseUnary()) };
        }
        return self.parsePrimary();
    }
    fn parsePrimary(self: *P) ExprError!Ast {
        self.skipWs();
        if (self.i >= self.src.len) return error.BadExpr;
        const c = self.src[self.i];
        if (c == '(') {
            self.i += 1;
            const inner = try self.parseOr();
            if (!self.eat(")")) return error.BadExpr;
            return inner;
        }
        if (c == '\'') return self.parseString();
        if (std.ascii.isDigit(c) or c == '-') return self.parseNumber();
        // identifier / path / call
        const start = self.i;
        while (self.i < self.src.len and (std.ascii.isAlphanumeric(self.src[self.i]) or
            self.src[self.i] == '_' or self.src[self.i] == '.' or self.src[self.i] == '-')) self.i += 1;
        if (self.i == start) return error.BadExpr;
        const word = self.src[start..self.i];
        if (std.mem.eql(u8, word, "null")) return .lit_null;
        if (std.mem.eql(u8, word, "true")) return .{ .lit_bool = true };
        if (std.mem.eql(u8, word, "false")) return .{ .lit_bool = false };
        self.skipWs();
        if (self.i < self.src.len and self.src[self.i] == '(') {
            self.i += 1;
            var args: std.ArrayList(Ast) = .empty;
            self.skipWs();
            if (!self.eat(")")) {
                while (true) {
                    try args.append(self.alloc, try self.parseOr());
                    if (self.eat(")")) break;
                    if (!self.eat(",")) return error.BadExpr;
                }
            }
            return .{ .call = .{ .name = word, .args = try args.toOwnedSlice(self.alloc) } };
        }
        return .{ .path = word };
    }
    fn parseString(self: *P) ExprError!Ast {
        self.i += 1; // opening '
        var out: std.ArrayList(u8) = .empty;
        while (self.i < self.src.len) {
            if (self.src[self.i] == '\'') {
                if (self.i + 1 < self.src.len and self.src[self.i + 1] == '\'') {
                    try out.append(self.alloc, '\'');
                    self.i += 2;
                } else {
                    self.i += 1;
                    return .{ .lit_str = try out.toOwnedSlice(self.alloc) };
                }
            } else {
                try out.append(self.alloc, self.src[self.i]);
                self.i += 1;
            }
        }
        return error.BadExpr;
    }
    fn parseNumber(self: *P) ExprError!Ast {
        const start = self.i;
        if (self.src[self.i] == '-') self.i += 1;
        while (self.i < self.src.len and (std.ascii.isDigit(self.src[self.i]) or self.src[self.i] == '.')) self.i += 1;
        const n = std.fmt.parseFloat(f64, self.src[start..self.i]) catch return error.BadExpr;
        return .{ .lit_num = n };
    }
};

pub fn parseExpr(alloc: std.mem.Allocator, src: []const u8) ExprError!Ast {
    var p = P{ .alloc = alloc, .src = src };
    const ast = try p.parseOr();
    p.skipWs();
    if (p.i != p.src.len) return error.BadExpr;
    return ast;
}

pub const Value = union(enum) {
    null_v,
    boolean: bool,
    number: f64,
    string: []const u8,

    pub fn truthy(self: Value) bool {
        return switch (self) {
            .null_v => false,
            .boolean => |b| b,
            .number => |n| n != 0,
            .string => |s| s.len != 0,
        };
    }
    pub fn toString(self: Value, alloc: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .null_v => "",
            .boolean => |b| if (b) "true" else "false",
            .number => |n| try std.fmt.allocPrint(alloc, "{d}", .{n}),
            .string => |s| s,
        };
    }
};

pub const Env = struct {
    vars: std.StringHashMapUnmanaged([]const u8) = .empty,

    pub fn put(self: *Env, alloc: std.mem.Allocator, path: []const u8, val: []const u8) !void {
        try self.vars.put(alloc, try std.ascii.allocLowerString(alloc, path), val);
    }
    pub fn lookup(self: *const Env, alloc: std.mem.Allocator, path: []const u8) !?[]const u8 {
        return self.vars.get(try std.ascii.allocLowerString(alloc, path));
    }
};

pub const EvalError = error{ EvalFailed, OutOfMemory };

pub fn eval(alloc: std.mem.Allocator, ast: Ast, env: *const Env) EvalError!Value {
    return switch (ast) {
        .lit_null => .null_v,
        .lit_bool => |b| .{ .boolean = b },
        .lit_num => |n| .{ .number = n },
        .lit_str => |s| .{ .string = s },
        .path => |p| if (try env.lookup(alloc, p)) |v| .{ .string = v } else .null_v,
        .unary_not => |inner| .{ .boolean = !(try eval(alloc, inner.*, env)).truthy() },
        .binary => |b| blk: {
            const l = try eval(alloc, b.lhs.*, env);
            switch (b.op) {
                .land => break :blk if (l.truthy()) try eval(alloc, b.rhs.*, env) else l,
                .lor => break :blk if (l.truthy()) l else try eval(alloc, b.rhs.*, env),
                .eq, .neq => {
                    const r = try eval(alloc, b.rhs.*, env);
                    const equal = valuesEqual(alloc, l, r) catch return error.EvalFailed;
                    break :blk .{ .boolean = if (b.op == .eq) equal else !equal };
                },
            }
        },
        .call => |c| try callFn(alloc, c.name, c.args, env),
    };
}

fn valuesEqual(alloc: std.mem.Allocator, l: Value, r: Value) !bool {
    if (std.meta.activeTag(l) == std.meta.activeTag(r)) {
        return switch (l) {
            .null_v => true,
            .boolean => |b| b == r.boolean,
            .number => |n| n == r.number,
            .string => |s| std.mem.eql(u8, s, r.string),
        };
    }
    return std.mem.eql(u8, try l.toString(alloc), try r.toString(alloc));
}

fn callFn(alloc: std.mem.Allocator, name: []const u8, args: []Ast, env: *const Env) EvalError!Value {
    if (std.mem.eql(u8, name, "format")) {
        if (args.len < 1) return error.EvalFailed;
        const tmpl = try (try eval(alloc, args[0], env)).toString(alloc);
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < tmpl.len) {
            if (tmpl[i] == '{' and i + 2 < tmpl.len and std.ascii.isDigit(tmpl[i + 1]) and tmpl[i + 2] == '}') {
                const idx = tmpl[i + 1] - '0' + 1;
                if (idx >= args.len) return error.EvalFailed;
                try out.appendSlice(alloc, try (try eval(alloc, args[idx], env)).toString(alloc));
                i += 3;
            } else {
                try out.append(alloc, tmpl[i]);
                i += 1;
            }
        }
        return .{ .string = try out.toOwnedSlice(alloc) };
    }
    if (args.len != 2) return error.EvalFailed;
    const a0 = try (try eval(alloc, args[0], env)).toString(alloc);
    const a1 = try (try eval(alloc, args[1], env)).toString(alloc);
    if (std.mem.eql(u8, name, "contains")) return .{ .boolean = std.mem.indexOf(u8, a0, a1) != null };
    if (std.mem.eql(u8, name, "startsWith")) return .{ .boolean = std.mem.startsWith(u8, a0, a1) };
    if (std.mem.eql(u8, name, "endsWith")) return .{ .boolean = std.mem.endsWith(u8, a0, a1) };
    return error.EvalFailed;
}

pub fn evalString(alloc: std.mem.Allocator, src: []const u8, env: *const Env) ![]const u8 {
    const ast = parseExpr(alloc, src) catch return error.EvalFailed;
    return (try eval(alloc, ast, env)).toString(alloc);
}

pub fn interpolate(alloc: std.mem.Allocator, text: []const u8, env: *const Env) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < text.len) {
        if (std.mem.indexOfPos(u8, text, i, "${{")) |open| {
            const close = std.mem.indexOfPos(u8, text, open, "}}") orelse return error.BadExpr;
            try out.appendSlice(alloc, text[i..open]);
            const inner = std.mem.trim(u8, text[open + 3 .. close], " ");
            try out.appendSlice(alloc, try evalString(alloc, inner, env));
            i = close + 2;
        } else {
            try out.appendSlice(alloc, text[i..]);
            break;
        }
    }
    return out.toOwnedSlice(alloc);
}
