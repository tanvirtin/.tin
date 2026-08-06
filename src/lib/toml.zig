const std = @import("std");

/// Minimal TOML subset parser for reading `mise.toml` files.
/// Supports: section headers `[tools]`, `[tasks.build]`, key = value pairs,
/// string / number / boolean values, arrays of strings, comments, blank lines.
/// Enough for `[tools]`, `[env]`, `[tasks.*]`. Not a full TOML implementation.
pub const Value = union(enum) {
    string: []const u8,
    array: []const []const u8,
};

pub const Entry = struct {
    key: []const u8,
    value: Value,
};

pub const Section = struct {
    name: []const u8,
    entries: []const Entry,
};

pub const Toml = struct {
    sections: []Section,

    pub fn find(self: *const Toml, section: []const u8) ?Section {
        for (self.sections) |sec| {
            if (std.mem.eql(u8, sec.name, section)) return sec;
        }
        return null;
    }
};

pub fn parse(allocator: std.mem.Allocator, input: []const u8) !Toml {
    var sections = std.ArrayListUnmanaged(Section){};
    var current_name: ?[]const u8 = null;
    var current_entries = std.ArrayListUnmanaged(Entry){};

    var lines = std.mem.splitScalar(u8, input, '\n');
    while (lines.next()) |raw| {
        const line = stripComment(stripLine(raw));

        if (line.len == 0) continue;

        if (line[0] == '[') {
            try flush(allocator, &sections, current_name, &current_entries);
            current_name = try parseSectionName(allocator, line);
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const value_str = std.mem.trim(u8, line[eq + 1 ..], " \t");

        const value = try parseValue(allocator, value_str);
        try current_entries.append(allocator, .{ .key = try allocator.dupe(u8, key), .value = value });
    }
    try flush(allocator, &sections, current_name, &current_entries);

    return .{ .sections = try sections.toOwnedSlice(allocator) };
}

fn stripLine(s: []const u8) []const u8 {
    return std.mem.trim(u8, s, " \t\r");
}

fn stripComment(s: []const u8) []const u8 {
    const idx = std.mem.indexOfScalar(u8, s, '#') orelse return s;
    return s[0..idx];
}

fn parseSectionName(allocator: std.mem.Allocator, line: []const u8) ![]const u8 {
    const close = std.mem.indexOfScalar(u8, line, ']') orelse return error.InvalidSection;
    const name = std.mem.trim(u8, line[1..close], " \t");
    return allocator.dupe(u8, name);
}

fn parseValue(allocator: std.mem.Allocator, s: []const u8) !Value {
    if (s.len >= 2 and s[0] == '[' and s[s.len - 1] == ']') {
        var items = std.ArrayListUnmanaged([]const u8){};
        var rest = std.mem.trim(u8, s[1 .. s.len - 1], " \t");
        while (rest.len > 0) {
            if (rest[0] == '"' or rest[0] == '\'') {
                const quote = rest[0];
                const end = std.mem.indexOfScalarPos(u8, rest, 1, quote) orelse break;
                const item = rest[1..end];
                try items.append(allocator, try allocator.dupe(u8, item));
                rest = std.mem.trim(u8, rest[end + 1 ..], " \t,");
            } else {
                const comma = std.mem.indexOfScalar(u8, rest, ',') orelse {
                    try items.append(allocator, try allocator.dupe(u8, std.mem.trim(u8, rest, " \t")));
                    break;
                };
                try items.append(allocator, try allocator.dupe(u8, std.mem.trim(u8, rest[0..comma], " \t")));
                rest = std.mem.trim(u8, rest[comma + 1 ..], " \t");
            }
        }
        return .{ .array = try items.toOwnedSlice(allocator) };
    }

    if (s.len >= 2 and (s[0] == '"' or s[0] == '\'') and s[s.len - 1] == s[0]) {
        return .{ .string = try allocator.dupe(u8, s[1 .. s.len - 1]) };
    }

    return .{ .string = try allocator.dupe(u8, s) };
}

fn flush(
    allocator: std.mem.Allocator,
    sections: *std.ArrayListUnmanaged(Section),
    name: ?[]const u8,
    entries: *std.ArrayListUnmanaged(Entry),
) !void {
    if (name) |n| {
        try sections.append(allocator, .{
            .name = n,
            .entries = try entries.toOwnedSlice(allocator),
        });
    }
}

const Sample =
    \\[tools]
    \\node = "22"
    \\python = "3.12"
    \\# a comment
    \\
    \\[env]
    \\NODE_ENV = "development"
    \\
    \\[tasks.dev]
    \\run = "npm run dev"
    \\depends = ["build"]
    \\
    \\[tasks.lint]
    \\run = "cargo clippy"
;

test "parse sections and string values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const toml = try parse(a, Sample);
    const tools = toml.find("tools").?;
    try std.testing.expectEqualStrings("node", tools.entries[0].key);
    try std.testing.expectEqualStrings("22", tools.entries[0].value.string);
}

test "parse task sections" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const toml = try parse(a, Sample);
    const tasks = toml.find("tasks.dev").?;
    try std.testing.expectEqualStrings("npm run dev", tasks.entries[0].value.string);
    try std.testing.expectEqualStrings("build", tasks.entries[1].value.array[0]);
}

test "parse empty input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const toml = try parse(a, "");
    try std.testing.expectEqual(@as(usize, 0), toml.sections.len);
}

test "parse inline table ignored safely" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const toml = try parse(a, "[tools]\nnode = { version = \"22\" }\n");
    // Inline tables fall back to string form; not parsed structurally but no crash.
    try std.testing.expectEqual(@as(usize, 1), toml.sections.len);
}
