const std = @import("std");
const output = @import("../lib/output.zig");
const process = @import("../lib/process.zig");
const Paths = @import("../core/environment/paths.zig").Paths;
const upgrade = @import("../core/upgrade.zig");

pub const meta = .{
    .name = "upgrade",
    .description = "Check for a newer release and install it",
};

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) u8 {
    if (managedExternally(allocator)) return output.ExitCode.success;

    var check_only = false;
    var passthrough = std.ArrayListUnmanaged([]const u8){};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--check")) {
            check_only = true;
        } else if (std.mem.eql(u8, arg, "--from-source") or std.mem.eql(u8, arg, "--from-binary")) {
            passthrough.append(allocator, arg) catch return 1;
        } else if (std.mem.eql(u8, arg, "--version")) {
            if (i + 1 >= args.len) {
                output.err("--version requires a tag", .{});
                return 1;
            }
            i += 1;
            if (!validVersion(args[i])) {
                output.err("invalid version: {s}", .{args[i]});
                return 1;
            }
            passthrough.append(allocator, "--version") catch return 1;
            passthrough.append(allocator, args[i]) catch return 1;
        } else if (std.mem.startsWith(u8, arg, "--version=")) {
            const version = arg["--version=".len..];
            if (!validVersion(version)) {
                output.err("invalid version: {s}", .{version});
                return 1;
            }
            passthrough.append(allocator, arg) catch return 1;
        } else {
            output.err("unknown argument: {s}", .{arg});
            return 1;
        }
    }

    const paths = Paths.init(allocator) catch {
        output.err("could not resolve environment paths", .{});
        return 1;
    };

    const installed = paths.readRevision(allocator);
    const tag = upgrade.fetchLatestTag(allocator) orelse {
        output.warn("could not determine the latest release; check your network", .{});
        return 0;
    };
    const latest = upgrade.fetchTagRevision(allocator, tag);
    const state = upgrade.classify(installed, latest);

    switch (state) {
        .current => output.success("tin is up to date ({s})", .{tag}),
        .behind => output.info("update available: {s} (installed {s})", .{ tag, revisionLabel(installed) }),
        .unknown => output.warn("could not compare revisions (latest {s})", .{tag}),
    }

    if (check_only) return if (state == .behind) 1 else 0;
    if (state == .current and passthrough.items.len == 0) return 0;

    return applyInstaller(allocator, paths, passthrough.items);
}

fn managedExternally(allocator: std.mem.Allocator) bool {
    const marker = std.process.getEnvVarOwned(allocator, "TIN_MANAGED_BY") catch return false;
    defer allocator.free(marker);
    if (std.mem.eql(u8, marker, "homebrew")) {
        output.info("tin is managed by Homebrew", .{});
        output.plain("Run 'brew upgrade tin' to update.", .{});
        return true;
    }
    return false;
}

fn revisionLabel(installed: ?[]const u8) []const u8 {
    const revision = installed orelse return "unknown";
    if (revision.len <= 7) return revision;
    return revision[0..7];
}

fn validVersion(version: []const u8) bool {
    if (version.len == 0) return false;
    if (std.mem.startsWith(u8, version, "-")) return false;
    if (std.mem.indexOf(u8, version, "..") != null) return false;
    for (version) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '/' or c == '-')) return false;
    }
    return true;
}

fn applyInstaller(allocator: std.mem.Allocator, paths: Paths, extra: []const []const u8) u8 {
    const url = upgrade.installerUrl(allocator);
    const script = std.fmt.allocPrint(allocator, "{s}/.tin-upgrade-{d}.sh", .{ paths.tin_dir, std.time.timestamp() }) catch {
        output.err("could not prepare the installer path", .{});
        return 1;
    };
    defer std.fs.deleteFileAbsolute(script) catch {};

    output.info("downloading installer from {s}", .{url});
    const download = process.capture(allocator, &.{ "curl", "-fsSL", "--max-time", "60", url, "-o", script }) catch {
        output.err("could not run curl", .{});
        return 1;
    };
    defer download.deinit(allocator);
    if (download.code != 0) {
        output.err("could not download the installer", .{});
        return 1;
    }

    var argv = std.ArrayListUnmanaged([]const u8){};
    argv.append(allocator, "sh") catch return 1;
    argv.append(allocator, script) catch return 1;
    for (extra) |arg| argv.append(allocator, arg) catch return 1;

    return process.runCode(allocator, argv.items) catch {
        output.err("could not run the installer", .{});
        return 1;
    };
}
