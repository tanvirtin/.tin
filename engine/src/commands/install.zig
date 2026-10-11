const std = @import("std");
const output = @import("../lib/output.zig");
const link = @import("../commands/link.zig");
const fonts = @import("../commands/fonts.zig");
const recipe = @import("../commands/recipe.zig");
const Environment = @import("../core/environment.zig");

pub const meta = .{
    .name = "install",
    .description = "Full environment bootstrap from tinrc.yml",
};

pub fn execute(allocator: std.mem.Allocator, _: []const []const u8) u8 {
    const paths = Environment.Paths.init(allocator) catch {
        output.err("could not resolve environment paths", .{});
        return 1;
    };

    const config = Environment.Config.loadOrEmpty(allocator, paths);

    const steps = Environment.RecipeManager.getInstallSteps(allocator, config) catch {
        output.err("could not read install steps from tinrc.yml", .{});
        return 1;
    };

    if (steps.len == 0) {
        output.warn("no install steps defined in tinrc.yml", .{});
        return 0;
    }

    output.info("installing .tin environment...\n", .{});

    var failures: usize = 0;
    for (steps) |step| {
        switch (step) {
            .link => {
                if (link.execute(allocator, &.{}) != 0) failures += 1;
            },
            .fonts => {
                if (fonts.execute(allocator, &.{}) != 0) failures += 1;
            },
            .recipes => |names| {
                for (names) |name| {
                    if (recipe.execute(allocator, &.{name}) != 0) failures += 1;
                }
            },
        }
        output.plain("", .{});
    }

    if (failures > 0) {
        output.err("install finished with {d} failure{s}", .{ failures, if (failures == 1) "" else "s" });
        return 1;
    }

    output.success("install complete", .{});
    return 0;
}
