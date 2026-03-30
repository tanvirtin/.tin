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
