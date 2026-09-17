const std = @import("std");
const agent = @import("../core/agent.zig");
const Environment = @import("../core/environment.zig");
const envfile = @import("../lib/envfile.zig");
const output = @import("../lib/output.zig");
const workspace = @import("../core/agent_workspace.zig");

pub const meta = .{ .name = "agent", .description = "Supervise local and remote OpenCode agents (JSON API for editors)" };
pub const children = [_][]const u8{ "servers", "snapshot", "create", "prompt", "inspect", "diff", "stop", "permission", "answer", "reject-question", "attach", "group", "groups", "open", "worktree", "serve" };

pub fn help() void {
    output.plain(
        \\tin agent servers                          List connections from tinrc.yml
        \\tin agent serve                            Run local server in the background (--foreground in this terminal; --stop shuts it down)
        \\tin agent groups                           List live worktree/tmux groups
        \\tin agent group                            Resolve this pane's own group connection
        \\tin agent open <local worktree path>        Reopen/create a Neovim + OpenCode tmux window
        \\tin agent worktree <branch>                 Create/reuse a local worktree and open its group
        \\tin agent snapshot                         Sessions, status, permissions, questions
        \\tin agent create <title>                    Create a coordinator session
        \\tin agent prompt <session>                  Send stdin as an asynchronous prompt
        \\tin agent inspect <session>                 Recent messages and tasks
        \\tin agent attach <session>                  Open the full OpenCode conversation (TUI)
        \\tin agent diff <session>                    Session changes from OpenCode snapshots
        \\tin agent stop <session> [--tree]            Abort one session or its descendants
        \\tin agent permission <request> <once|always|reject>
        \\tin agent answer <request>                  Read JSON answers (string[][]) from stdin
        \\tin agent reject-question <request>         Dismiss a pending question
        \\
        \\Options: --server <name> (default: local), --directory <absolute project path>
        \\open/worktree accept --new to force a fresh coordinator session instead of resuming the previous Control: one.
        \\Editor operations use --group <binding> from tin agent group. A moved pane invalidates the binding.
        \\Scoped operations reach only the group's coordinator and descendants in its worktree.
        \\Scoped create adds a child task session. Ungrouped editors cannot send messages.
        \\--directory overrides the selected server's directory; use paths on that server.
        \\For servers discovery it is only a fallback; configured remote directories stay remote.
        \\servers also includes live Tin worktree groups, identified by label + directory.
        \\Successes are JSON on stdout (except attach/serve); errors use stderr and a nonzero exit status.
        \\stop reports both stopped sessions and errors, exiting nonzero on partial failure.
        \\Without agents configuration, local connects to http://127.0.0.1:4096 in the current directory.
        \\No separate server step: any agent command boots the local server in the background
        \\on demand (pidfile ~/.tin/serve.pid, logs ~/.tin/serve.log; TIN_AUTO_SERVER=0 disables).
        \\Stop with 'tin agent serve --stop'; Ctrl-C stops a --foreground server.
        \\Default primary agent: tin-coordinator. Run tin link and restart OpenCode after installing it.
        \\Server credentials are resolved from ~/.tin/.env, then inherited environment variables.
        \\Closing the editor does not stop agents; use 'tin agent stop' for sessions.
        \\open/worktree are local operations; one tmux session per repo, one window per worktree.
        \\Outside tmux, use tmux attach to enter a created group. Closing it retains the worktree and agent history.
    , .{});
}

pub fn execute(allocator: std.mem.Allocator, args: []const []const u8) void {
    if (args.len == 0 or std.mem.eql(u8, args[0], "--help")) {
        help();
        return;
    }
    const result = executeInner(allocator, args) catch |err| {
        output.err("agent: {s}. Run 'tin help agent' for usage.", .{@errorName(err)});
        std.process.exit(1);
    };
    if (std.mem.eql(u8, args[0], "attach") or std.mem.eql(u8, args[0], "serve")) return;
    const text = agent.json(allocator, result) catch {
        output.err("agent: could not encode result", .{});
        std.process.exit(1);
    };
    output.plain("{s}", .{text});
    if (result == .object) {
        if (result.object.get("errors")) |errors| {
            if (errors == .array and errors.array.items.len > 0) std.process.exit(1);
        }
    }
}

fn executeInner(allocator: std.mem.Allocator, args: []const []const u8) !std.json.Value {
    const opts = try agent.Options.parse(args);
    const scoped = opts.group != null or std.mem.eql(u8, opts.action, "group");
    if (scoped and (std.mem.eql(u8, opts.action, "servers") or std.mem.eql(u8, opts.action, "groups") or std.mem.eql(u8, opts.action, "open") or std.mem.eql(u8, opts.action, "worktree") or std.mem.eql(u8, opts.action, "serve"))) return error.GroupActionNotAllowed;
    const group = if (scoped) try workspace.currentGroup(allocator) else null;
    if (group) |current| {
        if (opts.group) |expected| {
            if (!std.mem.eql(u8, expected, try current.binding(allocator))) return error.GroupChanged;
        }
        if (opts.server_explicit and !std.mem.eql(u8, opts.server, current.server)) return error.OutsideGroup;
        if (opts.directory) |directory| {
            if (!std.mem.eql(u8, directory, current.directory)) return error.OutsideGroup;
        }
    }
    if (std.mem.eql(u8, opts.action, "groups")) return agent.parseJson(allocator, try agent.json(allocator, try workspace.groups(allocator)));
    const env = try Environment.init(allocator);
    const servers = try agent.servers(allocator, env, opts.directory);
    if (std.mem.eql(u8, opts.action, "servers")) {
        var connections = std.ArrayListUnmanaged(agent.Server){};
        try connections.appendSlice(allocator, servers);
        for (try workspace.groups(allocator)) |live| {
            const base = for (servers) |server| {
                if (std.mem.eql(u8, server.name, live.server)) break server;
            } else continue;
            const duplicate = for (connections.items) |server| {
                if (std.mem.eql(u8, server.name, base.name) and std.mem.eql(u8, server.directory, live.directory)) break true;
            } else false;
            if (duplicate) continue;
            var connection = base;
            connection.directory = live.directory;
            connection.label = try std.fmt.allocPrint(allocator, "{s} / {s}", .{ base.name, live.name });
            try connections.append(allocator, connection);
        }
        return agent.parseJson(allocator, try agent.json(allocator, connections.items));
    }
    var server = for (servers) |item| {
        if (std.mem.eql(u8, item.name, if (group) |current| current.server else opts.server)) break item;
    } else return error.UnknownAgentServer;
    if (opts.directory) |directory| server.directory = directory;
    if (group) |current| {
        server.directory = current.directory;
        server.label = current.name;
        server.group = try current.binding(allocator);
        server.coordinator = current.coordinator;
        if (std.mem.eql(u8, opts.action, "group")) {
            if (workspace.pairOf(allocator)) |pair| {
                server.pane = pair.pane;
                server.session = pair.session;
            } else |_| {}
            return agent.parseJson(allocator, try agent.json(allocator, server));
        }
    }
    const env_path = try serverStatePath(allocator, ".env");
    const file = std.fs.openFileAbsolute(env_path, .{}) catch null;
    var credentials: []const envfile.Entry = &.{};
    if (file) |handle| {
        defer handle.close();
        credentials = try envfile.parse(allocator, try handle.readToEndAlloc(allocator, 1024 * 1024));
    }
    var api = agent.Api{ .allocator = allocator, .server = server, .credentials = credentials, .scope = server.coordinator, .guard = if (scoped) checkGroup else null };
    if (!std.mem.eql(u8, opts.action, "serve")) ensureServer(allocator, opts, server);
    if (std.mem.eql(u8, opts.action, "serve")) {
        if (opts.stop) {
            stopServer(allocator, server);
            return .null;
        }
        if (!opts.foreground and std.posix.isatty(std.posix.STDOUT_FILENO)) {
            const outcome = try backgroundServe(allocator, opts, server, false);
            if (outcome == .booted) {
                const log_path = try serverStatePath(allocator, "serve.log");
                output.plain("server {s} started in the background; logs at {s}; stop with 'tin agent serve --stop'", .{ server.name, log_path });
                return .null;
            }
            if (outcome == .up) {
                output.plain("server {s} already reachable at {s}", .{ server.name, server.url });
                return .null;
            }
        }
        try agent.serve(&api);
        return .null;
    }
    if (std.mem.eql(u8, opts.action, "open")) return agent.parseJson(allocator, try agent.json(allocator, try workspace.open(&api, opts.argument.?, opts.new)));
    if (std.mem.eql(u8, opts.action, "worktree")) return agent.parseJson(allocator, try agent.json(allocator, try workspace.worktree(&api, opts.argument.?, opts.new)));
    if (std.mem.eql(u8, opts.action, "attach")) {
        try agent.attach(&api, opts.argument.?);
        if (opts.teardown) |window| {
            if (workspace.currentGroup(api.allocator)) |current| {
                if (std.mem.eql(u8, try current.binding(api.allocator), api.server.group.?)) {
                    teardownChatPane(allocator, window, opts.argument.?);
                }
            } else |_| {}
        }
        return .null;
    }
    const needs_input = std.mem.eql(u8, opts.action, "prompt") or std.mem.eql(u8, opts.action, "answer");
    const input = if (needs_input) try std.fs.File.stdin().readToEndAlloc(allocator, 1024 * 1024) else null;
    return agent.run(&api, opts, input);
}

fn checkGroup(api: *agent.Api) !void {
    const current = try workspace.currentGroup(api.allocator);
    if (!std.mem.eql(u8, try current.binding(api.allocator), api.server.group.?) or
        !std.mem.eql(u8, current.server, api.server.name) or !std.mem.eql(u8, current.directory, api.server.directory)) return error.GroupChanged;
}

fn teardownChatPane(allocator: std.mem.Allocator, window: []const u8, session: []const u8) void {
    const result = std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "tmux", "list-panes", "-t", window, "-F", "#{pane_id}\t#{@tin_session}" } }) catch return;
    if (result.term != .Exited or result.term.Exited != 0) return;
    var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const pane = fields.next() orelse continue;
        const pane_session = fields.next() orelse continue;
        if (std.mem.eql(u8, pane_session, session)) {
            _ = std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "tmux", "kill-pane", "-t", pane } }) catch {};
        }
    }
}

const wait_poll_ns = 500 * std.time.ns_per_ms;

fn probeServer(allocator: std.mem.Allocator, url: []const u8) bool {
    const result = std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "curl", "--silent", "--max-time", "1", "-o", "/dev/null", "-w", "%{http_code}", "--noproxy", "localhost,127.0.0.1,::1", "--url", url } }) catch return false;
    if (result.term != .Exited or result.term.Exited != 0) return false;
    return !std.mem.eql(u8, std.mem.trim(u8, result.stdout, " \r\n"), "000");
}

fn waitForServer(allocator: std.mem.Allocator, url: []const u8) bool {
    for (0..20) |_| {
        if (probeServer(allocator, url)) return true;
        std.Thread.sleep(wait_poll_ns);
    }
    return false;
}

fn waitForShutdown(allocator: std.mem.Allocator, url: []const u8) bool {
    for (0..12) |_| {
        if (!probeServer(allocator, url)) return true;
        std.Thread.sleep(wait_poll_ns);
    }
    return false;
}

fn isLocalHttp(server: agent.Server) bool {
    const uri = std.Uri.parse(server.url) catch return false;
    const host = uri.host orelse return false;
    return std.mem.eql(u8, uri.scheme, "http") and (std.mem.eql(u8, host.percent_encoded, "127.0.0.1") or std.mem.eql(u8, host.percent_encoded, "localhost"));
}

const serve_state_dir = ".tin";

fn serverStatePath(allocator: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (std.posix.getenv("TIN_DIR")) |dir| return std.fs.path.join(allocator, &.{ dir, name });
    const home = std.posix.getenv("HOME") orelse return error.HomeNotSet;
    return std.fs.path.join(allocator, &.{ home, serve_state_dir, name });
}

fn reapListeners(allocator: std.mem.Allocator, url: []const u8) void {
    const uri = std.Uri.parse(url) catch return;
    const port = uri.port orelse return;
    killListenersOnPort(allocator, port, false);
}

fn isServerProcess(allocator: std.mem.Allocator, pid: []const u8) bool {
    const ps = std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "ps", "-o", "comm=", "-p", pid } }) catch return false;
    if (ps.term != .Exited or ps.term.Exited != 0) return false;
    const name = std.mem.trim(u8, ps.stdout, " \r\n");
    return std.mem.eql(u8, name, "opencode") or std.mem.startsWith(u8, name, "tin");
}

fn killListenersOnPort(allocator: std.mem.Allocator, port: u16, force: bool) void {
    const port_str = std.fmt.allocPrint(allocator, "{d}", .{port}) catch return;
    const addr_flag = std.fmt.allocPrint(allocator, "-iTCP:{s}", .{port_str}) catch return;
    defer allocator.free(addr_flag);
    const list = std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "lsof", "-t", addr_flag, "-sTCP:LISTEN" } }) catch return;
    if (list.term != .Exited or list.term.Exited != 0) return;
    var lines = std.mem.splitScalar(u8, list.stdout, '\n');
    while (lines.next()) |pid| {
        const trimmed = std.mem.trim(u8, pid, " \r\n");
        if (trimmed.len == 0) continue;
        _ = std.fmt.parseInt(u32, trimmed, 10) catch continue;
        if (!isServerProcess(allocator, trimmed)) continue;
        if (force) {
            _ = std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "kill", "-9", trimmed } }) catch {};
        } else {
            _ = std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "kill", trimmed } }) catch {};
        }
    }
}

fn readPid(allocator: std.mem.Allocator, path: []const u8) ?i32 {
    const file = std.fs.cwd().openFile(path, .{}) catch return null;
    defer file.close();
    const buffer = file.readToEndAlloc(allocator, 32) catch return null;
    return std.fmt.parseInt(i32, std.mem.trim(u8, buffer, " \r\n"), 10) catch null;
}

fn pidAlive(pid: i32) bool {
    std.posix.kill(pid, 0) catch |err| {
        return switch (err) {
            error.ProcessNotFound => false,
            else => true,
        };
    };
    return true;
}

const ServeOutcome = enum { foreground, up, booted };

fn spawnServer(allocator: std.mem.Allocator, opts: agent.Options, server: agent.Server) !i32 {
    const executable = try std.fs.selfExePathAlloc(allocator);
    const log_path = try serverStatePath(allocator, "serve.log");
    defer allocator.free(log_path);
    var argv = std.ArrayListUnmanaged([]const u8){};
    try argv.appendSlice(allocator, &.{ "/bin/sh", "-c", "exec \"$@\" >> \"$TIN_SERVE_LOG\" 2>&1", "tin" });
    try argv.appendSlice(allocator, &.{ executable, "agent", "serve", "--foreground" });
    if (opts.server_explicit) try argv.appendSlice(allocator, &.{ "--server", opts.server });
    if (opts.directory) |directory| try argv.appendSlice(allocator, &.{ "--directory", directory });
    var environment = try std.process.getEnvMap(allocator);
    defer environment.deinit();
    try environment.put("TIN_SERVE_LOG", log_path);
    var child = std.process.Child.init(argv.items, allocator);
    if (server.directory.len > 0) child.cwd = server.directory;
    child.env_map = &environment;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Ignore;
    child.stderr_behavior = .Ignore;
    try child.spawn();
    return child.id;
}

fn backgroundServe(allocator: std.mem.Allocator, opts: agent.Options, server: agent.Server, report: bool) !ServeOutcome {
    if (opts.foreground or !isLocalHttp(server)) return .foreground;
    if (waitForServer(allocator, server.url)) return .up;
    if (report) output.note("starting server {s} at {s}...", .{ server.name, server.url });
    const pid_path = try serverStatePath(allocator, "serve.pid");
    for (0..2) |_| {
        const file = std.fs.cwd().createFile(pid_path, .{ .read = true, .exclusive = true }) catch |err| {
            if (err != error.PathAlreadyExists) return err;
            if (readPid(allocator, pid_path)) |existing| {
                if (pidAlive(existing)) {
                    if (report) output.note("another process is starting server {s}; waiting...", .{server.name});
                    _ = waitForServer(allocator, server.url);
                    return .up;
                }
            }
            if (waitForServer(allocator, server.url)) return .up;
            std.fs.cwd().deleteFile(pid_path) catch {};
            continue;
        };
        defer file.close();
        reapListeners(allocator, server.url);
        const pid = try spawnServer(allocator, opts, server);
        file.writeAll(try std.fmt.allocPrint(allocator, "{d}\n", .{pid})) catch {};
        if (waitForServer(allocator, server.url)) return .booted;
        if (report) {
            const log_path = serverStatePath(allocator, "serve.log") catch null;
            if (log_path) |path| {
                output.note("server {s} started but is not responding; logs at {s}", .{ server.name, path });
            } else {
                output.note("server {s} started but is not responding", .{server.name});
            }
        }
        std.fs.cwd().deleteFile(pid_path) catch {};
        return .foreground;
    }
    return .up;
}

fn ensureServer(allocator: std.mem.Allocator, opts: agent.Options, server: agent.Server) void {
    if (std.posix.getenv("TIN_AUTO_SERVER")) |flag| {
        if (std.mem.eql(u8, flag, "0")) return;
    }
    const outcome = backgroundServe(allocator, opts, server, true) catch return;
    if (outcome == .booted) {
        const log_path = serverStatePath(allocator, "serve.log") catch null;
        if (log_path) |path| {
            output.note("server {s} started in the background; logs at {s}", .{ server.name, path });
        } else {
            output.note("server {s} started in the background", .{server.name});
        }
    }
}

fn stopServer(allocator: std.mem.Allocator, server: agent.Server) void {
    const pid_path = serverStatePath(allocator, "serve.pid") catch {
        output.plain("server {s} is not running", .{server.name});
        return;
    };
    reapListeners(allocator, server.url);
    if (readPid(allocator, pid_path)) |pid| {
        if (std.fmt.allocPrint(allocator, "{d}", .{pid})) |pid_str| {
            _ = std.process.Child.run(.{ .allocator = allocator, .argv = &.{ "kill", pid_str } }) catch {};
        } else |_| {}
    }
    std.fs.cwd().deleteFile(pid_path) catch {};
    if (waitForShutdown(allocator, server.url)) {
        output.plain("server {s} stopped", .{server.name});
        return;
    }
    if (std.Uri.parse(server.url)) |uri| {
        if (uri.port) |port| killListenersOnPort(allocator, port, true);
    } else |_| {}
    if (waitForShutdown(allocator, server.url)) {
        output.plain("server {s} stopped", .{server.name});
        return;
    }
    output.plain("server {s} did not stop cleanly; run lsof -iTCP:{d}", .{ server.name, (std.Uri.parse(server.url) catch return).port orelse 0 });
}
