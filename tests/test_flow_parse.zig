const std = @import("std");
const yaml = @import("yaml");

test "flow with braces in quoted value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try yaml.parse(arena.allocator(), "{\"a\":\"b{c}\"}");
    const v = r.getMapping("a").?;
    try std.testing.expectEqualStrings("b{c}", v.getString().?);
}

test "flow with multiple braces" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const r = try yaml.parse(arena.allocator(), "{\"pattern\":\"^\\\\$\\\\{\\\\{\"}");
    _ = r;
}
