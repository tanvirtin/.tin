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

pub const SymlinkError = error{
    SourceNotFound,
    TargetAlreadyExists,
    BackupFailed,
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
