const std = @import("std");
const process = @import("../lib/process.zig");

/// TmuxProvider — wraps tmux CLI operations in a single file. When zmux
/// matures, swap the backend here. All tin's tmux shell-out calls route
/// through these functions — nowhere else in the codebase touches a tmux
/// arg list directly.

pub fn available(allocator: std.mem.Allocator) bool {
    const res = process.captureExit(allocator, &.{ "sh", "-c", "command -v tmux" }) catch return false;
    return res.code == 0;
}

pub fn hasSession(allocator: std.mem.Allocator, session: []const u8) bool {
    const res = process.captureExit(allocator, &.{ "tmux", "has-session", "-t", session }) catch return false;
    return res.code == 0;
}

pub fn hasWindow(allocator: std.mem.Allocator, session: []const u8, window: []const u8) bool {
    const target = std.fmt.allocPrint(allocator, "{s}:{s}", .{ session, window }) catch return false;
    defer allocator.free(target);
    return hasSession(allocator, target);
}

pub fn killSession(allocator: std.mem.Allocator, session: []const u8) void {
    _ = process.run(allocator, &.{ "tmux", "kill-session", "-t", session }) catch {};
}

/// Create a session that runs a specific command (e.g. pi). Keeps the
/// pane aliver after the command exits so output is harvestable.
pub fn createSession(allocator: std.mem.Allocator, session: []const u8, cwd: []const u8, command: []const u8) !void {
    const launch = try std.fmt.allocPrint(allocator,
        "tmux new-session -d -s {s} -c {s} '{s}' ; tmux set-option -t {s} remain-on-exit on",
        .{ session, cwd, command, session },
    );
    defer allocator.free(launch);
    try process.run(allocator, &.{ "sh", "-c", launch });
}

/// Create a bare session in a directory (no special command). Used by the
/// workspace runtime to open an interactive shell rooted at the workspace.
pub fn createSessionSimple(allocator: std.mem.Allocator, session: []const u8, cwd: []const u8) !void {
    try process.run(allocator, &.{ "tmux", "new-session", "-d", "-s", session, "-c", cwd });
}

pub fn createWindow(allocator: std.mem.Allocator, session: []const u8, window: []const u8, dir: []const u8, cmd: []const u8) !void {
    try process.run(allocator, &.{ "tmux", "new-window", "-t", session, "-n", window, "-c", dir, cmd });
    const target = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ session, window });
    defer allocator.free(target);
    _ = process.captureExit(allocator, &.{ "tmux", "set-option", "-t", target, "remain-on-exit", "on" }) catch {};
}

pub fn windowCount(allocator: std.mem.Allocator, session: []const u8) usize {
    const res = process.captureExit(allocator, &.{ "tmux", "list-windows", "-t", session }) catch return 0;
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, res.stdout, '\n');
    while (lines.next()) |line| {
        if (line.len > 0) count += 1;
    }
    return count;
}
