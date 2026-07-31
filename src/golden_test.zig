const std = @import("std");
const yaml = @import("yaml.zig");
const ir = @import("ir.zig");
const gha = @import("frontend/gha.zig");

// To regenerate goldens: uncomment the print in the loop, run
// `zig build test 2>&1`, paste output into the .ir.json file.
test "golden: workflows lower to stable IR json" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][]const u8{ "basic", "matrix" };
    for (cases) |case| {
        const yml_path = try std.fmt.allocPrint(a, "testdata/workflows/{s}.yml", .{case});
        const json_path = try std.fmt.allocPrint(a, "testdata/workflows/{s}.ir.json", .{case});
        const src = try std.fs.cwd().readFileAlloc(a, yml_path, 1 << 20);
        var diags = yaml.Diags.init(a);
        const p = try gha.parseWorkflow(a, yml_path, src, &diags);
        const got = try ir.toJson(a, p);
        // std.debug.print("GOLDEN {s}: {s}\n", .{ case, got });
        const want = std.mem.trim(u8, try std.fs.cwd().readFileAlloc(a, json_path, 1 << 20), " \n\r");
        try std.testing.expectEqualStrings(want, got);
    }
}
