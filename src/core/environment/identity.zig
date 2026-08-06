const std = @import("std");
const yaml = @import("yaml");
const Config = @import("config.zig");

pub const Identity = struct {
    name: []const u8,
    email: []const u8,
};

pub const TemplateVar = struct { []const u8, []const u8 };

pub fn getIdentity(allocator: std.mem.Allocator, config: Config) ?Identity {
    const id_val = config.getMapping("identity") orelse return null;
    return yaml.decodeValue(Identity, allocator, id_val) catch return null;
}

pub fn getTemplateVars(allocator: std.mem.Allocator, config: Config) ![]const TemplateVar {
    var vars: std.ArrayListUnmanaged(TemplateVar) = .{};
    if (getIdentity(allocator, config)) |id| {
        try vars.append(allocator, .{ try allocator.dupe(u8, "identity.name"), try allocator.dupe(u8, id.name) });
        try vars.append(allocator, .{ try allocator.dupe(u8, "identity.email"), try allocator.dupe(u8, id.email) });
    }
    return try vars.toOwnedSlice(allocator);
}
