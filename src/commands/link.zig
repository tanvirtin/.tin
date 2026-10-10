const std = @import("std");
const output = @import("../lib/output.zig");
const Environment = @import("../core/environment.zig");

pub const meta = .{
    .name = "link",
    .description = "Create config symlinks for all managed files",
};

pub fn execute(allocator: std.mem.Allocator, _: []const []const u8) u8 {
    const paths = Environment.Paths.init(allocator) catch {
        output.err("could not resolve environment paths", .{});
        return 1;
    };

    const config = Environment.Config.load(allocator, paths) orelse {
        output.err("could not load tinrc.yml", .{});
        return 1;
    };

    const symlinks = Environment.RecipeManager.getManagedSymlinks(allocator, config, paths) catch {
        output.err("could not resolve symlinks from tinrc.yml", .{});
        return 1;
    };

    if (symlinks.len == 0) {
        output.warn("no symlinks defined in tinrc.yml", .{});
        return 0;
    }

    output.info("linking config files...", .{});

    var failed: usize = 0;
    for (symlinks) |symlink| {
        const status = symlink.status();
        switch (status) {
            .linked => {
                output.success("skip {s} (already linked)", .{symlink.name});
            },
            .missing => {
                symlink.link() catch {
                    output.err("failed to link {s}", .{symlink.name});
                    failed += 1;
                    continue;
                };
                output.success("link {s}", .{symlink.name});
            },
            .wrong_target, .not_a_symlink => {
                const backed_up = symlink.backupBeforeRepair(status);
                if (backed_up) symlink.backup(allocator) catch {
                    output.err("failed to backup {s}", .{symlink.name});
                    failed += 1;
                    continue;
                };
                symlink.link() catch {
                    output.err("failed to link {s}", .{symlink.name});
                    failed += 1;
                    continue;
                };
                if (backed_up) {
                    output.success("link {s} (backed up existing)", .{symlink.name});
                } else {
                    output.success("refresh {s}", .{symlink.name});
                }
            },
            .broken => {
                symlink.link() catch {
                    output.err("failed to link {s}", .{symlink.name});
                    failed += 1;
                    continue;
                };
                output.success("link {s} (replaced broken)", .{symlink.name});
            },
            .source_missing => {
                output.warn("skip {s} (source missing: {s})", .{ symlink.name, symlink.source });
                failed += 1;
            },
        }
    }

    if (failed > 0) {
        output.err("linking finished with {d} failure{s}", .{ failed, if (failed == 1) "" else "s" });
        return 1;
    }

    output.success("linking complete", .{});
    return 0;
}
