//! Atomic cross-platform file replacement.
const std = @import("std");
const builtin = @import("builtin");

/// Replace `dest` with `tmp` atomically. POSIX rename replaces in one
/// operation; Windows needs MoveFileExW with REPLACE_EXISTING.
pub fn replaceFile(tmp: []const u8, dest: []const u8) !void {
    if (builtin.os.tag == .windows)
        return std.os.windows.MoveFileEx(tmp, dest, 0x1 | 0x8); // REPLACE_EXISTING | WRITE_THROUGH
    return std.fs.cwd().rename(tmp, dest);
}
