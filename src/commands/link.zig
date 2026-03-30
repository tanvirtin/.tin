const std = @import("std");
const output = @import("../lib/output.zig");
const Environment = @import("../core/environment.zig");

pub const meta = .{
    .name = "link",
    .description = "Create config symlinks for all managed files",
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

    if (symlinks.len == 0) {
        output.warn("no symlinks defined in tinrc.yml", .{});
        return;
    }

    output.info("linking config files...", .{});

    for (symlinks) |symlink| {
        switch (symlink.status()) {
            .linked => {
                output.success("skip {s} (already linked)", .{symlink.name});
            },
            .missing => {
                symlink.link() catch {
                    output.err("failed to link {s}", .{symlink.name});
                    continue;
                };
                output.success("link {s}", .{symlink.name});
            },
            .wrong_target, .not_a_symlink => {
                symlink.backup(allocator) catch {
                    output.err("failed to backup {s}", .{symlink.name});
                    continue;
                };
                symlink.link() catch {
                    output.err("failed to link {s}", .{symlink.name});
                    continue;
                };
                output.success("link {s} (backed up existing)", .{symlink.name});
            },
            .broken => {
                symlink.unlink() catch {};
                symlink.link() catch {
                    output.err("failed to link {s}", .{symlink.name});
                    continue;
                };
                output.success("link {s} (replaced broken)", .{symlink.name});
            },
        }
    }

    output.success("linking complete", .{});
}
