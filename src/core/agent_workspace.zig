const std = @import("std");
const agent = @import("agent.zig");
const process = @import("../lib/process.zig");
const output = @import("../lib/output.zig");
const Allocator = std.mem.Allocator;

pub const Group = struct {
    window: []const u8,
    directory: []const u8,
    server: []const u8,
    coordinator: []const u8,
    name: []const u8,

    pub fn binding(self: Group, allocator: Allocator) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{s}/{s}", .{ self.window, self.coordinator });
    }
};

pub const Pair = struct {
    window: []const u8,
    directory: []const u8,
    server: []const u8,
    coordinator: []const u8,
    pane: []const u8,
    session: []const u8,
};

pub fn pairOf(allocator: Allocator) !Pair {
    const group = try currentGroup(allocator);
    const panes = try command(allocator, &.{ "tmux", "list-panes", "-t", group.window, "-F", "#{pane_id}\t#{@tin_session}\t#{@tin_server}\t#{pane_dead}" });
    var lines = std.mem.tokenizeScalar(u8, panes, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const pane = fields.next() orelse continue;
        const session = fields.next() orelse continue;
        const server = fields.next() orelse continue;
        const dead = fields.next() orelse continue;
        if (session.len > 0 and std.mem.eql(u8, server, group.server) and std.mem.eql(u8, dead, "0")) {
            return .{ .window = group.window, .directory = group.directory, .server = group.server, .coordinator = group.coordinator, .pane = pane, .session = session };
        }
    }
    return error.NoOpenCodePane;
}

pub fn currentGroup(allocator: Allocator) !Group {
    if (std.posix.getenv("TMUX") == null) return error.NotInTinGroup;
    const pane = std.posix.getenv("TMUX_PANE") orelse return error.NotInTinGroup;
    const line = try command(allocator, &.{ "tmux", "display-message", "-p", "-t", pane, "#{window_id}\t#{@tin_worktree}\t#{@tin_server}\t#{@tin_coordinator}\t#{window_name}" });
    return parseGroup(line) orelse error.NotInTinGroup;
}

fn parseGroup(line: []const u8) ?Group {
    var fields = std.mem.splitScalar(u8, line, '\t');
    const window = fields.next() orelse return null;
    const directory = fields.next() orelse return null;
    const server = fields.next() orelse return null;
    const coordinator = fields.next() orelse return null;
    const name = fields.next() orelse return null;
    if (directory.len == 0 or server.len == 0 or coordinator.len == 0) return null;
    return .{ .window = window, .directory = directory, .server = server, .coordinator = coordinator, .name = name };
}

fn command(allocator: Allocator, args: []const []const u8) ![]const u8 {
    const result = try std.process.Child.run(.{ .allocator = allocator, .argv = args });
    if (result.term != .Exited or result.term.Exited != 0) {
        output.err("{s}: {s}", .{ args[0], std.mem.trim(u8, result.stderr, " \r\n") });
        return error.WorkspaceCommandFailed;
    }
    return std.mem.trim(u8, result.stdout, " \r\n\t");
}

pub fn groups(allocator: Allocator) ![]Group {
    const result = process.captureExit(allocator, &.{ "tmux", "list-windows", "-a", "-F", "#{window_id}\t#{@tin_worktree}\t#{@tin_server}\t#{@tin_coordinator}\t#{window_name}" }) catch return &.{};
    if (result.code != 0) return &.{};
    var list = std.ArrayListUnmanaged(Group){};
    var seen = std.StringHashMapUnmanaged(void){};
    var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        const group = parseGroup(line) orelse continue;
        const entry = try seen.getOrPut(allocator, group.window);
        if (entry.found_existing) continue;
        try list.append(allocator, group);
    }
    return list.toOwnedSlice(allocator);
}

fn ensurePane(api: *agent.Api, id: []const u8, window: []const u8, cwd: []const u8) ![]const u8 {
    const allocator = api.allocator;
    api.scope = id;
    _ = try api.session(id);
    const panes = try command(allocator, &.{ "tmux", "list-panes", "-t", window, "-F", "#{pane_id}\t#{@tin_session}\t#{@tin_server}\t#{pane_dead}" });
    var lines = std.mem.tokenizeScalar(u8, panes, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const pane = fields.next() orelse continue;
        const session = fields.next() orelse continue;
        const server = fields.next() orelse continue;
        const dead = fields.next() orelse continue;
        if (session.len > 0 and std.mem.eql(u8, server, api.server.name) and std.mem.eql(u8, dead, "0")) {
            _ = try command(allocator, &.{ "tmux", "select-pane", "-t", pane });
            return pane;
        }
    }
    const executable = try std.fs.selfExePathAlloc(allocator);
    const binding = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ window, id });
    const pane = try command(allocator, &.{ "tmux", "split-window", "-h", "-l", "27%", "-t", window, "-c", cwd, "-P", "-F", "#{pane_id}", executable, "agent", "attach", id, "--server", api.server.name, "--directory", api.server.directory, "--group", binding, "--teardown", window });
    _ = try command(allocator, &.{ "tmux", "set-option", "-p", "-t", pane, "@tin_session", id });
    _ = try command(allocator, &.{ "tmux", "set-option", "-p", "-t", pane, "@tin_server", api.server.name });
    _ = try command(allocator, &.{ "tmux", "select-pane", "-t", pane });
    return pane;
}

fn focus(allocator: Allocator, window: []const u8) !void {
    if (std.posix.getenv("TMUX") != null) {
        _ = try command(allocator, &.{ "tmux", "switch-client", "-t", window });
    }
}

fn safeName(allocator: Allocator, name: []const u8) ![]const u8 {
    const result = try allocator.dupe(u8, name);
    for (result) |*char| {
        if (!std.ascii.isAlphanumeric(char.*) and char.* != '-' and char.* != '_') char.* = '-';
    }
    return result;
}

pub fn open(api: *agent.Api, path: []const u8, force_new: bool) !Group {
    const allocator = api.allocator;
    const root = try command(allocator, &.{ "git", "-C", path, "rev-parse", "--show-toplevel" });
    const directory = try std.fs.cwd().realpathAlloc(allocator, root);
    api.server.directory = directory;
    if (!force_new) {
        for (try groups(allocator)) |group| {
            if (std.mem.eql(u8, group.directory, directory) and std.mem.eql(u8, group.server, api.server.name)) {
                _ = try ensurePane(api, group.coordinator, group.window, directory);
                try focus(allocator, group.window);
                return group;
            }
        }
    }
    const common = try command(allocator, &.{ "git", "-C", root, "rev-parse", "--path-format=absolute", "--git-common-dir" });
    const repository = std.fs.path.basename(std.fs.path.dirname(common) orelse root);
    const session_name = try std.fmt.allocPrint(allocator, "tin-{s}-{x}", .{ try safeName(allocator, repository), std.hash.Wyhash.hash(0, common) & 0xffffff });
    const branch = try command(allocator, &.{ "git", "-C", root, "branch", "--show-current" });
    const name = if (branch.len > 0) branch else std.fs.path.basename(root);
    const sessions = if (force_new) .null else try api.request("GET", "/session?limit=200", null, directory);
    var coordinator: ?[]const u8 = null;
    if (force_new) {
        const session = try agent.run(api, .{ .action = "create", .argument = name }, null);
        if (session != .object) return error.InvalidResponse;
        const id = session.object.get("id") orelse return error.InvalidResponse;
        if (id != .string) return error.InvalidResponse;
        coordinator = id.string;
        for (try groups(allocator)) |group| {
            if (std.mem.eql(u8, group.directory, directory) and std.mem.eql(u8, group.server, api.server.name)) {
                killChatPanes(allocator, group.window, api.server.name);
                _ = try command(allocator, &.{ "tmux", "set-option", "-w", "-t", group.window, "@tin_coordinator", coordinator.? });
                _ = try ensurePane(api, coordinator.?, group.window, directory);
                try focus(allocator, group.window);
                return .{ .window = group.window, .directory = group.directory, .server = group.server, .coordinator = coordinator.?, .name = group.name };
            }
        }
    } else if (sessions == .array) {
        for (sessions.array.items) |session| {
            if (session != .object) continue;
            const dir = session.object.get("directory") orelse continue;
            const title = session.object.get("title") orelse continue;
            const id = session.object.get("id") orelse continue;
            if (dir == .string and title == .string and id == .string and std.mem.eql(u8, dir.string, directory) and std.mem.startsWith(u8, title.string, "Control: ")) {
                coordinator = id.string;
                break;
            }
        }
    }
    if (coordinator == null) {
        const session = try agent.run(api, .{ .action = "create", .argument = name }, null);
        if (session != .object) return error.InvalidResponse;
        const id = session.object.get("id") orelse return error.InvalidResponse;
        if (id != .string) return error.InvalidResponse;
        coordinator = id.string;
    }
    const existing = try process.captureExit(allocator, &.{ "tmux", "has-session", "-t", session_name });
    const window = if (existing.code == 0)
        try command(allocator, &.{ "tmux", "new-window", "-d", "-t", session_name, "-n", name, "-c", root, "-P", "-F", "#{window_id}", "nvim" })
    else
        try command(allocator, &.{ "tmux", "new-session", "-d", "-s", session_name, "-n", name, "-c", root, "-P", "-F", "#{window_id}", "nvim" });
    _ = try command(allocator, &.{ "tmux", "set-option", "-t", session_name, "detach-on-destroy", "off" });
    _ = try command(allocator, &.{ "tmux", "set-option", "-w", "-t", window, "@tin_worktree", directory });
    _ = try command(allocator, &.{ "tmux", "set-option", "-w", "-t", window, "@tin_server", api.server.name });
    _ = try command(allocator, &.{ "tmux", "set-option", "-w", "-t", window, "@tin_coordinator", coordinator.? });
    _ = try ensurePane(api, coordinator.?, window, directory);
    try focus(allocator, window);
    return .{ .window = window, .directory = directory, .server = api.server.name, .coordinator = coordinator.?, .name = name };
}

pub fn worktree(api: *agent.Api, branch: []const u8, force_new: bool) !Group {
    const allocator = api.allocator;
    _ = try command(allocator, &.{ "git", "check-ref-format", "--branch", branch });
    const root = try command(allocator, &.{ "git", "-C", api.server.directory, "rev-parse", "--show-toplevel" });
    _ = try api.request("GET", "/global/health", null, null);
    const worktrees = try command(allocator, &.{ "git", "-C", root, "worktree", "list", "--porcelain" });
    var lines = std.mem.splitScalar(u8, worktrees, '\n');
    var path: ?[]const u8 = null;
    const ref = try std.fmt.allocPrint(allocator, "branch refs/heads/{s}", .{branch});
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "worktree ")) path = line[9..];
        if (std.mem.eql(u8, line, ref)) return open(api, path orelse return error.InvalidWorktree, force_new);
    }
    const destination = try std.fmt.allocPrint(allocator, "{s}/{s}-{s}-{x}", .{ std.fs.path.dirname(root).?, std.fs.path.basename(root), try safeName(allocator, branch), std.hash.Wyhash.hash(0, branch) & 0xffffff });
    const exists = try process.captureExit(allocator, &.{ "git", "-C", root, "show-ref", "--verify", "--quiet", try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch}) });
    _ = if (exists.code == 0)
        try command(allocator, &.{ "git", "-C", root, "worktree", "add", destination, branch })
    else
        try command(allocator, &.{ "git", "-C", root, "worktree", "add", "-b", branch, destination });
    return open(api, destination, force_new) catch |err| {
        output.err("worktree created at {s}; reopen with tin agent open <path>", .{destination});
        return err;
    };
}

fn killChatPanes(allocator: Allocator, window: []const u8, server: []const u8) void {
    const panes = command(allocator, &.{ "tmux", "list-panes", "-t", window, "-F", "#{pane_id}\t#{@tin_session}\t#{@tin_server}" }) catch return;
    var lines = std.mem.tokenizeScalar(u8, panes, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const pane = fields.next() orelse continue;
        const session = fields.next() orelse continue;
        const pane_server = fields.next() orelse continue;
        if (session.len > 0 and std.mem.eql(u8, pane_server, server)) {
            _ = command(allocator, &.{ "tmux", "kill-pane", "-t", pane }) catch {};
        }
    }
}
