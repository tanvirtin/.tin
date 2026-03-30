const std = @import("std");
const yaml = @import("src/lib/yaml.zig");
pub fn main() !void {
    const alloc = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    var args = std.process.args();
    _ = args.next();
    const path = args.next() orelse return;
    const file = try std.fs.openFileAbsolute(path, .{});
    defer file.close();
    const content = try file.readToEndAlloc(arena.allocator(), 1024 * 1024);
    const result = yaml.parse(arena.allocator(), content);
    if (result) |_| {
        try std.fs.File.stdout().deprecatedWriter().print("OK\n", .{});
    } else |_| {
        try std.fs.File.stdout().deprecatedWriter().print("ERROR\n", .{});
    }
}
