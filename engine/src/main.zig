const std = @import("std");
const router = @import("router.zig");
const output = @import("lib/output.zig");

pub fn main() void {
    const gpa = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = std.process.args();
    _ = args.next();

    var arg_list = std.ArrayListUnmanaged([]const u8){};
    while (args.next()) |arg| {
        arg_list.append(allocator, arg) catch {
            output.err("out of memory while reading arguments", .{});
            std.process.exit(output.ExitCode.failure);
        };
    }

    const code = router.dispatch(allocator, arg_list.items);
    if (code != 0) std.process.exit(code);
}

test {
    _ = @import("router.zig");
    _ = @import("lib/output.zig");
    _ = @import("lib/fs.zig");
    _ = @import("lib/process.zig");
    _ = @import("lib/template.zig");
    _ = @import("lib/utils.zig");
    _ = @import("yaml");
    _ = @import("commands/help.zig");
    _ = @import("commands/link.zig");
    _ = @import("commands/unlink.zig");
    _ = @import("commands/heal.zig");
    _ = @import("commands/fonts.zig");
    _ = @import("commands/recipe.zig");
    _ = @import("commands/artifact.zig");
    _ = @import("commands/config.zig");
    _ = @import("commands/status.zig");
    _ = @import("commands/init.zig");
    _ = @import("commands/mcp.zig");
    _ = @import("commands/validate.zig");
    _ = @import("commands/schema.zig");
    _ = @import("commands/install.zig");
    _ = @import("commands/upgrade.zig");
    _ = @import("core/symlink.zig");
    _ = @import("core/environment.zig");
    _ = @import("core/environment/paths.zig");
    _ = @import("core/environment/config.zig");
    _ = @import("core/environment/recipe_manager.zig");
    _ = @import("core/recipe.zig");
    _ = @import("core/artifact.zig");
    _ = @import("core/inspection.zig");
    _ = @import("core/upgrade.zig");
    _ = @import("core/mcp.zig");
    _ = @import("platform/platform.zig");
    _ = @import("schemalang/ir.zig");
    _ = @import("schemalang/diagnostic.zig");
    _ = @import("schemalang/bootstrap.zig");
    _ = @import("schemalang/compile_core.zig");
    _ = @import("schemalang/core.zig");
    _ = @import("schemalang/engine.zig");
    _ = @import("schemalang/dogfood_test.zig");
}
