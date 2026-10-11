const std = @import("std");
const output = @import("../lib/output.zig");
const Environment = @import("../core/environment.zig");
const apply = @import("../core/apply.zig");

pub const meta = .{
    .name = "link",
    .description = "Create config symlinks for all managed files",
};

pub fn execute(allocator: std.mem.Allocator, _: []const []const u8) u8 {
    const paths = Environment.Paths.init(allocator) catch {
        output.err("could not resolve environment paths", .{});
        return 1;
    };

    const loaded_config = Environment.Config.load(allocator, paths) catch {
        output.err("link aborted: configuration could not be loaded", .{});
        return 1;
    };
    const config = loaded_config orelse {
        output.warn("no tinrc.yml found — nothing to link", .{});
        return 0;
    };

    return apply.linkManaged(allocator, paths, config);
}
