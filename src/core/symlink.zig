const std = @import("std");
const fs = @import("../lib/fs.zig");

const Symlink = @This();

source: []const u8,
target: []const u8,
name: []const u8,

pub const Status = enum {
    linked,
    missing,
    wrong_target,
    not_a_symlink,
    broken,
};

pub fn status(self: *const Symlink) Status {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const link_target = std.fs.readLinkAbsolute(self.target, &buf) catch |e| switch (e) {
        error.FileNotFound => return .missing,
        error.NotLink => return .not_a_symlink,
        else => return .broken,
    };

    if (std.mem.eql(u8, link_target, self.source)) {
        return .linked;
    }

    return .wrong_target;
}

pub fn link(self: *const Symlink) !void {
    try fs.ensureParentDirExists(self.target);
    std.fs.symLinkAbsolute(self.source, self.target, .{}) catch |e| switch (e) {
        error.PathAlreadyExists => {
            try self.unlink();
            try std.fs.symLinkAbsolute(self.source, self.target, .{});
        },
        else => return e,
    };
}

pub fn unlink(self: *const Symlink) !void {
    std.fs.deleteFileAbsolute(self.target) catch |e| switch (e) {
        error.FileNotFound => return,
        error.IsDir => {
            std.fs.deleteTreeAbsolute(self.target) catch return;
        },
        else => return e,
    };
}

pub fn backup(self: *const Symlink, allocator: std.mem.Allocator) !void {
    const backup_path = try std.fmt.allocPrint(allocator, "{s}.tin.bak", .{self.target});
    std.fs.renameAbsolute(self.target, backup_path) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
}

pub fn restore(self: *const Symlink, allocator: std.mem.Allocator) !void {
    const backup_path = try std.fmt.allocPrint(allocator, "{s}.tin.bak", .{self.target});
    std.fs.renameAbsolute(backup_path, self.target) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
}

test "status returns missing for nonexistent path" {
    const s = Symlink{
        .source = "/nonexistent/source",
        .target = "/nonexistent/target",
        .name = "test",
    };
    try std.testing.expectEqual(Status.missing, s.status());
}

test "link creates symlink and status is linked" {
    const source = "/tmp/tin_test_symlink_source";
    const target = "/tmp/tin_test_symlink_target";
    std.fs.deleteFileAbsolute(target) catch {};
    std.fs.deleteFileAbsolute(source) catch {};
    const f = try std.fs.createFileAbsolute(source, .{});
    f.close();
    const s = Symlink{ .source = source, .target = target, .name = "test" };
    try s.link();
    try std.testing.expectEqual(Status.linked, s.status());
    try s.unlink();
    try std.testing.expectEqual(Status.missing, s.status());
    std.fs.deleteFileAbsolute(source) catch {};
}

test "status returns wrong_target for mismatched symlink" {
    const target = "/tmp/tin_test_wrong_target";
    std.fs.deleteFileAbsolute(target) catch {};
    std.fs.symLinkAbsolute("/some/other/path", target, .{}) catch return;
    const s = Symlink{ .source = "/expected/path", .target = target, .name = "test" };
    try std.testing.expectEqual(Status.wrong_target, s.status());
    std.fs.deleteFileAbsolute(target) catch {};
}

test "backup and restore round-trips" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const target = "/tmp/tin_test_backup_target";
    std.fs.deleteFileAbsolute(target) catch {};
    std.fs.deleteFileAbsolute("/tmp/tin_test_backup_target.tin.bak") catch {};
    const f = try std.fs.createFileAbsolute(target, .{});
    f.close();
    const s = Symlink{ .source = "/x", .target = target, .name = "test" };
    try s.backup(arena.allocator());
    try std.testing.expect(!fs.pathExists(target));
    try std.testing.expect(fs.pathExists("/tmp/tin_test_backup_target.tin.bak"));
    try s.restore(arena.allocator());
    try std.testing.expect(fs.pathExists(target));
    std.fs.deleteFileAbsolute(target) catch {};
}

test "unlink tolerates missing target" {
    const s = Symlink{ .source = "/x", .target = "/tmp/tin_test_unlink_missing", .name = "test" };
    try s.unlink();
}

test "status returns not_a_symlink for regular file" {
    const target = "/tmp/tin_test_not_symlink";
    std.fs.deleteFileAbsolute(target) catch {};
    const f = try std.fs.createFileAbsolute(target, .{});
    f.close();
    const s = Symlink{ .source = "/x", .target = target, .name = "test" };
    try std.testing.expectEqual(Status.not_a_symlink, s.status());
    std.fs.deleteFileAbsolute(target) catch {};
}
