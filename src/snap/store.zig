//! Content-addressed blob store under `.jalan/store/`.
//!
//! Blobs are raw file contents addressed by their sha256 hex digest, fanned
//! out into `<root>/blobs/<hex[0..2]>/<hex>`. Writes are atomic: data lands
//! in `<root>/tmp/<rand>` first, then renames into place. An existing final
//! path means the content is already stored (same content = same name), so
//! the write is skipped — dedup is automatic by addressing.
const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;
const atomic = @import("atomic.zig");

pub const Error = error{ OutOfMemory, StoreIo };

pub fn isValidHex(hex: []const u8) bool {
    if (hex.len != 64) return false;
    for (hex) |c| if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false;
    return true;
}

/// Lowercase hex sha256 of `data` (64 chars, caller's allocator).
pub fn sha256Hex(alloc: std.mem.Allocator, data: []const u8) Error![]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(data, &digest, .{});
    const hex = std.fmt.bytesToHex(digest, .lower);
    return alloc.dupe(u8, &hex) catch return error.OutOfMemory;
}

/// Streamed sha256 of a file's contents.
pub fn sha256FileHex(alloc: std.mem.Allocator, abs_path: []const u8) Error![]u8 {
    const f = std.fs.openFileAbsolute(abs_path, .{}) catch return error.StoreIo;
    defer f.close();
    var h = Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = f.read(&buf) catch return error.StoreIo;
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    return alloc.dupe(u8, &hex) catch return error.OutOfMemory;
}

/// `<root>/blobs/<hex[0..2]>/<hex>`.
pub fn blobPath(alloc: std.mem.Allocator, root: []const u8, hex: []const u8) Error![]u8 {
    if (!isValidHex(hex)) return error.StoreIo;
    return std.fmt.allocPrint(alloc, "{s}/blobs/{s}/{s}", .{ root, hex[0..2], hex }) catch return error.OutOfMemory;
}

fn ensureParent(root_dir: std.fs.Dir, path: []const u8) Error!void {
    if (std.fs.path.dirname(path)) |dir| {
        root_dir.makePath(dir) catch return error.StoreIo;
    }
}

fn tmpPath(alloc: std.mem.Allocator, root: []const u8) Error![]u8 {
    var rand_buf: [8]u8 = undefined;
    std.crypto.random.bytes(&rand_buf);
    return std.fmt.allocPrint(alloc, "{s}/tmp/{s}", .{ root, std.fmt.bytesToHex(rand_buf, .lower) }) catch return error.OutOfMemory;
}

/// Store `data` as a blob; returns its hex digest. Repeated writes of the
/// same content are no-ops.
pub fn writeBlob(alloc: std.mem.Allocator, root: []const u8, data: []const u8) Error![]u8 {
    const hex = try sha256Hex(alloc, data);
    const final_rel = try blobPath(alloc, root, hex);
    var root_dir = std.fs.cwd().openDir(".", .{}) catch return error.StoreIo;
    defer root_dir.close();
    if (root_dir.access(final_rel, .{})) |_| {
        if (verifyBlob(alloc, root, hex)) |_| return hex else |_| {}
    } else |_| {}
    const tmp_rel = try tmpPath(alloc, root);
    try ensureParent(root_dir, tmp_rel);
    root_dir.writeFile(.{ .sub_path = tmp_rel, .data = data }) catch return error.StoreIo;
    errdefer root_dir.deleteFile(tmp_rel) catch {};
    try ensureParent(root_dir, final_rel);
    atomic.replaceFile(tmp_rel, final_rel) catch return error.StoreIo;
    return hex;
}

/// Read a blob by digest.
pub fn readBlob(alloc: std.mem.Allocator, root: []const u8, hex: []const u8) Error![]u8 {
    const path = try blobPath(alloc, root, hex);
    const data = std.fs.cwd().readFileAlloc(alloc, path, 1 << 31) catch return error.StoreIo;
    var digest: [32]u8 = undefined;
    Sha256.hash(data, &digest, .{});
    const actual = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &actual, hex)) return error.StoreIo;
    return data;
}

pub const CopiedFile = struct { hex: []u8, size: u64 };

/// Hash a file while streaming it into the store. File contents never enter
/// the caller's arena, which keeps repeated step snapshots bounded-memory.
pub fn copyFileToBlob(alloc: std.mem.Allocator, root: []const u8, src_abs: []const u8) Error!CopiedFile {
    const src = std.fs.openFileAbsolute(src_abs, .{}) catch return error.StoreIo;
    defer src.close();
    const tmp_rel = try tmpPath(alloc, root);
    var cwd = std.fs.cwd();
    try ensureParent(cwd, tmp_rel);
    var tmp = cwd.createFile(tmp_rel, .{}) catch return error.StoreIo;
    var tmp_open = true;
    defer if (tmp_open) tmp.close();
    errdefer cwd.deleteFile(tmp_rel) catch {};

    var h = Sha256.init(.{});
    var size: u64 = 0;
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = src.read(&buf) catch return error.StoreIo;
        if (n == 0) break;
        h.update(buf[0..n]);
        tmp.writeAll(buf[0..n]) catch return error.StoreIo;
        size += n;
    }
    tmp.close();
    tmp_open = false;
    var digest: [32]u8 = undefined;
    h.final(&digest);
    const hex_arr = std.fmt.bytesToHex(digest, .lower);
    const hex = alloc.dupe(u8, &hex_arr) catch return error.OutOfMemory;
    const final_rel = try blobPath(alloc, root, hex);
    try ensureParent(cwd, final_rel);
    if (verifyBlob(alloc, root, hex)) |_| {
        cwd.deleteFile(tmp_rel) catch {};
    } else |_| {
        atomic.replaceFile(tmp_rel, final_rel) catch return error.StoreIo;
    }
    return .{ .hex = hex, .size = size };
}

/// Verify that a blob exists and its bytes match its content address.
pub fn verifyBlob(alloc: std.mem.Allocator, root: []const u8, hex: []const u8) Error!void {
    const path = try blobPath(alloc, root, hex);
    const f = std.fs.cwd().openFile(path, .{}) catch return error.StoreIo;
    defer f.close();
    var h = Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = f.read(&buf) catch return error.StoreIo;
        if (n == 0) break;
        h.update(buf[0..n]);
    }
    var digest: [32]u8 = undefined;
    h.final(&digest);
    const actual = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &actual, hex)) return error.StoreIo;
}

/// Stream a verified blob into an already-safe destination directory. The
/// destination is replaced only after the complete blob hash is validated.
pub fn copyBlobToFile(alloc: std.mem.Allocator, root: []const u8, hex: []const u8, dst_dir: std.fs.Dir, dst_name: []const u8) Error!void {
    const path = try blobPath(alloc, root, hex);
    const src = std.fs.cwd().openFile(path, .{}) catch return error.StoreIo;
    defer src.close();
    const tmp_name = try std.fmt.allocPrint(alloc, ".jalan-restore-{x}", .{std.crypto.random.int(u64)});
    var tmp = dst_dir.createFile(tmp_name, .{ .exclusive = true }) catch return error.StoreIo;
    var tmp_open = true;
    defer if (tmp_open) tmp.close();
    errdefer dst_dir.deleteFile(tmp_name) catch {};

    var h = Sha256.init(.{});
    var buf: [64 * 1024]u8 = undefined;
    while (true) {
        const n = src.read(&buf) catch return error.StoreIo;
        if (n == 0) break;
        h.update(buf[0..n]);
        tmp.writeAll(buf[0..n]) catch return error.StoreIo;
    }
    tmp.close();
    tmp_open = false;
    var digest: [32]u8 = undefined;
    h.final(&digest);
    const actual = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &actual, hex)) return error.StoreIo;
    dst_dir.rename(tmp_name, dst_name) catch {
        dst_dir.deleteFile(dst_name) catch {};
        dst_dir.rename(tmp_name, dst_name) catch return error.StoreIo;
    };
}

test "sha256Hex matches known vector" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        try sha256Hex(a, "abc"),
    );
}

test "writeBlob dedups by content, readBlob round-trips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = ".jalan/tmp/storetest";
    std.fs.cwd().deleteTree(root) catch {};
    const h1 = try writeBlob(a, root, "hello jalan");
    const h2 = try writeBlob(a, root, "hello jalan");
    try std.testing.expectEqualStrings(h1, h2);
    try std.testing.expectEqualStrings("hello jalan", try readBlob(a, root, h1));
    const other = try writeBlob(a, root, "different");
    try std.testing.expect(!std.mem.eql(u8, h1, other));
    std.fs.cwd().deleteTree(root) catch {};
}

test "copyFileToBlob reports size and stores contents" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const root = ".jalan/tmp/storetest2";
    std.fs.cwd().deleteTree(root) catch {};
    try std.fs.cwd().makePath(root);
    const src = try std.fmt.allocPrint(a, "{s}/src.txt", .{root});
    try std.fs.cwd().writeFile(.{ .sub_path = src, .data = "0123456789" });
    const abs = try std.fs.cwd().realpathAlloc(a, src);
    const c = try copyFileToBlob(a, root, abs);
    try std.testing.expectEqual(@as(u64, 10), c.size);
    try std.testing.expectEqualStrings("0123456789", try readBlob(a, root, c.hex));
    std.fs.cwd().deleteTree(root) catch {};
}

test "blobPath fans out on first two hex chars" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const hex = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789";
    const p = try blobPath(a, ".jalan/store", hex);
    try std.testing.expect(std.mem.indexOf(u8, p, "blobs/ab/") != null);
    try std.testing.expectError(error.StoreIo, blobPath(a, ".jalan/store", "../../escape"));
}
