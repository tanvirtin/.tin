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
        return output.ExitCode.failure;
    };

    const loaded_config = Environment.Config.load(allocator, paths) catch {
        output.err("install aborted: configuration could not be loaded", .{});
        return output.ExitCode.failure;
    };
    const config = loaded_config orelse {
        output.warn("no tinrc.yml found — nothing to install", .{});
        return output.ExitCode.success;
    };

    const steps = Environment.RecipeManager.getInstallSteps(allocator, config) catch {
        output.err("could not read install steps from tinrc.yml", .{});
        return output.ExitCode.failure;
    };

    if (steps.len == 0) {
        output.warn("no install steps defined in tinrc.yml", .{});
        return output.ExitCode.success;
    }

    output.info("installing .tin environment...\n", .{});

    var hard_failures: usize = 0;
    var partial_failures: usize = 0;
    for (steps) |step| {
        switch (step) {
            .link => accountStep(link.execute(allocator, &.{}), &hard_failures, &partial_failures),
            .fonts => accountStep(fonts.execute(allocator, &.{}), &hard_failures, &partial_failures),
            .recipes => |names| {
                for (names) |name| {
                    accountStep(recipe.execute(allocator, &.{name}), &hard_failures, &partial_failures);
                }
            },
        }
        output.plain("", .{});
    }

    if (hard_failures > 0) {
        output.err("install finished with {d} failure{s}", .{ hard_failures, if (hard_failures == 1) "" else "s" });
        return output.ExitCode.failure;
    }
    if (partial_failures > 0) {
        output.err("install finished with {d} partial step{s}", .{ partial_failures, if (partial_failures == 1) "" else "s" });
        return output.ExitCode.partial;
    }

    output.success("install complete", .{});
    return output.ExitCode.success;
}

fn accountStep(code: u8, hard_failures: *usize, partial_failures: *usize) void {
    if (code == output.ExitCode.failure) hard_failures.* += 1;
    if (code == output.ExitCode.partial) partial_failures.* += 1;
}
