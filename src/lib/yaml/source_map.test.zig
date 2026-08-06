const std = @import("std");
const yaml = @import("../yaml.zig");

test "source map: basic plain" {
    const allocator = std.testing.allocator;
    const source = "run: echo hello";
    var doc = try yaml.parse(allocator, source);
    defer doc.deinit();

    const run = doc.value.get("run").?;
    const parsed = run.getString().?;
    const map = run.getSourceMap().?;

    try std.testing.expectEqualStrings("echo hello", parsed);
    // 'e' in "echo hello" should be at source index 5
    try std.testing.expectEqual(@as(u32, 5), map.map(0));
    // 'o' in "hello" should be at source index 14
    try std.testing.expectEqual(@as(u32, 14), map.map(9));
}

test "source map: single quoted with escape" {
    const allocator = std.testing.allocator;
    const source = "run: 'can''t stop'";
    var doc = try yaml.parse(allocator, source);
    defer doc.deinit();

    const run = doc.value.get("run").?;
    const parsed = run.getString().?;
    const map = run.getSourceMap().?;

    try std.testing.expectEqualStrings("can't stop", parsed);
    // 'c' at index 5
    try std.testing.expectEqual(@as(u32, 6), map.map(0));
    // 't' after '' at parsed index 4 should be source index 11
    try std.testing.expectEqual(@as(u32, 11), map.map(4));
}

test "source map: double quoted with escapes" {
    const allocator = std.testing.allocator;
    const source = "run: \"line\\nnext\"";
    var doc = try yaml.parse(allocator, source);
    defer doc.deinit();

    const run = doc.value.get("run").?;
    const parsed = run.getString().?;
    const map = run.getSourceMap().?;

    try std.testing.expectEqualStrings("line\nnext", parsed);
    // 'l' at index 6
    try std.testing.expectEqual(@as(u32, 6), map.map(0));
    // '\n' at parsed index 4 is source index 10 (the '\' in \n)
    try std.testing.expectEqual(@as(u32, 10), map.map(4));
    // 'n' in "next" at parsed index 5 is source index 12
    try std.testing.expectEqual(@as(u32, 12), map.map(5));
}

test "source map: literal block" {
    const allocator = std.testing.allocator;
    const source = 
        \\run: |
        \\  first
        \\  second
    ;
    var doc = try yaml.parse(allocator, source);
    defer doc.deinit();

    const run = doc.value.get("run").?;
    const parsed = run.getString().?;
    const map = run.getSourceMap().?;

    try std.testing.expectEqualStrings("first\nsecond\n", parsed);
    // 'f' at index 9
    try std.testing.expectEqual(@as(u32, 9), map.map(0));
    // '\n' at parsed index 5
    try std.testing.expectEqual(@as(u32, 14), map.map(5));
    // 's' at parsed index 6 is source index 17
    try std.testing.expectEqual(@as(u32, 17), map.map(6));
}

test "source map: folded block" {
    const allocator = std.testing.allocator;
    const source = 
        \\run: >
        \\  line1
        \\
        \\  line2
    ;
    var doc = try yaml.parse(allocator, source);
    defer doc.deinit();

    const run = doc.value.get("run").?;
    const parsed = run.getString().?;
    const map = run.getSourceMap().?;

    // Folded block: single newline -> space, double newline -> newline
    try std.testing.expectEqualStrings("line1\n\nline2\n", parsed);
    // 'l' in line1
    try std.testing.expectEqual(@as(u32, 9), map.map(0));
    // '\n' (first newline) at parsed index 5
    try std.testing.expectEqual(@as(u32, 14), map.map(5));
    // '\n' (second newline) at parsed index 6
    try std.testing.expectEqual(@as(u32, 15), map.map(6));
    // 'l' in line2 at parsed index 7
    try std.testing.expectEqual(@as(u32, 18), map.map(7));
}
