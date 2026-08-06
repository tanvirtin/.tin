const std = @import("std");
const router = @import("../router.zig");
const output = @import("../lib/output.zig");

pub const meta = .{
    .name = "help",
    .description = "Show usage information",
};

pub fn execute(_: std.mem.Allocator, _: []const []const u8) void {
    output.plain("tin — developer environment manager\n", .{});
    output.plain("Usage: tin <command> [args...]\n", .{});

    output.plain("Commands:", .{});
    inline for (router.command_entries) |entry| {
        output.plain("  {s:<14} {s}", .{ entry.name, entry.description });
    }

    output.plain("\nSkills:", .{});
    inline for (router.skill_entries) |entry| {
        output.plain("  {s:<14} {s}", .{ entry.name, entry.description });
    }

    output.plain("", .{});
}
