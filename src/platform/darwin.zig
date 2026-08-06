const std = @import("std");
const process = @import("../lib/process.zig");

pub fn getFontDir(allocator: std.mem.Allocator, home: []const u8) ![]const u8 {
    return std.fs.path.join(allocator, &.{ home, "Library", "Fonts" });
}

pub fn postFontInstall(_: std.mem.Allocator) !void {}

pub fn getOsName() []const u8 {
    return "darwin";
}

pub fn installPackage(allocator: std.mem.Allocator, name: []const u8) !void {
    try process.run(allocator, &.{ "brew", "install", name });
}
