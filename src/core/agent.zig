const std = @import("std");
const yaml = @import("yaml");
const Environment = @import("environment.zig");
const envfile = @import("../lib/envfile.zig");

const Allocator = std.mem.Allocator;
const Value = std.json.Value;

pub const Server = struct {
    name: []const u8 = "local",
    label: ?[]const u8 = null,
    url: []const u8 = "http://127.0.0.1:4096",
    directory: []const u8,
    agent: []const u8 = "tin-coordinator",
    password_env: []const u8 = "OPENCODE_SERVER_PASSWORD",
    username_env: []const u8 = "OPENCODE_SERVER_USERNAME",
    group: ?[]const u8 = null,
    coordinator: ?[]const u8 = null,
    pane: ?[]const u8 = null,
    session: ?[]const u8 = null,
};

pub const Options = struct {
    action: []const u8,
    server: []const u8 = "local",
    server_explicit: bool = false,
    directory: ?[]const u8 = null,
    argument: ?[]const u8 = null,
    reply: ?[]const u8 = null,
    tree: bool = false,
    new: bool = false,
    group: ?[]const u8 = null,
    foreground: bool = false,
    stop: bool = false,
    teardown: ?[]const u8 = null,

    pub fn parse(args: []const []const u8) !Options {
        if (args.len == 0) return error.Usage;
        var opts = Options{ .action = args[0] };
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (std.mem.eql(u8, arg, "--tree")) {
                opts.tree = true;
            } else if (std.mem.eql(u8, arg, "--new")) {
                opts.new = true;
            } else if (std.mem.eql(u8, arg, "--foreground")) {
                opts.foreground = true;
            } else if (std.mem.eql(u8, arg, "--stop")) {
                opts.stop = true;
            } else if (std.mem.eql(u8, arg, "--server") or std.mem.eql(u8, arg, "--directory") or std.mem.eql(u8, arg, "--group") or std.mem.eql(u8, arg, "--teardown")) {
                i += 1;
                if (i == args.len) return error.Usage;
                if (std.mem.eql(u8, arg, "--server")) {
                    opts.server = args[i];
                    opts.server_explicit = true;
                } else if (std.mem.eql(u8, arg, "--group")) opts.group = args[i] else if (std.mem.eql(u8, arg, "--teardown")) {
                    opts.teardown = args[i];
                } else opts.directory = args[i];
            } else if (std.mem.startsWith(u8, arg, "--")) {
                return error.Usage;
            } else if (opts.argument == null) {
                opts.argument = arg;
            } else if (opts.reply == null) {
                opts.reply = arg;
            } else return error.Usage;
        }
        if (opts.tree and !std.mem.eql(u8, opts.action, "stop")) return error.Usage;
        if (opts.new and !std.mem.eql(u8, opts.action, "open") and !std.mem.eql(u8, opts.action, "worktree")) return error.Usage;
        if (opts.directory) |directory| {
            if (!std.fs.path.isAbsolute(directory)) return error.DirectoryMustBeAbsolute;
        }
        const no_args = std.mem.eql(u8, opts.action, "servers") or std.mem.eql(u8, opts.action, "snapshot") or std.mem.eql(u8, opts.action, "groups") or std.mem.eql(u8, opts.action, "serve") or std.mem.eql(u8, opts.action, "group");
        const one_arg = for ([_][]const u8{ "create", "prompt", "inspect", "diff", "stop", "answer", "reject-question", "attach", "open", "worktree" }) |action| {
            if (std.mem.eql(u8, opts.action, action)) break true;
        } else false;
        const permission = std.mem.eql(u8, opts.action, "permission");
        if ((!no_args and !one_arg and !permission) or
            (no_args and opts.argument != null) or
            ((one_arg or permission) and opts.argument == null) or
            (!permission and opts.reply != null) or (permission and opts.reply == null)) return error.Usage;
        if (permission) {
            const reply = opts.reply.?;
            if (!std.mem.eql(u8, reply, "once") and !std.mem.eql(u8, reply, "always") and !std.mem.eql(u8, reply, "reject")) return error.Usage;
        }
        if (opts.argument) |argument| {
            if (argument.len == 0) return error.Usage;
            if (!std.mem.eql(u8, opts.action, "create") and !std.mem.eql(u8, opts.action, "open") and !std.mem.eql(u8, opts.action, "worktree")) {
                const question = std.mem.eql(u8, opts.action, "answer") or std.mem.eql(u8, opts.action, "reject-question");
                const prefix: []const u8 = if (permission) "per" else if (question) "que" else "ses";
                if (!std.mem.startsWith(u8, argument, prefix)) return error.InvalidID;
                for (argument) |char| {
                    if (!std.ascii.isAlphanumeric(char) and char != '_') return error.InvalidID;
                }
            }
        }
        return opts;
    }
};

fn field(node: yaml.Value, key: []const u8) !?[]const u8 {
    const value = node.get(key) orelse return null;
    return value.getString() orelse error.InvalidAgentConfig;
}

pub fn validateServer(server: Server) !void {
    if (server.name.len == 0 or !std.fs.path.isAbsolute(server.directory)) return error.InvalidAgentConfig;
    const uri = std.Uri.parse(server.url) catch return error.InvalidServerURL;
    if ((!std.mem.eql(u8, uri.scheme, "http") and !std.mem.eql(u8, uri.scheme, "https")) or
        uri.host == null or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null or
        uri.path.percent_encoded.len != 0) return error.InvalidServerURL;
    for (server.url) |char| {
        if (std.ascii.isWhitespace(char) or char < 32) return error.InvalidServerURL;
    }
}

pub fn servers(allocator: Allocator, env: Environment, directory: ?[]const u8) ![]Server {
    const cwd = directory orelse try std.process.getCwdAlloc(allocator);
    const node = env.config.getMapping("agents") orelse {
        const result = try allocator.alloc(Server, 1);
        result[0] = .{ .directory = cwd };
        return result;
    };
    const items = node.getSequence() orelse return error.InvalidAgentConfig;
    if (items.len == 0) return error.NoAgentServers;
    const result = try allocator.alloc(Server, items.len);
    for (items, 0..) |item, i| {
        result[i] = .{
            .name = (try field(item, "name")) orelse return error.InvalidAgentConfig,
            .url = (try field(item, "url")) orelse return error.InvalidAgentConfig,
            .directory = (try field(item, "directory")) orelse cwd,
            .agent = (try field(item, "agent")) orelse "tin-coordinator",
            .password_env = (try field(item, "password_env")) orelse "OPENCODE_SERVER_PASSWORD",
            .username_env = (try field(item, "username_env")) orelse "OPENCODE_SERVER_USERNAME",
        };
        try validateServer(result[i]);
        for (result[0..i]) |previous| {
            if (std.mem.eql(u8, previous.name, result[i].name)) return error.DuplicateServerName;
        }
    }
    return result;
}

pub fn parseJson(allocator: Allocator, text: []const u8) !Value {
    return (try std.json.parseFromSlice(Value, allocator, text, .{ .allocate = .alloc_always })).value;
}

pub fn json(allocator: Allocator, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(allocator, value, .{});
}

pub fn encode(allocator: Allocator, text: []const u8) ![]const u8 {
    var result = std.ArrayListUnmanaged(u8){};
    for (text) |char| {
        if (std.ascii.isAlphanumeric(char) or std.mem.indexOfScalar(u8, "-_.~", char) != null) {
            try result.append(allocator, char);
        } else {
            const escaped = try std.fmt.allocPrint(allocator, "%{X:0>2}", .{char});
            try result.appendSlice(allocator, escaped);
        }
    }
    return result.toOwnedSlice(allocator);
}

pub fn curlQuote(allocator: Allocator, text: []const u8) ![]const u8 {
    var result = std.ArrayListUnmanaged(u8){};
    try result.append(allocator, '"');
    for (text) |char| switch (char) {
        '\\' => try result.appendSlice(allocator, "\\\\"),
        '"' => try result.appendSlice(allocator, "\\\""),
        '\n' => try result.appendSlice(allocator, "\\n"),
        '\r' => try result.appendSlice(allocator, "\\r"),
        '\t' => try result.appendSlice(allocator, "\\t"),
        else => try result.append(allocator, char),
    };
    try result.append(allocator, '"');
    return result.toOwnedSlice(allocator);
}

pub const Api = struct {
    allocator: Allocator,
    server: Server,
    credentials: []const envfile.Entry = &.{},
    transport: *const fn (*Api, []const u8, []const u8, ?[]const u8, []const u8) anyerror!Value = http,
    scope: ?[]const u8 = null,
    guard: ?*const fn (*Api) anyerror!void = null,

    pub fn request(self: *Api, method: []const u8, path: []const u8, body: ?[]const u8, directory: ?[]const u8) !Value {
        if (self.guard) |guard| try guard(self);
        return self.transport(self, method, path, body, directory orelse self.server.directory);
    }

    pub fn session(self: *Api, id: []const u8) !Value {
        const target = try self.request("GET", try sessionPath(self.allocator, id, ""), null, null);
        const root = self.scope orelse return target;
        if (!std.mem.eql(u8, try getString(target, "directory"), self.server.directory)) return error.OutsideGroup;
        if (std.mem.eql(u8, id, root)) return target;
        const tree = try groupTree(self, root);
        if (tree != .array) return error.OutsideGroup;
        for (tree.array.items) |member| {
            if (std.mem.eql(u8, try getString(member, "id"), id)) return target;
        }
        return error.OutsideGroup;
    }

    fn authorizeRequest(self: *Api, path: []const u8, id: []const u8) !void {
        if (self.scope == null) return;
        const requests = try self.request("GET", path, null, null);
        if (requests != .array) return error.InvalidResponse;
        for (requests.array.items) |item| {
            if (std.mem.eql(u8, try getString(item, "id"), id)) {
                _ = try self.session(try getString(item, "sessionID"));
                return;
            }
        }
        return error.RequestNotInGroup;
    }

    fn secret(self: *Api, key: []const u8) ?[]const u8 {
        return envfile.find(self.credentials, key) orelse std.posix.getenv(key);
    }

    fn http(self: *Api, method: []const u8, path: []const u8, body: ?[]const u8, directory: []const u8) !Value {
        const allocator = self.allocator;
        const url = try std.fmt.allocPrint(allocator, "{s}{s}{s}directory={s}", .{
            self.server.url, path, if (std.mem.indexOfScalar(u8, path, '?') == null) "?" else "&", try encode(allocator, directory),
        });
        var config = std.ArrayListUnmanaged(u8){};
        try config.appendSlice(allocator, "header = \"Content-Type: application/json\"\n");
        if (self.secret(self.server.password_env)) |password| {
            if (password.len > 0) {
                const pair = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ self.secret(self.server.username_env) orelse "opencode", password });
                const base64 = std.base64.standard.Encoder;
                const encoded = try allocator.alloc(u8, base64.calcSize(pair.len));
                _ = base64.encode(encoded, pair);
                const header = try curlQuote(allocator, try std.fmt.allocPrint(allocator, "Authorization: Basic {s}", .{encoded}));
                try config.appendSlice(allocator, try std.fmt.allocPrint(allocator, "header = {s}\n", .{header}));
            }
        }
        if (body) |data| try config.appendSlice(allocator, try std.fmt.allocPrint(allocator, "data-raw = {s}\n", .{try curlQuote(allocator, data)}));
        var child = std.process.Child.init(&.{
            "curl",      "--silent", "--globoff", "--noproxy", "localhost,127.0.0.1,::1", "--connect-timeout", "2",     "--max-time", "8",
            "--request", method,     "--config",  "-",         "--write-out",             "\n%{http_code}",    "--url", url,
        }, allocator);
        child.stdin_behavior = .Pipe;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Ignore;
        try child.spawn();
        var running = true;
        errdefer {
            if (running) {
                _ = child.kill() catch {};
            }
        }
        try child.stdin.?.writeAll(config.items);
        child.stdin.?.close();
        child.stdin = null;
        const response = try child.stdout.?.readToEndAlloc(allocator, 32 * 1024 * 1024);
        const term = try child.wait();
        running = false;
        if (term != .Exited or term.Exited != 0) return error.ConnectionFailed;
        const last = std.mem.lastIndexOfScalar(u8, response, '\n') orelse return error.InvalidResponse;
        const code = std.fmt.parseInt(u16, response[last + 1 ..], 10) catch return error.InvalidResponse;
        if (code == 401 or code == 403) return error.AuthenticationFailed;
        if (code == 404) return error.NotFound;
        if (code == 409) return error.SessionBusy;
        if (code < 200 or code >= 300) return error.AgentRequestFailed;
        if (last == 0) return .{ .bool = true };
        return parseJson(allocator, response[0..last]) catch return error.InvalidResponse;
    }
};

pub const coordinator =
    \\You are the user's coordinating agent for this project, supervised through Tin.
    \\Own the overall goal and maintain a concise task list. Delegate bounded work to native subagents with the task tool when useful.
    \\Give each worker a clear scope, expected result, and verification step. Run independent work concurrently when supported.
    \\Avoid assigning overlapping file edits to concurrent workers. Use separate worktrees for independent editing tasks when available.
    \\Review worker results, integrate the work, and report changes, verification, and blockers.
    \\Keep progress and decisions visible. Follow the user's steering. Only claim workers, isolation, tests, or remote execution actually observed.
;

fn sessionPath(allocator: Allocator, id: []const u8, suffix: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "/session/{s}{s}", .{ try encode(allocator, id), suffix });
}

fn getString(value: Value, key: []const u8) ![]const u8 {
    if (value != .object) return error.InvalidResponse;
    const item = value.object.get(key) orelse return error.InvalidResponse;
    if (item != .string) return error.InvalidResponse;
    return item.string;
}

fn groupTree(api: *Api, root: []const u8) !Value {
    const allocator = api.allocator;
    var sessions = std.array_list.Managed(Value).init(allocator);
    var pending = std.ArrayListUnmanaged(Value){};
    try pending.append(allocator, try api.request("GET", try sessionPath(allocator, root, ""), null, null));
    var seen = std.StringHashMapUnmanaged(void){};
    while (pending.items.len > 0 and sessions.items.len < 200) {
        const session = pending.orderedRemove(0);
        try sessions.append(session);
        const id = try getString(session, "id");
        const entry = try seen.getOrPut(allocator, id);
        if (entry.found_existing) continue;
        const children = try api.request("GET", try sessionPath(allocator, id, "/children"), null, null);
        if (children != .array) return error.InvalidResponse;
        for (children.array.items) |child| {
            const child_id = try getString(child, "id");
            if (seen.contains(child_id)) continue;
            if (!std.mem.eql(u8, try getString(child, "directory"), api.server.directory)) continue;
            if (sessions.items.len + pending.items.len >= 200) break;
            try pending.append(allocator, child);
        }
    }
    return .{ .array = sessions };
}

fn snapshot(api: *Api) !Value {
    const allocator = api.allocator;
    const sessions = if (api.scope) |root| try groupTree(api, root) else try api.request("GET", "/session?limit=200&roots=false&scope=project", null, null);
    if (sessions != .array) return error.InvalidResponse;
    var selected = std.StringHashMapUnmanaged(void){};
    for (sessions.array.items) |session| {
        if (std.mem.eql(u8, try getString(session, "directory"), api.server.directory)) {
            try selected.put(allocator, try getString(session, "id"), {});
        }
    }
    var added = true;
    while (added) {
        added = false;
        for (sessions.array.items) |session| {
            const id = try getString(session, "id");
            const parent = session.object.get("parentID") orelse continue;
            if (parent == .string and selected.contains(parent.string) and !selected.contains(id)) {
                try selected.put(allocator, id, {});
                added = true;
            }
        }
    }
    var filtered = std.array_list.Managed(Value).init(allocator);
    var directories = std.StringHashMapUnmanaged(void){};
    try directories.put(allocator, api.server.directory, {});
    for (sessions.array.items) |session| {
        if (selected.contains(try getString(session, "id"))) {
            try filtered.append(session);
            try directories.put(allocator, try getString(session, "directory"), {});
        }
    }
    var statuses = std.json.ObjectMap.init(allocator);
    var permissions = std.json.ObjectMap.init(allocator);
    var questions = std.json.ObjectMap.init(allocator);
    var dirs = directories.keyIterator();
    while (dirs.next()) |directory| {
        const status = try api.request("GET", "/session/status", null, directory.*);
        if (status != .object) return error.InvalidResponse;
        var entries = status.object.iterator();
        while (entries.next()) |entry| {
            if (selected.contains(entry.key_ptr.*)) try statuses.put(entry.key_ptr.*, entry.value_ptr.*);
        }
        inline for (.{ .{ "/permission", &permissions }, .{ "/question", &questions } }) |pair| {
            const requests = try api.request("GET", pair[0], null, directory.*);
            if (requests != .array) return error.InvalidResponse;
            for (requests.array.items) |request| {
                if (selected.contains(try getString(request, "sessionID"))) try pair[1].put(try getString(request, "id"), request);
            }
        }
    }
    var result = std.json.ObjectMap.init(allocator);
    try result.put("sessions", .{ .array = filtered });
    try result.put("status", .{ .object = statuses });
    inline for (.{ .{ "permissions", permissions }, .{ "questions", questions } }) |pair| {
        var list = std.array_list.Managed(Value).init(allocator);
        try list.appendSlice(pair[1].values());
        try result.put(pair[0], .{ .array = list });
    }
    return .{ .object = result };
}

pub fn run(api: *Api, opts: Options, input: ?[]const u8) !Value {
    const allocator = api.allocator;
    const action = opts.action;
    if (std.mem.eql(u8, action, "snapshot")) return snapshot(api);
    const id = opts.argument orelse return error.Usage;
    if (std.mem.eql(u8, action, "create")) {
        const title = try std.fmt.allocPrint(allocator, "Control: {s}", .{id});
        if (api.scope) |root| {
            _ = try api.session(root);
            return api.request("POST", "/session", try json(allocator, .{ .title = title, .agent = api.server.agent, .parentID = root }), null);
        }
        return api.request("POST", "/session", try json(allocator, .{ .title = title, .agent = api.server.agent }), null);
    }
    if (std.mem.eql(u8, action, "permission")) {
        try api.authorizeRequest("/permission", id);
        return api.request("POST", try std.fmt.allocPrint(allocator, "/permission/{s}/reply", .{id}), try json(allocator, .{ .reply = opts.reply.? }), null);
    }
    if (std.mem.eql(u8, action, "answer")) {
        const answers = try parseJson(allocator, input orelse return error.InputRequired);
        if (answers != .array) return error.InvalidAnswers;
        for (answers.array.items) |answer| {
            if (answer != .array) return error.InvalidAnswers;
            for (answer.array.items) |label| {
                if (label != .string) return error.InvalidAnswers;
            }
        }
        try api.authorizeRequest("/question", id);
        return api.request("POST", try std.fmt.allocPrint(allocator, "/question/{s}/reply", .{id}), try json(allocator, .{ .answers = answers }), null);
    }
    if (std.mem.eql(u8, action, "reject-question")) {
        try api.authorizeRequest("/question", id);
        return api.request("POST", try std.fmt.allocPrint(allocator, "/question/{s}/reject", .{id}), null, null);
    }
    const session = try api.session(id);
    const directory = try getString(session, "directory");
    if (std.mem.eql(u8, action, "prompt")) {
        const text = input orelse return error.InputRequired;
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) return error.InputRequired;
        const is_coordinator = std.mem.startsWith(u8, try getString(session, "title"), "Control: ");
        const parts = .{.{ .type = "text", .text = text }};
        const body = if (is_coordinator)
            try json(allocator, .{ .parts = parts, .system = coordinator, .agent = api.server.agent })
        else
            try json(allocator, .{ .parts = parts });
        return api.request("POST", try sessionPath(allocator, id, "/prompt_async"), body, directory);
    }
    if (std.mem.eql(u8, action, "inspect")) {
        var result = std.json.ObjectMap.init(allocator);
        try result.put("session", session);
        try result.put("messages", try api.request("GET", try sessionPath(allocator, id, "/message?limit=30"), null, directory));
        try result.put("todos", try api.request("GET", try sessionPath(allocator, id, "/todo"), null, directory));
        return .{ .object = result };
    }
    if (std.mem.eql(u8, action, "diff")) return api.request("GET", try sessionPath(allocator, id, "/diff"), null, directory);
    if (std.mem.eql(u8, action, "stop")) {
        var stop = Stop{ .api = api, .tree = opts.tree };
        try stop.visit(session);
        return parseJson(allocator, try json(allocator, .{ .stopped = stop.stopped.items, .errors = stop.errors.items }));
    }
    return error.Usage;
}

pub fn attach(api: *Api, id: []const u8) !void {
    const session = try api.session(id);
    const directory = try getString(session, "directory");
    var environment = try std.process.getEnvMap(api.allocator);
    defer environment.deinit();
    try environment.put("OPENCODE_SERVER_PASSWORD", api.secret(api.server.password_env) orelse "");
    try environment.put("OPENCODE_SERVER_USERNAME", api.secret(api.server.username_env) orelse "opencode");
    var child = std.process.Child.init(&.{ "opencode", "attach", api.server.url, "--dir", directory, "--session", id }, api.allocator);
    child.env_map = &environment;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = try child.spawnAndWait();
    if (term != .Exited or term.Exited != 0) return error.AttachFailed;
}

pub fn serve(api: *Api) !void {
    const uri = try std.Uri.parse(api.server.url);
    const host = uri.host.?.percent_encoded;
    if (!std.mem.eql(u8, uri.scheme, "http") or (!std.mem.eql(u8, host, "127.0.0.1") and !std.mem.eql(u8, host, "localhost"))) return error.ServeRequiresLocalHTTP;
    var environment = try std.process.getEnvMap(api.allocator);
    defer environment.deinit();
    for (api.credentials) |credential| try environment.put(credential.key, credential.value);
    try environment.put("OPENCODE_SERVER_PASSWORD", api.secret(api.server.password_env) orelse "");
    try environment.put("OPENCODE_SERVER_USERNAME", api.secret(api.server.username_env) orelse "opencode");
    const port = try std.fmt.allocPrint(api.allocator, "{d}", .{uri.port orelse 80});
    var child = std.process.Child.init(&.{ "opencode", "serve", "--hostname", "127.0.0.1", "--port", port }, api.allocator);
    child.env_map = &environment;
    child.cwd = api.server.directory;
    child.stdin_behavior = .Inherit;
    child.stdout_behavior = .Inherit;
    child.stderr_behavior = .Inherit;
    const term = try child.spawnAndWait();
    if (term != .Exited or term.Exited != 0) return error.ServerExited;
}

const Stop = struct {
    api: *Api,
    tree: bool,
    seen: std.StringHashMapUnmanaged(void) = .{},
    stopped: std.ArrayListUnmanaged([]const u8) = .{},
    errors: std.ArrayListUnmanaged([]const u8) = .{},

    fn failure(self: *Stop, id: []const u8, err: anyerror) !void {
        try self.errors.append(self.api.allocator, try std.fmt.allocPrint(self.api.allocator, "{s}: {s}", .{ id, @errorName(err) }));
    }

    fn visit(self: *Stop, session: Value) anyerror!void {
        const allocator = self.api.allocator;
        const id = try getString(session, "id");
        const directory = try getString(session, "directory");
        if (self.api.scope != null) _ = try self.api.session(id);
        const entry = try self.seen.getOrPut(allocator, id);
        if (entry.found_existing) return;
        if (self.api.request("POST", try sessionPath(allocator, id, "/abort"), null, directory)) |result| {
            if (result == .bool and result.bool) try self.stopped.append(allocator, id) else try self.failure(id, error.InvalidResponse);
        } else |err| try self.failure(id, err);
        if (!self.tree) return;
        const children = self.api.request("GET", try sessionPath(allocator, id, "/children"), null, directory) catch |err| {
            try self.failure(id, err);
            return;
        };
        if (children != .array) return self.failure(id, error.InvalidResponse);
        for (children.array.items) |child| self.visit(child) catch |err| {
            try self.failure(id, err);
        };
    }
};
