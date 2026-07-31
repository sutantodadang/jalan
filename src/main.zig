const std = @import("std");
const jalan = @import("jalan");

pub fn main() !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try std.process.argsAlloc(arena.allocator());
    const code = jalan.cli.main(arena.allocator(), args[1..]) catch |e| blk: {
        std.debug.print("internal error: {s}\n", .{@errorName(e)});
        break :blk 3;
    };
    std.process.exit(code);
}
