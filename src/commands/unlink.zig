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

    var failed: usize = 0;

    for (symlinks) |symlink| {
        switch (symlink.status()) {
            .linked, .wrong_target, .broken => {
                symlink.unlink() catch {
                    output.err("failed to unlink {s}", .{symlink.name});
                    failed += 1;
                    continue;
                };
                symlink.restore(allocator) catch |e| {
                    failed += 1;
                    output.err("failed to restore {s} from {s}.tin.bak: {s}", .{ symlink.name, symlink.target, @errorName(e) });
                    continue;
                };
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

    if (failed > 0) {
        output.err("unlinking finished with {d} failure{s}", .{ failed, if (failed == 1) "" else "s" });
        return;
    }

    output.success("unlinking complete", .{});
}
