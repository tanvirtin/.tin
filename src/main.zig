const std = @import("std");
const router = @import("router.zig");

pub fn main() void {
    const gpa = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = std.process.args();
    _ = args.next();

    var arg_list = std.ArrayListUnmanaged([]const u8){};
    while (args.next()) |arg| {
        arg_list.append(allocator, arg) catch break;
    }

    router.dispatch(allocator, arg_list.items);
}

test {
    _ = @import("router.zig");
    _ = @import("lib/output.zig");
    _ = @import("lib/fs.zig");
    _ = @import("lib/process.zig");
    _ = @import("lib/template.zig");
    _ = @import("yaml");
    _ = @import("commands/help.zig");
    _ = @import("commands/link.zig");
    _ = @import("commands/unlink.zig");
    _ = @import("commands/fonts.zig");
    _ = @import("commands/recipe.zig");
    _ = @import("commands/artifact.zig");
    _ = @import("commands/validate.zig");
    _ = @import("commands/schema.zig");
    _ = @import("commands/install.zig");
    _ = @import("core/symlink.zig");
    _ = @import("core/environment.zig");
    _ = @import("core/recipe.zig");
    _ = @import("core/artifact.zig");
    _ = @import("platform/platform.zig");
    _ = @import("spec/ir.zig");
    _ = @import("spec/diagnostic.zig");
    _ = @import("spec/bootstrap.zig");
    _ = @import("spec/compile.zig");
    _ = @import("spec/validate.zig");
    _ = @import("spec/engine.zig");
    _ = @import("spec/dogfood.test.zig");
    _ = @import("lib/envfile.zig");
}
