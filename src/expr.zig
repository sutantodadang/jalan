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
