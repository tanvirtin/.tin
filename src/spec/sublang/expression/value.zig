const std = @import("std");

pub const Value = union(enum) {
    string: []const u8,
    number: f64,
    boolean: bool,
    null_t,
    array: []const Value,
    object: std.StringHashMap(Value),

    pub fn truthy(self: Value) bool {
        return switch (self) {
            .null_t => false,
            .boolean => |b| b,
            .number => |n| n != 0 and !std.math.isNan(n),
            .string => |s| s.len != 0,
            else => true,
        };
    }

    pub fn equal(a: Value, b: Value) bool {
        if (a.category() != b.category()) {
            const an = a.toNumber();
            const bn = b.toNumber();
            if (std.math.isNan(an) or std.math.isNan(bn)) return false;
            return an == bn;
        }
        return switch (a) {
            .string => |s| std.ascii.eqlIgnoreCase(s, b.string),
            .number => |n| n == b.number,
            .boolean => |x| x == b.boolean,
            .null_t => true,
            .array => arraysEqual(a.array, b.array),
            .object => objectsEqual(a.object, b.object),
        };
    }

    pub fn toNumber(self: Value) f64 {
        return switch (self) {
            .null_t => 0,
            .boolean => |b| if (b) 1 else 0,
            .number => |n| n,
            .array, .object => std.math.nan(f64),
            .string => |s| stringToNumber(s),
        };
    }

    const Category = enum { string, number, boolean, null_t, composite };

    fn category(self: Value) Category {
        return switch (self) {
            .string => .string,
            .number => .number,
            .boolean => .boolean,
            .null_t => .null_t,
            else => .composite,
        };
    }

    pub fn toString(self: Value, allocator: std.mem.Allocator) ![]const u8 {
        return switch (self) {
            .string => |s| s,
            .number => |n| try std.fmt.allocPrint(allocator, "{}", .{n}),
            .boolean => |b| if (b) "true" else "false",
            .null_t, .array, .object => "",
        };
    }

    fn arraysEqual(a: []const Value, b: []const Value) bool {
        if (a.len != b.len) return false;
        for (a, b) |x, y| {
            if (!equal(x, y)) return false;
        }
        return true;
    }

    fn objectsEqual(a: std.StringHashMap(Value), b: std.StringHashMap(Value)) bool {
        if (a.count() != b.count()) return false;
        var it = a.iterator();
        while (it.next()) |entry| {
            const other = b.get(entry.key_ptr.*) orelse return false;
            if (!equal(entry.value_ptr.*, other)) return false;
        }
        return true;
    }

    fn stringToNumber(s: []const u8) f64 {
        if (s.len == 0) return 0;
        return std.fmt.parseFloat(f64, s) catch std.math.nan(f64);
    }
};