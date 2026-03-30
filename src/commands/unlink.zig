const std = @import("std");
const output = @import("../lib/output.zig");
const Environment = @import("../core/environment.zig");
const Symlink = @import("../core/symlink.zig");

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

    for (symlinks) |s| {
        const st = s.status();
        switch (st) {
            .linked, .wrong_target, .broken => {
                s.unlink() catch {
                    output.err("failed to unlink {s}", .{s.name});
                    continue;
                };
                s.restore(allocator) catch {};
                output.success("unlink {s}", .{s.name});
            },
            .not_a_symlink => {
                output.warn("skip {s} (not a symlink, not managed by tin)", .{s.name});
            },
            .missing => {
                output.info("skip {s} (not present)", .{s.name});
            },
        }
    }

    output.success("unlinking complete", .{});
}
