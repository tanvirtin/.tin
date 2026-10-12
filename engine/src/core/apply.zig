const std = @import("std");
const fs = @import("../lib/fs.zig");
const output = @import("../lib/output.zig");
const platform = @import("../platform/platform.zig");
const Environment = @import("environment.zig");

pub fn linkManaged(allocator: std.mem.Allocator, paths: Environment.Paths, config: Environment.Config) u8 {
    const symlinks = Environment.RecipeManager.getManagedSymlinks(allocator, config, paths) catch {
        output.err("could not resolve symlinks from tinrc.yml", .{});
        return output.ExitCode.failure;
    };

    if (symlinks.len == 0) {
        output.warn("no symlinks defined in tinrc.yml", .{});
        return output.ExitCode.success;
    }

    output.info("linking config files...", .{});

    var failed: usize = 0;
    for (symlinks) |symlink| {
        const status = symlink.status();
        switch (status) {
            .linked => {
                output.record(.success, .{ .action = "link", .target = symlink.name, .status = "already-linked" }, "skip {s} (already linked)", .{symlink.name});
            },
            .missing => {
                symlink.link() catch {
                    output.record(.err, .{ .action = "link", .target = symlink.name, .status = "failed" }, "failed to link {s}", .{symlink.name});
                    failed += 1;
                    continue;
                };
                output.record(.success, .{ .action = "link", .target = symlink.name, .status = "created" }, "link {s}", .{symlink.name});
            },
            .wrong_target, .not_a_symlink, .broken => {
                const backed_up = symlink.repair(allocator, status) catch |e| {
                    switch (e) {
                        error.BackupFailed => output.record(.err, .{ .action = "backup", .target = symlink.name, .status = "failed" }, "failed to backup {s}", .{symlink.name}),
                        error.LinkFailed => output.record(.err, .{ .action = "link", .target = symlink.name, .status = "failed" }, "failed to link {s}", .{symlink.name}),
                    }
                    failed += 1;
                    continue;
                };
                if (backed_up) {
                    output.record(.success, .{ .action = "link", .target = symlink.name, .status = "backed-up" }, "link {s} (backed up existing)", .{symlink.name});
                } else if (status == .broken) {
                    output.record(.success, .{ .action = "link", .target = symlink.name, .status = "replaced-broken" }, "link {s} (replaced broken)", .{symlink.name});
                } else {
                    output.record(.success, .{ .action = "link", .target = symlink.name, .status = "refreshed" }, "refresh {s}", .{symlink.name});
                }
            },
            .source_missing => {
                output.record(.warn, .{ .action = "link", .target = symlink.name, .status = "source-missing" }, "skip {s} (source missing: {s})", .{ symlink.name, symlink.source });
                failed += 1;
            },
        }
    }

    if (failed > 0) {
        output.err("linking finished with {d} failure{s}", .{ failed, if (failed == 1) "" else "s" });
        return output.ExitCode.partial;
    }

    output.success("linking complete", .{});
    return output.ExitCode.success;
}

pub fn installFonts(allocator: std.mem.Allocator, paths: Environment.Paths, config: Environment.Config) u8 {
    const source_dir_path = Environment.RecipeManager.getFontSourceDir(allocator, config, paths) catch {
        output.err("could not resolve font source directory", .{});
        return output.ExitCode.failure;
    };

    const dest_dir_path = platform.getFontDir(allocator, paths.home_dir) catch {
        output.err("could not resolve font destination directory", .{});
        return output.ExitCode.failure;
    };

    fs.ensureDirectoryExists(dest_dir_path) catch {
        output.err("could not create font directory: {s}", .{dest_dir_path});
        return output.ExitCode.failure;
    };

    var source_dir = std.fs.openDirAbsolute(source_dir_path, .{ .iterate = true }) catch {
        output.err("could not open font source: {s}", .{source_dir_path});
        return output.ExitCode.failure;
    };
    defer source_dir.close();

    output.info("installing fonts...", .{});

    var installed: usize = 0;
    var skipped: usize = 0;
    var failed: usize = 0;
    var iter = source_dir.iterate();
    while (true) {
        const entry = iter.next() catch |e| {
            output.record(.err, .{ .action = "fonts", .target = source_dir_path, .status = "failed" }, "failed to read font directory {s}: {s}", .{ source_dir_path, @errorName(e) });
            return output.ExitCode.failure;
        } orelse break;
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".ttf")) continue;

        const dest_path = std.fs.path.join(allocator, &.{ dest_dir_path, entry.name }) catch |e| {
            output.record(.err, .{ .action = "copy", .target = entry.name, .status = "failed" }, "failed to resolve destination for {s}: {s}", .{ entry.name, @errorName(e) });
            failed += 1;
            continue;
        };

        if (fs.pathExists(dest_path)) {
            skipped += 1;
            continue;
        }

        const source_path = std.fs.path.join(allocator, &.{ source_dir_path, entry.name }) catch |e| {
            output.record(.err, .{ .action = "copy", .target = entry.name, .status = "failed" }, "failed to resolve source for {s}: {s}", .{ entry.name, @errorName(e) });
            failed += 1;
            continue;
        };
        std.fs.copyFileAbsolute(source_path, dest_path, .{}) catch |e| {
            output.record(.err, .{ .action = "copy", .target = entry.name, .status = "failed" }, "failed to copy {s}: {s}", .{ entry.name, @errorName(e) });
            failed += 1;
            continue;
        };
        output.record(.success, .{ .action = "copy", .target = entry.name, .status = "created" }, "copy {s}", .{entry.name});
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

    if (failed > 0) {
        output.err("fonts finished with {d} failure{s}", .{ failed, if (failed == 1) "" else "s" });
        return output.ExitCode.partial;
    }
    return output.ExitCode.success;
}
