const std = @import("std");
const output = @import("lib/output.zig");

const help = @import("commands/help.zig");
const link = @import("commands/link.zig");
const heal = @import("commands/heal.zig");
const fonts = @import("commands/fonts.zig");
const unlink = @import("commands/unlink.zig");
const recipe = @import("commands/recipe.zig");
const schema = @import("commands/schema.zig");
const artifact = @import("commands/artifact.zig");
const config = @import("commands/config.zig");
const status = @import("commands/status.zig");
const init = @import("commands/init.zig");
const mcp = @import("commands/mcp.zig");
const validate = @import("commands/validate.zig");
const upgrade = @import("commands/upgrade.zig");

const install = @import("commands/install.zig");

const Entry = struct {
    name: []const u8,
    description: []const u8,
    execute: *const fn (std.mem.Allocator, []const []const u8) u8,
};

fn entry(comptime module: type) Entry {
    return .{
        .name = module.meta.name,
        .description = module.meta.description,
        .execute = module.execute,
    };
}

pub const command_entries = [_]Entry{
    entry(artifact),
    entry(config),
    entry(status),
    entry(init),
    entry(mcp),
    entry(help),
    entry(link),
    entry(heal),
    entry(fonts),
    entry(unlink),
    entry(recipe),
    entry(validate),
    entry(schema),
    entry(upgrade),
    entry(install),
};

pub fn dispatch(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    var json = false;
    var filtered: std.ArrayListUnmanaged([]const u8) = .{};
    defer filtered.deinit(allocator);
    for (args) |arg| {
        if (std.mem.eql(u8, arg, "--json")) {
            json = true;
        } else {
            filtered.append(allocator, arg) catch {
                output.err("out of memory while parsing arguments", .{});
                return output.ExitCode.failure;
            };
        }
    }

    const mode: output.Mode = if (json) .json else .text;
    const rest = filtered.items;

    if (rest.len == 0) {
        output.configure(mode, "help");
        return help.execute(allocator, rest);
    }

    const command = rest[0];
    if (std.mem.eql(u8, command, "--help") or std.mem.eql(u8, command, "-h")) {
        output.configure(mode, "help");
        return help.execute(allocator, &.{});
    }
    const command_args = rest[1..];
    output.configure(mode, command);

    inline for (command_entries) |e| {
        if (std.mem.eql(u8, command, e.name)) {
            return e.execute(allocator, command_args);
        }
    }

    output.err("unknown command: {s}", .{command});
    output.plain("Run 'tin help' for usage.", .{});
    return output.ExitCode.usage;
}
