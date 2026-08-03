//! Groovy tree-walking interpreter over the AST from ast.zig (part B of the
//! Groovy front end). Arena memory: nothing is freed. A later part (frontend
//! wiring) drives this through the `Host` callback for any call the
//! interpreter cannot resolve itself (sh, stage, node, echo, parallel, ...).
const std = @import("std");
const yaml = @import("../yaml.zig");
const ast = @import("ast.zig");

pub const InterpError = error{ EvalFailed, OutOfMemory };

pub const ValueMap = std.StringArrayHashMapUnmanaged(Value);

pub const ClosureVal = struct { params: []ast.Param, body: []*ast.Node, captured: *Scope };

pub const Value = union(enum) {
    nul,
    boolean: bool,
    int: i64,
    float: f64,
    string: []const u8,
    list: *std.ArrayList(Value),
    map: *ValueMap,
    closure: ClosureVal,
};

pub const NamedArg = struct { name: []const u8, value: Value };

pub const Host = struct {
    ctx: *anyopaque,
    // Called for any free-function call the interpreter cannot resolve to a
    // user-defined closure variable (e.g. sh, stage, node, echo, parallel).
    // `named` are Groovy named args (already evaluated), `args` positional
    // (already evaluated; a trailing closure arrives as the last positional
    // Value of tag .closure). Return the call's value.
    call: *const fn (ctx: *anyopaque, interp: *Interp, name: []const u8, args: []Value, named: []const NamedArg, line: u32, col: u32) InterpError!Value,
};

pub const Scope = struct {
    vars: ValueMap = .{},
    parent: ?*Scope,

    fn lookup(self: *Scope, name: []const u8) ?*Value {
        var cur: ?*Scope = self;
        while (cur) |s| {
            if (s.vars.getPtr(name)) |p| return p;
            cur = s.parent;
        }
        return null;
    }
};

/// Statement execution result: threads break/continue/return through nested
/// blocks without using errors (errors are reserved for real eval failures).
const Control = union(enum) {
    // Carries the value of the last expression executed, implementing
    // Groovy's implicit "last expression is the return value" semantics for
    // closures/blocks with no explicit `return`.
    normal: Value,
    broke,
    continued,
    returned: Value,
};

fn numKind(v: Value) ?enum { i, f } {
    return switch (v) {
        .int => .i,
        .float => .f,
        else => null,
    };
}

fn asF64(v: Value) f64 {
    return switch (v) {
        .int => |i| @as(f64, @floatFromInt(i)),
        .float => |f| f,
        else => 0,
    };
}

fn asInt(v: Value) ?i64 {
    return switch (v) {
        .int => |i| i,
        .float => |f| @as(i64, @intFromFloat(f)),
        else => null,
    };
}

pub fn truthy(v: Value) bool {
    return switch (v) {
        .nul => false,
        .boolean => |b| b,
        .int => |i| i != 0,
        .float => |f| f != 0.0,
        .string => |s| s.len != 0,
        .list => |list| list.items.len != 0,
        .map => |m| m.count() != 0,
        .closure => true,
    };
}

pub const Interp = struct {
    alloc: std.mem.Allocator,
    diags: *yaml.Diags,
    host: Host,
    globals: *Scope,
    loop_guard_max: u64 = 1_000_000,
    range_cap: usize = 100_000,

    pub fn init(alloc: std.mem.Allocator, diags: *yaml.Diags, host: Host) !*Interp {
        const g = try alloc.create(Scope);
        g.* = .{ .vars = .{}, .parent = null };
        const self = try alloc.create(Interp);
        self.* = .{ .alloc = alloc, .diags = diags, .host = host, .globals = g };
        return self;
    }

    pub fn setGlobal(self: *Interp, name: []const u8, value: Value) !void {
        try self.globals.vars.put(self.alloc, name, value);
    }

    pub fn getGlobal(self: *Interp, name: []const u8) ?Value {
        return self.globals.vars.get(name);
    }

    pub fn run(self: *Interp, stmts: []*ast.Node) InterpError!Value {
        const ctrl = try self.execBlock(stmts, self.globals);
        return switch (ctrl) {
            .returned => |v| v,
            .normal => |v| v,
            else => Value{ .nul = {} },
        };
    }

    pub fn callClosure(self: *Interp, c: ClosureVal, args: []Value) InterpError!Value {
        const scope = try self.newScope(c.captured);
        if (c.params.len == 0) {
            const it_val: Value = if (args.len > 0) args[0] else Value{ .nul = {} };
            try scope.vars.put(self.alloc, "it", it_val);
        } else {
            for (c.params, 0..) |p, i| {
                const v: Value = if (i < args.len) args[i] else Value{ .nul = {} };
                try scope.vars.put(self.alloc, p.name, v);
            }
        }
        const ctrl = try self.execBlock(c.body, scope);
        return switch (ctrl) {
            .returned => |v| v,
            .normal => |v| v,
            else => Value{ .nul = {} },
        };
    }

    pub fn toStr(self: *Interp, v: Value) InterpError![]const u8 {
        return switch (v) {
            .nul => "null",
            .boolean => |b| if (b) "true" else "false",
            .int => |i| try std.fmt.allocPrint(self.alloc, "{d}", .{i}),
            .float => |f| try std.fmt.allocPrint(self.alloc, "{d}", .{f}),
            .string => |s| s,
            .list => |list| blk: {
                var buf: std.ArrayList(u8) = .empty;
                try buf.append(self.alloc, '[');
                for (list.items, 0..) |it, i| {
                    if (i > 0) try buf.appendSlice(self.alloc, ", ");
                    const s = try self.toStr(it);
                    try buf.appendSlice(self.alloc, s);
                }
                try buf.append(self.alloc, ']');
                break :blk try buf.toOwnedSlice(self.alloc);
            },
            .map => |m| blk: {
                if (m.count() == 0) break :blk "[:]";
                var buf: std.ArrayList(u8) = .empty;
                try buf.append(self.alloc, '[');
                var it = m.iterator();
                var i: usize = 0;
                while (it.next()) |entry| {
                    if (i > 0) try buf.appendSlice(self.alloc, ", ");
                    try buf.appendSlice(self.alloc, entry.key_ptr.*);
                    try buf.append(self.alloc, ':');
                    const vs = try self.toStr(entry.value_ptr.*);
                    try buf.appendSlice(self.alloc, vs);
                    i += 1;
                }
                try buf.append(self.alloc, ']');
                break :blk try buf.toOwnedSlice(self.alloc);
            },
            .closure => "<closure>",
        };
    }

    // -- internals ------------------------------------------------------

    fn newScope(self: *Interp, parent: ?*Scope) !*Scope {
        const s = try self.alloc.create(Scope);
        s.* = .{ .vars = .{}, .parent = parent };
        return s;
    }

    fn fail(self: *Interp, line: u32, col: u32, comptime fmt: []const u8, args: anytype) InterpError {
        self.diags.add(line, col, fmt, args) catch |e| return e;
        return error.EvalFailed;
    }

    fn assignVar(self: *Interp, scope: *Scope, name: []const u8, value: Value) !void {
        if (scope.lookup(name)) |ptr| {
            ptr.* = value;
            return;
        }
        try self.globals.vars.put(self.alloc, name, value);
    }

    fn combineAssign(self: *Interp, op: ast.AssignOp, cur: Value, rhs: Value, line: u32, col: u32) InterpError!Value {
        return switch (op) {
            .assign => rhs,
            .add_assign => try self.doAdd(cur, rhs, line, col),
            .sub_assign => try self.doArith(.sub, cur, rhs, line, col),
        };
    }

    /// Map/named-arg keys are bare idents or string literals meant as literal
    /// text, not variable references -- evaluate only when it's neither.
    fn mapKeyStr(self: *Interp, key: *ast.Node, scope: *Scope) InterpError![]const u8 {
        return switch (key.data) {
            .ident => |s| s,
            .str_lit => |s| s,
            else => blk: {
                const v = try self.evalExpr(key, scope);
                break :blk try self.toStr(v);
            },
        };
    }

    fn valuesEqual(self: *Interp, l: Value, r: Value) InterpError!bool {
        return switch (l) {
            .nul => r == .nul,
            .boolean => |lb| switch (r) {
                .boolean => |rb| lb == rb,
                else => false,
            },
            .int => |li| switch (r) {
                .int => |ri| li == ri,
                .float => |rf| @as(f64, @floatFromInt(li)) == rf,
                else => false,
            },
            .float => |lf| switch (r) {
                .int => |ri| lf == @as(f64, @floatFromInt(ri)),
                .float => |rf| lf == rf,
                else => false,
            },
            .string => |ls| switch (r) {
                .string => |rs| std.mem.eql(u8, ls, rs),
                else => false,
            },
            .list => |ll| switch (r) {
                .list => |rl| blk: {
                    if (ll.items.len != rl.items.len) break :blk false;
                    for (ll.items, rl.items) |a, b| {
                        if (!try self.valuesEqual(a, b)) break :blk false;
                    }
                    break :blk true;
                },
                else => false,
            },
            .map => |lm| switch (r) {
                .map => |rm| blk: {
                    if (lm.count() != rm.count()) break :blk false;
                    var it = lm.iterator();
                    while (it.next()) |entry| {
                        const rv = rm.get(entry.key_ptr.*) orelse break :blk false;
                        if (!try self.valuesEqual(entry.value_ptr.*, rv)) break :blk false;
                    }
                    break :blk true;
                },
                else => false,
            },
            .closure => false,
        };
    }

    fn doAdd(self: *Interp, l: Value, r: Value, line: u32, col: u32) InterpError!Value {
        if (l == .string or r == .string) {
            const ls = try self.toStr(l);
            const rs = try self.toStr(r);
            return Value{ .string = try std.mem.concat(self.alloc, u8, &.{ ls, rs }) };
        }
        if (l == .list) {
            const list = try self.alloc.create(std.ArrayList(Value));
            list.* = .empty;
            try list.appendSlice(self.alloc, l.list.items);
            if (r == .list) {
                try list.appendSlice(self.alloc, r.list.items);
            } else {
                try list.append(self.alloc, r);
            }
            return Value{ .list = list };
        }
        return try self.doArith(.add, l, r, line, col);
    }

    fn doArith(self: *Interp, op: ast.BinOp, l: Value, r: Value, line: u32, col: u32) InterpError!Value {
        const lk = numKind(l) orelse return self.fail(line, col, "groovy: arithmetic on non-numeric value", .{});
        const rk = numKind(r) orelse return self.fail(line, col, "groovy: arithmetic on non-numeric value", .{});
        if (lk == .i and rk == .i) {
            const li = l.int;
            const ri = r.int;
            switch (op) {
                .add => return Value{ .int = li + ri },
                .sub => return Value{ .int = li - ri },
                .mul => return Value{ .int = li * ri },
                .div => {
                    if (ri == 0) return self.fail(line, col, "groovy: division by zero", .{});
                    if (@rem(li, ri) == 0) return Value{ .int = @divTrunc(li, ri) };
                    return Value{ .float = @as(f64, @floatFromInt(li)) / @as(f64, @floatFromInt(ri)) };
                },
                else => unreachable,
            }
        }
        const lf = asF64(l);
        const rf = asF64(r);
        switch (op) {
            .add => return Value{ .float = lf + rf },
            .sub => return Value{ .float = lf - rf },
            .mul => return Value{ .float = lf * rf },
            .div => {
                if (rf == 0) return self.fail(line, col, "groovy: division by zero", .{});
                return Value{ .float = lf / rf };
            },
            else => unreachable,
        }
    }

    fn doMod(self: *Interp, l: Value, r: Value, line: u32, col: u32) InterpError!Value {
        if (l != .int or r != .int) return self.fail(line, col, "groovy: '%' requires integer operands", .{});
        if (r.int == 0) return self.fail(line, col, "groovy: division by zero", .{});
        return Value{ .int = @rem(l.int, r.int) };
    }

    fn doCompare(self: *Interp, op: ast.BinOp, l: Value, r: Value, line: u32, col: u32) InterpError!Value {
        if (numKind(l) != null and numKind(r) != null) {
            const lf = asF64(l);
            const rf = asF64(r);
            const res = switch (op) {
                .lt => lf < rf,
                .gt => lf > rf,
                .le => lf <= rf,
                .ge => lf >= rf,
                else => unreachable,
            };
            return Value{ .boolean = res };
        }
        if (l == .string and r == .string) {
            const c = std.mem.order(u8, l.string, r.string);
            const res = switch (op) {
                .lt => c == .lt,
                .gt => c == .gt,
                .le => c != .gt,
                .ge => c != .lt,
                else => unreachable,
            };
            return Value{ .boolean = res };
        }
        return self.fail(line, col, "groovy: relational operator on incompatible types", .{});
    }

    fn doIn(self: *Interp, l: Value, r: Value, line: u32, col: u32) InterpError!Value {
        switch (r) {
            .list => |list| {
                for (list.items) |item| {
                    if (try self.valuesEqual(l, item)) return Value{ .boolean = true };
                }
                return Value{ .boolean = false };
            },
            .map => |m| {
                const key = try self.toStr(l);
                return Value{ .boolean = m.contains(key) };
            },
            .string => |s| {
                const sub = try self.toStr(l);
                return Value{ .boolean = std.mem.indexOf(u8, s, sub) != null };
            },
            else => return self.fail(line, col, "groovy: 'in' requires list, map, or string on right side", .{}),
        }
    }

    fn doShift(self: *Interp, l: Value, r: Value, line: u32, col: u32) InterpError!Value {
        switch (l) {
            .list => |list| {
                try list.append(self.alloc, r);
                return l;
            },
            .string => |s| {
                const rs = try self.toStr(r);
                return Value{ .string = try std.mem.concat(self.alloc, u8, &.{ s, rs }) };
            },
            else => return self.fail(line, col, "groovy: '<<' requires list or string on left side", .{}),
        }
    }

    fn evalBinary(self: *Interp, op: ast.BinOp, l: Value, r: Value, line: u32, col: u32) InterpError!Value {
        return switch (op) {
            .add => try self.doAdd(l, r, line, col),
            .sub, .mul, .div => try self.doArith(op, l, r, line, col),
            .mod => try self.doMod(l, r, line, col),
            .eq => Value{ .boolean = try self.valuesEqual(l, r) },
            .neq => Value{ .boolean = !try self.valuesEqual(l, r) },
            .lt, .gt, .le, .ge => try self.doCompare(op, l, r, line, col),
            .in_op => try self.doIn(l, r, line, col),
            .concat_shift => try self.doShift(l, r, line, col),
            .and_, .or_ => unreachable,
        };
    }

    fn indexGet(self: *Interp, obj: Value, key: Value, line: u32, col: u32) InterpError!Value {
        switch (obj) {
            .list => |list| {
                const idx = asInt(key) orelse return self.fail(line, col, "groovy: list index must be an integer", .{});
                var i = idx;
                if (i < 0) i += @as(i64, @intCast(list.items.len));
                if (i < 0 or i >= @as(i64, @intCast(list.items.len))) return Value{ .nul = {} };
                return list.items[@intCast(i)];
            },
            .map => |m| {
                const ks = try self.toStr(key);
                return m.get(ks) orelse Value{ .nul = {} };
            },
            .string => |s| {
                const idx = asInt(key) orelse return self.fail(line, col, "groovy: string index must be an integer", .{});
                var i = idx;
                if (i < 0) i += @as(i64, @intCast(s.len));
                if (i < 0 or i >= @as(i64, @intCast(s.len))) return Value{ .nul = {} };
                const ch = try self.alloc.alloc(u8, 1);
                ch[0] = s[@intCast(i)];
                return Value{ .string = ch };
            },
            else => return self.fail(line, col, "groovy: cannot index into this value", .{}),
        }
    }

    fn fieldGet(self: *Interp, obj: Value, name: []const u8, line: u32, col: u32) InterpError!Value {
        switch (obj) {
            .map => |m| return m.get(name) orelse Value{ .nul = {} },
            .string => |s| {
                if (std.mem.eql(u8, name, "length")) return Value{ .int = @intCast(s.len) };
                return self.fail(line, col, "groovy: unknown field '{s}' on string", .{name});
            },
            .list => |list| {
                if (std.mem.eql(u8, name, "size")) return Value{ .int = @intCast(list.items.len) };
                return self.fail(line, col, "groovy: unknown field '{s}' on list", .{name});
            },
            else => return self.fail(line, col, "groovy: cannot access field '{s}' on this value", .{name}),
        }
    }

    fn splitString(self: *Interp, s: []const u8, sep: []const u8, drop_empty: bool) InterpError!*std.ArrayList(Value) {
        const list = try self.alloc.create(std.ArrayList(Value));
        list.* = .empty;
        if (sep.len == 0) {
            try list.append(self.alloc, Value{ .string = s });
            return list;
        }
        var it = std.mem.splitSequence(u8, s, sep);
        while (it.next()) |part| {
            if (drop_empty and part.len == 0) continue;
            try list.append(self.alloc, Value{ .string = part });
        }
        return list;
    }

    fn stringMethod(self: *Interp, s: []const u8, name: []const u8, args: []Value, line: u32, col: u32) InterpError!Value {
        if (std.mem.eql(u8, name, "size") or std.mem.eql(u8, name, "length")) return Value{ .int = @intCast(s.len) };
        if (std.mem.eql(u8, name, "toLowerCase")) return Value{ .string = try std.ascii.allocLowerString(self.alloc, s) };
        if (std.mem.eql(u8, name, "toUpperCase")) return Value{ .string = try std.ascii.allocUpperString(self.alloc, s) };
        if (std.mem.eql(u8, name, "trim")) return Value{ .string = std.mem.trim(u8, s, " \t\r\n") };
        if (std.mem.eql(u8, name, "isEmpty")) return Value{ .boolean = s.len == 0 };
        if (std.mem.eql(u8, name, "contains")) {
            if (args.len != 1 or args[0] != .string) return self.fail(line, col, "groovy: contains() requires a string argument", .{});
            return Value{ .boolean = std.mem.indexOf(u8, s, args[0].string) != null };
        }
        if (std.mem.eql(u8, name, "startsWith")) {
            if (args.len != 1 or args[0] != .string) return self.fail(line, col, "groovy: startsWith() requires a string argument", .{});
            return Value{ .boolean = std.mem.startsWith(u8, s, args[0].string) };
        }
        if (std.mem.eql(u8, name, "endsWith")) {
            if (args.len != 1 or args[0] != .string) return self.fail(line, col, "groovy: endsWith() requires a string argument", .{});
            return Value{ .boolean = std.mem.endsWith(u8, s, args[0].string) };
        }
        if (std.mem.eql(u8, name, "replace")) {
            if (args.len != 2 or args[0] != .string or args[1] != .string) return self.fail(line, col, "groovy: replace() requires two string arguments", .{});
            const out = try std.mem.replaceOwned(u8, self.alloc, s, args[0].string, args[1].string);
            return Value{ .string = out };
        }
        if (std.mem.eql(u8, name, "split")) {
            if (args.len != 1 or args[0] != .string) return self.fail(line, col, "groovy: split() requires a string argument", .{});
            return Value{ .list = try self.splitString(s, args[0].string, false) };
        }
        if (std.mem.eql(u8, name, "tokenize")) {
            if (args.len != 1 or args[0] != .string) return self.fail(line, col, "groovy: tokenize() requires a string argument", .{});
            return Value{ .list = try self.splitString(s, args[0].string, true) };
        }
        if (std.mem.eql(u8, name, "toInteger")) {
            const v = std.fmt.parseInt(i64, std.mem.trim(u8, s, " \t"), 10) catch return self.fail(line, col, "groovy: cannot parse '{s}' as integer", .{s});
            return Value{ .int = v };
        }
        return self.fail(line, col, "groovy: unknown method '{s}' on string", .{name});
    }

    fn listMethod(self: *Interp, list: *std.ArrayList(Value), name: []const u8, args: []Value, line: u32, col: u32) InterpError!Value {
        if (std.mem.eql(u8, name, "size")) return Value{ .int = @intCast(list.items.len) };
        if (std.mem.eql(u8, name, "isEmpty")) return Value{ .boolean = list.items.len == 0 };
        if (std.mem.eql(u8, name, "contains")) {
            if (args.len != 1) return self.fail(line, col, "groovy: contains() requires one argument", .{});
            for (list.items) |it| {
                if (try self.valuesEqual(it, args[0])) return Value{ .boolean = true };
            }
            return Value{ .boolean = false };
        }
        if (std.mem.eql(u8, name, "add")) {
            if (args.len != 1) return self.fail(line, col, "groovy: add() requires one argument", .{});
            try list.append(self.alloc, args[0]);
            return Value{ .boolean = true };
        }
        if (std.mem.eql(u8, name, "join")) {
            if (args.len != 1 or args[0] != .string) return self.fail(line, col, "groovy: join() requires a string separator", .{});
            var buf: std.ArrayList(u8) = .empty;
            for (list.items, 0..) |it, i| {
                if (i > 0) try buf.appendSlice(self.alloc, args[0].string);
                const s = try self.toStr(it);
                try buf.appendSlice(self.alloc, s);
            }
            return Value{ .string = try buf.toOwnedSlice(self.alloc) };
        }
        if (std.mem.eql(u8, name, "each")) {
            if (args.len != 1 or args[0] != .closure) return self.fail(line, col, "groovy: each() requires a closure argument", .{});
            for (list.items) |it| {
                var one = [_]Value{it};
                _ = try self.callClosure(args[0].closure, &one);
            }
            return Value{ .list = list };
        }
        if (std.mem.eql(u8, name, "collect")) {
            if (args.len != 1 or args[0] != .closure) return self.fail(line, col, "groovy: collect() requires a closure argument", .{});
            const out = try self.alloc.create(std.ArrayList(Value));
            out.* = .empty;
            for (list.items) |it| {
                var one = [_]Value{it};
                const v = try self.callClosure(args[0].closure, &one);
                try out.append(self.alloc, v);
            }
            return Value{ .list = out };
        }
        if (std.mem.eql(u8, name, "find")) {
            if (args.len != 1 or args[0] != .closure) return self.fail(line, col, "groovy: find() requires a closure argument", .{});
            for (list.items) |it| {
                var one = [_]Value{it};
                const v = try self.callClosure(args[0].closure, &one);
                if (truthy(v)) return it;
            }
            return Value{ .nul = {} };
        }
        if (std.mem.eql(u8, name, "findAll")) {
            if (args.len != 1 or args[0] != .closure) return self.fail(line, col, "groovy: findAll() requires a closure argument", .{});
            const out = try self.alloc.create(std.ArrayList(Value));
            out.* = .empty;
            for (list.items) |it| {
                var one = [_]Value{it};
                const v = try self.callClosure(args[0].closure, &one);
                if (truthy(v)) try out.append(self.alloc, it);
            }
            return Value{ .list = out };
        }
        return self.fail(line, col, "groovy: unknown method '{s}' on list", .{name});
    }

    fn mapMethod(self: *Interp, m: *ValueMap, name: []const u8, args: []Value, line: u32, col: u32) InterpError!Value {
        if (std.mem.eql(u8, name, "size")) return Value{ .int = @intCast(m.count()) };
        if (std.mem.eql(u8, name, "isEmpty")) return Value{ .boolean = m.count() == 0 };
        if (std.mem.eql(u8, name, "containsKey")) {
            if (args.len != 1) return self.fail(line, col, "groovy: containsKey() requires one argument", .{});
            const k = try self.toStr(args[0]);
            return Value{ .boolean = m.contains(k) };
        }
        if (std.mem.eql(u8, name, "get")) {
            if (args.len != 1) return self.fail(line, col, "groovy: get() requires one argument", .{});
            const k = try self.toStr(args[0]);
            return m.get(k) orelse Value{ .nul = {} };
        }
        if (std.mem.eql(u8, name, "put")) {
            if (args.len != 2) return self.fail(line, col, "groovy: put() requires two arguments", .{});
            const k = try self.toStr(args[0]);
            try m.put(self.alloc, k, args[1]);
            return args[1];
        }
        if (std.mem.eql(u8, name, "each")) {
            if (args.len != 1 or args[0] != .closure) return self.fail(line, col, "groovy: each() requires a closure argument", .{});
            const cl = args[0].closure;
            if (cl.params.len != 2) return self.fail(line, col, "groovy: map.each needs a two-parameter closure", .{});
            var it = m.iterator();
            while (it.next()) |entry| {
                var two = [_]Value{ Value{ .string = entry.key_ptr.* }, entry.value_ptr.* };
                _ = try self.callClosure(cl, &two);
            }
            return Value{ .map = m };
        }
        return self.fail(line, col, "groovy: unknown method '{s}' on map", .{name});
    }

    fn callMethod(self: *Interp, obj: Value, name: []const u8, args: []Value, line: u32, col: u32) InterpError!Value {
        if (std.mem.eql(u8, name, "toString") and args.len == 0) {
            return Value{ .string = try self.toStr(obj) };
        }
        switch (obj) {
            .string => |s| return try self.stringMethod(s, name, args, line, col),
            .list => |list| return try self.listMethod(list, name, args, line, col),
            .map => |m| return try self.mapMethod(m, name, args, line, col),
            .closure => |cl| {
                if (std.mem.eql(u8, name, "call")) return try self.callClosure(cl, args);
                return self.fail(line, col, "groovy: unknown method '{s}' on closure", .{name});
            },
            else => return self.fail(line, col, "groovy: unknown method '{s}' on {s}", .{ name, @tagName(obj) }),
        }
    }

    fn evalExpr(self: *Interp, node: *ast.Node, scope: *Scope) InterpError!Value {
        switch (node.data) {
            .null_lit => return Value{ .nul = {} },
            .bool_lit => |b| return Value{ .boolean = b },
            .int_lit => |i| return Value{ .int = i },
            .float_lit => |f| return Value{ .float = f },
            .str_lit => |s| return Value{ .string = s },
            .gstring => |parts| {
                var buf: std.ArrayList(u8) = .empty;
                for (parts) |p| {
                    switch (p) {
                        .raw => |r| try buf.appendSlice(self.alloc, r),
                        .expr => |e| {
                            const v = try self.evalExpr(e, scope);
                            const s = try self.toStr(v);
                            try buf.appendSlice(self.alloc, s);
                        },
                    }
                }
                return Value{ .string = try buf.toOwnedSlice(self.alloc) };
            },
            .list_lit => |items| {
                const list = try self.alloc.create(std.ArrayList(Value));
                list.* = .empty;
                for (items) |it| {
                    const v = try self.evalExpr(it, scope);
                    try list.append(self.alloc, v);
                }
                return Value{ .list = list };
            },
            .map_lit => |entries| {
                const m = try self.alloc.create(ValueMap);
                m.* = .{};
                for (entries) |e| {
                    const key_s = try self.mapKeyStr(e.key, scope);
                    const val = try self.evalExpr(e.value, scope);
                    try m.put(self.alloc, key_s, val);
                }
                return Value{ .map = m };
            },
            .range => |r| {
                const from_v = try self.evalExpr(r.from, scope);
                const to_v = try self.evalExpr(r.to, scope);
                const from_i = asInt(from_v) orelse return self.fail(node.line, node.col, "groovy: range bounds must be integers", .{});
                const to_i = asInt(to_v) orelse return self.fail(node.line, node.col, "groovy: range bounds must be integers", .{});
                const list = try self.alloc.create(std.ArrayList(Value));
                list.* = .empty;
                var count: usize = 0;
                if (from_i <= to_i) {
                    const end = if (r.inclusive) to_i else to_i - 1;
                    var i = from_i;
                    while (i <= end) : (i += 1) {
                        if (count >= self.range_cap) return self.fail(node.line, node.col, "groovy: range exceeds maximum size", .{});
                        try list.append(self.alloc, Value{ .int = i });
                        count += 1;
                    }
                } else {
                    const end = if (r.inclusive) to_i else to_i + 1;
                    var i = from_i;
                    while (i >= end) : (i -= 1) {
                        if (count >= self.range_cap) return self.fail(node.line, node.col, "groovy: range exceeds maximum size", .{});
                        try list.append(self.alloc, Value{ .int = i });
                        count += 1;
                    }
                }
                return Value{ .list = list };
            },
            .ident => |name| {
                if (scope.lookup(name)) |vptr| return vptr.*;
                return self.fail(node.line, node.col, "groovy: undefined variable '{s}'", .{name});
            },
            .binary => |b| {
                if (b.op == .and_) {
                    const l = try self.evalExpr(b.lhs, scope);
                    if (!truthy(l)) return Value{ .boolean = false };
                    const r = try self.evalExpr(b.rhs, scope);
                    return Value{ .boolean = truthy(r) };
                }
                if (b.op == .or_) {
                    const l = try self.evalExpr(b.lhs, scope);
                    if (truthy(l)) return Value{ .boolean = true };
                    const r = try self.evalExpr(b.rhs, scope);
                    return Value{ .boolean = truthy(r) };
                }
                const l = try self.evalExpr(b.lhs, scope);
                const r = try self.evalExpr(b.rhs, scope);
                return try self.evalBinary(b.op, l, r, node.line, node.col);
            },
            .unary => |u| {
                const v = try self.evalExpr(u.operand, scope);
                switch (u.op) {
                    .not => return Value{ .boolean = !truthy(v) },
                    .neg => switch (v) {
                        .int => |i| return Value{ .int = -i },
                        .float => |f| return Value{ .float = -f },
                        else => return self.fail(node.line, node.col, "groovy: unary '-' requires numeric operand", .{}),
                    },
                }
            },
            .ternary => |t| {
                const c = try self.evalExpr(t.cond, scope);
                return if (truthy(c)) try self.evalExpr(t.then, scope) else try self.evalExpr(t.els, scope);
            },
            .elvis => |e| {
                const l = try self.evalExpr(e.lhs, scope);
                return if (truthy(l)) l else try self.evalExpr(e.rhs, scope);
            },
            .index => |ix| {
                const obj = try self.evalExpr(ix.object, scope);
                const key = try self.evalExpr(ix.key, scope);
                return try self.indexGet(obj, key, node.line, node.col);
            },
            .field => |f| {
                const obj = try self.evalExpr(f.object, scope);
                if (obj == .nul) return Value{ .nul = {} };
                return try self.fieldGet(obj, f.name, node.line, node.col);
            },
            .call => |c| {
                const named_vals = try self.alloc.alloc(NamedArg, c.named.len);
                for (c.named, 0..) |e, i| {
                    const key = try self.mapKeyStr(e.key, scope);
                    const val = try self.evalExpr(e.value, scope);
                    named_vals[i] = .{ .name = key, .value = val };
                }
                if (c.callee) |callee_node| {
                    const obj = try self.evalExpr(callee_node, scope);
                    const args = try self.alloc.alloc(Value, c.args.len);
                    for (c.args, 0..) |an, i| args[i] = try self.evalExpr(an, scope);
                    return try self.callMethod(obj, c.name, args, node.line, node.col);
                }
                if (scope.lookup(c.name)) |vptr| {
                    if (vptr.* == .closure) {
                        const args = try self.alloc.alloc(Value, c.args.len);
                        for (c.args, 0..) |an, i| args[i] = try self.evalExpr(an, scope);
                        return try self.callClosure(vptr.*.closure, args);
                    }
                }
                const args = try self.alloc.alloc(Value, c.args.len);
                for (c.args, 0..) |an, i| args[i] = try self.evalExpr(an, scope);
                const forward_name = if (std.mem.eql(u8, c.name, "print")) "println" else c.name;
                return try self.host.call(self.host.ctx, self, forward_name, args, named_vals, node.line, node.col);
            },
            .closure => |cl| {
                return Value{ .closure = .{ .params = cl.params, .body = cl.body, .captured = scope } };
            },
            .assign => |a| {
                const value = try self.evalExpr(a.value, scope);
                switch (a.target.data) {
                    .ident => |name| {
                        const cur: Value = if (a.op == .assign) Value{ .nul = {} } else blk: {
                            const ptr = scope.lookup(name) orelse return self.fail(node.line, node.col, "groovy: undefined variable '{s}'", .{name});
                            break :blk ptr.*;
                        };
                        const final = try self.combineAssign(a.op, cur, value, node.line, node.col);
                        try self.assignVar(scope, name, final);
                        return final;
                    },
                    .field => |f| {
                        const obj = try self.evalExpr(f.object, scope);
                        const final = if (a.op == .assign) value else blk: {
                            const cur = try self.fieldGet(obj, f.name, node.line, node.col);
                            break :blk try self.combineAssign(a.op, cur, value, node.line, node.col);
                        };
                        switch (obj) {
                            .map => |m| try m.put(self.alloc, f.name, final),
                            else => return self.fail(node.line, node.col, "groovy: cannot assign field on this value", .{}),
                        }
                        return final;
                    },
                    .index => |ix| {
                        const obj = try self.evalExpr(ix.object, scope);
                        const key = try self.evalExpr(ix.key, scope);
                        const final = if (a.op == .assign) value else blk: {
                            const cur = try self.indexGet(obj, key, node.line, node.col);
                            break :blk try self.combineAssign(a.op, cur, value, node.line, node.col);
                        };
                        switch (obj) {
                            .list => |list| {
                                const idx = asInt(key) orelse return self.fail(node.line, node.col, "groovy: list index must be an integer", .{});
                                var i = idx;
                                if (i < 0) i += @as(i64, @intCast(list.items.len));
                                if (i < 0 or i >= @as(i64, @intCast(list.items.len))) return self.fail(node.line, node.col, "groovy: list index out of range", .{});
                                list.items[@intCast(i)] = final;
                            },
                            .map => |m| {
                                const ks = try self.toStr(key);
                                try m.put(self.alloc, ks, final);
                            },
                            else => return self.fail(node.line, node.col, "groovy: cannot index-assign on this value", .{}),
                        }
                        return final;
                    },
                    else => return self.fail(node.line, node.col, "groovy: invalid assignment target", .{}),
                }
            },
            else => return self.fail(node.line, node.col, "groovy: unsupported expression", .{}),
        }
    }

    fn execBlock(self: *Interp, stmts: []*ast.Node, scope: *Scope) InterpError!Control {
        var last = Value{ .nul = {} };
        for (stmts) |s| {
            const c = try self.execStmt(s, scope);
            switch (c) {
                .normal => |v| last = v,
                else => return c,
            }
        }
        return Control{ .normal = last };
    }

    fn execStmt(self: *Interp, node: *ast.Node, scope: *Scope) InterpError!Control {
        switch (node.data) {
            .var_decl => |vd| {
                const value: Value = if (vd.value) |ve| try self.evalExpr(ve, scope) else Value{ .nul = {} };
                try scope.vars.put(self.alloc, vd.name, value);
                return Control{ .normal = value };
            },
            .if_stmt => |s| {
                const c = try self.evalExpr(s.cond, scope);
                if (truthy(c)) {
                    const child = try self.newScope(scope);
                    return try self.execBlock(s.then_body, child);
                } else if (s.else_body) |eb| {
                    const child = try self.newScope(scope);
                    return try self.execBlock(eb, child);
                }
                return Control{ .normal = Value{ .nul = {} } };
            },
            .while_stmt => |s| {
                var iters: u64 = 0;
                const child = try self.newScope(scope);
                while (true) {
                    const c = try self.evalExpr(s.cond, scope);
                    if (!truthy(c)) break;
                    iters += 1;
                    if (iters > self.loop_guard_max) return self.fail(node.line, node.col, "groovy: loop iteration limit exceeded", .{});
                    child.vars.clearRetainingCapacity();
                    const ctrl = try self.execBlock(s.body, child);
                    switch (ctrl) {
                        .normal, .continued => {},
                        .broke => break,
                        .returned => return ctrl,
                    }
                }
                return Control{ .normal = Value{ .nul = {} } };
            },
            .for_in => |s| {
                const iterable = try self.evalExpr(s.iterable, scope);
                const child = try self.newScope(scope);
                switch (iterable) {
                    .list => |list| {
                        for (list.items) |item| {
                            child.vars.clearRetainingCapacity();
                            try child.vars.put(self.alloc, s.var_name, item);
                            const ctrl = try self.execBlock(s.body, child);
                            switch (ctrl) {
                                .normal, .continued => {},
                                .broke => break,
                                .returned => return ctrl,
                            }
                        }
                    },
                    .map => |m| {
                        var it = m.iterator();
                        while (it.next()) |entry| {
                            child.vars.clearRetainingCapacity();
                            try child.vars.put(self.alloc, s.var_name, Value{ .string = entry.key_ptr.* });
                            const ctrl = try self.execBlock(s.body, child);
                            switch (ctrl) {
                                .normal, .continued => {},
                                .broke => break,
                                .returned => return ctrl,
                            }
                        }
                    },
                    else => return self.fail(node.line, node.col, "groovy: for-in requires a list or map", .{}),
                }
                return Control{ .normal = Value{ .nul = {} } };
            },
            .try_stmt => |s| {
                const body_scope = try self.newScope(scope);
                const result = self.execBlock(s.body, body_scope);
                if (result) |ctrl| {
                    if (s.finally_body) |fb| {
                        const fscope = try self.newScope(scope);
                        const fctrl = try self.execBlock(fb, fscope);
                        switch (fctrl) {
                            .normal => {},
                            else => return fctrl,
                        }
                    }
                    return ctrl;
                } else |err| {
                    if (err == error.OutOfMemory) return err;
                    if (s.catch_body) |cb| {
                        const cscope = try self.newScope(scope);
                        if (s.catch_param) |p| {
                            try cscope.vars.put(self.alloc, p, Value{ .string = "error" });
                        }
                        const cctrl = try self.execBlock(cb, cscope);
                        if (s.finally_body) |fb| {
                            const fscope = try self.newScope(scope);
                            const fctrl = try self.execBlock(fb, fscope);
                            switch (fctrl) {
                                .normal => {},
                                else => return fctrl,
                            }
                        }
                        return cctrl;
                    } else {
                        if (s.finally_body) |fb| {
                            const fscope = try self.newScope(scope);
                            _ = try self.execBlock(fb, fscope);
                        }
                        return err;
                    }
                }
            },
            .ret => |r| {
                const value: Value = if (r) |ve| try self.evalExpr(ve, scope) else Value{ .nul = {} };
                return Control{ .returned = value };
            },
            .brk => return .broke,
            .cont => return .continued,
            else => {
                const v = try self.evalExpr(node, scope);
                return Control{ .normal = v };
            },
        }
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const TestCall = struct {
    name: []const u8,
    args: [][]const u8,
    named: [][]const u8,
};

const TestHost = struct {
    alloc: std.mem.Allocator,
    calls: std.ArrayList(TestCall) = .empty,
    responses: std.StringHashMapUnmanaged(Value) = .{},

    fn setResponse(self: *TestHost, name: []const u8, v: Value) !void {
        try self.responses.put(self.alloc, name, v);
    }

    fn call(ctx: *anyopaque, interp: *Interp, name: []const u8, args: []Value, named: []const NamedArg, line: u32, col: u32) InterpError!Value {
        _ = line;
        _ = col;
        const self: *TestHost = @ptrCast(@alignCast(ctx));
        const arg_strs = try self.alloc.alloc([]const u8, args.len);
        for (args, 0..) |a, i| arg_strs[i] = try interp.toStr(a);
        const named_strs = try self.alloc.alloc([]const u8, named.len);
        for (named, 0..) |n, i| {
            const vs = try interp.toStr(n.value);
            named_strs[i] = try std.fmt.allocPrint(self.alloc, "{s}={s}", .{ n.name, vs });
        }
        try self.calls.append(self.alloc, .{ .name = try self.alloc.dupe(u8, name), .args = arg_strs, .named = named_strs });
        if (self.responses.get(name)) |v| return v;
        return Value{ .nul = {} };
    }
};

fn testInterp(alloc: std.mem.Allocator, diags: *yaml.Diags, th: *TestHost) !*Interp {
    th.* = .{ .alloc = alloc };
    const host = Host{ .ctx = @ptrCast(th), .call = TestHost.call };
    return try Interp.init(alloc, diags, host);
}

fn runSrc(alloc: std.mem.Allocator, interp: *Interp, diags: *yaml.Diags, src: []const u8) !Value {
    const stmts = try ast.parse(alloc, src, diags);
    return try interp.run(stmts);
}

test "literals, arithmetic, and operator precedence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    var th: TestHost = undefined;
    const interp = try testInterp(a, &diags, &th);
    const v = try runSrc(a, interp, &diags, "return 1 + 2 * 3");
    try std.testing.expectEqual(@as(i64, 7), v.int);
    const v2 = try runSrc(a, interp, &diags, "return 7 / 2");
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), v2.float, 0.0001);
    const v3 = try runSrc(a, interp, &diags, "return 6 / 2");
    try std.testing.expectEqual(@as(i64, 3), v3.int);
}

test "string concat and GString interpolation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    var th: TestHost = undefined;
    const interp = try testInterp(a, &diags, &th);
    const v = try runSrc(a, interp, &diags, "return 'a' + 'b'");
    try std.testing.expectEqualStrings("ab", v.string);
    const v2 = try runSrc(a, interp, &diags,
        \\def name = 'world'
        \\return "hello ${name}!"
    );
    try std.testing.expectEqualStrings("hello world!", v2.string);
}

test "truthiness table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    var th: TestHost = undefined;
    const interp = try testInterp(a, &diags, &th);
    try std.testing.expect(!truthy((try runSrc(a, interp, &diags, "return 0"))));
    try std.testing.expect(!truthy((try runSrc(a, interp, &diags, "return ''"))));
    try std.testing.expect(!truthy((try runSrc(a, interp, &diags, "return []"))));
    try std.testing.expect(!truthy((try runSrc(a, interp, &diags, "return [:]"))));
    try std.testing.expect(!truthy((try runSrc(a, interp, &diags, "return null"))));
    try std.testing.expect(truthy((try runSrc(a, interp, &diags, "return 1"))));
    try std.testing.expect(truthy((try runSrc(a, interp, &diags, "return 'x'"))));
}

test "deep equality for lists and maps" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    var th: TestHost = undefined;
    const interp = try testInterp(a, &diags, &th);
    const v = try runSrc(a, interp, &diags, "return [1,2] == [1,2]");
    try std.testing.expect(v.boolean);
    const v2 = try runSrc(a, interp, &diags, "return [a:1,b:2] == [b:2,a:1]");
    try std.testing.expect(v2.boolean);
    const v3 = try runSrc(a, interp, &diags, "return [1,2] == [1,3]");
    try std.testing.expect(!v3.boolean);
}

test "elvis and ternary" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    var th: TestHost = undefined;
    const interp = try testInterp(a, &diags, &th);
    const v = try runSrc(a, interp, &diags, "return null ?: 5");
    try std.testing.expectEqual(@as(i64, 5), v.int);
    const v2 = try runSrc(a, interp, &diags, "return true ? 1 : 2");
    try std.testing.expectEqual(@as(i64, 1), v2.int);
}

test "def/assign scoping and global binding write from nested scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    var th: TestHost = undefined;
    const interp = try testInterp(a, &diags, &th);
    const v = try runSrc(a, interp, &diags,
        \\x = 1
        \\if (true) { x = 2 }
        \\return x
    );
    try std.testing.expectEqual(@as(i64, 2), v.int);
    // undeclared bare assignment inside closure creates a global
    const v2 = try runSrc(a, interp, &diags,
        \\def f = { newGlobal = 42 }
        \\f()
        \\return newGlobal
    );
    try std.testing.expectEqual(@as(i64, 42), v2.int);
}

test "undefined variable read fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    var th: TestHost = undefined;
    const interp = try testInterp(a, &diags, &th);
    try std.testing.expectError(error.EvalFailed, runSrc(a, interp, &diags, "return doesNotExist"));
}

test "list and map index read/write, negative index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    var th: TestHost = undefined;
    const interp = try testInterp(a, &diags, &th);
    const v = try runSrc(a, interp, &diags,
        \\def list = [1,2,3]
        \\list[0] = 9
        \\return list[-1]
    );
    try std.testing.expectEqual(@as(i64, 3), v.int);
    const v2 = try runSrc(a, interp, &diags,
        \\def m = [a: 1]
        \\m['b'] = 2
        \\return m['b']
    );
    try std.testing.expectEqual(@as(i64, 2), v2.int);
}

test "ranges materialize eagerly, inclusive and exclusive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    var th: TestHost = undefined;
    const interp = try testInterp(a, &diags, &th);
    const v = try runSrc(a, interp, &diags, "return (1..3).size()");
    try std.testing.expectEqual(@as(i64, 3), v.int);
    const v2 = try runSrc(a, interp, &diags, "return (1..<3).size()");
    try std.testing.expectEqual(@as(i64, 2), v2.int);
}

test "string methods" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    var th: TestHost = undefined;
    const interp = try testInterp(a, &diags, &th);
    const v = try runSrc(a, interp, &diags, "return 'a,b,,c'.split(',').size()");
    try std.testing.expectEqual(@as(i64, 4), v.int);
    const v2 = try runSrc(a, interp, &diags, "return 'a,b,,c'.tokenize(',').size()");
    try std.testing.expectEqual(@as(i64, 3), v2.int);
    const v3 = try runSrc(a, interp, &diags, "return 'hello'.replace('l', 'L')");
    try std.testing.expectEqualStrings("heLLo", v3.string);
    const v4 = try runSrc(a, interp, &diags, "return '42'.toInteger()");
    try std.testing.expectEqual(@as(i64, 42), v4.int);
    const v5 = try runSrc(a, interp, &diags, "return 'hello'.contains('ell')");
    try std.testing.expect(v5.boolean);
}

test "list each/collect/find/findAll/join/<<" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    var th: TestHost = undefined;
    const interp = try testInterp(a, &diags, &th);
    const v = try runSrc(a, interp, &diags,
        \\def sum = 0
        \\[1,2,3].each { sum += it }
        \\return sum
    );
    try std.testing.expectEqual(@as(i64, 6), v.int);
    const v2 = try runSrc(a, interp, &diags, "return [1,2,3].collect { it * 2 }.join(',')");
    try std.testing.expectEqualStrings("2,4,6", v2.string);
    const v3 = try runSrc(a, interp, &diags, "return [1,2,3].find { it > 1 }");
    try std.testing.expectEqual(@as(i64, 2), v3.int);
    const v4 = try runSrc(a, interp, &diags, "return [1,2,3].findAll { it > 1 }.size()");
    try std.testing.expectEqual(@as(i64, 2), v4.int);
    const v5 = try runSrc(a, interp, &diags,
        \\def list = [1]
        \\list << 2
        \\return list.size()
    );
    try std.testing.expectEqual(@as(i64, 2), v5.int);
}

test "map each with two-param closure, containsKey, put" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    var th: TestHost = undefined;
    const interp = try testInterp(a, &diags, &th);
    const v = try runSrc(a, interp, &diags,
        \\def m = [a: 1, b: 2]
        \\def total = 0
        \\m.each { k, v -> total += v }
        \\return total
    );
    try std.testing.expectEqual(@as(i64, 3), v.int);
    const v2 = try runSrc(a, interp, &diags, "return [a:1].containsKey('a')");
    try std.testing.expect(v2.boolean);
    const v3 = try runSrc(a, interp, &diags,
        \\def m = [:]
        \\m.put('x', 5)
        \\return m.get('x')
    );
    try std.testing.expectEqual(@as(i64, 5), v3.int);
}

test "map.each with wrong-arity closure fails" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    var th: TestHost = undefined;
    const interp = try testInterp(a, &diags, &th);
    try std.testing.expectError(error.EvalFailed, runSrc(a, interp, &diags, "[a:1].each { it }"));
}

test "closure call via variable, implicit it, multi-param" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    var th: TestHost = undefined;
    const interp = try testInterp(a, &diags, &th);
    const v = try runSrc(a, interp, &diags,
        \\def double = { it * 2 }
        \\return double(21)
    );
    try std.testing.expectEqual(@as(i64, 42), v.int);
    const v2 = try runSrc(a, interp, &diags,
        \\def add = { a, b -> a + b }
        \\return add(2, 3)
    );
    try std.testing.expectEqual(@as(i64, 5), v2.int);
}

test "user closure shadows host free function" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    var th: TestHost = undefined;
    const interp = try testInterp(a, &diags, &th);
    const v = try runSrc(a, interp, &diags,
        \\def sh = { 'shadowed' }
        \\return sh()
    );
    try std.testing.expectEqualStrings("shadowed", v.string);
    try std.testing.expectEqual(@as(usize, 0), th.calls.items.len);
}

test "host receives unresolved calls with positional, named args, and trailing closure" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    var th: TestHost = undefined;
    const interp = try testInterp(a, &diags, &th);
    _ = try runSrc(a, interp, &diags, "sh script: 'ls', returnStdout: true");
    try std.testing.expectEqual(@as(usize, 1), th.calls.items.len);
    try std.testing.expectEqualStrings("sh", th.calls.items[0].name);
    try std.testing.expectEqual(@as(usize, 2), th.calls.items[0].named.len);

    _ = try runSrc(a, interp, &diags, "node { echo 'hi' }");
    try std.testing.expectEqualStrings("node", th.calls.items[1].name);
    try std.testing.expectEqual(@as(usize, 1), th.calls.items[1].args.len);
}

test "println and print forward to host as println" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    var th: TestHost = undefined;
    const interp = try testInterp(a, &diags, &th);
    _ = try runSrc(a, interp, &diags, "println 'hi'\nprint 'bye'");
    try std.testing.expectEqualStrings("println", th.calls.items[0].name);
    try std.testing.expectEqualStrings("println", th.calls.items[1].name);
}

test "if/while/for-in with break and continue" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    var th: TestHost = undefined;
    const interp = try testInterp(a, &diags, &th);
    const v = try runSrc(a, interp, &diags,
        \\def sum = 0
        \\def i = 0
        \\while (i < 10) {
        \\  i += 1
        \\  if (i == 5) { continue }
        \\  if (i > 8) { break }
        \\  sum += i
        \\}
        \\return sum
    );
    try std.testing.expectEqual(@as(i64, 1 + 2 + 3 + 4 + 6 + 7 + 8), v.int);
    const v2 = try runSrc(a, interp, &diags,
        \\def sum = 0
        \\for (x in [1,2,3,4]) {
        \\  if (x == 2) { continue }
        \\  if (x == 4) { break }
        \\  sum += x
        \\}
        \\return sum
    );
    try std.testing.expectEqual(@as(i64, 1 + 3), v2.int);
}

test "return from closure unwinds only that call" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    var th: TestHost = undefined;
    const interp = try testInterp(a, &diags, &th);
    const v = try runSrc(a, interp, &diags,
        \\def f = {
        \\  if (true) { return 1 }
        \\  return 2
        \\}
        \\def x = f()
        \\return x + 10
    );
    try std.testing.expectEqual(@as(i64, 11), v.int);
}

test "while loop guard triggers on runaway loop" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    var th: TestHost = undefined;
    const interp = try testInterp(a, &diags, &th);
    interp.loop_guard_max = 10;
    try std.testing.expectError(error.EvalFailed, runSrc(a, interp, &diags, "while (true) { }"));
}

test "try/catch swallows EvalFailed and finally runs on both paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    var th: TestHost = undefined;
    const interp = try testInterp(a, &diags, &th);
    const v = try runSrc(a, interp, &diags,
        \\def log = []
        \\try {
        \\  log << 'try'
        \\  return boom
        \\} catch (e) {
        \\  log << 'catch'
        \\} finally {
        \\  log << 'finally'
        \\}
        \\return log.join(',')
    );
    try std.testing.expectEqualStrings("try,catch,finally", v.string);

    const v2 = try runSrc(a, interp, &diags,
        \\def log = []
        \\try {
        \\  log << 'ok'
        \\} finally {
        \\  log << 'finally2'
        \\}
        \\return log.join(',')
    );
    try std.testing.expectEqualStrings("ok,finally2", v2.string);
}

test "toStr renderings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    var th: TestHost = undefined;
    const interp = try testInterp(a, &diags, &th);
    try std.testing.expectEqualStrings("null", try interp.toStr(Value{ .nul = {} }));
    try std.testing.expectEqualStrings("true", try interp.toStr(Value{ .boolean = true }));
    try std.testing.expectEqualStrings("5", try interp.toStr(Value{ .int = 5 }));
    const v = try runSrc(a, interp, &diags, "return [1, 'x', true].toString()");
    try std.testing.expectEqualStrings("[1, x, true]", v.string);
    const v2 = try runSrc(a, interp, &diags, "return [a: 1].toString()");
    try std.testing.expectEqualStrings("[a:1]", v2.string);
}

test "unary not/neg and mixed int/float arithmetic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    var th: TestHost = undefined;
    const interp = try testInterp(a, &diags, &th);
    const v = try runSrc(a, interp, &diags, "return !false");
    try std.testing.expect(v.boolean);
    const v2 = try runSrc(a, interp, &diags, "return -(3)");
    try std.testing.expectEqual(@as(i64, -3), v2.int);
    const v3 = try runSrc(a, interp, &diags, "return 1 + 2.5");
    try std.testing.expectApproxEqAbs(@as(f64, 3.5), v3.float, 0.0001);
}

test "'in' operator over list, map, and string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    var th: TestHost = undefined;
    const interp = try testInterp(a, &diags, &th);
    const v = try runSrc(a, interp, &diags, "return 2 in [1,2,3]");
    try std.testing.expect(v.boolean);
    const v2 = try runSrc(a, interp, &diags, "return 'a' in [a: 1]");
    try std.testing.expect(v2.boolean);
    const v3 = try runSrc(a, interp, &diags, "return 'ell' in 'hello'");
    try std.testing.expect(v3.boolean);
}

test "setGlobal / getGlobal wire env-like bindings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = yaml.Diags.init(a);
    var th: TestHost = undefined;
    const interp = try testInterp(a, &diags, &th);
    const m = try a.create(ValueMap);
    m.* = .{};
    try m.put(a, "BUILD_NUMBER", Value{ .string = "42" });
    try interp.setGlobal("env", Value{ .map = m });
    const v = try runSrc(a, interp, &diags, "return env.BUILD_NUMBER");
    try std.testing.expectEqualStrings("42", v.string);
    try std.testing.expect(interp.getGlobal("env") != null);
}
