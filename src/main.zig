const std = @import("std");
const builtin = @import("builtin");
const jalan = @import("jalan");

// std.os.windows.kernel32 doesn't bind these two — declare them locally.
// Without this, `breakpoint —` (and any other non-ASCII output jalan writes,
// which is UTF-8) renders as mojibake on a Windows console left at its
// default (often non-UTF-8) codepage.
const CP_UTF8: c_uint = 65001;
extern "kernel32" fn SetConsoleOutputCP(wCodePageID: c_uint) callconv(.winapi) std.os.windows.BOOL;
extern "kernel32" fn SetConsoleCP(wCodePageID: c_uint) callconv(.winapi) std.os.windows.BOOL;

pub fn main() !void {
    if (builtin.os.tag == .windows) {
        _ = SetConsoleOutputCP(CP_UTF8);
        _ = SetConsoleCP(CP_UTF8);
    }
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    const args = try std.process.argsAlloc(arena.allocator());
    const code = jalan.cli.main(arena.allocator(), args[1..]) catch |e| blk: {
        std.debug.print("internal error: {s}\n", .{@errorName(e)});
        break :blk 3;
    };
    std.process.exit(code);
}
