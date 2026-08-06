const std = @import("std");

pub const Entry = struct {
    key: []const u8,
    value: []const u8,
};

pub fn parse(allocator: std.mem.Allocator, content: []const u8) ![]Entry {
    var entries = std.ArrayListUnmanaged(Entry){};
    var lines = std.mem.splitScalar(u8, content, '\n');

    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        if (key.len == 0) continue;

        var value = std.mem.trim(u8, line[eq + 1 ..], " \t");
        if (value.len >= 2 and
            ((value[0] == '"' and value[value.len - 1] == '"') or
                (value[0] == '\'' and value[value.len - 1] == '\'')))
        {
            value = value[1 .. value.len - 1];
        }

        try entries.append(allocator, .{
            .key = try allocator.dupe(u8, key),
            .value = try allocator.dupe(u8, value),
        });
    }

    return entries.toOwnedSlice(allocator);
}

pub fn find(entries: []const Entry, key: []const u8) ?[]const u8 {
    for (entries) |e| {
        if (std.mem.eql(u8, e.key, key)) return e.value;
    }
    return null;
}

test "parses key values and comments" {
    const content =
        \\ANTHROPIC_API_KEY="sk-ant-123"
        \\OPENROUTER_API_KEY=sk-or-456
        \\# comment line
        \\
        \\MISTRAL_API_KEY='mist-789'
        \\EMPTY_KEY=
        \\
    ;
    const entries = try parse(std.testing.allocator, content);

    try std.testing.expectEqual(@as(usize, 4), entries.len);
    try std.testing.expectEqualStrings("sk-ant-123", find(entries, "ANTHROPIC_API_KEY").?);
    try std.testing.expectEqualStrings("sk-or-456", find(entries, "OPENROUTER_API_KEY").?);
    try std.testing.expectEqualStrings("mist-789", find(entries, "MISTRAL_API_KEY").?);
    try std.testing.expectEqualStrings("", find(entries, "EMPTY_KEY").?);

    freeEntries(std.testing.allocator, entries);
}

test "find returns null for missing key" {
    const entries = try parse(std.testing.allocator, "FOO=bar\n");
    try std.testing.expect(find(entries, "NOPE") == null);
    freeEntries(std.testing.allocator, entries);
}

test "tolerates malformed lines" {
    const content = "NOSEPARATOR\n=value\nKEY=value\n";
    const entries = try parse(std.testing.allocator, content);
    try std.testing.expectEqual(@as(usize, 1), entries.len);
    try std.testing.expectEqualStrings("value", entries[0].value);
    freeEntries(std.testing.allocator, entries);
}

fn freeEntries(allocator: std.mem.Allocator, entries: []const Entry) void {
    for (entries) |e| {
        allocator.free(e.key);
        allocator.free(e.value);
    }
    allocator.free(entries);
}
