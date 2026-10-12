const std = @import("std");
const output = @import("../lib/output.zig");
const Environment = @import("../core/environment.zig");

pub const meta = .{
    .name = "unlink",
    .description = "Remove symlinks and restore backups",
};

pub fn execute(allocator: std.mem.Allocator, _: []const []const u8) u8 {
    const env = Environment.init(allocator) catch {
        output.err("could not resolve environment", .{});
        return output.ExitCode.failure;
    };

    const symlinks = env.managedSymlinks(allocator) catch {
        output.err("could not resolve symlinks from tinrc.yml", .{});
        return output.ExitCode.failure;
    };

    output.info("unlinking config files...", .{});

    var failed: usize = 0;

    for (symlinks) |symlink| {
        switch (symlink.status()) {
            .linked, .wrong_target, .broken, .source_missing => {
                symlink.unlink() catch {
                    output.record(.err, .{ .action = "unlink", .target = symlink.name, .status = "failed" }, "failed to unlink {s}", .{symlink.name});
                    failed += 1;
                    continue;
                };
                symlink.restore(allocator) catch |e| {
                    failed += 1;
                    output.record(.err, .{ .action = "restore", .target = symlink.name, .status = "failed" }, "failed to restore {s} from {s}.tin.bak: {s}", .{ symlink.name, symlink.target, @errorName(e) });
                    continue;
                };
                output.record(.success, .{ .action = "unlink", .target = symlink.name, .status = "removed" }, "unlink {s}", .{symlink.name});
            },
            .not_a_symlink => {
                output.record(.warn, .{ .action = "unlink", .target = symlink.name, .status = "skipped" }, "skip {s} (not a symlink, not managed by tin)", .{symlink.name});
            },
            .missing => {
                output.record(.info, .{ .action = "unlink", .target = symlink.name, .status = "absent" }, "skip {s} (not present)", .{symlink.name});
            },
        }
    }

    if (failed > 0) {
        output.err("unlinking finished with {d} failure{s}", .{ failed, if (failed == 1) "" else "s" });
        return output.ExitCode.partial;
    }

    output.success("unlinking complete", .{});
    return output.ExitCode.success;
}
