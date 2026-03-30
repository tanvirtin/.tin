const std = @import("std");
const output = @import("lib/output.zig");

const sn = @import("commands/sn.zig");
const help = @import("commands/help.zig");
const link = @import("commands/link.zig");
const fonts = @import("commands/fonts.zig");
const status = @import("commands/status.zig");
const unlink = @import("commands/unlink.zig");
const recipe = @import("commands/recipe.zig");

const install = @import("skills/install.zig");

const Entry = struct {
    name: []const u8,
    description: []const u8,
    execute: *const fn (std.mem.Allocator, []const []const u8) void,
};

fn entry(comptime module: type) Entry {
    return .{
        .name = module.meta.name,
        .description = module.meta.description,
        .execute = module.execute,
    };
}

pub const command_entries = [_]Entry{
    entry(sn),
    entry(help),
    entry(link),
    entry(fonts),
    entry(status),
    entry(unlink),
    entry(recipe),
};

pub const skill_entries = [_]Entry{
    entry(install),
};

pub fn dispatch(allocator: std.mem.Allocator, args: []const []const u8) void {
    if (args.len == 0) {
        help.execute(allocator, args);
        return;
    }

    const command = args[0];
    const command_args = args[1..];

    const all_entries = command_entries ++ skill_entries;
    inline for (all_entries) |e| {
        if (std.mem.eql(u8, command, e.name)) {
            e.execute(allocator, command_args);
            return;
        }
    }

    output.err("unknown command: {s}", .{command});
    output.plain("Run 'tin help' for usage.", .{});
}
