const std = @import("std");
const yaml = @import("yaml");
const Paths = @import("paths.zig");
const output = @import("../../lib/output.zig");

pub const Config = @This();

doc: ?yaml.DocNode,

const max_config_bytes = 256 * 1024;

pub fn load(allocator: std.mem.Allocator, paths: Paths) ?Config {
    const config_path = std.fs.path.join(allocator, &.{ paths.tin_dir, "tinrc.yml" }) catch return null;
    defer allocator.free(config_path);

    const file = std.fs.openFileAbsolute(config_path, .{}) catch return null;
    defer file.close();

    const size = file.getEndPos() catch 0;
    if (size > max_config_bytes) {
        output.err("tinrc.yml exceeds the {d}KB limit ({d} bytes) — refusing to load a truncated config", .{ max_config_bytes / 1024, size });
        return null;
    }

    const content = file.readToEndAlloc(allocator, max_config_bytes) catch return null;
    defer allocator.free(content);
    const doc = yaml.parse(allocator, content) catch null;

    return .{ .doc = doc };
}

pub fn getMapping(self: *const Config, key: []const u8) ?yaml.Value {
    const doc = self.doc orelse return null;
    return doc.getMapping(key);
}

test "getMapping returns value for present key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try yaml.parse(arena.allocator(), "a: 1\nb: hello");
    const config = Config{ .doc = doc };
    try std.testing.expect(config.getMapping("a") != null);
    try std.testing.expect(config.getMapping("b") != null);
}

test "getMapping returns null for missing key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const doc = try yaml.parse(arena.allocator(), "a: 1");
    const config = Config{ .doc = doc };
    try std.testing.expect(config.getMapping("missing") == null);
}

test "getMapping returns null when doc is absent" {
    const config = Config{ .doc = null };
    try std.testing.expect(config.getMapping("anything") == null);
}
