const std = @import("std");
const value = @import("value.zig");

const Value = value.Value;

pub const Status = struct {
    success: bool = true,
    failure: bool = false,
    always: bool = true,
    cancelled: bool = false,
};

pub const EvalEnv = struct {
    bindings: std.StringHashMap(Value),
    status: ?Status = null,

    pub fn init(allocator: std.mem.Allocator) EvalEnv {
        return .{ .bindings = std.StringHashMap(Value).init(allocator) };
    }

    pub fn set(self: *EvalEnv, name: []const u8, v: Value) !void {
        try self.bindings.put(name, v);
    }

    pub fn get(self: *const EvalEnv, name: []const u8) ?Value {
        return self.bindings.get(name);
    }
};