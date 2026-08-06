const std = @import("std");
const process = @import("../lib/process.zig");

pub fn getFontDir(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ home, ".local", "share", "fonts" });
}

pub fn postFontInstall(allocator: std.mem.Allocator) !void {
    try process.run(allocator, &.{ "fc-cache", "-f" });
}

pub fn getOsName() []const u8 {
    return "linux";
}

pub fn installPackage(allocator: std.mem.Allocator, name: []const u8) !void {
    try process.run(allocator, &.{ "apt-get", "-y", "install", name });
}
