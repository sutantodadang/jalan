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

const Line = struct { indent: u32, text: []const u8, raw: []const u8, no: u32, comment_only: bool = false };

const Parser = struct {
    alloc: std.mem.Allocator,
    lines: []Line,
    idx: usize = 0,
    diags: *Diags,

    fn peek(self: *Parser) ?Line {
        return if (self.idx < self.lines.len) self.lines[self.idx] else null;
    }

    fn parseValueText(self: *Parser, text: []const u8, no: u32, col: u32) ParseError!Node {
        const t = std.mem.trim(u8, text, " ");
        if (t.len >= 2 and t[0] == '[' and t[t.len - 1] == ']') {
            var items: std.ArrayList(Node) = .empty;
            var it = std.mem.splitScalar(u8, t[1 .. t.len - 1], ',');
            while (it.next()) |part| {
                const p = std.mem.trim(u8, part, " ");
                if (p.len == 0) continue;
                try items.append(self.alloc, try self.parseValueText(p, no, col));
            }
            return .{ .line = no, .col = col, .data = .{ .seq = try items.toOwnedSlice(self.alloc) } };
        }
        if (t.len >= 2 and t[0] == '"' and t[t.len - 1] == '"')
            return .{ .line = no, .col = col, .data = .{ .scalar = try unescapeDouble(self.alloc, t[1 .. t.len - 1]) } };
        if (t.len >= 2 and t[0] == '\'' and t[t.len - 1] == '\'')
            return .{ .line = no, .col = col, .data = .{ .scalar = t[1 .. t.len - 1] } };
        return .{ .line = no, .col = col, .data = .{ .scalar = t } };
    }

    /// Comment-only lines carry content for block scalars but must be
    /// invisible to every other consumer of `lines` — skip past any run of
    /// them regardless of indent so they never get mistaken for a key,
    /// sequence item, or an out-dent that would end a block.
    fn skipComments(self: *Parser) void {
        while (self.peek()) |ln| {
            if (!ln.comment_only) break;
            self.idx += 1;
        }
    }

    fn parseBlock(self: *Parser, min_indent: u32) ParseError!Node {
        self.skipComments();
        const first = self.peek() orelse
            return .{ .line = 0, .col = 0, .data = .{ .scalar = "" } };
        if (std.mem.startsWith(u8, first.text, "- ") or std.mem.eql(u8, first.text, "-"))
            return self.parseSeqBlock(first.indent, min_indent);
        return self.parseMapBlock(first.indent, min_indent);
    }

    fn parseSeqBlock(self: *Parser, base_indent: u32, min_indent: u32) ParseError!Node {
        var items: std.ArrayList(Node) = .empty;
        const start = self.peek().?;
        while (self.peek()) |ln| {
            if (ln.comment_only) {
                self.idx += 1;
                continue;
            }
            if (ln.indent != base_indent or ln.indent < min_indent) break;
            if (!std.mem.startsWith(u8, ln.text, "-")) break;
            const rest = std.mem.trim(u8, ln.text[1..], " ");
            if (rest.len == 0) {
                self.idx += 1;
                try items.append(self.alloc, try self.parseBlock(base_indent + 1));
            } else if (findKeyColon(rest) != null or std.mem.startsWith(u8, rest, "-")) {
                // Re-enter the item's remainder as a virtual deeper line so
                // `- key: v` merges with following lines indented past the dash.
                const raw_rest = std.mem.trim(u8, ln.raw[1..], " ");
                self.lines[self.idx] = .{ .indent = base_indent + 2, .text = rest, .raw = raw_rest, .no = ln.no };
                try items.append(self.alloc, try self.parseBlock(base_indent + 1));
            } else {
                // Plain scalar item: `- build` (no colon, no nested seq).
                var off: usize = 1;
                while (off < ln.text.len and ln.text[off] == ' ') off += 1;
                const item_col = ln.indent + @as(u32, @intCast(off)) + 1;
                self.idx += 1;
                try items.append(self.alloc, try self.parseValueText(rest, ln.no, item_col));
            }
        }
        return .{
            .line = start.no,
            .col = base_indent + 1,
            .data = .{ .seq = try items.toOwnedSlice(self.alloc) },
        };
    }

    fn parseBlockScalar(self: *Parser, marker: []const u8, base_indent: u32, no: u32) ParseError!Node {
        const folded = marker[0] == '>';
        var parts: std.ArrayList([]const u8) = .empty;
        var content_indent: ?u32 = null;
        while (self.peek()) |ln| {
            if (ln.indent <= base_indent) break;
            if (content_indent == null) content_indent = ln.indent;
            const keep = if (ln.indent >= content_indent.?) ln.indent - content_indent.? else 0;
            var buf: std.ArrayList(u8) = .empty;
            try buf.appendNTimes(self.alloc, ' ', keep);
            try buf.appendSlice(self.alloc, ln.raw);
            try parts.append(self.alloc, try buf.toOwnedSlice(self.alloc));
            self.idx += 1;
        }
        const sep: []const u8 = if (folded) " " else "\n";
        const joined = try std.mem.join(self.alloc, sep, parts.items);
        return .{ .line = no, .col = base_indent + 1, .data = .{ .scalar = joined } };
    }

    fn parseMapBlock(self: *Parser, base_indent: u32, min_indent: u32) ParseError!Node {
        var m: Map = .empty;
        const start = self.peek().?;
        while (self.peek()) |ln| {
            if (ln.comment_only) {
                self.idx += 1;
                continue;
            }
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
                if ((rest[0] == '|' or rest[0] == '>') and rest.len <= 2) {
                    value = try self.parseBlockScalar(rest, base_indent, ln.no);
                } else if (rest[0] == '&' or rest[0] == '*') {
                    try self.diags.add(ln.no, value_col, "YAML anchors are not supported", .{});
                    value = try self.parseValueText(rest, ln.no, value_col);
                } else {
                    value = try self.parseValueText(rest, ln.no, value_col);
                }
            } else if (blk: {
                self.skipComments();
                break :blk self.peek();
            }) |next| {
                if (next.indent > base_indent) {
                    value = try self.parseBlock(base_indent + 1);
                    // Anchor the nested block's position to its "key:" line,
                    // not the first line inside the block.
                    value.line = ln.no;
                    value.col = ln.indent + 1;
                } else if (next.indent == base_indent and std.mem.startsWith(u8, next.text, "-")) {
                    // YAML allows a sequence value to sit at the SAME indent
                    // as its parent key (`jobs:\n- job: x`) — common in Azure
                    // and CircleCI configs.
                    value = try self.parseSeqBlock(base_indent, base_indent);
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

fn unescapeDouble(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 1;
            try out.append(alloc, switch (s[i]) {
                'n' => '\n',
                't' => '\t',
                '"' => '"',
                '\\' => '\\',
                else => s[i],
            });
        } else try out.append(alloc, s[i]);
    }
    return out.toOwnedSlice(alloc);
}

/// Strip a trailing ` # comment` outside quotes; `#` must be at index 0 or
/// preceded by a space to count as a comment marker.
fn stripComment(text: []const u8) []const u8 {
    var in_s = false;
    var in_d = false;
    for (text, 0..) |c, i| {
        switch (c) {
            '\'' => in_s = !in_s,
            '"' => in_d = !in_d,
            '#' => if (!in_s and !in_d and (i == 0 or text[i - 1] == ' '))
                return std.mem.trimRight(u8, text[0..i], " "),
            else => {},
        }
    }
    return text;
}

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
        const raw_text = line[indent..];
        const text = stripComment(raw_text);
        // A comment-only line (raw text starts with `#`) strips to empty.
        // It must still enter `lines` — block scalars need it verbatim as
        // content — but flagged so map/seq walkers skip over it instead of
        // trying to parse it as a key or item.
        try lines.append(alloc, .{ .indent = indent, .text = text, .raw = raw_text, .no = no, .comment_only = text.len == 0 });
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

test "parse block sequence of scalars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = Diags.init(a);
    const root = try parse(a,
        \\needs:
        \\  - build
        \\  - lint
    , &diags);
    const seq = root.get("needs").?.data.seq;
    try std.testing.expectEqual(@as(usize, 2), seq.len);
    try std.testing.expectEqualStrings("lint", seq[1].data.scalar);
}

test "parse sequence of mappings (steps shape)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = Diags.init(a);
    const root = try parse(a,
        \\steps:
        \\  - name: hello
        \\    run: echo hi
        \\  - run: echo two
    , &diags);
    const steps = root.get("steps").?.data.seq;
    try std.testing.expectEqual(@as(usize, 2), steps.len);
    try std.testing.expectEqualStrings("echo hi", steps[0].get("run").?.data.scalar);
    try std.testing.expectEqualStrings("echo two", steps[1].get("run").?.data.scalar);
}

test "literal block scalar preserves newlines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = Diags.init(a);
    const root = try parse(a,
        \\run: |
        \\  echo one
        \\  echo two
    , &diags);
    try std.testing.expectEqualStrings("echo one\necho two", root.get("run").?.data.scalar);
}

test "literal block scalar preserves a hash comment in content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = Diags.init(a);
    const root = try parse(a,
        \\run: |
        \\  echo one # keep me
    , &diags);
    try std.testing.expectEqualStrings("echo one # keep me", root.get("run").?.data.scalar);
}

test "literal block scalar preserves a comment-only interior line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = Diags.init(a);
    const root = try parse(a,
        \\run: |
        \\  echo one
        \\  # note
        \\  echo two
    , &diags);
    try std.testing.expectEqualStrings("echo one\n# note\necho two", root.get("run").?.data.scalar);
}

test "comment-only line between mapping keys does not break the mapping" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = Diags.init(a);
    const root = try parse(a,
        \\a: 1
        \\# c
        \\b: 2
    , &diags);
    try std.testing.expectEqualStrings("1", root.get("a").?.data.scalar);
    try std.testing.expectEqualStrings("2", root.get("b").?.data.scalar);
    try std.testing.expectEqual(@as(usize, 0), diags.list.items.len);
}

test "folded block scalar joins with spaces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = Diags.init(a);
    const root = try parse(a, "msg: >\n  hello\n  world", &diags);
    try std.testing.expectEqualStrings("hello world", root.get("msg").?.data.scalar);
}

test "inline comment stripped outside quotes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = Diags.init(a);
    const root = try parse(a, "name: CI # the pipeline\nmsg: \"a # not comment\"", &diags);
    try std.testing.expectEqualStrings("CI", root.get("name").?.data.scalar);
    try std.testing.expectEqualStrings("a # not comment", root.get("msg").?.data.scalar);
}

test "flow sequence and quoted scalars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var diags = Diags.init(a);
    const root = try parse(a,
        \\os: [ubuntu-latest, "windows-latest"]
        \\msg: "line\nbreak"
        \\lit: 'no \n escape'
    , &diags);
    const os = root.get("os").?.data.seq;
    try std.testing.expectEqualStrings("windows-latest", os[1].data.scalar);
    try std.testing.expectEqualStrings("line\nbreak", root.get("msg").?.data.scalar);
    try std.testing.expectEqualStrings("no \\n escape", root.get("lit").?.data.scalar);
}
