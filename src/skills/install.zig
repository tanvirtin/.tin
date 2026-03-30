const std = @import("std");
const output = @import("../lib/output.zig");
const Environment = @import("../core/environment.zig");
const link = @import("../commands/link.zig");
const fonts = @import("../commands/fonts.zig");
const recipe = @import("../commands/recipe.zig");

pub const meta = .{
    .name = "install",
    .description = "Full environment bootstrap from tinrc.yml",
};

pub fn execute(allocator: std.mem.Allocator, _: []const []const u8) void {
    const env = Environment.init(allocator) catch {
        output.err("could not resolve environment", .{});
        return;
    };

    const steps = env.installSteps(allocator) catch {
        output.err("could not read install steps from tinrc.yml", .{});
        return;
    };

    if (steps.len == 0) {
        output.warn("no install steps defined in tinrc.yml", .{});
        return;
    }

    output.info("installing .tin environment...\n", .{});

    for (steps) |step| {
        switch (step) {
            .link => link.execute(allocator, &.{}),
            .fonts => fonts.execute(allocator, &.{}),
            .recipes => |names| {
                for (names) |name| {
                    recipe.execute(allocator, &.{name});
                }
            },
        }
        output.plain("", .{});
    }

    output.success("install complete", .{});
}
