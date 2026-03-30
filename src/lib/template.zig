const std = @import("std");

/// Expand `{{ key.path }}` placeholders in a string using a flat key-value map.
///
/// Example:
///   const vars = &.{ .{ "identity.name", "Tanvir" }, .{ "identity.email", "t@t.com" } };
///   const result = try render(allocator, "hello {{ identity.name }}", vars);
///   // result = "hello Tanvir"
pub fn render(
    allocator: std.mem.Allocator,
    template: []const u8,
    vars: []const struct { []const u8, []const u8 },
) ![]const u8 {
    var result: std.ArrayList(u8) = .{};
    var pos: usize = 0;

    while (pos < template.len) {
        if (pos + 1 < template.len and template[pos] == '{' and template[pos + 1] == '{') {
            // Find closing }}
            const start = pos + 2;
            if (std.mem.indexOfPos(u8, template, start, "}}")) |end| {
                const key = std.mem.trim(u8, template[start..end], " ");
                const value = lookup(vars, key) orelse "";
                try result.appendSlice(allocator, value);
                pos = end + 2;
            } else {
                // No closing }} — emit literal
                try result.append(allocator, template[pos]);
                pos += 1;
            }
        } else {
            try result.append(allocator, template[pos]);
            pos += 1;
        }
    }

    return result.items;
}

fn lookup(
    vars: []const struct { []const u8, []const u8 },
    key: []const u8,
) ?[]const u8 {
    for (vars) |entry| {
        if (std.mem.eql(u8, entry[0], key)) return entry[1];
    }
    return null;
}

// ── Tests ──

test "simple substitution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try render(arena.allocator(), "hello {{ name }}", &.{.{ "name", "world" }});
    try std.testing.expectEqualStrings("hello world", result);
}

test "multiple substitutions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try render(arena.allocator(), "{{ a }} and {{ b }}", &.{ .{ "a", "x" }, .{ "b", "y" } });
    try std.testing.expectEqualStrings("x and y", result);
}

test "dotted key path" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try render(arena.allocator(), "git config --global user.name \"{{ identity.name }}\"", &.{.{ "identity.name", "Tanvir Islam" }});
    try std.testing.expectEqualStrings("git config --global user.name \"Tanvir Islam\"", result);
}

test "missing var produces empty string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try render(arena.allocator(), "hello {{ missing }}", &.{});
    try std.testing.expectEqualStrings("hello ", result);
}

test "no placeholders returns original" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try render(arena.allocator(), "no templates here", &.{});
    try std.testing.expectEqualStrings("no templates here", result);
}

test "unclosed braces treated as literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try render(arena.allocator(), "hello {{ name", &.{.{ "name", "world" }});
    try std.testing.expectEqualStrings("hello {{ name", result);
}
