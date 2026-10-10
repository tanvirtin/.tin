const std = @import("std");
const fs = @import("../lib/fs.zig");
const output = @import("../lib/output.zig");
const platform = @import("../platform/platform.zig");
const Environment = @import("environment.zig");

pub fn linkManaged(allocator: std.mem.Allocator, paths: Environment.Paths, config: Environment.Config) u8 {
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
            .wrong_target, .not_a_symlink, .broken => {
                const backed_up = symlink.repair(allocator, status) catch |e| {
                    switch (e) {
                        error.BackupFailed => output.err("failed to backup {s}", .{symlink.name}),
                        error.LinkFailed => output.err("failed to link {s}", .{symlink.name}),
                    }
                    failed += 1;
                    continue;
                };
                if (backed_up) {
                    output.success("link {s} (backed up existing)", .{symlink.name});
                } else if (status == .broken) {
                    output.success("link {s} (replaced broken)", .{symlink.name});
                } else {
                    output.success("refresh {s}", .{symlink.name});
                }
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

pub fn installFonts(allocator: std.mem.Allocator, paths: Environment.Paths, config: Environment.Config) u8 {
    const source_dir_path = Environment.RecipeManager.getFontSourceDir(allocator, config, paths) catch {
        output.err("could not resolve font source directory", .{});
        return 1;
    };

    const dest_dir_path = platform.getFontDir(allocator, paths.home_dir) catch {
        output.err("could not resolve font destination directory", .{});
        return 1;
    };

    fs.ensureDirectoryExists(dest_dir_path) catch {
        output.err("could not create font directory: {s}", .{dest_dir_path});
        return 1;
    };

    var source_dir = std.fs.openDirAbsolute(source_dir_path, .{ .iterate = true }) catch {
        output.err("could not open font source: {s}", .{source_dir_path});
        return 1;
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
    return 0;
}
