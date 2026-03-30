const std = @import("std");
const output = @import("../lib/output.zig");
const fs = @import("../lib/fs.zig");
const platform = @import("../platform/platform.zig");
const Environment = @import("../core/environment.zig");

pub const meta = .{
    .name = "fonts",
    .description = "Install fonts to system font directory",
};

pub fn execute(allocator: std.mem.Allocator, _: []const []const u8) void {
    const env = Environment.init(allocator) catch {
        output.err("could not resolve environment", .{});
        return;
    };

    const source_dir_path = env.fontSourceDir(allocator) catch {
        output.err("could not resolve font source directory", .{});
        return;
    };

    const dest_dir_path = platform.getFontDir(allocator, env.home_dir) catch {
        output.err("could not resolve font destination directory", .{});
        return;
    };

    fs.ensureDirectoryExists(dest_dir_path) catch {
        output.err("could not create font directory: {s}", .{dest_dir_path});
        return;
    };

    var source_dir = std.fs.openDirAbsolute(source_dir_path, .{ .iterate = true }) catch {
        output.err("could not open font source: {s}", .{source_dir_path});
        return;
    };
    defer source_dir.close();

    output.info("installing fonts...", .{});

    var installed: usize = 0;
    var skipped: usize = 0;
    var iter = source_dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".ttf")) continue;

        const dest_path = std.fs.path.join(allocator, &.{ dest_dir_path, entry.name }) catch continue;

        if (fs.pathExists(dest_path)) {
            skipped += 1;
            continue;
        }

        const source_path = std.fs.path.join(allocator, &.{ source_dir_path, entry.name }) catch continue;
        std.fs.copyFileAbsolute(source_path, dest_path, .{}) catch {
            output.err("failed to copy {s}", .{entry.name});
            continue;
        };
        output.success("copy {s}", .{entry.name});
        installed += 1;
    }

    platform.postFontInstall(allocator) catch {
        output.warn("font cache refresh failed", .{});
    };

    if (installed > 0) {
        output.success("fonts installed ({d} new, {d} skipped)", .{ installed, skipped });
    } else {
        output.success("fonts up to date ({d} skipped)", .{skipped});
    }
}
