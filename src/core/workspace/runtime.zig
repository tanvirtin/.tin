const std = @import("std");
const yaml = @import("yaml");
const fs = @import("../../lib/fs.zig");
const process = @import("../../lib/process.zig");
const output = @import("../../lib/output.zig");
const Paths = @import("../environment/paths.zig");
const registry = @import("registry.zig");
const Method = @import("../method.zig");
const tmux = @import("../mux.zig");

pub const RuntimeError = error{
    NotARegisteredWorkspace,
    UnknownMethod,
    UnsetParam,
    UnknownDep,
    DepCycle,
    TmuxUnavailable,
    DockerUnavailable,
    NoMise,
    NoHealthcheck,
    ParseFailed,
    CommandFailed,
};

// ────────────────────────────────────────────────────────────
// Workspace document model
// ────────────────────────────────────────────────────────────

pub const Pair = struct {
    key: []const u8,
    value: []const u8,
};

pub const Healthcheck = struct {
    command: []const u8 = "",
    interval: []const u8 = "5s",
    retries: usize = 10,
};

pub const Dep = struct {
    target: []const u8,
    condition: []const u8 = "started",
};

pub const Component = struct {
    key: []const u8,
    method_id: []const u8,
    project: ?[]const u8 = null,
    params: []Pair = &.{},
    env: []Pair = &.{},
    scale: usize = 1,
    group: ?[]const u8 = null,
    auto: bool = false,
    healthcheck: ?Healthcheck = null,
    depends: []Dep = &.{},
};

pub const Workspace = struct {
    name: []const u8,
    path: []const u8,
    projects: []Pair = &.{},
    env: []Pair = &.{},
    tools: []Pair = &.{},
    components: []Component = &.{},

    pub fn findComponent(self: *const Workspace, key: []const u8) ?usize {
        for (self.components, 0..) |c, i| {
            if (std.mem.eql(u8, c.key, key)) return i;
        }
        return null;
    }
};

pub fn parseWorkspace(allocator: std.mem.Allocator, content: []const u8) !Workspace {
    var doc = yaml.parse(allocator, content) catch return error.ParseFailed;
    defer doc.deinit();
    const root = doc.value;

    const name = (root.get("name") orelse return error.ParseFailed).getString() orelse return error.ParseFailed;
    const path = if (root.get("path")) |pv| pv.getString() else null;
    if (path == null and root.get("projects") == null) return error.ParseFailed;

    var ws = Workspace{
        .name = try allocator.dupe(u8, name),
        .path = if (path) |p| try allocator.dupe(u8, p) else "",
    };

    if (root.get("env")) |v| ws.env = try collectStringMap(allocator, v);
    if (root.get("tools")) |v| ws.tools = try collectStringMap(allocator, v);

    if (root.get("projects")) |projs_v| ws.projects = try collectStringMap(allocator, projs_v);

    if (root.get("components")) |comps_v| {
        const node = comps_v.tree.nodes.items[comps_v.idx];
        if (node.tag == .mapping) {
            var comps = std.ArrayListUnmanaged(Component){};
            var child = node.first_child;
            while (child != 0) {
                const k_node = comps_v.tree.nodes.items[child];
                const key = k_node.computed_value orelse comps_v.tree.source[k_node.start..k_node.end];
                const val_idx = k_node.next_sibling;
                if (val_idx == 0) break;
                const comp_v = yaml.Value{ .tree = comps_v.tree, .idx = val_idx, .arena = comps_v.arena };
                try comps.append(allocator, try parseComponent(allocator, key, comp_v));
                child = comps_v.tree.nodes.items[val_idx].next_sibling;
            }
            ws.components = try comps.toOwnedSlice(allocator);
        }
    }

    if (root.get("topology")) |topo_v| {
        const node = topo_v.tree.nodes.items[topo_v.idx];
        if (node.tag == .mapping) {
            var child = node.first_child;
            while (child != 0) {
                const k_node = topo_v.tree.nodes.items[child];
                const key = k_node.computed_value orelse topo_v.tree.source[k_node.start..k_node.end];
                const val_idx = k_node.next_sibling;
                if (val_idx == 0) break;
                const dep_map = yaml.Value{ .tree = topo_v.tree, .idx = val_idx, .arena = topo_v.arena };
                if (dep_map.get("depends_on")) |dep_on| {
                    try attachDeps(allocator, &ws, key, dep_on);
                }
                child = topo_v.tree.nodes.items[val_idx].next_sibling;
            }
        }
    }

    return ws;
}

fn attachDeps(allocator: std.mem.Allocator, ws: *Workspace, key: []const u8, dep_on: yaml.Value) !void {
    const node = dep_on.tree.nodes.items[dep_on.idx];
    if (node.tag != .mapping) return;
    const ci = ws.findComponent(key) orelse return;

    var deps = std.ArrayListUnmanaged(Dep){};
    var child = node.first_child;
    while (child != 0) {
        const dk = dep_on.tree.nodes.items[child];
        const target = dk.computed_value orelse dep_on.tree.source[dk.start..dk.end];
        const dval_idx = dk.next_sibling;
        var condition: []const u8 = "started";
        if (dval_idx != 0) {
            const dval = yaml.Value{ .tree = dep_on.tree, .idx = dval_idx, .arena = dep_on.arena };
            if (dval.get("condition")) |cv| {
                if (cv.getString()) |cs| condition = cs;
            }
        }
        try deps.append(allocator, .{
            .target = try allocator.dupe(u8, target),
            .condition = try allocator.dupe(u8, condition),
        });
        if (dval_idx == 0) break;
        child = dep_on.tree.nodes.items[dval_idx].next_sibling;
    }
    ws.components[ci].depends = try deps.toOwnedSlice(allocator);
}

fn parseComponent(allocator: std.mem.Allocator, key: []const u8, v: yaml.Value) !Component {
    const method = (v.get("method") orelse return error.ParseFailed).getString() orelse return error.ParseFailed;
    var comp = Component{
        .key = try allocator.dupe(u8, key),
        .method_id = try allocator.dupe(u8, method),
    };
    if (v.get("project")) |proj| {
        if (proj.getString()) |s| comp.project = try allocator.dupe(u8, s);
    }
    if (v.get("params")) |p| comp.params = try collectStringMap(allocator, p);
    if (v.get("env")) |e| comp.env = try collectStringMap(allocator, e);
    if (v.get("group")) |g| {
        if (g.getString()) |s| comp.group = try allocator.dupe(u8, s);
    }
    if (v.get("scale")) |sc| {
        if (sc.getString()) |s| comp.scale = std.fmt.parseInt(usize, s, 10) catch 1;
    }
    if (v.get("auto")) |a| {
        if (a.getString()) |s| comp.auto = std.mem.eql(u8, s, "true");
    }
    if (v.get("healthcheck")) |hc| comp.healthcheck = try parseHealthcheck(allocator, hc);
    return comp;
}

fn parseHealthcheck(allocator: std.mem.Allocator, v: yaml.Value) !Healthcheck {
    var hc = Healthcheck{};
    if (v.get("command")) |c| {
        if (c.getString()) |s| hc.command = try allocator.dupe(u8, s);
    }
    if (v.get("interval")) |c| {
        if (c.getString()) |s| hc.interval = try allocator.dupe(u8, s);
    }
    if (v.get("retries")) |c| {
        if (c.getString()) |s| hc.retries = std.fmt.parseInt(usize, s, 10) catch 10;
    }
    return hc;
}

fn collectStringMap(allocator: std.mem.Allocator, v: yaml.Value) ![]Pair {
    const node = v.tree.nodes.items[v.idx];
    var out = std.ArrayListUnmanaged(Pair){};
    if (node.tag == .mapping) {
        var child = node.first_child;
        while (child != 0) {
            const k_node = v.tree.nodes.items[child];
            const k = k_node.computed_value orelse v.tree.source[k_node.start..k_node.end];
            const val_idx = k_node.next_sibling;
            if (val_idx != 0) {
                const val_v = yaml.Value{ .tree = v.tree, .idx = val_idx, .arena = v.arena };
                if (val_v.getString()) |s| {
                    try out.append(allocator, .{
                        .key = try allocator.dupe(u8, k),
                        .value = try allocator.dupe(u8, s),
                    });
                }
            }
            if (val_idx == 0) break;
            child = v.tree.nodes.items[val_idx].next_sibling;
        }
    }
    return out.toOwnedSlice(allocator);
}

// ────────────────────────────────────────────────────────────
// Topological ordering
// ────────────────────────────────────────────────────────────

/// Kahn's algorithm over the workspace dependency DAG. When `start` is set,
/// the subgraph of that component plus its transitive dependencies is ordered.
/// `error.UnknownDep` when a dependency references a component not present;
/// `error.DepCycle` when the DAG has a cycle.
pub fn topoSort(allocator: std.mem.Allocator, ws: *const Workspace, start: ?[]const u8) ![]const []const u8 {
    const n = ws.components.len;
    if (n == 0) return &[_][]const u8{};

    const selected = try allocator.alloc(bool, n);
    defer allocator.free(selected);
    @memset(selected, false);

    if (start) |s| {
        const si = ws.findComponent(s) orelse return error.UnknownDep;
        selected[si] = true;
        var changed = true;
        while (changed) {
            changed = false;
            for (ws.components, 0..) |c, i| {
                if (!selected[i]) continue;
                for (c.depends) |d| {
                    if (ws.findComponent(d.target)) |j| {
                        if (!selected[j]) {
                            selected[j] = true;
                            changed = true;
                        }
                    }
                }
            }
        }
    } else {
        @memset(selected, true);
    }

    var selected_count: usize = 0;
    for (selected) |s| {
        if (s) selected_count += 1;
    }

    const indeg = try allocator.alloc(usize, n);
    defer allocator.free(indeg);
    @memset(indeg, 0);

    for (ws.components, 0..) |c, i| {
        if (!selected[i]) continue;
        for (c.depends) |d| {
            const j = ws.findComponent(d.target) orelse return error.UnknownDep;
            if (!selected[j]) return error.UnknownDep;
            indeg[i] += 1;
        }
    }

    var queue = std.ArrayListUnmanaged(usize){};
    for (ws.components, 0..) |_, i| {
        if (selected[i] and indeg[i] == 0) try queue.append(allocator, i);
    }

    var order = std.ArrayListUnmanaged([]const u8){};
    while (queue.items.len > 0) {
        const i = queue.orderedRemove(0);
        try order.append(allocator, ws.components[i].key);
        for (ws.components, 0..) |c, j| {
            if (!selected[j]) continue;
            for (c.depends) |d| {
                if (ws.findComponent(d.target)) |ti| {
                    if (ti == i) {
                        indeg[j] -= 1;
                        if (indeg[j] == 0) try queue.append(allocator, j);
                    }
                }
            }
        }
    }

    if (order.items.len != selected_count) return error.DepCycle;
    return order.toOwnedSlice(allocator);
}

// ────────────────────────────────────────────────────────────
// Templating
// ────────────────────────────────────────────────────────────

const Lookup = struct {
    allocator: std.mem.Allocator,
    params: []const Pair,
    ws_name: []const u8,
    ws_path: []const u8,
    env: []const Pair,

    fn resolve(self: Lookup, key: []const u8) ?[]const u8 {
        if (std.mem.eql(u8, key, "workspace.name")) return self.ws_name;
        if (std.mem.eql(u8, key, "workspace.path")) return self.ws_path;
        if (std.mem.startsWith(u8, key, "env.")) {
            const name = key[4..];
            for (self.env) |p| {
                if (std.mem.eql(u8, p.key, name)) return p.value;
            }
            if (std.posix.getenv(name)) |v| return v;
            return null;
        }
        for (self.params) |p| {
            if (std.mem.eql(u8, p.key, key)) return p.value;
        }
        return null;
    }

    /// Every `{{ key }}` in `template` must resolve, or error.UnsetParam.
    fn ensureAll(self: Lookup, template: []const u8) !void {
        var i: usize = 0;
        while (i < template.len) {
            const open = std.mem.indexOfPos(u8, template, i, "{{") orelse break;
            const close_rel = std.mem.indexOfPos(u8, template, open + 2, "}}") orelse break;
            const close = close_rel + 2;
            const key = std.mem.trim(u8, template[open + 2 .. close - 2], " ");
            if (self.resolve(key) == null) return error.UnsetParam;
            i = close;
        }
    }
};

fn renderTemplate(allocator: std.mem.Allocator, template: []const u8, lookup: Lookup) ![]const u8 {
    var out = std.ArrayListUnmanaged(u8){};
    var i: usize = 0;
    while (i < template.len) {
        const open = std.mem.indexOfPos(u8, template, i, "{{") orelse {
            try out.appendSlice(allocator, template[i..]);
            break;
        };
        try out.appendSlice(allocator, template[i..open]);
        const close_rel = std.mem.indexOfPos(u8, template, open + 2, "}}") orelse {
            try out.appendSlice(allocator, template[open..]);
            break;
        };
        const close = close_rel + 2;
        const key = std.mem.trim(u8, template[open + 2 .. close - 2], " ");
        const val = lookup.resolve(key) orelse {
            try out.appendSlice(allocator, template[open..close]);
            i = close;
            continue;
        };
        try out.appendSlice(allocator, val);
        i = close;
    }
    return out.toOwnedSlice(allocator);
}

// ────────────────────────────────────────────────────────────
// Method resolution
// ────────────────────────────────────────────────────────────

pub const ResolvedMethod = struct {
    runtime: []const u8,
    command: ?[]const u8 = null,
    image: ?[]const u8 = null,
    dir: ?[]const u8 = null,
    tool: ?[]const u8 = null,
    file: ?[]const u8 = null,
    task_name: ?[]const u8 = null,
    ports: []const []const u8 = &.{},
    volumes: []const []const u8 = &.{},
    args: []const []const u8 = &.{},
    healthcheck: ?Healthcheck = null,
};

/// Resolve the effective workspace path for a component, accounting for the
/// optional `project` field that maps to a key in the workspace's `projects`.
fn projectPath(ws: *const Workspace, project_key: ?[]const u8) []const u8 {
    if (project_key) |key| {
        for (ws.projects) |p| {
            if (std.mem.eql(u8, p.key, key)) return p.value;
        }
    }
    return ws.path;
}

/// Merge method `defaults` with component `params` (params win), then render
/// the method template with the merged context. `error.UnsetParam` when a
/// `{{ key }}` has no value; `error.UnknownMethod` when the catalog has no
/// such method id.
pub fn resolveMethod(allocator: std.mem.Allocator, catalog: *const Method.Catalog, comp: *const Component, ws: *const Workspace) !ResolvedMethod {
    const method = catalog.find(comp.method_id) orelse return error.UnknownMethod;

    var params = std.ArrayListUnmanaged(Pair){};
    defer params.deinit(allocator);

    var defaults_doc = yaml.parse(allocator, method.content) catch return error.ParseFailed;
    defer defaults_doc.deinit();
    if (defaults_doc.value.get("defaults")) |dv| {
        const defaults = try collectStringMap(allocator, dv);
        defer allocator.free(defaults);
        for (defaults) |p| try params.append(allocator, p);
    }
    for (comp.params) |p| {
        var replaced = false;
        for (params.items) |*e| {
            if (std.mem.eql(u8, e.key, p.key)) {
                e.value = p.value;
                replaced = true;
                break;
            }
        }
        if (!replaced) try params.append(allocator, p);
    }

    const comp_path = projectPath(ws, comp.project);
    const lookup = Lookup{
        .allocator = allocator,
        .params = params.items,
        .ws_name = ws.name,
        .ws_path = comp_path,
        .env = ws.env,
    };
    try lookup.ensureAll(method.content);

    const rendered = try renderTemplate(allocator, method.content, lookup);
    defer allocator.free(rendered);

    var rm = try parseResolved(allocator, rendered, method.runtime);
    if (comp.healthcheck) |hc| rm.healthcheck = hc;
    return rm;
}

fn parseResolved(allocator: std.mem.Allocator, rendered: []const u8, runtime: []const u8) !ResolvedMethod {
    var doc = yaml.parse(allocator, rendered) catch return error.ParseFailed;
    defer doc.deinit();
    const root = doc.value;

    var rm = ResolvedMethod{ .runtime = try allocator.dupe(u8, runtime) };
    if (root.get("command")) |v| {
        if (v.getString()) |s| rm.command = try allocator.dupe(u8, s);
    }
    if (root.get("image")) |v| {
        if (v.getString()) |s| rm.image = try allocator.dupe(u8, s);
    }
    if (root.get("dir")) |v| {
        if (v.getString()) |s| rm.dir = try allocator.dupe(u8, s);
    }
    if (root.get("tool")) |v| {
        if (v.getString()) |s| rm.tool = try allocator.dupe(u8, s);
    }
    if (root.get("file")) |v| {
        if (v.getString()) |s| rm.file = try allocator.dupe(u8, s);
    }
    if (root.get("name")) |v| {
        if (v.getString()) |s| rm.task_name = try allocator.dupe(u8, s);
    }
    if (root.get("healthcheck")) |hc| rm.healthcheck = try parseHealthcheck(allocator, hc);

    if (root.get("ports")) |v| rm.ports = try collectStringList(allocator, v);
    if (root.get("volumes")) |v| rm.volumes = try collectStringList(allocator, v);
    if (root.get("args")) |v| rm.args = try collectStringList(allocator, v);
    return rm;
}

fn collectStringList(allocator: std.mem.Allocator, v: yaml.Value) ![]const []const u8 {
    var items = std.ArrayListUnmanaged([]const u8){};
    if (v.getSequence()) |seq| {
        for (seq) |it| {
            if (it.getString()) |s| try items.append(allocator, try allocator.dupe(u8, s));
        }
    }
    return items.toOwnedSlice(allocator);
}

// ────────────────────────────────────────────────────────────
// Command construction (pure, testable)
// ────────────────────────────────────────────────────────────

/// Resolve a workspace `path` field to an absolute directory (handles `~/`).
pub fn resolvePath(allocator: std.mem.Allocator, paths: *const Paths, raw: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, raw, "~/")) {
        return std.fs.path.join(allocator, &.{ paths.home_dir, raw[2..] });
    }
    if (std.fs.path.isAbsolute(raw)) return allocator.dupe(u8, raw);
    return std.fs.cwd().realpathAlloc(allocator, raw) catch allocator.dupe(u8, raw);
}

/// Pi's session store directory for a workspace path, mirroring pi's own
/// encoding: strip the leading `/`, replace `/`, `\`, `:` with `-`, wrap in
/// `--...--` under `~/.pi/agent/sessions/`.
pub fn sessionDirFor(allocator: std.mem.Allocator, paths: *const Paths, raw_path: []const u8) ![]const u8 {
    const resolved = try resolvePath(allocator, paths, raw_path);
    defer allocator.free(resolved);

    var encoded = std.ArrayListUnmanaged(u8){};
    defer encoded.deinit(allocator);
    try encoded.appendSlice(allocator, "--");
    const body = if (resolved.len > 0 and (resolved[0] == '/' or resolved[0] == '\\'))
        resolved[1..]
    else
        resolved;
    for (body) |c| {
        if (c == '/' or c == '\\' or c == ':') {
            try encoded.append(allocator, '-');
        } else {
            try encoded.append(allocator, c);
        }
    }
    try encoded.appendSlice(allocator, "--");

    const agent_dir = try paths.piAgentDir(allocator);
    defer allocator.free(agent_dir);
    return std.fs.path.join(allocator, &.{ agent_dir, "sessions", encoded.items });
}

/// Absolute working directory for a component: workspace path + method `dir`.
pub fn componentDir(allocator: std.mem.Allocator, ws_path: []const u8, rm: *const ResolvedMethod) ![]const u8 {
    if (rm.dir) |d| {
        if (d.len == 0) return allocator.dupe(u8, ws_path);
        if (std.fs.path.isAbsolute(d)) return allocator.dupe(u8, d);
        return std.fs.path.join(allocator, &.{ ws_path, d });
    }
    return allocator.dupe(u8, ws_path);
}

pub fn containerName(allocator: std.mem.Allocator, ws_name: []const u8, window: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "tin-{s}-{s}", .{ ws_name, window });
}

fn shQuote(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '\'') == null) {
        return std.fmt.allocPrint(allocator, "'{s}'", .{s});
    }
    var out = std.ArrayListUnmanaged(u8){};
    try out.append(allocator, '\'');
    for (s) |c| {
        if (c == '\'') {
            try out.appendSlice(allocator, "'\\''");
        } else {
            try out.append(allocator, c);
        }
    }
    try out.append(allocator, '\'');
    return out.toOwnedSlice(allocator);
}

fn appendEnvOnce(a: std.mem.Allocator, o: *std.ArrayListUnmanaged(u8), seen: *std.ArrayListUnmanaged([]const u8), pairs: []const Pair) !void {
    for (pairs) |p| {
        var already = false;
        for (seen.items) |k| {
            if (std.mem.eql(u8, k, p.key)) {
                already = true;
                break;
            }
        }
        if (already) continue;
        try seen.append(a, p.key);
        const q = try shQuote(a, p.value);
        try o.writer(a).print("export {s}={s}; ", .{ p.key, q });
    }
}

/// `export A='x'; export B='y'; ` prefix for a component's env, merged over the
/// workspace base env (component wins).
pub fn envExport(allocator: std.mem.Allocator, ws: *const Workspace, comp: *const Component) ![]const u8 {
    var out = std.ArrayListUnmanaged(u8){};
    var seen = std.ArrayListUnmanaged([]const u8){};

    try appendEnvOnce(allocator, &out, &seen, ws.env);
    try appendEnvOnce(allocator, &out, &seen, comp.env);
    return out.toOwnedSlice(allocator);
}

/// Wrap a command with `mise exec -- <tool> -- <command>` when a tool is pinned.
pub fn wrapCommand(allocator: std.mem.Allocator, tool: ?[]const u8, command: []const u8) ![]const u8 {
    if (tool) |tl| {
        if (tl.len > 0) {
            return std.fmt.allocPrint(allocator, "mise exec -- {s} -- {s}", .{ tl, command });
        }
    }
    return allocator.dupe(u8, command);
}

pub const Runtime = enum { process, container, compose, task };

pub fn runtimeKind(runtime: []const u8) ?Runtime {
    return std.meta.stringToEnum(Runtime, runtime);
}

/// `mise` is optional: when it is not installed, process components run their
/// command directly instead of failing (graceful fallback per the design).
pub fn miseAvailable(allocator: std.mem.Allocator) bool {
    const res = process.captureExit(allocator, &.{ "sh", "-c", "command -v mise" }) catch return false;
    return res.code == 0;
}

// ────────────────────────────────────────────────────────────
// tmux + docker executors
// ────────────────────────────────────────────────────────────

const Docker = struct {
    fn available(allocator: std.mem.Allocator) bool {
        const res = process.captureExit(allocator, &.{ "sh", "-c", "command -v docker" }) catch return false;
        return res.code == 0;
    }

    fn running(allocator: std.mem.Allocator, cname: []const u8) bool {
        const res = process.captureExit(allocator, &.{ "docker", "inspect", "-f", "{{.State.Running}}", cname }) catch return false;
        return res.code == 0 and std.mem.indexOf(u8, res.stdout, "true") != null;
    }

    fn runContainer(allocator: std.mem.Allocator, ws: *const Workspace, comp: *const Component, rm: *const ResolvedMethod, ws_path: []const u8) !void {
        const image = rm.image orelse return error.CommandFailed;
        const cname = try containerName(allocator, ws.name, comp.key);

        var argv = std.ArrayListUnmanaged([]const u8){};
        defer argv.deinit(allocator);
        try argv.appendSlice(allocator, &.{ "docker", "run", "-d", "--name", cname });
        for (rm.ports) |p| try argv.appendSlice(allocator, &.{ "-p", p });
        for (rm.volumes) |v| try argv.appendSlice(allocator, &.{ "-v", v });

        var seen = std.ArrayListUnmanaged([]const u8){};
        defer seen.deinit(allocator);
        var merged = std.ArrayListUnmanaged([]const u8){};
        defer merged.deinit(allocator);
        for (ws.env) |p| {
            var already = false;
            for (seen.items) |k| {
                if (std.mem.eql(u8, k, p.key)) {
                    already = true;
                    break;
                }
            }
            if (already) continue;
            try seen.append(allocator, p.key);
            try merged.append(allocator, try std.fmt.allocPrint(allocator, "{s}={s}", .{ p.key, p.value }));
        }
        for (comp.env) |p| {
            var already = false;
            for (seen.items) |k| {
                if (std.mem.eql(u8, k, p.key)) {
                    already = true;
                    break;
                }
            }
            if (already) continue;
            try seen.append(allocator, p.key);
            try merged.append(allocator, try std.fmt.allocPrint(allocator, "{s}={s}", .{ p.key, p.value }));
        }
        for (merged.items) |e| try argv.appendSlice(allocator, &.{ "-e", e });

        try argv.append(allocator, image);
        _ = ws_path;
        try process.run(allocator, argv.items);
    }

    fn stopRm(allocator: std.mem.Allocator, cname: []const u8) void {
        _ = process.captureExit(allocator, &.{ "docker", "stop", cname }) catch {};
        _ = process.captureExit(allocator, &.{ "docker", "rm", cname }) catch {};
    }
};

pub fn loadWorkspace(allocator: std.mem.Allocator, paths: *const Paths, name: []const u8) !Workspace {
    const ws = registry.load(allocator, paths.*, name) catch return error.NotARegisteredWorkspace;
    return parseWorkspace(allocator, ws.content);
}

fn parseIntervalMs(s: []const u8) u64 {
    if (std.mem.endsWith(u8, s, "ms")) return std.fmt.parseInt(u64, s[0 .. s.len - 2], 10) catch 1000;
    if (std.mem.endsWith(u8, s, "s")) return (std.fmt.parseInt(u64, s[0 .. s.len - 1], 10) catch 5) * 1000;
    if (std.mem.endsWith(u8, s, "m")) return (std.fmt.parseInt(u64, s[0 .. s.len - 1], 10) catch 1) * 60_000;
    return (std.fmt.parseInt(u64, s, 10) catch 5) * 1000;
}

fn waitHealthy(allocator: std.mem.Allocator, ws_path: []const u8, rm: *const ResolvedMethod, key: []const u8) !void {
    const hc = rm.healthcheck orelse return error.NoHealthcheck;
    const interval_ms = parseIntervalMs(hc.interval);
    const retries = if (hc.retries == 0) 1 else hc.retries;

    output.info("waiting for health: {s} ({s})", .{ key, hc.command });
    var attempt: usize = 0;
    while (attempt < retries) : (attempt += 1) {
        const res = process.captureExitCwd(allocator, &.{ "sh", "-c", hc.command }, ws_path) catch {
            std.Thread.sleep(interval_ms * std.time.ns_per_ms);
            continue;
        };
        if (res.code == 0) {
            output.success("healthy: {s}", .{key});
            return;
        }
        std.Thread.sleep(interval_ms * std.time.ns_per_ms);
    }
    return error.CommandFailed;
}

// ────────────────────────────────────────────────────────────
// Lifecycle
// ────────────────────────────────────────────────────────────

pub fn up(allocator: std.mem.Allocator, paths: *const Paths, name: []const u8, only: ?[]const u8) !void {
    const ws = try loadWorkspace(allocator, paths, name);
    if (!tmux.available(allocator)) return error.TmuxUnavailable;

    var catalog = try Method.Catalog.init(allocator, paths);
    defer catalog.deinit();

    const resolved = try allocator.alloc(ResolvedMethod, ws.components.len);
    defer allocator.free(resolved);
    for (ws.components, 0..) |*c, i| {
        resolved[i] = try resolveMethod(allocator, &catalog, c, &ws);
    }

    const order = try topoSort(allocator, &ws, only);
    const ws_path = try resolvePath(allocator, paths, ws.path);
    defer allocator.free(ws_path);

    if (!tmux.hasSession(allocator, ws.name)) {
        try tmux.createSessionSimple(allocator, ws.name, ws_path);
        output.info("session up: tin-{s}", .{ws.name});
    }

    for (order) |key| {
        const i = ws.findComponent(key).?;
        const comp = &ws.components[i];
        const rm = &resolved[i];

        for (comp.depends) |d| {
            if (std.mem.eql(u8, d.condition, "healthy")) {
                const dj = ws.findComponent(d.target) orelse return error.UnknownDep;
                try waitHealthy(allocator, ws_path, &resolved[dj], d.target);
            }
        }

        try bootComponent(allocator, &ws, comp, rm, ws_path);
    }
}

fn bootComponent(allocator: std.mem.Allocator, ws: *const Workspace, comp: *const Component, rm: *const ResolvedMethod, ws_path: []const u8) !void {
    const count = if (comp.scale == 0) 1 else comp.scale;
    var replica: usize = 0;
    while (replica < count) : (replica += 1) {
        const window = if (replica == 0)
            allocator.dupe(u8, comp.key) catch return error.CommandFailed
        else
            std.fmt.allocPrint(allocator, "{s}.{d}", .{ comp.key, replica }) catch return error.CommandFailed;
        defer allocator.free(window);
        try bootReplica(allocator, ws, comp, rm, ws_path, window, replica);
    }
}

fn bootReplica(allocator: std.mem.Allocator, ws: *const Workspace, comp: *const Component, rm: *const ResolvedMethod, ws_path: []const u8, window: []const u8, replica: usize) !void {
    const kind = runtimeKind(rm.runtime) orelse return error.UnknownMethod;
    const dir = try componentDir(allocator, ws_path, rm);
    defer allocator.free(dir);

    switch (kind) {
        .process => {
            if (tmux.hasWindow(allocator, ws.name, window)) {
                output.info("skip (running): {s}:{s}", .{ ws.name, window });
                return;
            }
            const env_prefix = try envExport(allocator, ws, comp);
            defer allocator.free(env_prefix);
            const cmd_line = try std.fmt.allocPrint(allocator, "{s}{s}", .{ env_prefix, rm.command orelse return error.CommandFailed });
            defer allocator.free(cmd_line);
            const use_mise = rm.tool != null and rm.tool.?.len > 0 and miseAvailable(allocator);
            const final_cmd = if (use_mise)
                try wrapCommand(allocator, rm.tool, cmd_line)
            else
                cmd_line;
            defer if (use_mise) allocator.free(final_cmd);
            try tmux.createWindow(allocator, ws.name, window, dir, final_cmd);
            output.success("up {s}:{s}", .{ ws.name, window });
        },
        .container => {
            const cname = try containerName(allocator, ws.name, window);
            defer allocator.free(cname);
            if (Docker.running(allocator, cname)) {
                output.info("skip (running): {s}", .{cname});
            } else {
                if (!Docker.available(allocator)) return error.DockerUnavailable;
                try Docker.runContainer(allocator, ws, comp, rm, ws_path);
                output.success("up {s}:{s} (container {s})", .{ ws.name, window, cname });
            }
            if (!tmux.hasWindow(allocator, ws.name, window)) {
                const logcmd = try std.fmt.allocPrint(allocator, "docker logs -f {s}", .{cname});
                defer allocator.free(logcmd);
                try tmux.createWindow(allocator, ws.name, window, ws_path, logcmd);
            }
            _ = replica;
        },
        .compose => {
            const file = rm.file orelse return error.CommandFailed;
            const target = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ ws.name, window });
            defer allocator.free(target);
            if (tmux.hasWindow(allocator, ws.name, window)) {
                output.info("skip (running): {s}", .{target});
                return;
            }
            const cmd_line = try std.fmt.allocPrint(allocator, "docker compose -f {s} up -d; exec docker compose -f {s} logs -f", .{ file, file });
            defer allocator.free(cmd_line);
            try tmux.createWindow(allocator, ws.name, window, dir, cmd_line);
            output.success("up {s}:{s} (compose {s})", .{ ws.name, window, file });
        },
        .task => {
            if (tmux.hasWindow(allocator, ws.name, window)) {
                output.info("skip (running): {s}:{s}", .{ ws.name, window });
                return;
            }
            const task_name = rm.task_name orelse return error.CommandFailed;
            if (!miseAvailable(allocator)) return error.NoMise;
            var args_buf = std.ArrayListUnmanaged(u8){};
            defer args_buf.deinit(allocator);
            for (rm.args) |a| try args_buf.writer(allocator).print(" {s}", .{a});
            const cmd_line = try std.fmt.allocPrint(allocator, "mise run {s}{s}", .{ task_name, args_buf.items });
            defer allocator.free(cmd_line);
            try tmux.createWindow(allocator, ws.name, window, dir, cmd_line);
            output.success("up {s}:{s} (task {s})", .{ ws.name, window, task_name });
        },
    }
}

pub fn down(allocator: std.mem.Allocator, paths: *const Paths, name: []const u8) !void {
    const ws = try loadWorkspace(allocator, paths, name);

    var catalog = try Method.Catalog.init(allocator, paths);
    defer catalog.deinit();

    const resolved = try allocator.alloc(ResolvedMethod, ws.components.len);
    defer allocator.free(resolved);
    for (ws.components, 0..) |*c, i| {
        resolved[i] = try resolveMethod(allocator, &catalog, c, &ws);
    }

    const order = try topoSort(allocator, &ws, null);
    const ws_path = try resolvePath(allocator, paths, ws.path);
    defer allocator.free(ws_path);

    var i: usize = order.len;
    while (i > 0) {
        i -= 1;
        const key = order[i];
        const ci = ws.findComponent(key).?;
        const comp = &ws.components[ci];
        const rm = &resolved[ci];
        const kind = runtimeKind(rm.runtime) orelse continue;

        switch (kind) {
            .container => {
                const count = if (comp.scale == 0) 1 else comp.scale;
                var replica: usize = 0;
                while (replica < count) : (replica += 1) {
                    const window = if (replica == 0)
                        comp.key
                    else
                        try std.fmt.allocPrint(allocator, "{s}.{d}", .{ comp.key, replica });
                    if (replica != 0) allocator.free(window);
                    const cname = try containerName(allocator, ws.name, window);
                    defer allocator.free(cname);
                    if (Docker.running(allocator, cname)) {
                        Docker.stopRm(allocator, cname);
                        output.info("down container: {s}", .{cname});
                    }
                }
            },
            .compose => {
                const file = rm.file orelse continue;
                const cmd_line = try std.fmt.allocPrint(allocator, "docker compose -f {s} down", .{file});
                defer allocator.free(cmd_line);
                _ = process.captureExitCwd(allocator, &.{ "sh", "-c", cmd_line }, ws_path) catch {};
                output.info("down compose: {s}", .{comp.key});
            },
            .process, .task => {},
        }
    }

    tmux.killSession(allocator, ws.name);
    output.success("down {s}", .{name});
}

pub fn statusOne(allocator: std.mem.Allocator, paths: *const Paths, ws: *const Workspace) !void {
    const running = tmux.hasSession(allocator, ws.name);
    const ws_path = try resolvePath(allocator, paths, ws.path);
    defer allocator.free(ws_path);

    if (running) {
        const count = tmux.windowCount(allocator, ws.name);
        output.info("{s}  running (tin-{s}, {d} windows)", .{ ws.name, ws.name, count });
    } else {
        output.info("{s}  stopped", .{ws.name});
    }
    output.plain("  path: {s}", .{ws.path});

    if (ws.components.len == 0) {
        output.plain("  components: none (shell-only)", .{});
        return;
    }

    var catalog = try Method.Catalog.init(allocator, paths);
    defer catalog.deinit();

    output.plain("  components:", .{});
    for (ws.components) |*comp| {
        var state: []const u8 = "down";
        if (running) {
            if (tmux.hasWindow(allocator, ws.name, comp.key)) state = "up";
        }
        const rm = resolveMethod(allocator, &catalog, comp, ws) catch null;
        const runtime = if (rm) |r| r.runtime else "?";
        output.plain("    {s:<20} {s:<10} {s}", .{ comp.key, runtime, state });
    }
}

pub fn status(allocator: std.mem.Allocator, paths: *const Paths) !void {
    const names = registry.listNames(allocator, paths.*) catch return;
    if (names.len == 0) {
        output.info("no workspaces registered", .{});
        output.plain("  Run 'tin workspace add <name> <path>' to register one.", .{});
        return;
    }
    for (names) |name| {
        const ws = loadWorkspace(allocator, paths, name) catch continue;
        try statusOne(allocator, paths, &ws);
    }
}

/// List Pi conversation history for a workspace: maps its `path` to Pi's
/// session store and lists the `.jsonl` files, with resume guidance.
pub fn sessions(allocator: std.mem.Allocator, paths: *const Paths, name: []const u8) !void {
    const ws = try loadWorkspace(allocator, paths, name);
    const session_dir = try sessionDirFor(allocator, paths, ws.path);
    defer allocator.free(session_dir);

    output.info("sessions for {s} ({s})", .{ ws.name, ws.path });
    output.plain("  store: {s}", .{session_dir});
    output.plain("", .{});

    if (!fs.pathExists(session_dir)) {
        output.plain("  (no sessions yet — the first Pi conversation in this workspace creates one)", .{});
        output.plain("", .{});
        output.plain("  resume: cd {s} && pi -c    # continue most recent", .{ws.path});
        output.plain("  browse: cd {s} && pi -r", .{ws.path});
        return;
    }

    var dir = std.fs.openDirAbsolute(session_dir, .{ .iterate = true }) catch {
        output.plain("  (could not read session store)", .{});
        return;
    };
    defer dir.close();

    var files = std.ArrayListUnmanaged([]const u8){};
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        try files.append(allocator, try allocator.dupe(u8, entry.name));
    }

    if (files.items.len == 0) {
        output.plain("  (store exists but has no sessions)", .{});
        output.plain("", .{});
        output.plain("  resume: cd {s} && pi -c", .{ws.path});
        return;
    }

    std.mem.sort([]const u8, files.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    output.plain("  {d} session(s):", .{files.items.len});
    for (files.items, 0..) |f, i| {
        const marker = if (i == files.items.len - 1) "  *" else "   ";
        output.plain("{s} {s}", .{ marker, f });
    }
    output.plain("", .{});
    output.plain("  resume: cd {s} && pi -c            # continue most recent (*)", .{ws.path});
    output.plain("  browse: cd {s} && pi -r", .{ws.path});
    output.plain("  open:   pi --session {s}/{s}", .{ session_dir, files.items[files.items.len - 1] });
}

// ────────────────────────────────────────────────────────────
// Tests
// ────────────────────────────────────────────────────────────

const t = std.testing;

fn testWorkspace() []const u8 {
    return 
    \\name: myapp
    \\path: ~/dev/myapp
    \\env:
    \\  NODE_ENV: development
    \\components:
    \\  db:
    \\    method: postgres
    \\    params: { port: 5433 }
    \\  api:
    \\    method: node-dev
    \\    params: { dir: services/api, script: dev }
    \\  worker:
    \\    method: node-dev
    \\    params: { dir: services/api, script: worker }
    \\topology:
    \\  api:
    \\    depends_on: { db: { condition: healthy } }
    \\  worker:
    \\    depends_on: { db: { condition: started } }
    \\
    ;
}

test "parseWorkspace extracts components and topology" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ws = try parseWorkspace(a, testWorkspace());
    try t.expectEqualStrings("myapp", ws.name);
    try t.expectEqualStrings("~/dev/myapp", ws.path);
    try t.expectEqual(@as(usize, 3), ws.components.len);
    try t.expectEqual(@as(usize, 1), ws.env.len);

    const db = ws.components[0];
    try t.expectEqualStrings("db", db.key);
    try t.expectEqualStrings("postgres", db.method_id);
    try t.expectEqual(@as(usize, 1), db.params.len);
    try t.expectEqualStrings("port", db.params[0].key);

    const api = ws.components[1];
    try t.expectEqual(@as(usize, 1), api.depends.len);
    try t.expectEqualStrings("db", api.depends[0].target);
    try t.expectEqualStrings("healthy", api.depends[0].condition);

    const worker = ws.components[2];
    try t.expectEqualStrings("started", worker.depends[0].condition);
}

test "topoSort orders dependencies first and detects cycles" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ws = try parseWorkspace(a, testWorkspace());
    const order = try topoSort(a, &ws, null);
    try t.expectEqual(@as(usize, 3), order.len);
    try t.expectEqualStrings("db", order[0]);
    // api/worker order between the two is unspecified; both after db
    try t.expectEqualStrings("db", order[0]);
    try t.expect(std.mem.eql(u8, "api", order[1]) or std.mem.eql(u8, "worker", order[1]));

    const cyclic =
        \\name: cyc
        \\path: /tmp
        \\components:
        \\  a: { method: x }
        \\  b: { method: y }
        \\topology:
        \\  a: { depends_on: { b: {} } }
        \\  b: { depends_on: { a: {} } }
        \\
    ;
    const cws = try parseWorkspace(a, cyclic);
    try t.expectError(error.DepCycle, topoSort(a, &cws, null));
}

test "topoSort with start selects transitive subgraph" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ws = try parseWorkspace(a, testWorkspace());
    const order = try topoSort(a, &ws, "api");
    try t.expectEqual(@as(usize, 2), order.len);
    try t.expectEqualStrings("db", order[0]);
    try t.expectEqualStrings("api", order[1]);
}

test "renderTemplate fills params and detects unset" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const lookup = Lookup{
        .allocator = a,
        .params = &.{.{ .key = "port", .value = "5433" }},
        .ws_name = "myapp",
        .ws_path = "/tmp/myapp",
        .env = &.{},
    };
    const rendered = try renderTemplate(a, "postgres:{{ port }}:{{ workspace.name }}", lookup);
    try t.expectEqualStrings("postgres:5433:myapp", rendered);

    try t.expectError(error.UnsetParam, lookup.ensureAll("x={{ missing }}"));
}

test "resolveMethod merges defaults and params, templates command" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const tmp = "/tmp/tin_runtime_method_test";
    std.fs.deleteTreeAbsolute(tmp) catch {};
    defer std.fs.deleteTreeAbsolute(tmp) catch {};

    const paths = Paths{
        .tin_dir = try std.fmt.allocPrint(a, "{s}/seed", .{tmp}),
        .home_dir = try std.fmt.allocPrint(a, "{s}/home", .{tmp}),
    };
    const seed_dir = try paths.seedMethodsDir(a);
    try fs.ensureDirectoryExists(seed_dir);
    const seed_file = try std.fmt.allocPrint(a, "{s}/node-dev.yml", .{seed_dir});
    const content =
        \\name: node-dev
        \\runtime: process
        \\defaults:
        \\  tool: node@22
        \\  script: dev
        \\tool: {{ tool }}
        \\command: npm run {{ script }}
        \\dir: {{ dir }}
        \\
    ;
    const file = try std.fs.createFileAbsolute(seed_file, .{});
    defer file.close();
    try file.writeAll(content);

    var catalog = try Method.Catalog.init(a, &paths);
    defer catalog.deinit();

    const ws = try parseWorkspace(a, testWorkspace());
    const api = &ws.components[1];
    const rm = try resolveMethod(a, &catalog, api, &ws);
    try t.expectEqualStrings("process", rm.runtime);
    try t.expectEqualStrings("node@22", rm.tool.?);
    try t.expectEqualStrings("npm run dev", rm.command.?);
    try t.expectEqualStrings("services/api", rm.dir.?);
}

test "envExport merges workspace env under component env" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ws = try parseWorkspace(a, testWorkspace());
    const comp = &ws.components[1];
    const ex = try envExport(a, &ws, comp);
    try t.expect(std.mem.indexOf(u8, ex, "NODE_ENV='development'") != null);
}

test "wrapCommand adds mise wrapper when tool present" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const wrapped = try wrapCommand(a, "node@22", "npm run dev");
    try t.expectEqualStrings("mise exec -- node@22 -- npm run dev", wrapped);
    const plain = try wrapCommand(a, null, "npm run dev");
    try t.expectEqualStrings("npm run dev", plain);
}

test "containerName builds tin-<ws>-<key>" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cname = try containerName(a, "myapp", "db");
    try t.expectEqualStrings("tin-myapp-db", cname);
}

test "componentDir joins workspace path and relative dir" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const rm = ResolvedMethod{ .runtime = "process", .dir = "services/api" };
    const dir = try componentDir(a, "/tmp/myapp", &rm);
    try t.expectEqualStrings("/tmp/myapp/services/api", dir);
}

test "sessionDirFor mirrors pi's path encoding" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const paths = Paths{
        .tin_dir = "/tmp/tin",
        .home_dir = "/Users/tanvirtin",
    };
    const dir = try sessionDirFor(a, &paths, "/Users/tanvirtin/.tin");
    try t.expectEqualStrings("/Users/tanvirtin/.pi/agent/sessions/--Users-tanvirtin-.tin--", dir);

    const tildy = try sessionDirFor(a, &paths, "~/dev/myapp");
    try t.expectEqualStrings("/Users/tanvirtin/.pi/agent/sessions/--Users-tanvirtin-dev-myapp--", tildy);
}
