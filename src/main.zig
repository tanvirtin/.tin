const std = @import("std");
const router = @import("router.zig");

pub fn main() void {
    const gpa = std.heap.page_allocator;
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    const allocator = arena.allocator();

    var args = std.process.args();
    _ = args.next();

    var arg_list: [64][]const u8 = undefined;
    var count: usize = 0;

    while (args.next()) |arg| {
        if (count >= arg_list.len) break;
        arg_list[count] = arg;
        count += 1;
    }

    router.dispatch(allocator, arg_list[0..count]);
}

test {
    _ = @import("router.zig");
    _ = @import("lib/output.zig");
    _ = @import("lib/fs.zig");
    _ = @import("lib/process.zig");
    _ = @import("lib/template.zig");
    _ = @import("lib/yaml.zig");
    _ = @import("lib/yaml/value.zig");
    _ = @import("lib/yaml/decode.zig");
    _ = @import("commands/status.zig");
    _ = @import("commands/help.zig");
    _ = @import("commands/link.zig");
    _ = @import("commands/unlink.zig");
    _ = @import("commands/fonts.zig");
    _ = @import("commands/recipe.zig");
    _ = @import("commands/sn.zig");
    _ = @import("skills/install.zig");
    _ = @import("core/symlink.zig");
    _ = @import("core/environment.zig");
    _ = @import("core/recipe.zig");
    _ = @import("core/sn.zig");
    _ = @import("platform/platform.zig");
}
