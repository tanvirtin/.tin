const std = @import("std");
const output = @import("../lib/output.zig");
const Environment = @import("../core/environment.zig");

pub const meta = .{
    .name = "unlink",
    .description = "Remove symlinks and restore backups",
};

pub fn execute(allocator: std.mem.Allocator, _: []const []const u8) void {
    const env = Environment.init(allocator) catch {
        output.err("could not resolve environment", .{});
        return;
    };

    const symlinks = env.managedSymlinks(allocator) catch {
        output.err("could not resolve symlinks from tinrc.yml", .{});
        return;
    };

    output.info("unlinking config files...", .{});

    for (symlinks) |symlink| {
        switch (symlink.status()) {
            .linked, .wrong_target, .broken => {
                symlink.unlink() catch {
                    output.err("failed to unlink {s}", .{symlink.name});
                    continue;
                };
                symlink.restore(allocator) catch {};
                output.success("unlink {s}", .{symlink.name});
            },
            .not_a_symlink => {
                output.warn("skip {s} (not a symlink, not managed by tin)", .{symlink.name});
            },
            .missing => {
                output.info("skip {s} (not present)", .{symlink.name});
            },
        }
    }

    output.success("unlinking complete", .{});
}
