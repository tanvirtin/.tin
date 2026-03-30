const std = @import("std");

pub const ParseError = error{
    InvalidYaml,
    OutOfMemory,
};

pub const Entry = struct {
    key: []const u8,
    value: Value,
};

pub const Value = union(enum) {
    scalar: []const u8,
    sequence: []const Value,
    mapping: []const Entry,

    pub fn getMapping(self: Value, key: []const u8) ?Value {
        switch (self) {
            .mapping => |entries| {
                for (entries) |entry| {
                    if (std.mem.eql(u8, entry.key, key)) return entry.value;
                }
                return null;
            },
            else => return null,
        }
    }

    pub fn getString(self: Value) ?[]const u8 {
        return switch (self) {
            .scalar => |s| s,
            else => null,
        };
    }

    pub fn getSequence(self: Value) ?[]const Value {
        return switch (self) {
            .sequence => |s| s,
            else => null,
        };
    }
};

test "getString returns scalar value" {
    const v = Value{ .scalar = "hello" };
    try std.testing.expectEqualStrings("hello", v.getString().?);
}

test "getString returns null for non-scalar" {
    const v = Value{ .sequence = &.{} };
    try std.testing.expect(v.getString() == null);
}

test "getSequence returns sequence items" {
    const items = [_]Value{ .{ .scalar = "a" }, .{ .scalar = "b" } };
    const v = Value{ .sequence = &items };
    const seq = v.getSequence().?;
    try std.testing.expectEqual(@as(usize, 2), seq.len);
    try std.testing.expectEqualStrings("a", seq[0].getString().?);
}

test "getSequence returns null for non-sequence" {
    const v = Value{ .scalar = "x" };
    try std.testing.expect(v.getSequence() == null);
}

test "getMapping finds key in entries" {
    const entries = [_]Entry{
        .{ .key = "name", .value = .{ .scalar = "tin" } },
        .{ .key = "version", .value = .{ .scalar = "1" } },
    };
    const v = Value{ .mapping = &entries };
    try std.testing.expectEqualStrings("tin", v.getMapping("name").?.getString().?);
    try std.testing.expectEqualStrings("1", v.getMapping("version").?.getString().?);
}

test "getMapping returns null for missing key" {
    const entries = [_]Entry{
        .{ .key = "name", .value = .{ .scalar = "tin" } },
    };
    const v = Value{ .mapping = &entries };
    try std.testing.expect(v.getMapping("missing") == null);
}

test "getMapping returns null for non-mapping" {
    const v = Value{ .scalar = "x" };
    try std.testing.expect(v.getMapping("anything") == null);
}

test "getString returns empty string for empty scalar" {
    const v = Value{ .scalar = "" };
    try std.testing.expectEqualStrings("", v.getString().?);
}

test "getSequence returns empty slice for empty sequence" {
    const v = Value{ .sequence = &.{} };
    try std.testing.expectEqual(@as(usize, 0), v.getSequence().?.len);
}

test "getMapping returns null for empty mapping" {
    const v = Value{ .mapping = &.{} };
    try std.testing.expect(v.getMapping("any") == null);
}
