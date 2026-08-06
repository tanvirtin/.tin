const std = @import("std");
const yaml = @import("yaml");
const Paths = @import("paths.zig");

pub const Config = @This();

doc: ?yaml.DocNode,

pub fn load(allocator: std.mem.Allocator, paths: Paths) ?Config {
    const config_path = std.fs.path.join(allocator, &.{ paths.tin_dir, "tinrc.yml" }) catch return null;
    defer allocator.free(config_path);

    const file = std.fs.openFileAbsolute(config_path, .{}) catch return null;
    defer file.close();
    
    const content = file.readToEndAlloc(allocator, 256 * 1024) catch return null;
    const doc = yaml.parse(allocator, content) catch null;

    return .{ .doc = doc };
}

pub fn getMapping(self: *const Config, key: []const u8) ?yaml.Value {
    const doc = self.doc orelse return null;
    return doc.getMapping(key);
}
