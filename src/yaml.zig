const std = @import("std");

pub const Diag = struct { line: u32, col: u32, msg: []const u8 };

pub const Diags = struct {
    alloc: std.mem.Allocator,
    list: std.ArrayList(Diag) = .empty,
    pub fn init(alloc: std.mem.Allocator) Diags {
        return .{ .alloc = alloc };
    }
    pub fn add(self: *Diags, line: u32, col: u32, comptime fmt: []const u8, args: anytype) !void {
        const msg = try std.fmt.allocPrint(self.alloc, fmt, args);
        try self.list.append(self.alloc, .{ .line = line, .col = col, .msg = msg });
    }
};

pub const Map = std.StringArrayHashMapUnmanaged(Node);

pub const Node = struct {
    line: u32,
    col: u32,
    data: Data,

    pub const Data = union(enum) {
        scalar: []const u8,
        seq: []Node,
        map: Map,
    };

    pub fn get(self: Node, key: []const u8) ?Node {
        return switch (self.data) {
            .map => |m| m.get(key),
            else => null,
        };
    }

    pub fn scalarOr(self: Node, default: []const u8) []const u8 {
        return switch (self.data) {
            .scalar => |s| s,
            else => default,
        };
    }
};

pub const ParseError = error{ ParseFailed, OutOfMemory };

const Line = struct { indent: u32, text: []const u8, no: u32 };

const Parser = struct {
    alloc: std.mem.Allocator,
    lines: []Line,
    idx: usize = 0,
    diags: *Diags,

    fn peek(self: *Parser) ?Line {
        return if (self.idx < self.lines.len) self.lines[self.idx] else null;
    }

    fn parseValueText(self: *Parser, text: []const u8, no: u32, col: u32) ParseError!Node {
        _ = self;
        return .{ .line = no, .col = col, .data = .{ .scalar = std.mem.trim(u8, text, " ") } };
    }

    fn parseBlock(self: *Parser, min_indent: u32) ParseError!Node {
        const first = self.peek() orelse
            return .{ .line = 0, .col = 0, .data = .{ .scalar = "" } };
        return self.parseMapBlock(first.indent, min_indent);
    }

    fn parseMapBlock(self: *Parser, base_indent: u32, min_indent: u32) ParseError!Node {
        var m: Map = .empty;
        const start = self.peek().?;
        while (self.peek()) |ln| {
            if (ln.indent < base_indent or ln.indent < min_indent) break;
            if (ln.indent > base_indent) {
                try self.diags.add(ln.no, ln.indent + 1, "unexpected indentation", .{});
                self.idx += 1;
                continue;
            }
            const colon = findKeyColon(ln.text) orelse {
                try self.diags.add(ln.no, ln.indent + 1, "expected 'key:' in mapping", .{});
                self.idx += 1;
                continue;
            };
            const key = std.mem.trim(u8, ln.text[0..colon], " \"'");
            const rest = std.mem.trim(u8, ln.text[colon + 1 ..], " ");
            self.idx += 1;
            var value: Node = undefined;
            if (rest.len > 0) {
                const after_colon = ln.text[colon + 1 ..];
                var off: usize = 0;
                while (off < after_colon.len and after_colon[off] == ' ') off += 1;
                const value_col = ln.indent + @as(u32, @intCast(colon)) + 1 + @as(u32, @intCast(off)) + 1;
                value = try self.parseValueText(rest, ln.no, value_col);
            } else if (self.peek()) |next| {
                if (next.indent > base_indent) {
                    value = try self.parseBlock(base_indent + 1);
                    // Anchor the nested block's position to its "key:" line,
                    // not the first line inside the block.
                    value.line = ln.no;
                    value.col = ln.indent + 1;
                } else {
                    value = .{ .line = ln.no, .col = ln.indent + 1, .data = .{ .scalar = "" } };
                }
            } else {
                value = .{ .line = ln.no, .col = ln.indent + 1, .data = .{ .scalar = "" } };
            }
            try m.put(self.alloc, key, value);
        }
        return .{ .line = start.no, .col = start.indent + 1, .data = .{ .map = m } };
    }
};

/// Colon that terminates a key: first ':' followed by space/EOL, outside quotes.
fn findKeyColon(text: []const u8) ?usize {
    var in_s = false;
    var in_d = false;
    for (text, 0..) |c, i| {
        switch (c) {
            '\'' => in_s = !in_s,
            '"' => in_d = !in_d,
            ':' => if (!in_s and !in_d) {
                if (i + 1 == text.len or text[i + 1] == ' ') return i;
            },
            else => {},
        }
    }
    return null;
}

pub fn parse(alloc: std.mem.Allocator, source: []const u8, diags: *Diags) ParseError!Node {
    var lines: std.ArrayList(Line) = .empty;
    var it = std.mem.splitScalar(u8, source, '\n');
    var no: u32 = 0;
    while (it.next()) |raw| {
        no += 1;
        const line = std.mem.trimRight(u8, raw, " \r");
        if (line.len == 0) continue;
        var indent: u32 = 0;
        for (line) |c| {
            if (c == ' ') indent += 1 else if (c == '\t') {
                try diags.add(no, indent + 1, "tab indentation not allowed in YAML", .{});
                break;
            } else break;
        }
        const text = line[indent..];
        if (text.len == 0 or text[0] == '#') continue;
        try lines.append(alloc, .{ .indent = indent, .text = text, .no = no });
    }
    var p = Parser{ .alloc = alloc, .lines = lines.items, .diags = diags };
    const root = try p.parseBlock(0);
    if (diags.list.items.len > 0) return error.ParseFailed;
    return root;
}

// ...implementation goes above tests...

test "parse flat mapping of scalars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = Diags.init(a);
    const root = try parse(a,
        \\name: CI
        \\version: 2
    , &diags);
    try std.testing.expectEqualStrings("CI", root.get("name").?.data.scalar);
    try std.testing.expectEqualStrings("2", root.get("version").?.data.scalar);
    try std.testing.expectEqual(@as(usize, 0), diags.list.items.len);
}

test "parse nested mapping tracks line numbers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = Diags.init(a);
    const root = try parse(a,
        \\jobs:
        \\  build:
        \\    name: Build it
    , &diags);
    const build = root.get("jobs").?.get("build").?;
    try std.testing.expectEqualStrings("Build it", build.get("name").?.data.scalar);
    try std.testing.expectEqual(@as(u32, 2), build.line);
}

test "inline scalar column points at the value, not the separator" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = Diags.init(a);
    const root = try parse(a,
        \\name: CI
    , &diags);
    const name = root.get("name").?;
    try std.testing.expectEqualStrings("CI", name.data.scalar);
    try std.testing.expectEqual(@as(u32, 7), name.col);
}

test "inline scalar column accounts for extra spaces after colon" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = Diags.init(a);
    const root = try parse(a,
        \\name:  CI
    , &diags);
    const name = root.get("name").?;
    try std.testing.expectEqualStrings("CI", name.data.scalar);
    try std.testing.expectEqual(@as(u32, 8), name.col);
}

test "tab indentation is a diagnostic" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = Diags.init(a);
    _ = parse(a, "jobs:\n\tbuild: x", &diags) catch {};
    try std.testing.expect(diags.list.items.len > 0);
}
